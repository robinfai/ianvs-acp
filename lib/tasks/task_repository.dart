import 'task_inbox_snapshot.dart';
import 'task_record.dart';
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
  });

  final TaskRecord task;
  final TaskRunRecord run;
  final TaskEventRecord dispatchEvent;
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
  });

  Future<void> appendEvents(
    List<TaskEventRecord> events, {
    required DateTime updatedAt,
  });

  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  });

  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  });

  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
  });

  Future<void> upsertResource(
    WorkspaceResource resource, {
    WorkspaceResource? expected,
    required DateTime updatedAt,
  });

  Future<int> revision();

  Future<void> close();
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
