enum AgentEventType {
  userMessage,
  agentTextDelta,
  agentTextDone,
  toolCall,
  error,
  status,
}

class AgentEvent {
  const AgentEvent({
    required this.type,
    required this.text,
    this.timestamp,
    this.metadata = const <String, Object?>{},
  });

  final AgentEventType type;
  final String text;
  final DateTime? timestamp;
  final Map<String, Object?> metadata;
}
