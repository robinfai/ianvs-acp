import 'package:flutter/foundation.dart';

import '../workspace/workspace.dart';
import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'task_store.dart';

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

  Future<ApprovalRequestRecord> createExportApprovalRequest({
    required String taskId,
    ExportTarget target = ExportTarget.simulated,
    String? destination,
    String? riskSummary,
    String? rationale,
    List<String>? artifactIds,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final now = _clock();
    final approval = ApprovalRequestRecord(
      id: _newId('approval'),
      taskId: task.id,
      runId: _trimmedOrNull(task.currentRunId),
      kind: ApprovalKind.export,
      status: ApprovalStatus.pending,
      createdAt: now,
      target: target,
      destination: _trimmedOrNull(destination),
      riskSummary: _trimmedOrNull(riskSummary),
      rationale: _trimmedOrNull(rationale),
      artifactIds: List.unmodifiable(
        artifactIds ?? _artifactIdsForTaskRun(task.id, task.currentRunId),
      ),
      metadata: Map.unmodifiable(metadata),
    );
    _snapshot = _snapshot.copyWith(
      approvals: [..._snapshot.approvals, approval],
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    await _appendReviewEventIfPossible(
      task,
      'Export approval requested.',
      metadata: <String, Object?>{
        'review_action': 'request_export_approval',
        'approval_id': approval.id,
        'approval_status': approval.status.name,
        'target': target.name,
      },
    );
    return approval;
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
    var tasks = _snapshot.tasks;
    final taskIndex = _indexOfTask(existing.taskId);
    if (taskIndex >= 0 &&
        existing.kind == ApprovalKind.export &&
        status == ApprovalStatus.approved) {
      tasks = [..._snapshot.tasks];
      tasks[taskIndex] = tasks[taskIndex].copyWith(
        status: TaskStatus.approvedForExport,
        updatedAt: now,
      );
    }
    _snapshot = _snapshot.copyWith(
      tasks: tasks,
      approvals: approvals,
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();

    final task = taskById(existing.taskId);
    if (task != null) {
      await _appendReviewEventIfPossible(
        task,
        'Export approval ${status.name}.',
        metadata: <String, Object?>{
          'review_action': 'resolve_export_approval',
          'approval_id': resolved.id,
          'approval_status': resolved.status.name,
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
    }
    return resolved;
  }

  Future<ApprovalRequestRecord> approveTaskExport(
    String taskId, {
    ExportTarget target = ExportTarget.simulated,
    String? destination,
    String? riskSummary,
    String? rationale,
  }) async {
    await _ensureLoaded();
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final pending = _pendingExportApprovalFor(task.id);
    if (pending != null) {
      return resolveApproval(
        pending.id,
        ApprovalStatus.approved,
        rationale: rationale,
      );
    }

    final now = _clock();
    final approval = ApprovalRequestRecord(
      id: _newId('approval'),
      taskId: task.id,
      runId: _trimmedOrNull(task.currentRunId),
      kind: ApprovalKind.export,
      status: ApprovalStatus.approved,
      createdAt: now,
      resolvedAt: now,
      target: target,
      destination: _trimmedOrNull(destination),
      riskSummary: _trimmedOrNull(riskSummary),
      rationale: _trimmedOrNull(rationale),
      artifactIds: List.unmodifiable(
        _artifactIdsForTaskRun(task.id, task.currentRunId),
      ),
      metadata: const <String, Object?>{},
    );
    final taskIndex = _indexOfTask(task.id);
    final tasks = [..._snapshot.tasks];
    tasks[taskIndex] = tasks[taskIndex].copyWith(
      status: TaskStatus.approvedForExport,
      updatedAt: now,
    );
    _snapshot = _snapshot.copyWith(
      tasks: _dedupeTasks(tasks),
      approvals: [..._snapshot.approvals, approval],
      updatedAt: now,
    );
    await store.save(_snapshot);
    notifyListeners();
    await _appendReviewEventIfPossible(
      taskById(task.id) ?? task,
      'Export approved.',
      metadata: <String, Object?>{
        'review_action': 'approve_export',
        'approval_id': approval.id,
        'approval_status': approval.status.name,
        'target': target.name,
      },
    );
    return approval;
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
        _snapshot.approvals.any((approval) => approval.id == id);
  }

  ApprovalRequestRecord? _pendingExportApprovalFor(String taskId) {
    for (final approval in _snapshot.approvals.reversed) {
      if (approval.taskId == taskId &&
          approval.kind == ApprovalKind.export &&
          approval.status == ApprovalStatus.pending) {
        return approval;
      }
    }
    return null;
  }

  List<String> _artifactIdsForTaskRun(String taskId, String? runId) {
    final targetRunId = _trimmedOrNull(runId);
    return _snapshot.artifacts
        .where(
          (artifact) =>
              artifact.taskId == taskId &&
              (targetRunId == null || artifact.runId == targetRunId),
        )
        .map((artifact) => artifact.id)
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
}
