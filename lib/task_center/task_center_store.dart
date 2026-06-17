import 'dart:convert';
import 'dart:io';

import 'task_center_models.dart';

typedef TaskCenterClock = DateTime Function();
typedef TaskCenterIdGenerator = String Function();

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
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('task center root must be a JSON object.');
    }
    return TaskCenterSnapshot.fromJson(decoded);
  }

  Future<TaskWorkspace> createWorkspace({
    required String title,
    String description = '',
    TaskWorkspaceAgentConfig agentConfig = const TaskWorkspaceAgentConfig(),
  }) async {
    final cleanTitle = _requiredText(title, 'title');
    final snapshot = await load();
    final now = _now().toUtc();
    final workspace = TaskWorkspace(
      id: _idGenerator(),
      title: cleanTitle,
      description: description.trim(),
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
  }) async {
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final now = _now().toUtc();
    final nextWorkspace = workspace.copyWith(
      updatedAt: now,
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
    final owner = TaskCenterTaskOwner.workAgent(cleanAgentName);
    final snapshot = await load();
    final workspace = _workspaceById(snapshot, workspaceId);
    final task = _taskById(workspace, taskId);
    final event = _event(
      type: 'work_task_claimed',
      actor: actor,
      message: '$cleanAgentName claimed the task.',
      metadata: <String, Object?>{'owner': owner.toJson()},
    );
    return _replaceTask(
      snapshot: snapshot,
      workspace: workspace,
      task: task.copyWith(
        currentOwner: owner,
        readiness: TaskCenterReadiness.ready,
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
    final file = File(path);
    await file.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await file.writeAsString('${encoder.convert(snapshot.toJson())}\n');
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
