import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';

void main() {
  Widget timeline(List<ChatMessage> messages, {String agentName = 'Codex'}) {
    return MaterialApp(
      home: Scaffold(
        body: ChatTimeline(messages: messages, agentName: agentName),
      ),
    );
  }

  testWidgets('ChatTimeline renders empty state', (tester) async {
    await tester.pumpWidget(timeline(const []));

    expect(find.text('Start a session to chat with Codex'), findsOneWidget);
  });

  testWidgets('ChatTimeline empty state renders custom agent name', (
    tester,
  ) async {
    await tester.pumpWidget(timeline(const [], agentName: 'Kimi Code Dev'));

    expect(
      find.text('Start a session to chat with Kimi Code Dev'),
      findsOneWidget,
    );
  });

  testWidgets('ChatTimeline renders user and assistant messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.user, text: 'Hello'),
        ChatMessage(role: ChatMessageRole.assistant, text: 'Hello, human.'),
      ]),
    );

    expect(find.text('User'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Hello, human.'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders streaming text as one assistant message', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Hello, I am Codex.',
        ),
      ]),
    );

    expect(find.text('Agent'), findsOneWidget);
    expect(find.text('Hello, I am Codex.'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders error card', (tester) async {
    await tester.pumpWidget(
      timeline([ChatMessage(role: ChatMessageRole.error, text: 'boom')]),
    );

    expect(find.text('Error'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders compact tool cards', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'exec_command',
            'status': 'completed',
            'kind': 'execute',
            'rawInput': {'cmd': 'flutter test'},
            'rawOutput': 'All tests passed.',
          },
        ),
      ]),
    );

    expect(find.text('Tool'), findsOneWidget);
    expect(find.text('exec_command'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('All tests passed.'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    expect(find.text('All tests passed.'), findsOneWidget);
  });

  testWidgets('ChatTimeline groups consecutive tool calls by tool name', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.assistant, text: 'Checking files.'),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'exec_command',
            'status': 'completed',
            'rawInput': {'cmd': 'pwd'},
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'call-2',
            'title': 'exec_command',
            'status': 'completed',
            'rawInput': {'cmd': 'ls'},
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'web_search',
          metadata: const {
            'toolCallId': 'call-3',
            'title': 'web_search',
            'status': 'completed',
            'rawInput': {'q': 'flutter ExpansionTile'},
          },
        ),
        ChatMessage(role: ChatMessageRole.assistant, text: 'Done.'),
      ]),
    );

    expect(find.text('3 tool calls'), findsOneWidget);
    expect(find.text('exec_command'), findsOneWidget);
    expect(find.text('x2'), findsOneWidget);
    expect(find.text('web_search'), findsOneWidget);
    expect(find.text('x1'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);

    await tester.tap(find.text('3 tool calls'));
    await tester.pumpAndSettle();

    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);
    expect(find.text('exec_command'), findsNWidgets(3));
    expect(find.text('web_search'), findsNWidgets(2));
  });

  testWidgets('ChatTimeline renders plan status entries', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'Implementation plan',
          metadata: const {
            'kind': 'plan',
            'title': 'Implementation plan',
            'entries': [
              {
                'content': 'Render tool calls as cards',
                'priority': 'high',
                'status': 'completed',
              },
              {
                'content': 'Verify resume flow',
                'priority': 'medium',
                'status': 'in_progress',
              },
            ],
          },
        ),
      ]),
    );

    expect(find.text('Implementation plan'), findsOneWidget);
    expect(find.text('Render tool calls as cards'), findsOneWidget);
    expect(find.text('Verify resume flow'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('Medium'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders thought and turn status updates', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'Checking the workspace before answering.',
          metadata: const {'kind': 'thought'},
        ),
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'Turn ended normally.',
          metadata: const {'kind': 'turn', 'stopReason': 'endTurn'},
        ),
      ]),
    );

    expect(find.text('Thought'), findsOneWidget);
    expect(
      find.text('Checking the workspace before answering.'),
      findsOneWidget,
    );
    expect(find.text('Turn ended normally.'), findsOneWidget);
    expect(find.text('End turn'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders non-text content blocks', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Attached context.',
          metadata: const {
            'contentBlocks': [
              {
                'type': 'resource_link',
                'uri': 'file:///workspace/lib/main.dart',
                'title': 'main.dart',
                'mimeType': 'text/x-dart',
              },
            ],
          },
        ),
      ]),
    );

    expect(find.text('Attached context.'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('text/x-dart'), findsOneWidget);
    expect(find.text('file:///workspace/lib/main.dart'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders diff change details', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'file:///workspace/lib/main.dart',
          metadata: const {
            'kind': 'diff',
            'uri': 'file:///workspace/lib/main.dart',
            'status': 'started',
            'changes': [
              {
                'type': 'modification',
                'line': 12,
                'oldContent': 'final oldValue = true;',
                'newContent': 'final newValue = true;',
              },
            ],
          },
        ),
      ]),
    );

    expect(find.text('Changed lines'), findsOneWidget);
    expect(find.text('final oldValue = true;'), findsNothing);

    await tester.tap(find.text('Changed lines'));
    await tester.pumpAndSettle();

    expect(find.text('Modification'), findsOneWidget);
    expect(find.text('line 12'), findsOneWidget);
    expect(find.textContaining('final oldValue = true;'), findsOneWidget);
    expect(find.textContaining('final newValue = true;'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders available command details', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'review',
          metadata: const {
            'kind': 'commands',
            'commands': [
              {
                'name': 'review',
                'description': 'Review the current change.',
                'input': {'hint': 'Optional focus area'},
                'parameters': {
                  'type': 'object',
                  'properties': {'scope': 'string'},
                },
              },
            ],
          },
        ),
      ]),
    );

    expect(find.text('review'), findsOneWidget);
    expect(find.text('Command details'), findsOneWidget);
    expect(find.text('Review the current change.'), findsNothing);

    await tester.tap(find.text('Command details'));
    await tester.pumpAndSettle();

    expect(find.text('Review the current change.'), findsOneWidget);
    expect(find.text('Input hint'), findsOneWidget);
    expect(find.text('Optional focus area'), findsOneWidget);
    expect(find.text('Parameters'), findsOneWidget);
    expect(find.textContaining('"scope"'), findsOneWidget);
  });
}
