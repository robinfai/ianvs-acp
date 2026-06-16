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
  }) async {
    final workspace = await store.createWorkspace(
      title: title,
      description: description,
    );
    _selectedWorkspaceId = workspace.id;
    await _refresh();
    return workspace;
  }

  Future<TaskCenterTask> createTask({
    required String workspaceId,
    required String title,
    String description = '',
    TaskCenterStatus status = TaskCenterStatus.todo,
  }) async {
    final task = await store.createTask(
      workspaceId: workspaceId,
      title: title,
      description: description,
      status: status,
    );
    await _refresh();
    return task;
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
