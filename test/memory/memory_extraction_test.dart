import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_extraction.dart';

void main() {
  test('rule extractor captures explicit preferred name memory', () {
    final candidates = extractRuleBasedMemoryCandidates(
      userPrompt: '记住我是 Rodriguez',
      assistantAnswer: '已记住。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, '用户称呼是 Rodriguez。');
    expect(candidates.single.confidence, 0.93);
  });

  test('rule extractor captures explicit project conventions', () {
    final candidates = extractRuleBasedMemoryCandidates(
      userPrompt: '请记住：本项目使用 Riverpod 管理状态。',
      assistantAnswer: '收到。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'project_rule');
    expect(candidates.single.scope, 'repo');
    expect(candidates.single.text, '本项目使用 Riverpod 管理状态。');
  });

  test('rule extractor skips AGENTS and tool-use constraints', () {
    final candidates = extractRuleBasedMemoryCandidates(
      userPrompt: '请记住：AGENTS.md 约束：中文回复，严禁使用 nc 或 netcat。',
      assistantAnswer: '收到。',
    );

    expect(candidates, isEmpty);
  });

  test(
    'rule extractor skips likely secrets even when explicitly requested',
    () {
      final candidates = extractRuleBasedMemoryCandidates(
        userPrompt: '请记住我的 API key 是 sk-test-123',
        assistantAnswer: '收到。',
      );

      expect(candidates, isEmpty);
    },
  );

  test(
    'merge candidates keeps primary results and appends unique rule results',
    () {
      final merged = mergeExtractedMemoryCandidates(
        const [
          ExtractedMemoryCandidate(
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.90,
          ),
        ],
        const [
          ExtractedMemoryCandidate(
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            confidence: 0.93,
          ),
          ExtractedMemoryCandidate(
            kind: 'project_rule',
            scope: 'repo',
            text: '本项目使用 Riverpod 管理状态。',
            confidence: 0.93,
          ),
        ],
      );

      expect(merged, hasLength(2));
      expect(merged.first.confidence, 0.90);
      expect(merged.last.text, '本项目使用 Riverpod 管理状态。');
    },
  );
}
