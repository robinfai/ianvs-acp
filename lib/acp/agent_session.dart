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
    this.initialEvents = const <AgentEvent>[],
    this.pinned = false,
    this.archived = false,
    this.unread = false,
  });

  final String id;
  final String cwd;
  final DateTime createdAt;
  final List<String> additionalDirectories;
  final String? title;
  final String? titleOverride;
  final DateTime? updatedAt;
  final String? agentName;
  final List<AgentEvent> initialEvents;
  final bool pinned;
  final bool archived;
  final bool unread;

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
    List<String>? additionalDirectories,
    List<AgentEvent>? initialEvents,
    bool? pinned,
    bool? archived,
    bool? unread,
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
      initialEvents: initialEvents ?? this.initialEvents,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      unread: unread ?? this.unread,
    );
  }
}
