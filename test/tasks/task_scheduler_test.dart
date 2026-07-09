import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
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

  test('TaskScheduler honors max concurrent tasks', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 8, 9),
          tasks: [
            _task(id: 'task-1', createdAt: DateTime(2026, 7, 8, 9)),
            _task(id: 'task-2', createdAt: DateTime(2026, 7, 8, 9, 1)),
            _task(id: 'task-3', createdAt: DateTime(2026, 7, 8, 9, 2)),
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
        idGenerator: (_) => 'event-1',
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
      expect(controller.runs.single.status, TaskStatus.failed);
      expect(controller.runs.single.endedAt, DateTime(2026, 7, 8, 10));
    },
  );
}

TaskRecord _task({
  required String id,
  TaskPriority priority = TaskPriority.normal,
  required DateTime createdAt,
  TaskStatus status = TaskStatus.queued,
  String? currentRunId,
}) {
  return TaskRecord(
    id: id,
    title: id,
    description: '',
    workspacePath: '/workspace/app',
    agentName: 'Codex',
    status: status,
    priority: priority,
    createdAt: createdAt,
    updatedAt: createdAt,
    currentRunId: currentRunId,
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

Future<void> _waitUntil(bool Function() condition, {int attempts = 40}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Condition was not met before timeout.');
}
