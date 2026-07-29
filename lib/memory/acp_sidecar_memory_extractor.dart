import '../acp/acp_agent_client.dart';
import '../acp/agent_event.dart';
import 'memory_extraction.dart';

export 'memory_extraction.dart' show ExtractedMemoryCandidate;

typedef AcpSidecarClientFactory = AcpAgentClient Function();

class AcpSidecarMemoryExtractor {
  const AcpSidecarMemoryExtractor({required this.clientFactory});

  final AcpSidecarClientFactory clientFactory;

  String buildExtractionPrompt({
    required String userPrompt,
    required String assistantAnswer,
    String globalInstructions = '',
    String workspaceInstructions = '',
    String repoInstructions = '',
  }) {
    return buildMemoryExtractionPrompt(
      userPrompt: userPrompt,
      assistantAnswer: assistantAnswer,
      globalInstructions: globalInstructions,
      workspaceInstructions: workspaceInstructions,
      repoInstructions: repoInstructions,
    );
  }

  Future<List<ExtractedMemoryCandidate>> extract({
    required String userPrompt,
    required String assistantAnswer,
    required String cwd,
    String? model,
    String globalInstructions = '',
    String workspaceInstructions = '',
    String repoInstructions = '',
  }) async {
    final client = clientFactory();
    try {
      await client.connect();
      final session = await client.createSession(cwd: cwd);
      final trimmedModel = model?.trim();
      if (trimmedModel != null && trimmedModel.isNotEmpty) {
        try {
          await client.setConfigOption(
            sessionId: session.id,
            configId: 'model',
            value: trimmedModel,
          );
        } catch (_) {
          // Some ACP agents do not expose model as a config option.
        }
      }
      final buffer = StringBuffer();
      await for (final event in client.sendPrompt(
        sessionId: session.id,
        prompt: buildExtractionPrompt(
          userPrompt: userPrompt,
          assistantAnswer: assistantAnswer,
          globalInstructions: globalInstructions,
          workspaceInstructions: workspaceInstructions,
          repoInstructions: repoInstructions,
        ),
      )) {
        if (event.type == AgentEventType.error) {
          throw StateError(event.text);
        }
        if (event.type == AgentEventType.agentTextDelta ||
            event.type == AgentEventType.agentTextDone) {
          buffer.write(event.text);
        }
      }
      return parseExtractedMemoryCandidates(buffer.toString());
    } finally {
      await client.dispose();
    }
  }
}
