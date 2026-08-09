import '../acp/agent_session.dart';
import '../workspace/workspace.dart';
import 'chat_controller.dart';

class WorkspaceController {
  WorkspaceController({
    required List<ChatController> controllers,
    required String currentWorkspacePath,
    this.defaultAgentName,
    this.includeArchived = false,
  }) : _controllers = List.unmodifiable(controllers),
       _currentWorkspacePath = normalizeWorkspacePath(currentWorkspacePath);

  final List<ChatController> _controllers;
  final String _currentWorkspacePath;
  final String? defaultAgentName;
  final bool includeArchived;

  List<WorkspaceRecord> get workspaces {
    final sessionsByPath = <String, Map<String, _WorkspaceSessionBucket>>{};
    final agentsBySource = <String, Set<String>>{};
    for (final controller in _controllers) {
      final agentName = controller.agentName.trim();
      if (agentName.isEmpty) continue;
      agentsBySource
          .putIfAbsent(_catalogSourceKey(controller), () => <String>{})
          .add(agentName);
    }
    for (final controller in _controllers) {
      for (final session in controller.sessions) {
        if (!includeArchived && session.archived) continue;
        final path = normalizeWorkspacePath(session.cwd);
        if (path.isEmpty) continue;
        final sessionId = session.id.trim();
        if (sessionId.isEmpty) continue;
        final effectiveSourceKey = _catalogSourceKey(controller);
        final sessionKey = '$effectiveSourceKey\u0000$sessionId';
        final normalizedSession = session.copyWith(cwd: path);
        sessionsByPath
            .putIfAbsent(path, () => <String, _WorkspaceSessionBucket>{})
            .putIfAbsent(
              sessionKey,
              () => _WorkspaceSessionBucket(
                defaultAgentName: defaultAgentName,
                catalogAgentNames:
                    agentsBySource[effectiveSourceKey] ?? const {},
              ),
            )
            .add(
              normalizedSession,
              sourceAgentName: controller.agentName,
              active: _isControllerCurrentSession(
                controller,
                normalizedSession,
              ),
            );
      }
    }

    sessionsByPath.putIfAbsent(
      _currentWorkspacePath,
      () => <String, _WorkspaceSessionBucket>{},
    );

    final records = sessionsByPath.entries.map((entry) {
      final sessions =
          entry.value.values.map((bucket) => bucket.resolvedSession()).toList()
            ..sort((a, b) {
              if (a.pinned && !b.pinned) return -1;
              if (b.pinned && !a.pinned) return 1;
              return b.displayTime.compareTo(a.displayTime);
            });
      return WorkspaceRecord(
        path: entry.key,
        name: workspaceNameFromPath(entry.key),
        sessions: List.unmodifiable(sessions),
        defaultAgentName: defaultAgentName,
      );
    }).toList();

    records.sort((a, b) {
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

  String _catalogSourceKey(ChatController controller) {
    final sourceKey = controller.sessionCatalogSourceKey?.trim();
    return sourceKey == null || sourceKey.isEmpty
        ? 'agent:${controller.agentName.trim()}'
        : sourceKey;
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

  bool _isControllerCurrentSession(
    ChatController controller,
    AgentSession session,
  ) {
    final current = controller.currentSession;
    if (current == null || current.id != session.id) return false;
    return normalizeWorkspacePath(current.cwd) == session.cwd;
  }
}

class _WorkspaceSessionBucket {
  _WorkspaceSessionBucket({
    required this.defaultAgentName,
    required Set<String> catalogAgentNames,
  }) : catalogAgentNames = Set<String>.unmodifiable(catalogAgentNames);

  final String? defaultAgentName;
  final Set<String> catalogAgentNames;
  final List<_WorkspaceSessionCandidate> _candidates =
      <_WorkspaceSessionCandidate>[];

  void add(
    AgentSession session, {
    required String sourceAgentName,
    required bool active,
  }) {
    _candidates.add(
      _WorkspaceSessionCandidate(
        session: session,
        sourceAgentName: _trimmedOrNull(sourceAgentName),
        active: active,
      ),
    );
  }

  AgentSession resolvedSession() {
    final agentName = _resolvedAgentName();
    final base = _baseSession(agentName);
    if (agentName == null || _trimmedOrNull(base.agentName) == agentName) {
      return base;
    }
    return base.copyWith(agentName: agentName);
  }

  AgentSession _baseSession(String? resolvedAgentName) {
    _WorkspaceSessionCandidate? best;
    for (final candidate in _candidates) {
      if (best == null ||
          _candidateRank(candidate, resolvedAgentName) >
              _candidateRank(best, resolvedAgentName)) {
        best = candidate;
      }
    }

    final selected = best ?? _candidates.first;
    return _candidates.fold<AgentSession>(
      selected.session,
      (session, candidate) => _mergeSession(session, candidate.session),
    );
  }

  int _candidateRank(
    _WorkspaceSessionCandidate candidate,
    String? resolvedAgentName,
  ) {
    var rank = 0;
    if (candidate.active) rank += 100;
    final agentName = _trimmedOrNull(candidate.session.agentName);
    if (agentName != null) rank += 20;
    if (resolvedAgentName != null && agentName == resolvedAgentName) {
      rank += 10;
    }
    if (candidate.session.updatedAt != null) rank += 1;
    return rank;
  }

  AgentSession _mergeSession(AgentSession selected, AgentSession candidate) {
    final metadata = candidate.displayTime.isAfter(selected.displayTime)
        ? candidate
        : selected;
    return AgentSession(
      id: selected.id,
      cwd: selected.cwd.trim().isEmpty ? candidate.cwd : selected.cwd,
      createdAt: selected.createdAt.isBefore(candidate.createdAt)
          ? selected.createdAt
          : candidate.createdAt,
      additionalDirectories: selected.additionalDirectories.isEmpty
          ? candidate.additionalDirectories
          : selected.additionalDirectories,
      title: metadata.title ?? selected.title ?? candidate.title,
      titleOverride: selected.titleOverride ?? candidate.titleOverride,
      updatedAt: _latestDateTime(selected.updatedAt, candidate.updatedAt),
      agentName: selected.agentName,
      initialEvents: selected.initialEvents.isEmpty
          ? candidate.initialEvents
          : selected.initialEvents,
      pinned: selected.pinned || candidate.pinned,
      archived: selected.archived || candidate.archived,
      unread: selected.unread || candidate.unread,
      localUnstarted: selected.localUnstarted && candidate.localUnstarted,
    );
  }

  DateTime? _latestDateTime(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String? _resolvedAgentName() {
    final activeAgentNames = <String>{};
    final explicitAgentNames = <String>{};
    final sourceAgentNames = <String>{};

    for (final candidate in _candidates) {
      final sessionAgentName = _trimmedOrNull(candidate.session.agentName);
      if (sessionAgentName != null) {
        explicitAgentNames.add(sessionAgentName);
        if (candidate.active) activeAgentNames.add(sessionAgentName);
      } else if (candidate.active && candidate.sourceAgentName != null) {
        activeAgentNames.add(candidate.sourceAgentName!);
      }
      if (candidate.sourceAgentName != null) {
        sourceAgentNames.add(candidate.sourceAgentName!);
      }
    }

    if (activeAgentNames.length == 1) return activeAgentNames.single;
    if (explicitAgentNames.length == 1) return explicitAgentNames.single;
    if (sourceAgentNames.length == 1) return sourceAgentNames.single;
    final fallback = _trimmedOrNull(defaultAgentName);
    if (fallback != null &&
        (explicitAgentNames.contains(fallback) ||
            sourceAgentNames.contains(fallback) ||
            catalogAgentNames.contains(fallback))) {
      return fallback;
    }
    if (explicitAgentNames.isNotEmpty) {
      final sorted = explicitAgentNames.toList()..sort();
      return sorted.first;
    }
    if (sourceAgentNames.isNotEmpty) {
      final sorted = sourceAgentNames.toList()..sort();
      return sorted.first;
    }
    return fallback;
  }

  String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

class _WorkspaceSessionCandidate {
  const _WorkspaceSessionCandidate({
    required this.session,
    required this.sourceAgentName,
    required this.active,
  });

  final AgentSession session;
  final String? sourceAgentName;
  final bool active;
}
