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
}
