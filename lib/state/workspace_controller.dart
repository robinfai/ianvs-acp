import '../acp/agent_session.dart';
import '../workspace/workspace.dart';
import 'chat_controller.dart';

class WorkspaceController {
  WorkspaceController({
    required List<ChatController> controllers,
    required String currentWorkspacePath,
    this.defaultAgentName,
  }) : _controllers = List.unmodifiable(controllers),
       _currentWorkspacePath = normalizeWorkspacePath(currentWorkspacePath);

  final List<ChatController> _controllers;
  final String _currentWorkspacePath;
  final String? defaultAgentName;

  List<WorkspaceRecord> get workspaces {
    final sessionsByPath = <String, List<AgentSession>>{};
    for (final controller in _controllers) {
      for (final session in controller.sessions) {
        final path = normalizeWorkspacePath(session.cwd);
        if (path.isEmpty) continue;
        sessionsByPath.putIfAbsent(path, () => <AgentSession>[]).add(session);
      }
    }

    sessionsByPath.putIfAbsent(_currentWorkspacePath, () => <AgentSession>[]);

    final records = sessionsByPath.entries.map((entry) {
      final sessions = List<AgentSession>.from(entry.value)
        ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
      return WorkspaceRecord(
        path: entry.key,
        name: workspaceNameFromPath(entry.key),
        sessions: List.unmodifiable(sessions),
        defaultAgentName: defaultAgentName,
      );
    }).toList();

    records.sort((a, b) {
      final aCurrent = a.path == _currentWorkspacePath;
      final bCurrent = b.path == _currentWorkspacePath;
      if (aCurrent && !bCurrent) return -1;
      if (bCurrent && !aCurrent) return 1;

      final aTime = a.lastActivityAt;
      final bTime = b.lastActivityAt;
      if (aTime != null && bTime != null) {
        final byTime = bTime.compareTo(aTime);
        if (byTime != 0) return byTime;
      } else if (aTime != null) {
        return -1;
      } else if (bTime != null) {
        return 1;
      }
      return a.name.compareTo(b.name);
    });

    return List.unmodifiable(records);
  }

  WorkspaceRecord get currentWorkspace {
    for (final workspace in workspaces) {
      if (workspace.path == _currentWorkspacePath) return workspace;
    }
    return WorkspaceRecord(
      path: _currentWorkspacePath,
      name: workspaceNameFromPath(_currentWorkspacePath),
      sessions: const <AgentSession>[],
      defaultAgentName: defaultAgentName,
    );
  }
}
