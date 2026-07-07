import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';
import 'package:ianvs_acp/ui/components/task_inbox_sidebar.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void main() {
  Future<void> pumpSidebar(
    WidgetTester tester,
    TaskInboxController controller, {
    String? selectedTaskId,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 720,
            child: TaskInboxSidebar(
              controller: controller,
              selectedTaskId: selectedTaskId,
              defaultWorkspacePath: '/workspace/app',
              defaultAgentName: 'Codex',
              agentNames: const ['Codex', 'Kimi'],
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);
  }

  testWidgets('TaskInboxSidebar creates and displays a task', (tester) async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(tester, controller);

    expect(find.text('No tasks yet'), findsOneWidget);

    await tester.tap(find.byTooltip('New task'));
    await _pumpFrames(tester);
    expect(find.text('New Task'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Build inbox UI',
    );
    await tester.enterText(
      find.byKey(const Key('task-description-field')),
      'Create a local task from the inbox.',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await _pumpFrames(tester);

    expect(find.text('Build inbox UI'), findsWidgets);
    expect(find.text('app'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Normal'), findsOneWidget);
    expect(controller.tasks.single.status, TaskStatus.inbox);
    expect(store.savedSnapshots.single.tasks.single.title, 'Build inbox UI');
  });

  testWidgets('TaskInboxSidebar persists after controller reload', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 9),
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Persisted inbox task',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 9),
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    expect(find.text('Persisted inbox task'), findsOneWidget);
    expect(controller.tasks.single.workspacePath, '/workspace/app');
  });

  testWidgets('TaskInboxSidebar shows artifact previews for selected task', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 9),
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Review artifacts',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.needsHumanReview,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 9),
              currentRunId: 'run-1',
            ),
          ],
          artifacts: [
            ArtifactRecord(
              id: 'artifact-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.gitDiff,
              title: 'Git diff preview',
              createdAt: DateTime(2026, 7, 7, 9),
              contentPreview: 'diff --git a/note.txt b/note.txt\n+after',
            ),
            ArtifactRecord(
              id: 'artifact-2',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.outboxFile,
              title: '.ianvs/outbox/task-1/report.md',
              createdAt: DateTime(2026, 7, 7, 9),
              contentPreview: 'export candidate',
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    expect(find.text('Git diff preview'), findsNothing);

    await tester.tap(find.text('Review artifacts'));
    await _pumpFrames(tester);

    expect(find.text('Artifacts 2'), findsOneWidget);
    expect(find.text('Git diff preview'), findsOneWidget);
    expect(find.textContaining('+after'), findsOneWidget);
    expect(find.text('.ianvs/outbox/task-1/report.md'), findsOneWidget);
  });

  testWidgets('TaskInboxSidebar shows review actions for review tasks', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    await tester.tap(find.text('Review artifacts'));
    await _pumpFrames(tester);

    expect(find.text('Approve Export'), findsOneWidget);
    expect(find.text('Mark Done Locally'), findsOneWidget);
    expect(find.text('Request Changes'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('TaskInboxSidebar selects externally requested task', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(tester, controller, selectedTaskId: 'task-1');

    expect(find.text('Review artifacts'), findsWidgets);
    expect(find.byKey(const Key('task-approve-export-button')), findsOneWidget);
    expect(
      find.byKey(const Key('task-mark-done-locally-button')),
      findsOneWidget,
    );
  });

  testWidgets('TaskInboxSidebar marks review task done locally', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    await tester.tap(find.text('Review artifacts'));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('task-mark-done-locally-button')));
    await _pumpFrames(tester);

    expect(controller.tasks.single.status, TaskStatus.done);
    expect(controller.approvals, isEmpty);
  });

  testWidgets('TaskInboxSidebar approves export from review actions', (
    tester,
  ) async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_reviewSnapshot()),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    await tester.tap(find.text('Review artifacts'));
    await _pumpFrames(tester);
    await tester.tap(find.byKey(const Key('task-approve-export-button')));
    await _pumpFrames(tester);

    expect(controller.tasks.single.status, TaskStatus.approvedForExport);
    expect(controller.approvals.single.kind, ApprovalKind.export);
    expect(controller.approvals.single.status, ApprovalStatus.approved);
    expect(controller.approvals.single.artifactIds, ['artifact-1']);
  });

  testWidgets('TaskInboxSidebar exposes export action for approved tasks', (
    tester,
  ) async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_approvedExportSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();
    TaskRecord? exportedTask;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 720,
            child: TaskInboxSidebar(
              controller: controller,
              defaultWorkspacePath: '/workspace/app',
              defaultAgentName: 'Codex',
              onExportTask: (task) {
                exportedTask = task;
              },
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.byTooltip('Export task'));
    await _pumpFrames(tester);

    expect(exportedTask?.id, 'task-1');
  });

  testWidgets('TaskInboxSidebar exposes run and linked session actions', (
    tester,
  ) async {
    final task = TaskRecord(
      id: 'task-1',
      title: 'Runnable task',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.inbox,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 7, 8),
      updatedAt: DateTime(2026, 7, 7, 9),
      sessionId: 'session-1',
    );
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(updatedAt: DateTime(2026, 7, 7, 9), tasks: [task]),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    TaskRecord? ranTask;
    TaskRecord? openedTask;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 720,
            child: TaskInboxSidebar(
              controller: controller,
              defaultWorkspacePath: '/workspace/app',
              defaultAgentName: 'Codex',
              onRunTask: (task) {
                ranTask = task;
              },
              onOpenLinkedSession: (task) {
                openedTask = task;
              },
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.byTooltip('Run task'));
    await _pumpFrames(tester);
    await tester.tap(find.byTooltip('Open linked session'));
    await _pumpFrames(tester);

    expect(ranTask?.id, 'task-1');
    expect(openedTask?.sessionId, 'session-1');
  });

  testWidgets('AppShell switches between Workspaces and Inbox sidebars', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(chat.dispose);
    final taskController = TaskInboxController(store: _MemoryTaskStore());
    addTearDown(taskController.dispose);
    await taskController.load();

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: chat,
          taskInboxController: taskController,
          agentName: 'Codex',
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.byType(WorkspaceSidebar), findsOneWidget);
    expect(find.byType(TaskInboxSidebar), findsNothing);

    await tester.tap(find.text('Inbox').first);
    await _pumpFrames(tester);

    expect(find.byType(TaskInboxSidebar), findsOneWidget);
    expect(find.byTooltip('New task'), findsOneWidget);

    await tester.tap(find.text('Workspaces').first);
    await _pumpFrames(tester);

    expect(find.byType(WorkspaceSidebar), findsOneWidget);
    expect(find.byType(TaskInboxSidebar), findsNothing);
  });

  testWidgets('AcpClientApp wires injected task controller into Inbox UI', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final chat = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(chat.dispose);
    final taskController = TaskInboxController(
      store: _MemoryTaskStore(),
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(taskController.dispose);
    await taskController.load();

    await tester.pumpWidget(
      AcpClientApp(controller: chat, taskInboxController: taskController),
    );
    await _pumpFrames(tester);

    await tester.tap(find.text('Inbox').first);
    await _pumpFrames(tester);
    await tester.tap(find.byTooltip('New task'));
    await _pumpFrames(tester);
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'App-level inbox task',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await _pumpFrames(tester);

    expect(find.text('App-level inbox task'), findsWidgets);
    expect(taskController.tasks.single.id, 'task-1');
  });

  testWidgets('AcpClientApp runs a task from the Inbox UI', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fake = FakeAgentClient();
    final chat = ChatController(
      client: fake,
      cwd: '/workspace/default',
      agentName: 'Codex',
    );
    addTearDown(chat.dispose);
    final ids = _DeterministicIds();
    final taskController = TaskInboxController(
      store: _MemoryTaskStore(),
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: ids.next,
    );
    addTearDown(taskController.dispose);
    await taskController.load();
    await taskController.createTask(
      title: 'Run from app',
      description: 'Execute through ACP.',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );

    await tester.pumpWidget(
      AcpClientApp(controller: chat, taskInboxController: taskController),
    );
    await _pumpFrames(tester);
    await tester.tap(find.text('Inbox').first);
    await _pumpFrames(tester);
    await tester.tap(find.byTooltip('Run task'));
    await _pumpUntil(
      tester,
      () => taskController.tasks.single.status == TaskStatus.needsHumanReview,
      describeFailure: () {
        final task = taskController.tasks.single;
        return 'status=${task.status.name}, error=${task.error}, '
            'events=${taskController.events.map((event) => event.text).toList()}';
      },
    );

    expect(taskController.tasks.single.sessionId, 'fake-session-1');
    expect(chat.currentSession?.cwd, '/workspace/app');
    expect(fake.lastPrompt, contains('Task ID: task-1'));
    expect(find.text('Needs Review'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    expect(find.byTooltip('Open linked session'), findsOneWidget);
  });
}

Future<void> _pumpFrames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 20,
  String Function()? describeFailure,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  final detail = describeFailure?.call();
  fail(
    detail == null
        ? 'Condition was not met before timeout.'
        : 'Condition was not met before timeout: $detail',
  );
}

class _DeterministicIds {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}

class _MemoryTaskStore implements TaskStore {
  _MemoryTaskStore([TaskInboxSnapshot? snapshot])
    : _snapshot = snapshot ?? TaskInboxSnapshot.empty();

  TaskInboxSnapshot _snapshot;
  final List<TaskInboxSnapshot> savedSnapshots = <TaskInboxSnapshot>[];

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    _snapshot = snapshot;
    savedSnapshots.add(snapshot);
  }
}

TaskInboxSnapshot _reviewSnapshot() {
  return TaskInboxSnapshot(
    updatedAt: DateTime(2026, 7, 7, 9),
    tasks: [
      TaskRecord(
        id: 'task-1',
        title: 'Review artifacts',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.needsHumanReview,
        priority: TaskPriority.normal,
        createdAt: DateTime(2026, 7, 7, 8),
        updatedAt: DateTime(2026, 7, 7, 9),
        currentRunId: 'run-1',
      ),
    ],
    runs: [
      TaskRunRecord(
        id: 'run-1',
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.needsHumanReview,
        startedAt: DateTime(2026, 7, 7, 8),
      ),
    ],
    artifacts: [
      ArtifactRecord(
        id: 'artifact-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ArtifactKind.gitDiff,
        title: 'Git diff preview',
        createdAt: DateTime(2026, 7, 7, 9),
        contentPreview: 'diff --git a/note.txt b/note.txt\n+after',
      ),
    ],
  );
}

TaskInboxSnapshot _approvedExportSnapshot() {
  final snapshot = _reviewSnapshot();
  return snapshot.copyWith(
    tasks: [
      snapshot.tasks.single.copyWith(status: TaskStatus.approvedForExport),
    ],
    approvals: [
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ApprovalKind.export,
        status: ApprovalStatus.approved,
        createdAt: DateTime(2026, 7, 7, 9),
        resolvedAt: DateTime(2026, 7, 7, 9),
        target: ExportTarget.simulated,
        artifactIds: const ['artifact-1'],
      ),
    ],
  );
}
