import 'dart:async';

import 'retry_policy.dart';
import 'runtime_registry.dart';
import 'task_inbox_controller.dart';
import 'task_record.dart';
import 'task_repository.dart';
import 'task_wake_timer.dart';
import 'task_worker.dart';
import 'workspace_execution_gate.dart';
import 'workspace_resource.dart';

export 'task_worker.dart';

class TaskScheduler {
  TaskScheduler({
    required this.taskController,
    required this.worker,
    this.maxConcurrentTasks = 1,
    WorkspaceExecutionGate? workspaceGate,
    this.runtimeRegistry,
    this.retryPolicy = const RetryPolicy(),
    this.onPersistenceFault,
    DateTime Function()? clock,
    TaskWakeTimerFactory? wakeTimerFactory,
  }) : workspaceGate = workspaceGate ?? WorkspaceExecutionGate(),
       _clock = clock ?? DateTime.now,
       _wakeTimerFactory = wakeTimerFactory ?? DartTaskWakeTimer.new {
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
  final WorkspaceExecutionGate workspaceGate;
  final LocalRuntimeRegistry? runtimeRegistry;
  final RetryPolicy retryPolicy;
  final void Function(TaskPersistenceStalledException error)?
  onPersistenceFault;
  final DateTime Function() _clock;
  final TaskWakeTimerFactory _wakeTimerFactory;
  final Set<String> _activeTaskIds = <String>{};
  final Map<String, String> _serialKeysByTaskId = <String, String>{};
  final Set<Future<void>> _activeRuns = <Future<void>>{};
  final Set<Future<void>> _activeDrains = <Future<void>>{};
  bool _started = false;
  bool _dispatchEnabled = false;
  bool _disposed = false;
  bool _drainScheduled = false;
  bool _draining = false;
  TaskWakeTimer? _retryWakeTimer;
  TaskWakeTimer? _refreshRetryTimer;
  TaskWakeTimer? _runtimeWakeTimer;
  DateTime? _retryWakeAt;
  Future<void>? _shutdownFuture;
  Future<void>? _faultCancellation;
  TaskPersistenceStalledException? _persistenceFault;

  bool get isStarted => _started;

  int get activeCount => _activeTaskIds.length;

  TaskPersistenceStalledException? get persistenceFault => _persistenceFault;

  void handlePersistenceFault(TaskPersistenceStalledException error) {
    _stopForPersistenceFault(error);
  }

  Future<void> start({bool dispatchQueuedTasks = true}) async {
    _ensureNotDisposed();
    if (_started) return;
    try {
      await taskController.load();
      await taskController.recoverInterruptedRuns();
    } on TaskPersistenceStalledException catch (error) {
      _stopForPersistenceFault(error);
      rethrow;
    }
    _ensureNotDisposed();
    if (_started) return;
    _started = true;
    _dispatchEnabled = dispatchQueuedTasks;
    taskController.addListener(_onTaskControllerChanged);
    runtimeRegistry?.addListener(_onRuntimeRegistryChanged);
    _scheduleDrain();
  }

  void startDispatching() {
    _ensureNotDisposed();
    if (!_started) {
      throw StateError('TaskScheduler has not started.');
    }
    _dispatchEnabled = true;
    _scheduleDrain();
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _dispatchEnabled = false;
    _retryWakeTimer?.cancel();
    _retryWakeTimer = null;
    _refreshRetryTimer?.cancel();
    _refreshRetryTimer = null;
    _runtimeWakeTimer?.cancel();
    _runtimeWakeTimer = null;
    _retryWakeAt = null;
    taskController.removeListener(_onTaskControllerChanged);
    runtimeRegistry?.removeListener(_onRuntimeRegistryChanged);
  }

  void dispose() {
    unawaited(shutdown());
  }

  Future<void> shutdown() {
    return _shutdownFuture ??= _shutdown();
  }

  Future<void> _shutdown() async {
    if (!_disposed) {
      stop();
      _disposed = true;
    }
    final persistenceCancellation = _faultCancellation;
    final cancellableWorker = worker;
    if (persistenceCancellation != null) {
      await _ignoreErrors(persistenceCancellation);
    } else if (cancellableWorker is CancellableTaskWorker) {
      try {
        await cancellableWorker.cancelActive();
      } on Object {
        // Active runs are still awaited before their persistence is closed.
      }
    }
    while (_drainScheduled ||
        _activeDrains.isNotEmpty ||
        _activeRuns.isNotEmpty) {
      final active = <Future<void>>[..._activeDrains, ..._activeRuns];
      if (active.isEmpty) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      await Future.wait(active.map(_ignoreErrors));
    }
    final disposableWorker = worker;
    if (disposableWorker is DisposableTaskWorker) {
      try {
        await disposableWorker.dispose();
      } on Object {
        // Task persistence is already settled; worker cleanup is best effort.
      }
    }
  }

  Future<TaskRecord> enqueueTask(String taskId) async {
    _throwIfPersistenceFaulted();
    _ensureNotDisposed();
    final existing = taskController.taskById(taskId);
    if (existing == null) throw StateError('Task not found: $taskId');
    final resettingAuthentication =
        existing.status == TaskStatus.blockedOnUserInput &&
        existing.metadata['failure_reason'] ==
            TaskFailureReason.authRequired.name;
    if (resettingAuthentication) {
      final resettableWorker = worker;
      if (resettableWorker is ResettableTaskWorker) {
        await resettableWorker.resetAgent(existing.agentName);
      }
    }
    final queued = await taskController.updateTask(
      taskId,
      status: TaskStatus.queued,
      summary: 'Queued for agent run.',
      error: null,
      metadata: resettingAuthentication
          ? _runtimeFailureMetadataCleared(existing.metadata)
          : _retryMetadataCleared(existing.metadata),
    );
    _scheduleDrain();
    return queued;
  }

  Future<bool> authenticateAgent(String agentName, String methodId) async {
    _throwIfPersistenceFaulted();
    _ensureNotDisposed();
    final authenticatableWorker = worker;
    if (authenticatableWorker is! AuthenticatableTaskWorker) return false;
    final authenticated = await authenticatableWorker.authenticateAgent(
      agentName,
      methodId,
    );
    if (!authenticated) return false;
    final registry = runtimeRegistry;
    if (registry != null) {
      try {
        await registry.probeAgent(agentName);
      } on Object {
        _scheduleRuntimeWake();
      }
    }
    _scheduleDrain();
    return true;
  }

  void _onTaskControllerChanged() {
    _scheduleDrain();
  }

  void _onRuntimeRegistryChanged() {
    if (_draining) return;
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (!_started || !_dispatchEnabled || _disposed || _drainScheduled) return;
    _drainScheduled = true;
    scheduleMicrotask(() {
      _drainScheduled = false;
      final activeDrain = _drain();
      _activeDrains.add(activeDrain);
      unawaited(
        activeDrain.then<void>(
          (_) => _activeDrains.remove(activeDrain),
          onError: (Object _, StackTrace _) {
            _activeDrains.remove(activeDrain);
          },
        ),
      );
    });
  }

  Future<void> _drain() async {
    if (!_started || !_dispatchEnabled || _disposed || _draining) return;
    _draining = true;
    try {
      try {
        await taskController.refreshIfChanged();
      } on TaskPersistenceStalledException catch (error) {
        _stopForPersistenceFault(error);
        return;
      } on Object {
        _scheduleRefreshRetry();
        return;
      }
      if (!_started || !_dispatchEnabled || _disposed) return;
      try {
        await _requeueAuthenticatedTasks();
      } on TaskPersistenceStalledException catch (error) {
        _stopForPersistenceFault(error);
        return;
      } on Object {
        _scheduleRefreshRetry();
        return;
      }
      if (!_started || !_dispatchEnabled || _disposed) return;
      final deferredTaskIds = <String>{};
      while (_started &&
          _dispatchEnabled &&
          !_disposed &&
          _activeTaskIds.length < maxConcurrentTasks) {
        final task = _nextQueuedTask(deferredTaskIds);
        if (task == null) return;
        _TaskDispatchRoute route;
        try {
          route = _dispatchRouteFor(task);
        } on Object {
          deferredTaskIds.add(task.id);
          _scheduleRefreshRetry();
          continue;
        }
        LocalRuntimeStatus? runtimeStatus;
        try {
          runtimeStatus = await _runtimeStatusFor(task);
        } on Object {
          deferredTaskIds.add(task.id);
          _scheduleRuntimeWake();
          continue;
        }
        if (!_started || !_dispatchEnabled || _disposed) return;
        if (runtimeStatus?.availability == RuntimeAvailability.busy) {
          deferredTaskIds.add(task.id);
          _scheduleRuntimeWake();
          continue;
        }
        final serialKey = route.serialKey;
        if (serialKey.isNotEmpty &&
            !workspaceGate.tryAcquire(serialKey, task.id)) {
          return;
        }
        if (serialKey.isNotEmpty) {
          _serialKeysByTaskId[task.id] = serialKey;
        }
        TaskWorkerLease? workerLease;
        if (!_isRuntimeBlocked(runtimeStatus)) {
          final reservableWorker = worker;
          if (reservableWorker is ReservableTaskWorker) {
            try {
              workerLease = await reservableWorker.tryAcquire(task);
            } on Object {
              _releaseTask(task);
              deferredTaskIds.add(task.id);
              _scheduleRuntimeWake();
              continue;
            }
            if (!_started || !_dispatchEnabled || _disposed) {
              await _releaseWorkerLease(workerLease);
              _releaseTask(task);
              return;
            }
            if (workerLease == null) {
              _releaseTask(task);
              deferredTaskIds.add(task.id);
              _scheduleRuntimeWake();
              continue;
            }
          }
        }
        _activeTaskIds.add(task.id);

        try {
          final dispatched = await _dispatchTask(
            task,
            expectedResource: route.expectedResource,
          );
          if (dispatched == null) {
            await _releaseWorkerLease(workerLease);
            _releaseTask(task);
            deferredTaskIds.add(task.id);
            _scheduleRuntimeWake();
            continue;
          }
          if (_isRuntimeBlocked(runtimeStatus)) {
            await _handleRuntimeBlocked(dispatched, runtimeStatus!);
            await _releaseWorkerLease(workerLease);
            _releaseTask(dispatched);
            continue;
          }
          if (!_started || !_dispatchEnabled || _disposed) {
            await _releaseWorkerLease(workerLease);
            _releaseTask(dispatched);
            return;
          }
          final activeRun = _runTask(dispatched, workerLease);
          workerLease = null;
          _activeRuns.add(activeRun);
          unawaited(
            activeRun.then<void>(
              (_) => _activeRuns.remove(activeRun),
              onError: (Object _, StackTrace _) {
                _activeRuns.remove(activeRun);
              },
            ),
          );
        } on TaskPersistenceStalledException catch (error) {
          await _releaseWorkerLease(workerLease);
          _releaseTask(task);
          _stopForPersistenceFault(error);
          return;
        } on TaskRepositoryConflict {
          await _releaseWorkerLease(workerLease);
          _releaseTask(task);
          deferredTaskIds.add(task.id);
          try {
            await taskController.refreshIfChanged();
          } on TaskPersistenceStalledException catch (error) {
            _stopForPersistenceFault(error);
            return;
          } on Object {
            _scheduleRefreshRetry();
          }
          _scheduleRuntimeWake();
        } catch (_) {
          await _releaseWorkerLease(workerLease);
          _releaseTask(task);
          deferredTaskIds.add(task.id);
          _scheduleRefreshRetry();
        }
      }
    } finally {
      _draining = false;
    }
  }

  void _scheduleRefreshRetry() {
    if (!_started || !_dispatchEnabled || _disposed) return;
    final existing = _refreshRetryTimer;
    if (existing != null && existing.isActive) return;
    _refreshRetryTimer = _wakeTimerFactory(
      const Duration(milliseconds: 250),
      () {
        _refreshRetryTimer = null;
        _scheduleDrain();
      },
    );
  }

  void _scheduleRuntimeWake() {
    if (!_started || !_dispatchEnabled || _disposed) return;
    final existing = _runtimeWakeTimer;
    if (existing != null && existing.isActive) return;
    _runtimeWakeTimer = _wakeTimerFactory(
      const Duration(milliseconds: 250),
      () {
        _runtimeWakeTimer = null;
        _scheduleDrain();
      },
    );
  }

  TaskRecord? _nextQueuedTask(Set<String> deferredTaskIds) {
    final queued = taskController.tasks
        .where(
          (task) =>
              task.status == TaskStatus.queued &&
              !deferredTaskIds.contains(task.id) &&
              !_activeTaskIds.contains(task.id) &&
              !workspaceGate.isLocked(_serialGateKey(task)) &&
              _retryReady(task),
        )
        .toList(growable: false);
    if (queued.isEmpty) return null;
    queued.sort(_compareQueuedTasks);
    return queued.first;
  }

  bool _retryReady(TaskRecord task) {
    final nextRetryAt = _nextRetryAt(task);
    if (nextRetryAt == null) return true;
    final now = _clock();
    if (!nextRetryAt.isAfter(now)) return true;
    _scheduleRetryWake(nextRetryAt);
    return false;
  }

  DateTime? _nextRetryAt(TaskRecord task) {
    final raw = task.metadata['next_retry_at'];
    if (raw is! String || raw.trim().isEmpty) return null;
    return DateTime.tryParse(raw.trim())?.toLocal();
  }

  void _scheduleRetryWake(DateTime wakeAt) {
    if (!_started || !_dispatchEnabled || _disposed) return;
    final delay = wakeAt.difference(_clock());
    if (delay <= Duration.zero) {
      _scheduleDrain();
      return;
    }
    final existing = _retryWakeTimer;
    final existingWakeAt = _retryWakeAt;
    if (existing != null &&
        existing.isActive &&
        existingWakeAt != null &&
        !wakeAt.isBefore(existingWakeAt)) {
      return;
    }
    existing?.cancel();
    _retryWakeAt = wakeAt;
    _retryWakeTimer = _wakeTimerFactory(delay, () {
      _retryWakeTimer = null;
      _retryWakeAt = null;
      _scheduleDrain();
    });
  }

  Future<TaskRecord?> _dispatchTask(
    TaskRecord task, {
    required WorkspaceResource? expectedResource,
  }) async {
    final claim = await taskController.claimTask(
      task,
      expectedResource: expectedResource,
    );
    return claim?.task;
  }

  Future<void> _requeueAuthenticatedTasks() async {
    if (runtimeRegistry == null) return;
    final blocked = taskController.tasks
        .where(
          (task) =>
              task.status == TaskStatus.blockedOnUserInput &&
              task.metadata['failure_reason'] ==
                  TaskFailureReason.authRequired.name,
        )
        .toList(growable: false);
    for (final task in blocked) {
      LocalRuntimeStatus status;
      try {
        status = (await _runtimeStatusFor(task))!;
      } on Object {
        _scheduleRuntimeWake();
        continue;
      }
      if (!_started || !_dispatchEnabled || _disposed) return;
      if (status.availability != RuntimeAvailability.available) {
        _scheduleRuntimeWake();
        continue;
      }
      await taskController.updateTask(
        task.id,
        status: TaskStatus.queued,
        sessionId: null,
        currentRunId: null,
        summary: 'Authentication completed. Queued for retry.',
        error: null,
        metadata: _runtimeFailureMetadataCleared(task.metadata),
      );
    }
  }

  Future<LocalRuntimeStatus?> _runtimeStatusFor(TaskRecord task) async {
    final registry = runtimeRegistry;
    if (registry == null) return null;
    return registry.probeAgent(task.agentName);
  }

  bool _isRuntimeBlocked(LocalRuntimeStatus? status) {
    return switch (status?.availability) {
      RuntimeAvailability.unavailable ||
      RuntimeAvailability.authRequired ||
      RuntimeAvailability.misconfigured => true,
      RuntimeAvailability.unknown ||
      RuntimeAvailability.available ||
      RuntimeAvailability.busy ||
      null => false,
    };
  }

  Future<void> _handleRuntimeBlocked(
    TaskRecord task,
    LocalRuntimeStatus status,
  ) async {
    final run = _currentRunFor(task);
    if (run == null) return;
    final reason = _failureReasonForRuntime(status);
    final label = taskFailureReasonLabel(reason);
    final detail = status.unavailableReason;
    final message = detail == null || detail.isEmpty
        ? '$label for ${task.agentName}.'
        : '$label for ${task.agentName}: $detail';

    await taskController.updateRun(
      run.id,
      status: TaskStatus.failed,
      endedAt: _clock(),
      error: message,
    );
    await taskController.appendEvent(
      taskId: task.id,
      runId: run.id,
      kind: TaskEventKind.system,
      text: message,
      metadata: <String, Object?>{
        'runtime_availability': status.availability.name,
        'failure_reason': reason.name,
        'unavailable_reason': detail,
      },
    );

    if (retryPolicy.shouldRetry(reason, run.attempt)) {
      await _queueRetry(task, run, reason, message);
      return;
    }

    await taskController.updateTask(
      task.id,
      status: reason == TaskFailureReason.authRequired
          ? TaskStatus.blockedOnUserInput
          : TaskStatus.failed,
      summary: message,
      error: message,
      metadata: _failureMetadata(task.metadata, reason, status: status),
    );
    if (reason == TaskFailureReason.authRequired) {
      _scheduleRuntimeWake();
    }
  }

  TaskFailureReason _failureReasonForRuntime(LocalRuntimeStatus status) {
    return switch (status.availability) {
      RuntimeAvailability.authRequired => TaskFailureReason.authRequired,
      RuntimeAvailability.unavailable ||
      RuntimeAvailability.misconfigured => TaskFailureReason.runtimeOffline,
      RuntimeAvailability.unknown ||
      RuntimeAvailability.available ||
      RuntimeAvailability.busy => TaskFailureReason.agentError,
    };
  }

  Future<void> _runTask(TaskRecord task, TaskWorkerLease? workerLease) async {
    try {
      final currentTask = taskController.taskById(task.id) ?? task;
      final result = workerLease == null
          ? await worker.run(currentTask)
          : await workerLease.run(currentTask);
      await _handleWorkerResult(result);
    } on TaskPersistenceStalledException catch (error) {
      _stopForPersistenceFault(error);
    } catch (error) {
      try {
        await _handleWorkerError(task, error);
      } on TaskPersistenceStalledException catch (persistenceError) {
        _stopForPersistenceFault(persistenceError);
      }
    } finally {
      await _releaseWorkerLease(workerLease);
      _releaseTask(task);
      _scheduleDrain();
    }
  }

  Future<void> _releaseWorkerLease(TaskWorkerLease? lease) async {
    if (lease == null) return;
    try {
      await lease.release();
    } on Object {
      // A released task must not retain scheduler capacity on cleanup errors.
    }
  }

  Future<void> _handleWorkerResult(TaskRecord result) async {
    if (result.status == TaskStatus.failed) {
      await _maybeRetryFailedTask(result);
      return;
    }
    await _finalizeRunIfNeeded(result);
  }

  Future<void> _handleWorkerError(TaskRecord task, Object error) async {
    final message = _messageForError(error);
    final run = _currentRunFor(task);
    if (run != null) {
      await taskController.updateRun(
        run.id,
        status: TaskStatus.failed,
        endedAt: _clock(),
        error: message,
      );
      await taskController.appendEvent(
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Task run failed: $message',
      );
    }
    final failed = await taskController.updateTask(
      task.id,
      status: TaskStatus.failed,
      error: message,
    );
    await _maybeRetryFailedTask(failed);
  }

  Future<void> _maybeRetryFailedTask(TaskRecord task) async {
    final run = _currentRunFor(task);
    final reason = taskFailureReasonFromText(task.error ?? task.summary);
    if (reason == TaskFailureReason.authRequired) {
      final message = task.error ?? taskFailureReasonLabel(reason);
      await taskController.updateTask(
        task.id,
        status: TaskStatus.blockedOnUserInput,
        summary: message,
        error: message,
        metadata: _failureMetadata(task.metadata, reason),
      );
      _scheduleRuntimeWake();
      return;
    }
    if (run != null && retryPolicy.shouldRetry(reason, run.attempt)) {
      await _queueRetry(
        task,
        run,
        reason,
        task.error ?? task.summary ?? taskFailureReasonLabel(reason),
      );
      return;
    }
    await taskController.updateTask(
      task.id,
      metadata: _failureMetadata(task.metadata, reason),
    );
  }

  Future<void> _queueRetry(
    TaskRecord task,
    TaskRunRecord run,
    TaskFailureReason reason,
    String message,
  ) async {
    final delay = retryPolicy.delayForAttempt(run.attempt);
    final nextRetryAt = _clock().add(delay);
    final queued = await taskController.retryTask(
      task.id,
      rationale: 'Retrying after ${taskFailureReasonLabel(reason)}.',
    );
    await taskController.updateTask(
      queued.id,
      status: TaskStatus.queued,
      summary: delay == Duration.zero
          ? 'Queued for retry after ${taskFailureReasonLabel(reason)}.'
          : '${taskFailureReasonLabel(reason)}. Retrying at '
                '${nextRetryAt.toIso8601String()}.',
      error: null,
      metadata: _failureMetadata(
        queued.metadata,
        reason,
        nextRetryAt: delay == Duration.zero ? null : nextRetryAt,
        message: message,
      ),
    );
  }

  Future<void> _finalizeRunIfNeeded(TaskRecord task) async {
    final run = _currentRunFor(task);
    if (run == null) return;
    if (run.status != TaskStatus.dispatched &&
        run.status != TaskStatus.running) {
      return;
    }
    if (!_isCompletedStatus(task.status)) return;
    await taskController.updateRun(
      run.id,
      status: task.status,
      endedAt: _clock(),
      error: task.error,
    );
  }

  bool _isCompletedStatus(TaskStatus status) {
    return switch (status) {
      TaskStatus.needsHumanReview ||
      TaskStatus.approvedForExport ||
      TaskStatus.exporting ||
      TaskStatus.done ||
      TaskStatus.failed ||
      TaskStatus.cancelled ||
      TaskStatus.rejected ||
      TaskStatus.needsChanges => true,
      _ => false,
    };
  }

  TaskRunRecord? _currentRunFor(TaskRecord task) {
    final runId = task.currentRunId?.trim();
    if (runId == null || runId.isEmpty) return null;
    for (final run in taskController.runs) {
      if (run.id == runId && run.taskId == task.id) return run;
    }
    return null;
  }

  Map<String, Object?> _failureMetadata(
    Map<String, Object?> existing,
    TaskFailureReason reason, {
    LocalRuntimeStatus? status,
    DateTime? nextRetryAt,
    String? message,
  }) {
    return <String, Object?>{
      ..._retryMetadataCleared(existing),
      'failure_reason': reason.name,
      if (status != null) 'runtime_availability': status.availability.name,
      if (status?.unavailableReason != null)
        'unavailable_reason': status!.unavailableReason,
      if (nextRetryAt != null) 'next_retry_at': nextRetryAt.toIso8601String(),
      if (message != null && message.trim().isNotEmpty)
        'last_failure_message': message.trim(),
    };
  }

  Map<String, Object?> _retryMetadataCleared(Map<String, Object?> existing) {
    return <String, Object?>{
      for (final entry in existing.entries)
        if (entry.key != 'next_retry_at') entry.key: entry.value,
    };
  }

  Map<String, Object?> _runtimeFailureMetadataCleared(
    Map<String, Object?> existing,
  ) {
    const removed = <String>{
      'failure_reason',
      'runtime_availability',
      'unavailable_reason',
      'last_failure_message',
      'next_retry_at',
    };
    return <String, Object?>{
      for (final entry in existing.entries)
        if (!removed.contains(entry.key)) entry.key: entry.value,
    };
  }

  void _releaseTask(TaskRecord task) {
    _activeTaskIds.remove(task.id);
    final serialKey = _serialKeysByTaskId.remove(task.id);
    if (serialKey != null) workspaceGate.release(serialKey, task.id);
  }

  String _serialGateKey(TaskRecord task) {
    return serialGateKeyForTask(task, taskController.snapshot.resources);
  }

  _TaskDispatchRoute _dispatchRouteFor(TaskRecord task) {
    WorkspaceResource? expectedResource;
    final resourceId = task.resourceId;
    if (resourceId != null) {
      for (final resource in taskController.snapshot.resources) {
        if (resource.id == resourceId) {
          expectedResource = resource;
          break;
        }
      }
      if (expectedResource == null) {
        throw StateError('Task references missing resource: $resourceId');
      }
    }
    return _TaskDispatchRoute(
      expectedResource: expectedResource,
      serialKey: serialGateKeyForTask(
        task,
        expectedResource == null
            ? const <WorkspaceResource>[]
            : <WorkspaceResource>[expectedResource],
      ),
    );
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

  void _stopForPersistenceFault(TaskPersistenceStalledException error) {
    if (_persistenceFault != null) return;
    _persistenceFault = error;
    stop();
    final cancellableWorker = worker;
    if (cancellableWorker is CancellableTaskWorker) {
      final cancellation = Future<void>.sync(cancellableWorker.cancelActive);
      _faultCancellation = cancellation;
      unawaited(_ignoreErrors(cancellation));
    }
    try {
      onPersistenceFault?.call(error);
    } on Object {
      // A presentation callback must not prevent runtime cancellation.
    }
  }

  void _throwIfPersistenceFaulted() {
    final fault = _persistenceFault;
    if (fault != null) throw fault;
  }
}

class _TaskDispatchRoute {
  const _TaskDispatchRoute({
    required this.expectedResource,
    required this.serialKey,
  });

  final WorkspaceResource? expectedResource;
  final String serialKey;
}

Future<void> _ignoreErrors(Future<void> future) async {
  try {
    await future;
  } on Object {
    // Shutdown is responsible for draining work, not re-reporting run errors.
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
