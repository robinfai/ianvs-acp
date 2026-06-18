import 'package:flutter/foundation.dart';

import 'task_center_models.dart';
import 'task_center_store.dart';

class TaskCenterController extends ChangeNotifier {
  TaskCenterController({required this.store});

  final TaskCenterStore store;

  TaskCenterSnapshot _snapshot = const TaskCenterSnapshot();
  String? _selectedWorkspaceId;
  bool _loaded = false;

  TaskCenterSnapshot get snapshot => _snapshot;

  bool get loaded => _loaded;

  List<TaskWorkspace> get workspaces => _snapshot.workspaces;

  String? get selectedWorkspaceId => _selectedWorkspaceId;

  TaskWorkspace? get selectedWorkspace {
    final selectedId = _selectedWorkspaceId;
    if (selectedId != null) {
      for (final workspace in workspaces) {
        if (workspace.id == selectedId) return workspace;
      }
    }
    return workspaces.isEmpty ? null : workspaces.first;
  }

  Future<void> load() async {
    _snapshot = await store.load();
    _loaded = true;
    _ensureSelectedWorkspace();
    notifyListeners();
  }

  Future<TaskWorkspace> createWorkspace({
    required String title,
    String description = '',
    String workspaceCwd = '',
    TaskWorkspaceAgentConfig agentConfig = const TaskWorkspaceAgentConfig(),
  }) async {
    final workspace = await store.createWorkspace(
      title: title,
      description: description,
      workspaceCwd: workspaceCwd,
      agentConfig: agentConfig,
    );
    _selectedWorkspaceId = workspace.id;
    await _refresh();
    return workspace;
  }

  Future<TaskWorkspace> updateWorkspaceAgentConfig({
    required String workspaceId,
    required TaskWorkspaceAgentConfig agentConfig,
    String? workspaceCwd,
  }) async {
    final workspace = await store.updateWorkspaceAgentConfig(
      workspaceId: workspaceId,
      agentConfig: agentConfig,
      workspaceCwd: workspaceCwd,
    );
    await _refresh();
    return workspace;
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
  }) async {
    final task = await store.createTask(
      workspaceId: workspaceId,
      title: title,
      description: description,
      details: details,
      objective: objective,
      acceptanceCriteria: acceptanceCriteria,
      humanQuestions: humanQuestions,
      currentOwner: currentOwner,
      suggestedOwner: suggestedOwner,
      readiness: readiness,
      routeReason: routeReason,
      status: status,
    );
    await _refresh();
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
    TaskCenterStatus? status,
    Map<String, Object?>? metadata,
  }) async {
    final task = await store.updateTask(
      workspaceId: workspaceId,
      taskId: taskId,
      title: title,
      description: description,
      details: details,
      objective: objective,
      acceptanceCriteria: acceptanceCriteria,
      humanQuestions: humanQuestions,
      currentOwner: currentOwner,
      suggestedOwner: suggestedOwner,
      readiness: readiness,
      routeReason: routeReason,
      executionResult: executionResult,
      verificationNotes: verificationNotes,
      status: status,
      metadata: metadata,
    );
    await _refresh();
    return task;
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
    final message = await store.postWorkspaceChatMessage(
      workspaceId: workspaceId,
      role: role,
      actor: actor,
      content: content,
      agentName: agentName,
      taskId: taskId,
      metadata: metadata,
    );
    await _refresh();
    return message;
  }

  Future<List<TaskWorkspaceChatMessage>> listWorkspaceChatMessages({
    required String workspaceId,
  }) {
    return store.listWorkspaceChatMessages(workspaceId: workspaceId);
  }

  Future<TaskCenterTask> moveTask({
    required String workspaceId,
    required String taskId,
    required TaskCenterStatus status,
    required int index,
  }) async {
    final task = await store.moveTask(
      workspaceId: workspaceId,
      taskId: taskId,
      status: status,
      index: index,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> transferTaskOwner({
    required String workspaceId,
    required String taskId,
    required TaskCenterTaskOwner owner,
    TaskCenterReadiness? readiness,
    String routeReason = '',
    String actor = 'human',
  }) async {
    final task = await store.transferTaskOwner(
      workspaceId: workspaceId,
      taskId: taskId,
      owner: owner,
      readiness: readiness,
      routeReason: routeReason,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> requestHumanConfirmation({
    required String workspaceId,
    required String taskId,
    required List<String> questions,
    String routeReason = '',
    String actor = 'human',
  }) async {
    final task = await store.requestHumanConfirmation(
      workspaceId: workspaceId,
      taskId: taskId,
      questions: questions,
      routeReason: routeReason,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> answerHumanQuestion({
    required String workspaceId,
    required String taskId,
    required String questionId,
    required String answer,
    String actor = 'human',
  }) async {
    final task = await store.answerHumanQuestion(
      workspaceId: workspaceId,
      taskId: taskId,
      questionId: questionId,
      answer: answer,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> claimWorkTask({
    required String workspaceId,
    required String taskId,
    required String agentName,
    String actor = 'human',
  }) async {
    final task = await store.claimWorkTask(
      workspaceId: workspaceId,
      taskId: taskId,
      agentName: agentName,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> startWorkRun({
    required String workspaceId,
    required String taskId,
    required String agentName,
    String sessionId = '',
    String progressSummary = '',
    String actor = 'human',
  }) async {
    final task = await store.startWorkRun(
      workspaceId: workspaceId,
      taskId: taskId,
      agentName: agentName,
      sessionId: sessionId,
      progressSummary: progressSummary,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> heartbeatWorkRun({
    required String workspaceId,
    required String taskId,
    required String runId,
    required TaskCenterWorkRunState state,
    String progressSummary = '',
    int? nextCheckMinutes,
    String actor = 'human',
  }) async {
    final task = await store.heartbeatWorkRun(
      workspaceId: workspaceId,
      taskId: taskId,
      runId: runId,
      state: state,
      progressSummary: progressSummary,
      nextCheckMinutes: nextCheckMinutes,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> bindWorkRunSession({
    required String workspaceId,
    required String taskId,
    required String runId,
    required String sessionId,
    String actor = 'app',
  }) async {
    final task = await store.bindWorkRunSession(
      workspaceId: workspaceId,
      taskId: taskId,
      runId: runId,
      sessionId: sessionId,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> reportWorkBlocker({
    required String workspaceId,
    required String taskId,
    required String runId,
    required TaskCenterWorkBlockerType blockerType,
    required String blockerReason,
    List<String> questions = const <String>[],
    String actor = 'human',
  }) async {
    final task = await store.reportWorkBlocker(
      workspaceId: workspaceId,
      taskId: taskId,
      runId: runId,
      blockerType: blockerType,
      blockerReason: blockerReason,
      questions: questions,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> releaseWorkTask({
    required String workspaceId,
    required String taskId,
    required String runId,
    required String reason,
    String actor = 'human',
  }) async {
    final task = await store.releaseWorkTask(
      workspaceId: workspaceId,
      taskId: taskId,
      runId: runId,
      reason: reason,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<TaskCenterTask> recoverStalledTask({
    required String workspaceId,
    required String taskId,
    required TaskCenterRecoverAction action,
    String agentName = '',
    String reason = '',
    String actor = 'human',
  }) async {
    final task = await store.recoverStalledTask(
      workspaceId: workspaceId,
      taskId: taskId,
      action: action,
      agentName: agentName,
      reason: reason,
      actor: actor,
    );
    await _refresh();
    return task;
  }

  Future<List<TaskCenterTask>> listStalledWork({
    required String workspaceId,
  }) async {
    final tasks = await store.listStalledWork(workspaceId: workspaceId);
    await _refresh();
    return tasks;
  }

  void selectWorkspace(String workspaceId) {
    if (_selectedWorkspaceId == workspaceId) return;
    _selectedWorkspaceId = workspaceId;
    _ensureSelectedWorkspace();
    notifyListeners();
  }

  Future<void> _refresh() async {
    _snapshot = await store.load();
    _loaded = true;
    _ensureSelectedWorkspace();
    notifyListeners();
  }

  void _ensureSelectedWorkspace() {
    if (workspaces.isEmpty) {
      _selectedWorkspaceId = null;
      return;
    }
    final selectedId = _selectedWorkspaceId;
    if (selectedId == null ||
        !workspaces.any((workspace) => workspace.id == selectedId)) {
      _selectedWorkspaceId = workspaces.first.id;
    }
  }
}
