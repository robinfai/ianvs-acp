import 'dart:async';

import 'package:flutter/foundation.dart';

import '../workspace/workspace.dart';
import 'runtime_registry.dart';
import 'task_data_sanitizer.dart';
import 'task_inbox_snapshot.dart';
import 'task_record.dart';
import 'task_repository.dart';
import 'task_timeline.dart';
import 'workspace_resource.dart';

typedef TaskInboxClock = DateTime Function();
typedef TaskInboxIdGenerator = String Function(String prefix);

const Object _unchanged = Object();

class TaskPersistenceStalledException implements Exception {
  const TaskPersistenceStalledException({
    required this.operation,
    required this.watchdog,
    required this.generation,
  });

  final String operation;
  final Duration watchdog;
  final int generation;

  @override
  String toString() {
    return 'Task persistence stalled during $operation after $watchdog '
        '(generation $generation). The controller is quarantined; reload '
        'the repository with a new controller after the pending operation '
        'has quiesced.';
  }
}

class TaskInboxController extends ChangeNotifier {
  static const Duration defaultPersistenceWatchdog = Duration(seconds: 15);

  TaskInboxController({
    required this.repository,
    TaskInboxClock? clock,
    this.idGenerator,
    this.persistenceWatchdog = defaultPersistenceWatchdog,
    TaskDataSanitizer? dataSanitizer,
  }) : _clock = clock ?? DateTime.now,
       dataSanitizer = dataSanitizer ?? const TaskDataSanitizer(),
       assert(persistenceWatchdog > Duration.zero);

  final TaskRepository repository;
  final TaskInboxClock _clock;
  final TaskInboxIdGenerator? idGenerator;
  final TaskDataSanitizer dataSanitizer;

  /// Bounds asynchronous repository calls after SQLite's five-second busy
  /// timeout. A Dart timer cannot interrupt a synchronous native call that is
  /// blocking the same isolate; it only quarantines calls whose Future can be
  /// observed by the event loop.
  final Duration persistenceWatchdog;
  TaskInboxSnapshot _snapshot = TaskInboxSnapshot.empty();
  bool _loaded = false;
  Future<void>? _loadFuture;
  Future<void> _stateTransition = Future<void>.value();
  int _revision = -1;
  int _idCounter = 0;
  int _persistenceGeneration = 0;
  TaskPersistenceStalledException? _persistenceFault;
  final Set<Future<void>> _repositoryOperations = <Future<void>>{};
  Completer<void>? _persistenceQuiesced;

  TaskInboxSnapshot get snapshot => _snapshot;

  List<TaskRecord> get tasks => _snapshot.tasks;

  List<TaskRunRecord> get runs => _snapshot.runs;

  List<TaskEventRecord> get events => _snapshot.events;

  List<ArtifactRecord> get artifacts => _snapshot.artifacts;

  List<ApprovalRequestRecord> get approvals => _snapshot.approvals;

  bool get isPersistenceFaulted => _persistenceFault != null;

  TaskPersistenceStalledException? get persistenceFault => _persistenceFault;

  bool get isPersistenceQuiesced => _repositoryOperations.isEmpty;

  bool get hasAtomicSchedulingAuthority =>
      repository is AtomicTaskSchedulingRepository;

  Future<void> get whenPersistenceQuiesced {
    if (_repositoryOperations.isEmpty) return Future<void>.value();
    return (_persistenceQuiesced ??= Completer<void>()).future;
  }

  List<TaskTimelineEntry> timelineForTask(String taskId) {
    return buildTaskTimeline(_snapshot, taskId);
  }

  Future<void> load() {
    final fault = _persistenceFault;
    if (fault != null) return Future<void>.error(fault);
    return _loadFuture ??= _loadOnce();
  }

  Future<void> _loadOnce() async {
    try {
      final loaded = await _awaitRepository(
        'loadRepository',
        repository.loadRepository,
      );
      _snapshot = loaded.snapshot;
      _revision = loaded.revision;
      _loaded = true;
      notifyListeners();
    } on Object {
      _loadFuture = null;
      rethrow;
    }
  }

  Future<bool> refreshIfChanged() async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final currentRevision = await _awaitRepository(
        'revision',
        repository.revision,
      );
      if (currentRevision == _revision) return false;
      final loaded = await _awaitRepository(
        'loadRepository',
        repository.loadRepository,
      );
      if (loaded.revision == _revision) return false;
      _snapshot = loaded.snapshot;
      _revision = loaded.revision;
      notifyListeners();
      return true;
    });
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
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final now = _clock();
      final task = TaskRecord(
        id: _newId('task'),
        title: dataSanitizer.sanitizeText(_requiredText(title, 'title')),
        description: dataSanitizer.sanitizeText(description.trim()),
        workspacePath: _requiredPath(workspacePath),
        agentName: _requiredText(agentName, 'agentName'),
        status: TaskStatus.inbox,
        priority: priority,
        createdAt: now,
        updatedAt: now,
        resourceId: _trimmedOrNull(resourceId),
        skillIds: _cleanStringList(skillIds),
        metadata: dataSanitizer.sanitize(metadata),
      );

      final inserted = await _awaitRepository(
        'insertTask',
        () => repository.insertTask(task),
      );
      _snapshot = _snapshot.copyWith(
        tasks: _dedupeTasks([..._snapshot.tasks, inserted]),
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();
      return inserted;
    });
  }

  Future<TaskRunRecord> createRun({
    required String taskId,
    TaskStatus status = TaskStatus.running,
    String? sessionId,
    String? promptSnapshot,
    String? model,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final taskIndex = _indexOfTask(taskId);
      if (taskIndex < 0) throw StateError('Task not found: $taskId');

      final now = _clock();
      final run = TaskRunRecord(
        id: _newId('run'),
        taskId: _snapshot.tasks[taskIndex].id,
        attempt:
            _snapshot.runs.where((run) => run.taskId == taskId.trim()).length +
            1,
        status: status,
        startedAt: now,
        sessionId: _trimmedOrNull(sessionId),
        promptSnapshot: _sanitizedTrimmedOrNull(promptSnapshot),
        model: _trimmedOrNull(model),
      );
      final existingTask = _snapshot.tasks[taskIndex];
      final updatedTask = existingTask.copyWith(
        status: status,
        currentRunId: run.id,
        updatedAt: now,
        sessionId: run.sessionId,
        metadata: dataSanitizer.sanitize(existingTask.metadata),
      );
      final created = await _awaitRepository(
        'createRun',
        () => repository.createRun(
          expectedTask: existingTask,
          task: updatedTask,
          run: run,
        ),
      );
      final tasks = [..._snapshot.tasks];
      final currentIndex = tasks.indexWhere(
        (candidate) => candidate.id == created.task.id,
      );
      if (currentIndex < 0) {
        throw StateError('Task disappeared after run creation: $taskId');
      }
      tasks[currentIndex] = created.task;
      _snapshot = _snapshot.copyWith(
        tasks: _dedupeTasks(tasks),
        runs: [..._snapshot.runs, created.run],
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();
      return created.run;
    });
  }

  Future<TaskClaim?> claimTask(
    TaskRecord expectedTask, {
    WorkspaceResource? expectedResource,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final taskId = expectedTask.id;
      final taskIndex = _indexOfTask(taskId);
      if (taskIndex < 0) throw StateError('Task not found: $taskId');
      if (_snapshot.tasks[taskIndex].status != TaskStatus.queued) return null;
      final task = expectedTask;
      if (task.status != TaskStatus.queued) return null;
      final now = _clock();
      final run = TaskRunRecord(
        id: _newId('run'),
        taskId: task.id,
        attempt:
            _snapshot.runs
                .where((run) => run.taskId == task.id)
                .fold<int>(
                  0,
                  (maximum, run) =>
                      run.attempt > maximum ? run.attempt : maximum,
                ) +
            1,
        status: TaskStatus.dispatched,
        startedAt: now,
      );
      final dispatchEvent = TaskEventRecord(
        id: _newId('event'),
        taskId: task.id,
        runId: run.id,
        kind: TaskEventKind.system,
        text: 'Task dispatched.',
        createdAt: now,
        metadata: const <String, Object?>{'task_status': 'dispatched'},
      );
      final claimedMetadata = dataSanitizer.sanitize(task.metadata);
      final claim = await _awaitRepository('claimTask', () {
        final target = repository;
        if (target is AtomicTaskClaimMetadataRepository) {
          return (target as AtomicTaskClaimMetadataRepository)
              .claimTaskWithMetadata(
                task,
                run,
                dispatchEvent: dispatchEvent,
                expectedResource: expectedResource,
                claimedMetadata: claimedMetadata,
              );
        }
        if (!_jsonValuesEqual(task.metadata, claimedMetadata)) {
          return Future<TaskClaim?>.error(
            UnsupportedError(
              'This task repository cannot atomically sanitize metadata '
              'while claiming a task.',
            ),
          );
        }
        return target.claimTask(
          task,
          run,
          dispatchEvent: dispatchEvent,
          expectedResource: expectedResource,
        );
      });
      if (claim == null) {
        await _reloadRepositoryWithinTransition();
        return null;
      }
      final tasks = [..._snapshot.tasks];
      final currentIndex = tasks.indexWhere(
        (candidate) => candidate.id == claim.task.id,
      );
      if (currentIndex < 0) {
        throw StateError('Task disappeared after claim: $taskId');
      }
      tasks[currentIndex] = claim.task;
      _snapshot = _snapshot.copyWith(
        tasks: _dedupeTasks(tasks),
        runs: [..._snapshot.runs, claim.run],
        events: [..._snapshot.events, claim.dispatchEvent],
        updatedAt: _latestTimestamp(
          _snapshot.updatedAt,
          claim.task.updatedAt,
          claim.run.startedAt,
          claim.dispatchEvent.createdAt,
        ),
      );
      _markRepositoryChanged();
      notifyListeners();
      return claim;
    });
  }

  Future<void> configureSchedulingAuthority({
    required int maxConcurrentTasks,
  }) async {
    if (!_loaded) await load();
    final target = repository;
    if (target is! AtomicTaskSchedulingRepository) {
      throw UnsupportedError(
        'This task repository does not provide an atomic scheduler.',
      );
    }
    final scheduling = target as AtomicTaskSchedulingRepository;
    await _withStateTransition(
      () => _awaitRepository(
        'configureScheduler',
        () => scheduling.configureScheduler(
          maxConcurrentTasks: maxConcurrentTasks,
        ),
      ),
    );
  }

  Future<void> publishSchedulingRuntimeStatus(LocalRuntimeStatus status) async {
    if (!_loaded) await load();
    final target = repository;
    if (target is! AtomicTaskSchedulingRepository) {
      throw UnsupportedError(
        'This task repository does not provide an atomic scheduler.',
      );
    }
    final scheduling = target as AtomicTaskSchedulingRepository;
    await _withStateTransition(
      () => _awaitRepository(
        'publishRuntimeStatus',
        () => scheduling.publishRuntimeStatus(status),
      ),
    );
  }

  Future<TaskSchedulingPoll> claimNextScheduledTask({
    Set<String> excludedTaskIds = const <String>{},
  }) async {
    if (!_loaded) await load();
    final target = repository;
    if (target is! AtomicTaskSchedulingRepository) {
      throw UnsupportedError(
        'This task repository does not provide an atomic scheduler.',
      );
    }
    final scheduling = target as AtomicTaskSchedulingRepository;
    return _withStateTransition(() async {
      final poll = await _awaitRepository(
        'claimNextTask',
        () => scheduling.claimNextTask(
          runId: _newId('run'),
          dispatchEventId: _newId('event'),
          now: _clock(),
          excludedTaskIds: excludedTaskIds,
        ),
      );
      _snapshot = poll.repository.snapshot;
      _revision = poll.repository.revision;
      notifyListeners();
      return poll;
    });
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
    if (!_loaded) await load();
    return _withStateTransition(
      () => _updateRunWithinTransition(
        runId,
        status: status,
        endedAt: endedAt,
        sessionId: sessionId,
        promptSnapshot: promptSnapshot,
        model: model,
        error: error,
      ),
    );
  }

  Future<TaskEventRecord> appendEvent({
    required String taskId,
    required String runId,
    required TaskEventKind kind,
    required String text,
    String? sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(
      () => _appendEventWithinTransition(
        taskId: taskId,
        runId: runId,
        kind: kind,
        text: text,
        sessionId: sessionId,
        metadata: metadata,
      ),
    );
  }

  Future<List<ArtifactRecord>> replaceArtifactsForRun({
    required String taskId,
    required String runId,
    required List<ArtifactRecord> artifacts,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
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

      final sanitizedArtifacts = _sanitizeArtifacts(artifacts);
      final artifactIds = <String>{};
      for (final artifact in sanitizedArtifacts) {
        final artifactId = artifact.id.trim();
        if (artifactId.isEmpty) {
          throw StateError('Artifact id is required.');
        }
        if (!artifactIds.add(artifactId)) {
          throw StateError('Duplicate artifact id: $artifactId');
        }
        if (_recordIdExistsOutsideArtifactRun(
          artifactId,
          taskId: task.id,
          runId: run.id,
        )) {
          throw StateError('Duplicate persisted id: $artifactId');
        }
        if (artifact.taskId != task.id || artifact.runId != run.id) {
          throw StateError('Artifact does not belong to task run: $artifactId');
        }
      }

      final now = _clock();
      final expectedArtifacts = _artifactsForTaskRun(task.id, run.id);
      await _awaitRepository(
        'replaceArtifactsForRun',
        () => repository.replaceArtifactsForRun(
          taskId: task.id,
          runId: targetRunId,
          expectedArtifacts: expectedArtifacts,
          artifacts: sanitizedArtifacts,
          updatedAt: now,
        ),
      );
      final retained = _snapshot.artifacts
          .where(
            (artifact) =>
                artifact.taskId != task.id || artifact.runId != targetRunId,
          )
          .toList(growable: true);
      retained.addAll(sanitizedArtifacts);
      _snapshot = _snapshot.copyWith(
        artifacts: List.unmodifiable(retained),
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();
      return sanitizedArtifacts;
    });
  }

  Future<List<ArtifactRecord>> reviewArtifactsForRun({
    required String taskId,
    required String runId,
    List<String> approvedArtifactIds = const <String>[],
    List<String> rejectedArtifactIds = const <String>[],
    String? rationale,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
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
      final previousArtifacts = _artifactsForTaskRun(task.id, run.id);
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
      final updatedRunArtifacts = _sanitizeArtifacts(
        artifacts.where(
          (artifact) => artifact.taskId == task.id && artifact.runId == run.id,
        ),
      );
      await _awaitRepository(
        'replaceArtifactsForRun',
        () => repository.replaceArtifactsForRun(
          taskId: task.id,
          runId: run.id,
          expectedArtifacts: previousArtifacts,
          artifacts: updatedRunArtifacts,
          updatedAt: now,
        ),
      );
      final merged =
          _snapshot.artifacts
              .where(
                (artifact) =>
                    artifact.taskId != task.id || artifact.runId != run.id,
              )
              .toList(growable: true)
            ..addAll(updatedRunArtifacts);
      _snapshot = _snapshot.copyWith(
        artifacts: List.unmodifiable(merged),
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();

      await _appendEventWithinTransition(
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
    });
  }

  Future<List<ArtifactRecord>> updateArtifactStatuses({
    required String taskId,
    required Iterable<String> artifactIds,
    required ArtifactStatus status,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
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

      final changed = <ArtifactRecord>[];
      for (final artifact in _snapshot.artifacts) {
        if (artifact.taskId == task.id && ids.contains(artifact.id)) {
          final updated = _sanitizeArtifact(artifact.copyWith(status: status));
          changed.add(updated);
        }
      }

      final now = _clock();
      final expectedArtifacts = _snapshot.artifacts
          .where((artifact) => ids.contains(artifact.id))
          .toList(growable: false);
      await _awaitRepository(
        'updateArtifacts',
        () => repository.updateArtifacts(
          expectedArtifacts: expectedArtifacts,
          artifacts: changed,
          updatedAt: now,
        ),
      );
      final changedById = <String, ArtifactRecord>{
        for (final artifact in changed) artifact.id: artifact,
      };
      final merged = _snapshot.artifacts
          .map((artifact) => changedById[artifact.id] ?? artifact)
          .toList(growable: false);
      _snapshot = _snapshot.copyWith(
        artifacts: List.unmodifiable(merged),
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();
      return List.unmodifiable(changed);
    });
  }

  Future<TaskRecord> markTaskDoneLocally(
    String taskId, {
    String? rationale,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final task = await _updateTaskWithinTransition(
        taskId,
        status: TaskStatus.done,
        summary: 'Marked done locally.',
      );
      await _appendReviewEventIfPossibleWithinTransition(
        task,
        'Marked done locally.',
        metadata: <String, Object?>{
          'review_action': 'mark_done_locally',
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
      return taskById(task.id) ?? task;
    });
  }

  Future<TaskRecord> requestTaskChanges(
    String taskId, {
    String? rationale,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final task = await _updateTaskWithinTransition(
        taskId,
        status: TaskStatus.needsChanges,
        summary: _trimmedOrNull(rationale) ?? 'Changes requested.',
      );
      await _appendReviewEventIfPossibleWithinTransition(
        task,
        'Changes requested.',
        metadata: <String, Object?>{
          'review_action': 'request_changes',
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
      return taskById(task.id) ?? task;
    });
  }

  Future<TaskRecord> retryTask(String taskId, {String? rationale}) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final task = taskById(taskId);
      if (task == null) throw StateError('Task not found: $taskId');
      final previousRunId = _trimmedOrNull(task.currentRunId);
      final previousStatus = task.status;
      final retrySummary = _trimmedOrNull(rationale) ?? 'Queued for retry.';

      final queued = await _updateTaskWithinTransition(
        task.id,
        status: TaskStatus.queued,
        currentRunId: null,
        summary: retrySummary,
        error: null,
      );

      if (previousRunId != null && _runExists(previousRunId)) {
        await _appendEventWithinTransition(
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
    });
  }

  Future<List<TaskRecord>> recoverInterruptedRuns({
    String reason = 'Task run interrupted before completion.',
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final recovered = <TaskRecord>[];
      final tasks = List<TaskRecord>.of(_snapshot.tasks);
      for (final task in tasks) {
        if (!_isInterruptedTaskState(task.status)) continue;
        final runId = _trimmedOrNull(task.currentRunId);
        if (runId == null) continue;
        final run = _runById(runId);
        if (run == null ||
            run.taskId != task.id ||
            !_isActiveRunState(run.status)) {
          continue;
        }
        await _updateRunWithinTransition(
          run.id,
          status: TaskStatus.failed,
          endedAt: _clock(),
          error: reason,
        );

        final updated = await _updateTaskWithinTransition(
          task.id,
          status: TaskStatus.failed,
          summary: reason,
          error: reason,
        );
        recovered.add(updated);

        await _appendEventWithinTransition(
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
      return List.unmodifiable(recovered);
    });
  }

  Future<TaskRecord> rejectTask(String taskId, {String? rationale}) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final task = await _updateTaskWithinTransition(
        taskId,
        status: TaskStatus.rejected,
        summary: _trimmedOrNull(rationale) ?? 'Task rejected.',
      );
      await _appendReviewEventIfPossibleWithinTransition(
        task,
        'Task rejected.',
        metadata: <String, Object?>{
          'review_action': 'reject',
          if (_trimmedOrNull(rationale) != null)
            'rationale': _trimmedOrNull(rationale),
        },
      );
      return taskById(task.id) ?? task;
    });
  }

  Future<ApprovalRequestRecord> resolveApproval(
    String approvalId,
    ApprovalStatus status, {
    String? rationale,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final target = approvalId.trim();
      final index = _snapshot.approvals.indexWhere(
        (approval) => approval.id == target,
      );
      if (index < 0) {
        throw StateError('Approval request not found: $approvalId');
      }
      if (status == ApprovalStatus.pending) {
        throw ArgumentError.value(
          status,
          'status',
          'Must be a resolved status',
        );
      }

      final now = _clock();
      final existing = _snapshot.approvals[index];
      final resolved = existing.copyWith(
        status: status,
        resolvedAt: now,
        destination: _sanitizedTrimmedOrNull(existing.destination),
        riskSummary: _sanitizedTrimmedOrNull(existing.riskSummary),
        rationale: _sanitizedTrimmedOrNull(rationale ?? existing.rationale),
        metadata: dataSanitizer.sanitize(existing.metadata),
      );
      await _awaitRepository(
        'upsertApproval',
        () => repository.upsertApproval(
          resolved,
          expected: existing,
          updatedAt: now,
        ),
      );
      final approvals = [..._snapshot.approvals];
      final currentIndex = approvals.indexWhere(
        (approval) => approval.id == resolved.id,
      );
      if (currentIndex < 0) {
        throw StateError(
          'Approval request disappeared after update: $approvalId',
        );
      }
      approvals[currentIndex] = resolved;
      _snapshot = _snapshot.copyWith(approvals: approvals, updatedAt: now);
      _markRepositoryChanged();
      notifyListeners();

      final task = taskById(existing.taskId);
      if (task != null) {
        await _appendReviewEventIfPossibleWithinTransition(
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
    });
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
    if (!_loaded) await load();
    return _withStateTransition(
      () => _updateTaskWithinTransition(
        taskId,
        title: title,
        description: description,
        workspacePath: workspacePath,
        agentName: agentName,
        status: status,
        priority: priority,
        sessionId: sessionId,
        currentRunId: currentRunId,
        summary: summary,
        error: error,
        resourceId: resourceId,
        skillIds: skillIds,
        metadata: metadata,
      ),
    );
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
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final target = taskId.trim();
      if (target.isEmpty) return;
      final tasks = _snapshot.tasks
          .where((task) => task.id != target)
          .toList(growable: false);
      if (tasks.length == _snapshot.tasks.length) return;
      final expected = TaskDeleteExpectation.fromSnapshot(_snapshot, target);
      final now = _clock();
      await _awaitRepository(
        'deleteTask',
        () => repository.deleteTask(expected, updatedAt: now),
      );
      _snapshot = _snapshot.copyWith(
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
        updatedAt: now,
      );
      _markRepositoryChanged();
      notifyListeners();
    });
  }

  Future<RawPayloadPurgeResult> purgeRawPayloads({
    Duration retention = const Duration(days: 30),
    bool force = false,
  }) async {
    if (!_loaded) await load();
    return _withStateTransition(() async {
      final target = repository;
      if (target is! RawPayloadMaintenanceRepository) {
        throw UnsupportedError(
          'This task repository does not support raw payload maintenance.',
        );
      }
      final maintenanceRepository = target as RawPayloadMaintenanceRepository;
      final result = await _awaitRepository(
        'purgeRawPayloads',
        () => maintenanceRepository.purgeRawPayloads(
          now: _clock(),
          retention: retention,
          force: force,
        ),
      );
      await _reloadRepositoryWithinTransition();
      return result;
    });
  }

  void _markRepositoryChanged() {
    // A different connection may have committed immediately before this
    // write. Force the next refresh to reload instead of recording a revision
    // that may include rows absent from the local snapshot.
    _revision = -1;
  }

  bool _adoptAuthoritativeProjection() {
    final target = repository;
    if (target is! AuthoritativeTaskRepositoryProjection) return false;
    final projection = (target as AuthoritativeTaskRepositoryProjection)
        .authoritativeProjection;
    _snapshot = projection.snapshot;
    _revision = projection.revision;
    return true;
  }

  Future<void> _reloadRepositoryWithinTransition() async {
    final loaded = await _awaitRepository(
      'loadRepository',
      repository.loadRepository,
    );
    _snapshot = loaded.snapshot;
    _revision = loaded.revision;
    notifyListeners();
  }

  DateTime _latestTimestamp(
    DateTime first,
    DateTime second,
    DateTime third,
    DateTime fourth,
  ) {
    var latest = first;
    for (final candidate in <DateTime>[second, third, fourth]) {
      if (candidate.isAfter(latest)) latest = candidate;
    }
    return latest;
  }

  Future<T> _withStateTransition<T>(Future<T> Function() action) {
    final fault = _persistenceFault;
    if (fault != null) return Future<T>.error(fault);
    final previous = _stateTransition;
    final result = Completer<T>();
    final transition = () async {
      try {
        await previous;
      } on Object {
        // A failed transition must not prevent later repository operations.
      }
      try {
        _throwIfPersistenceFaulted();
        result.complete(await action());
      } on Object catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    }();
    _stateTransition = transition;
    return result.future;
  }

  Future<void> settle() async {
    _throwIfPersistenceFaulted();
    final loading = _loadFuture;
    if (loading != null) await loading;
    await Future<void>.value();
    while (true) {
      final transition = _stateTransition;
      await transition;
      _throwIfPersistenceFaulted();
      if (identical(transition, _stateTransition)) return;
    }
  }

  Future<T> _awaitRepository<T>(
    String operationName,
    Future<T> Function() operation,
  ) async {
    _throwIfPersistenceFaulted();
    final generation = _persistenceGeneration + 1;
    final source = operation();
    late final Future<void> tracked;
    tracked = source.then<void>(
      (_) => _repositoryOperationCompleted(tracked),
      onError: (Object _, StackTrace _) {
        _repositoryOperationCompleted(tracked);
      },
    );
    _repositoryOperations.add(tracked);
    if (_persistenceQuiesced?.isCompleted ?? false) {
      _persistenceQuiesced = null;
    }
    return source.timeout(
      persistenceWatchdog,
      onTimeout: () {
        final fault = _persistenceFault ??= TaskPersistenceStalledException(
          operation: operationName,
          watchdog: persistenceWatchdog,
          generation: generation,
        );
        _persistenceGeneration = fault.generation;
        throw fault;
      },
    );
  }

  void _repositoryOperationCompleted(Future<void> operation) {
    _repositoryOperations.remove(operation);
    if (_repositoryOperations.isNotEmpty) return;
    final quiesced = _persistenceQuiesced;
    _persistenceQuiesced = null;
    if (quiesced != null && !quiesced.isCompleted) quiesced.complete();
  }

  void _throwIfPersistenceFaulted() {
    final fault = _persistenceFault;
    if (fault != null) throw fault;
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

  bool _recordIdExistsOutsideArtifactRun(
    String id, {
    required String taskId,
    required String runId,
  }) {
    if (taskById(id) != null) return true;
    return _snapshot.runs.any((run) => run.id == id) ||
        _snapshot.events.any((event) => event.id == id) ||
        _snapshot.approvals.any((approval) => approval.id == id) ||
        _snapshot.resources.any((resource) => resource.id == id) ||
        _snapshot.artifacts.any(
          (artifact) =>
              artifact.id == id &&
              (artifact.taskId != taskId || artifact.runId != runId),
        );
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

  bool _isInterruptedTaskState(TaskStatus status) {
    return switch (status) {
      TaskStatus.running ||
      TaskStatus.dispatched ||
      TaskStatus.blockedOnPermission ||
      TaskStatus.collectingArtifacts => true,
      _ => false,
    };
  }

  bool _isActiveRunState(TaskStatus status) {
    return switch (status) {
      TaskStatus.running || TaskStatus.dispatched => true,
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

  List<ArtifactRecord> _sanitizeArtifacts(Iterable<ArtifactRecord> artifacts) {
    return List<ArtifactRecord>.unmodifiable(artifacts.map(_sanitizeArtifact));
  }

  ArtifactRecord _sanitizeArtifact(ArtifactRecord artifact) {
    return artifact.copyWith(
      title: dataSanitizer.sanitizeText(artifact.title),
      path: artifact.path == null
          ? null
          : dataSanitizer.sanitizeText(artifact.path!),
      contentPreview: artifact.contentPreview == null
          ? null
          : dataSanitizer.sanitizeText(artifact.contentPreview!),
      metadata: dataSanitizer.sanitize(
        Map<String, Object?>.of(artifact.metadata),
      ),
    );
  }

  Future<TaskRunRecord> _updateRunWithinTransition(
    String runId, {
    TaskStatus? status,
    DateTime? endedAt,
    String? sessionId,
    Object? promptSnapshot = _unchanged,
    Object? model = _unchanged,
    String? error,
  }) async {
    final target = runId.trim();
    final index = _snapshot.runs.indexWhere((run) => run.id == target);
    if (index < 0) throw StateError('Task run not found: $runId');
    final now = _clock();
    final existing = _snapshot.runs[index];
    final updated = existing.copyWith(
      status: status,
      endedAt: endedAt ?? existing.endedAt,
      sessionId: sessionId ?? existing.sessionId,
      promptSnapshot: _sanitizedTrimmedOrNull(
        identical(promptSnapshot, _unchanged)
            ? existing.promptSnapshot
            : promptSnapshot as String?,
      ),
      model: identical(model, _unchanged)
          ? existing.model
          : _trimmedOrNull(model as String?),
      error: _sanitizedTrimmedOrNull(error ?? existing.error),
    );
    final persisted = await _awaitRepository(
      'updateRun',
      () => repository.updateRun(updated, expected: existing, updatedAt: now),
    );
    if (_adoptAuthoritativeProjection()) {
      notifyListeners();
      return _runById(persisted.id) ?? persisted;
    }
    final runs = [..._snapshot.runs];
    final currentIndex = runs.indexWhere(
      (candidate) => candidate.id == persisted.id,
    );
    if (currentIndex < 0) {
      throw StateError('Task run disappeared after update: $runId');
    }
    runs[currentIndex] = persisted;
    _snapshot = _snapshot.copyWith(runs: runs, updatedAt: now);
    _markRepositoryChanged();
    notifyListeners();
    return persisted;
  }

  Future<TaskRecord> _updateTaskWithinTransition(
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
    final index = _indexOfTask(taskId);
    if (index < 0) throw StateError('Task not found: $taskId');
    final existing = _snapshot.tasks[index];
    final now = _clock();
    final updated = existing.copyWith(
      title: title == null
          ? null
          : dataSanitizer.sanitizeText(_requiredText(title, 'title')),
      description: description == null
          ? null
          : dataSanitizer.sanitizeText(description.trim()),
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
      summary: _sanitizedTrimmedOrNull(
        identical(summary, _unchanged) ? existing.summary : summary as String?,
      ),
      error: _sanitizedTrimmedOrNull(
        identical(error, _unchanged) ? existing.error : error as String?,
      ),
      resourceId: identical(resourceId, _unchanged)
          ? existing.resourceId
          : _trimmedOrNull(resourceId as String?),
      skillIds: skillIds == null ? null : _cleanStringList(skillIds),
      metadata: dataSanitizer.sanitize(metadata ?? existing.metadata),
    );
    final persisted = await _awaitRepository(
      'updateTask',
      () => repository.updateTask(updated, expected: existing),
    );
    if (_adoptAuthoritativeProjection()) {
      notifyListeners();
      return taskById(persisted.id) ?? persisted;
    }
    final tasks = [..._snapshot.tasks];
    final currentIndex = tasks.indexWhere(
      (candidate) => candidate.id == persisted.id,
    );
    if (currentIndex < 0) {
      throw StateError('Task disappeared after update: $taskId');
    }
    tasks[currentIndex] = persisted;
    _snapshot = _snapshot.copyWith(tasks: _dedupeTasks(tasks), updatedAt: now);
    _markRepositoryChanged();
    notifyListeners();
    return persisted;
  }

  Future<TaskEventRecord> _appendEventWithinTransition({
    required String taskId,
    required String runId,
    required TaskEventKind kind,
    required String text,
    String? sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final task = taskById(taskId);
    if (task == null) throw StateError('Task not found: $taskId');
    final run = _runById(runId);
    if (run == null) throw StateError('Task run not found: $runId');
    final now = _clock();
    final event = TaskEventRecord(
      id: _newId('event'),
      taskId: task.id,
      runId: run.id,
      kind: kind,
      text: dataSanitizer.sanitizeText(
        kind == TaskEventKind.assistant ? text : text.trim(),
      ),
      createdAt: now,
      sessionId: _trimmedOrNull(sessionId),
      metadata: dataSanitizer.sanitize(metadata),
    );
    await _awaitRepository(
      'appendEvents',
      () => repository.appendEvents(<TaskEventRecord>[event], updatedAt: now),
    );
    _snapshot = _snapshot.copyWith(
      events: [..._snapshot.events, event],
      updatedAt: now,
    );
    _markRepositoryChanged();
    notifyListeners();
    return event;
  }

  Future<void> _appendReviewEventIfPossibleWithinTransition(
    TaskRecord task,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final runId = _trimmedOrNull(task.currentRunId);
    if (runId == null) return;
    final runExists = _snapshot.runs.any((run) => run.id == runId);
    if (!runExists) return;
    await _appendEventWithinTransition(
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

  String? _sanitizedTrimmedOrNull(String? value) {
    final trimmed = _trimmedOrNull(value);
    return trimmed == null ? null : dataSanitizer.sanitizeText(trimmed);
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

bool _jsonValuesEqual(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_jsonValuesEqual(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_jsonValuesEqual(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}
