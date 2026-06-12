import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/memory/acp_sidecar_memory_extractor.dart';

void main() {
  test('sidecar extractor asks isolated agent for JSON candidates', () async {
    final fake = FakeAgentClient();
    final extractor = AcpSidecarMemoryExtractor(clientFactory: () => fake);
    final prompt = extractor.buildExtractionPrompt(
      userPrompt: '本项目使用 Riverpod 管理状态。',
      assistantAnswer: '记住了。',
    );

    expect(prompt, contains('Return JSON only'));
    expect(prompt, contains('project_rule'));
    expect(prompt, contains('本项目使用 Riverpod 管理状态。'));
  });

  test('sidecar extractor runs agent and parses JSON candidates', () async {
    final fake = _JsonExtractionAgentClient();
    final extractor = AcpSidecarMemoryExtractor(clientFactory: () => fake);

    final candidates = await extractor.extract(
      userPrompt: '本项目使用 Riverpod 管理状态。',
      assistantAnswer: '记住了。',
      cwd: '/workspace',
      model: 'gpt-5-mini',
    );

    expect(fake.didConnect, isTrue);
    expect(fake.connected, isFalse);
    expect(fake.sessionCount, 1);
    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'gpt-5-mini');
    expect(fake.lastPrompt, contains('本项目使用 Riverpod 管理状态。'));
    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'project_rule');
    expect(candidates.single.scope, 'repo');
    expect(candidates.single.text, 'The project uses Riverpod.');
    expect(candidates.single.confidence, 0.91);
  });
}

class _JsonExtractionAgentClient extends FakeAgentClient {
  bool didConnect = false;

  @override
  Future<void> connect() async {
    await super.connect();
    didConnect = true;
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    String? memoryContext,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    lastPrompt = prompt;
    yield const AgentEvent(
      type: AgentEventType.agentTextDelta,
      text:
          '{"candidates":[{"kind":"project_rule","scope":"repo","text":"The project uses Riverpod.","confidence":0.91,"reason":"Durable repo convention."}]}',
    );
    yield const AgentEvent(type: AgentEventType.agentTextDone, text: '');
  }
}
