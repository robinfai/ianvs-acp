import '../workspace/workspace.dart';

class WorkspaceExecutionGate {
  final Map<String, String> _locksByWorkspacePath = <String, String>{};

  bool tryAcquire(String workspacePath, String taskId) {
    final key = _workspaceKey(workspacePath);
    final owner = taskId.trim();
    if (key.isEmpty || owner.isEmpty) return false;
    final currentOwner = _locksByWorkspacePath[key];
    if (currentOwner != null && currentOwner != owner) return false;
    _locksByWorkspacePath[key] = owner;
    return true;
  }

  void release(String workspacePath, String taskId) {
    final key = _workspaceKey(workspacePath);
    if (_locksByWorkspacePath[key] == taskId.trim()) {
      _locksByWorkspacePath.remove(key);
    }
  }

  bool isLocked(String workspacePath) {
    return _locksByWorkspacePath.containsKey(_workspaceKey(workspacePath));
  }

  String? ownerFor(String workspacePath) {
    return _locksByWorkspacePath[_workspaceKey(workspacePath)];
  }

  String _workspaceKey(String workspacePath) {
    return normalizeWorkspacePath(workspacePath);
  }
}
