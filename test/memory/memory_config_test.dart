import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/automatic_memory_maintenance.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
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
      expect(config.review.autoOpen, 'high_confidence_auto');
      expect(config.maintenance.enabled, true);
      expect(config.maintenance.mode, 'high_confidence_auto');
      expect(config.maintenance.costMode, 'low_cost');
      expect(config.maintenance.maxItemsPerBatch, 50);
      expect(config.maintenance.manualOnlyActions, [
        'delete',
        'disable',
        'expire',
      ]);
    },
  );

  test(
    'MemoryConfig parses extractor agent, model, and maintenance policy',
    () {
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
        'daemon_base_url': 'http://127.0.0.1:43129',
        'daemon_token_env': 'IANVS_MEMORY_TOKEN',
        'auto_start_daemon': true,
        'maintenance': {
          'enabled': false,
          'mode': 'manual_review',
          'cost_mode': 'low_cost',
          'high_confidence_threshold': 0.92,
          'review_threshold': 0.7,
          'max_items_per_batch': 8,
          'manual_only_actions': ['delete', 'expire'],
        },
      });
      expect(config.extractor.agent, 'Codex');
      expect(config.extractor.model, 'gpt-5-mini');
      expect(config.llm.baseUrl, 'http://127.0.0.1:11434/v1');
      expect(config.llm.apiKeyEnv, 'OLLAMA_API_KEY');
      expect(config.maintenance.enabled, false);
      expect(config.maintenance.mode, 'manual_review');
      expect(config.maintenance.highConfidenceThreshold, 0.92);
      expect(config.maintenance.reviewThreshold, 0.7);
      expect(config.maintenance.maxItemsPerBatch, 8);
      expect(config.maintenance.manualOnlyActions, [
        'delete',
        'disable',
        'expire',
      ]);
      expect(config.toJson()['maintenance'], isA<Map>());
      expect(config.toJson(), isNot(contains('daemon_base_url')));
      expect(config.toJson(), isNot(contains('daemon_token_env')));
      expect(config.toJson(), isNot(contains('auto_start_daemon')));
    },
  );

  test('MemoryMaintenanceConfig upgrades legacy cleanup manual actions', () {
    final config = MemoryConfig.fromJson({
      'maintenance': {
        'manual_only_actions': ['delete'],
      },
    });

    expect(config.maintenance.manualOnlyActions, [
      'delete',
      'disable',
      'expire',
    ]);
  });

  test('MemoryReviewConfig prefers mode and keeps auto_open compatibility', () {
    final config = MemoryConfig.fromJson({
      'review': {
        'mode': 'manual_review',
        'auto_open': 'high_confidence',
        'high_confidence_threshold': 0.91,
      },
    });
    expect(config.review.mode, 'manual_review');
    expect(config.review.autoOpen, 'manual_review');
    expect(config.review.highConfidenceThreshold, 0.91);
    expect(config.toJson()['review'], containsPair('mode', 'manual_review'));
    expect(config.toJson()['review'], isNot(contains('auto_open')));

    final legacyConfig = MemoryConfig.fromJson({
      'review': {'auto_open': 'high_confidence'},
    });
    expect(legacyConfig.review.mode, 'high_confidence');
  });

  test('candidate auto approval threshold follows review mode', () {
    expect(
      candidateAutoApproveThreshold(
        const MemoryReviewConfig(mode: 'manual_review'),
      ),
      isNull,
    );
    expect(
      candidateAutoApproveThreshold(
        const MemoryReviewConfig(
          mode: 'high_confidence_auto',
          highConfidenceThreshold: 0.91,
        ),
      ),
      0.91,
    );
    expect(
      candidateAutoApproveThreshold(const MemoryReviewConfig(mode: 'auto')),
      0.0,
    );
  });

  test('change request auto approval threshold follows maintenance mode', () {
    expect(
      changeRequestAutoApproveThreshold(
        const MemoryMaintenanceConfig(
          mode: 'high_confidence_auto',
          highConfidenceThreshold: 0.92,
        ),
      ),
      0.92,
    );
    expect(
      changeRequestAutoApproveThreshold(
        const MemoryMaintenanceConfig(mode: 'manual_review'),
      ),
      isNull,
    );
    expect(
      changeRequestAutoApproveThreshold(
        const MemoryMaintenanceConfig(enabled: false),
      ),
      isNull,
    );
  });

  test(
    'candidate extraction runs automatic LLM maintenance when configured',
    () {
      const approved = CreateCandidatesResult(
        candidates: <MemoryCandidate>[],
        approvedMemories: [
          MemoryRecord(
            id: 'mem_1',
            kind: 'user_preference',
            scope: 'global',
            text: 'The user goes by Rodriguez.',
            status: 'active',
            createdAt: 1,
            updatedAt: 1,
          ),
        ],
      );

      expect(
        shouldRunMaintenanceAfterCandidateExtraction(
          maintenance: const MemoryMaintenanceConfig(),
          result: approved,
        ),
        isTrue,
      );
      expect(
        shouldRunMaintenanceAfterCandidateExtraction(
          maintenance: const MemoryMaintenanceConfig(mode: 'manual_review'),
          result: approved,
        ),
        isFalse,
      );
      expect(
        shouldRunMaintenanceAfterCandidateExtraction(
          maintenance: const MemoryMaintenanceConfig(enabled: false),
          result: approved,
        ),
        isFalse,
      );
      expect(
        shouldRunMaintenanceAfterCandidateExtraction(
          maintenance: const MemoryMaintenanceConfig(),
          result: CreateCandidatesResult.empty,
        ),
        isFalse,
      );
    },
  );

  test(
    'manual candidate approval runs automatic LLM maintenance when configured',
    () {
      expect(
        shouldRunMaintenanceAfterCandidateApproval(
          maintenance: const MemoryMaintenanceConfig(),
        ),
        isTrue,
      );
      expect(
        shouldRunMaintenanceAfterCandidateApproval(
          maintenance: const MemoryMaintenanceConfig(mode: 'manual_review'),
        ),
        isFalse,
      );
      expect(
        shouldRunMaintenanceAfterCandidateApproval(
          maintenance: const MemoryMaintenanceConfig(enabled: false),
        ),
        isFalse,
      );
    },
  );
}
