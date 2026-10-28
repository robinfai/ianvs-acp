import 'package:test/test.dart';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';

void main() {
  const identity = ChatContentIdentity('generation-1', 'session');
  ChatContentUpdate update(
    ChatContentKind kind, {
    String text = '',
    String? tool,
    Map<String, Object?> metadata = const {},
    ChatContentIdentity owner = identity,
  }) => ChatContentUpdate(
    identity: owner,
    turnId: 1,
    kind: kind,
    text: text,
    toolCallId: tool,
    metadata: metadata,
  );
  test('partial tools merge by turn and call ID; revisions change', () {
    final p = ChatContentProjection(identity: identity);
    p.apply(
      update(
        ChatContentKind.tool,
        tool: 'a',
        text: 'Run',
        metadata: {
          'status': 'pending',
          'rawInput': {'command': 'pwd'},
        },
      ),
    );
    p.apply(update(ChatContentKind.tool, tool: 'b', text: 'Other'));
    p.apply(
      update(
        ChatContentKind.tool,
        tool: 'a',
        metadata: {'status': 'completed'},
      ),
    );
    expect(p.messages.length, 2);
    expect(p.messages.first.metadata['rawInput'], {'command': 'pwd'});
    expect(p.messages.first.metadata['status'], 'completed');
    expect(p.messages.first.revision, 1);
    expect(p.revision, 3);
  });
  test(
    'restore is invisible until matching commit and failures preserve history',
    () {
      final p = ChatContentProjection(identity: identity);
      p.apply(update(ChatContentKind.textDelta, text: 'existing'));
      p.beginRestore('restore-1');
      p.apply(
        update(ChatContentKind.textDelta, text: 'replayed'),
        restoreId: 'restore-1',
      );
      expect(p.messages.single.text, 'existing');
      expect(p.apply(update(ChatContentKind.textDelta, text: 'late')), isFalse);
      p.discardRestore('restore-1');
      expect(p.messages.single.text, 'existing');
      p.beginRestore('restore-2');
      expect(
        p.apply(
          update(ChatContentKind.textDelta, text: 'stale'),
          restoreId: 'restore-1',
        ),
        isFalse,
      );
      p.apply(
        update(ChatContentKind.textDelta, text: 'committed'),
        restoreId: 'restore-2',
      );
      p.commitRestore('restore-2');
      expect(p.messages.single.text, 'committed');
    },
  );
  test('old connection generation cannot mutate new content', () {
    final p = ChatContentProjection(identity: identity);
    expect(
      p.apply(
        update(
          ChatContentKind.textDelta,
          text: 'old',
          owner: const ChatContentIdentity('old', 'session'),
        ),
      ),
      isFalse,
    );
    expect(p.messages, isEmpty);
  });
  test(
    'tool null fields preserve existing data while explicit empties clear it',
    () {
      final p = ChatContentProjection(identity: identity);
      p.apply(
        update(
          ChatContentKind.tool,
          tool: 'a',
          text: 'Run',
          metadata: {
            'rawInput': {'tool': 'read'},
            'content': [1],
          },
        ),
      );
      p.apply(
        update(
          ChatContentKind.tool,
          tool: 'a',
          text: ' ',
          metadata: {'rawInput': null, 'content': []},
        ),
      );
      expect(p.messages.single.text, 'Run');
      expect(p.messages.single.metadata['rawInput'], {'tool': 'read'});
      expect(p.messages.single.metadata['content'], isEmpty);
    },
  );

  test(
    'shared text mutation validates every owner before mutating any buffer',
    () {
      final owner = Object();
      final a = ChatMessage(role: ChatMessageRole.assistant, text: 'a')
        ..projectionClaimOwnership(owner, 1);
      final b = ChatMessage(role: ChatMessageRole.assistant, text: 'b')
        ..projectionClaimOwnership(Object(), 1);
      final mutation = ChatTextMutation.prepare(
        parts: [
          ChatTextAppend(target: a, text: '1', acceptedUtf8Bytes: 1),
          ChatTextAppend(target: b, text: '2', acceptedUtf8Bytes: 1),
        ],
        previousRetained: {a: a.retainedBytes, b: b.retainedBytes},
        inputBudget: const ChatInputBudget(),
      );
      expect(() => mutation.apply(owner), throwsStateError);
      expect(a.text, 'a');
      expect(b.text, 'b');
    },
  );
}
