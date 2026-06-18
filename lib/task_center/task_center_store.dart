import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'task_center_models.dart';

typedef TaskCenterClock = DateTime Function();
typedef TaskCenterIdGenerator = String Function();

const Duration _claimedStaleAfter = Duration(minutes: 2);
const Duration _runningStaleAfter = Duration(minutes: 10);
const Duration _permissionStaleAfter = Duration(minutes: 5);

class TaskCenterStore {
  TaskCenterStore({
    String? path,
    TaskCenterClock? now,
    TaskCenterIdGenerator? idGenerator,
    Map<String, String>? environment,
  }) : path = path ?? resolveDefaultPath(environment: environment),
       _now = now ?? DateTime.now,
       _idGenerator = idGenerator ?? _defaultId;

  final String path;
  final TaskCenterClock _now;
  final TaskCenterIdGenerator _idGenerator;
  Future<void> _writeChain = Future<void>.value();

  static String resolveDefaultPath({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final explicit = env['IANVS_ACP_TASK_CENTER_PATH'];
    if (explicit != null && explicit.trim().isNotEmpty) return explicit.trim();

    final legacyExplicit = env['ACP_TASK_CENTER_PATH'];
    if (legacyExplicit != null && legacyExplicit.trim().isNotEmpty) {
      return legacyExplicit.trim();
    }

    final xdgDataHome = env['XDG_DATA_HOME'];
    if (xdgDataHome != null && xdgDataHome.trim().isNotEmpty) {
      return '${xdgDataHome.trim()}/ianvs-acp/task_center.json';
    }

    final home = env['HOME'];
    if (home == null || home.trim().isEmpty) {
      return 'task_center.json';
    }
    return '${home.trim()}/.local/share/ianvs-acp/task_center.json';
  }

  Future<TaskCenterSnapshot> load() async {
    final file = File(path);
    if (!await file.exists()) return const TaskCenterSnapshot();
    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return const TaskCenterSnapshot();
    try {
      return _snapshotFromRawJson(raw);
    } on FormatException {
      final repaired = _firstJsonRoot(raw);
      if (repaired == null) rethrow;
      final snapshot = _snapshotFromRawJson(repaired);
      await _write(snapshot);
      return snapshot;
    }
  }

  Future<TaskWorkspace> createWorkspace({
    required String title,
    String description = '',
    String workspaceCwd = '',
    TaskWorkspaceAgentConfig agentConfig = const TaskWorkspaceAgentConfig(),
  }) async {
    final cleanTitle = _requiredText(title, 'title');
    final snapshot = await load();
    final now = _now().toUtc();
    final workspace = TaskWorkspace(
      id: _idGenerator(),
      title: cleanTitle,
      description: description.trim(),
      workspaceCwd: workspaceCwd.trim(),
      agentConfig: agentConfig,
      createdAt: now,
      updatedAt: now,
    );
    await _write(
      snapshot.copyWith(workspaces: [...snapshot.workspaces, workspace]),
    );
    return workspace;
  }

  Future<TaskWorkspace> updateWorkspaceAgentConfig({
    required String workspaceId,
    required TaskWorkspaceAgentConfig agentConfig,
    String? workspaceCwd,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final now = _now().toUtc();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      workspaceCwd: workspaceCwd?.trim(),
      agentConfig: agentConfig,
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace;
  }

  Future<TaskCenterTask> createTask({
    required String workspaceId,
    required String title,
    String description = '',
    String details = '',
    String objective = '',
    List<String> acceptanceCriteria = const <String>[],
    List<TaskCenterHumanQuestion> humanQuestions =
        const <TaskCenterHumanQuestion>[],
    TaskCenterTaskOwner currentOwner = const TaskCenterTaskOwner.unassigned(),
    TaskCenterTaskOwner? suggestedOwner,
    TaskCenterReadiness readiness = TaskCenterReadiness.needsInfo,
    String routeReason = '',
    TaskCenterStatus status = TaskCenterStatus.todo,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final cleanTitle = _requiredText(title, 'title');
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final sortOrder = workspace.tasks
        .where((task) => task.status == status)
        .length;
    final now = _now().toUtc();
    final task = TaskCenterTask(
      id: _idGenerator(),
      workspaceId: workspace.id,
      title: cleanTitle,
      description: description.trim(),
      details: details.trim(),
      objective: objective.trim(),
      acceptanceCriteria: _cleanStringList(acceptanceCriteria),
      humanQuestions: humanQuestions,
      currentOwner: currentOwner,
      suggestedOwner: suggestedOwner,
      readiness: readiness,
      routeReason: routeReason.trim(),
      status: status,
      sortOrder: sortOrder,
      createdAt: now,
      updatedAt: now,
      metadata: Map<String, Object?>.unmodifiable(metadata),
    );
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders([...workspace.tasks, task]),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return task;
  }

  Future<TaskCenterTask> updateTask({
    required String workspaceId,
    required String taskId,
    String? title,
    String? description,
    String? details,
    String? objective,
    List<String>? acceptanceCriteria,
    List<TaskCenterHumanQuestion>? humanQuestions,
    TaskCenterTaskOwner? currentOwner,
    TaskCenterTaskOwner? suggestedOwner,
    TaskCenterReadiness? readiness,
    String? routeReason,
    String? executionResult,
    String? verificationNotes,
    List<TaskCenterWorkRun>? workRuns,
    List<TaskCenterEvent>? events,
    TaskCenterStatus? status,
    Map<String, Object?>? metadata,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var updated = task.copyWith(
      title: title == null ? null : _requiredText(title, 'title'),
      description: description?.trim(),
      details: details?.trim(),
      objective: objective?.trim(),
      acceptanceCriteria: acceptanceCriteria == null
          ? null
          : _cleanStringList(acceptanceCriteria),
      humanQuestions: humanQuestions,
      currentOwner: currentOwner,
      suggestedOwner: suggestedOwner,
      readiness: readiness,
      routeReason: routeReason?.trim(),
      executionResult: executionResult?.trim(),
      verificationNotes: verificationNotes?.trim(),
      workRuns: workRuns,
      events: events,
      status: status,
      updatedAt: now,
      metadata: metadata == null
          ? null
          : Map<String, Object?>.unmodifiable(metadata),
    );
    if (status != null && status != task.status) {
      final targetIndex = workspace.tasks
          .where((candidate) => candidate.status == status)
          .length;
      updated = updated.copyWith(sortOrder: targetIndex);
    }
    final tasks = workspace.tasks
        .map((candidate) => candidate.id == taskId ? updated : candidate)
        .toList();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders(tasks),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
    );
  }

  Future<TaskCenterTask> moveTask({
    required String workspaceId,
    required String taskId,
    required TaskCenterStatus status,
    required int index,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    final targetTasks =
        workspace.tasks
            .where(
              (candidate) =>
                  candidate.status == status && candidate.id != taskId,
            )
            .toList()
          ..sort(_compareTaskOrder);
    final clampedIndex = index.clamp(0, targetTasks.length).toInt();
    final moved = task.copyWith(
      status: status,
      sortOrder: clampedIndex,
      updatedAt: now,
    );
    targetTasks.insert(clampedIndex, moved);

    final remaining = workspace.tasks
        .where(
          (candidate) => candidate.status != status && candidate.id != taskId,
        )
        .toList();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      tasks: _normalizeOrders([...remaining, ...targetTasks]),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
    );
  }

  Future<bool> deleteTask({
    required String workspaceId,
    required String taskId,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final tasks = workspace.tasks
        .where((candidate) => candidate.id != taskId)
        .toList();
    if (tasks.length == workspace.tasks.length) return false;
    final nextWorkspace = workspace.copyWith(
      updatedAt: _now().toUtc(),
      tasks: _normalizeOrders(tasks),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return true;
  }

  Future<TaskWorkspaceChatMessage> postWorkspaceChatMessage({
    required String workspaceId,
    required TaskWorkspaceChatRole role,
    required String actor,
    required String content,
    String agentName = '',
    String? taskId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final now = _now().toUtc();
    final message = TaskWorkspaceChatMessage(
      id: _idGenerator(),
      workspaceId: workspace.id,
      role: role,
      actor: _requiredText(actor, 'actor'),
      agentName: agentName.trim(),
      content: _requiredText(content, 'content'),
      taskId: taskId?.trim().isEmpty == true ? null : taskId?.trim(),
      createdAt: now,
      metadata: Map<String, Object?>.unmodifiable(metadata),
    );
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
      chatMessages: [...workspace.chatMessages, message],
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return message;
  }

  Future<List<TaskWorkspaceChatMessage>> listWorkspaceChatMessages({
    required String workspaceId,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    return workspace.chatMessages;
  }

  Future<TaskCenterTask> transferTaskOwner({
    required String workspaceId,
    required String taskId,
    required TaskCenterTaskOwner owner,
    TaskCenterReadiness? readiness,
    String routeReason = '',
    String actor = 'agent',
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final reason = routeReason.trim();
    final event = _event(
      type: 'owner_transferred',
      actor: actor,
      message: reason.isEmpty ? 'Transferred task owner.' : reason,
      metadata: <String, Object?>{'owner': owner.toJson()},
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: owner,
        readiness: readiness,
        routeReason: reason,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> requestHumanConfirmation({
    required String workspaceId,
    required String taskId,
    required List<String> questions,
    String routeReason = '',
    String actor = 'agent',
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final existingQuestions = <String, TaskCenterHumanQuestion>{
      for (final question in task.humanQuestions)
        _questionKey(question.question): question,
    };
    final requestedQuestions = <TaskCenterHumanQuestion>[];
    final newQuestions = <TaskCenterHumanQuestion>[];
    for (final question in _cleanStringList(questions)) {
      final key = _questionKey(question);
      final existing = existingQuestions[key];
      if (existing != null) {
        requestedQuestions.add(existing);
        continue;
      }
      final created = TaskCenterHumanQuestion(
        id: _idGenerator(),
        question: question,
      );
      existingQuestions[key] = created;
      requestedQuestions.add(created);
      newQuestions.add(created);
    }
    final reason = routeReason.trim();
    final event = _event(
      type: 'human_confirmation_requested',
      actor: actor,
      message: reason.isEmpty ? 'Requested human confirmation.' : reason,
      metadata: <String, Object?>{
        'questions': requestedQuestions
            .map((question) => question.toJson())
            .toList(),
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: const TaskCenterTaskOwner.human(),
        readiness: TaskCenterReadiness.waitingHuman,
        routeReason: reason,
        humanQuestions: [...task.humanQuestions, ...newQuestions],
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> answerHumanQuestion({
    required String workspaceId,
    required String taskId,
    required String questionId,
    required String answer,
    String actor = 'human',
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final cleanQuestionId = _requiredText(questionId, 'question_id');
    final cleanAnswer = _requiredText(answer, 'answer');
    var found = false;
    final questions = task.humanQuestions
        .map((question) {
          if (question.id != cleanQuestionId) return question;
          found = true;
          return question.copyWith(answer: cleanAnswer, resolved: true);
        })
        .toList(growable: false);
    if (!found) throw FormatException('Unknown question "$questionId".');
    final event = _event(
      type: 'human_question_answered',
      actor: actor,
      message: 'Answered a human confirmation question.',
      metadata: <String, Object?>{
        'question_id': cleanQuestionId,
        'answer': cleanAnswer,
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        humanQuestions: questions,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> claimWorkTask({
    required String workspaceId,
    required String taskId,
    required String agentName,
    String actor = 'agent',
  }) async {
    final cleanAgentName = _requiredText(agentName, 'agent_name');
    return startWorkRun(
      workspaceId: workspaceId,
      taskId: taskId,
      agentName: cleanAgentName,
      actor: actor,
    );
  }

  Future<TaskCenterTask> startWorkRun({
    required String workspaceId,
    required String taskId,
    required String agentName,
    String sessionId = '',
    String progressSummary = '',
    String actor = 'agent',
  }) async {
    final cleanAgentName = _requiredText(agentName, 'agent_name');
    final cleanSessionId = sessionId.trim();
    final cleanSummary = progressSummary.trim();
    final owner = TaskCenterTaskOwner.workAgent(cleanAgentName);
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    final releasedRuns = task.workRuns
        .map((run) {
          if (!run.isActive) return run;
          return run.copyWith(
            state: TaskCenterWorkRunState.released,
            lastHeartbeatAt: now,
            completedAt: now,
            blockerReason: 'Superseded by a new work run.',
          );
        })
        .toList(growable: false);
    final run = TaskCenterWorkRun(
      id: _idGenerator(),
      taskId: task.id,
      agentName: cleanAgentName,
      sessionId: cleanSessionId,
      state: TaskCenterWorkRunState.running,
      startedAt: now,
      lastHeartbeatAt: now,
      progressSummary: cleanSummary,
    );
    final event = _event(
      type: 'work_task_claimed',
      actor: actor,
      message: '$cleanAgentName claimed the task.',
      metadata: <String, Object?>{
        'owner': owner.toJson(),
        'run_id': run.id,
        if (cleanSessionId.isNotEmpty) 'session_id': cleanSessionId,
        if (cleanSummary.isNotEmpty) 'progress_summary': cleanSummary,
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: owner,
        readiness: TaskCenterReadiness.ready,
        status: TaskCenterStatus.inProgress,
        workRuns: [...releasedRuns, run],
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> heartbeatWorkRun({
    required String workspaceId,
    required String taskId,
    required String runId,
    required TaskCenterWorkRunState state,
    String progressSummary = '',
    int? nextCheckMinutes,
    String actor = 'agent',
  }) async {
    final cleanRunId = _requiredText(runId, 'run_id');
    final cleanSummary = progressSummary.trim();
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var found = false;
    var terminalRun = false;
    final runs = task.workRuns
        .map((run) {
          if (run.id != cleanRunId) return run;
          found = true;
          if (!run.isActive) {
            terminalRun = true;
            return run;
          }
          return run.copyWith(
            state: state,
            lastHeartbeatAt: now,
            progressSummary: cleanSummary.isEmpty
                ? run.progressSummary
                : cleanSummary,
            nextCheckAt: nextCheckMinutes == null
                ? run.nextCheckAt
                : now.add(Duration(minutes: nextCheckMinutes)),
          );
        })
        .toList(growable: false);
    if (!found) throw FormatException('Unknown work run "$runId".');
    if (terminalRun) {
      throw FormatException('Work run "$runId" is not active.');
    }
    final event = _event(
      type: 'work_run_heartbeat',
      actor: actor,
      message: 'Updated worker heartbeat.',
      metadata: <String, Object?>{
        'run_id': cleanRunId,
        'state': state.id,
        if (cleanSummary.isNotEmpty) 'progress_summary': cleanSummary,
        ...?nextCheckMinutes == null
            ? null
            : <String, Object?>{'next_check_minutes': nextCheckMinutes},
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        workRuns: runs,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> bindWorkRunSession({
    required String workspaceId,
    required String taskId,
    required String runId,
    required String sessionId,
    String actor = 'app',
  }) async {
    final cleanRunId = _requiredText(runId, 'run_id');
    final cleanSessionId = _requiredText(sessionId, 'session_id');
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var found = false;
    final runs = task.workRuns
        .map((run) {
          if (run.id != cleanRunId) return run;
          found = true;
          return run.copyWith(
            sessionId: cleanSessionId,
            lastHeartbeatAt: now,
            metadata: <String, Object?>{
              ...run.metadata,
              'session_bound_at': now.toIso8601String(),
              'session_bound_by': actor,
            },
          );
        })
        .toList(growable: false);
    if (!found) throw FormatException('Unknown work run "$runId".');
    final event = _event(
      type: 'work_run_session_bound',
      actor: actor,
      message: 'Bound worker run to ACP session.',
      metadata: <String, Object?>{
        'run_id': cleanRunId,
        'session_id': cleanSessionId,
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        workRuns: runs,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> reportWorkBlocker({
    required String workspaceId,
    required String taskId,
    required String runId,
    required TaskCenterWorkBlockerType blockerType,
    required String blockerReason,
    List<String> questions = const <String>[],
    String actor = 'agent',
  }) async {
    final cleanRunId = _requiredText(runId, 'run_id');
    final cleanReason = _requiredText(blockerReason, 'blocker_reason');
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var found = false;
    final runState = switch (blockerType) {
      TaskCenterWorkBlockerType.needsHuman =>
        TaskCenterWorkRunState.waitingHuman,
      TaskCenterWorkBlockerType.permission =>
        TaskCenterWorkRunState.waitingPermission,
      _ => TaskCenterWorkRunState.blocked,
    };
    final runs = task.workRuns
        .map((run) {
          if (run.id != cleanRunId) return run;
          found = true;
          return run.copyWith(
            state: runState,
            lastHeartbeatAt: now,
            blockerReason: cleanReason,
            metadata: <String, Object?>{
              ...run.metadata,
              'blocker_type': blockerType.id,
            },
          );
        })
        .toList(growable: false);
    if (!found) throw FormatException('Unknown work run "$runId".');

    final nextReadiness = switch (blockerType) {
      TaskCenterWorkBlockerType.needsHuman => TaskCenterReadiness.waitingHuman,
      TaskCenterWorkBlockerType.permission => TaskCenterReadiness.blocked,
      TaskCenterWorkBlockerType.unclearGoal ||
      TaskCenterWorkBlockerType.missingAcceptance =>
        TaskCenterReadiness.needsInfo,
      _ => TaskCenterReadiness.blocked,
    };
    final nextOwner = blockerType == TaskCenterWorkBlockerType.needsHuman
        ? const TaskCenterTaskOwner.human()
        : const TaskCenterTaskOwner.fastAgent('');
    final newQuestions = blockerType == TaskCenterWorkBlockerType.needsHuman
        ? _newHumanQuestions(
            existing: task.humanQuestions,
            questions: questions,
          )
        : const <TaskCenterHumanQuestion>[];
    final event = _event(
      type: 'work_blocker_reported',
      actor: actor,
      message: cleanReason,
      metadata: <String, Object?>{
        'run_id': cleanRunId,
        'blocker_type': blockerType.id,
        if (newQuestions.isNotEmpty)
          'questions': newQuestions
              .map((question) => question.toJson())
              .toList(growable: false),
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: nextOwner,
        readiness: nextReadiness,
        routeReason: cleanReason,
        humanQuestions: [...task.humanQuestions, ...newQuestions],
        workRuns: runs,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> releaseWorkTask({
    required String workspaceId,
    required String taskId,
    required String runId,
    required String reason,
    String actor = 'agent',
  }) async {
    final cleanRunId = _requiredText(runId, 'run_id');
    final cleanReason = _requiredText(reason, 'reason');
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final now = _now().toUtc();
    var found = false;
    final runs = task.workRuns
        .map((run) {
          if (run.id != cleanRunId) return run;
          found = true;
          return run.copyWith(
            state: TaskCenterWorkRunState.released,
            lastHeartbeatAt: now,
            completedAt: now,
            blockerReason: cleanReason,
          );
        })
        .toList(growable: false);
    if (!found) throw FormatException('Unknown work run "$runId".');
    final nextOwner = workspace.agentConfig.fastAgentName.trim().isEmpty
        ? const TaskCenterTaskOwner.unassigned()
        : TaskCenterTaskOwner.fastAgent(workspace.agentConfig.fastAgentName);
    final event = _event(
      type: 'work_task_released',
      actor: actor,
      message: cleanReason,
      metadata: <String, Object?>{'run_id': cleanRunId},
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: nextOwner,
        readiness: TaskCenterReadiness.blocked,
        routeReason: cleanReason,
        workRuns: runs,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<List<TaskCenterTask>> listStalledWork({
    required String workspaceId,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final now = _now().toUtc();
    var changed = false;
    final stalledIds = <String>{};
    final tasks = workspace.tasks
        .map((task) {
          var taskChanged = false;
          var isStalled = false;
          final hadActiveRun = task.workRuns.any((run) => run.isActive);
          final runs = task.workRuns.toList(growable: false);
          final latestRun = runs.isEmpty ? null : runs.last;
          if (latestRun != null &&
              _canResumeRun(latestRun) &&
              _isRunStalled(latestRun, now)) {
            isStalled = true;
            if (latestRun.isActive) {
              taskChanged = true;
              runs[runs.length - 1] = latestRun.copyWith(
                state: TaskCenterWorkRunState.stale,
                lastHeartbeatAt: now,
                blockerReason: latestRun.blockerReason.isEmpty
                    ? 'Worker heartbeat is stale.'
                    : latestRun.blockerReason,
              );
            }
          }
          final currentRun = runs.isEmpty ? null : runs.last;
          final needsRecoverableRun =
              currentRun == null || _canResumeRun(currentRun);
          final missingRun =
              task.status == TaskCenterStatus.inProgress &&
              task.currentOwner.kind == TaskCenterOwnerKind.workAgent &&
              !hadActiveRun &&
              !runs.any((run) => run.isActive) &&
              needsRecoverableRun;
          if (missingRun) {
            isStalled = true;
            taskChanged = true;
          }
          if (!isStalled) return task;
          stalledIds.add(task.id);
          if (!taskChanged && task.readiness == TaskCenterReadiness.blocked) {
            return task;
          }
          changed = true;
          return task.copyWith(
            readiness: TaskCenterReadiness.blocked,
            routeReason: missingRun
                ? 'Worker task has no active work run.'
                : 'Worker heartbeat is stale.',
            workRuns: runs,
            updatedAt: now,
          );
        })
        .toList(growable: false);

    final nextWorkspace = workspace.copyWith(
      updatedAt: changed ? now : workspace.updatedAt,
      tasks: _normalizeOrders(tasks),
    );
    if (changed) await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks
        .where((task) => stalledIds.contains(task.id))
        .toList(growable: false);
  }

  Future<TaskCenterTask> recoverStalledTask({
    required String workspaceId,
    required String taskId,
    required TaskCenterRecoverAction action,
    String agentName = '',
    String reason = '',
    String actor = 'human',
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final cleanReason = reason.trim();
    final nextOwner = switch (action) {
      TaskCenterRecoverAction.nudgeWorker => task.currentOwner,
      TaskCenterRecoverAction.reassignWorker => TaskCenterTaskOwner.workAgent(
        _requiredText(agentName, 'agent_name'),
      ),
      TaskCenterRecoverAction.returnToFast => TaskCenterTaskOwner.fastAgent(
        workspace.agentConfig.fastAgentName,
      ),
      TaskCenterRecoverAction.sendToThinking =>
        TaskCenterTaskOwner.thinkingAgent(
          workspace.agentConfig.thinkingAgentName,
        ),
      TaskCenterRecoverAction.askHuman => const TaskCenterTaskOwner.human(),
      TaskCenterRecoverAction.markFailed => task.currentOwner,
    };
    final nextReadiness = switch (action) {
      TaskCenterRecoverAction.nudgeWorker ||
      TaskCenterRecoverAction.reassignWorker => TaskCenterReadiness.ready,
      TaskCenterRecoverAction.returnToFast => TaskCenterReadiness.needsInfo,
      TaskCenterRecoverAction.sendToThinking =>
        TaskCenterReadiness.needsThinking,
      TaskCenterRecoverAction.askHuman => TaskCenterReadiness.waitingHuman,
      TaskCenterRecoverAction.markFailed => TaskCenterReadiness.blocked,
    };
    final nextStatus = action == TaskCenterRecoverAction.markFailed
        ? TaskCenterStatus.review
        : task.status;
    final event = _event(
      type: 'stalled_work_recovered',
      actor: actor,
      message: cleanReason.isEmpty ? 'Recovered stalled work.' : cleanReason,
      metadata: <String, Object?>{
        'action': action.id,
        if (agentName.trim().isNotEmpty) 'agent_name': agentName.trim(),
      },
    );
    final nextWorkRuns = switch (action) {
      TaskCenterRecoverAction.nudgeWorker => _nudgeWorkRuns(
        task: task,
        agentName: nextOwner.agentName,
        now: event.createdAt,
      ),
      TaskCenterRecoverAction.reassignWorker => _reassignWorkRuns(
        task: task,
        agentName: nextOwner.agentName,
        now: event.createdAt,
      ),
      _ => task.workRuns,
    };
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: nextOwner,
        readiness: nextReadiness,
        routeReason: cleanReason,
        status: nextStatus,
        workRuns: nextWorkRuns,
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<TaskCenterTask> recordExecutionResult({
    required String workspaceId,
    required String taskId,
    required String executionResult,
    String verificationNotes = '',
    String actor = 'agent',
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final cleanResult = _requiredText(executionResult, 'execution_result');
    final cleanVerification = verificationNotes.trim();
    final event = _event(
      type: 'execution_result_recorded',
      actor: actor,
      message: 'Recorded execution result.',
      metadata: <String, Object?>{
        'execution_result': cleanResult,
        if (cleanVerification.isNotEmpty)
          'verification_notes': cleanVerification,
      },
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        executionResult: cleanResult,
        verificationNotes: cleanVerification,
        workRuns: _completeActiveRun(
          task.workRuns,
          actor: actor,
          now: event.createdAt,
        ),
        events: [...task.events, event],
        updatedAt: event.createdAt,
      ),
    );
  }

  Future<List<TaskCenterTask>> listRoleTasks({
    required String workspaceId,
    required TaskCenterOwnerKind ownerKind,
    String? agentName,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final tasks =
        workspace.tasks
            .where(
              (task) => task.currentOwner.matches(
                kind: ownerKind,
                agentName: agentName,
              ),
            )
            .toList()
          ..sort(_compareTaskOrder);
    return tasks;
  }

  Future<List<TaskCenterEvent>> listTaskEvents({
    required String workspaceId,
    required String taskId,
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    return _taskById(workspace, taskId).events;
  }

  Future<void> _write(TaskCenterSnapshot snapshot) async {
    final write = _writeChain.then((_) => _writeAtomically(snapshot));
    _writeChain = write.catchError((_) {});
    await write;
  }

  Future<void> _writeAtomically(TaskCenterSnapshot snapshot) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final tempFile = File(
      '$path.$pid.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await tempFile.writeAsString(
      '${encoder.convert(snapshot.toJson())}\n',
      flush: true,
    );
    await tempFile.rename(path);
  }

  TaskCenterSnapshot _snapshotFromRawJson(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('task center root must be a JSON object.');
    }
    return TaskCenterSnapshot.fromJson(decoded);
  }

  String? _firstJsonRoot(String raw) {
    final start = raw.indexOf('{');
    if (start < 0) return null;

    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var index = start; index < raw.length; index += 1) {
      final codeUnit = raw.codeUnitAt(index);

      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (codeUnit == 0x5c) {
          escaped = true;
        } else if (codeUnit == 0x22) {
          inString = false;
        }
        continue;
      }

      if (codeUnit == 0x22) {
        inString = true;
      } else if (codeUnit == 0x7b || codeUnit == 0x5b) {
        depth += 1;
      } else if (codeUnit == 0x7d || codeUnit == 0x5d) {
        depth -= 1;
        if (depth == 0) return raw.substring(start, index + 1);
        if (depth < 0) return null;
      }
    }

    return null;
  }

  TaskWorkspace _workspaceById(
    TaskCenterSnapshot snapshot,
    String workspaceId,
  ) {
    final cleanId = _requiredText(workspaceId, 'workspace_id');
    for (final workspace in snapshot.workspaces) {
      if (workspace.id == cleanId) return workspace;
    }
    throw FormatException('Unknown workspace "$workspaceId".');
  }

  TaskCenterTask _taskById(TaskWorkspace workspace, String taskId) {
    final cleanId = _requiredText(taskId, 'task_id');
    for (final task in workspace.tasks) {
      if (task.id == cleanId) return task;
    }
    throw FormatException('Unknown task "$taskId".');
  }

  TaskCenterSnapshot _replaceWorkspace(
    TaskCenterSnapshot snapshot,
    TaskWorkspace workspace,
  ) {
    return snapshot.copyWith(
      workspaces: snapshot.workspaces
          .map(
            (candidate) => candidate.id == workspace.id ? workspace : candidate,
          )
          .toList(growable: false),
    );
  }

  Future<TaskCenterTask> _replaceTask({
    required TaskCenterSnapshot snapshot,
    required TaskWorkspace workspace,
    required TaskCenterTask task,
  }) async {
    final nextWorkspace = workspace.copyWith(
      updatedAt: task.updatedAt,
      tasks: _normalizeOrders(
        workspace.tasks
            .map((candidate) => candidate.id == task.id ? task : candidate)
            .toList(growable: false),
      ),
    );
    await _write(_replaceWorkspace(snapshot, nextWorkspace));
    return nextWorkspace.tasks.firstWhere(
      (candidate) => candidate.id == task.id,
    );
  }

  List<TaskCenterWorkRun> _nudgeWorkRuns({
    required TaskCenterTask task,
    required String agentName,
    required DateTime now,
  }) {
    final cleanAgentName = _requiredText(agentName, 'agent_name');
    var resumed = false;
    final runs = task.workRuns
        .map((run) {
          if (resumed ||
              run.agentName != cleanAgentName ||
              !_canResumeRun(run)) {
            return run;
          }
          resumed = true;
          return run.copyWith(
            state: TaskCenterWorkRunState.running,
            lastHeartbeatAt: now,
            progressSummary: run.progressSummary.isEmpty
                ? 'Nudged from stalled recovery.'
                : run.progressSummary,
            blockerReason: '',
          );
        })
        .toList(growable: false);
    if (resumed) return runs;
    return [
      ...runs,
      _newRecoveredWorkRun(
        task: task,
        agentName: cleanAgentName,
        now: now,
        progressSummary: 'Nudged from stalled recovery.',
      ),
    ];
  }

  List<TaskCenterWorkRun> _reassignWorkRuns({
    required TaskCenterTask task,
    required String agentName,
    required DateTime now,
  }) {
    final cleanAgentName = _requiredText(agentName, 'agent_name');
    return [
      for (final run in task.workRuns)
        _shouldReleaseRunForRecovery(run)
            ? run.copyWith(
                state: TaskCenterWorkRunState.released,
                lastHeartbeatAt: now,
                completedAt: run.completedAt ?? now,
                blockerReason: 'Recovered by reassigning to $cleanAgentName.',
              )
            : run,
      _newRecoveredWorkRun(
        task: task,
        agentName: cleanAgentName,
        now: now,
        progressSummary: 'Reassigned from stalled recovery.',
      ),
    ];
  }

  TaskCenterWorkRun _newRecoveredWorkRun({
    required TaskCenterTask task,
    required String agentName,
    required DateTime now,
    required String progressSummary,
  }) {
    return TaskCenterWorkRun(
      id: _idGenerator(),
      taskId: task.id,
      agentName: agentName,
      state: TaskCenterWorkRunState.running,
      startedAt: now,
      lastHeartbeatAt: now,
      progressSummary: progressSummary,
    );
  }

  List<TaskCenterHumanQuestion> _newHumanQuestions({
    required List<TaskCenterHumanQuestion> existing,
    required List<String> questions,
  }) {
    final existingQuestions = <String, TaskCenterHumanQuestion>{
      for (final question in existing)
        _questionKey(question.question): question,
    };
    final newQuestions = <TaskCenterHumanQuestion>[];
    for (final question in _cleanStringList(questions)) {
      final key = _questionKey(question);
      if (existingQuestions.containsKey(key)) continue;
      final created = TaskCenterHumanQuestion(
        id: _idGenerator(),
        question: question,
      );
      existingQuestions[key] = created;
      newQuestions.add(created);
    }
    return newQuestions;
  }

  TaskCenterEvent _event({
    required String type,
    required String actor,
    required String message,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return TaskCenterEvent(
      id: _idGenerator(),
      type: type,
      actor: actor.trim().isEmpty ? 'agent' : actor.trim(),
      message: message.trim(),
      createdAt: _now().toUtc(),
      metadata: Map<String, Object?>.unmodifiable(metadata),
    );
  }
}

List<TaskCenterWorkRun> _completeActiveRun(
  List<TaskCenterWorkRun> runs, {
  required String actor,
  required DateTime now,
}) {
  final cleanActor = actor.trim();
  var completed = false;
  return runs
      .map((run) {
        if (completed || !run.isActive) return run;
        if (cleanActor.isNotEmpty && run.agentName != cleanActor) return run;
        completed = true;
        return run.copyWith(
          state: TaskCenterWorkRunState.delivered,
          lastHeartbeatAt: now,
          completedAt: now,
        );
      })
      .toList(growable: false);
}

bool _canResumeRun(TaskCenterWorkRun run) {
  return switch (run.state) {
    TaskCenterWorkRunState.delivered ||
    TaskCenterWorkRunState.released ||
    TaskCenterWorkRunState.failed => false,
    _ => true,
  };
}

bool _shouldReleaseRunForRecovery(TaskCenterWorkRun run) {
  return run.isActive ||
      run.state == TaskCenterWorkRunState.stale ||
      run.state == TaskCenterWorkRunState.blocked;
}

bool _isRunStalled(TaskCenterWorkRun run, DateTime now) {
  return switch (run.state) {
    TaskCenterWorkRunState.claimed =>
      now.difference(run.lastHeartbeatAt) >= _claimedStaleAfter,
    TaskCenterWorkRunState.running =>
      now.difference(run.lastHeartbeatAt) >= _runningStaleAfter,
    TaskCenterWorkRunState.waitingPermission =>
      now.difference(run.lastHeartbeatAt) >= _permissionStaleAfter,
    TaskCenterWorkRunState.blocked ||
    TaskCenterWorkRunState.failed ||
    TaskCenterWorkRunState.released ||
    TaskCenterWorkRunState.stale => true,
    _ => false,
  };
}

List<TaskCenterTask> _normalizeOrders(List<TaskCenterTask> tasks) {
  final result = <TaskCenterTask>[];
  for (final status in TaskCenterStatus.values) {
    final group = tasks.where((task) => task.status == status).toList()
      ..sort(_compareTaskOrder);
    for (var index = 0; index < group.length; index++) {
      result.add(group[index].copyWith(sortOrder: index));
    }
  }
  return result;
}

int _compareTaskOrder(TaskCenterTask a, TaskCenterTask b) {
  final order = a.sortOrder.compareTo(b.sortOrder);
  if (order != 0) return order;
  return a.createdAt.compareTo(b.createdAt);
}

String _requiredText(String value, String fieldName) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) throw FormatException('$fieldName is required.');
  return trimmed;
}

List<String> _cleanStringList(List<String> values) {
  return values
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList(growable: false);
}

String _questionKey(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

String _defaultId() {
  return DateTime.now().toUtc().microsecondsSinceEpoch.toRadixString(36);
}
