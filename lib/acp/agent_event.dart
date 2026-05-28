enum AgentEventType {
  userMessage,
  agentTextDelta,
  agentTextDone,
  toolCall,
  error,
  status,
}

class AgentEvent {
  const AgentEvent({required this.type, required this.text, this.timestamp});

  final AgentEventType type;
  final String text;
  final DateTime? timestamp;
}
