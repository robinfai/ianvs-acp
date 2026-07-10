import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/retry_policy.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_scheduler.dart';
import 'package:ianvs_acp/tasks/task_store.dart';

void main() {
  test('TaskScheduler enqueues an inbox task without starting work', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 8, 9),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(controller.dispose);
    await controller.load();
    final task = await controller.createTask(
      title: 'Queue me',
      description: '',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    final queued = await scheduler.enqueueTask(task.id);

    expect(queued.status, TaskStatus.queued);
    expect(store.savedSnapshots.last.tasks.single.status, TaskStatus.queued);
    expect(worker.startedTaskIds, isEmpty);
  });

  test('TaskScheduler runs queued tasks by priority', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-normal',
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 8, 9),
            ),
            _task(
              id: 'task-urgent',
              priority: TaskPriority.urgent,
              createdAt: DateTime(2026, 7, 8, 9, 1),
            ),
            _task(
              id: 'task-high',
              priority: TaskPriority.high,
              createdAt: DateTime(2026, 7, 8, 9, 2),
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      maxConcurrentTasks: 1,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);
    expect(worker.startedTaskIds, ['task-urgent']);

    worker.complete('task-urgent');
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    expect(worker.startedTaskIds, ['task-urgent', 'task-high']);

    worker.complete('task-high');
    await _waitUntil(() => worker.startedTaskIds.length == 3);
    expect(worker.startedTaskIds, ['task-urgent', 'task-high', 'task-normal']);
  });

  test('TaskScheduler stop prevents queued task scans', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start();
    scheduler.stop();
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(scheduler.isStarted, isFalse);
    expect(worker.startedTaskIds, isEmpty);
    expect(controller.runs, isEmpty);
  });

  test('TaskScheduler dispatches a run before starting work', () async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      clock: () => DateTime(2026, 7, 8, 9, 30),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);

    expect(controller.runs.single.status, TaskStatus.dispatched);
    expect(controller.runs.single.taskId, 'task-1');
    expect(controller.tasks.single.currentRunId, 'run-1');
    expect(controller.events.single.text, 'Task dispatched.');
    expect(controller.events.single.metadata['task_status'], 'dispatched');
  });

  test(
    'TaskScheduler runs different workspaces up to max concurrency',
    () async {
      final controller = TaskInboxController(
        store: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: DateTime(2026, 7, 8, 9),
            tasks: [
              _task(
                id: 'task-1',
                workspacePath: '/workspace/app',
                createdAt: DateTime(2026, 7, 8, 9),
              ),
              _task(
                id: 'task-2',
                workspacePath: '/workspace/other',
                createdAt: DateTime(2026, 7, 8, 9, 1),
              ),
              _task(
                id: 'task-3',
                workspacePath: '/workspace/third',
                createdAt: DateTime(2026, 7, 8, 9, 2),
              ),
            ],
          ),
        ),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 2,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.length == 2);
      expect(worker.startedTaskIds, ['task-1', 'task-2']);
      expect(scheduler.activeCount, 2);

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(worker.startedTaskIds, ['task-1', 'task-2']);

      worker.complete('task-1');
      await _waitUntil(() => worker.startedTaskIds.length == 3);
      expect(worker.startedTaskIds, ['task-1', 'task-2', 'task-3']);
    },
  );

  test('TaskScheduler serializes tasks with the same workspace path', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(
              id: 'task-1',
              workspacePath: '/workspace/app',
              createdAt: DateTime(2026, 7, 8, 9),
            ),
            _task(
              id: 'task-2',
              workspacePath: '/workspace/app/',
              createdAt: DateTime(2026, 7, 8, 9, 1),
            ),
            _task(
              id: 'task-3',
              workspacePath: '/workspace/other',
              createdAt: DateTime(2026, 7, 8, 9, 2),
            ),
          ],
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      maxConcurrentTasks: 3,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    expect(worker.startedTaskIds, ['task-1', 'task-3']);

    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(worker.startedTaskIds, ['task-1', 'task-3']);

    worker.complete('task-1');
    await _waitUntil(() => worker.startedTaskIds.length == 3);
    expect(worker.startedTaskIds, ['task-1', 'task-3', 'task-2']);
  });

  test(
    'TaskScheduler keeps runtime offline tasks queued with an event',
    () async {
      final now = DateTime(2026, 7, 8, 9);
      final controller = TaskInboxController(
        store: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [_task(id: 'task-1', createdAt: now)],
          ),
        ),
        clock: () => now,
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final runtimeRegistry = LocalRuntimeRegistry(clock: () => now)
        ..setStatus(
          LocalRuntimeStatus.unavailable(
            agentName: 'Codex',
            checkedAt: now,
            reason: 'Agent process is offline.',
          ),
        );
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        runtimeRegistry: runtimeRegistry,
        retryPolicy: const RetryPolicy(baseDelay: Duration(hours: 1)),
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => controller.events.isNotEmpty);

      expect(worker.startedTaskIds, isEmpty);
      expect(controller.tasks.single.status, TaskStatus.queued);
      expect(controller.tasks.single.summary, contains('Runtime unavailable'));
      expect(
        controller.tasks.single.metadata['failure_reason'],
        'runtimeOffline',
      );
      expect(controller.tasks.single.metadata['next_retry_at'], isNotNull);
      expect(controller.runs.single.status, TaskStatus.failed);
      expect(
        controller.events.map((event) => event.text),
        contains(contains('Runtime unavailable')),
      );
    },
  );

  test('TaskScheduler blocks auth-required runtime without retrying', () async {
    final now = DateTime(2026, 7, 8, 9);
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: now,
          tasks: [_task(id: 'task-1', createdAt: now)],
        ),
      ),
      clock: () => now,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final runtimeRegistry = LocalRuntimeRegistry(clock: () => now)
      ..setStatus(
        LocalRuntimeStatus.authRequired(
          agentName: 'Codex',
          checkedAt: now,
          reason: 'Run authentication first.',
        ),
      );
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      runtimeRegistry: runtimeRegistry,
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => controller.events.isNotEmpty);

    expect(worker.startedTaskIds, isEmpty);
    expect(controller.tasks.single.status, TaskStatus.blockedOnUserInput);
    expect(
      controller.tasks.single.summary,
      contains('Authentication required'),
    );
    expect(controller.tasks.single.metadata['failure_reason'], 'authRequired');
    expect(controller.runs.single.status, TaskStatus.failed);
    expect(
      controller.events.map((event) => event.text),
      contains(contains('Authentication required')),
    );
  });

  test('TaskScheduler retries retryable failures with a new run', () async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      clock: () => DateTime(2026, 7, 8, 10),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _FailOnceTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      retryPolicy: const RetryPolicy(baseDelay: Duration.zero),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 2);
    worker.complete('task-1');
    await _waitUntil(
      () => controller.tasks.single.status == TaskStatus.needsHumanReview,
    );

    expect(worker.startedTaskIds, ['task-1', 'task-1']);
    expect(controller.runs.map((run) => run.attempt), [1, 2]);
    expect(controller.runs.map((run) => run.id), ['run-1', 'run-2']);
    expect(
      controller.events.map((event) => event.text),
      contains('Task retry queued.'),
    );
  });

  test(
    'TaskScheduler moves retry wake earlier for newly queued task',
    () async {
      final now = DateTime.now();
      final controller = TaskInboxController(
        store: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: now,
            tasks: [
              _task(
                id: 'task-late',
                createdAt: now,
                metadata: <String, Object?>{
                  'next_retry_at': now
                      .add(const Duration(milliseconds: 350))
                      .toIso8601String(),
                },
              ),
              _task(
                id: 'task-early',
                createdAt: now.add(const Duration(milliseconds: 1)),
                metadata: <String, Object?>{
                  'next_retry_at': now
                      .add(const Duration(milliseconds: 50))
                      .toIso8601String(),
                },
              ),
            ],
          ),
        ),
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 1,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(
        () => worker.startedTaskIds.contains('task-early'),
        attempts: 20,
      );

      expect(worker.startedTaskIds, ['task-early']);
    },
  );

  test('TaskScheduler does not retry non-retryable failures', () async {
    final ids = _DeterministicIds();
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      clock: () => DateTime(2026, 7, 8, 10),
      idGenerator: ids.next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _NonRetryableFailureTaskWorker(controller);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: worker,
      retryPolicy: const RetryPolicy(baseDelay: Duration.zero),
    );
    addTearDown(scheduler.dispose);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.length == 1);
    await Future<void>.delayed(const Duration(milliseconds: 25));

    expect(worker.startedTaskIds, ['task-1']);
    expect(controller.runs, hasLength(1));
    expect(controller.tasks.single.status, TaskStatus.failed);
    expect(controller.tasks.single.error, contains('permissionDenied'));
  });

  test(
    'TaskScheduler recovers interrupted runs before draining queue',
    () async {
      final controller = TaskInboxController(
        store: _MemoryTaskStore(
          TaskInboxSnapshot(
            updatedAt: DateTime(2026, 7, 8, 9),
            tasks: [
              _task(
                id: 'task-interrupted',
                createdAt: DateTime(2026, 7, 8, 9),
                status: TaskStatus.running,
                currentRunId: 'run-1',
              ),
              _task(id: 'task-queued', createdAt: DateTime(2026, 7, 8, 9, 1)),
            ],
            runs: [
              TaskRunRecord(
                id: 'run-1',
                taskId: 'task-interrupted',
                attempt: 1,
                status: TaskStatus.running,
                startedAt: DateTime(2026, 7, 8, 9),
              ),
            ],
          ),
        ),
        clock: () => DateTime(2026, 7, 8, 10),
        idGenerator: _DeterministicIds().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final worker = _RecordingTaskWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        maxConcurrentTasks: 1,
      );
      addTearDown(scheduler.dispose);

      await scheduler.start();
      await _waitUntil(() => worker.startedTaskIds.length == 1);

      expect(worker.startedTaskIds, ['task-queued']);
      expect(
        controller.taskById('task-interrupted')!.status,
        TaskStatus.failed,
      );
      final recoveredRun = controller.runs.singleWhere(
        (run) => run.id == 'run-1',
      );
      expect(recoveredRun.status, TaskStatus.failed);
      expect(recoveredRun.endedAt, DateTime(2026, 7, 8, 10));
    },
  );

  test('TaskScheduler shutdown cancels and waits for active work', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final worker = _CancellableTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);

    await scheduler.start();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);
    var shutdownFinished = false;
    final shutdown = scheduler.shutdown().then((_) => shutdownFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(worker.cancelCalls, 1);
    expect(shutdownFinished, isFalse);
    worker.complete();
    await shutdown;
    expect(shutdownFinished, isTrue);
    expect(scheduler.activeCount, 0);
  });

  test('TaskScheduler shutdown waits for dispatch persistence', () async {
    final store = _BlockingSaveTaskStore(
      TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 8, 9),
        tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
      ),
    );
    final controller = TaskInboxController(
      store: store,
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final scheduler = TaskScheduler(
      taskController: controller,
      worker: _RecordingTaskWorker(controller),
    );

    await scheduler.start();
    await store.saveStarted.future;
    var shutdownFinished = false;
    final shutdown = scheduler.shutdown().then((_) => shutdownFinished = true);
    await Future<void>.delayed(Duration.zero);

    expect(shutdownFinished, isFalse);
    store.releaseSave();
    await shutdown;
    expect(shutdownFinished, isTrue);
    expect(scheduler.activeCount, 0);
  });

  test('TaskScheduler can recover without dispatching queued work', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [_task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9))],
        ),
      ),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(controller.dispose);
    final worker = _RecordingTaskWorker(controller);
    final scheduler = TaskScheduler(taskController: controller, worker: worker);
    addTearDown(scheduler.dispose);

    await scheduler.start(dispatchQueuedTasks: false);
    await controller.updateTask('task-1', summary: 'Updated before publish.');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(worker.startedTaskIds, isEmpty);

    scheduler.startDispatching();
    await _waitUntil(() => worker.startedTaskIds.isNotEmpty);
    expect(worker.startedTaskIds, ['task-1']);
  });
}

TaskRecord _task({
  required String id,
  TaskPriority priority = TaskPriority.normal,
  required DateTime createdAt,
  TaskStatus status = TaskStatus.queued,
  String workspacePath = '/workspace/app',
  String? currentRunId,
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
  return TaskRecord(
    id: id,
    title: id,
    description: '',
    workspacePath: workspacePath,
    agentName: 'Codex',
    status: status,
    priority: priority,
    createdAt: createdAt,
    updatedAt: createdAt,
    currentRunId: currentRunId,
    metadata: metadata,
  );
}

class _RecordingTaskWorker implements TaskWorker {
  _RecordingTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final completion = Completer<void>();
    _completions[task.id] = completion;
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await completion.future;
    return controller.updateTaskStatus(task.id, TaskStatus.needsHumanReview);
  }

  void complete(String taskId) {
    final completion = _completions[taskId];
    if (completion == null || completion.isCompleted) return;
    completion.complete();
  }
}

class _FailOnceTaskWorker implements TaskWorker {
  _FailOnceTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Map<String, Completer<void>> _completions = <String, Completer<void>>{};

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    if (startedTaskIds.length == 1) {
      await controller.updateRun(
        runId,
        status: TaskStatus.failed,
        endedAt: DateTime(2026, 7, 8, 10),
        error: 'runtimeOffline: agent disconnected',
      );
      return controller.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: 'runtimeOffline: agent disconnected',
      );
    }

    final completion = Completer<void>();
    _completions[task.id] = completion;
    await controller.updateRun(runId, status: TaskStatus.running);
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await completion.future;
    await controller.updateRun(
      runId,
      status: TaskStatus.needsHumanReview,
      endedAt: DateTime(2026, 7, 8, 10, 1),
    );
    return controller.updateTaskStatus(task.id, TaskStatus.needsHumanReview);
  }

  void complete(String taskId) {
    final completion = _completions[taskId];
    if (completion == null || completion.isCompleted) return;
    completion.complete();
  }
}

class _NonRetryableFailureTaskWorker implements TaskWorker {
  _NonRetryableFailureTaskWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    await controller.updateRun(
      runId,
      status: TaskStatus.failed,
      endedAt: DateTime(2026, 7, 8, 10),
      error: 'permissionDenied: user denied tool access',
    );
    return controller.updateTask(
      task.id,
      status: TaskStatus.failed,
      error: 'permissionDenied: user denied tool access',
    );
  }
}

class _CancellableTaskWorker implements CancellableTaskWorker {
  _CancellableTaskWorker(this.controller);

  final TaskInboxController controller;
  final Completer<void> _completion = Completer<void>();
  final List<String> startedTaskIds = <String>[];
  int cancelCalls = 0;

  @override
  Future<void> cancelActive() async {
    cancelCalls += 1;
  }

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    await controller.updateTaskStatus(task.id, TaskStatus.running);
    await _completion.future;
    return controller.updateTaskStatus(task.id, TaskStatus.cancelled);
  }

  void complete() {
    if (!_completion.isCompleted) _completion.complete();
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

class _BlockingSaveTaskStore implements TaskStore {
  _BlockingSaveTaskStore(this._snapshot);

  TaskInboxSnapshot _snapshot;
  final Completer<void> saveStarted = Completer<void>();
  final Completer<void> _saveRelease = Completer<void>();

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    if (!saveStarted.isCompleted) saveStarted.complete();
    await _saveRelease.future;
    _snapshot = snapshot;
  }

  void releaseSave() {
    if (!_saveRelease.isCompleted) _saveRelease.complete();
  }
}

class _DeterministicIds {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}

Future<void> _waitUntil(bool Function() condition, {int attempts = 40}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}
