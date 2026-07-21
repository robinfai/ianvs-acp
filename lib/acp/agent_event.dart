import 'acp_input_budget.dart' as acp;

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
    this.omissions = const <acp.AcpInputOmission>[],
  });

  final AgentEventType type;
  final String text;
  final DateTime? timestamp;
  final Map<String, Object?> metadata;
  final List<acp.AcpInputOmission> omissions;
}
