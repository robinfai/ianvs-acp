class AgentSession {
  const AgentSession({
    required this.id,
    required this.cwd,
    required this.createdAt,
  });

  final String id;
  final String cwd;
  final DateTime createdAt;

  String get shortId => id.length <= 8 ? id : id.substring(0, 8);
}
