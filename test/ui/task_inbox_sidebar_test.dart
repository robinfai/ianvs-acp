import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/ui/components/task_inbox_sidebar.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

import '../support/memory_task_repository.dart';

void main() {
  Future<void> pumpSidebar(
    WidgetTester tester,
    TaskInboxController controller, {
    String? selectedTaskId,
    String? defaultModel,
    ValueChanged<TaskRecord>? onRunTask,
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
              defaultModel: defaultModel,
              agentNames: const ['Codex', 'Kimi'],
              onRunTask: onRunTask,
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
      repository: store,
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

  testWidgets('TaskInboxSidebar snapshots the selected model into a task', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(),
      idGenerator: (_) => 'task-model',
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(tester, controller, defaultModel: 'gpt-5.3-codex-spark');
    await tester.tap(find.byTooltip('New task'));
    await _pumpFrames(tester);
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Run with the selected model',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await _pumpFrames(tester);

    expect(controller.tasks.single.metadata['model'], 'gpt-5.3-codex-spark');
  });

  testWidgets('TaskInboxSidebar empty state opens a labeled task editor', (
    tester,
  ) async {
    final controller = TaskInboxController(repository: _MemoryTaskStore());
    addTearDown(controller.dispose);
    await controller.load();
    final semantics = tester.ensureSemantics();

    await pumpSidebar(tester, controller);

    expect(find.text('Create task'), findsOneWidget);
    await tester.tap(find.byKey(const Key('task-empty-create-button')));
    await _pumpFrames(tester);

    expect(find.text('New Task'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Task title')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Task description')), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Task workspace path')),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('TaskInboxSidebar reveals task context and next action', (
    tester,
  ) async {
    final task = TaskRecord(
      id: 'task-context',
      title: 'Clarify the Inbox',
      description: 'Make the task request visible after creation.',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.inbox,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 7, 8),
      updatedAt: DateTime(2026, 7, 7, 9),
    );
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(updatedAt: task.updatedAt, tasks: [task]),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(tester, controller, onRunTask: (_) {});
    expect(find.text(task.description), findsNothing);

    await tester.tap(find.text(task.title));
    await _pumpFrames(tester);

    expect(find.text(task.description), findsOneWidget);
    expect(find.text('Ready to run in the background.'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Run task'), findsOneWidget);
  });

  testWidgets(
    'TaskInboxSidebar does not enqueue an already queued task again',
    (tester) async {
      final task = TaskRecord(
        id: 'task-queued',
        title: 'Waiting task',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.queued,
        priority: TaskPriority.normal,
        createdAt: DateTime(2026, 7, 7, 8),
        updatedAt: DateTime(2026, 7, 7, 9),
        summary: 'Queued for agent run.',
      );
      final controller = TaskInboxController(
        repository: _MemoryTaskStore(
          TaskInboxSnapshot(updatedAt: task.updatedAt, tasks: [task]),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();

      await pumpSidebar(
        tester,
        controller,
        selectedTaskId: task.id,
        onRunTask: (_) => fail('Queued tasks must not be enqueued twice.'),
      );

      expect(find.byTooltip('Run task'), findsNothing);
      expect(
        find.text(
          'Waiting for an available agent. This task will start automatically.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('TaskInboxSidebar surfaces failure context before retry', (
    tester,
  ) async {
    final task = TaskRecord(
      id: 'task-failed',
      title: 'Failed task',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.failed,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 7, 8),
      updatedAt: DateTime(2026, 7, 7, 9),
      error: 'The agent disconnected before completion.',
    );
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(updatedAt: task.updatedAt, tasks: [task]),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(
      tester,
      controller,
      selectedTaskId: task.id,
      onRunTask: (_) {},
    );

    expect(find.text(task.error!), findsOneWidget);
    expect(
      find.text('Review the error, then retry when you are ready.'),
      findsOneWidget,
    );
    expect(find.widgetWithText(FilledButton, 'Retry'), findsOneWidget);
  });

  testWidgets('TaskInboxSidebar persists after controller reload', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
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

  testWidgets(
    'TaskInboxSidebar confirms raw data purge and keeps durable task data',
    (tester) async {
      final createdAt = DateTime.utc(2030, 1, 2);
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: <TaskRecord>[
            TaskRecord(
              id: 'task-1',
              title: 'Keep task title',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.needsHumanReview,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
              currentRunId: 'run-1',
              summary: 'Keep summary',
            ),
          ],
          runs: <TaskRunRecord>[
            TaskRunRecord(
              id: 'run-1',
              taskId: 'task-1',
              attempt: 1,
              status: TaskStatus.needsHumanReview,
              startedAt: createdAt,
              promptSnapshot: 'raw prompt',
            ),
          ],
          events: <TaskEventRecord>[
            TaskEventRecord(
              id: 'event-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: TaskEventKind.tool,
              text: 'Keep event text',
              createdAt: createdAt,
              metadata: const <String, Object?>{'raw': 'secret'},
            ),
          ],
          artifacts: <ArtifactRecord>[
            ArtifactRecord(
              id: 'artifact-1',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.gitDiff,
              title: 'src/main.dart',
              createdAt: createdAt,
              path: 'src/main.dart',
              contentPreview: 'raw diff secret',
              metadata: const <String, Object?>{'raw_payload': true},
            ),
          ],
        ),
      );
      final controller = TaskInboxController(repository: store);
      addTearDown(controller.dispose);
      await controller.load();
      await pumpSidebar(tester, controller, selectedTaskId: 'task-1');

      await tester.tap(find.byTooltip('Task data actions'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Clear raw tool data'));
      await _pumpFrames(tester);
      expect(find.text('Clear raw tool data?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await _pumpFrames(tester);
      expect(store.rawPayloadPurgeCount, 0);

      await tester.tap(find.byTooltip('Task data actions'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Clear raw tool data'));
      await _pumpFrames(tester);
      await tester.tap(
        find.byKey(const Key('task-clear-raw-data-confirm-button')),
      );
      await _pumpFrames(tester);

      expect(store.rawPayloadPurgeCount, 1);
      expect(controller.tasks.single.title, 'Keep task title');
      expect(controller.tasks.single.summary, 'Keep summary');
      expect(controller.events.single.text, 'Keep event text');
      expect(controller.events.single.metadata, isEmpty);
      expect(controller.artifacts.single.title, 'src/main.dart');
      expect(controller.artifacts.single.path, 'src/main.dart');
      expect(controller.artifacts.single.contentPreview, isNull);
      expect(find.text('src/main.dart'), findsOneWidget);
      expect(find.textContaining('raw diff secret'), findsNothing);
      expect(find.textContaining('Cleared 3 raw data records'), findsOneWidget);
    },
  );

  testWidgets('TaskInboxSidebar reports raw data purge failure', (
    tester,
  ) async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(repository: store);
    addTearDown(controller.dispose);
    await controller.load();
    store.beforeOperation = (operation) async {
      if (operation == 'purgeRawPayloads') throw StateError('disk locked');
    };
    await pumpSidebar(tester, controller);

    await tester.tap(find.byTooltip('Task data actions'));
    await _pumpFrames(tester);
    await tester.tap(find.text('Clear raw tool data'));
    await _pumpFrames(tester);
    await tester.tap(
      find.byKey(const Key('task-clear-raw-data-confirm-button')),
    );
    await _pumpFrames(tester);

    expect(
      find.textContaining('Could not clear raw tool data'),
      findsOneWidget,
    );
    expect(find.textContaining('disk locked'), findsOneWidget);
  });

  testWidgets(
    'TaskInboxSidebar abandons confirmation after controller replacement',
    (tester) async {
      final oldStore = _MemoryTaskStore();
      final newStore = _MemoryTaskStore();
      final oldController = TaskInboxController(repository: oldStore);
      final newController = TaskInboxController(repository: newStore);
      addTearDown(oldController.dispose);
      addTearDown(newController.dispose);
      await oldController.load();
      await newController.load();
      await pumpSidebar(tester, oldController);

      await tester.tap(find.byTooltip('Task data actions'));
      await _pumpFrames(tester);
      await tester.tap(find.text('Clear raw tool data'));
      await _pumpFrames(tester);
      expect(find.text('Clear raw tool data?'), findsOneWidget);

      await pumpSidebar(tester, newController);
      expect(find.text('Clear raw tool data?'), findsOneWidget);
      await pumpSidebar(tester, oldController);
      expect(find.text('Clear raw tool data?'), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('task-clear-raw-data-confirm-button')),
      );
      await _pumpFrames(tester);

      expect(oldStore.rawPayloadPurgeCount, 0);
      expect(newStore.rawPayloadPurgeCount, 0);
      expect(find.textContaining('Cleared '), findsNothing);
    },
  );

  testWidgets('TaskInboxSidebar shows artifact previews for selected task', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
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
      repository: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller);

    await tester.tap(find.text('Review artifacts'));
    await _pumpFrames(tester);

    expect(find.text('Approve Export'), findsNothing);
    expect(find.byKey(const Key('task-approve-export-button')), findsNothing);
    expect(find.text('Mark Done Locally'), findsOneWidget);
    expect(find.text('Request Changes'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
  });

  testWidgets('TaskInboxSidebar selects externally requested task', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();

    await pumpSidebar(tester, controller, selectedTaskId: 'task-1');

    expect(find.text('Review artifacts'), findsWidgets);
    expect(find.byKey(const Key('task-approve-export-button')), findsNothing);
    expect(
      find.byKey(const Key('task-mark-done-locally-button')),
      findsOneWidget,
    );
  });

  testWidgets('TaskInboxSidebar marks review task done locally', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(_reviewSnapshot()),
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

  testWidgets('TaskInboxSidebar serializes review decisions while saving', (
    tester,
  ) async {
    final saveGate = Completer<void>();
    var updateAttempts = 0;
    final store = _MemoryTaskStore(_reviewSnapshot())
      ..beforeOperation = (operation) async {
        if (operation != 'updateTask') return;
        updateAttempts += 1;
        await saveGate.future;
      };
    final controller = TaskInboxController(repository: store);
    addTearDown(controller.dispose);
    await controller.load();
    await pumpSidebar(tester, controller, selectedTaskId: 'task-1');

    await tester.tap(find.byKey(const Key('task-mark-done-locally-button')));
    await tester.pump();

    expect(find.text('Saving decision…'), findsOneWidget);
    expect(updateAttempts, 1);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('task-mark-done-locally-button')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const Key('task-request-changes-button')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('task-reject-button')))
          .onPressed,
      isNull,
    );

    saveGate.complete();
    await _pumpFrames(tester);

    expect(controller.tasks.single.status, TaskStatus.done);
    expect(updateAttempts, 1);
  });

  testWidgets('TaskInboxSidebar does not expose export actions', (
    tester,
  ) async {
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(_reviewSnapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();

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
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.byTooltip('Export task'), findsNothing);
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
      repository: _MemoryTaskStore(
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

  testWidgets('TaskInboxSidebar lets an auth-blocked task be retried', (
    tester,
  ) async {
    final task = TaskRecord(
      id: 'task-auth',
      title: 'Authenticate and retry',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.blockedOnUserInput,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 7, 8),
      updatedAt: DateTime(2026, 7, 7, 9),
      metadata: const <String, Object?>{'failure_reason': 'authRequired'},
    );
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(updatedAt: DateTime(2026, 7, 7, 9), tasks: [task]),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    TaskRecord? retriedTask;

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
              onRunTask: (task) => retriedTask = task,
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    await tester.tap(find.byTooltip('Run task'));
    await _pumpFrames(tester);

    expect(retriedTask?.id, 'task-auth');
  });

  testWidgets('TaskInboxSidebar does not run other user-input blocks', (
    tester,
  ) async {
    final task = TaskRecord(
      id: 'task-permission',
      title: 'Resolve permission first',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
      status: TaskStatus.blockedOnUserInput,
      priority: TaskPriority.normal,
      createdAt: DateTime(2026, 7, 7, 8),
      updatedAt: DateTime(2026, 7, 7, 9),
      metadata: const <String, Object?>{'failure_reason': 'permissionDenied'},
    );
    final controller = TaskInboxController(
      repository: _MemoryTaskStore(
        TaskInboxSnapshot(updatedAt: DateTime(2026, 7, 7, 9), tasks: [task]),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    var runCalls = 0;

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
              onRunTask: (_) => runCalls += 1,
            ),
          ),
        ),
      ),
    );
    await _pumpFrames(tester);

    expect(find.byTooltip('Run task'), findsNothing);
    expect(runCalls, 0);
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
    final taskController = TaskInboxController(repository: _MemoryTaskStore());
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
      repository: _MemoryTaskStore(),
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

    final foregroundFake = FakeAgentClient();
    final chat = ChatController(
      client: foregroundFake,
      cwd: '/workspace/default',
      agentName: 'Codex',
    );
    addTearDown(chat.dispose);
    final backgroundFake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final ids = _DeterministicIds();
    final taskController = TaskInboxController(
      repository: _MemoryTaskStore(),
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
      AcpClientApp(
        controller: chat,
        config: config,
        autoLoadWorkspaceSessions: false,
        taskInboxController: taskController,
        createTaskAgentClient: (_) => backgroundFake,
      ),
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
    expect(chat.currentSession, isNull);
    expect(foregroundFake.lastPrompt, isNull);
    expect(backgroundFake.lastPrompt, contains('Task ID: task-1'));
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

class _MemoryTaskStore extends MemoryTaskRepository {
  _MemoryTaskStore([super.snapshot]);
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
