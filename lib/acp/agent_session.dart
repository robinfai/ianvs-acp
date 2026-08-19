import 'agent_event.dart';

class AgentSession {
  const AgentSession({
    required this.id,
    required this.cwd,
    required this.createdAt,
    this.additionalDirectories = const <String>[],
    this.title,
    this.titleOverride,
    this.updatedAt,
    this.agentName,
    this.sessionTemplateId,
    this.sessionTemplateVersion,
    this.initialEvents = const <AgentEvent>[],
    this.pinned = false,
    this.archived = false,
    this.unread = false,
    this.localUnstarted = false,
  });

  final String id;
  final String cwd;
  final DateTime createdAt;
  final List<String> additionalDirectories;
  final String? title;
  final String? titleOverride;
  final DateTime? updatedAt;
  final String? agentName;
  final String? sessionTemplateId;
  final int? sessionTemplateVersion;
  final List<AgentEvent> initialEvents;
  final bool pinned;
  final bool archived;
  final bool unread;
  final bool localUnstarted;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  String get displayTitle {
    final override = titleOverride?.trim();
    if (override != null && override.isNotEmpty) return override;
    final trimmed = title?.trim();
    return trimmed == null || trimmed.isEmpty ? shortId : trimmed;
  }

  DateTime get displayTime => updatedAt ?? createdAt;

  AgentSession copyWith({
    String? cwd,
    String? title,
    String? titleOverride,
    DateTime? updatedAt,
    String? agentName,
    String? sessionTemplateId,
    int? sessionTemplateVersion,
    List<String>? additionalDirectories,
    List<AgentEvent>? initialEvents,
    bool? pinned,
    bool? archived,
    bool? unread,
    bool? localUnstarted,
  }) {
    return AgentSession(
      id: id,
      cwd: cwd ?? this.cwd,
      createdAt: createdAt,
      additionalDirectories:
          additionalDirectories ?? this.additionalDirectories,
      title: title ?? this.title,
      titleOverride: titleOverride ?? this.titleOverride,
      updatedAt: updatedAt ?? this.updatedAt,
      agentName: agentName ?? this.agentName,
      sessionTemplateId: sessionTemplateId ?? this.sessionTemplateId,
      sessionTemplateVersion:
          sessionTemplateVersion ?? this.sessionTemplateVersion,
      initialEvents: initialEvents ?? this.initialEvents,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      unread: unread ?? this.unread,
      localUnstarted: localUnstarted ?? this.localUnstarted,
    );
  }
}

bool sameSessionWorkspaceIdentity(AgentSession left, AgentSession right) {
  return sessionWorkspaceIdentityMatches(
    left,
    sessionId: right.id,
    cwd: right.cwd,
    additionalDirectories: right.additionalDirectories,
  );
}

bool sessionWorkspaceIdentityMatches(
  AgentSession session, {
  required String sessionId,
  required String cwd,
  required Iterable<String> additionalDirectories,
}) {
  if (session.id.trim() != sessionId.trim() ||
      session.cwd.trim() != cwd.trim()) {
    return false;
  }
  final existingDirectories = _normalizedWorkspaceDirectories(
    session.additionalDirectories,
  );
  final requestedDirectories = _normalizedWorkspaceDirectories(
    additionalDirectories,
  );
  return existingDirectories.length == requestedDirectories.length &&
      existingDirectories.containsAll(requestedDirectories);
}

String sessionWorkspaceConflictMessage(String sessionId) {
  return 'Session ${sessionId.trim()} is already bound to a different workspace.';
}

Set<String> _normalizedWorkspaceDirectories(Iterable<String> directories) {
  return {
    for (final directory in directories)
      if (directory.trim().isNotEmpty) directory.trim(),
  };
}
