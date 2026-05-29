import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';

void main() {
  Widget timeline(List<ChatMessage> messages) {
    return MaterialApp(
      home: Scaffold(body: ChatTimeline(messages: messages)),
    );
  }

  testWidgets('ChatTimeline renders empty state', (tester) async {
    await tester.pumpWidget(timeline(const []));

    expect(find.text('Start a session to chat with Codex'), findsOneWidget);
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
}
