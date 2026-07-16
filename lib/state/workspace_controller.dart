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
    final sessionsByPath =
        <String, Map<ChatController, Map<String, _WorkspaceSessionBucket>>>{};
    for (final controller in _controllers) {
      for (final session in controller.sessions) {
        if (session.archived) continue;
        final path = normalizeWorkspacePath(session.cwd);
        if (path.isEmpty) continue;
        final sessionId = session.id.trim();
        if (sessionId.isEmpty) continue;
        final normalizedSession = session.copyWith(cwd: path);
        sessionsByPath
            .putIfAbsent(
              path,
              () =>
                  Map<
                    ChatController,
                    Map<String, _WorkspaceSessionBucket>
                  >.identity(),
            )
            .putIfAbsent(controller, () => <String, _WorkspaceSessionBucket>{})
            .putIfAbsent(
              sessionId,
              () => _WorkspaceSessionBucket(
                defaultAgentName: defaultAgentName,
                controllerAgentName: controller.agentName,
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
      () =>
          Map<ChatController, Map<String, _WorkspaceSessionBucket>>.identity(),
    );

    final records = sessionsByPath.entries.map((entry) {
      final sessions =
          entry.value.values
              .expand((sessionsById) => sessionsById.values)
              .map((bucket) => bucket.resolvedSession())
              .toList()
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
    required this.controllerAgentName,
  });

  final String? defaultAgentName;
  final String controllerAgentName;
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
      archived: false,
      unread: selected.unread || candidate.unread,
    );
  }

  DateTime? _latestDateTime(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  String? _resolvedAgentName() {
    final trustedControllerAgentName = _trimmedOrNull(controllerAgentName);
    if (trustedControllerAgentName != null) return trustedControllerAgentName;

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
    if (explicitAgentNames.length > 1) return _fallbackAgentName();
    if (sourceAgentNames.length == 1) return sourceAgentNames.single;
    return _fallbackAgentName();
  }

  String? _fallbackAgentName() => _trimmedOrNull(defaultAgentName);

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
