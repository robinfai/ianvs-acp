class AgentSession {
  const AgentSession({
    required this.id,
    required this.cwd,
    required this.createdAt,
    this.title,
    this.updatedAt,
  });

  final String id;
  final String cwd;
  final DateTime createdAt;
  final String? title;
  final DateTime? updatedAt;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);

  String get displayTitle {
    final trimmed = title?.trim();
    return trimmed == null || trimmed.isEmpty ? shortId : trimmed;
  }

  DateTime get displayTime => updatedAt ?? createdAt;

  AgentSession copyWith({String? title, DateTime? updatedAt}) {
    return AgentSession(
      id: id,
      cwd: cwd,
      createdAt: createdAt,
      title: title ?? this.title,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
