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
