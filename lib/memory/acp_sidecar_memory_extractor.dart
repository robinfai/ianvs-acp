import '../acp/acp_agent_client.dart';

typedef AcpSidecarClientFactory = AcpAgentClient Function();

class AcpSidecarMemoryExtractor {
  const AcpSidecarMemoryExtractor({required this.clientFactory});

  final AcpSidecarClientFactory clientFactory;

  String buildExtractionPrompt({
    required String userPrompt,
    required String assistantAnswer,
  }) {
    return '''
You are a memory extraction engine for a local AI agent client.
Extract only durable, useful memories from the current turn.
Allowed memory kinds:
1. user_preference
2. project_rule
3. architecture_decision
4. session_summary
Do not extract secrets, temporary one-off instructions, unverified assumptions, long code snippets, or error logs.
Return JSON only.
Schema:
{"candidates":[{"kind":"user_preference | project_rule | architecture_decision | session_summary","scope":"global | workspace | repo | session","text":"Clear, concise memory text.","confidence":0.0,"reason":"Short reason why this is durable and useful."}]}

User prompt:
$userPrompt

Assistant answer:
$assistantAnswer
''';
  }
}
