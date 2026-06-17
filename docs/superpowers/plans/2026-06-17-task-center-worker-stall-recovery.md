# Task Center Worker Stall Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add worker execution runs, stalled-work detection, and in-chat recovery controls so `in_progress` tasks cannot silently remain stuck with a worker agent.

**Architecture:** Extend the existing task-center model with `TaskCenterWorkRun`, then route all worker ownership through store methods that create, update, scan, recover, and complete those runs. Expose the lifecycle through TaskCenterAgentApi/MCP tools, surface stalled work in Workspace Chat, and show run context in Kanban details and Agents tab without replacing the current board/chat architecture.

**Tech Stack:** Dart, Flutter, `ChangeNotifier`, local JSON persistence via `TaskCenterStore`, MCP tool schemas in `TaskCenterMcpHost`, existing Flutter widget tests and source-level UI tests.

---

## File Structure

- Modify `lib/task_center/task_center_models.dart`
  - Add `TaskCenterWorkRunState`, `TaskCenterWorkBlockerType`, `TaskCenterRecoverAction`, and `TaskCenterWorkRun`.
  - Add `workRuns` to `TaskCenterTask`, JSON read/write, and agent JSON.
- Modify `lib/task_center/task_center_store.dart`
  - Add lifecycle methods: `startWorkRun`, `heartbeatWorkRun`, `reportWorkBlocker`, `releaseWorkTask`, `listStalledWork`, `recoverStalledTask`.
  - Update `claimWorkTask`, `recordExecutionResult`, and delivery paths to preserve active run state.
- Modify `lib/task_center/task_center_controller.dart`
  - Add wrapper methods for UI use.
- Modify `lib/task_center/task_center_agent_api.dart`
  - Add agent-facing tools for work-run lifecycle and recovery.
  - Harden `task_center_deliver_work_result` so non-active-worker delivery goes to review.
- Modify `lib/task_center/task_center_mcp_host.dart`
  - Add tool descriptions and JSON schemas.
- Modify `lib/app.dart`
  - Update fast-agent prompt rules and workspace chat prompt to query stalled work before dispatch.
- Modify `lib/ui/components/task_center_board.dart`
  - Add stalled-work cards in Workspace Chat.
  - Add execution summary to Kanban cards and task details.
  - Add task/run context to Agents tab session tiles.
- Modify tests:
  - `test/task_center/task_center_store_test.dart`
  - `test/task_center/task_center_agent_api_test.dart`
  - `test/task_center/task_center_mcp_host_test.dart`
  - `test/task_center/task_center_controller_test.dart`
  - `test/ui/task_center_board_test.dart`
  - `test/ui/acp_client_app_test.dart`

## Task 1: Work Run Model And JSON Compatibility

**Files:**
- Modify: `lib/task_center/task_center_models.dart`
- Test: `test/task_center/task_center_store_test.dart`

- [ ] **Step 1: Write failing model persistence tests**

Add this test near the existing persistence tests in `test/task_center/task_center_store_test.dart`:

```dart
test('persists task work runs and reads old tasks without runs', () async {
  final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
  addTearDown(() => temp.delete(recursive: true));
  final ids = _IdSequence();
  final store = TaskCenterStore(
    path: '${temp.path}/task_center.json',
    now: () => DateTime.utc(2026, 6, 17, 15),
    idGenerator: ids.next,
  );

  final workspace = await store.createWorkspace(title: 'Worker recovery');
  final task = await store.createTask(
    workspaceId: workspace.id,
    title: 'Implement recovery',
    status: TaskCenterStatus.inProgress,
  );

  final updated = await store.updateTask(
    workspaceId: workspace.id,
    taskId: task.id,
    workRuns: [
      TaskCenterWorkRun(
        id: 'run-1',
        taskId: task.id,
        agentName: 'codex-worker',
        sessionId: 'session-1',
        state: TaskCenterWorkRunState.running,
        startedAt: DateTime.utc(2026, 6, 17, 15),
        lastHeartbeatAt: DateTime.utc(2026, 6, 17, 15, 1),
        progressSummary: 'Editing task center store.',
      ),
    ],
  );

  expect(updated.workRuns.single.state, TaskCenterWorkRunState.running);

  final snapshot = await TaskCenterStore(path: store.path).load();
  final reloadedTask = snapshot.workspaces.single.tasks.single;
  expect(reloadedTask.workRuns.single.id, 'run-1');
  expect(reloadedTask.workRuns.single.agentName, 'codex-worker');

  final raw = jsonDecode(await File(store.path).readAsString())
      as Map<String, Object?>;
  final tasks =
      ((raw['workspaces'] as List<Object?>).single as Map<String, Object?>)[
              'tasks']
          as List<Object?>;
  final jsonTask = tasks.single as Map<String, Object?>;
  jsonTask.remove('work_runs');
  await File(store.path).writeAsString(jsonEncode(raw));

  final oldSnapshot = await TaskCenterStore(path: store.path).load();
  expect(oldSnapshot.workspaces.single.tasks.single.workRuns, isEmpty);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
flutter test test/task_center/task_center_store_test.dart --plain-name "persists task work runs and reads old tasks without runs"
```

Expected: FAIL with missing `TaskCenterWorkRun`, `TaskCenterWorkRunState`, or `workRuns`.

- [ ] **Step 3: Implement model types and JSON fields**

Add these model types to `lib/task_center/task_center_models.dart` after `TaskCenterReadiness`:

```dart
enum TaskCenterWorkRunState {
  claimed('claimed', 'Claimed'),
  running('running', 'Running'),
  waitingPermission('waiting_permission', 'Waiting Permission'),
  waitingHuman('waiting_human', 'Waiting Human'),
  blocked('blocked', 'Blocked'),
  stale('stale', 'Stale'),
  failed('failed', 'Failed'),
  released('released', 'Released'),
  delivered('delivered', 'Delivered');

  const TaskCenterWorkRunState(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterWorkRunState fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final state in values) {
      if (state.id == normalized) return state;
    }
    throw FormatException('Unknown work run state "$id".');
  }
}

enum TaskCenterWorkBlockerType {
  unclearGoal('unclear_goal'),
  missingAcceptance('missing_acceptance'),
  needsHuman('needs_human'),
  permission('permission'),
  toolError('tool_error'),
  externalDependency('external_dependency'),
  other('other');

  const TaskCenterWorkBlockerType(this.id);

  final String id;

  static TaskCenterWorkBlockerType fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final type in values) {
      if (type.id == normalized) return type;
    }
    throw FormatException('Unknown work blocker type "$id".');
  }
}

enum TaskCenterRecoverAction {
  nudgeWorker('nudge_worker'),
  reassignWorker('reassign_worker'),
  returnToFast('return_to_fast'),
  sendToThinking('send_to_thinking'),
  askHuman('ask_human'),
  markFailed('mark_failed');

  const TaskCenterRecoverAction(this.id);

  final String id;

  static TaskCenterRecoverAction fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final action in values) {
      if (action.id == normalized) return action;
    }
    throw FormatException('Unknown recovery action "$id".');
  }
}

class TaskCenterWorkRun {
  const TaskCenterWorkRun({
    required this.id,
    required this.taskId,
    required this.agentName,
    required this.state,
    required this.startedAt,
    required this.lastHeartbeatAt,
    this.sessionId = '',
    this.completedAt,
    this.progressSummary = '',
    this.blockerReason = '',
    this.nextCheckAt,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String taskId;
  final String agentName;
  final String sessionId;
  final TaskCenterWorkRunState state;
  final DateTime startedAt;
  final DateTime lastHeartbeatAt;
  final DateTime? completedAt;
  final String progressSummary;
  final String blockerReason;
  final DateTime? nextCheckAt;
  final Map<String, Object?> metadata;

  bool get isActive {
    return switch (state) {
      TaskCenterWorkRunState.claimed ||
      TaskCenterWorkRunState.running ||
      TaskCenterWorkRunState.waitingPermission ||
      TaskCenterWorkRunState.waitingHuman => true,
      _ => false,
    };
  }

  TaskCenterWorkRun copyWith({
    String? sessionId,
    TaskCenterWorkRunState? state,
    DateTime? lastHeartbeatAt,
    DateTime? completedAt,
    String? progressSummary,
    String? blockerReason,
    DateTime? nextCheckAt,
    Map<String, Object?>? metadata,
  }) {
    return TaskCenterWorkRun(
      id: id,
      taskId: taskId,
      agentName: agentName,
      sessionId: sessionId ?? this.sessionId,
      state: state ?? this.state,
      startedAt: startedAt,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      completedAt: completedAt ?? this.completedAt,
      progressSummary: progressSummary ?? this.progressSummary,
      blockerReason: blockerReason ?? this.blockerReason,
      nextCheckAt: nextCheckAt ?? this.nextCheckAt,
      metadata: metadata ?? this.metadata,
    );
  }

  factory TaskCenterWorkRun.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('work run entries must be objects.');
    }
    final json = _jsonMap(raw);
    return TaskCenterWorkRun(
      id: _requiredString(json['id'], 'work_run.id'),
      taskId: _requiredString(json['task_id'] ?? json['taskId'], 'work_run.task_id'),
      agentName: _requiredString(
        json['agent_name'] ?? json['agentName'],
        'work_run.agent_name',
      ),
      sessionId: _stringValue(json['session_id'] ?? json['sessionId']) ?? '',
      state: TaskCenterWorkRunState.fromId(
        _requiredString(json['state'], 'work_run.state'),
      ),
      startedAt: _dateTimeValue(json['started_at'], 'work_run.started_at'),
      lastHeartbeatAt: _dateTimeValue(
        json['last_heartbeat_at'] ?? json['lastHeartbeatAt'],
        'work_run.last_heartbeat_at',
      ),
      completedAt: _optionalDateTimeValue(
        json['completed_at'] ?? json['completedAt'],
        'work_run.completed_at',
      ),
      progressSummary:
          _stringValue(json['progress_summary'] ?? json['progressSummary']) ?? '',
      blockerReason:
          _stringValue(json['blocker_reason'] ?? json['blockerReason']) ?? '',
      nextCheckAt: _optionalDateTimeValue(
        json['next_check_at'] ?? json['nextCheckAt'],
        'work_run.next_check_at',
      ),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      'agent_name': agentName,
      if (sessionId.isNotEmpty) 'session_id': sessionId,
      'state': state.id,
      'started_at': startedAt.toIso8601String(),
      'last_heartbeat_at': lastHeartbeatAt.toIso8601String(),
      if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
      if (progressSummary.isNotEmpty) 'progress_summary': progressSummary,
      if (blockerReason.isNotEmpty) 'blocker_reason': blockerReason,
      if (nextCheckAt != null) 'next_check_at': nextCheckAt!.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{...toJson(), 'state_label': state.label};
  }
}
```

Add this helper near existing date helpers:

```dart
DateTime? _optionalDateTimeValue(Object? value, String field) {
  if (value == null) return null;
  return _dateTimeValue(value, field);
}
```

Update `TaskCenterTask`:

```dart
this.workRuns = const <TaskCenterWorkRun>[],
final List<TaskCenterWorkRun> workRuns;
List<TaskCenterWorkRun>? workRuns,
workRuns: workRuns ?? this.workRuns,
workRuns: _workRuns(json['work_runs'] ?? json['workRuns']),
if (workRuns.isNotEmpty)
  'work_runs': workRuns.map((run) => run.toJson()).toList(),
if (workRuns.isNotEmpty)
  'work_runs': workRuns.map((run) => run.toAgentJson()).toList(),
```

Add parser:

```dart
List<TaskCenterWorkRun> _workRuns(Object? raw) {
  if (raw == null) return const <TaskCenterWorkRun>[];
  if (raw is! List) {
    throw const FormatException('work_runs must be a list.');
  }
  return raw.map(TaskCenterWorkRun.fromJson).toList(growable: false);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run:

```bash
dart format lib/task_center/task_center_models.dart test/task_center/task_center_store_test.dart
flutter test test/task_center/task_center_store_test.dart --plain-name "persists task work runs and reads old tasks without runs"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/task_center/task_center_models.dart test/task_center/task_center_store_test.dart
git commit -m "feat: persist task center work runs"
```

## Task 2: Store Lifecycle And Stalled Work Detection

**Files:**
- Modify: `lib/task_center/task_center_store.dart`
- Modify: `lib/task_center/task_center_models.dart`
- Test: `test/task_center/task_center_store_test.dart`

- [ ] **Step 1: Write failing store lifecycle tests**

Add these tests to `test/task_center/task_center_store_test.dart`:

```dart
test('starts heartbeats and completes active work runs', () async {
  final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
  addTearDown(() => temp.delete(recursive: true));
  final ids = _IdSequence();
  var now = DateTime.utc(2026, 6, 17, 16);
  final store = TaskCenterStore(
    path: '${temp.path}/task_center.json',
    now: () => now,
    idGenerator: ids.next,
  );

  final workspace = await store.createWorkspace(title: 'Worker lifecycle');
  final task = await store.createTask(
    workspaceId: workspace.id,
    title: 'Run worker',
  );

  final started = await store.startWorkRun(
    workspaceId: workspace.id,
    taskId: task.id,
    agentName: 'codex-worker',
    sessionId: 'session-1',
    progressSummary: 'Starting implementation.',
  );
  final runId = started.workRuns.single.id;
  expect(started.status, TaskCenterStatus.inProgress);
  expect(started.currentOwner.agentName, 'codex-worker');
  expect(started.workRuns.single.state, TaskCenterWorkRunState.running);

  now = DateTime.utc(2026, 6, 17, 16, 3);
  final heartbeat = await store.heartbeatWorkRun(
    workspaceId: workspace.id,
    taskId: task.id,
    runId: runId,
    state: TaskCenterWorkRunState.running,
    progressSummary: 'Store method added.',
  );
  expect(heartbeat.workRuns.single.progressSummary, 'Store method added.');

  final delivered = await store.recordExecutionResult(
    workspaceId: workspace.id,
    taskId: task.id,
    executionResult: 'Done.',
    actor: 'codex-worker',
  );
  expect(delivered.workRuns.single.state, TaskCenterWorkRunState.delivered);
});

test('detects stale and missing work runs', () async {
  final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
  addTearDown(() => temp.delete(recursive: true));
  final ids = _IdSequence();
  var now = DateTime.utc(2026, 6, 17, 17);
  final store = TaskCenterStore(
    path: '${temp.path}/task_center.json',
    now: () => now,
    idGenerator: ids.next,
  );

  final workspace = await store.createWorkspace(title: 'Stalled work');
  final staleTask = await store.createTask(
    workspaceId: workspace.id,
    title: 'Stale worker',
  );
  await store.startWorkRun(
    workspaceId: workspace.id,
    taskId: staleTask.id,
    agentName: 'codex-worker',
  );

  final missingTask = await store.createTask(
    workspaceId: workspace.id,
    title: 'Missing run',
    status: TaskCenterStatus.inProgress,
    currentOwner: const TaskCenterTaskOwner.workAgent('codex-worker'),
    readiness: TaskCenterReadiness.ready,
  );

  now = DateTime.utc(2026, 6, 17, 17, 12);
  final stalled = await store.listStalledWork(workspaceId: workspace.id);
  expect(stalled.map((task) => task.id), contains(staleTask.id));
  expect(stalled.map((task) => task.id), contains(missingTask.id));
  expect(stalled.firstWhere((task) => task.id == staleTask.id).readiness,
      TaskCenterReadiness.blocked);
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
flutter test test/task_center/task_center_store_test.dart --plain-name "starts heartbeats and completes active work runs"
flutter test test/task_center/task_center_store_test.dart --plain-name "detects stale and missing work runs"
```

Expected: FAIL with missing store methods.

- [ ] **Step 3: Implement lifecycle methods**

Add these public methods to `TaskCenterStore` with the exact signatures shown here:

```dart
Future<TaskCenterTask> startWorkRun({
  required String workspaceId,
  required String taskId,
  required String agentName,
  String sessionId = '',
  String progressSummary = '',
  String actor = 'agent',
});

Future<TaskCenterTask> heartbeatWorkRun({
  required String workspaceId,
  required String taskId,
  required String runId,
  required TaskCenterWorkRunState state,
  String progressSummary = '',
  int? nextCheckMinutes,
  String actor = 'agent',
});

Future<TaskCenterTask> reportWorkBlocker({
  required String workspaceId,
  required String taskId,
  required String runId,
  required TaskCenterWorkBlockerType blockerType,
  required String blockerReason,
  List<String> questions = const <String>[],
  String actor = 'agent',
});

Future<TaskCenterTask> releaseWorkTask({
  required String workspaceId,
  required String taskId,
  required String runId,
  required String reason,
  String actor = 'agent',
});

Future<List<TaskCenterTask>> listStalledWork({
  required String workspaceId,
});

Future<TaskCenterTask> recoverStalledTask({
  required String workspaceId,
  required String taskId,
  required TaskCenterRecoverAction action,
  String agentName = '',
  String reason = '',
  String actor = 'human',
});
```

Implement `startWorkRun` by loading the snapshot, finding the workspace and task, creating a run with `idGenerator`, marking older active runs as `released`, adding a `work_task_claimed` event, setting `status` to `inProgress`, setting owner to `TaskCenterTaskOwner.workAgent(agentName)`, and setting readiness to `TaskCenterReadiness.ready`.

Implement `heartbeatWorkRun` by finding the run, updating `state`, `lastHeartbeatAt`, `progressSummary`, and `nextCheckAt`, then appending a `work_run_heartbeat` event.

Implement `reportWorkBlocker` by updating the run blocker state and applying this routing:

```dart
final nextReadiness = switch (blockerType) {
  TaskCenterWorkBlockerType.needsHuman => TaskCenterReadiness.waitingHuman,
  TaskCenterWorkBlockerType.permission => TaskCenterReadiness.blocked,
  TaskCenterWorkBlockerType.unclearGoal ||
  TaskCenterWorkBlockerType.missingAcceptance => TaskCenterReadiness.needsInfo,
  _ => TaskCenterReadiness.blocked,
};
final nextOwner = blockerType == TaskCenterWorkBlockerType.needsHuman
    ? const TaskCenterTaskOwner.human()
    : const TaskCenterTaskOwner.fastAgent('');
```

When `blockerType` is `needsHuman`, create human questions from the `questions` list. When it is not `needsHuman`, keep existing human questions unchanged.

Implement `releaseWorkTask` by marking the run `released`, setting owner to fast agent when the workspace has one, otherwise unassigned, setting readiness to `blocked`, and appending a `work_task_released` event.

Implement `listStalledWork` by loading the workspace, marking stale active runs in memory and in persisted tasks, and returning tasks that have stale, blocked, failed, released, or missing active runs.

Implement `recoverStalledTask` by applying this routing:

```dart
final nextOwner = switch (action) {
  TaskCenterRecoverAction.nudgeWorker => task.currentOwner,
  TaskCenterRecoverAction.reassignWorker => TaskCenterTaskOwner.workAgent(agentName),
  TaskCenterRecoverAction.returnToFast => TaskCenterTaskOwner.fastAgent(
    workspace.agentConfig.fastAgentName,
  ),
  TaskCenterRecoverAction.sendToThinking => TaskCenterTaskOwner.thinkingAgent(
    workspace.agentConfig.thinkingAgentName,
  ),
  TaskCenterRecoverAction.askHuman => const TaskCenterTaskOwner.human(),
  TaskCenterRecoverAction.markFailed => task.currentOwner,
};
final nextReadiness = switch (action) {
  TaskCenterRecoverAction.nudgeWorker ||
  TaskCenterRecoverAction.reassignWorker => TaskCenterReadiness.ready,
  TaskCenterRecoverAction.returnToFast => TaskCenterReadiness.needsInfo,
  TaskCenterRecoverAction.sendToThinking => TaskCenterReadiness.needsThinking,
  TaskCenterRecoverAction.askHuman => TaskCenterReadiness.waitingHuman,
  TaskCenterRecoverAction.markFailed => TaskCenterReadiness.blocked,
};
final nextStatus = action == TaskCenterRecoverAction.markFailed
    ? TaskCenterStatus.review
    : task.status;
```

Use these exact stale thresholds:

```dart
const Duration _claimedStaleAfter = Duration(minutes: 2);
const Duration _runningStaleAfter = Duration(minutes: 10);
const Duration _permissionStaleAfter = Duration(minutes: 5);

bool _isRunStalled(TaskCenterWorkRun run, DateTime now) {
  return switch (run.state) {
    TaskCenterWorkRunState.claimed =>
      now.difference(run.lastHeartbeatAt) >= _claimedStaleAfter,
    TaskCenterWorkRunState.running =>
      now.difference(run.lastHeartbeatAt) >= _runningStaleAfter,
    TaskCenterWorkRunState.waitingPermission =>
      now.difference(run.lastHeartbeatAt) >= _permissionStaleAfter,
    TaskCenterWorkRunState.blocked ||
    TaskCenterWorkRunState.failed ||
    TaskCenterWorkRunState.released ||
    TaskCenterWorkRunState.stale => true,
    _ => false,
  };
}
```

Update `claimWorkTask` to delegate to `startWorkRun`:

```dart
return startWorkRun(
  workspaceId: workspaceId,
  taskId: taskId,
  agentName: cleanAgentName,
  actor: actor,
);
```

Update `recordExecutionResult` so the active run for `actor` becomes `delivered` when present:

```dart
final runs = _completeActiveRun(
  task.workRuns,
  actor: actor,
  now: event.createdAt,
);
```

- [ ] **Step 4: Run store tests**

Run:

```bash
dart format lib/task_center/task_center_store.dart lib/task_center/task_center_models.dart test/task_center/task_center_store_test.dart
flutter test test/task_center/task_center_store_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/task_center/task_center_models.dart lib/task_center/task_center_store.dart test/task_center/task_center_store_test.dart
git commit -m "feat: track worker run lifecycle"
```

## Task 3: Agent API And MCP Tool Schemas

**Files:**
- Modify: `lib/task_center/task_center_agent_api.dart`
- Modify: `lib/task_center/task_center_mcp_host.dart`
- Test: `test/task_center/task_center_agent_api_test.dart`
- Test: `test/task_center/task_center_mcp_host_test.dart`

- [ ] **Step 1: Write failing API tests**

Add to `test/task_center/task_center_agent_api_test.dart`:

```dart
test('agent API starts heartbeats and recovers stalled work', () async {
  final temp = await Directory.systemTemp.createTemp('ianvs_task_center_api');
  addTearDown(() => temp.delete(recursive: true));
  final ids = _IdSequence();
  final api = TaskCenterAgentApi(
    store: TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 17, 18),
      idGenerator: ids.next,
    ),
  );

  final workspaceResult = await api.call('task_center_create_workspace', {
    'title': 'Recovery API',
    'fast_agent_name': 'codex-fast',
    'thinking_agent_name': 'codex-thinking',
    'work_agent_names': ['codex-worker', 'codex-worker-2'],
  });
  final workspaceId =
      (workspaceResult['workspace'] as Map<String, Object?>)['id'] as String;

  final taskResult = await api.call('task_center_create_task', {
    'workspace_id': workspaceId,
    'title': 'Recover me',
  });
  final taskId = (taskResult['task'] as Map<String, Object?>)['id'] as String;

  final started = await api.call('task_center_start_work_run', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'agent_name': 'codex-worker',
    'session_id': 'session-1',
    'progress_summary': 'Starting.',
  });
  final run = (((started['task'] as Map<String, Object?>)['work_runs']
      as List<Object?>).single as Map<String, Object?>);
  expect(run['state'], 'running');

  final heartbeat = await api.call('task_center_heartbeat_work_run', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'run_id': run['id'],
    'state': 'running',
    'progress_summary': 'Still working.',
  });
  expect(
    ((((heartbeat['task'] as Map<String, Object?>)['work_runs']
        as List<Object?>).single as Map<String, Object?>)['progress_summary']),
    'Still working.',
  );

  final blocker = await api.call('task_center_report_work_blocker', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'run_id': run['id'],
    'blocker_type': 'missing_acceptance',
    'blocker_reason': 'Acceptance is not clear.',
  });
  expect((blocker['task'] as Map<String, Object?>)['readiness'], 'needs_info');

  final recovered = await api.call('task_center_recover_stalled_task', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'action': 'reassign_worker',
    'agent_name': 'codex-worker-2',
    'reason': 'Original worker blocked.',
  });
  expect(
    ((recovered['task'] as Map<String, Object?>)['current_owner']
        as Map<String, Object?>)['agent_name'],
    'codex-worker-2',
  );
});

test('agent API exposes worker recovery tools in catalog', () {
  final api = TaskCenterAgentApi(store: TaskCenterStore(path: 'unused.json'));

  expect(api.toolNames, contains('task_center_start_work_run'));
  expect(api.toolNames, contains('task_center_heartbeat_work_run'));
  expect(api.toolNames, contains('task_center_report_work_blocker'));
  expect(api.toolNames, contains('task_center_release_work_task'));
  expect(api.toolNames, contains('task_center_recover_stalled_task'));
  expect(api.toolNames, contains('task_center_list_stalled_work'));
});
```

Add to `test/task_center/task_center_mcp_host_test.dart`:

```dart
expect(
  tools.tools.map((tool) => tool.name),
  contains('task_center_start_work_run'),
);
expect(
  tools.tools.map((tool) => tool.name),
  contains('task_center_recover_stalled_task'),
);
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
flutter test test/task_center/task_center_agent_api_test.dart --plain-name "agent API starts heartbeats and recovers stalled work"
flutter test test/task_center/task_center_agent_api_test.dart --plain-name "agent API exposes worker recovery tools in catalog"
flutter test test/task_center/task_center_mcp_host_test.dart
```

Expected: FAIL with unknown tool names or missing MCP tool names.

- [ ] **Step 3: Implement API methods and schemas**

Add tool names to `_toolNames` in `TaskCenterAgentApi`:

```dart
'task_center_start_work_run',
'task_center_heartbeat_work_run',
'task_center_report_work_blocker',
'task_center_release_work_task',
'task_center_recover_stalled_task',
'task_center_list_stalled_work',
```

Add switch cases:

```dart
'task_center_start_work_run' => _startWorkRun(arguments),
'task_center_heartbeat_work_run' => _heartbeatWorkRun(arguments),
'task_center_report_work_blocker' => _reportWorkBlocker(arguments),
'task_center_release_work_task' => _releaseWorkTask(arguments),
'task_center_recover_stalled_task' => _recoverStalledTask(arguments),
'task_center_list_stalled_work' => _listStalledWork(arguments),
```

Implement private methods using store wrappers and returning agent JSON:

```dart
Future<Map<String, Object?>> _startWorkRun(Map<String, Object?> arguments) async {
  final task = await store.startWorkRun(
    workspaceId: _requiredString(arguments, 'workspace_id'),
    taskId: _requiredString(arguments, 'task_id'),
    agentName: _requiredString(arguments, 'agent_name'),
    sessionId: _optionalString(arguments, 'session_id') ?? '',
    progressSummary: _optionalString(arguments, 'progress_summary') ?? '',
    actor: _optionalString(arguments, 'actor') ?? 'agent',
  );
  await _notifyChanged();
  return <String, Object?>{'task': task.toAgentJson()};
}
```

Use equivalent complete methods for heartbeat, blocker, release, recover, and list stalled work.

Add parsers:

```dart
TaskCenterWorkRunState _requiredWorkRunState(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterWorkRunState.fromId(_requiredString(arguments, key));
}

TaskCenterWorkBlockerType _requiredBlockerType(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterWorkBlockerType.fromId(_requiredString(arguments, key));
}

TaskCenterRecoverAction _requiredRecoverAction(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterRecoverAction.fromId(_requiredString(arguments, key));
}
```

Add MCP descriptions and schemas in `TaskCenterMcpHost` with `additionalProperties: false`. Include required fields exactly as in the API tests.

- [ ] **Step 4: Run API and MCP tests**

Run:

```bash
dart format lib/task_center/task_center_agent_api.dart lib/task_center/task_center_mcp_host.dart test/task_center/task_center_agent_api_test.dart test/task_center/task_center_mcp_host_test.dart
flutter test test/task_center/task_center_agent_api_test.dart test/task_center/task_center_mcp_host_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/task_center/task_center_agent_api.dart lib/task_center/task_center_mcp_host.dart test/task_center/task_center_agent_api_test.dart test/task_center/task_center_mcp_host_test.dart
git commit -m "feat: expose worker recovery task center tools"
```

## Task 4: Controller Wrappers And Agent Prompt Rules

**Files:**
- Modify: `lib/task_center/task_center_controller.dart`
- Modify: `lib/app.dart`
- Test: `test/task_center/task_center_controller_test.dart`
- Test: `test/ui/acp_client_app_test.dart`

- [ ] **Step 1: Write failing controller and prompt tests**

Add to `test/task_center/task_center_controller_test.dart`:

```dart
test('controller exposes worker run recovery actions', () async {
  final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
  addTearDown(() => temp.delete(recursive: true));
  final store = TaskCenterStore(
    path: '${temp.path}/task_center.json',
    now: () => DateTime.utc(2026, 6, 17, 19),
    idGenerator: _IdSequence().next,
  );
  final controller = TaskCenterController(store: store);
  final workspace = await controller.createWorkspace(title: 'Controller run');
  final task = await controller.createTask(
    workspaceId: workspace.id,
    title: 'Start run',
  );

  final started = await controller.startWorkRun(
    workspaceId: workspace.id,
    taskId: task.id,
    agentName: 'codex-worker',
  );
  expect(started.workRuns.single.state, TaskCenterWorkRunState.running);

  final stalled = await controller.listStalledWork(workspaceId: workspace.id);
  expect(stalled, isEmpty);
});
```

Add to `test/ui/acp_client_app_test.dart` in the existing prompt source test:

```dart
expect(source, contains('task_center_list_stalled_work'));
expect(source, contains('task_center_start_work_run'));
expect(source, contains('task_center_heartbeat_work_run'));
expect(source, contains('task_center_report_work_blocker'));
expect(source, contains('不能沉默卡在任务里'));
```

- [ ] **Step 2: Run tests to verify they fail**

Run:

```bash
flutter test test/task_center/task_center_controller_test.dart --plain-name "controller exposes worker run recovery actions"
flutter test test/ui/acp_client_app_test.dart --plain-name "AcpClientApp fast agent prompt names task center workflow tools"
```

Expected: FAIL with missing controller methods or missing prompt text.

- [ ] **Step 3: Add controller wrappers and prompt rules**

Add wrappers to `TaskCenterController`:

```dart
Future<TaskCenterTask> startWorkRun({
  required String workspaceId,
  required String taskId,
  required String agentName,
  String sessionId = '',
  String progressSummary = '',
  String actor = 'human',
}) async {
  final task = await store.startWorkRun(
    workspaceId: workspaceId,
    taskId: taskId,
    agentName: agentName,
    sessionId: sessionId,
    progressSummary: progressSummary,
    actor: actor,
  );
  await _refresh();
  return task;
}
```

Add equivalent wrappers for `heartbeatWorkRun`, `reportWorkBlocker`, `releaseWorkTask`, `recoverStalledTask`, and `listStalledWork`.

Update `_fastAgentWorkspacePrompt` in `lib/app.dart` so the numbered requirements include:

```dart
'9. 每次分派 worker 前，先调用 task_center_list_stalled_work；如果有卡住任务，优先调用 task_center_recover_stalled_task 恢复。',
'10. 分派 worker 时必须创建 work run：调用 task_center_start_work_run；worker 执行中必须用 task_center_heartbeat_work_run 上报进度。',
'11. worker 目标不清、验收不清、权限等待或工具失败时，必须调用 task_center_report_work_blocker，不能沉默卡在任务里。',
```

- [ ] **Step 4: Run controller and prompt tests**

Run:

```bash
dart format lib/task_center/task_center_controller.dart lib/app.dart test/task_center/task_center_controller_test.dart test/ui/acp_client_app_test.dart
flutter test test/task_center/task_center_controller_test.dart test/ui/acp_client_app_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/task_center/task_center_controller.dart lib/app.dart test/task_center/task_center_controller_test.dart test/ui/acp_client_app_test.dart
git commit -m "feat: route worker recovery through controller"
```

## Task 5: Workspace Chat Stalled Recovery Card

**Files:**
- Modify: `lib/ui/components/task_center_board.dart`
- Test: `test/ui/task_center_board_test.dart`

- [ ] **Step 1: Write failing UI source test**

Add to `test/ui/task_center_board_test.dart`:

```dart
test('TaskCenterBoard surfaces stalled worker recovery in workspace chat', () async {
  final source = await File(
    'lib/ui/components/task_center_board.dart',
  ).readAsString();

  expect(source, contains('_WorkerStalledRecoveries'));
  expect(source, contains('_WorkerStalledCard'));
  expect(source, contains('listStalledWork('));
  expect(source, contains('recoverStalledTask('));
  expect(source, contains('Worker stalled'));
  expect(source, contains('催一下 worker'));
  expect(source, contains('换一个 worker'));
  expect(source, contains('交回 fast agent'));
  expect(source, contains('转 thinking agent'));
  expect(source, contains('标记失败'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
flutter test test/ui/task_center_board_test.dart --plain-name "TaskCenterBoard surfaces stalled worker recovery in workspace chat"
```

Expected: FAIL because recovery widgets do not exist.

- [ ] **Step 3: Implement recovery widgets**

In `_WorkspaceChatPanelState.build`, place the widget directly below `_WaitingHumanConfirmations`:

```dart
_WorkerStalledRecoveries(
  controller: widget.controller,
  workspace: widget.workspace,
),
```

Add these widgets below `_WaitingHumanConfirmations`:

```dart
class _WorkerStalledRecoveries extends StatefulWidget {
  const _WorkerStalledRecoveries({
    required this.controller,
    required this.workspace,
  });

  final TaskCenterController controller;
  final TaskWorkspace workspace;

  @override
  State<_WorkerStalledRecoveries> createState() =>
      _WorkerStalledRecoveriesState();
}

class _WorkerStalledRecoveriesState extends State<_WorkerStalledRecoveries> {
  List<TaskCenterTask> _stalled = const <TaskCenterTask>[];
  String? _submittingTaskId;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant _WorkerStalledRecoveries oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspace.id != widget.workspace.id ||
        oldWidget.workspace.updatedAt != widget.workspace.updatedAt) {
      unawaited(_load());
    }
  }

  Future<void> _load() async {
    final stalled = await widget.controller.listStalledWork(
      workspaceId: widget.workspace.id,
    );
    if (!mounted) return;
    setState(() => _stalled = stalled);
  }

  @override
  Widget build(BuildContext context) {
    if (_stalled.isEmpty) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: const BoxDecoration(color: Color(0xfffff1f2)),
      child: SizedBox(
        height: 168,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          itemCount: _stalled.length,
          separatorBuilder: (context, index) => const SizedBox(width: 10),
          itemBuilder: (context, index) {
            final task = _stalled[index];
            return _WorkerStalledCard(
              task: task,
              workspace: widget.workspace,
              submitting: _submittingTaskId == task.id,
              onRecover: (action, agentName) => unawaited(
                _recover(task, action, agentName),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _recover(
    TaskCenterTask task,
    TaskCenterRecoverAction action,
    String agentName,
  ) async {
    setState(() => _submittingTaskId = task.id);
    try {
      await widget.controller.recoverStalledTask(
        workspaceId: widget.workspace.id,
        taskId: task.id,
        action: action,
        agentName: agentName,
        reason: 'Recovered from workspace chat.',
        actor: 'human',
      );
      await _load();
    } finally {
      if (mounted) setState(() => _submittingTaskId = null);
    }
  }
}
```

Implement `_WorkerStalledCard` with the exact labels from the failing test and map actions:

```dart
OutlinedButton(
  onPressed: submitting
      ? null
      : () => onRecover(TaskCenterRecoverAction.nudgeWorker, task.currentOwner.agentName),
  child: const Text('催一下 worker'),
)
```

Use `workspace.agentConfig.workAgentNames` to choose the reassignment target:

```dart
String _nextWorkerName(TaskWorkspace workspace, TaskCenterTask task) {
  for (final agentName in workspace.agentConfig.workAgentNames) {
    if (agentName != task.currentOwner.agentName) return agentName;
  }
  return workspace.agentConfig.workAgentNames.isEmpty
      ? task.currentOwner.agentName
      : workspace.agentConfig.workAgentNames.first;
}
```

- [ ] **Step 4: Run UI test**

Run:

```bash
dart format lib/ui/components/task_center_board.dart test/ui/task_center_board_test.dart
flutter test test/ui/task_center_board_test.dart --plain-name "TaskCenterBoard surfaces stalled worker recovery in workspace chat"
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/components/task_center_board.dart test/ui/task_center_board_test.dart
git commit -m "feat: show stalled worker recovery in chat"
```

## Task 6: Execution Summary In Kanban Details And Agents Tab

**Files:**
- Modify: `lib/ui/components/task_center_board.dart`
- Test: `test/ui/task_center_board_test.dart`

- [ ] **Step 1: Write failing UI source test**

Add:

```dart
test('TaskCenterBoard shows work run execution context', () async {
  final source = await File(
    'lib/ui/components/task_center_board.dart',
  ).readAsString();

  expect(source, contains('_TaskExecutionPanel'));
  expect(source, contains('Execution'));
  expect(source, contains('lastHeartbeatAt'));
  expect(source, contains('progressSummary'));
  expect(source, contains('workRuns'));
  expect(source, contains('_AgentSessionRunPill'));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
flutter test test/ui/task_center_board_test.dart --plain-name "TaskCenterBoard shows work run execution context"
```

Expected: FAIL because execution panel and run pill do not exist.

- [ ] **Step 3: Implement execution display**

Add helper:

```dart
TaskCenterWorkRun? _activeOrLatestRun(TaskCenterTask task) {
  if (task.workRuns.isEmpty) return null;
  for (final run in task.workRuns.reversed) {
    if (run.isActive) return run;
  }
  return task.workRuns.last;
}
```

In `_TaskCard`, add a compact run line after owner/readiness pills:

```dart
final run = _activeOrLatestRun(task);
if (run != null)
  _TinyPill(
    label: '${run.agentName} · ${run.state.label}',
    color: run.state == TaskCenterWorkRunState.stale
        ? AppColors.danger
        : AppColors.primaryDark,
    background: run.state == TaskCenterWorkRunState.stale
        ? const Color(0xfffff1f2)
        : AppColors.primaryMist,
  ),
```

In `_TaskProtocolPanel`, insert:

```dart
_TaskExecutionPanel(task: task),
```

Implement:

```dart
class _TaskExecutionPanel extends StatelessWidget {
  const _TaskExecutionPanel({required this.task});

  final TaskCenterTask task;

  @override
  Widget build(BuildContext context) {
    final run = _activeOrLatestRun(task);
    if (run == null) {
      return const _PanelSection(
        title: 'Execution',
        children: [
          Text(
            'No worker run yet.',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
        ],
      );
    }
    return _PanelSection(
      title: 'Execution',
      children: [
        _InfoRow(label: 'Worker', value: run.agentName),
        _InfoRow(label: 'State', value: run.state.label),
        _InfoRow(label: 'Last heartbeat', value: _formatRunTime(run.lastHeartbeatAt)),
        if (run.progressSummary.isNotEmpty)
          _InfoRow(label: 'Progress', value: run.progressSummary),
        if (run.blockerReason.isNotEmpty)
          _InfoRow(label: 'Blocker', value: run.blockerReason),
      ],
    );
  }
}
```

Add `_AgentSessionRunPill` to `_AgentSessionTile` when a session id matches a task work run. Pass workspace tasks into `_AgentSessionGroupView` and `_AgentSessionTile`, then calculate:

```dart
List<TaskCenterWorkRun> _runsForSession(
  List<TaskCenterTask> tasks,
  AgentSession session,
) {
  return [
    for (final task in tasks)
      for (final run in task.workRuns)
        if (run.sessionId == session.id) run,
  ];
}
```

- [ ] **Step 4: Run UI tests**

Run:

```bash
dart format lib/ui/components/task_center_board.dart test/ui/task_center_board_test.dart
flutter test test/ui/task_center_board_test.dart
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ui/components/task_center_board.dart test/ui/task_center_board_test.dart
git commit -m "feat: display worker execution context"
```

## Task 7: End-To-End Coverage And Verification

**Files:**
- Modify: `test/task_center/task_center_workflow_simulation_test.dart`
- Modify: `test/ui/task_center_board_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`

- [ ] **Step 1: Add workflow simulation test**

Add a workflow test:

```dart
test('worker run can stall and be reassigned through recovery', () async {
  final harness = await _TaskCenterWorkflowHarness.create();
  final workspaceId = await harness.createWorkspace();
  final taskId = await harness.createTask(
    workspaceId: workspaceId,
    title: 'Recover stalled worker',
  );

  final started = await harness.api.call('task_center_start_work_run', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'agent_name': 'codex-worker',
    'progress_summary': 'Starting.',
  });
  final run = (((started['task'] as Map<String, Object?>)['work_runs']
      as List<Object?>).single as Map<String, Object?>);

  await harness.api.call('task_center_report_work_blocker', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'run_id': run['id'],
    'blocker_type': 'tool_error',
    'blocker_reason': 'Tool failed repeatedly.',
  });

  final recovered = await harness.api.call('task_center_recover_stalled_task', {
    'workspace_id': workspaceId,
    'task_id': taskId,
    'action': 'reassign_worker',
    'agent_name': 'codex-worker-2',
    'reason': 'Retry with another worker.',
  });

  final owner = (recovered['task'] as Map<String, Object?>)['current_owner']
      as Map<String, Object?>;
  expect(owner['agent_name'], 'codex-worker-2');
});
```

- [ ] **Step 2: Run workflow test to verify it passes**

Run:

```bash
flutter test test/task_center/task_center_workflow_simulation_test.dart --plain-name "worker run can stall and be reassigned through recovery"
```

Expected: PASS.

- [ ] **Step 3: Run full verification**

Run:

```bash
flutter test
flutter analyze
git diff --check
flutter build macos --debug
```

Expected:

- `flutter test`: all tests pass.
- `flutter analyze`: `No issues found`.
- `git diff --check`: no output.
- `flutter build macos --debug`: builds `ACP Client.app`.

- [ ] **Step 4: Manual demo checklist**

Run the debug app:

```bash
open -n "build/macos/Build/Products/Debug/ACP Client.app"
```

Manual checks:

- Create or use a workspace with fast, thinking, and at least two worker agents.
- Create a task and assign it to worker.
- Confirm task detail shows `Execution`.
- Simulate blocker through MCP/API or worker prompt.
- Confirm Workspace Chat shows `Worker stalled`.
- Click `换一个 worker`.
- Confirm the task owner changes to the second worker.
- Confirm Agents tab still shows the relevant worker session transcript.

- [ ] **Step 5: Commit**

```bash
git add test/task_center/task_center_workflow_simulation_test.dart test/ui/task_center_board_test.dart test/ui/acp_client_app_test.dart
git commit -m "test: cover worker stall recovery workflow"
```

## Self-Review Checklist

- Spec coverage:
  - Work run data model: Task 1.
  - Store lifecycle and stale detection: Task 2.
  - Agent API and MCP exposure: Task 3.
  - Agent prompt rules: Task 4.
  - Workspace Chat recovery card: Task 5.
  - Kanban details and Agents tab context: Task 6.
  - End-to-end verification: Task 7.
- Red flag scan:
  - Clean.
- Type consistency:
  - The plan consistently uses `TaskCenterWorkRun`, `TaskCenterWorkRunState`, `TaskCenterWorkBlockerType`, `TaskCenterRecoverAction`, `workRuns`, and `work_runs`.
