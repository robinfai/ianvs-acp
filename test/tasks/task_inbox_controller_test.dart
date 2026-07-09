import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';

void main() {
  test('TaskInboxController creates inbox task and persists it', () async {
    var now = DateTime(2026, 7, 7, 8);
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      store: store,
      clock: () => now,
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);

    await controller.load();
    final task = await controller.createTask(
      title: '  Add inbox  ',
      description: '  Create local task store  ',
      workspacePath: '/workspace/app/',
      agentName: '  Codex  ',
      priority: TaskPriority.high,
    );

    expect(task.id, 'task-1');
    expect(task.title, 'Add inbox');
    expect(task.description, 'Create local task store');
    expect(task.workspacePath, '/workspace/app');
    expect(task.agentName, 'Codex');
    expect(task.status, TaskStatus.inbox);
    expect(task.priority, TaskPriority.high);
    expect(store.savedSnapshots, hasLength(1));
    expect(store.savedSnapshots.single.tasks.single.id, 'task-1');

    now = DateTime(2026, 7, 7, 9);
    final updated = await controller.updateTaskStatus(
      task.id,
      TaskStatus.running,
      summary: 'Started',
    );

    expect(updated.status, TaskStatus.running);
    expect(updated.summary, 'Started');
    expect(updated.updatedAt, now);
    expect(store.savedSnapshots, hasLength(2));
    expect(store.savedSnapshots.last.tasks.single.status, TaskStatus.running);
  });

  test(
    'TaskInboxController filters by status and normalized workspace',
    () async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 8),
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'A',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 8),
            ),
            TaskRecord(
              id: 'task-2',
              title: 'B',
              description: '',
              workspacePath: '/workspace/other',
              agentName: 'Codex',
              status: TaskStatus.done,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 8),
            ),
          ],
        ),
      );
      final controller = TaskInboxController(store: store);
      addTearDown(controller.dispose);

      await controller.load();

      expect(
        controller.tasksForStatus(TaskStatus.inbox).map((task) => task.id),
        ['task-1'],
      );
      expect(
        controller.tasksForWorkspace('/workspace/app/').map((task) => task.id),
        ['task-1'],
      );
    },
  );

  test('TaskInboxController notifies listeners on load and changes', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    var notifications = 0;
    controller.addListener(() {
      notifications += 1;
    });

    await controller.load();
    expect(notifications, 1);

    await controller.createTask(
      title: 'Add inbox',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    expect(notifications, 2);
  });

  test('TaskInboxController rejects duplicate generated ids', () async {
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Existing',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.inbox,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 7, 8),
            updatedAt: DateTime(2026, 7, 7, 8),
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      store: store,
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);

    await expectLater(
      controller.createTask(
        title: 'New',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
      ),
      throwsStateError,
    );
  });

  test('TaskInboxController can clear nullable task fields', () async {
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Existing',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.running,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 7, 8),
            updatedAt: DateTime(2026, 7, 7, 8),
            sessionId: 'session-1',
            currentRunId: 'run-1',
            summary: 'Summary',
            error: 'Error',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final task = await controller.updateTask(
      'task-1',
      status: TaskStatus.failed,
      sessionId: null,
      currentRunId: null,
      summary: null,
      error: null,
    );

    expect(task.status, TaskStatus.failed);
    expect(task.sessionId, isNull);
    expect(task.currentRunId, isNull);
    expect(task.summary, isNull);
    expect(task.error, isNull);
  });

  test('TaskInboxController replaces artifacts for a task run', () async {
    final snapshot = TaskInboxSnapshot(
      updatedAt: DateTime(2026, 7, 7, 8),
      tasks: [
        TaskRecord(
          id: 'task-1',
          title: 'Existing',
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.collectingArtifacts,
          priority: TaskPriority.normal,
          createdAt: DateTime(2026, 7, 7, 8),
          updatedAt: DateTime(2026, 7, 7, 8),
          currentRunId: 'run-1',
        ),
      ],
      runs: [
        TaskRunRecord(
          id: 'run-1',
          taskId: 'task-1',
          attempt: 1,
          status: TaskStatus.running,
          startedAt: DateTime(2026, 7, 7, 8),
        ),
      ],
      artifacts: [
        ArtifactRecord(
          id: 'old-artifact',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitStatus,
          title: 'Old status',
          createdAt: DateTime(2026, 7, 7, 8),
        ),
      ],
    );
    final store = _MemoryTaskStore(snapshot);
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final artifacts = await controller.replaceArtifactsForRun(
      taskId: 'task-1',
      runId: 'run-1',
      artifacts: [
        ArtifactRecord(
          id: 'artifact-1',
          taskId: 'task-1',
          runId: 'run-1',
          kind: ArtifactKind.gitDiff,
          title: 'Git diff preview',
          createdAt: DateTime(2026, 7, 7, 9),
          contentPreview: '+after',
        ),
      ],
    );

    expect(artifacts.single.id, 'artifact-1');
    expect(controller.artifacts.map((artifact) => artifact.id), ['artifact-1']);
    expect(
      store.savedSnapshots.last.artifacts.single.title,
      'Git diff preview',
    );
    expect(store.savedSnapshots.last.updatedAt, DateTime(2026, 7, 7, 9));
  });

  test('TaskInboxController marks review task done locally', () async {
    final store = _MemoryTaskStore(_reviewSnapshot());
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 7, 9),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final task = await controller.markTaskDoneLocally('task-1');

    expect(task.status, TaskStatus.done);
    expect(controller.approvals, isEmpty);
    expect(controller.events.last.kind, TaskEventKind.review);
    expect(controller.events.last.text, 'Marked done locally.');
  });

  test(
    'TaskInboxController request changes and reject update review status',
    () async {
      final store = _MemoryTaskStore(_reviewSnapshot());
      final controller = TaskInboxController(
        store: store,
        clock: () => DateTime(2026, 7, 7, 9),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final changes = await controller.requestTaskChanges(
        'task-1',
        rationale: 'Tighten tests.',
      );
      expect(changes.status, TaskStatus.needsChanges);
      expect(changes.summary, 'Tighten tests.');

      await controller.updateTaskStatus('task-1', TaskStatus.needsHumanReview);
      final rejected = await controller.rejectTask('task-1');

      expect(rejected.status, TaskStatus.rejected);
      expect(rejected.summary, 'Task rejected.');
      expect(
        controller.events.where((event) => event.kind == TaskEventKind.review),
        hasLength(2),
      );
    },
  );

  test(
    'TaskInboxController reviews artifacts without creating export approval',
    () async {
      final store = _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 8),
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
              updatedAt: DateTime(2026, 7, 7, 8),
              currentRunId: 'run-1',
              sessionId: 'session-1',
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
              title: 'Safe diff',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
            ArtifactRecord(
              id: 'artifact-2',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.outboxFile,
              title: 'Unsafe file',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
            ArtifactRecord(
              id: 'artifact-3',
              taskId: 'task-1',
              runId: 'run-1',
              kind: ArtifactKind.testLog,
              title: 'Evidence log',
              createdAt: DateTime(2026, 7, 7, 8),
            ),
          ],
        ),
      );
      final controller = TaskInboxController(
        store: store,
        clock: () => DateTime(2026, 7, 7, 9),
      );
      addTearDown(controller.dispose);
      await controller.load();

      final reviewed = await controller.reviewArtifactsForRun(
        taskId: 'task-1',
        runId: 'run-1',
        approvedArtifactIds: const ['artifact-1'],
        rejectedArtifactIds: const ['artifact-2'],
        rationale: 'Only the diff should leave the machine.',
      );

      expect(reviewed.map((artifact) => artifact.status), [
        ArtifactStatus.approved,
        ArtifactStatus.rejected,
        ArtifactStatus.reviewed,
      ]);
      expect(controller.events.single.kind, TaskEventKind.review);
      expect(controller.events.single.text, 'Artifact review completed.');
      expect(controller.events.single.metadata['approved_artifact_ids'], [
        'artifact-1',
      ]);
      expect(controller.events.single.metadata['rejected_artifact_ids'], [
        'artifact-2',
      ]);
      expect(controller.approvals, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.needsHumanReview);
      expect(controller.artifacts.map((artifact) => artifact.status), [
        ArtifactStatus.approved,
        ArtifactStatus.rejected,
        ArtifactStatus.reviewed,
      ]);
    },
  );

  test('TaskInboxController queues retry and preserves run history', () async {
    final ids = _DeterministicIds();
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Retry me',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.failed,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 8, 8),
            updatedAt: DateTime(2026, 7, 8, 8),
            currentRunId: 'run-1',
            sessionId: 'session-1',
            error: 'boom',
          ),
        ],
        runs: [
          TaskRunRecord(
            id: 'run-1',
            taskId: 'task-1',
            attempt: 1,
            status: TaskStatus.failed,
            startedAt: DateTime(2026, 7, 8, 8),
            endedAt: DateTime(2026, 7, 8, 8, 5),
            sessionId: 'session-1',
            error: 'boom',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();

    final queued = await controller.retryTask(
      'task-1',
      rationale: 'Try again with a smaller change.',
    );

    expect(queued.status, TaskStatus.queued);
    expect(queued.summary, 'Try again with a smaller change.');
    expect(queued.error, isNull);
    expect(queued.sessionId, isNull);
    expect(queued.currentRunId, isNull);
    expect(controller.runs.single.id, 'run-1');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(controller.events.single.kind, TaskEventKind.system);
    expect(controller.events.single.runId, 'run-1');
    expect(controller.events.single.text, 'Task retry queued.');

    final secondRun = await controller.createRun(taskId: 'task-1');

    expect(secondRun.id, 'run-2');
    expect(secondRun.attempt, 2);
    expect(controller.tasks.single.currentRunId, 'run-2');
  });

  test('TaskInboxController recovers interrupted runs as failed', () async {
    final ids = _DeterministicIds();
    final store = _MemoryTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 8),
        tasks: [
          TaskRecord(
            id: 'task-1',
            title: 'Interrupted',
            description: '',
            workspacePath: '/workspace/app',
            agentName: 'Codex',
            status: TaskStatus.running,
            priority: TaskPriority.normal,
            createdAt: DateTime(2026, 7, 8, 8),
            updatedAt: DateTime(2026, 7, 8, 8),
            currentRunId: 'run-1',
            sessionId: 'session-1',
          ),
        ],
        runs: [
          TaskRunRecord(
            id: 'run-1',
            taskId: 'task-1',
            attempt: 1,
            status: TaskStatus.running,
            startedAt: DateTime(2026, 7, 8, 8),
            sessionId: 'session-1',
          ),
        ],
      ),
    );
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();

    final recovered = await controller.recoverInterruptedRuns();

    expect(recovered.map((task) => task.id), ['task-1']);
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(
      controller.tasks.single.error,
      'Task run interrupted before completion.',
    );
    expect(controller.tasks.single.currentRunId, 'run-1');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(controller.runs.single.endedAt, DateTime(2026, 7, 8, 9));
    expect(
      controller.runs.single.error,
      'Task run interrupted before completion.',
    );
    expect(controller.events.single.kind, TaskEventKind.system);
    expect(
      controller.events.single.text,
      'Task run recovered as failed: Task run interrupted before completion.',
    );
  });
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
    updatedAt: DateTime(2026, 7, 7, 8),
    tasks: [
      TaskRecord(
        id: 'task-1',
        title: 'Review me',
        description: '',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        status: TaskStatus.needsHumanReview,
        priority: TaskPriority.normal,
        createdAt: DateTime(2026, 7, 7, 8),
        updatedAt: DateTime(2026, 7, 7, 8),
        currentRunId: 'run-1',
        sessionId: 'session-1',
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
        createdAt: DateTime(2026, 7, 7, 8),
        contentPreview: '+after',
      ),
    ],
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
