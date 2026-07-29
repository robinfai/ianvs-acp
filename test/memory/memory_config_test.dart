import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_config.dart';

void main() {
  test(
    'MemoryConfig defaults to disabled local memory with ACP sidecar extractor',
    () {
      const config = MemoryConfig();
      expect(config.enabled, false);
      expect(config.embedding.provider, 'fastembed-local');
      expect(config.embedding.model, 'intfloat/multilingual-e5-small');
      expect(config.embedding.dimension, 384);
      expect(config.extractor.provider, 'acp-sidecar');
      expect(config.extractor.fallbackProvider, 'rules');
      expect(config.review.approvalMode, 'auto_high_confidence');
      expect(config.review.autoOpen, 'high_confidence');
      expect(config.profile.maxItems, 4);
      expect(config.maintenance.enabled, true);
      expect(config.maintenance.mode, 'high_confidence_auto');
      expect(config.maintenance.costMode, 'low_cost');
      expect(config.maintenance.runAfterExtraction, true);
      expect(config.maintenance.idleEnabled, true);
      expect(config.maintenance.idleAfterTurns, 6);
      expect(config.maintenance.idleMaxPendingReviews, 0);
      expect(config.maintenance.maxItemsPerBatch, 12);
      expect(config.maintenance.manualOnlyActions, ['delete']);
    },
  );

  test('MemoryConfig parses extractor, model, and maintenance settings', () {
    final config = MemoryConfig.fromJson({
      'extractor': {
        'provider': 'acp-sidecar',
        'agent': 'Codex',
        'model': 'gpt-5-mini',
        'global_instructions': 'Remember durable user preferences only.',
        'workspace_instructions': 'Ignore one-off workspace chatter.',
        'repo_instructions': 'In this repo, prioritize project rules.',
      },
      'llm': {
        'base_url': 'http://127.0.0.1:11434/v1',
        'model': 'qwen2.5:7b',
        'api_key_env': 'OLLAMA_API_KEY',
      },
      'review': {
        'approval_mode': 'auto_high_confidence',
        'high_confidence_threshold': 0.9,
      },
      'maintenance': {
        'enabled': true,
        'mode': 'manual_review',
        'cost_mode': 'low_cost',
        'high_confidence_threshold': 0.91,
        'review_threshold': 0.77,
        'run_after_extraction': false,
        'idle_enabled': true,
        'idle_after_turns': 4,
        'idle_max_pending_reviews': 2,
        'max_items_per_batch': 8,
        'manual_only_actions': ['delete', 'expire'],
      },
      'profile': {'max_items': 2},
      'daemon_base_url': 'http://127.0.0.1:43129',
      'daemon_token_env': 'IANVS_MEMORY_TOKEN',
      'auto_start_daemon': true,
    });
    expect(config.extractor.agent, 'Codex');
    expect(config.extractor.model, 'gpt-5-mini');
    expect(
      config.extractor.globalInstructions,
      'Remember durable user preferences only.',
    );
    expect(
      config.extractor.workspaceInstructions,
      'Ignore one-off workspace chatter.',
    );
    expect(
      config.extractor.repoInstructions,
      'In this repo, prioritize project rules.',
    );
    expect(config.llm.baseUrl, 'http://127.0.0.1:11434/v1');
    expect(config.llm.apiKeyEnv, 'OLLAMA_API_KEY');
    expect(config.review.approvalMode, 'auto_high_confidence');
    expect(config.review.highConfidenceThreshold, 0.9);
    expect(config.profile.maxItems, 2);
    expect(config.maintenance.mode, 'manual_review');
    expect(config.maintenance.highConfidenceThreshold, 0.91);
    expect(config.maintenance.reviewThreshold, 0.77);
    expect(config.maintenance.runAfterExtraction, false);
    expect(config.maintenance.idleEnabled, true);
    expect(config.maintenance.idleAfterTurns, 4);
    expect(config.maintenance.idleMaxPendingReviews, 2);
    expect(config.maintenance.maxItemsPerBatch, 8);
    expect(config.maintenance.manualOnlyActions, ['delete', 'expire']);
    expect(
      (config.toJson()['extractor']
          as Map<String, Object?>)['repo_instructions'],
      'In this repo, prioritize project rules.',
    );
    expect(config.toJson()['maintenance'], isA<Map<String, Object?>>());
    final maintenanceJson = config.toJson()['maintenance'] as Map;
    expect(maintenanceJson['idle_enabled'], true);
    expect(maintenanceJson['idle_after_turns'], 4);
    expect(maintenanceJson['idle_max_pending_reviews'], 2);
    expect((config.toJson()['profile'] as Map)['max_items'], 2);
    expect(config.toJson(), isNot(contains('daemon_base_url')));
    expect(config.toJson(), isNot(contains('daemon_token_env')));
    expect(config.toJson(), isNot(contains('auto_start_daemon')));
  });

  test('MemoryConfig normalizes review and maintenance modes from config', () {
    final config = MemoryConfig.fromJson({
      'review': {
        'approval_mode': ' Auto-High-Confidence ',
        'auto_open': ' Never ',
      },
      'maintenance': {
        'mode': ' Manual-Review ',
        'manual_only_actions': [' Delete ', ' EXPIRE ', ''],
      },
    });

    expect(config.review.approvalMode, MemoryApprovalMode.autoHighConfidence);
    expect(config.review.autoOpen, MemoryReviewAutoOpen.never);
    expect(config.maintenance.mode, 'manual_review');
    expect(config.maintenance.manualOnlyActions, ['delete', 'expire']);
  });

  test('MemoryConfig falls back to automatic review when mode is unknown', () {
    final config = MemoryConfig.fromJson({
      'review': {'approval_mode': 'ask-me-later'},
      'maintenance': {'mode': 'surprise-me'},
    });

    expect(config.review.approvalMode, MemoryApprovalMode.autoHighConfidence);
    expect(config.maintenance.mode, 'high_confidence_auto');
  });
}
