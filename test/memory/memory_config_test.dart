import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_config.dart';

void main() {
  test(
    'MemoryConfig defaults to enabled local memory with ACP sidecar extractor',
    () {
      const config = MemoryConfig();
      expect(config.enabled, true);
      expect(config.autoStartDaemon, true);
      expect(config.embedding.provider, 'fastembed-local');
      expect(config.embedding.model, 'intfloat/multilingual-e5-small');
      expect(config.embedding.dimension, 384);
      expect(config.extractor.provider, 'acp-sidecar');
      expect(config.extractor.fallbackProvider, 'rules');
      expect(config.review.autoOpen, 'high_confidence');
    },
  );

  test('MemoryConfig parses extractor agent and model', () {
    final config = MemoryConfig.fromJson({
      'extractor': {
        'provider': 'acp-sidecar',
        'agent': 'Codex',
        'model': 'gpt-5-mini',
      },
      'llm': {
        'base_url': 'http://127.0.0.1:11434/v1',
        'model': 'qwen2.5:7b',
        'api_key_env': 'OLLAMA_API_KEY',
      },
    });
    expect(config.extractor.agent, 'Codex');
    expect(config.extractor.model, 'gpt-5-mini');
    expect(config.llm.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(config.llm.apiKeyEnv, 'OLLAMA_API_KEY');
  });
}
