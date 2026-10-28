import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';

void main() {
  Widget app(Widget child, {bool dark = false}) => MaterialApp(
    theme: dark ? ThemeData.dark() : ThemeData.light(),
    home: Scaffold(
      body: Align(alignment: Alignment.topCenter, child: child),
    ),
  );

  testWidgets(
    'hosted input preserves host editor, composition and focus across mode/slots',
    (tester) async {
      final controller = TextEditingController(text: 'draft');
      final focus = FocusNode();
      var sends = 0;
      final editor = TextField(
        key: const ValueKey('host-editor'),
        controller: controller,
        focusNode: focus,
      );
      Widget composer(bool shell) => PromptInput.hosted(
        editor: editor,
        header: shell ? const Text('Shell') : null,
        contextStrip: shell ? null : const Text('Context'),
        actions: TextButton(
          key: const ValueKey('host-send'),
          onPressed: () => sends++,
          child: Text(shell ? 'Run' : 'Send'),
        ),
      );
      await tester.pumpWidget(app(composer(true)));
      focus.requestFocus();
      controller.value = const TextEditingValue(
        text: 'draft',
        selection: TextSelection.collapsed(offset: 3),
        composing: TextRange(start: 1, end: 4),
      );
      await tester.pump();
      final before = tester.state(find.byType(EditableText));
      await tester.pumpWidget(app(composer(false)));
      expect(tester.state(find.byType(EditableText)), same(before));
      expect(focus.hasFocus, isTrue);
      expect(controller.selection.baseOffset, 3);
      expect(controller.value.composing, const TextRange(start: 1, end: 4));
      expect(find.byType(EditableText), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('host-send')));
      expect(sends, 1);
      await tester.pumpWidget(const SizedBox());
      controller.text = 'still owned by host';
      void listener() {}
      focus.addListener(listener);
      focus.removeListener(listener);
      controller.dispose();
      focus.dispose();
    },
  );

  testWidgets(
    'literal preview normalizes display but copies original only when enabled',
    (tester) async {
      const source = '```sh\r\necho "x"\rnext\n```';
      String? copied;
      await tester.pumpWidget(app(const ChatCodePreview(source: source)));
      expect(find.byTooltip('Copy source'), findsNothing);
      expect(find.text('```sh\necho "x"\nnext\n```'), findsOneWidget);
      await tester.pumpWidget(
        app(
          ChatCodePreview(
            source: source,
            maxCharacters: 10,
            onCopy: (text) {
              copied = text;
            },
          ),
        ),
      );
      expect(find.text('Preview truncated'), findsOneWidget);
      await tester.tap(find.byTooltip('Copy source'));
      expect(copied, source);
    },
  );

  testWidgets('320px dark host components retain separate guarded actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var commandApprovals = 0;
    var acpApprovals = 0;
    await tester.pumpWidget(
      app(
        SingleChildScrollView(
          child: ChatMessageFrame(
            role: ChatMessageRole.assistant,
            roleLabel: 'Assistant with a long visible role label',
            footer: const Text('Host execution record'),
            child: ChatDecisionCard(
              title: const Text('Review command'),
              body: const ChatCodePreview(
                source:
                    'echo aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              ),
              actions: [
                TextButton(
                  key: const ValueKey('command-approve'),
                  onPressed: () => commandApprovals++,
                  child: const Text('Approve command'),
                ),
                TextButton(
                  key: const ValueKey('acp-approve'),
                  onPressed: () => acpApprovals++,
                  child: const Text('Allow ACP request'),
                ),
              ],
            ),
          ),
        ),
        dark: true,
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester
          .getTopLeft(find.text('Assistant with a long visible role label'))
          .dy,
      lessThan(tester.getTopLeft(find.text('Review command')).dy),
    );
    await tester.tap(find.byKey(const ValueKey('command-approve')));
    expect(commandApprovals, 1);
    expect(acpApprovals, 0);
  });

  testWidgets(
    'tool card remains standalone and hides default output when linked',
    (tester) async {
      final message = ChatMessageData(
        role: ChatMessageRole.tool,
        text: 'Execute command',
        metadata: {
          'toolCallId': 'call-1',
          'title': 'Execute command',
          'status': 'completed',
          'rawOutput': 'private output',
        },
      );
      await tester.pumpWidget(
        app(ChatToolCard(message: message, expanded: true)),
      );
      expect(find.text('Output'), findsOneWidget);
      await tester.pumpWidget(
        app(
          ChatToolCard(
            message: message,
            expanded: true,
            showDetails: false,
            footer: const Text('Running · original block 7'),
          ),
        ),
      );
      expect(find.text('Output'), findsNothing);
      expect(find.text('Running · original block 7'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(
        app(
          ChatToolCard(
            message: message.copyWith(
              metadata: {
                ...message.metadata,
                'content': [
                  {
                    'type': 'image',
                    'data': 'invalid-base64',
                    'mimeType': 'image/png',
                  },
                  {
                    'type': 'diff',
                    'path': 'hidden-file.txt',
                    'oldText': 'before',
                    'newText': 'after',
                  },
                ],
              },
            ),
            expanded: true,
            showDetails: false,
            footer: const Text('Running · original block 7'),
          ),
        ),
      );
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('hidden-file.txt'), findsNothing);
      expect(find.text('Output'), findsNothing);
      expect(find.text('Running · original block 7'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'rich tool disclosure follows host state without discarding rendered diffs',
    (tester) async {
      final message = ChatMessageData(
        role: ChatMessageRole.tool,
        text: 'Edit file',
        metadata: {
          'toolCallId': 'diff-host',
          'title': 'Edit file',
          'status': 'completed',
          'content': [
            {
              'type': 'diff',
              'path': 'controlled.txt',
              'oldText': 'old',
              'newText': 'new',
            },
          ],
        },
      );
      bool? requested;
      Widget card(bool expanded) => ChatToolCard(
        message: message,
        expanded: expanded,
        onExpandedChanged: (value) {
          requested = value;
        },
      );
      await tester.pumpWidget(app(card(false)));
      expect(
        find.byKey(const ValueKey('tool-activity-details-diff-host')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(const ValueKey('tool-activity-toggle-diff-host')),
      );
      expect(requested, isTrue);
      expect(
        find.byKey(const ValueKey('tool-activity-details-diff-host')),
        findsNothing,
      );
      await tester.pumpWidget(app(card(true)));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('tool-activity-details-diff-host')),
        findsOneWidget,
      );
      expect(find.textContaining('controlled.txt'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
