import 'dart:async';

import 'task_inbox_controller.dart';
import 'task_record.dart';
import 'task_runner.dart';

abstract interface class TaskWorker {
  Future<TaskRecord> run(TaskRecord task);
}

class TaskRunnerWorker implements TaskWorker {
  const TaskRunnerWorker({required this.runner});

  final TaskRunner runner;

  @override
  Future<TaskRecord> run(TaskRecord task) => runner.runTask(task.id);
}

class TaskScheduler {
  TaskScheduler({
    required this.taskController,
    required this.worker,
    this.maxConcurrentTasks = 1,
  }) {
    if (maxConcurrentTasks < 1) {
      throw ArgumentError.value(
        maxConcurrentTasks,
        'maxConcurrentTasks',
        'Must be greater than zero.',
      );
    }
  }

  final TaskInboxController taskController;
  final TaskWorker worker;
  final int maxConcurrentTasks;
  final Set<String> _activeTaskIds = <String>{};
  bool _started = false;
  bool _disposed = false;
  bool _drainScheduled = false;
  bool _draining = false;

  bool get isStarted => _started;

  int get activeCount => _activeTaskIds.length;

  Future<void> start() async {
    _ensureNotDisposed();
    if (_started) return;
    await taskController.load();
    await taskController.recoverInterruptedRuns();
    _ensureNotDisposed();
    if (_started) return;
    _started = true;
    taskController.addListener(_onTaskControllerChanged);
    _scheduleDrain();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    taskController.removeListener(_onTaskControllerChanged);
  }

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
  }

  Future<TaskRecord> enqueueTask(String taskId) async {
    _ensureNotDisposed();
    final queued = await taskController.updateTaskStatus(
      taskId,
      TaskStatus.queued,
      summary: 'Queued for agent run.',
    );
    _scheduleDrain();
    return queued;
  }

  void _onTaskControllerChanged() {
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (!_started || _disposed || _drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      unawaited(_drain());
    });
  }

  Future<void> _drain() async {
    if (!_started || _disposed || _draining) return;
    _draining = true;
    try {
      while (_started &&
          !_disposed &&
          _activeTaskIds.length < maxConcurrentTasks) {
        final task = _nextQueuedTask();
        if (task == null) return;
        _activeTaskIds.add(task.id);
        unawaited(_runTask(task));
      }
    } finally {
      _draining = false;
    }
  }

  TaskRecord? _nextQueuedTask() {
    final queued = taskController.tasks
        .where(
          (task) =>
              task.status == TaskStatus.queued &&
              !_activeTaskIds.contains(task.id),
        )
        .toList(growable: false);
    if (queued.isEmpty) return null;
    queued.sort(_compareQueuedTasks);
    return queued.first;
  }

  Future<void> _runTask(TaskRecord task) async {
    try {
      await worker.run(task);
    } catch (error) {
      await _markTaskFailed(task, error);
    } finally {
      _activeTaskIds.remove(task.id);
      _scheduleDrain();
    }
  }

  Future<void> _markTaskFailed(TaskRecord task, Object error) async {
    try {
      await taskController.updateTask(
        task.id,
        status: TaskStatus.failed,
        error: _messageForError(error),
      );
    } catch (_) {
      // The task may have been deleted while the worker was running.
    }
  }

  String _messageForError(Object error) {
    if (error is StateError) return error.message;
    if (error is Exception) return error.toString();
    return '$error';
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('TaskScheduler has been disposed.');
    }
  }
}

int _compareQueuedTasks(TaskRecord a, TaskRecord b) {
  final priority = _priorityRank(
    b.priority,
  ).compareTo(_priorityRank(a.priority));
  if (priority != 0) return priority;
  final created = a.createdAt.compareTo(b.createdAt);
  if (created != 0) return created;
  final updated = a.updatedAt.compareTo(b.updatedAt);
  if (updated != 0) return updated;
  return a.id.compareTo(b.id);
}

int _priorityRank(TaskPriority priority) {
  return switch (priority) {
    TaskPriority.low => 0,
    TaskPriority.normal => 1,
    TaskPriority.high => 2,
    TaskPriority.urgent => 3,
  };
}
