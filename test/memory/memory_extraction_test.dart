import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_extraction.dart';

void main() {
  test('parses extracted memory entities and tags', () {
    final candidates = parseExtractedMemoryCandidates('''
{
  "candidates": [
    {
      "kind": "user_preference",
      "scope": "global",
      "text": "Use the user's preferred display name in greetings.",
      "confidence": 0.91,
      "instructionScopes": ["global", "repo"],
      "entities": [
        {"text": "Rodriguez", "type": "person"},
        {"text": "display-name", "type": "tag"}
      ]
    }
  ]
}
''');

    expect(candidates, hasLength(1));
    expect(candidates.single.entities, hasLength(2));
    expect(candidates.single.entities.first.text, 'Rodriguez');
    expect(candidates.single.entities.first.type, 'person');
    expect(candidates.single.instructionScopes, ['global', 'repo']);
    expect(candidates.single.toJson()['instructionScopes'], ['global', 'repo']);
  });

  test('normalizes extractor session-scoped candidates before review', () {
    final candidates = parseExtractedMemoryCandidates('''
{
  "candidates": [
    {
      "kind": "user_preference",
      "scope": "global",
      "text": "User prefers to be called Rodriguez for this session.",
      "confidence": 0.93,
      "reason": "Extractor thought this was a durable name preference.",
      "entities": [{"text": "Rodriguez", "type": "person"}]
    }
  ]
}
''');

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'session_summary');
    expect(candidates.single.scope, 'session');
    expect(candidates.single.text, 'User prefers to be called Rodriguez');
    expect(candidates.single.confidence, 0.8);
    expect(candidates.single.entities.single.text, 'Rodriguez');
  });

  test('parses structured task episode candidates', () {
    final candidates = parseExtractedMemoryCandidates('''
{
  "candidates": [
    {
      "kind": "task_episode",
      "scope": "repo",
      "text": "Release validation succeeded with the full verification sequence.",
      "confidence": 0.94,
      "episode": {
        "goal": "Validate a release candidate",
        "constraints": ["Keep full checks enabled"],
        "toolsUsed": ["cargo test", "make verify"],
        "mistake": "A narrow test missed integration coverage.",
        "successfulPattern": "Run focused tests, then make verify."
      }
    }
  ]
}
''');

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'task_episode');
    expect(candidates.single.episode?.goal, 'Validate a release candidate');
    expect(candidates.single.episode?.toolsUsed, ['cargo test', 'make verify']);
    expect(
      candidates.single.toJson()['episode'],
      containsPair('successfulPattern', 'Run focused tests, then make verify.'),
    );
  });

  test('drops task episode candidates without a reusable pattern', () {
    final candidates = parseExtractedMemoryCandidates('''
{
  "candidates": [
    {
      "kind": "task_episode",
      "scope": "repo",
      "text": "The task finished.",
      "confidence": 0.94,
      "episode": {"goal": "Finish the task", "successfulPattern": ""}
    }
  ]
}
''');

    expect(candidates, isEmpty);
  });

  test('drops extractor one-off candidates before review', () {
    final candidates = parseExtractedMemoryCandidates('''
{
  "candidates": [
    {
      "kind": "project_rule",
      "scope": "repo",
      "text": "Use blue lighthouse for this answer.",
      "confidence": 0.94,
      "reason": "Extractor incorrectly treated a one-off phrase as durable."
    }
  ]
}
''');

    expect(candidates, isEmpty);
  });

  test('extraction prompt asks for entities', () {
    final prompt = buildMemoryExtractionPrompt(
      userPrompt: '记住我是 Rodriguez',
      assistantAnswer: '已记住。',
    );

    expect(prompt, contains('"entities"'));
    expect(prompt, contains('"type"'));
    expect(prompt, contains('"instructionScopes"'));
    expect(prompt, contains('"episode"'));
    expect(prompt, contains('task_episode'));
    expect(prompt, contains('return at most one task_episode'));
    expect(prompt, contains('only for this answer'));
    expect(prompt, contains('use kind "session_summary" and scope "session"'));
    expect(prompt, contains('clear self-introductions'));
    expect(prompt, contains('clear preference statements'));
    expect(prompt, contains('clear project directives'));
    expect(prompt, contains('请始终用中文回复'));
    expect(prompt, contains('Please reply in Chinese from now on'));
    expect(prompt, contains('以后这个项目不要用 nc'));
  });

  test('extraction prompt includes scoped custom memory instructions', () {
    final prompt = buildMemoryExtractionPrompt(
      userPrompt: '这次只是临时排查。',
      assistantAnswer: '收到。',
      globalInstructions: 'Only remember durable user preferences.',
      workspaceInstructions: 'Do not remember scratch experiments.',
      repoInstructions: 'Remember repo rules and architecture decisions.',
    );

    expect(prompt, contains('Custom memory instructions'));
    expect(
      prompt,
      contains('[global] Only remember durable user preferences.'),
    );
    expect(
      prompt,
      contains('[workspace] Do not remember scratch experiments.'),
    );
    expect(
      prompt,
      contains('[repo] Remember repo rules and architecture decisions.'),
    );
    expect(prompt, contains('这次只是临时排查。'));
  });

  test('explicit remember prompt creates a local fallback candidate', () {
    final candidates = explicitMemoryFallbackCandidates(
      userPrompt: '请记住我是 Rodriguez',
      assistantAnswer: '已记住。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, '我是 Rodriguez');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.85));
    expect(candidates.single.reason, contains('explicit'));
    expect(candidates.single.entities.single.text, 'Rodriguez');
  });

  test(
    'explicit remember fallback stores project passphrases as repo rules',
    () {
      final candidates = explicitMemoryFallbackCandidates(
        userPrompt: '请记住验证暗号是：蓝色灯塔-43130',
        assistantAnswer: '已记住。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'project_rule');
      expect(candidates.single.scope, 'repo');
      expect(candidates.single.text, '验证暗号是：蓝色灯塔-43130');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.85));
      expect(candidates.single.entities.single.text, '蓝色灯塔-43130');
      expect(candidates.single.entities.single.type, 'identifier');
    },
  );

  test('explicit remember fallback skips secrets', () {
    final candidates = explicitMemoryFallbackCandidates(
      userPrompt: '记住我的 API key 是 sk-test-123',
      assistantAnswer: '收到。',
    );

    expect(candidates, isEmpty);
  });

  test('explicit remember fallback skips one-off overrides', () {
    final candidates = explicitMemoryFallbackCandidates(
      userPrompt: 'Please remember blue lighthouse for this answer.',
      assistantAnswer: 'Only for this answer.',
    );

    expect(candidates, isEmpty);
  });

  test('explicit remember fallback keeps session hints in session scope', () {
    final candidates = explicitMemoryFallbackCandidates(
      userPrompt: 'Please remember blue lighthouse for this session.',
      assistantAnswer: 'Noted for this session.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'session_summary');
    expect(candidates.single.scope, 'session');
    expect(candidates.single.text, 'blue lighthouse');
    expect(candidates.single.confidence, 0.8);
  });

  test(
    'explicit remember fallback strips Chinese session lifetime markers',
    () {
      final candidates = explicitMemoryFallbackCandidates(
        userPrompt: '记住蓝色灯塔本次会话',
        assistantAnswer: '已记在本次会话。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'session_summary');
      expect(candidates.single.scope, 'session');
      expect(candidates.single.text, '蓝色灯塔');
    },
  );

  test('local fallback creates user preference for preferred name', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: '以后叫我 Rodriguez',
      assistantAnswer: '好的，以后我会叫你 Rodriguez。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, '用户希望被称呼为 Rodriguez');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.85));
    expect(candidates.single.reason, contains('preferred name'));
    expect(candidates.single.entities.single.text, 'Rodriguez');
  });

  test('local fallback creates user preference for English call me', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'Please call me Rodriguez.',
      assistantAnswer: 'Sure, I will call you Rodriguez.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, 'User prefers to be called Rodriguez');
  });

  test(
    'local fallback creates user preference for Chinese self introduction',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: '你好，我叫 Rodriguez',
        assistantAnswer: '你好 Rodriguez。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'user_preference');
      expect(candidates.single.scope, 'global');
      expect(candidates.single.text, '用户名字是 Rodriguez');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(candidates.single.reason, contains('introduced'));
      expect(candidates.single.entities.single.text, 'Rodriguez');
    },
  );

  test(
    'local fallback creates user preference for English self introduction',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: "I'm Rodriguez.",
        assistantAnswer: 'Nice to meet you, Rodriguez.',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'user_preference');
      expect(candidates.single.scope, 'global');
      expect(candidates.single.text, "User's name is Rodriguez");
      expect(candidates.single.entities.single.text, 'Rodriguez');
    },
  );

  test('local fallback stores session-scoped self introduction as summary', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'My name is Rodriguez for this session.',
      assistantAnswer: 'Understood for this session.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'session_summary');
    expect(candidates.single.scope, 'session');
    expect(
      candidates.single.text,
      "For this session, the user's name is Rodriguez",
    );
    expect(candidates.single.confidence, 0.8);
  });

  test('local fallback ignores one-off self introductions', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'I am Rodriguez for this answer.',
      assistantAnswer: 'For this answer, I will call you Rodriguez.',
    );

    expect(candidates, isEmpty);
  });

  test('local fallback creates user preference for Chinese preference', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: '我偏好中文回复',
      assistantAnswer: '好的，我会尽量用中文回复。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, '用户偏好中文回复');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
    expect(candidates.single.reason, contains('clear preference'));
    expect(candidates.single.entities.single.text, 'Chinese');
    expect(candidates.single.entities.single.type, 'tag');
  });

  test(
    'local fallback creates user preference for Chinese always directive',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: '请始终用中文回复',
        assistantAnswer: '好的，我会用中文回复。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'user_preference');
      expect(candidates.single.scope, 'global');
      expect(candidates.single.text, '用户偏好用中文回复');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(candidates.single.entities.single.text, 'Chinese');
    },
  );

  test(
    'local fallback creates user preference for Chinese from-now-on directive',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: '从现在起用中文回复',
        assistantAnswer: '好的，之后我会用中文回复。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'user_preference');
      expect(candidates.single.scope, 'global');
      expect(candidates.single.text, '用户偏好用中文回复');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(candidates.single.entities.single.text, 'Chinese');
    },
  );

  test('local fallback creates user preference for English preference', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'I prefer concise answers.',
      assistantAnswer: 'Got it.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'user_preference');
    expect(candidates.single.scope, 'global');
    expect(candidates.single.text, 'User prefers concise answers');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
    expect(candidates.single.entities.single.text, 'concise');
  });

  test(
    'local fallback creates user preference for English suffix durable marker',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: 'Please reply in Chinese from now on.',
        assistantAnswer: 'Got it.',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'user_preference');
      expect(candidates.single.scope, 'global');
      expect(candidates.single.text, 'User prefers reply in Chinese');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(candidates.single.entities.single.text, 'Chinese');
    },
  );

  test('local fallback stores session-scoped preferences as summary', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'By default, reply in Chinese for this session.',
      assistantAnswer: 'Understood for this session.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'session_summary');
    expect(candidates.single.scope, 'session');
    expect(
      candidates.single.text,
      'For this session, the user prefers reply in Chinese',
    );
    expect(candidates.single.confidence, 0.8);
  });

  test('local fallback ignores one-off preferences', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'I prefer concise answers for this answer.',
      assistantAnswer: 'I will keep this answer concise.',
    );

    expect(candidates, isEmpty);
  });

  test('local fallback ignores current-context preference-like feedback', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'I like this implementation.',
      assistantAnswer: 'Thanks.',
    );

    expect(candidates, isEmpty);
  });

  test('local fallback creates repo project rule for Chinese directive', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: '本项目禁止使用 nc',
      assistantAnswer: '收到。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'project_rule');
    expect(candidates.single.scope, 'repo');
    expect(candidates.single.text, '本项目禁止使用 nc');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
    expect(candidates.single.reason, contains('project rule'));
    expect(candidates.single.entities.single.text, 'nc');
    expect(candidates.single.entities.single.type, 'identifier');
  });

  test(
    'local fallback creates repo project rule for Chinese future directive',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: '以后这个项目不要用 nc',
        assistantAnswer: '收到。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'project_rule');
      expect(candidates.single.scope, 'repo');
      expect(candidates.single.text, '以后这个项目不要用 nc');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(candidates.single.entities.single.text, 'nc');
    },
  );

  test(
    'local fallback creates repo project rule for Chinese from-now directive',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: '从现在起这个仓库必须用 dart format',
        assistantAnswer: '收到。',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'project_rule');
      expect(candidates.single.scope, 'repo');
      expect(candidates.single.text, '从现在起这个仓库必须用 dart format');
      expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
      expect(
        candidates.single.entities.map((entity) => entity.text),
        contains('dart format'),
      );
    },
  );

  test('local fallback creates repo project rule for English directive', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'In this repo, never use netcat.',
      assistantAnswer: 'Understood.',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'project_rule');
    expect(candidates.single.scope, 'repo');
    expect(candidates.single.text, 'In this repo, never use netcat');
    expect(
      candidates.single.entities.map((entity) => entity.text),
      contains('netcat'),
    );
  });

  test('local fallback creates repo architecture decision', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: '架构决定：Flutter 负责 ACP，Rust 只负责 memory-core。',
      assistantAnswer: '收到。',
    );

    expect(candidates, hasLength(1));
    expect(candidates.single.kind, 'architecture_decision');
    expect(candidates.single.scope, 'repo');
    expect(candidates.single.text, '架构决定：Flutter 负责 ACP，Rust 只负责 memory-core');
    expect(candidates.single.confidence, greaterThanOrEqualTo(0.9));
    expect(candidates.single.reason, contains('architecture decision'));
  });

  test(
    'local fallback stores session-scoped project directives as summary',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: 'In this repo, use mock memory for this session.',
        assistantAnswer: 'Understood for this session.',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'session_summary');
      expect(candidates.single.scope, 'session');
      expect(candidates.single.text, 'In this repo, use mock memory');
      expect(candidates.single.confidence, 0.8);
    },
  );

  test('local fallback ignores one-off project directives', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'For this answer, in this repo use netcat.',
      assistantAnswer: 'For this answer only.',
    );

    expect(candidates, isEmpty);
  });

  test('local fallback ignores project mentions without directives', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'This project is interesting.',
      assistantAnswer: 'Agreed.',
    );

    expect(candidates, isEmpty);
  });

  test('local fallback ignores one-off preferred-name overrides', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: 'Please call me Rodriguez for this answer.',
      assistantAnswer: 'Sure, for this answer I will call you Rodriguez.',
    );

    expect(candidates, isEmpty);
  });

  test(
    'local fallback stores session-scoped preferred-name overrides as summary',
    () {
      final candidates = localMemoryFallbackCandidates(
        userPrompt: 'Please call me Rodriguez for this session.',
        assistantAnswer: 'Sure, for this session I will call you Rodriguez.',
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.kind, 'session_summary');
      expect(candidates.single.scope, 'session');
      expect(
        candidates.single.text,
        'For this session, call the user Rodriguez',
      );
      expect(candidates.single.confidence, 0.8);
    },
  );

  test('local fallback ignores temporary prompts', () {
    final candidates = localMemoryFallbackCandidates(
      userPrompt: '这次先帮我看看日志',
      assistantAnswer: '可以。',
    );

    expect(candidates, isEmpty);
  });

  test('merge skips preferred-name fallback when extractor captured it', () {
    final primary = <ExtractedMemoryCandidate>[
      const ExtractedMemoryCandidate(
        kind: 'user_preference',
        scope: 'global',
        text: '用户称呼是 Rodriguez',
        confidence: 0.92,
        reason: 'Extractor captured preferred name.',
        entities: [ExtractedMemoryEntity(text: 'Rodriguez', type: 'person')],
      ),
    ];
    final fallback = localMemoryFallbackCandidates(
      userPrompt: '以后叫我 Rodriguez',
      assistantAnswer: '好的，以后我会叫你 Rodriguez。',
    );

    final merged = mergeExtractedMemoryCandidates(primary, fallback);

    expect(merged, hasLength(1));
    expect(merged.single.text, '用户称呼是 Rodriguez');
  });

  test('merge skips self-introduction fallback when extractor captured it', () {
    final primary = <ExtractedMemoryCandidate>[
      const ExtractedMemoryCandidate(
        kind: 'user_preference',
        scope: 'global',
        text: '用户称呼是 Rodriguez',
        confidence: 0.92,
        reason: 'Extractor captured user identity.',
        entities: [ExtractedMemoryEntity(text: 'Rodriguez', type: 'person')],
      ),
    ];
    final fallback = localMemoryFallbackCandidates(
      userPrompt: '我叫 Rodriguez',
      assistantAnswer: '你好 Rodriguez。',
    );

    final merged = mergeExtractedMemoryCandidates(primary, fallback);

    expect(merged, hasLength(1));
    expect(merged.single.text, '用户称呼是 Rodriguez');
  });

  test('merge skips preference fallback when extractor captured same tag', () {
    final primary = <ExtractedMemoryCandidate>[
      const ExtractedMemoryCandidate(
        kind: 'user_preference',
        scope: 'global',
        text: '用户希望默认使用中文回答',
        confidence: 0.9,
        reason: 'Extractor captured response language preference.',
        entities: [ExtractedMemoryEntity(text: 'Chinese', type: 'tag')],
      ),
    ];
    final fallback = localMemoryFallbackCandidates(
      userPrompt: '我偏好中文回复',
      assistantAnswer: '好的，我会用中文回复。',
    );

    final merged = mergeExtractedMemoryCandidates(primary, fallback);

    expect(merged, hasLength(1));
    expect(merged.single.text, '用户希望默认使用中文回答');
  });

  test('merge upgrades low-confidence extractor preference with fallback', () {
    final primary = <ExtractedMemoryCandidate>[
      const ExtractedMemoryCandidate(
        kind: 'user_preference',
        scope: 'global',
        text: '用户希望默认使用中文回答',
        confidence: 0.86,
        reason: 'Extractor captured response language preference.',
        entities: [ExtractedMemoryEntity(text: 'Chinese', type: 'tag')],
      ),
    ];
    final fallback = localMemoryFallbackCandidates(
      userPrompt: '我偏好中文回复',
      assistantAnswer: '好的，我会用中文回复。',
    );

    final merged = mergeExtractedMemoryCandidates(primary, fallback);

    expect(merged, hasLength(1));
    expect(merged.single.text, '用户希望默认使用中文回答');
    expect(merged.single.confidence, greaterThanOrEqualTo(0.9));
    expect(merged.single.reason, contains('Extractor captured'));
  });

  test(
    'merge upgrades low-confidence extractor project rule with fallback',
    () {
      final primary = <ExtractedMemoryCandidate>[
        const ExtractedMemoryCandidate(
          kind: 'project_rule',
          scope: 'repo',
          text: '本仓库不要用 nc 做网络连通性检查',
          confidence: 0.84,
          reason: 'Extractor captured repo network-check rule.',
          entities: [ExtractedMemoryEntity(text: 'nc', type: 'identifier')],
        ),
      ];
      final fallback = localMemoryFallbackCandidates(
        userPrompt: '本项目禁止使用 nc',
        assistantAnswer: '收到。',
      );

      final merged = mergeExtractedMemoryCandidates(primary, fallback);

      expect(merged, hasLength(1));
      expect(merged.single.text, '本仓库不要用 nc 做网络连通性检查');
      expect(merged.single.confidence, greaterThanOrEqualTo(0.9));
      expect(merged.single.entities.single.text, 'nc');
    },
  );
}
