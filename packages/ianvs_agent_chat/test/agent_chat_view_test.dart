import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class MemorySession extends ChatSession with ChangeNotifier {
  MemorySession(this.identity, {this.capabilities = const ChatCapabilities()});
  final String identity;
  final ChatCapabilities capabilities;
  final List<ChatMessageView> messages = [];
  final List<String> sent = [];
  int revision = 0, stops = 0;
  bool sending = false;
  @override
  ChatSessionState get state => ChatSessionState(
    identity: identity,
    agentName: identity,
    messages: messages,
    messagesRevision: revision,
    isSending: sending,
    capabilities: capabilities,
  );
  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) async {
    sent.add(text);
    messages.add(
      ChatMessageData(
        role: ChatMessageRole.user,
        text: text,
        turnId: sent.length,
      ),
    );
    revision++;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    sending = false;
    notifyListeners();
  }
}

Widget host(ChatSession session, {ChatThemeData? theme}) => MaterialApp(
  home: Scaffold(
    body: ChatTheme(
      data: theme ?? const ChatThemeData(),
      child: AgentChatView(session: session),
    ),
  ),
);

void main() {
  testWidgets('image-only backend opens the image picker directly', (
    tester,
  ) async {
    final session = MemorySession(
      'Images',
      capabilities: const ChatCapabilities(
        attachments: true,
        prompt: ChatPromptCapabilities(
          files: false,
          image: true,
          audio: false,
          embeddedContext: false,
        ),
      ),
    );
    addTearDown(session.dispose);
    PromptAttachmentKind? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentChatView(
            session: session,
            pickAttachmentsForKind: (kind) async {
              selected = kind;
              return [];
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('prompt-attachment-picker')));
    await tester.pumpAndSettle();
    expect(selected, PromptAttachmentKind.image);
  });

  testWidgets(
    'pure text capabilities hide unavailable controls and route send',
    (tester) async {
      final session = MemorySession('Plain');
      addTearDown(session.dispose);
      await tester.pumpWidget(host(session));
      expect(find.byKey(const Key('prompt-attachment-picker')), findsNothing);
      await tester.enterText(find.byType(TextField), 'hello');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt-action-button')));
      await tester.pumpAndSettle();
      expect(session.sent, ['hello']);
      expect(find.text('hello'), findsOneWidget);
    },
  );
  testWidgets(
    'switching backends clears draft and detaches old notifications',
    (tester) async {
      final a = MemorySession('ACP'), b = MemorySession('LLM');
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      await tester.pumpWidget(host(a));
      await tester.enterText(find.byType(TextField), 'old draft');
      await tester.pumpWidget(host(b));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await a.send('late old event');
      await tester.pump();
      expect(find.text('late old event'), findsNothing);
      await tester.enterText(find.byType(TextField), 'new draft');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt-action-button')));
      await tester.pumpAndSettle();
      expect(b.sent, ['new draft']);
    },
  );
  testWidgets('stop routes only to the displayed session', (tester) async {
    final a = MemorySession('A')..sending = true,
        b = MemorySession('B')..sending = true;
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(host(a));
    await tester.pump();
    await tester.tap(find.byKey(const Key('prompt-action-button')));
    await tester.pump();
    expect(a.stops, 1);
    expect(b.stops, 0);
  });
  testWidgets(
    'theme is scoped to the conversation and changes message surface',
    (tester) async {
      final session = MemorySession('Theme');
      addTearDown(session.dispose);
      await session.send('themed');
      const custom = Color(0xffcceeff);
      await tester.pumpWidget(
        host(
          session,
          theme: const ChatThemeData(colors: {'userMessageSurface': custom}),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              (widget.decoration! as BoxDecoration).color == custom,
        ),
        findsWidgets,
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('typed plan and tool models render without ACP metadata code', (
    tester,
  ) async {
    final session = MemorySession('Tools');
    addTearDown(session.dispose);
    session.messages.addAll([
      ChatMessageData(
        role: ChatMessageRole.user,
        text: 'Inspect project',
        turnId: 1,
      ),
      ChatPlanMessage(
        steps: const [
          ChatPlanStep('Inspect files', status: ChatPlanStatus.completed),
        ],
        turnId: 1,
      ),
      ChatToolMessage(
        callId: 'read-1',
        name: 'Read README',
        status: ChatToolStatus.completed,
        turnId: 1,
        output: 'Done',
      ),
      ChatMessageData(
        role: ChatMessageRole.assistant,
        text: 'Inspection complete',
        turnId: 1,
      ),
    ]);
    await tester.pumpWidget(host(session));
    await tester.pumpAndSettle();
    expect(find.textContaining('Inspection complete'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
