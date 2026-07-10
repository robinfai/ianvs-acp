import 'dart:convert';

import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_repository.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

typedef MemoryRepositoryHook = Future<void> Function(String operation);

class MemoryTaskRepository implements TaskRepository {
  MemoryTaskRepository([TaskInboxSnapshot? snapshot, this.beforeOperation])
    : _snapshot =
          snapshot ??
          TaskInboxSnapshot.empty(
            updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
          );

  TaskInboxSnapshot _snapshot;
  int _revision = 0;
  bool _closed = false;
  int initializeCount = 0;
  int loadCount = 0;
  final List<TaskInboxSnapshot> savedSnapshots = <TaskInboxSnapshot>[];
  MemoryRepositoryHook? beforeOperation;

  TaskInboxSnapshot get currentSnapshot => _snapshot;

  @override
  Future<void> initialize() async {
    _ensureOpen();
    initializeCount += 1;
    await beforeOperation?.call('initialize');
  }

  @override
  Future<TaskRepositorySnapshot> loadRepository() async {
    _ensureOpen();
    loadCount += 1;
    await beforeOperation?.call('load');
    return TaskRepositorySnapshot(revision: _revision, snapshot: _snapshot);
  }

  @override
  Future<TaskRecord> insertTask(TaskRecord task) async {
    await _beforeWrite('insertTask');
    if (_snapshot.tasks.any((candidate) => candidate.id == task.id)) {
      throw TaskRepositoryConflict('Task already exists: ${task.id}');
    }
    _commit(
      _snapshot.copyWith(tasks: <TaskRecord>[..._snapshot.tasks, task]),
      updatedAt: task.updatedAt,
    );
    return task;
  }

  @override
  Future<TaskRecord> updateTask(
    TaskRecord task, {
    required TaskRecord expected,
  }) async {
    if (task.id != expected.id || task.createdAt != expected.createdAt) {
      throw ArgumentError('Updated task must keep its identity.');
    }
    await _beforeWrite('updateTask');
    final index = _snapshot.tasks.indexWhere(
      (candidate) => candidate.id == task.id,
    );
    if (index < 0 || !_sameRecord(_snapshot.tasks[index], expected)) {
      throw TaskRepositoryConflict('Task changed concurrently: ${task.id}');
    }
    final tasks = [..._snapshot.tasks];
    tasks[index] = task;
    _commit(_snapshot.copyWith(tasks: tasks), updatedAt: task.updatedAt);
    return task;
  }

  @override
  Future<void> deleteTask(
    TaskDeleteExpectation expected, {
    required DateTime updatedAt,
  }) async {
    await _beforeWrite('deleteTask');
    final index = _snapshot.tasks.indexWhere(
      (task) => task.id == expected.task.id,
    );
    final current = index < 0
        ? null
        : TaskDeleteExpectation.fromSnapshot(_snapshot, expected.task.id);
    if (current == null ||
        !_sameRecord(current.task, expected.task) ||
        !_sameRecordSet(current.runs, expected.runs) ||
        !_sameRecordSet(current.events, expected.events) ||
        !_sameRecordSet(current.artifacts, expected.artifacts) ||
        !_sameRecordSet(current.approvals, expected.approvals)) {
      throw TaskRepositoryConflict(
        'Task aggregate changed concurrently: ${expected.task.id}',
      );
    }
    final target = expected.task.id;
    _commit(
      _snapshot.copyWith(
        tasks: _snapshot.tasks
            .where((task) => task.id != target)
            .toList(growable: false),
        runs: _snapshot.runs
            .where((run) => run.taskId != target)
            .toList(growable: false),
        events: _snapshot.events
            .where((event) => event.taskId != target)
            .toList(growable: false),
        artifacts: _snapshot.artifacts
            .where((artifact) => artifact.taskId != target)
            .toList(growable: false),
        approvals: _snapshot.approvals
            .where((approval) => approval.taskId != target)
            .toList(growable: false),
      ),
      updatedAt: updatedAt,
    );
  }

  @override
  Future<TaskRunCreation> createRun({
    required TaskRecord expectedTask,
    required TaskRecord task,
    required TaskRunRecord run,
  }) async {
    if (task.id != expectedTask.id ||
        task.createdAt != expectedTask.createdAt) {
      throw ArgumentError('Updated task must keep its identity.');
    }
    await _beforeWrite('createRun');
    final taskIndex = _snapshot.tasks.indexWhere(
      (candidate) => candidate.id == task.id,
    );
    if (taskIndex < 0 ||
        !_sameRecord(_snapshot.tasks[taskIndex], expectedTask)) {
      throw TaskRepositoryConflict('Task changed concurrently: ${task.id}');
    }
    if (task.id != run.taskId || task.currentRunId != run.id) {
      throw ArgumentError('Task run must belong to the updated task.');
    }
    if (_snapshot.runs.any((candidate) => candidate.id == run.id)) {
      throw TaskRepositoryConflict('Task run already exists: ${run.id}');
    }
    final tasks = [..._snapshot.tasks];
    tasks[taskIndex] = task;
    _commit(
      _snapshot.copyWith(
        tasks: tasks,
        runs: <TaskRunRecord>[..._snapshot.runs, run],
      ),
      updatedAt: task.updatedAt,
    );
    return TaskRunCreation(task: task, run: run);
  }

  @override
  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask,
    TaskRunRecord run, {
    required TaskEventRecord dispatchEvent,
    WorkspaceResource? expectedResource,
  }) async {
    if (run.status != TaskStatus.dispatched || run.endedAt != null) {
      throw ArgumentError('Claimed task runs must start dispatched.');
    }
    await _beforeWrite('claimTask');
    final index = _snapshot.tasks.indexWhere(
      (task) => task.id == expectedTask.id && task.status == TaskStatus.queued,
    );
    if (index < 0) return null;
    final existing = _snapshot.tasks[index];
    if (!_sameRecord(existing, expectedTask)) return null;
    if (run.taskId != existing.id ||
        dispatchEvent.taskId != existing.id ||
        dispatchEvent.runId != run.id) {
      throw ArgumentError('Claim records must belong to the queued task.');
    }
    final resourceId = existing.resourceId;
    if (resourceId == null) {
      if (expectedResource != null) return null;
    } else {
      final resourceIndex = _snapshot.resources.indexWhere(
        (resource) => resource.id == resourceId,
      );
      if (resourceIndex < 0 ||
          expectedResource == null ||
          !_sameRecord(_snapshot.resources[resourceIndex], expectedResource)) {
        return null;
      }
    }
    if (_snapshot.runs.any((candidate) => candidate.id == run.id)) {
      throw TaskRepositoryConflict('Task run already exists: ${run.id}');
    }
    if (_snapshot.events.any((event) => event.id == dispatchEvent.id)) {
      throw TaskRepositoryConflict(
        'Task event already exists: ${dispatchEvent.id}',
      );
    }
    final claimAt = _latestTimestamp(
      existing.updatedAt,
      run.startedAt,
      dispatchEvent.createdAt,
    );
    final actualRun = run.copyWith(
      attempt:
          _snapshot.runs
              .where((candidate) => candidate.taskId == existing.id)
              .fold<int>(0, (maximum, candidate) {
                return candidate.attempt > maximum
                    ? candidate.attempt
                    : maximum;
              }) +
          1,
      startedAt: claimAt,
    );
    final actualEvent = dispatchEvent.copyWith(createdAt: claimAt);
    final claimed = existing.copyWith(
      status: TaskStatus.dispatched,
      currentRunId: actualRun.id,
      updatedAt: claimAt,
    );
    final tasks = [..._snapshot.tasks];
    tasks[index] = claimed;
    _commit(
      _snapshot.copyWith(
        tasks: tasks,
        runs: <TaskRunRecord>[..._snapshot.runs, actualRun],
        events: <TaskEventRecord>[..._snapshot.events, actualEvent],
      ),
      updatedAt: claimAt,
    );
    return TaskClaim(task: claimed, run: actualRun, dispatchEvent: actualEvent);
  }

  @override
  Future<TaskRunRecord> updateRun(
    TaskRunRecord run, {
    required TaskRunRecord expected,
    required DateTime updatedAt,
  }) async {
    if (run.id != expected.id ||
        run.taskId != expected.taskId ||
        run.attempt != expected.attempt ||
        run.startedAt != expected.startedAt) {
      throw ArgumentError('Updated task run must keep its identity.');
    }
    await _beforeWrite('updateRun');
    final index = _snapshot.runs.indexWhere(
      (candidate) => candidate.id == run.id,
    );
    if (index < 0 || !_sameRecord(_snapshot.runs[index], expected)) {
      throw TaskRepositoryConflict('Task run changed concurrently: ${run.id}');
    }
    final runs = [..._snapshot.runs];
    runs[index] = run;
    _commit(_snapshot.copyWith(runs: runs), updatedAt: updatedAt);
    return run;
  }

  @override
  Future<void> appendEvents(
    List<TaskEventRecord> events, {
    required DateTime updatedAt,
  }) async {
    if (events.isEmpty) return;
    await _beforeWrite('appendEvents');
    final ids = _snapshot.events.map((event) => event.id).toSet();
    for (final event in events) {
      if (!ids.add(event.id)) {
        throw TaskRepositoryConflict('Task event already exists: ${event.id}');
      }
    }
    _commit(
      _snapshot.copyWith(
        events: <TaskEventRecord>[..._snapshot.events, ...events],
      ),
      updatedAt: updatedAt,
    );
  }

  @override
  Future<void> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  }) async {
    await _beforeWrite('replaceArtifactsForRun');
    final current = _snapshot.artifacts
        .where(
          (artifact) => artifact.taskId == taskId && artifact.runId == runId,
        )
        .toList(growable: false);
    if (!_sameRecordSet(current, expectedArtifacts)) {
      throw TaskRepositoryConflict(
        'Artifacts changed concurrently for task run: $runId',
      );
    }
    if (artifacts.any(
      (artifact) => artifact.taskId != taskId || artifact.runId != runId,
    )) {
      throw ArgumentError('Artifacts must belong to one task run.');
    }
    final replacementIds = artifacts.map((artifact) => artifact.id).toSet();
    final removedIds = expectedArtifacts
        .map((artifact) => artifact.id)
        .where((id) => !replacementIds.contains(id))
        .toSet();
    for (final approval in _snapshot.approvals) {
      if (approval.taskId != taskId) continue;
      if (approval.artifactIds.any(removedIds.contains)) {
        throw TaskRepositoryConflict(
          'Artifacts are still referenced by approval ${approval.id}.',
        );
      }
    }
    final retained =
        _snapshot.artifacts
            .where(
              (artifact) =>
                  artifact.taskId != taskId || artifact.runId != runId,
            )
            .toList(growable: true)
          ..addAll(artifacts);
    if (retained.map((artifact) => artifact.id).toSet().length !=
        retained.length) {
      throw TaskRepositoryConflict('Artifact id already exists.');
    }
    _commit(_snapshot.copyWith(artifacts: retained), updatedAt: updatedAt);
  }

  @override
  Future<void> updateArtifacts({
    required List<ArtifactRecord> expectedArtifacts,
    required List<ArtifactRecord> artifacts,
    required DateTime updatedAt,
  }) async {
    if (expectedArtifacts.isEmpty && artifacts.isEmpty) return;
    await _beforeWrite('updateArtifacts');
    if (expectedArtifacts.length != artifacts.length) {
      throw ArgumentError('Artifact update must keep the same records.');
    }
    final expectedById = <String, ArtifactRecord>{
      for (final artifact in expectedArtifacts) artifact.id: artifact,
    };
    final updatedById = <String, ArtifactRecord>{
      for (final artifact in artifacts) artifact.id: artifact,
    };
    if (expectedById.length != expectedArtifacts.length ||
        updatedById.length != artifacts.length ||
        !_sameRecordSet(
          _snapshot.artifacts
              .where((artifact) => expectedById.containsKey(artifact.id))
              .toList(growable: false),
          expectedArtifacts,
        )) {
      throw TaskRepositoryConflict('Artifacts changed concurrently.');
    }
    final updated = _snapshot.artifacts
        .map((artifact) {
          final replacement = updatedById[artifact.id];
          if (replacement == null) return artifact;
          final expected = expectedById[artifact.id]!;
          if (replacement.taskId != expected.taskId ||
              replacement.runId != expected.runId) {
            throw ArgumentError('Updated artifact must keep its owner.');
          }
          return replacement;
        })
        .toList(growable: false);
    _commit(_snapshot.copyWith(artifacts: updated), updatedAt: updatedAt);
  }

  @override
  Future<void> upsertApproval(
    ApprovalRequestRecord approval, {
    ApprovalRequestRecord? expected,
    required DateTime updatedAt,
  }) async {
    await _beforeWrite('upsertApproval');
    final approvals = [..._snapshot.approvals];
    final index = approvals.indexWhere(
      (candidate) => candidate.id == approval.id,
    );
    if (expected == null && index >= 0) {
      throw TaskRepositoryConflict(
        'Approval request already exists: ${approval.id}',
      );
    }
    if (expected != null &&
        (approval.id != expected.id ||
            approval.taskId != expected.taskId ||
            approval.runId != expected.runId ||
            approval.kind != expected.kind ||
            approval.createdAt != expected.createdAt)) {
      throw ArgumentError('Updated approval request must keep its identity.');
    }
    if (expected != null &&
        (index < 0 || !_sameRecord(approvals[index], expected))) {
      throw TaskRepositoryConflict(
        'Approval request changed concurrently: ${approval.id}',
      );
    }
    if (index < 0) {
      approvals.add(approval);
    } else {
      approvals[index] = approval;
    }
    _commit(_snapshot.copyWith(approvals: approvals), updatedAt: updatedAt);
  }

  @override
  Future<void> upsertResource(
    WorkspaceResource resource, {
    WorkspaceResource? expected,
    required DateTime updatedAt,
  }) async {
    if (expected != null && resource.id != expected.id) {
      throw ArgumentError('Updated resource must keep its id.');
    }
    await _beforeWrite('upsertResource');
    final resources = [..._snapshot.resources];
    final index = resources.indexWhere(
      (candidate) => candidate.id == resource.id,
    );
    if (expected == null && index >= 0) {
      throw TaskRepositoryConflict(
        'Workspace resource already exists: ${resource.id}',
      );
    }
    if (expected != null &&
        (index < 0 || !_sameRecord(resources[index], expected))) {
      throw TaskRepositoryConflict(
        'Workspace resource changed concurrently: ${resource.id}',
      );
    }
    if (index < 0) {
      resources.add(resource);
    } else {
      resources[index] = resource;
    }
    _commit(_snapshot.copyWith(resources: resources), updatedAt: updatedAt);
  }

  @override
  Future<int> revision() async {
    _ensureOpen();
    await beforeOperation?.call('revision');
    return _revision;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await beforeOperation?.call('close');
    _closed = true;
  }

  Future<void> _beforeWrite(String operation) async {
    _ensureOpen();
    await beforeOperation?.call(operation);
  }

  void _commit(TaskInboxSnapshot snapshot, {required DateTime updatedAt}) {
    snapshot.validateReferences();
    final records = <Object>[
      ...snapshot.tasks,
      ...snapshot.runs,
      ...snapshot.events,
      ...snapshot.artifacts,
      ...snapshot.approvals,
      ...snapshot.resources,
    ];
    if (records.any(
      (record) => !taskRepositoryRecordHasCanonicalFields(record),
    )) {
      throw ArgumentError('Task snapshot must use canonical record values.');
    }
    final json = snapshot.toJson();
    final restored = TaskInboxSnapshot.fromJsonStrict(json);
    if (jsonEncode(restored.toJson()) != jsonEncode(json)) {
      throw ArgumentError('Task snapshot must use canonical record values.');
    }
    _revision += 1;
    final effectiveUpdatedAt = _snapshot.updatedAt.isAfter(updatedAt)
        ? _snapshot.updatedAt
        : updatedAt;
    _snapshot = snapshot.copyWith(updatedAt: effectiveUpdatedAt);
    savedSnapshots.add(_snapshot);
  }

  void _ensureOpen() {
    if (_closed) throw StateError('Task repository is closed.');
  }

  static bool _sameRecord(Object left, Object right) {
    return jsonEncode(_recordJson(left)) == jsonEncode(_recordJson(right));
  }

  static bool _sameRecordSet(List<Object> left, List<Object> right) {
    if (left.length != right.length) return false;
    String encode(Object record) => jsonEncode(_recordJson(record));
    final leftRecords = left.map(encode).toList()..sort();
    final rightRecords = right.map(encode).toList()..sort();
    for (var index = 0; index < leftRecords.length; index += 1) {
      if (leftRecords[index] != rightRecords[index]) return false;
    }
    return true;
  }

  static Map<String, Object?> _recordJson(Object record) {
    return switch (record) {
      TaskRecord value => value.toJson(),
      TaskRunRecord value => value.toJson(),
      TaskEventRecord value => value.toJson(),
      ArtifactRecord value => value.toJson(),
      ApprovalRequestRecord value => value.toJson(),
      WorkspaceResource value => value.toJson(),
      _ => throw ArgumentError('Unsupported task record: $record'),
    };
  }

  static DateTime _latestTimestamp(
    DateTime first,
    DateTime second,
    DateTime third,
  ) {
    var latest = first;
    if (second.isAfter(latest)) latest = second;
    if (third.isAfter(latest)) latest = third;
    return latest;
  }
}
