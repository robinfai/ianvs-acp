import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'runtime_registry.dart';
import 'workspace_resource.dart';

class TaskRepositorySnapshot {
  const TaskRepositorySnapshot({
    required this.revision,
    required this.snapshot,
  });

  final int revision;
  final TaskInboxSnapshot snapshot;
}

class TaskRunCreation {
  const TaskRunCreation({required this.task, required this.run});

  final TaskRecord task;
  final TaskRunRecord run;
}

class TaskClaim {
  const TaskClaim({
    required this.task,
    required this.run,
    required this.dispatchEvent,
    this.reservationId,
    this.executorLease,
  });

  final TaskRecord task;
  final TaskRunRecord run;
  final TaskEventRecord dispatchEvent;
  final String? reservationId;
  final TaskExecutorLease? executorLease;
}

enum TaskExecutorLeaseState {
  claimed,
  starting,
  active,
  expired,
  released,
  superseded,
}

class TaskExecutorLease {
  const TaskExecutorLease({
    required this.leaseId,
    required this.runId,
    required this.executorId,
    required this.generation,
    required this.reservationId,
    required this.acquiredAt,
    required this.expiresAt,
    required this.lastHeartbeatAt,
    required this.state,
    this.startAcknowledgedAt,
    this.releasedAt,
  });

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
  final TaskExecutorLeaseState state;
}

class TaskExecutorCommandContext {
  const TaskExecutorCommandContext({
    required this.runId,
    required this.executorLeaseId,
    required this.generation,
    required this.commandId,
    required this.now,
  });

  final String runId;
  final String executorLeaseId;
  final int generation;
  final String commandId;
  final DateTime now;
}

class TaskStoredRuntimeEvent {
  const TaskStoredRuntimeEvent({
    required this.sequence,
    required this.event,
    this.executorLeaseId,
    this.executorGeneration,
    this.commandId,
  });

  final int sequence;
  final TaskEventRecord event;
  final String? executorLeaseId;
  final int? executorGeneration;
  final String? commandId;
}

class TaskRuntimeEventPage {
  TaskRuntimeEventPage({
    required this.runId,
    required this.afterSequence,
    required List<TaskStoredRuntimeEvent> events,
    required this.nextSequence,
    required this.hasMore,
  }) : events = List<TaskStoredRuntimeEvent>.unmodifiable(events);

  final String runId;
  final int afterSequence;
  final List<TaskStoredRuntimeEvent> events;
  final int nextSequence;
  final bool hasMore;
}

class TaskCapacityReservation {
  const TaskCapacityReservation({
    required this.reservationId,
    required this.agentName,
    required this.hostInstanceId,
    required this.createdAt,
    required this.expiresAt,
  });

  final String reservationId;
  final String agentName;
  final String hostInstanceId;
  final DateTime createdAt;
  final DateTime expiresAt;
}

enum TaskSchedulingAdmissionReason {
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

class TaskSchedulingAdmission {
  const TaskSchedulingAdmission({
    required this.reason,
    required this.retryable,
    this.nextWakeAt,
    this.selectedReservationId,
    this.blockedTaskIds = const <String>[],
  });

  final TaskSchedulingAdmissionReason reason;
  final bool retryable;
  final DateTime? nextWakeAt;
  final String? selectedReservationId;
  final List<String> blockedTaskIds;
}

class TaskSchedulingPoll {
  const TaskSchedulingPoll({
    required this.repository,
    required this.claim,
    required this.nextWakeAt,
    this.admission = const TaskSchedulingAdmission(
      reason: TaskSchedulingAdmissionReason.queueEmpty,
      retryable: false,
    ),
  });

  final TaskRepositorySnapshot repository;
  final TaskClaim? claim;
  final DateTime? nextWakeAt;
  final TaskSchedulingAdmission admission;
}

class TaskDeleteExpectation {
  const TaskDeleteExpectation({
    required this.task,
    this.runs = const <TaskRunRecord>[],
    this.events = const <TaskEventRecord>[],
    this.artifacts = const <ArtifactRecord>[],
    this.approvals = const <ApprovalRequestRecord>[],
  });

  factory TaskDeleteExpectation.fromSnapshot(
    TaskInboxSnapshot snapshot,
    String taskId,
  ) {
    final target = taskId.trim();
    TaskRecord? task;
    for (final candidate in snapshot.tasks) {
      if (candidate.id == target) {
        task = candidate;
        break;
      }
    }
    if (task == null) throw StateError('Task not found: $taskId');
    return TaskDeleteExpectation(
      task: task,
      runs: snapshot.runs
          .where((run) => run.taskId == target)
          .toList(growable: false),
      events: snapshot.events
          .where((event) => event.taskId == target)
          .toList(growable: false),
      artifacts: snapshot.artifacts
          .where((artifact) => artifact.taskId == target)
          .toList(growable: false),
      approvals: snapshot.approvals
          .where((approval) => approval.taskId == target)
          .toList(growable: false),
    );
  }

  final TaskRecord task;
  final List<TaskRunRecord> runs;
  final List<TaskEventRecord> events;
  final List<ArtifactRecord> artifacts;
  final List<ApprovalRequestRecord> approvals;
}

class TaskRepositoryConflict implements Exception {
  const TaskRepositoryConflict(this.message);

  final String message;

  @override
  String toString() => 'TaskRepositoryConflict: $message';
}

class RawPayloadPurgeResult {
  const RawPayloadPurgeResult({
    this.skipped = false,
    this.eventsPurged = 0,
    this.runsPurged = 0,
    this.artifactsPurged = 0,
  });

  final bool skipped;
  final int eventsPurged;
  final int runsPurged;
  final int artifactsPurged;

  int get totalPurged => eventsPurged + runsPurged + artifactsPurged;
}

bool taskRepositoryRecordHasCanonicalFields(Object record) {
  bool requiredText(String value) => value.isNotEmpty && value.trim() == value;
  bool optionalText(String? value) =>
      value == null || (value.isNotEmpty && value.trim() == value);
  bool optionalContent(String? value) => value == null || value.isNotEmpty;
  return switch (record) {
    TaskRecord value =>
      requiredText(value.id) &&
          requiredText(value.title) &&
          requiredText(value.workspacePath) &&
          requiredText(value.agentName) &&
          optionalText(value.sessionId) &&
          optionalText(value.currentRunId) &&
          optionalText(value.summary) &&
          optionalText(value.error) &&
          optionalText(value.resourceId),
    TaskRunRecord value =>
      requiredText(value.id) &&
          requiredText(value.taskId) &&
          value.attempt > 0 &&
          optionalText(value.sessionId) &&
          optionalText(value.promptSnapshot) &&
          optionalText(value.model) &&
          optionalText(value.error),
    TaskEventRecord value =>
      requiredText(value.id) &&
          requiredText(value.taskId) &&
          requiredText(value.runId) &&
          optionalText(value.sessionId),
    ArtifactRecord value =>
      requiredText(value.id) &&
          requiredText(value.taskId) &&
          requiredText(value.runId) &&
          requiredText(value.title) &&
          optionalText(value.path) &&
          optionalContent(value.contentPreview) &&
          optionalText(value.sha256) &&
          (value.sizeBytes == null || value.sizeBytes! >= 0),
    ApprovalRequestRecord value =>
      requiredText(value.id) &&
          requiredText(value.taskId) &&
          optionalText(value.runId) &&
          optionalText(value.destination) &&
          optionalText(value.riskSummary) &&
          optionalText(value.rationale),
    WorkspaceResource value =>
      requiredText(value.id) &&
          requiredText(value.label) &&
          value.ref['path'] is String &&
          requiredText(value.ref['path']! as String),
    _ => false,
  };
}

enum TaskMigrationPhase { inactive, importing, active }

enum TaskImportDisposition { imported, alreadyImporting, alreadyActive }

class TaskMigrationMetadata {
  const TaskMigrationMetadata({required this.phase, this.sourceChecksum});

  final TaskMigrationPhase phase;
  final String? sourceChecksum;
}

abstract class TaskRepository {
  Future<void> initialize();

  Future<TaskRepositorySnapshot> loadRepository();

  Future<TaskRecord> insertTask(TaskRecord task);

  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> deleteTask(
    TaskDeleteExpectation expected, {
    required DateTime updatedAt,
  });

  Future<TaskRunCreation> createRun({
    required TaskRecord expectedTask,
    required TaskRecord task,
    required TaskRunRecord run,
  });

  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  });

  Future<TaskRunRecord> updateRun(
    TaskRunRecord run, {
    required TaskRunRecord expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> appendEvents(
    List<TaskEventRecord> events, {
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
    TaskExecutorCommandContext? executorContext,
  });

  Future<void> upsertResource(
    WorkspaceResource resource, {
    WorkspaceResource? expected,
    required DateTime updatedAt,
  });

  Future<int> revision();

  Future<void> close();
}

abstract interface class AtomicTaskClaimMetadataRepository {
  Future<TaskClaim?> claimTaskWithMetadata(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
    required Map<String, Object?> claimedMetadata,
  });
}

/// Marker for repositories whose returned snapshot is the complete projection
/// of an external state-machine authority rather than an independently mutable
/// Dart model.
abstract interface class AuthoritativeTaskRepositoryProjection {
  TaskRepositorySnapshot get authoritativeProjection;
}

abstract interface class AtomicTaskSchedulingRepository {
  Future<void> configureScheduler({required int maxConcurrentTasks});

  Future<void> publishRuntimeStatus(LocalRuntimeStatus status);

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
  });
}

abstract interface class ExecutorLeaseTaskRepository {
  Future<TaskExecutorLease?> executorLeaseForRun(String runId);

  Future<TaskExecutorLease> acknowledgeExecutorStart({
    required TaskExecutorCommandContext context,
    required DateTime nextExpiresAt,
  });

  Future<TaskExecutorLease> heartbeatExecutor({
    required TaskExecutorCommandContext context,
    required DateTime nextExpiresAt,
  });

  Future<TaskExecutorLease> releaseExecutor({
    required TaskExecutorCommandContext context,
    bool cancelled = false,
  });
}

abstract interface class RuntimeEventTaskRepository {
  Future<TaskRuntimeEventPage> runtimeEvents({
    required String runId,
    required int afterSequence,
    int limit = 200,
  });
}

abstract interface class RawPayloadMaintenanceRepository {
  Future<RawPayloadPurgeResult> purgeRawPayloads({
    required DateTime now,
    Duration retention = const Duration(days: 30),
    bool force = false,
  });
}

abstract class TaskMigrationRepository {
  Future<TaskMigrationMetadata> migrationMetadata();

  Future<bool> isActive();

  Future<TaskImportDisposition> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  });

  Future<void> rollbackImport(String checksum);

  Future<void> activateImport(String checksum);

  Future<void> activateVerifiedSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  });
}
