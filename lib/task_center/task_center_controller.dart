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
    TaskWorkspaceAgentConfig agentConfig = const TaskWorkspaceAgentConfig(),
  }) async {
    final workspace = await store.createWorkspace(
      title: title,
      description: description,
      agentConfig: agentConfig,
    );
    _selectedWorkspaceId = workspace.id;
    await _refresh();
    return workspace;
  }

  Future<TaskWorkspace> updateWorkspaceAgentConfig({
    required String workspaceId,
    required TaskWorkspaceAgentConfig agentConfig,
  }) async {
    final workspace = await store.updateWorkspaceAgentConfig(
      workspaceId: workspaceId,
      agentConfig: agentConfig,
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
