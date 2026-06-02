import 'agent_event.dart';

class AgentSession {
  const AgentSession({
    required this.id,
    required this.cwd,
    required this.createdAt,
    this.additionalDirectories = const <String>[],
    this.title,
    this.updatedAt,
    this.agentName,
    this.initialEvents = const <AgentEvent>[],
  });

  final String id;
  final String cwd;
  final DateTime createdAt;
  final List<String> additionalDirectories;
  final String? title;
  final DateTime? updatedAt;
  final String? agentName;
  final List<AgentEvent> initialEvents;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  String get displayTitle {
    final trimmed = title?.trim();
    return trimmed == null || trimmed.isEmpty ? shortId : trimmed;
  }

  DateTime get displayTime => updatedAt ?? createdAt;

  AgentSession copyWith({
    String? title,
    DateTime? updatedAt,
    String? agentName,
    List<String>? additionalDirectories,
    List<AgentEvent>? initialEvents,
  }) {
    return AgentSession(
      id: id,
      cwd: cwd,
      createdAt: createdAt,
      additionalDirectories:
          additionalDirectories ?? this.additionalDirectories,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
      agentName: agentName ?? this.agentName,
      initialEvents: initialEvents ?? this.initialEvents,
    );
  }
}
