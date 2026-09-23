import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';

class AdmissionSession extends ChatSession
    with ChangeNotifier
    implements ChatSubmissionSession {
  Object identity = 'one';
  final pending = <Completer<ChatSubmitResult>>[];
  final submissions = <ChatSubmission>[];
  bool sending = false;
  ChatPermissionRequest? permission;
  @override
  ChatSessionState get state => ChatSessionState(
    identity: identity,
    agentName: 'Test',
    messages: const [],
    isSending: sending,
    permission: permission,
    capabilities: const ChatCapabilities(permissions: true, attachments: true),
  );
  @override
  Future<ChatSubmitResult> submit(ChatSubmission submission) {
    submissions.add(submission);
    final receipt = Completer<ChatSubmitResult>();
    pending.add(receipt);
    return receipt.future;
  }

  void update() => notifyListeners();
  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) => throw StateError('Legacy send must not also execute.');
  @override
  Future<void> stop() async {}
}

Widget host(
  AdmissionSession session,
  ChatComposerController draft, {
  double width = 420,
  double height = 560,
}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        height: height,
        child: AgentChatView(session: session, composerController: draft),
      ),
    ),
  ),
);

void main() {
  test(
    'ledger registers pending requests before reentry and freezes attachments',
    () async {
      final ledger = ChatSubmissionLedger();
      final attachments = <PromptAttachment>[];
      final submission = ChatSubmission(
        id: 'id',
        sessionIdentity: 'one',
        draftRevision: 1,
        text: 'hello',
        attachments: attachments,
      );
      attachments.add(const PromptAttachment(path: 'a', name: 'a'));
      expect(submission.attachments, isEmpty);
      expect(() => submission.attachments.clear(), throwsUnsupportedError);
      final result = Completer<ChatSubmitResult>();
      var calls = 0;
      Future<ChatSubmitResult>? reentry;
      final first = ledger.submit(submission, () {
        calls++;
        reentry = ledger.submit(
          submission,
          () => throw StateError('duplicate'),
        );
        return result.future;
      });
      expect(reentry, same(first));
      final second = ledger.submit(
        submission,
        () => throw StateError('duplicate'),
      );
      expect(second, same(first));
      result.complete(const ChatSubmitResult.accepted());
      expect((await first).isAccepted, isTrue);
      expect(
        ledger.submit(submission, () => throw StateError('duplicate')),
        same(first),
      );
      expect(calls, 1);
    },
  );

  testWidgets(
    'admission rejects without losing draft, prevents double send, and clears before generation completes',
    (tester) async {
      final session = AdmissionSession();
      final draft = ChatComposerController(text: 'keep me');
      addTearDown(session.dispose);
      addTearDown(draft.dispose);
      await tester.pumpWidget(host(session, draft));
      draft.requestFocus();
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(session.submissions.length, 1);
      session.pending.single.complete(
        const ChatSubmitResult.rejected('Too long'),
      );
      await tester.pump();
      expect(draft.text, 'keep me');
      expect(find.text('Too long'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(session.submissions.length, 2);
      session.sending = true;
      session.update();
      session.pending.last.complete(const ChatSubmitResult.accepted());
      await tester.pump();
      expect(draft.text, isEmpty);
      expect(session.state.isSending, isTrue);
      await tester.pumpWidget(const SizedBox());
      draft.replaceText('host still owns controller');
      expect(draft.text, contains('host'));
    },
  );

  testWidgets('old receipts cannot clear edited drafts or a new session', (
    tester,
  ) async {
    final session = AdmissionSession();
    final draft = ChatComposerController(text: 'first');
    addTearDown(session.dispose);
    addTearDown(draft.dispose);
    await tester.pumpWidget(host(session, draft));
    await tester.tap(find.byKey(const Key('prompt-action-button')));
    draft.replaceText('second');
    session.pending.first.complete(const ChatSubmitResult.queued());
    await tester.pump();
    expect(draft.text, 'second');
    await tester.tap(find.byKey(const Key('prompt-action-button')));
    session.identity = 'two';
    session.update();
    await tester.pump();
    expect(draft.text, isEmpty);
    draft.insertText('new session text');
    session.pending.last.complete(const ChatSubmitResult.accepted());
    await tester.pump();
    expect(draft.text, 'new session text');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'attachments participate in admission revision and survive rejection',
    (tester) async {
      final draft = ChatComposerController(text: 'with file');
      addTearDown(draft.dispose);
      final receipts = <Completer<ChatSubmitResult>>[];
      final submissions = <ChatSubmission>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptInput(
              isSending: false,
              onStop: () {},
              composerController: draft,
              onSubmit: (submission) {
                submissions.add(submission);
                final receipt = Completer<ChatSubmitResult>();
                receipts.add(receipt);
                return receipt.future;
              },
              promptCapabilities: const ChatPromptCapabilities(
                files: false,
                image: true,
                audio: false,
                embeddedContext: false,
              ),
              pickAttachmentsForKind: (_) async => [
                const PromptAttachment(
                  path: '',
                  name: 'draft.png',
                  mimeType: 'image/png',
                  data: 'AA==',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('prompt-action-button')));
      final revision = draft.revision;
      await tester.tap(find.byKey(const Key('prompt-attachment-picker')));
      await tester.pumpAndSettle();
      expect(draft.revision, greaterThan(revision));
      receipts.first.complete(const ChatSubmitResult.accepted());
      await tester.pumpAndSettle();
      expect(draft.text, 'with file');
      expect(find.byTooltip('draft.png'), findsOneWidget);
      await tester.tap(find.byKey(const Key('prompt-action-button')));
      expect(submissions, hasLength(2));
      expect(submissions.last.attachments.single.name, 'draft.png');
      receipts.last.completeError(StateError('Admission failed'));
      await tester.pump();
      expect(find.byTooltip('draft.png'), findsOneWidget);
      expect(draft.text, 'with file');
      draft.clear();
      await tester.pump();
      expect(find.byTooltip('draft.png'), findsNothing);
    },
  );

  for (final width in [320.0, 360.0, 420.0, 600.0, 620.0, 900.0]) {
    for (final height in [400.0, 560.0, 800.0]) {
      testWidgets('shared composer fits local $width x $height', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(1000, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = AdmissionSession();
        final draft = ChatComposerController();
        addTearDown(session.dispose);
        addTearDown(draft.dispose);
        await tester.pumpWidget(
          host(session, draft, width: width, height: height),
        );
        await tester.enterText(find.byType(TextField), 'line\n' * 6);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.byKey(const Key('prompt-action-button')).hitTestable(),
          findsOneWidget,
        );
        expect(
          tester.getSize(find.byType(PromptInput)).height,
          lessThanOrEqualTo(height * .60),
        );
      });
    }
  }
}
