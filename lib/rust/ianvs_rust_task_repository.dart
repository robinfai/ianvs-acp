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
        AtomicTaskSchedulingRepository {
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

  @override
  TaskRepositorySnapshot get authoritativeProjection =>
      _projection ?? (throw StateError('Rust TaskInbox is not initialized.'));

  @override
  Future<void> initialize() {
    _ensureNotClosed();
    return _initializeFuture ??= Future<void>.sync(_initializeOnce);
  }

  void _initializeOnce() {
    final opened = _authority.open(databasePath);
    switch (opened.migration.phase) {
      case IanvsWorkflowMigrationPhase.native:
        _authority.stageTaskInbox(
          source: bootstrapSnapshot,
          sourceChecksum: sourceChecksum,
        );
        _authority.materializeTaskInbox();
        _setMaterialized(_authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.staged:
        _requireMatchingImport(opened.migration);
        _authority.materializeTaskInbox();
        _setMaterialized(_authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.ready:
        _requireMatchingImport(opened.migration);
        _setMaterialized(_authority.activateTaskInbox());
      case IanvsWorkflowMigrationPhase.active:
        final current = _authority.currentTaskInbox();
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
    return authoritativeProjection;
  }

  @override
  Future<TaskRecord> insertTask(TaskRecord task) {
    return _mutate(() {
      _commit(
        _authority.applyTaskInbox(IanvsTaskInboxCommand.createTask(task)),
      );
      return _task(task.id);
    });
  }

  @override
  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
  }) {
    return _mutate(() {
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
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.updateTaskDefinition(
              task: task,
              updatedAt: task.updatedAt,
            ),
          ),
        );
      } else if (task.status == expected.status) {
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.updateTaskProjection(
              task: task,
              updatedAt: task.updatedAt,
            ),
          ),
        );
      } else if (task.status == TaskStatus.queued) {
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.queueTaskProjection(
              task: task,
              updatedAt: task.updatedAt,
            ),
          ),
        );
      } else if (task.status == TaskStatus.cancelled) {
        final run = _currentRun(
          expected,
        )?.copyWith(status: TaskStatus.cancelled, endedAt: task.updatedAt);
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.cancelTaskProjection(
              task: task,
              run: run,
              updatedAt: task.updatedAt,
            ),
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
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.transitionRunProjection(
              task: task,
              run: run,
              transition: transition,
              updatedAt: task.updatedAt,
            ),
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
    return _mutate(() {
      _expectTask(expected.task);
      _commit(
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
    return _mutate(() {
      _expectTask(expectedTask);
      if (run.status != TaskStatus.dispatched ||
          task.status != TaskStatus.dispatched) {
        throw const TaskRepositoryConflict(
          'Rust run creation must enter the dispatched state.',
        );
      }
      _commit(
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
      now: run.startedAt,
      excludedTaskIds: excluded,
    );
    return poll.claim?.task.id == expectedTask.id ? poll.claim : null;
  }

  @override
  Future<TaskRunRecord> updateRun(
    TaskRunRecord run, {
    required TaskRunRecord expected,
    required DateTime updatedAt,
  }) {
    return _mutate(() {
      _expectRun(expected);
      if (run.status == expected.status) {
        _commit(
          _authority.applyTaskInbox(
            IanvsTaskInboxCommand.updateRunProjection(
              run: run,
              updatedAt: updatedAt,
            ),
          ),
        );
      } else {
        final task = _task(expected.taskId);
        if (run.status == TaskStatus.cancelled) {
          _commit(
            _authority.applyTaskInbox(
              IanvsTaskInboxCommand.cancelTaskProjection(
                task: task.copyWith(
                  status: TaskStatus.cancelled,
                  updatedAt: updatedAt,
                ),
                run: run,
                updatedAt: updatedAt,
              ),
            ),
          );
        } else {
          _commit(
            _authority.applyTaskInbox(
              IanvsTaskInboxCommand.transitionRunProjection(
                task: task.copyWith(status: run.status, updatedAt: updatedAt),
                run: run,
                transition: _transition(expected.status, run.status),
                updatedAt: updatedAt,
              ),
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
  }) {
    return _mutate(() {
      _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.appendEvents(
            events: events,
            updatedAt: updatedAt,
          ),
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
  }) {
    return _mutate(() {
      _expectArtifacts(expectedArtifacts, taskId: taskId, runId: runId);
      _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.replaceArtifacts(
            taskId: taskId,
            runId: runId,
            artifacts: artifacts,
            updatedAt: updatedAt,
          ),
        ),
      );
    });
  }

  @override
  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  }) {
    return _mutate(() {
      if (!_recordsEqual(
        authoritativeProjection.snapshot.artifacts,
        expectedArtifacts,
      )) {
        throw const TaskRepositoryConflict('Artifact projection is stale.');
      }
      _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.replaceArtifactSet(
            artifacts: artifacts,
            updatedAt: updatedAt,
          ),
        ),
      );
    });
  }

  @override
  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
  }) {
    return _mutate(() {
      final current = _approvalOrNull(approval.id);
      if (!_recordEqual(current, expected)) {
        throw const TaskRepositoryConflict('Approval projection is stale.');
      }
      _commit(
        _authority.applyTaskInbox(
          IanvsTaskInboxCommand.upsertApproval(
            approval: approval,
            updatedAt: updatedAt,
          ),
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
    return _mutate(() {
      final current = _resourceOrNull(resource.id);
      if (!_recordEqual(current, expected)) {
        throw const TaskRepositoryConflict('Resource projection is stale.');
      }
      _commit(
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
    return authoritativeProjection.revision;
  }

  @override
  Future<void> configureScheduler({required int maxConcurrentTasks}) {
    return _mutate(() {
      _authority.configureScheduler(maxConcurrentTasks: maxConcurrentTasks);
    });
  }

  @override
  Future<void> publishRuntimeStatus(LocalRuntimeStatus status) {
    return _mutate(() {
      _authority.setSchedulerRuntimeStatus(
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
    required DateTime now,
    Set<String> excludedTaskIds = const <String>{},
  }) {
    return _mutate(() {
      final projected = _authority.schedulerClaimNext(
        runId: runId,
        dispatchEventId: dispatchEventId,
        now: now,
        excludedTaskIds: excludedTaskIds.toList(growable: false),
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
        );
      }
      return TaskSchedulingPoll(
        repository: authoritativeProjection,
        claim: taskClaim,
        nextWakeAt: projected.nextWakeAt,
      );
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _authority.dispose();
  }

  Future<T> _mutate<T>(T Function() operation) async {
    await initialize();
    try {
      return operation();
    } on StateError catch (error) {
      final message = error.message.toString();
      if (message.contains('revision') && message.contains('conflict')) {
        throw TaskRepositoryConflict(message);
      }
      rethrow;
    }
  }

  void _commit(IanvsTaskInboxMaterializedProjection projection) {
    _setMaterialized(projection);
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
