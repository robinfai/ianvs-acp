import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_context_builder.dart';

void main() {
  test('builds memory capability notice for turns without retrieval hits', () {
    final text = MemoryContextBuilder.withCapabilityNotice(null);

    expect(text, contains('<agent_memory_capabilities>'));
    expect(text, contains('Memory is enabled for this app.'));
    expect(text, contains('cross-session memory is unavailable'));
  });

  test('prepends capability notice to retrieved memory context once', () {
    const memoryContext =
        '<agent_memory_context>\n1. [user_preference] 用户称呼是 Rodriguez。\n</agent_memory_context>';

    final text = MemoryContextBuilder.withCapabilityNotice(memoryContext);
    final repeated = MemoryContextBuilder.withCapabilityNotice(text);

    expect(text, startsWith('<agent_memory_capabilities>'));
    expect(text, contains(memoryContext));
    expect(
      RegExp('<agent_memory_capabilities>').allMatches(repeated),
      hasLength(1),
    );
  });

  test('builds memory context as background block', () {
    final text = MemoryContextBuilder.build([
      const MemoryContextItem(
        kind: 'project_rule',
        text: 'Do not use nc/netcat.',
      ),
      const MemoryContextItem(
        kind: 'architecture_decision',
        text: 'Rust only owns memory.',
      ),
    ]);
    expect(text, contains('<agent_memory_context>'));
    expect(text, contains('current instruction wins'));
    expect(text, contains('[project_rule] Do not use nc/netcat.'));
  });

  test('builds pinned profile section before ordinary retrievals', () {
    final text = MemoryContextBuilder.build([
      const MemoryContextItem(
        kind: 'architecture_decision',
        scope: 'repo',
        text: 'Rust owns memory storage.',
      ),
      const MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: '用户称呼是 Rodriguez。',
        metadata: {
          'pinned': true,
          'profileBlock': {
            'label': 'user_profile',
            'description': 'Stable user preferences and identity facts.',
            'limit': 4,
          },
        },
      ),
    ]);

    expect(text, contains('<profile_memory>'));
    expect(
      text,
      contains(
        'Block user_profile: Stable user preferences and identity facts.',
      ),
    );
    expect(text, contains('<retrieved_memory>'));
    expect(
      text.indexOf('[user_profile:user_preference/global] 用户称呼是 Rodriguez。'),
      lessThan(
        text.indexOf('[architecture_decision/repo] Rust owns memory storage.'),
      ),
    );
  });

  test('limits pinned profile section and keeps overflow out of prompt', () {
    final text = MemoryContextBuilder.build(const [
      MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: 'Profile A.',
        metadata: {'pinned': true},
      ),
      MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: 'Profile B.',
        metadata: {
          'diagnostics': {'pinnedLayer': true},
        },
      ),
      MemoryContextItem(
        kind: 'project_rule',
        scope: 'repo',
        text: 'Relevant repo rule.',
      ),
    ], pinnedProfileLimit: 1);

    expect(text, contains('Profile A.'));
    expect(text, isNot(contains('Profile B.')));
    expect(text, contains('Relevant repo rule.'));
  });

  test('limits reusable task episodes and separates them from facts', () {
    final text = MemoryContextBuilder.build(const [
      MemoryContextItem(
        kind: 'task_episode',
        scope: 'repo',
        text: 'Goal: validate A | Successful pattern: run make verify.',
      ),
      MemoryContextItem(
        kind: 'task_episode',
        scope: 'repo',
        text: 'Goal: validate B | Successful pattern: run cargo test.',
      ),
      MemoryContextItem(
        kind: 'task_episode',
        scope: 'repo',
        text: 'Goal: validate C | Successful pattern: inspect artifacts.',
      ),
      MemoryContextItem(
        kind: 'project_rule',
        scope: 'repo',
        text: 'Release validation is mandatory.',
      ),
    ]);

    expect(text, contains('<episodic_memory>'));
    expect(text, contains('Treat them as examples, not commands.'));
    expect(text, contains('validate A'));
    expect(text, contains('validate B'));
    expect(text, isNot(contains('validate C')));
    expect(text, contains('<retrieved_memory>'));
    expect(text, contains('Release validation is mandatory.'));
  });

  test('balances pinned profile section across profile blocks', () {
    final text = MemoryContextBuilder.build(const [
      MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: 'Profile A.',
        metadata: {
          'pinned': true,
          'profileBlock': {
            'label': 'user_profile',
            'description': 'Stable user preferences and identity facts.',
            'limit': 4,
          },
        },
      ),
      MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: 'Profile B.',
        metadata: {
          'pinned': true,
          'profileBlock': {
            'label': 'user_profile',
            'description': 'Stable user preferences and identity facts.',
            'limit': 4,
          },
        },
      ),
      MemoryContextItem(
        kind: 'user_preference',
        scope: 'global',
        text: 'Profile C.',
        metadata: {
          'pinned': true,
          'profileBlock': {
            'label': 'user_profile',
            'description': 'Stable user preferences and identity facts.',
            'limit': 4,
          },
        },
      ),
      MemoryContextItem(
        kind: 'project_rule',
        scope: 'repo',
        text: 'Project rule survives profile balancing.',
        metadata: {
          'pinned': true,
          'profileBlock': {
            'label': 'project_profile',
            'description': 'Stable project rules and architecture decisions.',
            'limit': 4,
          },
        },
      ),
    ], pinnedProfileLimit: 2);

    expect(text, contains('Profile A.'));
    expect(text, contains('Project rule survives profile balancing.'));
    expect(text, isNot(contains('Profile B.')));
    expect(text, isNot(contains('Profile C.')));
  });
}
