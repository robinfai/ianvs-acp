import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/ui/components/prompt_input.dart';

void main() {
  Widget input({
    required bool isSending,
    required PromptSendCallback onSend,
    bool enabled = true,
    VoidCallback? onStop,
    String agentName = 'Codex',
    List<Map<String, Object?>> availableCommands =
        const <Map<String, Object?>>[],
    AcpPromptCapabilities? promptCapabilities,
    PromptAttachmentPicker? pickAttachments,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: PromptInput(
          agentName: agentName,
          enabled: enabled,
          isSending: isSending,
          availableCommands: availableCommands,
          promptCapabilities: promptCapabilities,
          onSend: onSend,
          onStop: onStop ?? () {},
          pickAttachments: pickAttachments,
        ),
      ),
    );
  }

  testWidgets('PromptInput empty input cannot send', (tester) async {
    var sent = false;
    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) => sent = true),
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
      input(agentName: 'Kimi Code Dev', isSending: false, onSend: (_, _) {}),
    );

    expect(find.text('Send a prompt to Kimi Code Dev...'), findsOneWidget);
  });

  testWidgets('PromptInput input after typing can send', (tester) async {
    String? sentText;
    await tester.pumpWidget(
      input(isSending: false, onSend: (text, _) => sentText = text),
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

  testWidgets('PromptInput preserves multiline prompts', (tester) async {
    String? sentText;
    await tester.pumpWidget(
      input(isSending: false, onSend: (text, _) => sentText = text),
    );

    await tester.enterText(find.byType(TextField), 'Line one\nLine two');
    await tester.pump();
    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(sentText, 'Line one\nLine two');
  });

  testWidgets('PromptInput suggests and inserts slash commands', (
    tester,
  ) async {
    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        availableCommands: const [
          {'name': 'review', 'description': 'Review the current change.'},
          {'name': 'summarize', 'description': 'Summarize the session.'},
        ],
      ),
    );

    await tester.enterText(find.byType(TextField), '/rev');
    await tester.pump();

    expect(find.text('/review'), findsOneWidget);
    expect(find.text('Review the current change.'), findsOneWidget);
    expect(find.text('/summarize'), findsNothing);

    await tester.tap(find.text('/review'));
    await tester.pump();

    final textField = tester.widget<TextField>(find.byType(TextField));
    expect(textField.controller?.text, '/review ');
    expect(find.text('Review the current change.'), findsNothing);
  });

  testWidgets('PromptInput hides slash commands while sending', (tester) async {
    await tester.pumpWidget(
      input(
        isSending: true,
        onSend: (_, _) {},
        availableCommands: const [
          {'name': 'review', 'description': 'Review the current change.'},
        ],
      ),
    );

    expect(find.text('/review'), findsNothing);
  });

  testWidgets('PromptInput sending state disables Send and enables Stop', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      input(isSending: true, onSend: (_, _) {}, onStop: () => stopped = true),
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
    await tester.pumpWidget(input(isSending: false, onSend: (_, _) {}));

    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    expect(stopButton.onPressed, isNull);
  });

  testWidgets('PromptInput disabled state preserves draft text', (
    tester,
  ) async {
    var sent = false;
    await tester.pumpWidget(
      input(isSending: false, onSend: (_, _) => sent = true),
    );

    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();

    await tester.pumpWidget(
      input(enabled: false, isSending: false, onSend: (_, _) => sent = true),
    );

    final textField = tester.widget<TextField>(find.byType(TextField));
    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    final stopButton = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop'),
    );
    final attachButton = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.attach_file_rounded),
        matching: find.byType(IconButton),
      ),
    );

    expect(textField.enabled, isFalse);
    expect(textField.controller?.text, 'Keep this draft');
    expect(sendButton.onPressed, isNull);
    expect(stopButton.onPressed, isNull);
    expect(attachButton.onPressed, isNull);

    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(sent, isFalse);
    expect(textField.controller?.text, 'Keep this draft');
  });

  testWidgets('PromptInput attaches files and sends without text', (
    tester,
  ) async {
    List<PromptAttachment>? sentAttachments;
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
      size: 2048,
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, attachments) => sentAttachments = attachments,
        pickAttachments: () async => const [attachment],
      ),
    );

    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await tester.pump();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('2.0 KB'), findsOneWidget);

    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    expect(sendButton.onPressed, isNotNull);

    await tester.tap(find.text('Send'));
    await tester.pump();

    expect(sentAttachments, [attachment]);
    expect(find.text('readme.md'), findsNothing);
  });

  testWidgets('PromptInput ignores picker results after sending starts', (
    tester,
  ) async {
    var sent = false;
    final pickerStarted = Completer<void>();
    final pickerResult = Completer<List<PromptAttachment>>();
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
      size: 2048,
    );

    Future<List<PromptAttachment>> pickAttachments() async {
      pickerStarted.complete();
      return pickerResult.future;
    }

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) => sent = true,
        pickAttachments: pickAttachments,
      ),
    );

    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await tester.pump();
    expect(pickerStarted.isCompleted, isTrue);

    await tester.pumpWidget(
      input(
        isSending: true,
        onSend: (_, _) => sent = true,
        pickAttachments: pickAttachments,
      ),
    );
    pickerResult.complete(const [attachment]);
    await tester.pump();

    expect(find.text('readme.md'), findsNothing);
    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    expect(sendButton.onPressed, isNull);
    expect(sent, isFalse);
  });

  testWidgets('PromptInput marks attachments by prompt capability mode', (
    tester,
  ) async {
    const readme = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
    );
    const screenshot = PromptAttachment(
      path: '/workspace/screenshot.png',
      name: 'screenshot.png',
      mimeType: 'image/png',
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) {},
        promptCapabilities: const AcpPromptCapabilities(
          image: false,
          audio: false,
          embeddedContext: true,
        ),
        pickAttachments: () async => const [readme, screenshot],
      ),
    );

    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await tester.pump();

    expect(find.text('readme.md'), findsOneWidget);
    expect(find.text('screenshot.png'), findsOneWidget);
    expect(find.text('Embed'), findsOneWidget);
    expect(find.text('Link'), findsOneWidget);
  });

  testWidgets('PromptInput can remove an attachment before sending', (
    tester,
  ) async {
    var sent = false;
    const attachment = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
    );

    await tester.pumpWidget(
      input(
        isSending: false,
        onSend: (_, _) => sent = true,
        pickAttachments: () async => const [attachment],
      ),
    );

    await tester.tap(find.byIcon(Icons.attach_file_rounded));
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pump();

    expect(find.text('readme.md'), findsNothing);
    await tester.tap(find.text('Send'));
    await tester.pump();
    expect(sent, isFalse);
  });
}
