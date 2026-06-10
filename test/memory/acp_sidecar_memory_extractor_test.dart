import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/memory/acp_sidecar_memory_extractor.dart';

void main() {
  test('sidecar extractor asks isolated agent for JSON candidates', () async {
    final fake = FakeAgentClient();
    final extractor = AcpSidecarMemoryExtractor(clientFactory: () => fake);
    final prompt = extractor.buildExtractionPrompt(
      userPrompt: '本项目严禁使用 nc。',
      assistantAnswer: '记住了。',
    );

    expect(prompt, contains('Return JSON only'));
    expect(prompt, contains('project_rule'));
    expect(prompt, contains('本项目严禁使用 nc。'));
  });
}
