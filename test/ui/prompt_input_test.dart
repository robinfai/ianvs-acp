import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/components/prompt_input.dart';

void main() {
  Widget input({
    required bool isSending,
    required ValueChanged<String> onSend,
    VoidCallback? onStop,
    String agentName = 'Codex',
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PromptInput(
          agentName: agentName,
          isSending: isSending,
          onSend: onSend,
          onStop: onStop ?? () {},
        ),
      ),
    );
  }

  testWidgets('PromptInput empty input cannot send', (tester) async {
    var sent = false;
    await tester.pumpWidget(
      input(isSending: false, onSend: (_) => sent = true),
    );

    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    expect(sendButton.onPressed, isNull);

    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent, isFalse);
  });

  testWidgets('PromptInput renders custom agent name in placeholder', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(agentName: 'Kimi Code Dev', isSending: false, onSend: (_) {}),
    );

    expect(find.text('Send a prompt to Kimi Code Dev...'), findsOneWidget);
  });

  testWidgets('PromptInput input after typing can send', (tester) async {
    String? sentText;
    await tester.pumpWidget(
      input(isSending: false, onSend: (text) => sentText = text),
    );

    await tester.enterText(find.byType(TextField), 'Hello Codex');
    await tester.pump();

    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sentText, 'Hello Codex');
  });

  testWidgets('PromptInput sending state disables Send and enables Stop', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      input(isSending: true, onSend: (_) {}, onStop: () => stopped = true),
    );

    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    expect(sendButton.onPressed, isNull);
    expect(stopButton.onPressed, isNotNull);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(stopped, isTrue);
  });

  testWidgets('PromptInput Stop disabled when not sending', (tester) async {
    await tester.pumpWidget(input(isSending: false, onSend: (_) {}));

    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    expect(stopButton.onPressed, isNull);
  });
}
