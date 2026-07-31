import 'dart:io';

import '../acp/agent_session.dart';

class WorkspaceRecord {
  const WorkspaceRecord({
    required this.path,
    required this.name,
    required this.sessions,
    this.pinned = false,
    this.defaultAgentName,
  });

  final String path;
  final String name;
  final List<AgentSession> sessions;
  final bool pinned;
  final String? defaultAgentName;

  DateTime? get lastActivityAt {
    DateTime? latest;
    for (final session in sessions) {
      final time = session.displayTime;
      if (latest == null || time.isAfter(latest)) latest = time;
    }
    return latest;
  }

  int get sessionCount => sessions.length;

  List<String> get agentNames {
    final names = <String>{};
    for (final session in sessions) {
      final agentName = session.agentName?.trim();
      if (agentName != null && agentName.isNotEmpty) {
        names.add(agentName);
      }
    }
    final sorted = names.toList()..sort();
    return sorted;
  }

  Map<String, List<AgentSession>> sessionsByAgent({String? preferredAgent}) {
    final grouped = <String, List<AgentSession>>{};
    for (final session in sessions) {
      final agentName = session.agentName?.trim();
      final key = agentName == null || agentName.isEmpty
          ? 'Unknown Agent'
          : agentName;
      grouped.putIfAbsent(key, () => <AgentSession>[]).add(session);
    }

    for (final group in grouped.values) {
      group.sort((a, b) {
        if (a.pinned && !b.pinned) return -1;
        if (b.pinned && !a.pinned) return 1;
        return b.displayTime.compareTo(a.displayTime);
      });
    }

    final orderedKeys = grouped.keys.toList()
      ..sort((a, b) {
        final preferred = preferredAgent?.trim();
        if (preferred != null && preferred.isNotEmpty) {
          if (a == preferred && b != preferred) return -1;
          if (b == preferred && a != preferred) return 1;
        }
        return a.compareTo(b);
      });

    return <String, List<AgentSession>>{
      for (final key in orderedKeys) key: grouped[key]!,
    };
  }
}

String normalizeWorkspacePath(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return trimmed;
  var normalized = trimmed.replaceAll(RegExp(r'/+$'), '');
  if (normalized.isEmpty && trimmed.startsWith('/')) normalized = '/';
  return normalized;
}

String workspaceNameFromPath(String path) {
  final normalized = normalizeWorkspacePath(path);
  if (normalized.isEmpty) return 'Workspace';
  if (normalized == '/') return '/';
  final parts = normalized
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) return normalized;
  return parts.last;
}

bool workspaceSupportsGitWorktrees(String path) {
  var directory = Directory(normalizeWorkspacePath(path));
  if (directory.path.trim().isEmpty) return false;
  if (!directory.existsSync()) return false;
  while (true) {
    final marker = '${directory.path}${Platform.pathSeparator}.git';
    final type = FileSystemEntity.typeSync(marker, followLinks: false);
    if (type == FileSystemEntityType.directory ||
        type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      return true;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) return false;
    directory = parent;
  }
}
