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

  String? configureScheduler(Object workflow, Map<String, Object?> config);

  String? setSchedulerRuntimeStatus(
    Object workflow,
    Map<String, Object?> status,
  );

  String? schedulerClaimNext(Object workflow, Map<String, Object?> request);

  String? currentTaskInbox(Object workflow);

  String? lastError(Object workflow);

  void freeWorkflow(Object workflow);
}

abstract interface class IanvsWorkflowAuthority {
  IanvsWorkflowProjection open(String databasePath);

  IanvsTaskInboxStageProjection stageTaskInbox({
    required TaskInboxSnapshot source,
    required String sourceChecksum,
  });

  TaskInboxSnapshot? taskInboxSource();

  IanvsTaskInboxMaterializedProjection materializeTaskInbox();

  IanvsTaskInboxMaterializedProjection activateTaskInbox();

  IanvsTaskInboxMaterializedProjection applyTaskInbox(
    IanvsTaskInboxCommand command,
  );

  IanvsWorkflowProjection configureScheduler({required int maxConcurrentTasks});

  IanvsWorkflowProjection setSchedulerRuntimeStatus(
    IanvsSchedulerRuntimeStatus status,
  );

  IanvsSchedulerClaimProjection schedulerClaimNext({
    required String runId,
    required String dispatchEventId,
    required DateTime now,
    List<String> excludedTaskIds = const <String>[],
  });

  TaskInboxSnapshot? currentTaskInbox();

  void dispose();
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

  static const int expectedFfiVersion = 5;

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
  IanvsWorkflowProjection configureScheduler({
    required int maxConcurrentTasks,
  }) {
    _ensureOpened();
    if (maxConcurrentTasks < 1) {
      throw ArgumentError.value(
        maxConcurrentTasks,
        'maxConcurrentTasks',
        'must be positive',
      );
    }
    return _decodeProjection(
      _native.configureScheduler(_workflow, <String, Object?>{
        'maxConcurrentTasks': maxConcurrentTasks,
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
    required DateTime now,
    List<String> excludedTaskIds = const <String>[],
  }) {
    _ensureOpened();
    final encoded = _native.schedulerClaimNext(_workflow, <String, Object?>{
      'runId': _requiredText(runId, 'runId'),
      'dispatchEventId': _requiredText(dispatchEventId, 'dispatchEventId'),
      'now': now.toIso8601String(),
      'excludedTaskIds': excludedTaskIds
          .map((taskId) => _requiredText(taskId, 'excludedTaskIds'))
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

final class IanvsWorkflowProjection {
  IanvsWorkflowProjection._({
    required this.schemaVersion,
    required this.revision,
    required this.migration,
    required List<IanvsWorkflowTask> tasks,
    required List<IanvsWorkflowRun> runs,
    required List<String> recoveredFailedTaskIds,
  }) : tasks = List<IanvsWorkflowTask>.unmodifiable(tasks),
       runs = List<IanvsWorkflowRun>.unmodifiable(runs),
       recoveredFailedTaskIds = List<String>.unmodifiable(
         recoveredFailedTaskIds,
       );

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
        : _jsonMap(json['recovery'], 'recovery');
    final recovered = recovery == null
        ? const <String>[]
        : _stringList(recovery['failedTaskIds'], 'recovery.failedTaskIds');
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
      recoveredFailedTaskIds: recovered,
    );
  }

  static const int supportedSchemaVersion = 1;

  final int schemaVersion;
  final int revision;
  final IanvsWorkflowMigration migration;
  final List<IanvsWorkflowTask> tasks;
  final List<IanvsWorkflowRun> runs;
  final List<String> recoveredFailedTaskIds;
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
    );
  }

  final String taskId;
  final String runId;
  final String dispatchEventId;
  final String agentName;
  final String workspacePath;
  final int attempt;
}

final class IanvsSchedulerClaimProjection {
  const IanvsSchedulerClaimProjection({
    required this.workflow,
    required this.taskInbox,
    required this.claim,
    required this.nextWakeAt,
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
    );
  }

  final IanvsWorkflowProjection workflow;
  final TaskInboxSnapshot taskInbox;
  final IanvsSchedulerClaim? claim;
  final DateTime? nextWakeAt;
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
  _configureScheduler;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _setSchedulerRuntimeStatus;
  late final Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)
  _schedulerClaimNext;
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

int _nonnegativeInt(Map<String, Object?> json, String name) {
  final value = json[name];
  if (value is! int || value < 0) {
    throw FormatException('$name must be a nonnegative int.');
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
