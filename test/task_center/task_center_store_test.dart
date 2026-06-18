import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('creates workspaces and tasks then reloads them from disk', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/task_center.json');
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: file.path,
      now: () => DateTime.utc(2026, 6, 16, 9, 30),
      idGenerator: ids.next,
    );

    final workspace = await store.createWorkspace(
      title: 'Local launch',
      description: 'Coordinate the local task center build.',
    );
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Wire the kanban board',
      description: 'Use boardview for status columns.',
      status: TaskCenterStatus.todo,
    );

    expect(await file.exists(), isTrue);
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(decoded['version'], 1);
    expect(workspace.id, 'id-1');
    expect(task.id, 'id-2');

    final reloaded = TaskCenterStore(path: file.path);
    final snapshot = await reloaded.load();

    expect(snapshot.workspaces, hasLength(1));
    expect(snapshot.workspaces.single.title, 'Local launch');
    expect(
      snapshot.workspaces.single.tasks.single.title,
      'Wire the kanban board',
    );
    expect(
      snapshot.workspaces.single.tasks.single.status,
      TaskCenterStatus.todo,
    );
  });

  test('persists workspace working directory for agent sessions', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final store = TaskCenterStore(path: '${temp.path}/task_center.json');

    final workspace = await store.createWorkspace(
      title: 'Agent workspace',
      workspaceCwd: '/workspace/bk-sec-ai',
    );

    expect(workspace.workspaceCwd, '/workspace/bk-sec-ai');

    final reloaded = await TaskCenterStore(path: store.path).load();
    expect(reloaded.workspaces.single.workspaceCwd, '/workspace/bk-sec-ai');
    expect(
      reloaded.workspaces.single.toAgentJson()['workspace_cwd'],
      '/workspace/bk-sec-ai',
    );
  });

  test(
    'moves tasks between status columns and keeps explicit ordering',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final ids = _IdSequence();
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 16, 10),
        idGenerator: ids.next,
      );

      final workspace = await store.createWorkspace(title: 'Agent workspace');
      final first = await store.createTask(
        workspaceId: workspace.id,
        title: 'Create workspace API',
        status: TaskCenterStatus.todo,
      );
      final second = await store.createTask(
        workspaceId: workspace.id,
        title: 'Persist status changes',
        status: TaskCenterStatus.inProgress,
      );

      final moved = await store.moveTask(
        workspaceId: workspace.id,
        taskId: first.id,
        status: TaskCenterStatus.inProgress,
        index: 0,
      );

      expect(moved.status, TaskCenterStatus.inProgress);
      final snapshot = await store.load();
      final inProgress = snapshot.workspaces.single.tasks
          .where((task) => task.status == TaskCenterStatus.inProgress)
          .toList();

      expect(inProgress.map((task) => task.id), [first.id, second.id]);
      expect(inProgress.map((task) => task.sortOrder), [0, 1]);
    },
  );

  test('resolves default local persistence path from XDG_DATA_HOME', () {
    final path = TaskCenterStore.resolveDefaultPath(
      environment: {'XDG_DATA_HOME': '/Users/example/.local/state'},
    );

    expect(path, '/Users/example/.local/state/ianvs-acp/task_center.json');
  });

  test(
    'repairs trailing data after a complete task center JSON root',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/task_center.json');
      final valid = jsonEncode({
        'version': 1,
        'workspaces': [
          {
            'id': 'workspace-1',
            'title': 'Recovered workspace',
            'created_at': '2026-06-17T12:00:00.000Z',
            'updated_at': '2026-06-17T12:00:00.000Z',
          },
        ],
      });
      await file.writeAsString('$valid\nold trailing bytes from a prior write');

      final snapshot = await TaskCenterStore(path: file.path).load();

      expect(snapshot.workspaces.single.title, 'Recovered workspace');
      final repaired =
          jsonDecode(await file.readAsString()) as Map<String, Object?>;
      expect(repaired['workspaces'], isA<List<Object?>>());
    },
  );

  test('serializes overlapping writes into a valid JSON file', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/task_center.json');
    final store = TaskCenterStore(
      path: file.path,
      now: () => DateTime.utc(2026, 6, 17, 12),
      idGenerator: _IdSequence().next,
    );

    await Future.wait([
      store.createWorkspace(title: 'Workspace A'),
      store.createWorkspace(title: 'Workspace B'),
      store.createWorkspace(title: 'Workspace C'),
    ]);

    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, Object?>;
    expect(decoded['version'], 1);
    final reloaded = await store.load();
    expect(reloaded.workspaces, isNotEmpty);
  });

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

    final raw =
        jsonDecode(await File(store.path).readAsString())
            as Map<String, Object?>;
    final tasks =
        ((raw['workspaces'] as List<Object?>).single
                as Map<String, Object?>)['tasks']
            as List<Object?>;
    final jsonTask = tasks.single as Map<String, Object?>;
    jsonTask.remove('work_runs');
    await File(store.path).writeAsString(jsonEncode(raw));

    final oldSnapshot = await TaskCenterStore(path: store.path).load();
    expect(oldSnapshot.workspaces.single.tasks.single.workRuns, isEmpty);
  });

  test('does not surface delivered work as stalled recovery', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    var now = DateTime.utc(2026, 6, 17, 16);
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => now,
      idGenerator: ids.next,
    );

    final workspace = await store.createWorkspace(title: 'Delivered worker');
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Return TAPD table',
      status: TaskCenterStatus.inProgress,
    );
    await store.startWorkRun(
      workspaceId: workspace.id,
      taskId: task.id,
      agentName: 'codex-worker',
      actor: 'human',
    );
    await store.recordExecutionResult(
      workspaceId: workspace.id,
      taskId: task.id,
      executionResult: 'Delivered table.',
      actor: 'codex-worker',
    );

    now = DateTime.utc(2026, 6, 17, 16, 30);
    final stalled = await store.listStalledWork(workspaceId: workspace.id);

    expect(stalled, isEmpty);
  });

  test(
    'does not surface delivered work with older stale runs as stalled recovery',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final ids = _IdSequence();
      var now = DateTime.utc(2026, 6, 17, 16);
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => now,
        idGenerator: ids.next,
      );

      final workspace = await store.createWorkspace(title: 'Delivered worker');
      final task = await store.createTask(
        workspaceId: workspace.id,
        title: 'Return TAPD table',
        status: TaskCenterStatus.inProgress,
      );
      await store.startWorkRun(
        workspaceId: workspace.id,
        taskId: task.id,
        agentName: 'codex-worker',
        actor: 'human',
      );
      now = DateTime.utc(2026, 6, 17, 16, 20);
      final firstStalled = await store.listStalledWork(
        workspaceId: workspace.id,
      );
      expect(firstStalled, hasLength(1));

      await store.startWorkRun(
        workspaceId: workspace.id,
        taskId: task.id,
        agentName: 'codex-worker-2',
        actor: 'human',
      );
      await store.recordExecutionResult(
        workspaceId: workspace.id,
        taskId: task.id,
        executionResult: 'Delivered table.',
        actor: 'codex-worker-2',
      );

      now = DateTime.utc(2026, 6, 17, 16, 45);
      final stalled = await store.listStalledWork(workspaceId: workspace.id);

      expect(stalled, isEmpty);
    },
  );

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

    expect(
      () => store.heartbeatWorkRun(
        workspaceId: workspace.id,
        taskId: task.id,
        runId: runId,
        state: TaskCenterWorkRunState.running,
        progressSummary: 'Stale heartbeat after delivery.',
      ),
      throwsFormatException,
    );

    final reloaded = await TaskCenterStore(path: store.path).load();
    expect(
      reloaded.workspaces.single.tasks.single.workRuns.single.state,
      TaskCenterWorkRunState.delivered,
    );
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
    expect(
      stalled.firstWhere((task) => task.id == staleTask.id).readiness,
      TaskCenterReadiness.blocked,
    );
  });

  test('nudge recovery creates an active run for missing worker run', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    var now = DateTime.utc(2026, 6, 17, 18);
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => now,
      idGenerator: ids.next,
    );

    final workspace = await store.createWorkspace(
      title: 'Missing run recovery',
      agentConfig: const TaskWorkspaceAgentConfig(
        workAgentNames: <String>['codex-worker'],
      ),
    );
    final task = await store.createTask(
      workspaceId: workspace.id,
      title: 'Continue worker',
      status: TaskCenterStatus.inProgress,
      currentOwner: const TaskCenterTaskOwner.workAgent('codex-worker'),
      readiness: TaskCenterReadiness.ready,
    );

    now = DateTime.utc(2026, 6, 17, 18, 12);
    final stalled = await store.listStalledWork(workspaceId: workspace.id);
    expect(stalled.single.id, task.id);
    expect(stalled.single.readiness, TaskCenterReadiness.blocked);

    now = DateTime.utc(2026, 6, 17, 18, 13);
    final nudged = await store.recoverStalledTask(
      workspaceId: workspace.id,
      taskId: task.id,
      action: TaskCenterRecoverAction.nudgeWorker,
      reason: 'Please continue.',
      actor: 'human',
    );

    expect(nudged.readiness, TaskCenterReadiness.ready);
    expect(nudged.currentOwner.agentName, 'codex-worker');
    expect(nudged.workRuns.single.agentName, 'codex-worker');
    expect(nudged.workRuns.single.state, TaskCenterWorkRunState.running);

    final afterRecovery = await store.listStalledWork(
      workspaceId: workspace.id,
    );
    expect(afterRecovery, isEmpty);
  });

  test(
    'persists workspace role agents, task protocol fields, and events',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final ids = _IdSequence();
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 9),
        idGenerator: ids.next,
      );

      final workspace = await store.createWorkspace(
        title: 'Agent protocol workspace',
        agentConfig: const TaskWorkspaceAgentConfig(
          fastAgentName: 'quick-agent',
          thinkingAgentName: 'thinking-agent',
          workAgentNames: <String>['work-agent-1', 'work-agent-2'],
          fastAgentPrompt: 'Collect context and triage quickly.',
          thinkingAgentPrompt: 'Reason deeply and produce human questions.',
          workAgentPrompt: 'Validate goals and acceptance before execution.',
        ),
      );

      final task = await store.createTask(
        workspaceId: workspace.id,
        title: 'Implement task protocol',
        description: 'Track the product protocol separately from board status.',
        details: 'Keep status and owner separate.',
        objective: 'Ship a local human-agent workflow.',
        acceptanceCriteria: const <String>[
          'Workspace roles are persisted',
          'Agents can request human confirmation',
        ],
        currentOwner: const TaskCenterTaskOwner.fastAgent('quick-agent'),
        readiness: TaskCenterReadiness.needsInfo,
        routeReason: 'New task needs triage.',
      );

      final transferred = await store.transferTaskOwner(
        workspaceId: workspace.id,
        taskId: task.id,
        owner: const TaskCenterTaskOwner.thinkingAgent('thinking-agent'),
        readiness: TaskCenterReadiness.needsThinking,
        routeReason: 'Requires deeper analysis.',
        actor: 'quick-agent',
      );

      final waiting = await store.requestHumanConfirmation(
        workspaceId: workspace.id,
        taskId: transferred.id,
        questions: const <String>['Which acceptance checks are mandatory?'],
        routeReason: 'Acceptance is not clear enough.',
        actor: 'thinking-agent',
      );

      final recorded = await store.recordExecutionResult(
        workspaceId: workspace.id,
        taskId: waiting.id,
        executionResult: 'Implemented model, API, and UI updates.',
        verificationNotes: 'Store and API tests cover the workflow.',
        actor: 'work-agent-1',
      );

      expect(recorded.currentOwner.kind, TaskCenterOwnerKind.human);
      expect(recorded.readiness, TaskCenterReadiness.waitingHuman);
      expect(recorded.humanQuestions.single.resolved, isFalse);
      expect(
        recorded.events.map((event) => event.type),
        containsAll([
          'owner_transferred',
          'human_confirmation_requested',
          'execution_result_recorded',
        ]),
      );

      final reloaded = await TaskCenterStore(path: store.path).load();
      final reloadedWorkspace = reloaded.workspaces.single;
      final reloadedTask = reloadedWorkspace.tasks.single;

      expect(reloadedWorkspace.agentConfig.fastAgentName, 'quick-agent');
      expect(reloadedWorkspace.agentConfig.workAgentNames, <String>[
        'work-agent-1',
        'work-agent-2',
      ]);
      expect(reloadedTask.objective, 'Ship a local human-agent workflow.');
      expect(reloadedTask.acceptanceCriteria, hasLength(2));
      expect(reloadedTask.currentOwner.kind, TaskCenterOwnerKind.human);
      expect(reloadedTask.routeReason, 'Acceptance is not clear enough.');
      expect(reloadedTask.executionResult, contains('Implemented model'));
      expect(reloadedTask.verificationNotes, contains('tests cover'));
      expect(reloadedTask.events, hasLength(3));
    },
  );

  test(
    'requesting human confirmation reuses existing matching questions',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
      addTearDown(() => temp.delete(recursive: true));
      final ids = _IdSequence();
      final store = TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 10),
        idGenerator: ids.next,
      );

      final workspace = await store.createWorkspace(title: 'Human loop');
      final task = await store.createTask(
        workspaceId: workspace.id,
        title: 'Confirm scope',
        humanQuestions: const <TaskCenterHumanQuestion>[
          TaskCenterHumanQuestion(
            id: 'manual-question',
            question: 'Can work start after these checks?',
          ),
        ],
      );

      final waiting = await store.requestHumanConfirmation(
        workspaceId: workspace.id,
        taskId: task.id,
        questions: const <String>['Can work start after these checks?'],
        actor: 'thinking-agent',
      );

      expect(waiting.humanQuestions, hasLength(1));
      expect(waiting.humanQuestions.single.id, 'manual-question');
      expect(waiting.events.single.metadata['questions'], [
        {
          'id': 'manual-question',
          'question': 'Can work start after these checks?',
        },
      ]);
    },
  );

  test('persists workspace chat messages for fast agent admission', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final ids = _IdSequence();
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 17, 11),
      idGenerator: ids.next,
    );

    final workspace = await store.createWorkspace(
      title: 'Fast inbox',
      agentConfig: const TaskWorkspaceAgentConfig(fastAgentName: 'quick-agent'),
    );

    final humanMessage = await store.postWorkspaceChatMessage(
      workspaceId: workspace.id,
      role: TaskWorkspaceChatRole.human,
      actor: 'human',
      content: '请判断这个需求是否进入任务中心。',
    );
    final fastReply = await store.postWorkspaceChatMessage(
      workspaceId: workspace.id,
      role: TaskWorkspaceChatRole.fastAgent,
      actor: 'quick-agent',
      agentName: 'quick-agent',
      content: '已准入，会创建任务并转交。',
      metadata: const <String, Object?>{'admission': 'accepted'},
    );

    expect(humanMessage.id, 'id-2');
    expect(fastReply.id, 'id-3');

    final reloaded = await TaskCenterStore(path: store.path).load();
    final messages = reloaded.workspaces.single.chatMessages;

    expect(messages, hasLength(2));
    expect(messages.first.role, TaskWorkspaceChatRole.human);
    expect(messages.first.content, '请判断这个需求是否进入任务中心。');
    expect(messages.last.role, TaskWorkspaceChatRole.fastAgent);
    expect(messages.last.actor, 'quick-agent');
    expect(messages.last.metadata['admission'], 'accepted');
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
