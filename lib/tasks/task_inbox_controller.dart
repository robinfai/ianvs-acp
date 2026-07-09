import 'package:flutter/foundation.dart';

import '../workspace/workspace.dart';
import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'task_store.dart';
import 'task_timeline.dart';

typedef TaskInboxClock = DateTime Function();
typedef TaskInboxIdGenerator = String Function(String prefix);

const Object _unchanged = Object();

class TaskInboxController extends ChangeNotifier {
  TaskInboxController({
    required this.store,
    TaskInboxClock? clock,
    this.idGenerator,
  }) : _clock = clock ?? DateTime.now;

  final TaskStore store;
  final TaskInboxClock _clock;
  final TaskInboxIdGenerator? idGenerator;
  TaskInboxSnapshot _snapshot = TaskInboxSnapshot.empty();
  bool _loaded = false;
  int _idCounter = 0;

  TaskInboxSnapshot get snapshot => _snapshot;

  List<TaskRecord> get tasks => _snapshot.tasks;

  List<TaskRunRecord> get runs => _snapshot.runs;

  List<TaskEventRecord> get events => _snapshot.events;

  List<ArtifactRecord> get artifacts => _snapshot.artifacts;

  List<ApprovalRequestRecord> get approvals => _snapshot.approvals;

  List<TaskTimelineEntry> timelineForTask(String taskId) {
    return buildTaskTimeline(_snapshot, taskId);
  }

  Future<void> load() async {
    _snapshot = await store.load();
    _loaded = true;
    notifyListeners();
  }

  TaskRecord? taskById(String id) {
    final target = id.trim();
    if (target.isEmpty) return null;
    for (final task in _snapshot.tasks) {
      if (task.id == target) return task;
    }
    return null;
  }

  List<TaskRecord> tasksForStatus(TaskStatus status) {
    return _snapshot.tasks
        .where((task) => task.status == status)
        .toList(growable: false);
  }

  List<TaskRecord> tasksForWorkspace(String workspacePath) {
    final normalized = normalizeWorkspacePath(workspacePath);
    return _snapshot.tasks
        .where(
          (task) => normalizeWorkspacePath(task.workspacePath) == normalized,
        )
        .toList(growable: false);
  }

  Future<TaskRecord> createTask({
    required String title,
    required String description,
    required String workspacePath,
    required String agentName,
    TaskPriority priority = TaskPriority.normal,
    String? resourceId,
    List<String> skillIds = const <String>[],
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    await _ensureLoaded();
    final now = _clock();
    final task = TaskRecord(
      id: _newId('task'),
      title: _requiredText(title, 'title'),
      description: description.trim(),
      workspacePath: _requiredPath(workspacePath),
      agentName: _requiredText(agentName, 'agentName'),
      status: TaskStatus.inbox,
      priority: priority,
      createdAt: now,
      updatedAt: now,
      resourceId: _trimmedOrNull(resourceId),
      skillIds: _cleanStringList(skillIds),
      metadata: Map.unmodifiable(metadata),
    );

    await _replaceTasks([..._snapshot.tasks, task], updatedAt: now);
    return task;
  }

  Future<TaskRunRecord> createRun({
    required String taskId,
    TaskStatus status = TaskStatus.running,
    String? sessionId,
    String? promptSnapshot,
    String? model,
  }) async {
    await _ensureLoaded();
    final taskIndex = _indexOfTask(taskId);
    if (taskIndex < 0) throw StateError('Task not found: $taskId');

    final now = _clock();
    final run = TaskRunRecord(
      id: _newId('run'),
      taskId: _snapshot.tasks[taskIndex].id,
      attempt:
          _snapshot.runs.where((run) => run.taskId == taskId.trim()).length + 1,
      status: status,
      startedAt: now,
      sessionId: _trimmedOrNull(sessionId),
      promptSnapshot: _trimmedOrNull(promptSnapshot),
      model: _trimmedOrNull(model),
    );
    final tasks = [..._snapshot.tasks];
    tasks[taskIndex] = tasks[taskIndex].copyWith(
      status: status,
      currentRunId: run.id,
      updatedAt: now,
      sessionId: run.sessionId,
    );
    _snapshot = _snapshot.copyWith(
      tasks: _dedupeTasks(tasks),
      runs: [..._snapshot.runs, run],
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    return run;
  }

  Future<TaskRunRecord> updateRun(
    String runId, {
    TaskStatus? status,
    DateTime? endedAt,
    String? sessionId,
    Object? promptSnapshot = _unchanged,
    Object? model = _unchanged,
    String? error,
  }) async {
    await _ensureLoaded();
    final target = runId.trim();
    final index = _snapshot.runs.indexWhere((run) => run.id == target);
    if (index < 0) throw StateError('Task run not found: $runId');

    final now = _clock();
    final existing = _snapshot.runs[index];
    final updated = existing.copyWith(
      status: status,
      endedAt: endedAt ?? existing.endedAt,
      sessionId: sessionId ?? existing.sessionId,
      promptSnapshot: identical(promptSnapshot, _unchanged)
          ? existing.promptSnapshot
          : _trimmedOrNull(promptSnapshot as String?),
      model: identical(model, _unchanged)
          ? existing.model
          : _trimmedOrNull(model as String?),
      error: error ?? existing.error,
    );
    final runs = [..._snapshot.runs];
    runs[index] = updated;
    _snapshot = _snapshot.copyWith(runs: runs, updatedAt: now);
    await store.save(_snapshot);
    notifyListeners();
    return updated;
  }

  Future<TaskEventRecord> appendEvent({
    required String taskId,
    required String runId,
    required TaskEventKind kind,
    required String text,
    String? sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final targetRunId = runId.trim();
    TaskRunRecord? run;
    for (final candidate in _snapshot.runs) {
      if (candidate.id == targetRunId) {
        run = candidate;
        break;
      }
    }
    if (run == null) throw StateError('Task run not found: $runId');
    final now = _clock();
    final event = TaskEventRecord(
      id: _newId('event'),
      taskId: task.id,
      runId: run.id,
      kind: kind,
      text: text.trim(),
      createdAt: now,
      sessionId: _trimmedOrNull(sessionId),
      metadata: Map.unmodifiable(metadata),
    );
    _snapshot = _snapshot.copyWith(
      events: [..._snapshot.events, event],
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    return event;
  }

  Future<List<ArtifactRecord>> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> artifacts,
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final targetRunId = runId.trim();
    TaskRunRecord? run;
    for (final candidate in _snapshot.runs) {
      if (candidate.id == targetRunId) {
        run = candidate;
        break;
      }
    }
    if (run == null) throw StateError('Task run not found: $runId');

    final artifactIds = <String>{};
    for (final artifact in artifacts) {
      final artifactId = artifact.id.trim();
      if (artifactId.isEmpty) {
        throw StateError('Artifact id is required.');
      }
      if (!artifactIds.add(artifactId)) {
        throw StateError('Duplicate artifact id: $artifactId');
      }
      if (artifact.taskId != task.id || artifact.runId != run.id) {
        throw StateError('Artifact does not belong to task run: $artifactId');
      }
    }

    final now = _clock();
    final retained = _snapshot.artifacts
        .where(
          (artifact) =>
              artifact.taskId != task.id || artifact.runId != targetRunId,
        )
        .toList(growable: true);
    retained.addAll(artifacts);
    _snapshot = _snapshot.copyWith(
      artifacts: List.unmodifiable(retained),
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    return List.unmodifiable(artifacts);
  }

  Future<List<ArtifactRecord>> reviewArtifactsForRun({
    required String taskId,
    required String runId,
    List<String> approvedArtifactIds = const <String>[],
    List<String> rejectedArtifactIds = const <String>[],
    String? rationale,
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final run = _runById(runId);
    if (run == null || run.taskId != task.id) {
      throw StateError('Task run not found: $runId');
    }

    final approvedIds = _artifactIdSet(approvedArtifactIds);
    final rejectedIds = _artifactIdSet(rejectedArtifactIds);
    final overlap = approvedIds.intersection(rejectedIds);
    if (overlap.isNotEmpty) {
      throw StateError(
        'Artifact cannot be both approved and rejected: ${overlap.join(', ')}',
      );
    }

    final runArtifacts = _artifactsForTaskRun(task.id, run.id);
    final knownIds = runArtifacts.map((artifact) => artifact.id).toSet();
    final unknownIds = approvedIds.union(rejectedIds).difference(knownIds);
    if (unknownIds.isNotEmpty) {
      throw StateError('Artifact not found: ${unknownIds.join(', ')}');
    }

    final reviewedIds = <String>[];
    final artifacts = <ArtifactRecord>[];
    for (final artifact in _snapshot.artifacts) {
      if (artifact.taskId != task.id || artifact.runId != run.id) {
        artifacts.add(artifact);
        continue;
      }
      if (approvedIds.contains(artifact.id)) {
        artifacts.add(artifact.copyWith(status: ArtifactStatus.approved));
        continue;
      }
      if (rejectedIds.contains(artifact.id)) {
        artifacts.add(artifact.copyWith(status: ArtifactStatus.rejected));
        continue;
      }
      if (artifact.status == ArtifactStatus.candidate) {
        reviewedIds.add(artifact.id);
        artifacts.add(artifact.copyWith(status: ArtifactStatus.reviewed));
        continue;
      }
      artifacts.add(artifact);
    }

    final now = _clock();
    _snapshot = _snapshot.copyWith(
      artifacts: List.unmodifiable(artifacts),
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();

    await appendEvent(
      taskId: task.id,
      runId: run.id,
      kind: TaskEventKind.review,
      text: 'Artifact review completed.',
      sessionId: task.sessionId,
      metadata: <String, Object?>{
        'review_action': 'review_artifacts',
        'approved_artifact_ids': approvedIds.toList(growable: false),
        'rejected_artifact_ids': rejectedIds.toList(growable: false),
        'reviewed_artifact_ids': reviewedIds,
        if (_trimmedOrNull(rationale) != null)
          'rationale': _trimmedOrNull(rationale),
      },
    );
    return _artifactsForTaskRun(task.id, run.id);
  }

  Future<List<ArtifactRecord>> updateArtifactStatuses({
    required String taskId,
    required Iterable<String> artifactIds,
    required ArtifactStatus status,
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final ids = _artifactIdSet(artifactIds);
    if (ids.isEmpty) return const <ArtifactRecord>[];

    final knownIds = _snapshot.artifacts
        .where((artifact) => artifact.taskId == task.id)
        .map((artifact) => artifact.id)
        .toSet();
    final unknownIds = ids.difference(knownIds);
    if (unknownIds.isNotEmpty) {
      throw StateError('Artifact not found: ${unknownIds.join(', ')}');
    }

    final updatedArtifacts = <ArtifactRecord>[];
    final changed = <ArtifactRecord>[];
    for (final artifact in _snapshot.artifacts) {
      if (artifact.taskId == task.id && ids.contains(artifact.id)) {
        final updated = artifact.copyWith(status: status);
        updatedArtifacts.add(updated);
        changed.add(updated);
      } else {
        updatedArtifacts.add(artifact);
      }
    }

    final now = _clock();
    _snapshot = _snapshot.copyWith(
      artifacts: List.unmodifiable(updatedArtifacts),
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    return List.unmodifiable(changed);
  }

  Future<TaskRecord> markTaskDoneLocally(
    String taskId, {
    String? rationale,
  }) async {
    final task = await updateTaskStatus(
      taskId,
      TaskStatus.done,
      summary: 'Marked done locally.',
    );
    await _appendReviewEventIfPossible(
      task,
      'Marked done locally.',
      metadata: <String, Object?>{
        'review_action': 'mark_done_locally',
        if (_trimmedOrNull(rationale) != null)
          'rationale': _trimmedOrNull(rationale),
      },
    );
    return taskById(task.id) ?? task;
  }

  Future<TaskRecord> requestTaskChanges(
    String taskId, {
    String? rationale,
  }) async {
    final task = await updateTaskStatus(
      taskId,
      TaskStatus.needsChanges,
      summary: _trimmedOrNull(rationale) ?? 'Changes requested.',
    );
    await _appendReviewEventIfPossible(
      task,
      'Changes requested.',
      metadata: <String, Object?>{
        'review_action': 'request_changes',
        if (_trimmedOrNull(rationale) != null)
          'rationale': _trimmedOrNull(rationale),
      },
    );
    return taskById(task.id) ?? task;
  }

  Future<TaskRecord> retryTask(String taskId, {String? rationale}) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final previousRunId = _trimmedOrNull(task.currentRunId);
    final previousStatus = task.status;
    final retrySummary = _trimmedOrNull(rationale) ?? 'Queued for retry.';

    final queued = await updateTask(
      task.id,
      status: TaskStatus.queued,
      sessionId: null,
      currentRunId: null,
      summary: retrySummary,
      error: null,
    );

    if (previousRunId != null && _runExists(previousRunId)) {
      await appendEvent(
        taskId: task.id,
        runId: previousRunId,
        kind: TaskEventKind.system,
        text: 'Task retry queued.',
        sessionId: task.sessionId,
        metadata: <String, Object?>{
          'retry': true,
          'previous_status': previousStatus.name,
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
    }
    return taskById(task.id) ?? queued;
  }

  Future<List<TaskRecord>> recoverInterruptedRuns({
    String reason = 'Task run interrupted before completion.',
  }) async {
    await _ensureLoaded();
    final recovered = <TaskRecord>[];
    final tasks = List<TaskRecord>.of(_snapshot.tasks);
    for (final task in tasks) {
      if (!_isInterruptedTaskStatus(task.status)) continue;
      final runId = _trimmedOrNull(task.currentRunId);
      if (runId != null) {
        final run = _runById(runId);
        if (run != null && _isInterruptedTaskStatus(run.status)) {
          await updateRun(
            run.id,
            status: TaskStatus.failed,
            endedAt: _clock(),
            error: reason,
          );
        }
      }

      final updated = await updateTask(
        task.id,
        status: TaskStatus.failed,
        summary: reason,
        error: reason,
      );
      recovered.add(updated);

      if (runId != null && _runExists(runId)) {
        await appendEvent(
          taskId: task.id,
          runId: runId,
          kind: TaskEventKind.system,
          text: 'Task run recovered as failed: $reason',
          sessionId: task.sessionId,
          metadata: <String, Object?>{
            'recovered': true,
            'previous_status': task.status.name,
          },
        );
      }
    }
    return List.unmodifiable(recovered);
  }

  Future<TaskRecord> rejectTask(String taskId, {String? rationale}) async {
    final task = await updateTaskStatus(
      taskId,
      TaskStatus.rejected,
      summary: _trimmedOrNull(rationale) ?? 'Task rejected.',
    );
    await _appendReviewEventIfPossible(
      task,
      'Task rejected.',
      metadata: <String, Object?>{
        'review_action': 'reject',
        if (_trimmedOrNull(rationale) != null)
          'rationale': _trimmedOrNull(rationale),
      },
    );
    return taskById(task.id) ?? task;
  }

  Future<ApprovalRequestRecord> resolveApproval(
    String approvalId,
    ApprovalStatus status, {
    String? rationale,
  }) async {
    await _ensureLoaded();
    final target = approvalId.trim();
    final index = _snapshot.approvals.indexWhere(
      (approval) => approval.id == target,
    );
    if (index < 0) throw StateError('Approval request not found: $approvalId');
    if (status == ApprovalStatus.pending) {
      throw ArgumentError.value(status, 'status', 'Must be a resolved status');
    }

    final now = _clock();
    final existing = _snapshot.approvals[index];
    final resolved = existing.copyWith(
      status: status,
      resolvedAt: now,
      rationale: _trimmedOrNull(rationale) ?? existing.rationale,
    );
    final approvals = [..._snapshot.approvals];
    approvals[index] = resolved;
    _snapshot = _snapshot.copyWith(approvals: approvals, updatedAt: now);
    await store.save(_snapshot);
    notifyListeners();

    final task = taskById(existing.taskId);
    if (task != null) {
      await _appendReviewEventIfPossible(
        task,
        'Approval ${status.name}.',
        metadata: <String, Object?>{
          'review_action': 'resolve_approval',
          'approval_id': resolved.id,
          'approval_status': resolved.status.name,
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
    }
    return resolved;
  }

  Future<TaskRecord> updateTask(
    String taskId, {
    String? title,
    String? description,
    String? workspacePath,
    String? agentName,
    TaskStatus? status,
    TaskPriority? priority,
    Object? sessionId = _unchanged,
    Object? currentRunId = _unchanged,
    Object? summary = _unchanged,
    Object? error = _unchanged,
    Object? resourceId = _unchanged,
    List<String>? skillIds,
    Map<String, Object?>? metadata,
  }) async {
    await _ensureLoaded();
    final index = _indexOfTask(taskId);
    if (index < 0) throw StateError('Task not found: $taskId');

    final existing = _snapshot.tasks[index];
    final now = _clock();
    final updated = existing.copyWith(
      title: title == null ? null : _requiredText(title, 'title'),
      description: description?.trim(),
      workspacePath: workspacePath == null
          ? null
          : _requiredPath(workspacePath),
      agentName: agentName == null
          ? null
          : _requiredText(agentName, 'agentName'),
      status: status,
      priority: priority,
      updatedAt: now,
      sessionId: identical(sessionId, _unchanged)
          ? existing.sessionId
          : _trimmedOrNull(sessionId as String?),
      currentRunId: identical(currentRunId, _unchanged)
          ? existing.currentRunId
          : _trimmedOrNull(currentRunId as String?),
      summary: identical(summary, _unchanged)
          ? existing.summary
          : _trimmedOrNull(summary as String?),
      error: identical(error, _unchanged)
          ? existing.error
          : _trimmedOrNull(error as String?),
      resourceId: identical(resourceId, _unchanged)
          ? existing.resourceId
          : _trimmedOrNull(resourceId as String?),
      skillIds: skillIds == null ? null : _cleanStringList(skillIds),
      metadata: metadata == null ? null : Map.unmodifiable(metadata),
    );

    final tasks = [..._snapshot.tasks];
    tasks[index] = updated;
    await _replaceTasks(tasks, updatedAt: now);
    return updated;
  }

  Future<TaskRecord> updateTaskStatus(
    String taskId,
    TaskStatus status, {
    String? summary,
    String? error,
  }) {
    return updateTask(
      taskId,
      status: status,
      summary: summary ?? _unchanged,
      error: error ?? _unchanged,
    );
  }

  Future<void> deleteTask(String taskId) async {
    await _ensureLoaded();
    final target = taskId.trim();
    if (target.isEmpty) return;
    final tasks = _snapshot.tasks
        .where((task) => task.id != target)
        .toList(growable: false);
    if (tasks.length == _snapshot.tasks.length) return;
    final now = _clock();
    _snapshot = _snapshot.copyWith(tasks: tasks, updatedAt: now);
    await store.save(_snapshot);
    notifyListeners();
  }

  Future<void> saveSnapshot(TaskInboxSnapshot snapshot) async {
    await _ensureLoaded();
    _snapshot = snapshot.copyWith(updatedAt: snapshot.updatedAt);
    await store.save(_snapshot);
    notifyListeners();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    await load();
  }

  Future<void> _replaceTasks(
    List<TaskRecord> tasks, {
    required DateTime updatedAt,
  }) async {
    _snapshot = _snapshot.copyWith(
      tasks: _dedupeTasks(tasks),
      updatedAt: updatedAt,
    );
    await store.save(_snapshot);
    notifyListeners();
  }

  int _indexOfTask(String taskId) {
    final target = taskId.trim();
    if (target.isEmpty) return -1;
    return _snapshot.tasks.indexWhere((task) => task.id == target);
  }

  String _newId(String prefix) {
    for (var attempt = 0; attempt < 100; attempt += 1) {
      final generated =
          idGenerator?.call(prefix) ??
          '$prefix-${_clock().microsecondsSinceEpoch}-${_idCounter++}';
      final id = generated.trim();
      if (id.isEmpty) continue;
      if (!_recordIdExists(id)) return id;
    }
    throw StateError('Could not generate a unique task id.');
  }

  bool _recordIdExists(String id) {
    if (taskById(id) != null) return true;
    return _snapshot.runs.any((run) => run.id == id) ||
        _snapshot.events.any((event) => event.id == id) ||
        _snapshot.artifacts.any((artifact) => artifact.id == id) ||
        _snapshot.approvals.any((approval) => approval.id == id) ||
        _snapshot.resources.any((resource) => resource.id == id);
  }

  TaskRunRecord? _runById(String runId) {
    final target = runId.trim();
    if (target.isEmpty) return null;
    for (final run in _snapshot.runs) {
      if (run.id == target) return run;
    }
    return null;
  }

  bool _runExists(String runId) => _runById(runId) != null;

  bool _isInterruptedTaskStatus(TaskStatus status) {
    return switch (status) {
      TaskStatus.running ||
      TaskStatus.dispatched ||
      TaskStatus.blockedOnPermission ||
      TaskStatus.blockedOnUserInput ||
      TaskStatus.collectingArtifacts => true,
      _ => false,
    };
  }

  Set<String> _artifactIdSet(Iterable<String> artifactIds) {
    return artifactIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
  }

  List<ArtifactRecord> _artifactsForTaskRun(String taskId, String? runId) {
    final targetRunId = _trimmedOrNull(runId);
    return _snapshot.artifacts
        .where(
          (artifact) =>
              artifact.taskId == taskId &&
              (targetRunId == null || artifact.runId == targetRunId),
        )
        .toList(growable: false);
  }

  Future<void> _appendReviewEventIfPossible(
    TaskRecord task,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final runId = _trimmedOrNull(task.currentRunId);
    if (runId == null) return;
    final runExists = _snapshot.runs.any((run) => run.id == runId);
    if (!runExists) return;
    await appendEvent(
      taskId: task.id,
      runId: runId,
      kind: TaskEventKind.review,
      text: text,
      sessionId: task.sessionId,
      metadata: metadata,
    );
  }

  List<TaskRecord> _dedupeTasks(List<TaskRecord> tasks) {
    final byId = <String, TaskRecord>{};
    for (final task in tasks) {
      final id = task.id.trim();
      if (id.isEmpty) continue;
      if (byId.containsKey(id)) {
        throw StateError('Duplicate task id: $id');
      }
      byId[id] = task;
    }
    return List.unmodifiable(byId.values);
  }

  String _requiredText(String value, String fieldName) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(value, fieldName, 'Required');
    }
    return trimmed;
  }

  String _requiredPath(String value) {
    final normalized = normalizeWorkspacePath(value);
    if (normalized.isEmpty) {
      throw ArgumentError.value(value, 'workspacePath', 'Required');
    }
    return normalized;
  }

  String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  List<String> _cleanStringList(Iterable<String> values) {
    return List.unmodifiable(
      values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet(),
    );
  }
}
