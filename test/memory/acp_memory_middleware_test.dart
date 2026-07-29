import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/acp_memory_middleware.dart';

void main() {
  test('detailed search returns memory context and used memories', () async {
    final middleware = AcpMemoryMiddleware(
      search: (_) async => throw StateError('legacy search should not run'),
      searchDetails: (context) async => const MemoryPromptResult(
        memoryContext: '<agent_memory_context>name</agent_memory_context>',
        usedMemories: [
          MemoryUsedItem(
            id: 'mem_name',
            kind: 'user_preference',
            scope: 'global',
            text: '用户称呼是 Rodriguez。',
            score: 0.93,
            metadata: <String, Object?>{
              'diagnostics': <String, Object?>{'finalScore': 0.93},
            },
          ),
        ],
      ),
    );

    final result = await middleware.preparePrompt('怎么称呼我？');

    expect(result.memoryContext, contains('<agent_memory_capabilities>'));
    expect(result.memoryContext, contains('<agent_memory_context>'));
    expect(result.usedMemories.single.id, 'mem_name');
    expect(result.usedMemories.single.metadata?['diagnostics'], isA<Map>());
  });

  test(
    'successful empty search still tells agent memory is available',
    () async {
      final middleware = AcpMemoryMiddleware(search: (_) async => null);

      final result = await middleware.preparePrompt('记住我叫 Rodriguez');

      expect(result.memoryContext, contains('<agent_memory_capabilities>'));
      expect(result.memoryContext, contains('Memory is enabled for this app.'));
      expect(
        result.memoryContext,
        contains('cross-session memory is unavailable'),
      );
      expect(result.usedMemories, isEmpty);
    },
  );

  test('memory feedback is delegated without affecting prompt flow', () async {
    MemoryFeedbackContext? submitted;
    final middleware = AcpMemoryMiddleware(
      search: (_) async => null,
      feedback: (context) async {
        submitted = context;
      },
    );

    await middleware.submitFeedback(
      memoryId: 'mem_name',
      rating: 'not_relevant',
      turnId: 'turn_1',
      reason: '不是本问题需要的记忆',
    );

    expect(submitted?.memoryId, 'mem_name');
    expect(submitted?.rating, 'not_relevant');
    expect(submitted?.turnId, 'turn_1');
    expect(submitted?.reason, '不是本问题需要的记忆');
  });

  test(
    'turn completion callback runs even when extraction is absent',
    () async {
      MemoryTurnContext? completed;
      final middleware = AcpMemoryMiddleware(
        search: (_) async => null,
        onTurnComplete: (context) async {
          completed = context;
        },
      );
      const context = MemoryTurnContext(
        userPrompt: '记住我的名字',
        assistantAnswer: '已记住。',
        sessionId: 'session-1',
        turnId: 'turn-1',
      );

      await middleware.extractTurn(context);

      expect(completed?.userPrompt, '记住我的名字');
      expect(completed?.assistantAnswer, '已记住。');
      expect(completed?.sessionId, 'session-1');
      expect(completed?.turnId, 'turn-1');
    },
  );

  test('turn completion callback runs when extraction fails', () async {
    var completed = false;
    final middleware = AcpMemoryMiddleware(
      search: (_) async => null,
      extract: (_) async => throw StateError('extractor down'),
      onTurnComplete: (_) async {
        completed = true;
      },
    );

    await middleware.extractTurn(
      const MemoryTurnContext(userPrompt: 'hello', assistantAnswer: 'hi'),
    );

    expect(completed, isTrue);
  });

  test(
    'search failure returns original prompt and records nonfatal error',
    () async {
      final middleware = AcpMemoryMiddleware(
        search: (_) async => throw StateError('down'),
      );
      final result = await middleware.preparePrompt('hello');
      expect(result.prompt, 'hello');
      expect(result.memoryContext, isNull);
      expect(result.error, contains('down'));
    },
  );
}
