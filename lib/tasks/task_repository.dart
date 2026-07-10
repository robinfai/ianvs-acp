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

class TaskClaim {
  const TaskClaim({required this.task, required this.run});

  final TaskRecord task;
  final TaskRunRecord run;
}

abstract class TaskRepository {
  Future<void> initialize();

  // Kept distinct from the temporary TaskStore.load compatibility method.
  // TaskStore is removed when controllers move to row-level writes.
  Future<TaskRepositorySnapshot> loadRepository();

  Future<TaskRecord> insertTask(TaskRecord task);

  Future<TaskRecord> updateTask(TaskRecord task);

  Future<TaskClaim?> claimTask(String taskId, TaskRunRecord run);

  Future<TaskRunRecord> updateRun(TaskRunRecord run);

  Future<void> appendEvents(List<TaskEventRecord> events);

  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> artifacts,
  });

  Future<void> upsertApproval(ApprovalRequestRecord approval);

  Future<void> upsertResource(WorkspaceResource resource);

  Future<int> revision();

  Future<void> close();
}

abstract class TaskMigrationRepository {
  Future<bool> isActive();

  Future<void> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  });

  Future<void> rollbackImport(String checksum);

  Future<void> activateImport(String checksum);
}
