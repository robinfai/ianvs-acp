import 'dart:async';
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../tasks/task_inbox_snapshot.dart';
import '../tasks/task_record.dart';
import '../tasks/workspace_resource.dart';
import 'ianvs_acp_native.dart';

abstract interface class IanvsWorkflowNativeApi {
  int get ffiVersion;

  Object createWorkflow();

  String? openWorkflow(Object workflow, String databasePath);

  String? applyWorkflow(Object workflow, Map<String, Object?> command);

  String? snapshotWorkflow(Object workflow);

  String? stageTaskInbox(
    Object workflow,
    Map<String, Object?> snapshot,
    String sourceChecksum,
  );

  String? taskInboxSource(Object workflow);

  String? materializeTaskInbox(Object workflow);

  String? activateTaskInbox(Object workflow);

  String? applyTaskInbox(Object workflow, Map<String, Object?> command);

  String? applyTaskInboxAsExecutor(
    Object workflow,
    Map<String, Object?> request,
  );

  String? configureScheduler(Object workflow, Map<String, Object?> config);

  String? setSchedulerRuntimeStatus(
    Object workflow,
    Map<String, Object?> status,
  );

  String? schedulerClaimNext(Object workflow, Map<String, Object?> request);

  String? executorLeaseForRun(Object workflow, String runId);

  String? runtimeEvents(
    Object workflow,
    String runId,
    int afterSequence,
    int limit,
  );

  String? executorLeaseCommand(Object workflow, Map<String, Object?> command);

  String? currentTaskInbox(Object workflow);

  String? lastError(Object workflow);

  void freeWorkflow(Object workflow);
}

abstract interface class IanvsWorkflowAuthority {
  FutureOr<IanvsWorkflowProjection> open(String databasePath);

  FutureOr<IanvsTaskInboxStageProjection> stageTaskInbox({
    required TaskInboxSnapshot source,
    required String sourceChecksum,
  });

  FutureOr<TaskInboxSnapshot?> taskInboxSource();

  FutureOr<IanvsTaskInboxMaterializedProjection> materializeTaskInbox();

  FutureOr<IanvsTaskInboxMaterializedProjection> activateTaskInbox();

  FutureOr<IanvsTaskInboxMaterializedProjection> applyTaskInbox(
    IanvsTaskInboxCommand command,
  );

  FutureOr<IanvsTaskInboxMaterializedProjection> applyTaskInboxAsExecutor({
    required IanvsExecutorCommandContext context,
    required IanvsTaskInboxCommand command,
  });

  FutureOr<IanvsWorkflowProjection> configureScheduler({
    required int maxConcurrentTasks,
    int runtimeStatusFreshnessSeconds = 30,
  });

  FutureOr<IanvsWorkflowProjection> setSchedulerRuntimeStatus(
    IanvsSchedulerRuntimeStatus status,
  );

  FutureOr<IanvsSchedulerClaimProjection> schedulerClaimNext({
    required String runId,
    required String dispatchEventId,
    required String executorLeaseId,
    required String executorId,
    required String commandId,
    required DateTime now,
    required DateTime leaseExpiresAt,
    List<String> excludedTaskIds = const <String>[],
    List<IanvsSchedulerCapacityReservation> capacityReservations =
        const <IanvsSchedulerCapacityReservation>[],
  });

  FutureOr<IanvsExecutorLease?> executorLeaseForRun(String runId);

  FutureOr<IanvsRuntimeEventPage> runtimeEvents({
    required String runId,
    required int afterSequence,
    int limit = 200,
  });

  FutureOr<IanvsExecutorLease> applyExecutorLeaseCommand(
    IanvsExecutorLeaseCommand command,
  );

  FutureOr<TaskInboxSnapshot?> currentTaskInbox();

  FutureOr<IanvsTaskInboxMaterializedProjection?> currentTaskInboxProjection();

  FutureOr<void> dispose();
}

final class IanvsRustWorkflow implements IanvsWorkflowAuthority {
  IanvsRustWorkflow({IanvsWorkflowNativeApi? native})
    : _native = native ?? FfiIanvsWorkflowNativeApi.open() {
    if (_native.ffiVersion != expectedFfiVersion) {
      throw StateError(
        'Unsupported ianvs workflow FFI version ${_native.ffiVersion}; '
        'expected $expectedFfiVersion.',
      );
    }
    _workflow = _native.createWorkflow();
  }

  static const int expectedFfiVersion = 7;

  final IanvsWorkflowNativeApi _native;
  late final Object _workflow;
  bool _opened = false;
  bool _disposed = false;

  @override
  IanvsWorkflowProjection open(String databasePath) {
    _ensureOpenHandle();
    if (_opened) {
      throw StateError('Rust workflow is already open.');
    }
    final encoded = _native.openWorkflow(_workflow, databasePath);
    final projection = _decodeProjection(encoded, operation: 'openWorkflow');
    _opened = true;
    return projection;
  }

  IanvsWorkflowProjection apply(IanvsWorkflowCommand command) {
    _ensureOpened();
    final encoded = _native.applyWorkflow(_workflow, command.toJson());
    return _decodeProjection(encoded, operation: command.operation);
  }

  IanvsWorkflowProjection snapshot() {
    _ensureOpened();
    return _decodeProjection(
      _native.snapshotWorkflow(_workflow),
      operation: 'snapshotWorkflow',
    );
  }

  @override
  IanvsTaskInboxStageProjection stageTaskInbox({
    required TaskInboxSnapshot source,
    required String sourceChecksum,
  }) {
    _ensureOpened();
    final encoded = _native.stageTaskInbox(
      _workflow,
      source.toJson(),
      sourceChecksum,
    );
    if (encoded == null) {
      throw StateError(
        'stageTaskInbox failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException(
        'Rust staged TaskInbox projection must be an object.',
      );
    }
    return IanvsTaskInboxStageProjection.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  @override
  TaskInboxSnapshot? taskInboxSource() {
    _ensureOpened();
    return _decodeTaskInboxEnvelope(
      _native.taskInboxSource(_workflow),
      field: 'source',
      operation: 'taskInboxSource',
    );
  }

  TaskInboxSnapshot? _decodeTaskInboxEnvelope(
    String? encoded, {
    required String field,
    required String operation,
  }) {
    if (encoded == null) {
      throw StateError(
        '$operation failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException(
        'TaskInbox source envelope must be an object.',
      );
    }
    final envelope = decoded.map(
      (key, value) => MapEntry(key.toString(), value),
    );
    if (envelope['schemaVersion'] != 1 ||
        envelope['taskInboxSchema'] != TaskInboxSnapshot.schema) {
      throw FormatException(
        'Unsupported TaskInbox source envelope: '
        '${envelope['schemaVersion']} / ${envelope['taskInboxSchema']}',
      );
    }
    final value = envelope[field];
    return value == null ? null : TaskInboxSnapshot.fromJsonStrict(value);
  }

  @override
  IanvsTaskInboxMaterializedProjection materializeTaskInbox() {
    _ensureOpened();
    return _decodeMaterializedTaskInbox(
      _native.materializeTaskInbox(_workflow),
      operation: 'materializeTaskInbox',
    );
  }

  @override
  IanvsTaskInboxMaterializedProjection activateTaskInbox() {
    _ensureOpened();
    return _decodeMaterializedTaskInbox(
      _native.activateTaskInbox(_workflow),
      operation: 'activateTaskInbox',
    );
  }

  @override
  IanvsTaskInboxMaterializedProjection applyTaskInbox(
    IanvsTaskInboxCommand command,
  ) {
    _ensureOpened();
    return _decodeMaterializedTaskInbox(
      _native.applyTaskInbox(_workflow, command.toJson()),
      operation: command.operation,
    );
  }

  @override
  IanvsTaskInboxMaterializedProjection applyTaskInboxAsExecutor({
    required IanvsExecutorCommandContext context,
    required IanvsTaskInboxCommand command,
  }) {
    _ensureOpened();
    return _decodeMaterializedTaskInbox(
      _native.applyTaskInboxAsExecutor(_workflow, <String, Object?>{
        'context': context.toJson(),
        'command': command.toJson(),
      }),
      operation: 'applyTaskInboxAsExecutor',
    );
  }

  @override
  IanvsWorkflowProjection configureScheduler({
    required int maxConcurrentTasks,
    int runtimeStatusFreshnessSeconds = 30,
  }) {
    _ensureOpened();
    if (maxConcurrentTasks < 1) {
      throw ArgumentError.value(
        maxConcurrentTasks,
        'maxConcurrentTasks',
        'must be positive',
      );
    }
    if (runtimeStatusFreshnessSeconds < 1) {
      throw ArgumentError.value(
        runtimeStatusFreshnessSeconds,
        'runtimeStatusFreshnessSeconds',
        'must be positive',
      );
    }
    return _decodeProjection(
      _native.configureScheduler(_workflow, <String, Object?>{
        'maxConcurrentTasks': maxConcurrentTasks,
        'runtimeStatusFreshnessSeconds': runtimeStatusFreshnessSeconds,
      }),
      operation: 'configureScheduler',
    );
  }

  @override
  IanvsWorkflowProjection setSchedulerRuntimeStatus(
    IanvsSchedulerRuntimeStatus status,
  ) {
    _ensureOpened();
    return _decodeProjection(
      _native.setSchedulerRuntimeStatus(_workflow, status.toJson()),
      operation: 'setSchedulerRuntimeStatus',
    );
  }

  @override
  IanvsSchedulerClaimProjection schedulerClaimNext({
    required String runId,
    required String dispatchEventId,
    required String executorLeaseId,
    required String executorId,
    required String commandId,
    required DateTime now,
    required DateTime leaseExpiresAt,
    List<String> excludedTaskIds = const <String>[],
    List<IanvsSchedulerCapacityReservation> capacityReservations =
        const <IanvsSchedulerCapacityReservation>[],
  }) {
    _ensureOpened();
    final encoded = _native.schedulerClaimNext(_workflow, <String, Object?>{
      'runId': _requiredText(runId, 'runId'),
      'dispatchEventId': _requiredText(dispatchEventId, 'dispatchEventId'),
      'executorLeaseId': _requiredText(executorLeaseId, 'executorLeaseId'),
      'executorId': _requiredText(executorId, 'executorId'),
      'commandId': _requiredText(commandId, 'commandId'),
      'now': now.toIso8601String(),
      'leaseExpiresAt': leaseExpiresAt.toIso8601String(),
      'excludedTaskIds': excludedTaskIds
          .map((taskId) => _requiredText(taskId, 'excludedTaskIds'))
          .toList(growable: false),
      'capacityReservations': capacityReservations
          .map((reservation) => reservation.toJson())
          .toList(growable: false),
    });
    if (encoded == null) {
      throw StateError(
        'schedulerClaimNext failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException(
        'Rust scheduler claim projection must be an object.',
      );
    }
    return IanvsSchedulerClaimProjection.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  @override
  IanvsExecutorLease? executorLeaseForRun(String runId) {
    _ensureOpened();
    final encoded = _native.executorLeaseForRun(
      _workflow,
      _requiredText(runId, 'runId'),
    );
    if (encoded == null) {
      throw StateError(
        'executorLeaseForRun failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = _jsonMap(jsonDecode(encoded), 'executor lease envelope');
    final lease = decoded['lease'];
    return lease == null
        ? null
        : IanvsExecutorLease.fromJson(_jsonMap(lease, 'lease'));
  }

  @override
  IanvsRuntimeEventPage runtimeEvents({
    required String runId,
    required int afterSequence,
    int limit = 200,
  }) {
    _ensureOpened();
    if (afterSequence < 0) {
      throw ArgumentError.value(
        afterSequence,
        'afterSequence',
        'must be nonnegative',
      );
    }
    if (limit < 1 || limit > IanvsRuntimeEventPage.maxLimit) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 500');
    }
    final encoded = _native.runtimeEvents(
      _workflow,
      _requiredText(runId, 'runId'),
      afterSequence,
      limit,
    );
    if (encoded == null) {
      throw StateError(
        'runtimeEvents failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    return IanvsRuntimeEventPage.fromJson(
      _jsonMap(jsonDecode(encoded), 'runtime event page'),
    );
  }

  @override
  IanvsExecutorLease applyExecutorLeaseCommand(
    IanvsExecutorLeaseCommand command,
  ) {
    _ensureOpened();
    final encoded = _native.executorLeaseCommand(_workflow, command.toJson());
    if (encoded == null) {
      throw StateError(
        'applyExecutorLeaseCommand failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    return IanvsExecutorLease.fromJson(
      _jsonMap(jsonDecode(encoded), 'executor lease'),
    );
  }

  IanvsTaskInboxMaterializedProjection _decodeMaterializedTaskInbox(
    String? encoded, {
    required String operation,
  }) {
    if (encoded == null) {
      throw StateError(
        '$operation failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException(
        'Rust materialized TaskInbox projection must be an object.',
      );
    }
    return IanvsTaskInboxMaterializedProjection.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  @override
  TaskInboxSnapshot? currentTaskInbox() {
    _ensureOpened();
    return _decodeTaskInboxEnvelope(
      _native.currentTaskInbox(_workflow),
      field: 'current',
      operation: 'currentTaskInbox',
    );
  }

  @override
  IanvsTaskInboxMaterializedProjection? currentTaskInboxProjection() {
    final taskInbox = currentTaskInbox();
    if (taskInbox == null) return null;
    return IanvsTaskInboxMaterializedProjection(
      workflow: snapshot(),
      taskInbox: taskInbox,
    );
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _native.freeWorkflow(_workflow);
  }

  IanvsWorkflowProjection _decodeProjection(
    String? encoded, {
    required String operation,
  }) {
    if (encoded == null) {
      throw StateError(
        '$operation failed: '
        '${_native.lastError(_workflow) ?? 'unknown native error'}',
      );
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException(
        'Rust workflow projection must be an object.',
      );
    }
    return IanvsWorkflowProjection.fromJson(
      decoded.map((key, value) => MapEntry(key.toString(), value)),
    );
  }

  void _ensureOpenHandle() {
    if (_disposed) {
      throw StateError('Rust workflow is disposed.');
    }
  }

  void _ensureOpened() {
    _ensureOpenHandle();
    if (!_opened) {
      throw StateError('Rust workflow is not open.');
    }
  }
}

final class IanvsWorkflowCommand {
  IanvsWorkflowCommand._(this.operation, Map<String, Object?> fields)
    : _fields = Map<String, Object?>.unmodifiable(fields);

  factory IanvsWorkflowCommand.createTask({
    required String taskId,
    required String workspacePath,
    required String agentName,
  }) => IanvsWorkflowCommand._('create_task', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'workspacePath': _requiredText(workspacePath, 'workspacePath'),
    'agentName': _requiredText(agentName, 'agentName'),
  });

  factory IanvsWorkflowCommand.queueTask(String taskId) =>
      IanvsWorkflowCommand._('queue_task', <String, Object?>{
        'taskId': _requiredText(taskId, 'taskId'),
      });

  factory IanvsWorkflowCommand.updateTaskDefinition({
    required String taskId,
    required String workspacePath,
    required String agentName,
  }) => IanvsWorkflowCommand._('update_task_definition', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'workspacePath': _requiredText(workspacePath, 'workspacePath'),
    'agentName': _requiredText(agentName, 'agentName'),
  });

  factory IanvsWorkflowCommand.deleteTask(String taskId) =>
      IanvsWorkflowCommand._('delete_task', <String, Object?>{
        'taskId': _requiredText(taskId, 'taskId'),
      });

  factory IanvsWorkflowCommand.dispatchTask({
    required String taskId,
    required String runId,
  }) => IanvsWorkflowCommand._('dispatch_task', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'runId': _requiredText(runId, 'runId'),
  });

  factory IanvsWorkflowCommand.startRun(String runId) =>
      IanvsWorkflowCommand._run('start_run', runId);

  factory IanvsWorkflowCommand.waitForPermission(String runId) =>
      IanvsWorkflowCommand._run('wait_for_permission', runId);

  factory IanvsWorkflowCommand.waitForUserInput(String runId) =>
      IanvsWorkflowCommand._run('wait_for_user_input', runId);

  factory IanvsWorkflowCommand.resumeRun(String runId) =>
      IanvsWorkflowCommand._run('resume_run', runId);

  factory IanvsWorkflowCommand.collectArtifacts(String runId) =>
      IanvsWorkflowCommand._run('collect_artifacts', runId);

  factory IanvsWorkflowCommand.requireHumanReview(String runId) =>
      IanvsWorkflowCommand._run('require_human_review', runId);

  factory IanvsWorkflowCommand.requestChanges(String runId) =>
      IanvsWorkflowCommand._run('request_changes', runId);

  factory IanvsWorkflowCommand.completeRun(String runId) =>
      IanvsWorkflowCommand._run('complete_run', runId);

  factory IanvsWorkflowCommand.failRun(String runId) =>
      IanvsWorkflowCommand._run('fail_run', runId);

  factory IanvsWorkflowCommand.rejectRun(String runId) =>
      IanvsWorkflowCommand._run('reject_run', runId);

  factory IanvsWorkflowCommand.cancelTask(String taskId) =>
      IanvsWorkflowCommand._('cancel_task', <String, Object?>{
        'taskId': _requiredText(taskId, 'taskId'),
      });

  factory IanvsWorkflowCommand._run(String operation, String runId) =>
      IanvsWorkflowCommand._(operation, <String, Object?>{
        'runId': _requiredText(runId, 'runId'),
      });

  final String operation;
  final Map<String, Object?> _fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation,
    ..._fields,
  };
}

enum IanvsTaskInboxRunTransition {
  start,
  waitForPermission,
  waitForUserInput,
  resume,
  collectArtifacts,
  requireHumanReview,
  requestChanges,
  complete,
  fail,
  reject,
}

final class IanvsTaskInboxCommand {
  IanvsTaskInboxCommand._(this.operation, Map<String, Object?> fields)
    : _fields = Map<String, Object?>.unmodifiable(fields);

  factory IanvsTaskInboxCommand.createTask(TaskRecord task) =>
      IanvsTaskInboxCommand._('create_task', <String, Object?>{
        'task': task.toJson(),
      });

  factory IanvsTaskInboxCommand.queueTask({
    required String taskId,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('queue_task', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.queueTaskProjection({
    required TaskRecord task,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('queue_task_projection', <String, Object?>{
    'task': task.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.updateTaskDefinition({
    required TaskRecord task,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('update_task_definition', <String, Object?>{
    'task': task.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.dispatchRun({
    required TaskRunRecord run,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('dispatch_run', <String, Object?>{
    'run': run.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.dispatchRunProjection({
    required TaskRecord task,
    required TaskRunRecord run,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('dispatch_run_projection', <String, Object?>{
    'task': task.toJson(),
    'run': run.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.transitionRun({
    required String runId,
    required IanvsTaskInboxRunTransition transition,
    required DateTime updatedAt,
    DateTime? endedAt,
    String? error,
  }) => IanvsTaskInboxCommand._('transition_run', <String, Object?>{
    'runId': _requiredText(runId, 'runId'),
    'transition': transition.jsonValue,
    'updatedAt': updatedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt.toIso8601String(),
    if (error != null) 'error': _requiredText(error, 'error'),
  });

  factory IanvsTaskInboxCommand.transitionRunProjection({
    required TaskRecord task,
    required TaskRunRecord run,
    required IanvsTaskInboxRunTransition transition,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('transition_run_projection', <String, Object?>{
    'task': task.toJson(),
    'run': run.toJson(),
    'transition': transition.jsonValue,
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.cancelTask({
    required String taskId,
    required DateTime updatedAt,
    DateTime? endedAt,
  }) => IanvsTaskInboxCommand._('cancel_task', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'updatedAt': updatedAt.toIso8601String(),
    if (endedAt != null) 'endedAt': endedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.cancelTaskProjection({
    required TaskRecord task,
    TaskRunRecord? run,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('cancel_task_projection', <String, Object?>{
    'task': task.toJson(),
    if (run != null) 'run': run.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.deleteTask({
    required String taskId,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('delete_task', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.updateTaskProjection({
    required TaskRecord task,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('update_task_projection', <String, Object?>{
    'task': task.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.updateRunProjection({
    required TaskRunRecord run,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('update_run_projection', <String, Object?>{
    'run': run.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.appendEvents({
    required List<TaskEventRecord> events,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('append_events', <String, Object?>{
    'events': events.map((event) => event.toJson()).toList(growable: false),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.replaceArtifacts({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('replace_artifacts', <String, Object?>{
    'taskId': _requiredText(taskId, 'taskId'),
    'runId': _requiredText(runId, 'runId'),
    'artifacts': artifacts
        .map((artifact) => artifact.toJson())
        .toList(growable: false),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.replaceArtifactSet({
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('replace_artifact_set', <String, Object?>{
    'artifacts': artifacts
        .map((artifact) => artifact.toJson())
        .toList(growable: false),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.upsertApproval({
    required ApprovalRequestRecord approval,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('upsert_approval', <String, Object?>{
    'approval': approval.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  factory IanvsTaskInboxCommand.upsertResource({
    required WorkspaceResource resource,
    required DateTime updatedAt,
  }) => IanvsTaskInboxCommand._('upsert_resource', <String, Object?>{
    'resource': resource.toJson(),
    'updatedAt': updatedAt.toIso8601String(),
  });

  final String operation;
  final Map<String, Object?> _fields;

  Map<String, Object?> toJson() => <String, Object?>{
    'operation': operation,
    ..._fields,
  };
}

extension on IanvsTaskInboxRunTransition {
  String get jsonValue {
    return switch (this) {
      IanvsTaskInboxRunTransition.start => 'start',
      IanvsTaskInboxRunTransition.waitForPermission => 'wait_for_permission',
      IanvsTaskInboxRunTransition.waitForUserInput => 'wait_for_user_input',
      IanvsTaskInboxRunTransition.resume => 'resume',
      IanvsTaskInboxRunTransition.collectArtifacts => 'collect_artifacts',
      IanvsTaskInboxRunTransition.requireHumanReview => 'require_human_review',
      IanvsTaskInboxRunTransition.requestChanges => 'request_changes',
      IanvsTaskInboxRunTransition.complete => 'complete',
      IanvsTaskInboxRunTransition.fail => 'fail',
      IanvsTaskInboxRunTransition.reject => 'reject',
    };
  }
}

enum IanvsSchedulerRuntimeAvailability {
  unknown,
  available,
  busy,
  unavailable,
  authRequired,
  misconfigured,
}

final class IanvsSchedulerRuntimeStatus {
  IanvsSchedulerRuntimeStatus({
    required this.agentName,
    required this.availability,
    required this.observedAt,
    this.unavailableReason,
    this.supportsSessionResume = false,
    this.supportsPermissions = false,
    this.maxConcurrentTasks = 1,
  }) {
    _requiredText(agentName, 'agentName');
    if (unavailableReason != null) {
      _requiredText(unavailableReason!, 'unavailableReason');
    }
    if (maxConcurrentTasks < 1) {
      throw ArgumentError.value(
        maxConcurrentTasks,
        'maxConcurrentTasks',
        'must be positive',
      );
    }
  }

  final String agentName;
  final IanvsSchedulerRuntimeAvailability availability;
  final DateTime observedAt;
  final String? unavailableReason;
  final bool supportsSessionResume;
  final bool supportsPermissions;
  final int maxConcurrentTasks;

  Map<String, Object?> toJson() => <String, Object?>{
    'agentName': _requiredText(agentName, 'agentName'),
    'availability': availability.jsonValue,
    'observedAt': observedAt.toIso8601String(),
    'unavailableReason': ?unavailableReason,
    'supportsSessionResume': supportsSessionResume,
    'supportsPermissions': supportsPermissions,
    'maxConcurrentTasks': maxConcurrentTasks,
  };
}

final class IanvsSchedulerCapacityReservation {
  IanvsSchedulerCapacityReservation({
    required this.reservationId,
    required this.agentName,
    required this.hostInstanceId,
    required this.createdAt,
    required this.expiresAt,
  }) {
    _requiredText(reservationId, 'reservationId');
    _requiredText(agentName, 'agentName');
    _requiredText(hostInstanceId, 'hostInstanceId');
    if (!createdAt.isBefore(expiresAt)) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'must be after createdAt',
      );
    }
  }

  final String reservationId;
  final String agentName;
  final String hostInstanceId;
  final DateTime createdAt;
  final DateTime expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'reservationId': reservationId,
    'agentName': agentName,
    'hostInstanceId': hostInstanceId,
    'createdAt': createdAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  };
}

enum IanvsExecutorLeaseState {
  claimed,
  starting,
  active,
  expired,
  released,
  superseded,
}

enum IanvsExecutorLeaseOperation {
  acknowledgeStart,
  heartbeat,
  release,
  cancel,
  markOrphaned,
}

final class IanvsExecutorCommandContext {
  IanvsExecutorCommandContext({
    required this.runId,
    required this.executorLeaseId,
    required this.generation,
    required this.commandId,
    required this.now,
  }) {
    _requiredText(runId, 'runId');
    _requiredText(executorLeaseId, 'executorLeaseId');
    _requiredText(commandId, 'commandId');
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
  }

  final String runId;
  final String executorLeaseId;
  final int generation;
  final String commandId;
  final DateTime now;

  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    'executorLeaseId': executorLeaseId,
    'generation': generation,
    'commandId': commandId,
    'now': now.toIso8601String(),
  };
}

final class IanvsExecutorLeaseCommand {
  const IanvsExecutorLeaseCommand({
    required this.context,
    required this.operation,
    this.nextExpiresAt,
  });

  final IanvsExecutorCommandContext context;
  final IanvsExecutorLeaseOperation operation;
  final DateTime? nextExpiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'context': context.toJson(),
    'operation': operation.jsonValue,
    'nextExpiresAt': ?nextExpiresAt?.toIso8601String(),
  };
}

extension on IanvsExecutorLeaseOperation {
  String get jsonValue => switch (this) {
    IanvsExecutorLeaseOperation.acknowledgeStart => 'acknowledge_start',
    IanvsExecutorLeaseOperation.heartbeat => 'heartbeat',
    IanvsExecutorLeaseOperation.release => 'release',
    IanvsExecutorLeaseOperation.cancel => 'cancel',
    IanvsExecutorLeaseOperation.markOrphaned => 'mark_orphaned',
  };
}

final class IanvsExecutorLease {
  const IanvsExecutorLease({
    required this.leaseId,
    required this.runId,
    required this.executorId,
    required this.generation,
    required this.reservationId,
    required this.acquiredAt,
    required this.expiresAt,
    required this.lastHeartbeatAt,
    required this.startAcknowledgedAt,
    required this.releasedAt,
    required this.state,
  });

  factory IanvsExecutorLease.fromJson(Map<String, Object?> json) {
    final generation = _nonnegativeInt(json, 'generation');
    if (generation < 1) {
      throw const FormatException('Executor generation must be positive.');
    }
    return IanvsExecutorLease(
      leaseId: _requiredJsonString(json, 'leaseId'),
      runId: _requiredJsonString(json, 'runId'),
      executorId: _requiredJsonString(json, 'executorId'),
      generation: generation,
      reservationId: _requiredJsonString(json, 'reservationId'),
      acquiredAt: _requiredJsonDateTime(json, 'acquiredAt'),
      expiresAt: _requiredJsonDateTime(json, 'expiresAt'),
      lastHeartbeatAt: _requiredJsonDateTime(json, 'lastHeartbeatAt'),
      startAcknowledgedAt: _optionalJsonDateTime(json, 'startAcknowledgedAt'),
      releasedAt: _optionalJsonDateTime(json, 'releasedAt'),
      state: _executorLeaseState(json['state']),
    );
  }

  final String leaseId;
  final String runId;
  final String executorId;
  final int generation;
  final String reservationId;
  final DateTime acquiredAt;
  final DateTime expiresAt;
  final DateTime lastHeartbeatAt;
  final DateTime? startAcknowledgedAt;
  final DateTime? releasedAt;
  final IanvsExecutorLeaseState state;
}

final class IanvsStoredRuntimeEvent {
  const IanvsStoredRuntimeEvent({
    required this.sequence,
    required this.event,
    required this.executorLeaseId,
    required this.executorGeneration,
    required this.commandId,
  });

  factory IanvsStoredRuntimeEvent.fromJson(Map<String, Object?> json) {
    final event = TaskEventRecord.fromJson(json['event']);
    if (event == null) {
      throw const FormatException('Stored runtime event is invalid.');
    }
    final rawGeneration = json['executorGeneration'];
    final generation = rawGeneration == null
        ? null
        : _nonnegativeInt(json, 'executorGeneration');
    if (generation == 0) {
      throw const FormatException('executorGeneration must be positive.');
    }
    return IanvsStoredRuntimeEvent(
      sequence: _nonnegativeInt(json, 'sequence'),
      event: event,
      executorLeaseId: _optionalJsonString(json, 'executorLeaseId'),
      executorGeneration: generation,
      commandId: _optionalJsonString(json, 'commandId'),
    );
  }

  final int sequence;
  final TaskEventRecord event;
  final String? executorLeaseId;
  final int? executorGeneration;
  final String? commandId;
}

final class IanvsRuntimeEventPage {
  IanvsRuntimeEventPage({
    required this.runId,
    required this.afterSequence,
    required List<IanvsStoredRuntimeEvent> events,
    required this.nextSequence,
    required this.hasMore,
  }) : events = List<IanvsStoredRuntimeEvent>.unmodifiable(events);

  factory IanvsRuntimeEventPage.fromJson(Map<String, Object?> json) {
    return IanvsRuntimeEventPage(
      runId: _requiredJsonString(json, 'runId'),
      afterSequence: _nonnegativeInt(json, 'afterSequence'),
      events: _jsonList(json['events'], 'events')
          .map(
            (event) => IanvsStoredRuntimeEvent.fromJson(
              _jsonMap(event, 'runtime event'),
            ),
          )
          .toList(growable: false),
      nextSequence: _nonnegativeInt(json, 'nextSequence'),
      hasMore: _requiredJsonBool(json, 'hasMore'),
    );
  }

  static const int maxLimit = 500;

  final String runId;
  final int afterSequence;
  final List<IanvsStoredRuntimeEvent> events;
  final int nextSequence;
  final bool hasMore;
}

extension on IanvsSchedulerRuntimeAvailability {
  String get jsonValue => switch (this) {
    IanvsSchedulerRuntimeAvailability.unknown => 'unknown',
    IanvsSchedulerRuntimeAvailability.available => 'available',
    IanvsSchedulerRuntimeAvailability.busy => 'busy',
    IanvsSchedulerRuntimeAvailability.unavailable => 'unavailable',
    IanvsSchedulerRuntimeAvailability.authRequired => 'auth_required',
    IanvsSchedulerRuntimeAvailability.misconfigured => 'misconfigured',
  };
}

enum IanvsWorkflowTaskStatus {
  inbox,
  queued,
  dispatched,
  running,
  blockedOnPermission,
  blockedOnUserInput,
  collectingArtifacts,
  needsHumanReview,
  needsChanges,
  done,
  failed,
  cancelled,
  rejected,
}

enum IanvsWorkflowRunStatus {
  dispatched,
  running,
  waitingPermission,
  waitingUserInput,
  collectingArtifacts,
  needsHumanReview,
  needsChanges,
  succeeded,
  failed,
  cancelled,
  rejected,
}

enum IanvsWorkflowMigrationPhase { native, staged, ready, active }

final class IanvsWorkflowMigration {
  const IanvsWorkflowMigration({required this.phase, this.sourceChecksum});

  factory IanvsWorkflowMigration.fromJson(Map<String, Object?> json) {
    final phase = switch (json['phase']) {
      'native' => IanvsWorkflowMigrationPhase.native,
      'staged' => IanvsWorkflowMigrationPhase.staged,
      'ready' => IanvsWorkflowMigrationPhase.ready,
      'active' => IanvsWorkflowMigrationPhase.active,
      final value => throw FormatException(
        'Unknown workflow migration phase: $value',
      ),
    };
    final sourceChecksum = _optionalJsonString(json, 'sourceChecksum');
    return IanvsWorkflowMigration(phase: phase, sourceChecksum: sourceChecksum);
  }

  final IanvsWorkflowMigrationPhase phase;
  final String? sourceChecksum;
}

final class IanvsWorkflowTask {
  const IanvsWorkflowTask({
    required this.id,
    required this.workspacePath,
    required this.agentName,
    required this.status,
    required this.attempt,
    required this.currentRunId,
  });

  factory IanvsWorkflowTask.fromJson(Map<String, Object?> json) {
    return IanvsWorkflowTask(
      id: _requiredJsonString(json, 'id'),
      workspacePath: _requiredJsonString(json, 'workspacePath'),
      agentName: _requiredJsonString(json, 'agentName'),
      status: _taskStatus(json['status']),
      attempt: _nonnegativeInt(json, 'attempt'),
      currentRunId: _optionalJsonString(json, 'currentRunId'),
    );
  }

  final String id;
  final String workspacePath;
  final String agentName;
  final IanvsWorkflowTaskStatus status;
  final int attempt;
  final String? currentRunId;
}

final class IanvsWorkflowRun {
  const IanvsWorkflowRun({
    required this.id,
    required this.taskId,
    required this.attempt,
    required this.status,
  });

  factory IanvsWorkflowRun.fromJson(Map<String, Object?> json) {
    final attempt = _nonnegativeInt(json, 'attempt');
    if (attempt < 1) {
      throw const FormatException('Workflow run attempt must be positive.');
    }
    return IanvsWorkflowRun(
      id: _requiredJsonString(json, 'id'),
      taskId: _requiredJsonString(json, 'taskId'),
      attempt: attempt,
      status: _runStatus(json['status']),
    );
  }

  final String id;
  final String taskId;
  final int attempt;
  final IanvsWorkflowRunStatus status;
}

enum IanvsRecoveryState {
  requeued,
  orphaned,
  waiting,
  reviewRequired,
  terminal,
}

enum IanvsPromptSubmissionState {
  notSubmitted,
  submitted,
  unknown,
  notApplicable,
}

enum IanvsWorkspaceMutationPossibility {
  none,
  readOnly,
  possible,
  confirmed,
  unknown,
}

enum IanvsSuggestedRecoveryAction {
  requeue,
  resumeSession,
  retryReadOnly,
  humanReview,
  keepWaiting,
  terminal,
}

final class IanvsRunRecoveryRecord {
  const IanvsRunRecoveryRecord({
    required this.taskId,
    required this.runId,
    required this.previousState,
    required this.recoveryState,
    required this.reason,
    required this.promptSubmissionState,
    required this.workspaceMutationPossibility,
    required this.suggestedAction,
    required this.executorLeaseId,
  });

  factory IanvsRunRecoveryRecord.fromJson(Map<String, Object?> json) {
    return IanvsRunRecoveryRecord(
      taskId: _requiredJsonString(json, 'taskId'),
      runId: _requiredJsonString(json, 'runId'),
      previousState: _requiredJsonString(json, 'previousState'),
      recoveryState: switch (_requiredJsonString(json, 'recoveryState')) {
        'requeued' => IanvsRecoveryState.requeued,
        'orphaned' => IanvsRecoveryState.orphaned,
        'waiting' => IanvsRecoveryState.waiting,
        'review_required' => IanvsRecoveryState.reviewRequired,
        'terminal' => IanvsRecoveryState.terminal,
        final value => throw FormatException('Unknown recovery state: $value'),
      },
      reason: _requiredJsonString(json, 'reason'),
      promptSubmissionState: switch (_requiredJsonString(
        json,
        'promptSubmissionState',
      )) {
        'not_submitted' => IanvsPromptSubmissionState.notSubmitted,
        'submitted' => IanvsPromptSubmissionState.submitted,
        'unknown' => IanvsPromptSubmissionState.unknown,
        'not_applicable' => IanvsPromptSubmissionState.notApplicable,
        final value => throw FormatException(
          'Unknown prompt submission state: $value',
        ),
      },
      workspaceMutationPossibility: switch (_requiredJsonString(
        json,
        'workspaceMutationPossibility',
      )) {
        'none' => IanvsWorkspaceMutationPossibility.none,
        'read_only' => IanvsWorkspaceMutationPossibility.readOnly,
        'possible' => IanvsWorkspaceMutationPossibility.possible,
        'confirmed' => IanvsWorkspaceMutationPossibility.confirmed,
        'unknown' => IanvsWorkspaceMutationPossibility.unknown,
        final value => throw FormatException(
          'Unknown workspace mutation possibility: $value',
        ),
      },
      suggestedAction: switch (_requiredJsonString(json, 'suggestedAction')) {
        'requeue' => IanvsSuggestedRecoveryAction.requeue,
        'resume_session' => IanvsSuggestedRecoveryAction.resumeSession,
        'retry_read_only' => IanvsSuggestedRecoveryAction.retryReadOnly,
        'human_review' => IanvsSuggestedRecoveryAction.humanReview,
        'keep_waiting' => IanvsSuggestedRecoveryAction.keepWaiting,
        'terminal' => IanvsSuggestedRecoveryAction.terminal,
        final value => throw FormatException(
          'Unknown suggested recovery action: $value',
        ),
      },
      executorLeaseId: _optionalJsonString(json, 'executorLeaseId'),
    );
  }

  final String taskId;
  final String runId;
  final String previousState;
  final IanvsRecoveryState recoveryState;
  final String reason;
  final IanvsPromptSubmissionState promptSubmissionState;
  final IanvsWorkspaceMutationPossibility workspaceMutationPossibility;
  final IanvsSuggestedRecoveryAction suggestedAction;
  final String? executorLeaseId;
}

final class IanvsRecoveryReport {
  IanvsRecoveryReport({
    required this.detectedAt,
    required List<IanvsRunRecoveryRecord> runs,
  }) : runs = List<IanvsRunRecoveryRecord>.unmodifiable(runs);

  factory IanvsRecoveryReport.fromJson(Map<String, Object?> json) {
    return IanvsRecoveryReport(
      detectedAt: DateTime.parse(_requiredJsonString(json, 'detectedAt')),
      runs: _jsonList(json['runs'], 'recovery.runs')
          .map(
            (value) => IanvsRunRecoveryRecord.fromJson(
              _jsonMap(value, 'recovery run'),
            ),
          )
          .toList(growable: false),
    );
  }

  final DateTime detectedAt;
  final List<IanvsRunRecoveryRecord> runs;
}

final class IanvsWorkflowProjection {
  IanvsWorkflowProjection._({
    required this.schemaVersion,
    required this.revision,
    required this.migration,
    required List<IanvsWorkflowTask> tasks,
    required List<IanvsWorkflowRun> runs,
    required this.recovery,
  }) : tasks = List<IanvsWorkflowTask>.unmodifiable(tasks),
       runs = List<IanvsWorkflowRun>.unmodifiable(runs);

  factory IanvsWorkflowProjection.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion != supportedSchemaVersion) {
      throw FormatException(
        'Unsupported ianvs workflow schema: $schemaVersion',
      );
    }
    final revision = _nonnegativeInt(json, 'revision');
    final migration = IanvsWorkflowMigration.fromJson(
      _jsonMap(json['migration'], 'migration'),
    );
    final snapshot = _jsonMap(json['snapshot'], 'snapshot');
    final rawTasks = _jsonList(snapshot['tasks'], 'snapshot.tasks');
    final rawRuns = _jsonList(snapshot['runs'], 'snapshot.runs');
    final recovery = json['recovery'] == null
        ? null
        : IanvsRecoveryReport.fromJson(_jsonMap(json['recovery'], 'recovery'));
    return IanvsWorkflowProjection._(
      schemaVersion: schemaVersion as int,
      revision: revision,
      migration: migration,
      tasks: rawTasks
          .map((value) => IanvsWorkflowTask.fromJson(_jsonMap(value, 'task')))
          .toList(growable: false),
      runs: rawRuns
          .map((value) => IanvsWorkflowRun.fromJson(_jsonMap(value, 'run')))
          .toList(growable: false),
      recovery: recovery,
    );
  }

  static const int supportedSchemaVersion = 1;

  final int schemaVersion;
  final int revision;
  final IanvsWorkflowMigration migration;
  final List<IanvsWorkflowTask> tasks;
  final List<IanvsWorkflowRun> runs;
  final IanvsRecoveryReport? recovery;
}

final class IanvsTaskInboxStageProjection {
  IanvsTaskInboxStageProjection._({
    required this.workflow,
    required List<String> normalizedHistoricalTaskIds,
  }) : normalizedHistoricalTaskIds = List<String>.unmodifiable(
         normalizedHistoricalTaskIds,
       );

  factory IanvsTaskInboxStageProjection.fromJson(Map<String, Object?> json) {
    return IanvsTaskInboxStageProjection._(
      workflow: IanvsWorkflowProjection.fromJson(json),
      normalizedHistoricalTaskIds: _stringList(
        json['normalizedHistoricalTaskIds'],
        'normalizedHistoricalTaskIds',
      ),
    );
  }

  final IanvsWorkflowProjection workflow;
  final List<String> normalizedHistoricalTaskIds;
}

final class IanvsTaskInboxMaterializedProjection {
  const IanvsTaskInboxMaterializedProjection({
    required this.workflow,
    required this.taskInbox,
  });

  factory IanvsTaskInboxMaterializedProjection.fromJson(
    Map<String, Object?> json,
  ) {
    return IanvsTaskInboxMaterializedProjection(
      workflow: IanvsWorkflowProjection.fromJson(json),
      taskInbox: TaskInboxSnapshot.fromJsonStrict(json['taskInbox']),
    );
  }

  final IanvsWorkflowProjection workflow;
  final TaskInboxSnapshot taskInbox;
}

final class IanvsSchedulerClaim {
  const IanvsSchedulerClaim({
    required this.taskId,
    required this.runId,
    required this.dispatchEventId,
    required this.agentName,
    required this.workspacePath,
    required this.attempt,
    required this.reservationId,
    required this.executorLease,
  });

  factory IanvsSchedulerClaim.fromJson(Map<String, Object?> json) {
    final attempt = _nonnegativeInt(json, 'attempt');
    if (attempt < 1) {
      throw const FormatException('Scheduler claim attempt must be positive.');
    }
    return IanvsSchedulerClaim(
      taskId: _requiredJsonString(json, 'taskId'),
      runId: _requiredJsonString(json, 'runId'),
      dispatchEventId: _requiredJsonString(json, 'dispatchEventId'),
      agentName: _requiredJsonString(json, 'agentName'),
      workspacePath: _requiredJsonString(json, 'workspacePath'),
      attempt: attempt,
      reservationId: _requiredJsonString(json, 'reservationId'),
      executorLease: IanvsExecutorLease.fromJson(
        _jsonMap(json['executorLease'], 'executorLease'),
      ),
    );
  }

  final String taskId;
  final String runId;
  final String dispatchEventId;
  final String agentName;
  final String workspacePath;
  final int attempt;
  final String reservationId;
  final IanvsExecutorLease executorLease;
}

enum IanvsSchedulerAdmissionReason {
  claimed,
  queueEmpty,
  globalCapacity,
  noExecutorCapacity,
  agentCapacity,
  runtimeUnavailable,
  runtimeStatusStale,
  workspaceBusy,
  retryNotReady,
  noMatchingRuntime,
  excluded,
}

final class IanvsSchedulerAdmission {
  const IanvsSchedulerAdmission({
    required this.reason,
    required this.retryable,
    required this.nextWakeAt,
    required this.selectedReservationId,
    required this.blockedTaskIds,
  });

  factory IanvsSchedulerAdmission.fromJson(Map<String, Object?> json) {
    final rawBlockedTaskIds = json['blockedTaskIds'] ?? const <Object?>[];
    if (rawBlockedTaskIds is! List) {
      throw const FormatException('Scheduler blockedTaskIds must be a list.');
    }
    return IanvsSchedulerAdmission(
      reason: _schedulerAdmissionReason(json['reason']),
      retryable: _requiredJsonBool(json, 'retryable'),
      nextWakeAt: _optionalJsonDateTime(json, 'nextWakeAt'),
      selectedReservationId: _optionalJsonString(json, 'selectedReservationId'),
      blockedTaskIds: List<String>.unmodifiable(
        rawBlockedTaskIds.map((value) {
          if (value is! String || value.isEmpty || value.trim() != value) {
            throw const FormatException(
              'Scheduler blockedTaskIds must contain canonical strings.',
            );
          }
          return value;
        }),
      ),
    );
  }

  final IanvsSchedulerAdmissionReason reason;
  final bool retryable;
  final DateTime? nextWakeAt;
  final String? selectedReservationId;
  final List<String> blockedTaskIds;
}

final class IanvsSchedulerClaimProjection {
  const IanvsSchedulerClaimProjection({
    required this.workflow,
    required this.taskInbox,
    required this.claim,
    required this.nextWakeAt,
    required this.admission,
  });

  factory IanvsSchedulerClaimProjection.fromJson(Map<String, Object?> json) {
    final rawClaim = json['claim'];
    return IanvsSchedulerClaimProjection(
      workflow: IanvsWorkflowProjection.fromJson(json),
      taskInbox: TaskInboxSnapshot.fromJsonStrict(json['taskInbox']),
      claim: rawClaim == null
          ? null
          : IanvsSchedulerClaim.fromJson(_jsonMap(rawClaim, 'claim')),
      nextWakeAt: _optionalJsonDateTime(json, 'nextWakeAt'),
      admission: IanvsSchedulerAdmission.fromJson(
        _jsonMap(json['admission'], 'admission'),
      ),
    );
  }

  final IanvsWorkflowProjection workflow;
  final TaskInboxSnapshot taskInbox;
  final IanvsSchedulerClaim? claim;
  final DateTime? nextWakeAt;
  final IanvsSchedulerAdmission admission;
}

final class FfiIanvsWorkflowNativeApi implements IanvsWorkflowNativeApi {
  FfiIanvsWorkflowNativeApi._(this._library) {
    _version = _library.lookupFunction<Uint32 Function(), int Function()>(
      'ianvs_acp_ffi_version',
    );
    _workflowNew = _library
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'ianvs_workflow_new',
        );
    _workflowFree = _library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('ianvs_workflow_free');
    _workflowOpen = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_open');
    _workflowApply = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_apply');
    _workflowSnapshot = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_snapshot');
    _stageTaskInbox = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_workflow_stage_task_inbox');
    _taskInboxSource = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_task_inbox_source');
    _materializeTaskInbox = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_materialize_task_inbox');
    _activateTaskInbox = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_activate_task_inbox');
    _applyTaskInbox = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_apply_task_inbox');
    _applyTaskInboxAsExecutor = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_apply_task_inbox_as_executor');
    _configureScheduler = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_scheduler_configure');
    _setSchedulerRuntimeStatus = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_scheduler_set_runtime_status');
    _schedulerClaimNext = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_scheduler_claim_next');
    _executorLeaseForRun = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_executor_lease_for_run');
    _runtimeEvents = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Uint64, Uint32),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int, int)
        >('ianvs_workflow_runtime_events');
    _executorLeaseCommand = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
          Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_workflow_executor_lease_command');
    _currentTaskInbox = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_current_task_inbox');
    _workflowLastError = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_workflow_last_error');
    _stringFree = _library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('ianvs_acp_string_free');
  }

  factory FfiIanvsWorkflowNativeApi.open({String? libraryPath}) {
    return FfiIanvsWorkflowNativeApi._(
      DynamicLibrary.open(
        libraryPath ?? FfiIanvsAcpNativeApi.resolveLibraryPath(),
      ),
    );
  }

  final DynamicLibrary _library;
  late final int Function() _version;
  late final Pointer<Void> Function() _workflowNew;
  late final void Function(Pointer<Void>) _workflowFree;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>) _workflowOpen;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _workflowApply;
  late final Pointer<Utf8> Function(Pointer<Void>) _workflowSnapshot;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
  _stageTaskInbox;
  late final Pointer<Utf8> Function(Pointer<Void>) _taskInboxSource;
  late final Pointer<Utf8> Function(Pointer<Void>) _materializeTaskInbox;
  late final Pointer<Utf8> Function(Pointer<Void>) _activateTaskInbox;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _applyTaskInbox;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _applyTaskInboxAsExecutor;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _configureScheduler;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _setSchedulerRuntimeStatus;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _schedulerClaimNext;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _executorLeaseForRun;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>, int, int)
  _runtimeEvents;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _executorLeaseCommand;
  late final Pointer<Utf8> Function(Pointer<Void>) _currentTaskInbox;
  late final Pointer<Utf8> Function(Pointer<Void>) _workflowLastError;
  late final void Function(Pointer<Utf8>) _stringFree;

  @override
  int get ffiVersion => _version();

  @override
  Object createWorkflow() {
    final workflow = _workflowNew();
    if (workflow == nullptr) {
      throw StateError('Failed to allocate Rust workflow.');
    }
    return workflow;
  }

  @override
  String? openWorkflow(Object workflow, String databasePath) {
    return _withUtf8(databasePath, (path) {
      return _takeNativeString(_workflowOpen(_pointer(workflow), path));
    });
  }

  @override
  String? applyWorkflow(Object workflow, Map<String, Object?> command) {
    return _withUtf8(jsonEncode(command), (encoded) {
      return _takeNativeString(_workflowApply(_pointer(workflow), encoded));
    });
  }

  @override
  String? snapshotWorkflow(Object workflow) {
    return _takeNativeString(_workflowSnapshot(_pointer(workflow)));
  }

  @override
  String? stageTaskInbox(
    Object workflow,
    Map<String, Object?> snapshot,
    String sourceChecksum,
  ) {
    return _withTwoUtf8(jsonEncode(snapshot), sourceChecksum, (
      encoded,
      checksum,
    ) {
      return _takeNativeString(
        _stageTaskInbox(_pointer(workflow), encoded, checksum),
      );
    });
  }

  @override
  String? taskInboxSource(Object workflow) {
    return _takeNativeString(_taskInboxSource(_pointer(workflow)));
  }

  @override
  String? materializeTaskInbox(Object workflow) {
    return _takeNativeString(_materializeTaskInbox(_pointer(workflow)));
  }

  @override
  String? activateTaskInbox(Object workflow) {
    return _takeNativeString(_activateTaskInbox(_pointer(workflow)));
  }

  @override
  String? applyTaskInbox(Object workflow, Map<String, Object?> command) {
    return _withUtf8(jsonEncode(command), (encoded) {
      return _takeNativeString(_applyTaskInbox(_pointer(workflow), encoded));
    });
  }

  @override
  String? applyTaskInboxAsExecutor(
    Object workflow,
    Map<String, Object?> request,
  ) {
    return _withUtf8(jsonEncode(request), (encoded) {
      return _takeNativeString(
        _applyTaskInboxAsExecutor(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? configureScheduler(Object workflow, Map<String, Object?> config) {
    return _withUtf8(jsonEncode(config), (encoded) {
      return _takeNativeString(
        _configureScheduler(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? setSchedulerRuntimeStatus(
    Object workflow,
    Map<String, Object?> status,
  ) {
    return _withUtf8(jsonEncode(status), (encoded) {
      return _takeNativeString(
        _setSchedulerRuntimeStatus(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? schedulerClaimNext(Object workflow, Map<String, Object?> request) {
    return _withUtf8(jsonEncode(request), (encoded) {
      return _takeNativeString(
        _schedulerClaimNext(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? executorLeaseForRun(Object workflow, String runId) {
    return _withUtf8(runId, (encoded) {
      return _takeNativeString(
        _executorLeaseForRun(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? runtimeEvents(
    Object workflow,
    String runId,
    int afterSequence,
    int limit,
  ) {
    return _withUtf8(runId, (encoded) {
      return _takeNativeString(
        _runtimeEvents(_pointer(workflow), encoded, afterSequence, limit),
      );
    });
  }

  @override
  String? executorLeaseCommand(Object workflow, Map<String, Object?> command) {
    return _withUtf8(jsonEncode(command), (encoded) {
      return _takeNativeString(
        _executorLeaseCommand(_pointer(workflow), encoded),
      );
    });
  }

  @override
  String? currentTaskInbox(Object workflow) {
    return _takeNativeString(_currentTaskInbox(_pointer(workflow)));
  }

  @override
  String? lastError(Object workflow) {
    return _takeNativeString(_workflowLastError(_pointer(workflow)));
  }

  @override
  void freeWorkflow(Object workflow) => _workflowFree(_pointer(workflow));

  Pointer<Void> _pointer(Object workflow) {
    if (workflow is! Pointer<Void>) {
      throw ArgumentError.value(workflow, 'workflow', 'invalid native handle');
    }
    return workflow;
  }

  String? _takeNativeString(Pointer<Utf8> value) {
    if (value == nullptr) {
      return null;
    }
    try {
      return value.toDartString();
    } finally {
      _stringFree(value);
    }
  }
}

T _withUtf8<T>(String value, T Function(Pointer<Utf8>) operation) {
  final pointer = value.toNativeUtf8();
  try {
    return operation(pointer);
  } finally {
    malloc.free(pointer);
  }
}

T _withTwoUtf8<T>(
  String first,
  String second,
  T Function(Pointer<Utf8>, Pointer<Utf8>) operation,
) {
  return _withUtf8(first, (firstPointer) {
    return _withUtf8(second, (secondPointer) {
      return operation(firstPointer, secondPointer);
    });
  });
}

String _requiredText(String value, String name) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    throw ArgumentError.value(value, name, 'must not be empty');
  }
  return trimmed;
}

Map<String, Object?> _jsonMap(Object? value, String name) {
  if (value is! Map) {
    throw FormatException('$name must be an object.');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

List<Object?> _jsonList(Object? value, String name) {
  if (value is! List) {
    throw FormatException('$name must be an array.');
  }
  return List<Object?>.from(value, growable: false);
}

String _requiredJsonString(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw FormatException('$name must be a canonical non-empty string.');
  }
  return value;
}

String? _optionalJsonString(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value == null) {
    return null;
  }
  if (value is! String || value.isEmpty || value.trim() != value) {
    throw FormatException('$name must be null or a canonical string.');
  }
  return value;
}

DateTime? _optionalJsonDateTime(Map<String, Object?> json, String name) {
  final value = _optionalJsonString(json, name);
  if (value == null) {
    return null;
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$name must be an ISO-8601 timestamp.');
  }
  return parsed;
}

DateTime _requiredJsonDateTime(Map<String, Object?> json, String name) {
  final value = _requiredJsonString(json, name);
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw FormatException('$name must be an ISO-8601 timestamp.');
  }
  return parsed;
}

int _nonnegativeInt(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! int || value < 0) {
    throw FormatException('$name must be a nonnegative int.');
  }
  return value;
}

bool _requiredJsonBool(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! bool) {
    throw FormatException('$name must be a boolean.');
  }
  return value;
}

List<String> _stringList(Object? value, String name) {
  final values = _jsonList(value, name);
  return values
      .map((item) {
        if (item is! String || item.isEmpty || item.trim() != item) {
          throw FormatException('$name entries must be canonical strings.');
        }
        return item;
      })
      .toList(growable: false);
}

IanvsWorkflowTaskStatus _taskStatus(Object? value) {
  return switch (value) {
    'inbox' => IanvsWorkflowTaskStatus.inbox,
    'queued' => IanvsWorkflowTaskStatus.queued,
    'dispatched' => IanvsWorkflowTaskStatus.dispatched,
    'running' => IanvsWorkflowTaskStatus.running,
    'blocked_on_permission' => IanvsWorkflowTaskStatus.blockedOnPermission,
    'blocked_on_user_input' => IanvsWorkflowTaskStatus.blockedOnUserInput,
    'collecting_artifacts' => IanvsWorkflowTaskStatus.collectingArtifacts,
    'needs_human_review' => IanvsWorkflowTaskStatus.needsHumanReview,
    'needs_changes' => IanvsWorkflowTaskStatus.needsChanges,
    'done' => IanvsWorkflowTaskStatus.done,
    'failed' => IanvsWorkflowTaskStatus.failed,
    'cancelled' => IanvsWorkflowTaskStatus.cancelled,
    'rejected' => IanvsWorkflowTaskStatus.rejected,
    _ => throw FormatException('Unknown workflow task status: $value'),
  };
}

IanvsWorkflowRunStatus _runStatus(Object? value) {
  return switch (value) {
    'dispatched' => IanvsWorkflowRunStatus.dispatched,
    'running' => IanvsWorkflowRunStatus.running,
    'waiting_permission' => IanvsWorkflowRunStatus.waitingPermission,
    'waiting_user_input' => IanvsWorkflowRunStatus.waitingUserInput,
    'collecting_artifacts' => IanvsWorkflowRunStatus.collectingArtifacts,
    'needs_human_review' => IanvsWorkflowRunStatus.needsHumanReview,
    'needs_changes' => IanvsWorkflowRunStatus.needsChanges,
    'succeeded' => IanvsWorkflowRunStatus.succeeded,
    'failed' => IanvsWorkflowRunStatus.failed,
    'cancelled' => IanvsWorkflowRunStatus.cancelled,
    'rejected' => IanvsWorkflowRunStatus.rejected,
    _ => throw FormatException('Unknown workflow run status: $value'),
  };
}

IanvsSchedulerAdmissionReason _schedulerAdmissionReason(Object? value) {
  return switch (value) {
    'claimed' => IanvsSchedulerAdmissionReason.claimed,
    'queue_empty' => IanvsSchedulerAdmissionReason.queueEmpty,
    'global_capacity' => IanvsSchedulerAdmissionReason.globalCapacity,
    'no_executor_capacity' => IanvsSchedulerAdmissionReason.noExecutorCapacity,
    'agent_capacity' => IanvsSchedulerAdmissionReason.agentCapacity,
    'runtime_unavailable' => IanvsSchedulerAdmissionReason.runtimeUnavailable,
    'runtime_status_stale' => IanvsSchedulerAdmissionReason.runtimeStatusStale,
    'workspace_busy' => IanvsSchedulerAdmissionReason.workspaceBusy,
    'retry_not_ready' => IanvsSchedulerAdmissionReason.retryNotReady,
    'no_matching_runtime' => IanvsSchedulerAdmissionReason.noMatchingRuntime,
    'excluded' => IanvsSchedulerAdmissionReason.excluded,
    _ => throw FormatException('Unknown scheduler admission reason: $value'),
  };
}

IanvsExecutorLeaseState _executorLeaseState(Object? value) {
  return switch (value) {
    'claimed' => IanvsExecutorLeaseState.claimed,
    'starting' => IanvsExecutorLeaseState.starting,
    'active' => IanvsExecutorLeaseState.active,
    'expired' => IanvsExecutorLeaseState.expired,
    'released' => IanvsExecutorLeaseState.released,
    'superseded' => IanvsExecutorLeaseState.superseded,
    _ => throw FormatException('Unknown executor lease state: $value'),
  };
}
