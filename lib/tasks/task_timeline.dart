import 'task_inbox_snapshot.dart';
import 'task_record.dart';

enum TaskTimelineEntryKind { runStarted, runEnded, event, artifact, approval }

class TaskTimelineEntry {
  const TaskTimelineEntry({
    required this.id,
    required this.kind,
    required this.taskId,
    required this.timestamp,
    required this.title,
    this.runId,
    this.detail,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final TaskTimelineEntryKind kind;
  final String taskId;
  final String? runId;
  final DateTime timestamp;
  final String title;
  final String? detail;
  final Map<String, Object?> metadata;
}

List<TaskTimelineEntry> buildTaskTimeline(
  TaskInboxSnapshot snapshot,
  String taskId,
) {
  final target = taskId.trim();
  if (target.isEmpty) return const <TaskTimelineEntry>[];
  final entries = <_RankedTimelineEntry>[];

  for (final run in snapshot.runs) {
    if (run.taskId != target) continue;
    entries.add(
      _RankedTimelineEntry(
        rank: 0,
        entry: TaskTimelineEntry(
          id: 'run-${run.id}-started',
          kind: TaskTimelineEntryKind.runStarted,
          taskId: run.taskId,
          runId: run.id,
          timestamp: run.startedAt,
          title: 'Run #${run.attempt} started',
          detail: run.promptSnapshot,
          metadata: <String, Object?>{
            'run_id': run.id,
            'attempt': run.attempt,
            'status': run.status.name,
            if (run.sessionId != null) 'session_id': run.sessionId,
            if (run.model != null) 'model': run.model,
          },
        ),
      ),
    );
    final endedAt = run.endedAt;
    if (endedAt != null) {
      entries.add(
        _RankedTimelineEntry(
          rank: 4,
          entry: TaskTimelineEntry(
            id: 'run-${run.id}-ended',
            kind: TaskTimelineEntryKind.runEnded,
            taskId: run.taskId,
            runId: run.id,
            timestamp: endedAt,
            title: 'Run #${run.attempt} ${_runEndLabel(run.status)}',
            detail: run.error,
            metadata: <String, Object?>{
              'run_id': run.id,
              'attempt': run.attempt,
              'status': run.status.name,
              if (run.sessionId != null) 'session_id': run.sessionId,
            },
          ),
        ),
      );
    }
  }

  for (final event in snapshot.events) {
    if (event.taskId != target) continue;
    entries.add(
      _RankedTimelineEntry(
        rank: 1,
        entry: TaskTimelineEntry(
          id: event.id,
          kind: TaskTimelineEntryKind.event,
          taskId: event.taskId,
          runId: event.runId,
          timestamp: event.createdAt,
          title: event.text,
          metadata: <String, Object?>{
            ...event.metadata,
            'event_kind': event.kind.name,
            if (event.sessionId != null) 'session_id': event.sessionId,
          },
        ),
      ),
    );
  }

  for (final artifact in snapshot.artifacts) {
    if (artifact.taskId != target) continue;
    entries.add(
      _RankedTimelineEntry(
        rank: 2,
        entry: TaskTimelineEntry(
          id: artifact.id,
          kind: TaskTimelineEntryKind.artifact,
          taskId: artifact.taskId,
          runId: artifact.runId,
          timestamp: artifact.createdAt,
          title: artifact.title,
          detail: artifact.contentPreview,
          metadata: <String, Object?>{
            ...artifact.metadata,
            'artifact_kind': artifact.kind.name,
            'artifact_status': artifact.status.name,
            if (artifact.path != null) 'path': artifact.path,
            if (artifact.sha256 != null) 'sha256': artifact.sha256,
            if (artifact.sizeBytes != null) 'size_bytes': artifact.sizeBytes,
          },
        ),
      ),
    );
  }

  for (final approval in snapshot.approvals) {
    if (approval.taskId != target) continue;
    entries.add(
      _RankedTimelineEntry(
        rank: 3,
        entry: TaskTimelineEntry(
          id: approval.id,
          kind: TaskTimelineEntryKind.approval,
          taskId: approval.taskId,
          runId: approval.runId,
          timestamp: approval.createdAt,
          title:
              '${_approvalKindLabel(approval.kind)} approval '
              '${approval.status.name}',
          detail: approval.rationale,
          metadata: <String, Object?>{
            ...approval.metadata,
            'approval_kind': approval.kind.name,
            'approval_status': approval.status.name,
            if (approval.resolvedAt != null)
              'resolved_at': approval.resolvedAt!.toIso8601String(),
          },
        ),
      ),
    );
  }

  entries.sort((a, b) {
    final timestamp = a.entry.timestamp.compareTo(b.entry.timestamp);
    if (timestamp != 0) return timestamp;
    final rank = a.rank.compareTo(b.rank);
    if (rank != 0) return rank;
    return a.entry.id.compareTo(b.entry.id);
  });
  return List.unmodifiable(entries.map((entry) => entry.entry));
}

class _RankedTimelineEntry {
  const _RankedTimelineEntry({required this.rank, required this.entry});

  final int rank;
  final TaskTimelineEntry entry;
}

String _runEndLabel(TaskStatus status) {
  return switch (status) {
    TaskStatus.needsHumanReview => 'completed',
    TaskStatus.done => 'completed',
    TaskStatus.failed => 'failed',
    TaskStatus.cancelled => 'cancelled',
    TaskStatus.rejected => 'rejected',
    TaskStatus.needsChanges => 'needs changes',
    _ => status.name,
  };
}

String _approvalKindLabel(ApprovalKind kind) {
  return switch (kind) {
    ApprovalKind.toolPermission => 'Tool permission',
  };
}
