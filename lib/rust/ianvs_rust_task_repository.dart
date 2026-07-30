import 'dart:async';
import 'dart:convert';

import '../tasks/runtime_registry.dart';
import '../tasks/task_inbox_snapshot.dart';
import '../tasks/task_record.dart';
import '../tasks/task_repository.dart';
import '../tasks/workspace_resource.dart';
import 'ianvs_workflow_native.dart';

/// TaskInbox repository adapter whose only durable authority is Rust Core.
///
/// Dart retains a complete immutable projection for rendering and optimistic
/// expectation checks. Every mutation is a typed Rust product operation; this
/// class never writes ACP JSON or a second TaskInbox database.
final class IanvsRustTaskRepository
    implements
        TaskRepository,
        AuthoritativeTaskRepositoryProjection,
        AtomicTaskSchedulingRepository,
        ExecutorLeaseTaskRepository,
        RuntimeEventTaskRepository {
  IanvsRustTaskRepository({
    required this.databasePath,
    required this.bootstrapSnapshot,
    required this.sourceChecksum,
    IanvsWorkflowAuthority? authority,
  }) : _authority = authority ?? IanvsRustWorkflow() {
    if (databasePath.trim().isEmpty) {
      throw ArgumentError.value(
        databasePath,
        'databasePath',
        'must not be empty',
      );
    }
    if (sourceChecksum.trim().isEmpty) {
      throw ArgumentError.value(
        sourceChecksum,
        'sourceChecksum',
        'must not be empty',
      );
    }
  }

  final String databasePath;
  final TaskInboxSnapshot bootstrapSnapshot;
  final String sourceChecksum;
  final IanvsWorkflowAuthority _authority;

  TaskRepositorySnapshot? _projection;
  Future<void>? _initializeFuture;
  bool _closed = false;

  Future<void> configureStorage({
    required int maxDatabaseBytes,
    required int retentionDays,
  }) async {
    final authority = _authority;
    if (authority is! IanvsStoragePolicyAuthority) return;
    await (authority as IanvsStoragePolicyAuthority).configureStorage(
      maxDatabaseBytes: maxDatabaseBytes,
      retentionDays: retentionDays,
    );
  }

  @override
  TaskRepositorySnapshot get authoritativeProjection =>
      _projection ?? (throw StateError('Rust TaskInbox is not initialized.'));

  @override
  Future<void> initialize() {
    _ensureNotClosed();
    return _initializeFuture ??= Future<void>.sync(_initializeOnce);
  }

  Future<void> _initializeOnce() async {
    final opened = await _authority.open(databasePath);
    switch (opened.migration.phase) {
      case IanvsWorkflowMigrationPhase.native:
        await _authority.stageTaskInbox(
          source: bootstrapSnapshot,
          sourceChecksum: sourceChecksum,
        );
        await _authority.materializeTaskInbox();
        _setMaterialized(await _authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.staged:
        _requireMatchingImport(opened.migration);
        await _authority.materializeTaskInbox();
        _setMaterialized(await _authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.ready:
        _requireMatchingImport(opened.migration);
        _setMaterialized(await _authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.active:
        final current = await _authority.currentTaskInbox();
        if (current == null) {
          throw StateError('Active Rust workflow has no TaskInbox projection.');
        }
        _projection = TaskRepositorySnapshot(
          revision: opened.revision,
          snapshot: current,
        );
    }
  }

  void _requireMatchingImport(IanvsWorkflowMigration migration) {
    if (migration.sourceChecksum != sourceChecksum) {
      throw StateError(
        'Rust TaskInbox import checksum mismatch: '
        '${migration.sourceChecksum} != $sourceChecksum.',
      );
    }
  }

  @override
  Future<TaskRepositorySnapshot> loadRepository() async {
    await initialize();
    await _refreshProjection();
    return authoritativeProjection;
  }

  @override
  Future<TaskRecord> insertTask(TaskRecord task) {
    return _mutate(() async {
      await _commit(
        _authority.applyTaskInbox(IanvsTaskInboxCommand.createTask(task)),
      );
      return _task(task.id);
    });
  }

  @override
  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      _expectTask(expected);
      final definitionChanged =
          task.workspacePath != expected.workspacePath ||
          task.agentName != expected.agentName;
      if (definitionChanged) {
        if (task.status != expected.status) {
          throw const TaskRepositoryConflict(
            'Task definition and authority status cannot change together.',
          );
        }
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.updateTaskDefinition(
              task: task,
              updatedAt: task.updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      } else if (task.status == expected.status) {
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.updateTaskProjection(
              task: task,
              updatedAt: task.updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      } else if (task.status == TaskStatus.queued) {
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.queueTaskProjection(
              task: task,
              updatedAt: task.updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      } else if (task.status == TaskStatus.cancelled) {
        final run = _currentRun(
          expected,
        )?.copyWith(status: TaskStatus.cancelled, endedAt: task.updatedAt);
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.cancelTaskProjection(
              task: task,
              run: run,
              updatedAt: task.updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      } else {
        final currentRun = _currentRun(expected);
        if (currentRun == null) {
          throw TaskRepositoryConflict(
            'Task ${task.id} cannot transition without a current run.',
          );
        }
        final transition = _transition(currentRun.status, task.status);
        final run = currentRun.copyWith(
          status: task.status,
          endedAt: _terminalStatus(task.status)
              ? task.updatedAt
              : currentRun.endedAt,
          error: task.error ?? currentRun.error,
        );
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.transitionRunProjection(
              task: task,
              run: run,
              transition: transition,
              updatedAt: task.updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      }
      return _task(task.id);
    });
  }

  @override
  Future<void> deleteTask(
    TaskDeleteExpectation expected, {
    required DateTime updatedAt,
  }) {
    return _mutate(() async {
      _expectTask(expected.task);
      await _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.deleteTask(
            taskId: expected.task.id,
            updatedAt: updatedAt,
          ),
        ),
      );
    });
  }

  @override
  Future<TaskRunCreation> createRun({
    required TaskRecord expectedTask,
    required TaskRecord task,
    required TaskRunRecord run,
  }) {
    return _mutate(() async {
      _expectTask(expectedTask);
      if (run.status != TaskStatus.dispatched ||
          task.status != TaskStatus.dispatched) {
        throw const TaskRepositoryConflict(
          'Rust run creation must enter the dispatched state.',
        );
      }
      await _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.dispatchRunProjection(
            task: task,
            run: run,
            updatedAt: task.updatedAt,
          ),
        ),
      );
      return TaskRunCreation(task: _task(task.id), run: _run(run.id));
    });
  }

  @override
  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  }) async {
    await initialize();
    _expectTask(expectedTask);
    final excluded = authoritativeProjection.snapshot.tasks
        .where((task) => task.id != expectedTask.id)
        .map((task) => task.id)
        .toSet();
    final poll = await claimNextTask(
      runId: run.id,
      dispatchEventId: dispatchEvent.id,
      executorLeaseId: 'executor-${run.id}',
      executorId: 'repository-adapter',
      commandId: 'claim-${run.id}',
      now: run.startedAt,
      leaseExpiresAt: run.startedAt.add(const Duration(minutes: 1)),
      excludedTaskIds: excluded,
    );
    return poll.claim?.task.id == expectedTask.id ? poll.claim : null;
  }

  @override
  Future<TaskRunRecord> updateRun(
    TaskRunRecord run, {
    required TaskRunRecord expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      _expectRun(expected);
      if (run.status == expected.status) {
        await _commit(
          _applyTaskInbox(
            IanvsTaskInboxCommand.updateRunProjection(
              run: run,
              updatedAt: updatedAt,
            ),
            executorContext: executorContext,
          ),
        );
      } else {
        final task = _task(expected.taskId);
        if (run.status == TaskStatus.cancelled) {
          await _commit(
            _applyTaskInbox(
              IanvsTaskInboxCommand.cancelTaskProjection(
                task: task.copyWith(
                  status: TaskStatus.cancelled,
                  updatedAt: updatedAt,
                ),
                run: run,
                updatedAt: updatedAt,
              ),
              executorContext: executorContext,
            ),
          );
        } else {
          await _commit(
            _applyTaskInbox(
              IanvsTaskInboxCommand.transitionRunProjection(
                task: task.copyWith(status: run.status, updatedAt: updatedAt),
                run: run,
                transition: _transition(expected.status, run.status),
                updatedAt: updatedAt,
              ),
              executorContext: executorContext,
            ),
          );
        }
      }
      return _run(run.id);
    });
  }

  @override
  Future<void> appendEvents(
    List<TaskEventRecord> events, {
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      await _commit(
        _applyTaskInbox(
          IanvsTaskInboxCommand.appendEvents(
            events: events,
            updatedAt: updatedAt,
          ),
          executorContext: executorContext,
        ),
      );
    });
  }

  @override
  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      _expectArtifacts(expectedArtifacts, taskId: taskId, runId: runId);
      await _commit(
        _applyTaskInbox(
          IanvsTaskInboxCommand.replaceArtifacts(
            taskId: taskId,
            runId: runId,
            artifacts: artifacts,
            updatedAt: updatedAt,
          ),
          executorContext: executorContext,
        ),
      );
    });
  }

  @override
  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      if (!_recordsEqual(
        authoritativeProjection.snapshot.artifacts,
        expectedArtifacts,
      )) {
        throw const TaskRepositoryConflict('Artifact projection is stale.');
      }
      await _commit(
        _applyTaskInbox(
          IanvsTaskInboxCommand.replaceArtifactSet(
            artifacts: artifacts,
            updatedAt: updatedAt,
          ),
          executorContext: executorContext,
        ),
      );
    });
  }

  @override
  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  }) {
    return _mutate(() async {
      final current = _approvalOrNull(approval.id);
      if (!_recordEqual(current, expected)) {
        throw const TaskRepositoryConflict('Approval projection is stale.');
      }
      await _commit(
        _applyTaskInbox(
          IanvsTaskInboxCommand.upsertApproval(
            approval: approval,
            updatedAt: updatedAt,
          ),
          executorContext: executorContext,
        ),
      );
    });
  }

  @override
  Future<void> upsertResource(
    WorkspaceResource resource, {
    WorkspaceResource? expected,
    required DateTime updatedAt,
  }) {
    return _mutate(() async {
      final current = _resourceOrNull(resource.id);
      if (!_recordEqual(current, expected)) {
        throw const TaskRepositoryConflict('Resource projection is stale.');
      }
      await _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.upsertResource(
            resource: resource,
            updatedAt: updatedAt,
          ),
        ),
      );
    });
  }

  @override
  Future<int> revision() async {
    await initialize();
    await _refreshProjection();
    return authoritativeProjection.revision;
  }

  Future<void> _refreshProjection() async {
    final current = await _authority.currentTaskInboxProjection();
    if (current == null) {
      throw StateError('Active Rust workflow has no TaskInbox projection.');
    }
    _setMaterialized(current);
  }

  @override
  Future<void> configureScheduler({required int maxConcurrentTasks}) {
    return _mutate(() async {
      await _authority.configureScheduler(
        maxConcurrentTasks: maxConcurrentTasks,
      );
    });
  }

  @override
  Future<void> publishRuntimeStatus(LocalRuntimeStatus status) {
    return _mutate(() async {
      await _authority.setSchedulerRuntimeStatus(
        IanvsSchedulerRuntimeStatus(
          agentName: status.agentName,
          availability: _runtimeAvailability(status.availability),
          observedAt: status.checkedAt,
          unavailableReason: status.unavailableReason,
          supportsSessionResume: status.supportsSessionResume,
          supportsPermissions: status.supportsPermissions,
          maxConcurrentTasks: status.maxConcurrentTasks,
        ),
      );
    });
  }

  @override
  Future<TaskSchedulingPoll> claimNextTask({
    required String runId,
    required String dispatchEventId,
    required String executorLeaseId,
    required String executorId,
    required String commandId,
    required DateTime now,
    required DateTime leaseExpiresAt,
    Set<String> excludedTaskIds = const <String>{},
    List<TaskCapacityReservation> capacityReservations =
        const <TaskCapacityReservation>[],
  }) {
    return _mutate(() async {
      final projected = await _authority.schedulerClaimNext(
        runId: runId,
        dispatchEventId: dispatchEventId,
        executorLeaseId: executorLeaseId,
        executorId: executorId,
        commandId: commandId,
        now: now,
        leaseExpiresAt: leaseExpiresAt,
        excludedTaskIds: excludedTaskIds.toList(growable: false),
        capacityReservations: capacityReservations
            .map(
              (reservation) => IanvsSchedulerCapacityReservation(
                reservationId: reservation.reservationId,
                agentName: reservation.agentName,
                hostInstanceId: reservation.hostInstanceId,
                createdAt: reservation.createdAt,
                expiresAt: reservation.expiresAt,
              ),
            )
            .toList(growable: false),
      );
      _projection = TaskRepositorySnapshot(
        revision: projected.workflow.revision,
        snapshot: projected.taskInbox,
      );
      final claim = projected.claim;
      TaskClaim? taskClaim;
      if (claim != null) {
        taskClaim = TaskClaim(
          task: _task(claim.taskId),
          run: _run(claim.runId),
          dispatchEvent: _event(claim.dispatchEventId),
          reservationId: claim.reservationId,
          executorLease: _executorLease(claim.executorLease),
        );
      }
      return TaskSchedulingPoll(
        repository: authoritativeProjection,
        claim: taskClaim,
        nextWakeAt: projected.nextWakeAt,
        admission: TaskSchedulingAdmission(
          reason: _admissionReason(projected.admission.reason),
          retryable: projected.admission.retryable,
          nextWakeAt: projected.admission.nextWakeAt,
          selectedReservationId: projected.admission.selectedReservationId,
          blockedTaskIds: projected.admission.blockedTaskIds,
        ),
      );
    });
  }

  @override
  Future<TaskExecutorLease?> executorLeaseForRun(String runId) {
    return _mutate(() async {
      final lease = await _authority.executorLeaseForRun(runId);
      return lease == null ? null : _executorLease(lease);
    });
  }

  @override
  Future<TaskRuntimeEventPage> runtimeEvents({
    required String runId,
    required int afterSequence,
    int limit = 200,
  }) {
    return _mutate(() async {
      final page = await _authority.runtimeEvents(
        runId: runId,
        afterSequence: afterSequence,
        limit: limit,
      );
      return TaskRuntimeEventPage(
        runId: page.runId,
        afterSequence: page.afterSequence,
        events: page.events
            .map(
              (stored) => TaskStoredRuntimeEvent(
                sequence: stored.sequence,
                event: stored.event,
                executorLeaseId: stored.executorLeaseId,
                executorGeneration: stored.executorGeneration,
                commandId: stored.commandId,
              ),
            )
            .toList(growable: false),
        nextSequence: page.nextSequence,
        hasMore: page.hasMore,
      );
    });
  }

  @override
  Future<TaskExecutorLease> acknowledgeExecutorStart({
    required TaskExecutorCommandContext context,
    required DateTime nextExpiresAt,
  }) {
    return _executorLeaseCommand(
      context: context,
      operation: IanvsExecutorLeaseOperation.acknowledgeStart,
      nextExpiresAt: nextExpiresAt,
    );
  }

  @override
  Future<TaskExecutorLease> heartbeatExecutor({
    required TaskExecutorCommandContext context,
    required DateTime nextExpiresAt,
  }) {
    return _executorLeaseCommand(
      context: context,
      operation: IanvsExecutorLeaseOperation.heartbeat,
      nextExpiresAt: nextExpiresAt,
    );
  }

  @override
  Future<TaskExecutorLease> releaseExecutor({
    required TaskExecutorCommandContext context,
    bool cancelled = false,
  }) {
    return _executorLeaseCommand(
      context: context,
      operation: cancelled
          ? IanvsExecutorLeaseOperation.cancel
          : IanvsExecutorLeaseOperation.release,
    );
  }

  Future<TaskExecutorLease> _executorLeaseCommand({
    required TaskExecutorCommandContext context,
    required IanvsExecutorLeaseOperation operation,
    DateTime? nextExpiresAt,
  }) {
    return _mutate(() async {
      final lease = await _authority.applyExecutorLeaseCommand(
        IanvsExecutorLeaseCommand(
          context: IanvsExecutorCommandContext(
            runId: context.runId,
            executorLeaseId: context.executorLeaseId,
            generation: context.generation,
            commandId: context.commandId,
            now: context.now,
          ),
          operation: operation,
          nextExpiresAt: nextExpiresAt,
        ),
      );
      return _executorLease(lease);
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _authority.dispose();
  }

  Future<T> _mutate<T>(FutureOr<T> Function() operation) async {
    await initialize();
    try {
      return await operation();
    } on StateError catch (error) {
      final message = error.message.toString();
      if (message.contains('revision') && message.contains('conflict')) {
        throw TaskRepositoryConflict(message);
      }
      rethrow;
    }
  }

  Future<void> _commit(
    FutureOr<IanvsTaskInboxMaterializedProjection> projection,
  ) async {
    _setMaterialized(await projection);
  }

  FutureOr<IanvsTaskInboxMaterializedProjection> _applyTaskInbox(
    IanvsTaskInboxCommand command, {
    TaskExecutorCommandContext? executorContext,
  }) {
    if (executorContext == null) {
      return _authority.applyTaskInbox(command);
    }
    return _authority.applyTaskInboxAsExecutor(
      context: IanvsExecutorCommandContext(
        runId: executorContext.runId,
        executorLeaseId: executorContext.executorLeaseId,
        generation: executorContext.generation,
        commandId: executorContext.commandId,
        now: executorContext.now,
      ),
      command: command,
    );
  }

  void _setMaterialized(IanvsTaskInboxMaterializedProjection projection) {
    _projection = TaskRepositorySnapshot(
      revision: projection.workflow.revision,
      snapshot: projection.taskInbox,
    );
  }

  void _expectTask(TaskRecord expected) {
    if (!_recordEqual(_taskOrNull(expected.id), expected)) {
      throw TaskRepositoryConflict('Task ${expected.id} projection is stale.');
    }
  }

  void _expectRun(TaskRunRecord expected) {
    if (!_recordEqual(_runOrNull(expected.id), expected)) {
      throw TaskRepositoryConflict('Run ${expected.id} projection is stale.');
    }
  }

  void _expectArtifacts(
    List<ArtifactRecord> expected, {
    required String taskId,
    required String runId,
  }) {
    final current = authoritativeProjection.snapshot.artifacts
        .where(
          (artifact) => artifact.taskId == taskId && artifact.runId == runId,
        )
        .toList(growable: false);
    if (!_recordsEqual(current, expected)) {
      throw const TaskRepositoryConflict('Artifact projection is stale.');
    }
  }

  TaskRecord _task(String id) =>
      _taskOrNull(id) ??
      (throw StateError('Rust projection omitted task $id.'));

  TaskRecord? _taskOrNull(String id) {
    for (final task in authoritativeProjection.snapshot.tasks) {
      if (task.id == id) return task;
    }
    return null;
  }

  TaskRunRecord _run(String id) =>
      _runOrNull(id) ?? (throw StateError('Rust projection omitted run $id.'));

  TaskRunRecord? _runOrNull(String id) {
    for (final run in authoritativeProjection.snapshot.runs) {
      if (run.id == id) return run;
    }
    return null;
  }

  TaskRunRecord? _currentRun(TaskRecord task) {
    final runId = task.currentRunId;
    return runId == null ? null : _runOrNull(runId);
  }

  TaskEventRecord _event(String id) {
    for (final event in authoritativeProjection.snapshot.events) {
      if (event.id == id) return event;
    }
    throw StateError('Rust projection omitted event $id.');
  }

  ApprovalRequestRecord? _approvalOrNull(String id) {
    for (final approval in authoritativeProjection.snapshot.approvals) {
      if (approval.id == id) return approval;
    }
    return null;
  }

  WorkspaceResource? _resourceOrNull(String id) {
    for (final resource in authoritativeProjection.snapshot.resources) {
      if (resource.id == id) return resource;
    }
    return null;
  }

  void _ensureNotClosed() {
    if (_closed) throw StateError('Rust TaskInbox repository is closed.');
  }
}

IanvsTaskInboxRunTransition _transition(TaskStatus from, TaskStatus to) {
  return switch ((from, to)) {
    (TaskStatus.dispatched, TaskStatus.running) =>
      IanvsTaskInboxRunTransition.start,
    (TaskStatus.running, TaskStatus.blockedOnPermission) =>
      IanvsTaskInboxRunTransition.waitForPermission,
    (TaskStatus.running, TaskStatus.blockedOnUserInput) =>
      IanvsTaskInboxRunTransition.waitForUserInput,
    (
      TaskStatus.blockedOnPermission || TaskStatus.blockedOnUserInput,
      TaskStatus.running,
    ) =>
      IanvsTaskInboxRunTransition.resume,
    (TaskStatus.running, TaskStatus.collectingArtifacts) =>
      IanvsTaskInboxRunTransition.collectArtifacts,
    (TaskStatus.collectingArtifacts, TaskStatus.needsHumanReview) =>
      IanvsTaskInboxRunTransition.requireHumanReview,
    (TaskStatus.needsHumanReview, TaskStatus.needsChanges) =>
      IanvsTaskInboxRunTransition.requestChanges,
    (
      TaskStatus.collectingArtifacts || TaskStatus.needsHumanReview,
      TaskStatus.done,
    ) =>
      IanvsTaskInboxRunTransition.complete,
    (_, TaskStatus.failed) => IanvsTaskInboxRunTransition.fail,
    (_, TaskStatus.rejected) => IanvsTaskInboxRunTransition.reject,
    _ => throw TaskRepositoryConflict(
      'Unsupported Rust run transition: ${from.name} -> ${to.name}.',
    ),
  };
}

bool _terminalStatus(TaskStatus status) => switch (status) {
  TaskStatus.done ||
  TaskStatus.failed ||
  TaskStatus.cancelled ||
  TaskStatus.rejected ||
  TaskStatus.needsChanges => true,
  _ => false,
};

IanvsSchedulerRuntimeAvailability _runtimeAvailability(
  RuntimeAvailability availability,
) => switch (availability) {
  RuntimeAvailability.unknown => IanvsSchedulerRuntimeAvailability.unknown,
  RuntimeAvailability.available => IanvsSchedulerRuntimeAvailability.available,
  RuntimeAvailability.busy => IanvsSchedulerRuntimeAvailability.busy,
  RuntimeAvailability.unavailable =>
    IanvsSchedulerRuntimeAvailability.unavailable,
  RuntimeAvailability.authRequired =>
    IanvsSchedulerRuntimeAvailability.authRequired,
  RuntimeAvailability.misconfigured =>
    IanvsSchedulerRuntimeAvailability.misconfigured,
};

TaskSchedulingAdmissionReason _admissionReason(
  IanvsSchedulerAdmissionReason reason,
) => switch (reason) {
  IanvsSchedulerAdmissionReason.claimed =>
    TaskSchedulingAdmissionReason.claimed,
  IanvsSchedulerAdmissionReason.queueEmpty =>
    TaskSchedulingAdmissionReason.queueEmpty,
  IanvsSchedulerAdmissionReason.globalCapacity =>
    TaskSchedulingAdmissionReason.globalCapacity,
  IanvsSchedulerAdmissionReason.noExecutorCapacity =>
    TaskSchedulingAdmissionReason.noExecutorCapacity,
  IanvsSchedulerAdmissionReason.agentCapacity =>
    TaskSchedulingAdmissionReason.agentCapacity,
  IanvsSchedulerAdmissionReason.runtimeUnavailable =>
    TaskSchedulingAdmissionReason.runtimeUnavailable,
  IanvsSchedulerAdmissionReason.runtimeStatusStale =>
    TaskSchedulingAdmissionReason.runtimeStatusStale,
  IanvsSchedulerAdmissionReason.workspaceBusy =>
    TaskSchedulingAdmissionReason.workspaceBusy,
  IanvsSchedulerAdmissionReason.retryNotReady =>
    TaskSchedulingAdmissionReason.retryNotReady,
  IanvsSchedulerAdmissionReason.noMatchingRuntime =>
    TaskSchedulingAdmissionReason.noMatchingRuntime,
  IanvsSchedulerAdmissionReason.excluded =>
    TaskSchedulingAdmissionReason.excluded,
};

TaskExecutorLease _executorLease(IanvsExecutorLease lease) => TaskExecutorLease(
  leaseId: lease.leaseId,
  runId: lease.runId,
  executorId: lease.executorId,
  generation: lease.generation,
  reservationId: lease.reservationId,
  acquiredAt: lease.acquiredAt,
  expiresAt: lease.expiresAt,
  lastHeartbeatAt: lease.lastHeartbeatAt,
  startAcknowledgedAt: lease.startAcknowledgedAt,
  releasedAt: lease.releasedAt,
  state: switch (lease.state) {
    IanvsExecutorLeaseState.claimed => TaskExecutorLeaseState.claimed,
    IanvsExecutorLeaseState.starting => TaskExecutorLeaseState.starting,
    IanvsExecutorLeaseState.active => TaskExecutorLeaseState.active,
    IanvsExecutorLeaseState.expired => TaskExecutorLeaseState.expired,
    IanvsExecutorLeaseState.released => TaskExecutorLeaseState.released,
    IanvsExecutorLeaseState.superseded => TaskExecutorLeaseState.superseded,
  },
);

bool _recordEqual(Object? left, Object? right) {
  if (left == null || right == null) return left == right;
  return jsonEncode(_recordJson(left)) == jsonEncode(_recordJson(right));
}

bool _recordsEqual(List<Object> left, List<Object> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (!_recordEqual(left[index], right[index])) return false;
  }
  return true;
}

Object _recordJson(Object record) => switch (record) {
  TaskRecord value => value.toJson(),
  TaskRunRecord value => value.toJson(),
  TaskEventRecord value => value.toJson(),
  ArtifactRecord value => value.toJson(),
  ApprovalRequestRecord value => value.toJson(),
  WorkspaceResource value => value.toJson(),
  _ => throw ArgumentError.value(record, 'record', 'unsupported record type'),
};
