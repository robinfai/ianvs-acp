import 'dart:collection';
import 'dart:io';
import 'dart:ui' show PointerDeviceKind, SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show
        debugPaintBaselinesEnabled,
        debugPaintPointersEnabled,
        debugPaintSizeEnabled;
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/bounded_image_preview.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
import 'package:ianvs_acp/ui/components/markdown_code_block.dart';
import 'package:ianvs_acp/ui/image_decode_budget.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  Widget timeline(
    List<ChatMessage> messages, {
    String agentName = 'Codex',
    bool hasActiveSession = false,
    String? activeSessionLabel,
    bool isLoadingSession = false,
    int messageListRevision = 0,
    bool? showNewSessionAction,
    VoidCallback? onNewSession,
    MarkdownTapLinkCallback? onTapLink,
    ThemeData? theme,
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpImageDecodeBudgetLedger? imageDecodeLedger,
    BoundedImageDecoder boundedImageDecoder = const DartUiBoundedImageDecoder(),
    Size? mediaQuerySize,
  }) {
    final chat = ChatTimeline(
      messages: messages,
      agentName: agentName,
      hasActiveSession: hasActiveSession,
      activeSessionLabel: activeSessionLabel,
      isLoadingSession: isLoadingSession,
      messageListRevision: messageListRevision,
      showNewSessionAction: showNewSessionAction ?? onNewSession != null,
      onNewSession: onNewSession,
      onTapLink: onTapLink,
      inputBudget: inputBudget,
      imageDecodeLedger: imageDecodeLedger,
      boundedImageDecoder: boundedImageDecoder,
    );
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        body: mediaQuerySize == null
            ? chat
            : MediaQuery(
                data: MediaQueryData(size: mediaQuerySize),
                child: chat,
              ),
      ),
    );
  }

  ScrollController timelineScrollController(WidgetTester tester) => tester
      .widget<CustomScrollView>(
        find.byKey(const ValueKey('chat-timeline-list')),
      )
      .controller!;

  testWidgets('ChatTimeline renders empty state', (tester) async {
    await tester.pumpWidget(timeline(const []));

    expect(find.text('Start a session to chat with Codex'), findsOneWidget);
  });

  testWidgets('ChatTimeline collapses enhanced turn process behind summary', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Implement the queue'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'Inspecting and editing several files.',
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text: 'The queue is implemented and verified.',
        metadata: const {
          'kind': 'assistant_summary',
          'sourceTurnId': 1,
          'collapseProcess': true,
        },
      ),
    );

    await tester.pumpWidget(timeline(controller.messages));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('assistant-turn-summary')),
      findsOneWidget,
    );
    expect(find.text('The queue is implemented and verified.'), findsOneWidget);
    expect(find.text('Implement the queue'), findsOneWidget);
    expect(find.text('Inspecting and editing several files.'), findsNothing);
    var processToggle = tester.getSemantics(
      find.byKey(const ValueKey('processed-turn-toggle')),
    );
    expect(processToggle.label, contains('Expand processed turn'));
    expect(
      processToggle.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(processToggle.flagsCollection.isExpanded, Tristate.isFalse);

    await tester.tap(find.textContaining('Processed').first);
    await tester.pumpAndSettle();
    expect(find.text('Implement the queue'), findsOneWidget);
    expect(find.text('Inspecting and editing several files.'), findsOneWidget);
    processToggle = tester.getSemantics(
      find.byKey(const ValueKey('processed-turn-toggle')),
    );
    expect(processToggle.label, contains('Collapse processed turn'));
    expect(processToggle.flagsCollection.isExpanded, Tristate.isTrue);
  });

  testWidgets(
    'ChatTimeline keeps unscoped prompt and response visible while process is collapsed',
    (tester) async {
      await tester.pumpWidget(
        timeline([
          ChatMessage(role: ChatMessageRole.user, text: 'Review this change'),
          ChatMessage(
            role: ChatMessageRole.status,
            text: 'Inspecting files',
            metadata: const {'kind': 'thought'},
          ),
          ChatMessage(
            role: ChatMessageRole.tool,
            text: 'wait',
            metadata: const {'status': 'completed'},
          ),
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'The change is ready.',
          ),
          ChatMessage(
            role: ChatMessageRole.status,
            text: 'Turn ended normally.',
            metadata: const {'kind': 'turn', 'stopReason': 'endTurn'},
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Review this change'), findsOneWidget);
      expect(find.text('The change is ready.'), findsOneWidget);
      expect(find.text('Inspecting files'), findsNothing);
      expect(find.text('wait'), findsNothing);
      expect(
        find.byKey(const ValueKey('processed-turn-toggle')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('processed-turn-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Inspecting files'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tool-call-group-toggle')));
      await tester.pumpAndSettle();
      expect(find.text('Inspecting files'), findsOneWidget);
      expect(find.text('Waited for background work'), findsNWidgets(2));
    },
  );

  testWidgets(
    'ChatTimeline infers completed historical turns from the next prompt',
    (tester) async {
      await tester.pumpWidget(
        timeline([
          ChatMessage(role: ChatMessageRole.user, text: 'First request'),
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'I will inspect the implementation.',
          ),
          ChatMessage(
            role: ChatMessageRole.tool,
            text: 'read_file',
            metadata: const {
              'toolCallId': 'historical-read-1',
              'status': 'completed',
            },
          ),
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'The first request is complete.',
          ),
          ChatMessage(role: ChatMessageRole.user, text: 'Second request'),
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Working on the second request.',
          ),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('First request'), findsOneWidget);
      expect(find.text('The first request is complete.'), findsOneWidget);
      expect(find.text('I will inspect the implementation.'), findsNothing);
      expect(find.text('read_file'), findsNothing);
      expect(
        find.byKey(const ValueKey('processed-turn-toggle')),
        findsOneWidget,
      );
      expect(find.text('Working on the second request.'), findsOneWidget);
    },
  );

  testWidgets(
    'ChatTimeline aggregates attachment projections into one turn node',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(980, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.user,
          text: '''# Files mentioned by the user:

## reference.png: /private/tmp/reference.png

## My request for Codex:
Review the screenshot''',
        ),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(
          role: ChatMessageRole.user,
          text: '[@image](file:///private/tmp/reference.png)',
        ),
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'Reviewed.'),
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.user, text: 'Apply the changes'),
        startsNewTurn: true,
      );
      controller.addMessageForTesting(
        ChatMessage(role: ChatMessageRole.assistant, text: 'Applied.'),
      );

      await tester.pumpWidget(timeline(controller.messages));
      await tester.pumpAndSettle();

      final outline = tester.widget<ListView>(
        find.byKey(const ValueKey('turn-navigation-outline-list')),
      );
      expect(outline.childrenDelegate.estimatedChildCount, 2);
      expect(find.textContaining('@image'), findsNothing);
      expect(find.textContaining('/private/tmp/reference.png'), findsNothing);
      expect(find.text('Review the screenshot'), findsOneWidget);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('turn-navigation-marker-0')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Review the screenshot'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets(
    'ChatTimeline turn rail previews prompts and scrolls to a selected turn',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(980, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      for (var index = 0; index < 4; index++) {
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.user,
            text: 'User request ${index + 1}',
          ),
          startsNewTurn: true,
        );
        controller.addMessageForTesting(
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Agent response ${index + 1}\n${'details\n' * 12}',
          ),
        );
      }

      await tester.pumpWidget(timeline(controller.messages));
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel('Conversation turn navigation'),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('turn-navigation-marker-3')),
        findsOneWidget,
      );
      final firstMarkerTop = tester
          .getTopLeft(find.byKey(const ValueKey('turn-navigation-marker-0')))
          .dy;
      final secondMarkerTop = tester
          .getTopLeft(find.byKey(const ValueKey('turn-navigation-marker-1')))
          .dy;
      final lastMarkerTop = tester
          .getTopLeft(find.byKey(const ValueKey('turn-navigation-marker-3')))
          .dy;
      expect(secondMarkerTop - firstMarkerTop, moreOrLessEquals(16));
      expect(lastMarkerTop - firstMarkerTop, lessThanOrEqualTo(48));
      final outlineRect = tester.getRect(
        find.byKey(const ValueKey('turn-navigation-outline-list')),
      );
      final markerGroupCenter =
          (firstMarkerTop +
              tester
                  .getBottomRight(
                    find.byKey(const ValueKey('turn-navigation-marker-3')),
                  )
                  .dy) /
          2;
      expect(
        markerGroupCenter,
        moreOrLessEquals(outlineRect.center.dy, epsilon: 1),
      );

      double markerWidth(int index) => tester
          .getSize(find.byKey(ValueKey('turn-navigation-bar-$index')))
          .width;
      expect(markerWidth(0), 7);
      expect(markerWidth(3), 7);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('turn-navigation-marker-2')),
        ),
      );
      await tester.pumpAndSettle();

      expect(markerWidth(2), 34);
      expect(markerWidth(1), greaterThan(markerWidth(0)));
      expect(markerWidth(1), lessThan(markerWidth(2)));
      expect(markerWidth(3), markerWidth(1));
      expect(
        tester
                .getTopLeft(
                  find.byKey(const ValueKey('turn-navigation-marker-1')),
                )
                .dy -
            tester
                .getTopLeft(
                  find.byKey(const ValueKey('turn-navigation-marker-0')),
                )
                .dy,
        moreOrLessEquals(16),
      );

      expect(
        find.byKey(const ValueKey('turn-navigation-preview')),
        findsOneWidget,
      );
      expect(find.text('User request 3'), findsAtLeastNWidgets(1));
      expect(find.textContaining('Agent response 3'), findsAtLeastNWidgets(1));

      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('turn-navigation-marker-1')),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));

      expect(markerWidth(1), greaterThan(7));
      expect(markerWidth(2), greaterThan(7));
      expect(
        find.byKey(const ValueKey('turn-navigation-preview')),
        findsAtLeastNWidgets(1),
      );
      await tester.pumpAndSettle();
      expect(markerWidth(1), 34);
      expect(markerWidth(0), greaterThan(7));
      expect(markerWidth(2), markerWidth(0));
      expect(find.text('User request 2'), findsAtLeastNWidgets(1));

      await mouse.moveTo(Offset(outlineRect.right + 20, outlineRect.center.dy));
      await tester.pump(const Duration(milliseconds: 16));
      expect(
        find.byKey(const ValueKey('turn-navigation-preview')),
        findsAtLeastNWidgets(1),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('turn-navigation-preview')),
        findsNothing,
      );
      expect(markerWidth(0), 7);
      expect(markerWidth(1), 7);

      final timelineController = timelineScrollController(tester);
      expect(timelineController.offset, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('turn-navigation-marker-0')));
      await tester.pumpAndSettle();
      expect(timelineController.offset, lessThan(1));
    },
  );

  testWidgets(
    'ChatTimeline outline indexes every user message across full history',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(980, 520));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final messages = <ChatMessage>[];
      for (var index = 0; index < 220; index++) {
        messages
          ..add(
            ChatMessage(
              role: ChatMessageRole.user,
              text: 'Historical user request $index',
            ),
          )
          ..add(
            ChatMessage(
              role: ChatMessageRole.assistant,
              text:
                  'Historical agent response $index\n'
                  '${index < 110 ? 'variable-height detail\n' * 8 : 'short'}',
            ),
          );
      }

      await tester.pumpWidget(timeline(messages));
      await tester.pumpAndSettle();

      final outline = tester.widget<ListView>(
        find.byKey(const ValueKey('turn-navigation-outline-list')),
      );
      expect(outline.childrenDelegate.estimatedChildCount, 220);
      expect(outline.controller!.offset, greaterThan(0));
      expect(find.textContaining('Showing latest'), findsNothing);

      outline.controller!.jumpTo(110 * 16);
      await tester.pumpAndSettle();
      final timelineController = timelineScrollController(tester);
      final offsetBeforeJump = timelineController.offset;
      await tester.tap(
        find.byKey(const ValueKey('turn-navigation-marker-110')),
      );
      await tester.pump();
      expect(find.text('Historical user request 110'), findsOneWidget);
      expect(find.text('Historical user request 109'), findsOneWidget);
      expect(find.text('Historical user request 111'), findsOneWidget);
      expect(find.text('Historical user request 0'), findsNothing);
      expect(find.text('Historical user request 219'), findsNothing);
      await tester.pumpAndSettle();
      expect(offsetBeforeJump, greaterThan(0));
      expect(timelineController.offset, moreOrLessEquals(0, epsilon: 0.5));
      final firstTargetOffset = timelineController.offset;
      final firstTargetTop = tester
          .getTopLeft(find.text('Historical user request 110'))
          .dy;
      final timelineTop = tester
          .getTopLeft(find.byKey(const ValueKey('chat-timeline-list')))
          .dy;
      expect(firstTargetTop, inInclusiveRange(timelineTop, timelineTop + 100));

      await tester.tap(
        find.byKey(const ValueKey('turn-navigation-marker-110')),
      );
      await tester.pumpAndSettle();
      final repeatedTargetOffset = timelineScrollController(tester).offset;
      expect(
        repeatedTargetOffset,
        moreOrLessEquals(firstTargetOffset, epsilon: 1),
      );
      expect(
        tester.getTopLeft(find.text('Historical user request 110')).dy,
        moreOrLessEquals(firstTargetTop, epsilon: 1),
      );
      final activeBar = tester.widget<AnimatedContainer>(
        find.byKey(const ValueKey('turn-navigation-bar-110')),
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('turn-navigation-bar-110')))
            .width,
        7,
      );
      expect(
        (activeBar.decoration! as BoxDecoration).color,
        AppColors.textPrimary,
      );
    },
  );

  testWidgets(
    'ChatTimeline unscoped messages share their response in outline preview',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(980, 420));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        timeline([
          ChatMessage(role: ChatMessageRole.user, text: 'First request'),
          ChatMessage(role: ChatMessageRole.assistant, text: 'First response'),
          ChatMessage(role: ChatMessageRole.user, text: 'Second request'),
          ChatMessage(role: ChatMessageRole.assistant, text: 'Second response'),
        ]),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer();
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('turn-navigation-marker-0')),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('First request'), findsAtLeastNWidgets(1));
      expect(find.text('First response'), findsAtLeastNWidgets(1));
    },
  );

  testWidgets('ChatTimeline directly retargets the virtualized turn window', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(980, 520));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messages = <ChatMessage>[];
    for (var index = 0; index < 140; index++) {
      messages
        ..add(
          ChatMessage(
            role: ChatMessageRole.user,
            text: 'Retarget user request $index',
          ),
        )
        ..add(
          ChatMessage(
            role: ChatMessageRole.assistant,
            text:
                'Retarget agent response $index\n'
                '${index.isEven ? 'variable detail\n' * 6 : 'short'}',
          ),
        );
    }

    await tester.pumpWidget(timeline(messages));
    await tester.pumpAndSettle();

    final outline = tester.widget<ListView>(
      find.byKey(const ValueKey('turn-navigation-outline-list')),
    );
    final timelineController = timelineScrollController(tester);
    outline.controller!.jumpTo(20 * 16);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('turn-navigation-marker-20')));
    await tester.pump();
    expect(find.text('Retarget user request 20'), findsOneWidget);
    expect(timelineController.offset, moreOrLessEquals(0, epsilon: 0.5));

    outline.controller!.jumpTo(outline.controller!.position.maxScrollExtent);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('turn-navigation-marker-139')));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Retarget user request 139'), findsOneWidget);
    expect(find.text('Retarget user request 20'), findsNothing);
    expect(timelineController.offset, moreOrLessEquals(0, epsilon: 0.5));
  });

  testWidgets('ChatTimeline delegates image blocks without decoding in build', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxEmbeddedMediaBytes: 1,
      maxImageDimension: 2,
      maxImagePixels: 4,
      maxImagePreviewPixels: 4,
      maxImagePreviewPixelsGlobal: 4,
      maxImageDecodeBytesGlobal: 17,
    );
    final decoder = _RejectingImageDecoder();
    final ledger = AcpImageDecodeBudgetLedger(budget: budget);
    final message = ChatMessage(
      role: ChatMessageRole.assistant,
      text: 'image',
      metadata: const {
        'contentBlocks': [
          {'type': 'image', 'mimeType': 'image/png', 'data': 'YQ=='},
        ],
      },
    );

    await tester.pumpWidget(
      timeline(
        [message],
        inputBudget: budget,
        imageDecodeLedger: ledger,
        boundedImageDecoder: decoder,
      ),
    );
    expect(decoder.createBufferCalls, 0);

    await tester.pump();
    await tester.pump();
    expect(decoder.createBufferCalls, 1);
    expect(find.text('Image preview unavailable.'), findsOneWidget);
  });

  testWidgets('ChatTimeline places sent image thumbnails above user text', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.user,
      text: 'Please inspect this image',
      metadata: const {
        'contentBlocks': [
          {'type': 'image', 'mimeType': 'image/png', 'data': 'YQ=='},
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], boundedImageDecoder: _RejectingImageDecoder()),
    );
    await tester.pump();
    await tester.pump();

    final thumbnail = find.byKey(const ValueKey('inline-image-thumbnail'));
    expect(thumbnail, findsOneWidget);
    expect(
      tester.getTopLeft(thumbnail).dy,
      lessThan(tester.getTopLeft(find.text('Please inspect this image')).dy),
    );

    await tester.tap(thumbnail);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-preview-modal')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-preview-modal')), findsNothing);

    await tester.tap(thumbnail);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('image-preview-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-preview-modal')), findsNothing);
  });

  testWidgets('ChatTimeline renders ACP tool image content as viewed images', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'read_image',
      metadata: const {
        'toolCallId': 'image-1',
        'title': 'Read image',
        'status': 'completed',
        'content': [
          {
            'type': 'content',
            'content': {
              'type': 'image',
              'mimeType': 'image/png',
              'data': 'YQ==',
            },
          },
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], boundedImageDecoder: _RejectingImageDecoder()),
    );
    await tester.pump();

    expect(find.text('Viewed 1 image'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tool-image-activity-toggle')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('inline-image-thumbnail')), findsNothing);

    await tester.tap(find.text('Viewed 1 image'));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('inline-image-thumbnail')),
      findsOneWidget,
    );
  });

  testWidgets('ChatTimeline renders ACP tool diffs with file change counts', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_file',
      metadata: const {
        'toolCallId': 'diff-1',
        'title': 'Edit file',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'lib/example.dart',
            'oldText': 'first\nold value\nlast\n',
            'newText': 'first\nnew value\nlast\n',
          },
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], mediaQuerySize: const Size(800, 300)),
    );
    await tester.pumpAndSettle();

    expect(find.text('Edited 1 file'), findsOneWidget);
    expect(find.text('lib/example.dart'), findsOneWidget);
    expect(find.text('+1'), findsNWidgets(2));
    expect(find.text('-1'), findsNWidgets(2));
    expect(find.text('old value'), findsNothing);
    expect(find.text('new value'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('tool-diff-file-row-lib/example.dart')),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('tool-diff-hover-preview-lib/example.dart')),
      findsOneWidget,
    );
    expect(find.text('old value'), findsOneWidget);
    expect(find.text('new value'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 120));
    expect(find.text('old value'), findsNothing);
    expect(find.text('new value'), findsNothing);
  });

  testWidgets('ChatTimeline summarizes several edited files as one card', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_files',
      metadata: const {
        'toolCallId': 'diff-many',
        'title': 'Edit files',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'design-qa.md',
            'oldText': 'title\n',
            'newText': 'title\nresult\n',
          },
          {
            'type': 'diff',
            'path': 'lib/ui/components/chat_timeline.dart',
            'oldText': 'old\n',
            'newText': 'new\n',
          },
          {
            'type': 'diff',
            'path': 'test/ui/chat_timeline_test.dart',
            'oldText': '',
            'newText': 'first\nsecond\n',
          },
        ],
      },
    );

    await tester.pumpWidget(timeline([message]));
    await tester.pumpAndSettle();

    expect(find.text('Edited 3 files'), findsOneWidget);
    expect(find.text('design-qa.md'), findsOneWidget);
    expect(find.text('lib/ui/components/chat_timeline.dart'), findsOneWidget);
    expect(find.text('test/ui/chat_timeline_test.dart'), findsOneWidget);
    expect(find.text('+4'), findsOneWidget);
    expect(find.text('-1'), findsNWidgets(2));
  });

  testWidgets('ChatTimeline presents workspace diff paths relatively', (
    tester,
  ) async {
    final absolutePath =
        '${Directory.current.path}/lib/ui/components/chat_timeline.dart';
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_file',
      metadata: {
        'toolCallId': 'diff-relative-path',
        'title': 'Edit file',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': absolutePath,
            'oldText': 'old\n',
            'newText': 'new\n',
          },
        ],
      },
    );

    await tester.pumpWidget(timeline([message]));
    await tester.pumpAndSettle();

    expect(find.text('lib/ui/components/chat_timeline.dart'), findsOneWidget);
    expect(find.text(absolutePath), findsNothing);
    expect(
      tester
          .getSemantics(
            find.byKey(ValueKey('tool-diff-file-row-$absolutePath')),
          )
          .label,
      contains('Preview diff for lib/ui/components/chat_timeline.dart'),
    );
  });

  testWidgets('ChatTimeline opens a lower-half file preview upward', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 300));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_files',
      metadata: const {
        'toolCallId': 'diff-direction',
        'title': 'Edit files',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'lib/first.dart',
            'oldText': 'old\n',
            'newText': 'new\n',
          },
          {
            'type': 'diff',
            'path': 'lib/bottom.dart',
            'oldText': 'before\n',
            'newText': 'after\n',
          },
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], mediaQuerySize: const Size(800, 300)),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(
      const ValueKey('tool-diff-file-row-lib/bottom.dart'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    final preview = find.byKey(
      const ValueKey('tool-diff-hover-preview-lib/bottom.dart'),
    );
    expect(preview, findsOneWidget);
    expect(tester.getCenter(row).dy, greaterThan(150));
    final rowRect = tester.getRect(row);
    final previewRect = tester.getRect(preview);
    expect((previewRect.right - rowRect.right).abs(), lessThanOrEqualTo(1));
    expect((previewRect.left - rowRect.left - 40).abs(), lessThanOrEqualTo(1));
    expect(previewRect.bottom - rowRect.top, closeTo(8, 1));

    await mouse.moveTo(previewRect.center);
    await tester.pump(const Duration(milliseconds: 140));
    expect(preview, findsOneWidget);
    expect(
      tester
          .widget<Container>(
            find.byKey(
              const ValueKey('tool-diff-file-row-surface-lib/bottom.dart'),
            ),
          )
          .color,
      AppColors.surfaceRaised,
    );
  });

  testWidgets('ChatTimeline opens an upper-half file preview downward', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_file',
      metadata: const {
        'toolCallId': 'diff-upper-half',
        'title': 'Edit file',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'lib/upper.dart',
            'oldText': 'before\n',
            'newText': 'after\n',
          },
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], mediaQuerySize: const Size(800, 600)),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('tool-diff-file-row-lib/upper.dart'));
    expect(tester.getCenter(row).dy, lessThan(300));
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    final preview = find.byKey(
      const ValueKey('tool-diff-hover-preview-lib/upper.dart'),
    );
    expect(preview, findsOneWidget);
    final rowRect = tester.getRect(row);
    final previewRect = tester.getRect(preview);
    expect((previewRect.right - rowRect.right).abs(), lessThanOrEqualTo(1));
    expect((previewRect.left - rowRect.left - 40).abs(), lessThanOrEqualTo(1));
    expect(rowRect.bottom - previewRect.top, closeTo(8, 1));
  });

  testWidgets('ChatTimeline switches file hover color without a dark tail', (
    tester,
  ) async {
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_files',
      metadata: const {
        'toolCallId': 'diff-hover-color',
        'title': 'Edit files',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'lib/first.dart',
            'oldText': 'old\n',
            'newText': 'new\n',
          },
          {
            'type': 'diff',
            'path': 'lib/second.dart',
            'oldText': 'before\n',
            'newText': 'after\n',
          },
        ],
      },
    );

    await tester.pumpWidget(timeline([message]));
    await tester.pumpAndSettle();

    Container surface(String path) => tester.widget<Container>(
      find.byKey(ValueKey('tool-diff-file-row-surface-$path')),
    );
    final firstRow = find.byKey(
      const ValueKey('tool-diff-file-row-lib/first.dart'),
    );
    final secondRow = find.byKey(
      const ValueKey('tool-diff-file-row-lib/second.dart'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();

    await mouse.moveTo(tester.getCenter(firstRow));
    await tester.pump();
    expect(surface('lib/first.dart').color, AppColors.surfaceRaised);
    expect(surface('lib/second.dart').color, Colors.transparent);
    expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 120));
    expect(surface('lib/first.dart').color, Colors.transparent);
    expect(surface('lib/second.dart').color, Colors.transparent);

    await mouse.moveTo(tester.getCenter(secondRow));
    await tester.pump();
    expect(surface('lib/first.dart').color, Colors.transparent);
    expect(surface('lib/second.dart').color, AppColors.surfaceRaised);

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 120));
    expect(surface('lib/first.dart').color, Colors.transparent);
    expect(surface('lib/second.dart').color, Colors.transparent);
    expect(find.byIcon(Icons.visibility_outlined), findsNothing);
  });

  testWidgets('ChatTimeline keeps a tall hover preview inside the viewport', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 360));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final oldLines = List.generate(30, (index) => 'old line $index').join('\n');
    final newLines = List.generate(30, (index) => 'new line $index').join('\n');
    final message = ChatMessage(
      role: ChatMessageRole.tool,
      text: 'edit_file',
      metadata: {
        'toolCallId': 'diff-viewport',
        'title': 'Edit file',
        'status': 'completed',
        'content': [
          {
            'type': 'diff',
            'path': 'lib/viewport.dart',
            'oldText': oldLines,
            'newText': newLines,
          },
        ],
      },
    );

    await tester.pumpWidget(
      timeline([message], mediaQuerySize: const Size(800, 360)),
    );
    await tester.pumpAndSettle();

    final row = find.byKey(
      const ValueKey('tool-diff-file-row-lib/viewport.dart'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(row));
    await tester.pumpAndSettle();

    final preview = find.byKey(
      const ValueKey('tool-diff-hover-preview-lib/viewport.dart'),
    );
    expect(preview, findsOneWidget);
    final previewRect = tester.getRect(preview);
    expect(previewRect.top, greaterThanOrEqualTo(0));
    expect(previewRect.bottom, lessThanOrEqualTo(360));

    await mouse.moveTo(previewRect.center);
    await tester.pump(const Duration(milliseconds: 140));
    final scrollable = find.descendant(
      of: find.byKey(const ValueKey('tool-diff-lines-lib/viewport.dart')),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsOneWidget);
    await tester.drag(scrollable, const Offset(0, -80));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(scrollable).position.pixels,
      greaterThan(0),
    );
    expect(preview, findsOneWidget);
  });

  testWidgets(
    'ChatTimeline diff card matches accepted default and hover visuals',
    (tester) async {
      await tester.runAsync(_loadDiffGoldenFonts);
      debugPaintBaselinesEnabled = false;
      debugPaintPointersEnabled = false;
      debugPaintSizeEnabled = false;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final workspace = Directory.current.path;
      final messages = [
        ChatMessage(role: ChatMessageRole.user, text: 'Show the edited files'),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'edit_files',
          metadata: {
            'toolCallId': 'diff-golden',
            'title': 'Edit files',
            'status': 'completed',
            'content': [
              {
                'type': 'diff',
                'path': '$workspace/design-qa.md',
                'oldText': 'status: blocked\n',
                'newText': 'status: passed\nnotes: verified\n',
              },
              {
                'type': 'diff',
                'path': '$workspace/lib/ui/components/chat_timeline.dart',
                'oldText':
                    'child: Container(\n  width: 116,\n  color: oldColor,\n',
                'newText':
                    'child: Semantics(\n  label: displayPath,\n  color: hoverColor,\n',
              },
              {
                'type': 'diff',
                'path': '$workspace/test/ui/chat_timeline_test.dart',
                'oldText': '',
                'newText': 'expect(preview, findsOneWidget);\n',
              },
            ],
          },
        ),
      ];

      await tester.pumpWidget(
        timeline(
          messages,
          mediaQuerySize: const Size(1000, 600),
          theme: ThemeData(fontFamily: 'ACPTestSans'),
        ),
      );
      await tester.pumpAndSettle();

      final appOverlay = find.byType(Overlay).first;
      await expectLater(
        appOverlay,
        matchesGoldenFile(
          '../../design-qa-artifacts/file-diff-redesign-default.png',
        ),
      );

      debugPaintBaselinesEnabled = false;
      final row = find.byKey(
        ValueKey(
          'tool-diff-file-row-$workspace/lib/ui/components/chat_timeline.dart',
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(row));
      await tester.pumpAndSettle();

      await expectLater(
        appOverlay,
        matchesGoldenFile(
          '../../design-qa-artifacts/file-diff-redesign-hover.png',
        ),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets('ChatTimeline never builds MarkdownBody after syntax overflow', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMarkdownSyntaxTokens: 1,
      maxMarkdownFallbackBytes: 5,
    );
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.assistant, text: '**😀😀**'),
      ], inputBudget: budget),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.widgetWithText(SelectableText, '**'), findsOneWidget);
    expect(find.textContaining('markdown syntax tokens'), findsOneWidget);
  });

  testWidgets('ChatTimeline keeps MarkdownBody at the exact syntax limit', (
    tester,
  ) async {
    const budget = AcpInputBudget(maxMarkdownSyntaxTokens: 4);
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.assistant, text: '**safe**'),
      ], inputBudget: budget),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('markdown syntax tokens'), findsNothing);
  });

  testWidgets('ChatTimeline forwards Markdown link taps', (tester) async {
    String? tappedHref;
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: '[Open file](docs/readme.md#L4)',
        ),
      ], onTapLink: (text, href, title) => tappedHref = href),
    );

    await tester.tap(find.text('Open file'));

    expect(tappedHref, 'docs/readme.md#L4');
    expect(
      find.byKey(const ValueKey('markdown-file-reference')),
      findsOneWidget,
    );
  });

  testWidgets('ChatTimeline renders fenced code with the shared code block', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: '```dart\nfinal value = 1;\n```',
        ),
      ]),
    );

    expect(find.byType(MarkdownCodeBlock), findsOneWidget);
    expect(find.text('DART'), findsOneWidget);
    expect(find.byTooltip('复制代码'), findsOneWidget);
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    expect(markdown.styleSheet!.codeblockPadding, EdgeInsets.zero);
    final wrapperDecoration =
        markdown.styleSheet!.codeblockDecoration! as BoxDecoration;
    expect(wrapperDecoration.color, isNull);
    expect(wrapperDecoration.border, isNull);
  });

  testWidgets(
    'ChatTimeline markdown links and code block match accepted visuals',
    (tester) async {
      await tester.runAsync(_loadDiffGoldenFonts);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 600);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      await tester.pumpWidget(
        timeline(
          [
            ChatMessage(
              role: ChatMessageRole.assistant,
              text: '''右侧面板中的文件引用：
[file_preview_workspace.dart](lib/ui/components/file_preview_workspace.dart)、[workspace_inspector.dart](lib/ui/components/workspace_inspector.dart)。

最稳妥的处理是让边框最后绘制：

```dart
decoration: BoxDecoration(
  color: AppColors.surface,
  borderRadius: BorderRadius.circular(AppRadius.xl),
),
foregroundDecoration: BoxDecoration(
  border: Border.all(color: AppColors.border),
),
```''',
            ),
          ],
          mediaQuerySize: const Size(1000, 600),
          theme: ThemeData(fontFamily: 'ACPTestSans'),
        ),
      );
      await tester.pumpAndSettle();

      await expectLater(
        find.byType(Overlay).first,
        matchesGoldenFile(
          '../../design-qa-artifacts/markdown-rendering-polish.png',
        ),
      );
    },
    skip: !Platform.isMacOS,
  );

  testWidgets('ChatTimeline displays one typed notice per omission kind', (
    tester,
  ) async {
    const budget = AcpInputBudget(maxMarkdownSyntaxTokens: 1);
    final omission = AcpInputOmission(
      reason: AcpInputOmissionReason.inputLimit,
      resource: 'markdown syntax tokens',
      truncated: true,
      limit: 1,
      observedAtLeast: 2,
    );
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: '**safe**',
          omissions: [omission],
        ),
      ], inputBudget: budget),
    );

    expect(find.textContaining('markdown syntax tokens'), findsOneWidget);
  });

  testWidgets('ChatTimeline bounds tool metadata after expansion', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMetadataPreviewChars: 20,
      maxMetadataPreviewBytes: 12,
    );
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'bounded-metadata',
            'title': 'exec_command',
            'status': 'completed',
            'rawInput': {'secret': 'TOOL_METADATA_CANARY'},
          },
        ),
      ], inputBudget: budget),
    );

    expect(find.textContaining('TOOL_METADATA_CANARY'), findsNothing);
    await tester.tap(
      find.byKey(const ValueKey('tool-activity-toggle-bounded-metadata')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('TOOL_METADATA_CANARY'), findsNothing);
    expect(find.textContaining('metadata preview bytes'), findsOneWidget);
  });

  testWidgets('ChatTimeline caches expanded metadata by real revisions', (
    tester,
  ) async {
    final first = _CountingPreviewMap('first');
    final second = _CountingPreviewMap('second');
    final metadata = <String, Object?>{
      'toolCallId': 'cached-metadata',
      'title': 'exec_command',
      'status': 'completed',
      'rawInput': first,
    };
    final message = _TestChatMessage(
      role: ChatMessageRole.tool,
      text: 'exec_command',
      metadata: metadata,
    );
    var listRevision = 0;
    AcpInputBudget budget = const AcpInputBudget();
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(
              body: ChatTimeline(
                messages: [message],
                messageListRevision: listRevision,
                inputBudget: budget,
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey('tool-activity-toggle-cached-metadata')),
    );
    await tester.pumpAndSettle();
    expect(first.entriesReads, 1);

    rebuild(() {});
    await tester.pump();
    expect(first.entriesReads, 1);

    rebuild(() => message.revision += 1);
    await tester.pump();
    expect(first.entriesReads, 2);

    rebuild(() => listRevision += 1);
    await tester.pump();
    expect(first.entriesReads, 2);

    rebuild(() => metadata['rawInput'] = second);
    await tester.pump();
    expect(first.entriesReads, 2);
    expect(second.entriesReads, 1);

    rebuild(
      () => budget = const AcpInputBudget(
        maxMetadataPreviewChars: 7,
        maxMetadataPreviewBytes: 9,
      ),
    );
    await tester.pump();
    expect(second.entriesReads, 2);
  });

  testWidgets('ChatTimeline preserves unknown payload identity for cache', (
    tester,
  ) async {
    final block = _CountingPreviewMap.fromValues(<String, Object?>{
      'type': 'mystery',
      'value': 'UNKNOWN_CANARY',
    });
    final metadata = <String, Object?>{
      'contentBlocks': <Object?>[block],
    };
    final message = _TestChatMessage(
      role: ChatMessageRole.assistant,
      text: '',
      metadata: metadata,
    );
    late StateSetter rebuild;

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            rebuild = setState;
            return Scaffold(body: ChatTimeline(messages: [message]));
          },
        ),
      ),
    );
    await tester.pump();
    expect(block.entriesReads, 1);

    rebuild(() {});
    await tester.pump();
    expect(block.entriesReads, 1);

    rebuild(() => message.revision += 1);
    await tester.pump();
    await tester.pump();
    expect(block.entriesReads, 2);
  });

  testWidgets('ChatTimeline empty state exposes primary new session action', (
    tester,
  ) async {
    var starts = 0;
    await tester.pumpWidget(
      timeline(
        const [],
        onNewSession: () {
          starts += 1;
        },
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'New Session'));
    await tester.pump();

    expect(starts, 1);
  });

  testWidgets('ChatTimeline preserves a disabled compact session affordance', (
    tester,
  ) async {
    await tester.pumpWidget(timeline(const [], showNewSessionAction: true));

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'New Session'),
    );
    expect(button.onPressed, isNull);
    expect(
      find.byTooltip('New session is temporarily unavailable'),
      findsOneWidget,
    );
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

  testWidgets('ChatTimeline empty state reflects active resumed session', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline(
        const [],
        hasActiveSession: true,
        activeSessionLabel: 'Implement attachment flow',
      ),
    );

    expect(find.text('Session ready'), findsOneWidget);
    expect(
      find.textContaining('Implement attachment flow loaded.'),
      findsOneWidget,
    );
    expect(find.text('Start a session to chat with Codex'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'New Session'), findsNothing);
  });

  testWidgets('ChatTimeline shows loading state while session replay loads', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline(
        const [],
        hasActiveSession: true,
        activeSessionLabel: 'Implement attachment flow',
        isLoadingSession: true,
      ),
    );

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Loading session'), findsOneWidget);
    expect(
      find.textContaining('Loading Implement attachment flow.'),
      findsOneWidget,
    );
    expect(find.text('Session ready'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'New Session'), findsNothing);
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

    expect(find.text('User'), findsNothing);
    expect(find.text('Agent'), findsNothing);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('Hello, human.'), findsOneWidget);
  });

  testWidgets('ChatTimeline gives user message selections contrast', (
    tester,
  ) async {
    final appSelectionColor = AppColors.primary.withValues(alpha: 0.18);
    const userSelectionColor = Color(0x3d000000);

    await tester.pumpWidget(
      timeline(
        [
          ChatMessage(role: ChatMessageRole.user, text: 'Pick this text'),
          ChatMessage(role: ChatMessageRole.assistant, text: 'Keep default'),
        ],
        theme: ThemeData(
          textSelectionTheme: TextSelectionThemeData(
            selectionColor: appSelectionColor,
          ),
        ),
      ),
    );

    final userMarkdown = find.byWidgetPredicate(
      (widget) => widget is MarkdownBody && widget.data == 'Pick this text',
    );
    final assistantMarkdown = find.byWidgetPredicate(
      (widget) => widget is MarkdownBody && widget.data == 'Keep default',
    );

    expect(
      TextSelectionTheme.of(tester.element(userMarkdown)).selectionColor,
      userSelectionColor,
    );
    expect(
      DefaultSelectionStyle.of(tester.element(userMarkdown)).selectionColor,
      userSelectionColor,
    );
    expect(
      TextSelectionTheme.of(tester.element(assistantMarkdown)).selectionColor,
      appSelectionColor,
    );
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

    expect(find.text('Agent'), findsNothing);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Hello, I am Codex.'), findsOneWidget);
  });

  testWidgets('ChatTimeline blocks remote and local markdown image IO', (
    tester,
  ) async {
    String? copiedText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final arguments = call.arguments as Map<Object?, Object?>;
          copiedText = arguments['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: [
            '![remote](https://images.example.com/pixel.png)',
            '![local](file:///tmp/private.png)',
            '![inline](data:image/png;base64,AAAA)',
            '![unknown](custom+image://asset/icon.png)',
          ].join('\n\n'),
        ),
      ]),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Image blocked'), findsNWidgets(4));
    expect(find.textContaining('images.example.com'), findsOneWidget);
    expect(find.textContaining('file'), findsOneWidget);
    expect(find.textContaining('data'), findsOneWidget);
    expect(find.textContaining('custom+image'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy blocked image link').first);
    await tester.pump();
    expect(copiedText, 'https://images.example.com/pixel.png');
  });

  testWidgets('ChatTimeline keeps ordinary markdown links on the link path', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: '[Open docs](https://example.com/docs)',
        ),
      ]),
    );

    expect(find.byType(Image), findsNothing);
    expect(find.textContaining('Image blocked'), findsNothing);
    expect(find.text('Open docs'), findsOneWidget);

    await tester.tap(find.text('Open docs'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'ChatTimeline keeps scroll position pinned to bottom on updates',
    (tester) async {
      final messages = List<ChatMessage>.generate(
        20,
        (index) => ChatMessage(
          role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
          text: 'Message $index\n${List.filled(4, 'line').join('\n')}',
        ),
      );

      Widget constrainedTimeline() {
        return MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 240,
              child: ChatTimeline(messages: messages),
            ),
          ),
        );
      }

      await tester.pumpWidget(constrainedTimeline());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      ScrollPosition timelinePosition() {
        return timelineScrollController(tester).position;
      }

      var position = timelinePosition();
      expect(position.maxScrollExtent, greaterThan(0));
      expect(position.pixels, moreOrLessEquals(position.maxScrollExtent));

      messages.last.text +=
          '\n${List.filled(20, 'streaming output').join('\n')}';
      await tester.pumpWidget(constrainedTimeline());
      await tester.pump();
      await tester.pump();
      await tester.pump();

      position = timelinePosition();
      expect(position.pixels, moreOrLessEquals(position.maxScrollExtent));
    },
  );

  testWidgets('ChatTimeline keeps scroll pinned when metadata changes', (
    tester,
  ) async {
    final messages = List<ChatMessage>.generate(
      18,
      (index) => ChatMessage(
        role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
        text: 'Message $index\n${List.filled(3, 'line').join('\n')}',
      ),
    );
    messages.add(
      ChatMessage(
        role: ChatMessageRole.status,
        text: 'Implementation plan',
        metadata: const {
          'kind': 'plan',
          'title': 'Implementation plan',
          'entries': [
            {
              'content': 'Initial check',
              'priority': 'medium',
              'status': 'in_progress',
            },
          ],
        },
      ),
    );

    Widget constrainedTimeline() {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 240,
            child: ChatTimeline(messages: messages),
          ),
        ),
      );
    }

    await tester.pumpWidget(constrainedTimeline());
    await tester.pump();
    await tester.pump();
    await tester.pump();

    ScrollPosition timelinePosition() {
      return timelineScrollController(tester).position;
    }

    var position = timelinePosition();
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent));

    messages[messages.length - 1] = ChatMessage(
      role: ChatMessageRole.status,
      text: 'Implementation plan',
      metadata: {
        'kind': 'plan',
        'title': 'Implementation plan',
        'entries': [
          for (var index = 0; index < 24; index++)
            {
              'content': 'Follow-up item $index',
              'priority': index.isEven ? 'high' : 'medium',
              'status': index.isEven ? 'completed' : 'in_progress',
            },
        ],
      },
    );
    await tester.pumpWidget(constrainedTimeline());
    await tester.pump();
    await tester.pump();
    await tester.pump();

    position = timelinePosition();
    expect(position.pixels, moreOrLessEquals(position.maxScrollExtent));
  });

  testWidgets(
    'ChatTimeline refreshes same-length replace and reorder by list revision',
    (tester) async {
      final messages = List<ChatMessage>.generate(
        24,
        (index) => ChatMessage(
          role: index.isEven ? ChatMessageRole.user : ChatMessageRole.assistant,
          text: 'Message $index\n${List.filled(3, 'line').join('\n')}',
        ),
      );
      var listRevision = 0;

      Widget constrainedTimeline() {
        return MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 420,
              height: 240,
              child: ChatTimeline(
                messages: messages,
                messageListRevision: listRevision,
              ),
            ),
          ),
        );
      }

      await tester.pumpWidget(constrainedTimeline());
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final controller = timelineScrollController(tester);
      controller.jumpTo(0);

      messages[messages.length - 1] = ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'Replacement\n${List.filled(20, 'tall').join('\n')}',
      );
      listRevision += 1;
      await tester.pumpWidget(constrainedTimeline());
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        controller.position.pixels,
        moreOrLessEquals(controller.position.maxScrollExtent),
      );

      controller.jumpTo(0);
      final first = messages.removeAt(0);
      messages.add(first);
      listRevision += 1;
      await tester.pumpWidget(constrainedTimeline());
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(
        controller.position.pixels,
        moreOrLessEquals(controller.position.maxScrollExtent),
      );
    },
  );

  testWidgets('ChatTimeline lazily keeps complete large histories', (
    tester,
  ) async {
    final messages = List<ChatMessage>.generate(
      260,
      (index) => ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'Large history message $index',
      ),
    );

    await tester.pumpWidget(timeline(messages));
    await tester.pumpAndSettle();

    expect(find.textContaining('Showing latest'), findsNothing);
    final controller = timelineScrollController(tester);
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(find.text('Large history message 0'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders error card', (tester) async {
    await tester.pumpWidget(
      timeline([ChatMessage(role: ChatMessageRole.error, text: 'boom')]),
    );

    expect(find.text('Error'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });

  testWidgets('ChatTimeline renders compact single-tool rows', (tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(799, 599));
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

    expect(find.text('Ran flutter test'), findsOneWidget);
    expect(find.text('All tests passed.'), findsNothing);
    var chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-activity-chevron-opacity-call-1')),
    );
    expect(chevronOpacity.opacity, 0);

    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const ValueKey('tool-activity-toggle-call-1')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('All tests passed.'), findsNothing);
    chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-activity-chevron-opacity-call-1')),
    );
    expect(chevronOpacity.opacity, 1);

    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();

    expect(find.text('All tests passed.'), findsOneWidget);
  });

  testWidgets('ChatTimeline folds thought with one adjacent tool', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.user,
          text: 'Wait for the background check',
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'wait',
          metadata: const {
            'toolCallId': 'wait-1',
            'title': 'wait',
            'status': 'completed',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'Assessing the background result.',
          metadata: const {'kind': 'thought'},
        ),
      ]),
    );

    expect(find.text('Waited for background work'), findsOneWidget);
    expect(find.text('Assessing the background result.'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-call-group-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Assessing the background result.'), findsOneWidget);
    expect(find.text('Waited for background work'), findsNWidgets(2));
  });

  testWidgets('ChatTimeline bounds long tool output with scroll edge fades', (
    tester,
  ) async {
    final output = List<String>.generate(
      80,
      (index) => 'output line $index',
    ).join('\n');
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: {
            'toolCallId': 'long-output',
            'title': 'exec_command',
            'status': 'completed',
            'rawOutput': output,
          },
        ),
      ]),
    );

    await tester.tap(
      find.byKey(const ValueKey('tool-activity-toggle-long-output')),
    );
    await tester.pumpAndSettle();

    final region = find.byKey(const ValueKey('metadata-scroll-region-output'));
    expect(region, findsOneWidget);
    expect(tester.getSize(region).height, lessThanOrEqualTo(260));
    final fades = find.descendant(
      of: region,
      matching: find.byType(AnimatedOpacity),
    );
    expect(tester.widget<AnimatedOpacity>(fades.first).opacity, 0);
    expect(tester.widget<AnimatedOpacity>(fades.last).opacity, 1);

    final scrollView = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: region,
        matching: find.byKey(const ValueKey('scroll-fade-scroll-view')),
      ),
    );
    scrollView.controller!.jumpTo(
      scrollView.controller!.position.maxScrollExtent,
    );
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedOpacity>(fades.first).opacity, 1);
    expect(tester.widget<AnimatedOpacity>(fades.last).opacity, 0);
  });

  testWidgets('ChatTimeline does not truncate structured command output', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMetadataPreviewChars: 20,
      maxMetadataPreviewBytes: 20,
    );
    const finalLine = 'FINAL_OUTPUT_LINE_MUST_REMAIN_VISIBLE';
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'wait',
          metadata: const {
            'toolCallId': 'structured-output',
            'title': 'wait',
            'status': 'completed',
            'rawOutput': {
              'output': [
                {'type': 'input_text', 'text': 'first line\n$finalLine'},
              ],
            },
          },
        ),
      ], inputBudget: budget),
    );

    await tester.tap(
      find.byKey(const ValueKey('tool-activity-toggle-structured-output')),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining(finalLine), findsOneWidget);
    expect(find.textContaining('metadata preview chars'), findsNothing);
    expect(find.textContaining('Content omitted'), findsNothing);
  });

  testWidgets('ChatTimeline tool group has default hover and expanded states', (
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
            'rawOutput': 'workspace ready',
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

    expect(find.text('Ran commands and searched'), findsOneWidget);
    expect(find.text('exec_command'), findsNothing);
    expect(find.text('web_search'), findsNothing);
    expect(find.text('call-1'), findsNothing);
    var summaryStyle = tester.widget<AnimatedDefaultTextStyle>(
      find.byKey(const ValueKey('tool-call-group-summary')),
    );
    var chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-call-group-chevron-opacity')),
    );
    expect(summaryStyle.style.color, AppColors.textSecondary);
    expect(chevronOpacity.opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('tool-call-group-toggle'))),
    );
    await tester.pumpAndSettle();
    summaryStyle = tester.widget<AnimatedDefaultTextStyle>(
      find.byKey(const ValueKey('tool-call-group-summary')),
    );
    chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-call-group-chevron-opacity')),
    );
    expect(summaryStyle.style.color, AppColors.textPrimary);
    expect(chevronOpacity.opacity, 1);
    expect(
      find.byKey(const ValueKey('tool-call-group-details-collapsed')),
      findsOneWidget,
    );
    expect(find.text('Ran pwd'), findsNothing);

    final groupToggle = tester.getSemantics(
      find.byKey(const ValueKey('tool-call-group-toggle')),
    );
    expect(
      groupToggle.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(find.text('Ran commands and searched'));
    await tester.pumpAndSettle();

    summaryStyle = tester.widget<AnimatedDefaultTextStyle>(
      find.byKey(const ValueKey('tool-call-group-summary')),
    );
    chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-call-group-chevron-opacity')),
    );
    final chevron = tester.widget<AnimatedRotation>(
      find.byKey(const ValueKey('tool-call-group-chevron')),
    );
    expect(summaryStyle.style.color, AppColors.textSecondary);
    expect(chevronOpacity.opacity, 1);
    expect(chevron.turns, 0.25);
    expect(
      find.byKey(const ValueKey('tool-call-group-details')),
      findsOneWidget,
    );
    expect(find.text('call-1'), findsNothing);
    expect(find.text('exec_command'), findsNothing);
    expect(find.text('web_search'), findsNothing);
    expect(find.text('Ran pwd'), findsOneWidget);
    expect(find.text('Ran ls'), findsOneWidget);
    expect(find.text('Searched flutter ExpansionTile'), findsOneWidget);
    expect(find.text('workspace ready'), findsNothing);

    final activitySemantics = tester.getSemantics(
      find.byKey(const ValueKey('tool-activity-toggle-call-1')),
    );
    expect(
      activitySemantics.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );
    var activityChevron = tester.widget<AnimatedRotation>(
      find.byKey(const ValueKey('tool-activity-chevron-call-1')),
    );
    expect(activityChevron.turns, 0);

    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('tool-activity-details-call-1')),
      findsOneWidget,
    );
    expect(find.text('workspace ready'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('Input'), findsOneWidget);
    activityChevron = tester.widget<AnimatedRotation>(
      find.byKey(const ValueKey('tool-activity-chevron-call-1')),
    );
    expect(activityChevron.turns, 0.25);

    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();

    expect(find.text('workspace ready'), findsNothing);
    expect(
      find.byKey(const ValueKey('tool-activity-details-collapsed-call-1')),
      findsOneWidget,
    );
  });

  testWidgets('ChatTimeline folds adjacent thinking into the tool group', (
    tester,
  ) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: const Offset(799, 599));
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Check the timeline'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'read_file',
        metadata: const {
          'toolCallId': 'call-1',
          'title': 'read_file',
          'status': 'completed',
          'rawInput': {'path': '/tmp/chat_timeline.dart'},
        },
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text: 'Inspecting the implementation.',
        metadata: const {'kind': 'thought'},
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'exec_command',
        metadata: const {
          'toolCallId': 'call-2',
          'title': 'exec_command',
          'status': 'completed',
          'rawInput': {'cmd': 'flutter test'},
        },
      ),
    );
    await tester.pumpWidget(timeline(controller.messages));

    expect(find.text('Inspecting the implementation.'), findsNothing);
    expect(find.text('Read files and ran commands'), findsOneWidget);

    await mouse.moveTo(
      tester.getCenter(find.byKey(const ValueKey('tool-call-group-toggle'))),
    );
    await tester.pumpAndSettle();

    expect(find.text('Inspecting the implementation.'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-call-group-toggle')));
    await tester.pumpAndSettle();

    expect(find.text('Thought'), findsOneWidget);
    expect(find.text('Inspecting the implementation.'), findsOneWidget);
    expect(find.text('Read chat_timeline.dart'), findsOneWidget);
    expect(find.text('Ran flutter test'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Read chat_timeline.dart')).dy,
      lessThan(
        tester.getTopLeft(find.text('Inspecting the implementation.')).dy,
      ),
    );
    expect(
      tester.getTopLeft(find.text('Inspecting the implementation.')).dy,
      lessThan(tester.getTopLeft(find.text('Ran flutter test')).dy),
    );

    await mouse.moveTo(const Offset(799, 599));
    await tester.pumpAndSettle();

    expect(find.text('Inspecting the implementation.'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('tool-call-group-details')),
      findsOneWidget,
    );
    final chevronOpacity = tester.widget<AnimatedOpacity>(
      find.byKey(const ValueKey('tool-call-group-chevron-opacity')),
    );
    expect(chevronOpacity.opacity, 0);
  });

  testWidgets('ChatTimeline keeps assistant commentary outside tool groups', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Inspect the timeline'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'read_file',
        metadata: const {
          'toolCallId': 'read-1',
          'title': 'read_file',
          'status': 'completed',
        },
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'read_file',
        metadata: const {
          'toolCallId': 'read-2',
          'title': 'read_file',
          'status': 'completed',
        },
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.assistant,
        text: 'Now I will edit the implementation.',
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'apply_patch',
        metadata: const {
          'toolCallId': 'edit-1',
          'title': 'apply_patch',
          'status': 'completed',
        },
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'exec_command',
        metadata: const {
          'toolCallId': 'run-1',
          'title': 'exec_command',
          'status': 'completed',
        },
      ),
    );
    await tester.pumpWidget(timeline(controller.messages));

    expect(find.text('Read files'), findsOneWidget);
    expect(find.text('Edited files and ran commands'), findsOneWidget);
    expect(find.text('Now I will edit the implementation.'), findsOneWidget);
    expect(find.text('Thought'), findsNothing);
    expect(
      find.byKey(const ValueKey('tool-call-group-toggle')),
      findsNWidgets(2),
    );
  });

  testWidgets('ChatTimeline preserves soft line breaks in user prompts', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.user, text: 'hover\n展开\n默认'),
      ]),
    );

    expect(find.text('hover\n展开\n默认'), findsOneWidget);
  });

  testWidgets('ChatTimeline projects text image markers as thumbnails', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.user,
          text: '''hover
展开
默认

[@codex-clipboard-reference.png](file:///tmp/reference.png)[@image](/tmp/reference.png)''',
        ),
      ]),
    );
    await tester.pump();

    expect(find.byKey(const ValueKey('text-image-thumbnails')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    final thumbnailImage = tester.widget<Image>(find.byType(Image));
    final thumbnailProvider = thumbnailImage.image as ResizeImage;
    expect(thumbnailProvider.policy, ResizeImagePolicy.fit);
    expect(thumbnailProvider.width, 232);
    expect(thumbnailProvider.height, 232);
    expect(find.text('hover\n展开\n默认'), findsOneWidget);
    expect(find.textContaining('codex-clipboard-reference'), findsNothing);
    expect(find.textContaining('[@image]'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('text-image-thumbnail:/tmp/reference.png')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('image-preview-modal')), findsOneWidget);
    final modalImage = tester.widget<Image>(
      find.descendant(
        of: find.byKey(const ValueKey('image-preview-modal')),
        matching: find.byType(Image),
      ),
    );
    final modalProvider = modalImage.image as ResizeImage;
    expect(modalProvider.policy, ResizeImagePolicy.fit);
    expect(modalProvider.width, 2400);
    expect(modalProvider.height, 1600);
  });

  testWidgets('ChatTimeline preserves tool disclosure state across streaming', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Run checks'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'exec_command',
        metadata: const {
          'toolCallId': 'call-1',
          'title': 'exec_command',
          'status': 'in_progress',
          'rawInput': {'cmd': 'flutter test'},
          'rawOutput': 'starting',
        },
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'read_file',
        metadata: const {
          'toolCallId': 'call-2',
          'title': 'read_file',
          'status': 'completed',
          'rawInput': {'path': '/tmp/result.txt'},
        },
      ),
    );
    await tester.pumpWidget(timeline(controller.messages));

    await tester.tap(find.byKey(const ValueKey('tool-call-group-toggle')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();
    expect(find.text('starting'), findsOneWidget);

    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.status,
        text: 'Checking the streamed result.',
        metadata: const {'kind': 'thought'},
      ),
    );
    controller.addMessageForTesting(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: 'exec_command',
        metadata: const {
          'toolCallId': 'call-1',
          'title': 'exec_command',
          'status': 'completed',
          'rawOutput': 'finished',
        },
      ),
    );
    await tester.pumpWidget(
      timeline(controller.messages, messageListRevision: 1),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('tool-call-group-details')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('tool-activity-details-call-1')),
      findsOneWidget,
    );
    expect(find.text('finished'), findsOneWidget);
    expect(find.text('Checking the streamed result.'), findsOneWidget);
  });

  testWidgets('ChatTimeline tool groups do not count failures as pending', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'exec_command',
            'status': 'completed',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'web_search',
          metadata: const {
            'toolCallId': 'call-2',
            'title': 'web_search',
            'status': 'failed',
          },
        ),
      ]),
    );

    expect(find.text('Ran commands and searched'), findsOneWidget);
    expect(find.text('1 failed'), findsOneWidget);
    expect(find.text('1 pending'), findsNothing);
  });

  testWidgets('ChatTimeline summarizes mixed tool activities naturally', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'load_skill',
          metadata: const {
            'toolCallId': 'call-load',
            'title': 'load_skill',
            'status': 'completed',
            'rawInput': {'name': 'product-design'},
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'read_file',
          metadata: const {
            'toolCallId': 'call-read',
            'title': 'read_file',
            'status': 'completed',
            'rawInput': {'path': '/tmp/chat_timeline.dart'},
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'apply_patch',
          metadata: const {
            'toolCallId': 'call-edit',
            'title': 'apply_patch',
            'status': 'completed',
            'rawInput': '*** Update File: lib/ui/chat_timeline_test.dart',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'exec_command',
          metadata: const {
            'toolCallId': 'call-run',
            'title': 'exec_command',
            'status': 'completed',
            'rawInput': {'cmd': 'flutter test --no-pub'},
          },
        ),
      ]),
    );

    expect(
      find.text('Loaded tools, edited files, read files, and ran commands'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);

    await tester.tap(
      find.text('Loaded tools, edited files, read files, and ran commands'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Loaded product-design'), findsOneWidget);
    expect(find.text('Read chat_timeline.dart'), findsOneWidget);
    expect(find.text('Edited chat_timeline_test.dart'), findsOneWidget);
    expect(find.text('Ran flutter test --no-pub'), findsOneWidget);
  });

  testWidgets('ChatTimeline uses patterned summaries for support tools', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        for (final title in ['mcp.node_repl.js', 'wait', 'Context compacted'])
          ChatMessage(
            role: ChatMessageRole.tool,
            text: title,
            metadata: {
              'toolCallId': 'call-$title',
              'title': title,
              'status': 'completed',
            },
          ),
      ]),
    );

    expect(
      find.text(
        'Controlled the app, waited for background work, and compacted context',
      ),
      findsOneWidget,
    );
  });

  testWidgets('ChatTimeline tool groups surface in-progress work', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'Bash',
            'status': 'inProgress',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'web_search',
          metadata: const {
            'toolCallId': 'call-2',
            'title': 'web_search',
            'status': 'completed',
          },
        ),
      ]),
    );

    expect(find.text('Ran commands and searched'), findsOneWidget);
    expect(find.text('1 in progress'), findsOneWidget);
    expect(find.text('1 pending'), findsNothing);
  });

  testWidgets('ChatTimeline coalesces tool call chunks by call id', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.assistant, text: 'Running command.'),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'Bash',
            'status': 'pending',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'Bash',
            'status': 'in_progress',
            'rawInput': '{"command"',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'toolCallId': 'call-1',
            'title': 'Bash',
            'status': 'completed',
            'rawInput': {'command': 'echo hi'},
            'rawOutput': 'hi',
          },
        ),
      ]),
    );

    expect(find.text('3 tool calls'), findsNothing);
    expect(find.text('Ran echo hi'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();

    expect(find.text('call-1'), findsOneWidget);
    expect(find.textContaining('echo hi'), findsNWidgets(2));
    expect(find.text('hi'), findsOneWidget);
    expect(find.text('{"command"'), findsNothing);
  });

  testWidgets('ChatTimeline coalesces tool call chunks by id aliases', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(role: ChatMessageRole.assistant, text: 'Running command.'),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'id': 'call-1',
            'title': 'Bash',
            'status': 'pending',
          },
        ),
        ChatMessage(
          role: ChatMessageRole.tool,
          text: 'Bash',
          metadata: const {
            'call_id': 'call-1',
            'title': 'Bash',
            'status': 'completed',
            'rawOutput': 'hi',
          },
        ),
      ]),
    );

    expect(find.text('2 tool calls'), findsNothing);
    expect(find.text('Ran Bash'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('tool-activity-toggle-call-1')));
    await tester.pumpAndSettle();

    expect(find.text('call-1'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets(
    'ChatTimeline coalesces tool call chunks by snake case id alias',
    (tester) async {
      await tester.pumpWidget(
        timeline([
          ChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Running command.',
          ),
          ChatMessage(
            role: ChatMessageRole.tool,
            text: 'Bash',
            metadata: const {
              'tool_call_id': 'call-1',
              'title': 'Bash',
              'status': 'pending',
            },
          ),
          ChatMessage(
            role: ChatMessageRole.tool,
            text: 'Bash',
            metadata: const {
              'tool_call_id': 'call-1',
              'title': 'Bash',
              'status': 'completed',
              'raw_input': {'command': 'echo hi'},
              'raw_output': 'hi',
            },
          ),
        ]),
      );

      expect(find.text('2 tool calls'), findsNothing);
      expect(find.text('Ran echo hi'), findsOneWidget);
      expect(find.text('call-1'), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey('tool-activity-toggle-call-1')),
      );
      await tester.pumpAndSettle();

      expect(find.text('call-1'), findsOneWidget);
      expect(find.textContaining('echo hi'), findsNWidgets(2));
      expect(find.text('hi'), findsOneWidget);
    },
  );

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

  testWidgets('ChatTimeline keeps plan entries readable in narrow widths', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 140,
            height: 360,
            child: ChatTimeline(
              messages: [
                ChatMessage(
                  role: ChatMessageRole.status,
                  text: 'Implementation plan',
                  metadata: const {
                    'kind': 'plan',
                    'title': 'Implementation plan',
                    'entries': [
                      {
                        'content': 'Check prompt composer states and review',
                        'priority': 'high',
                        'status': 'in_progress',
                      },
                    ],
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(
      find.text('Check prompt composer states and review'),
      findsOneWidget,
    );
    expect(find.text('High'), findsOneWidget);
  });

  testWidgets('ChatTimeline normalizes plan entry status icons', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'Implementation plan',
          metadata: const {
            'kind': 'plan',
            'entries': [
              {
                'content': 'Run active command',
                'priority': 'medium',
                'status': 'inProgress',
              },
              {
                'content': 'Handle failed check',
                'priority': 'high',
                'status': 'rejected',
              },
              {
                'content': 'Skip stale task',
                'priority': 'low',
                'status': 'canceled',
              },
            ],
          },
        ),
      ]),
    );

    expect(find.byIcon(Icons.play_circle_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
    expect(find.byIcon(Icons.cancel_outlined), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked_rounded), findsNothing);
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

  testWidgets('ChatTimeline separates streamed thought summaries', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: '**Inspecting layout****Refining spacing**',
          metadata: const {'kind': 'thought'},
        ),
      ]),
    );

    expect(find.text('Inspecting layout · Refining spacing'), findsOneWidget);
    expect(find.textContaining('****'), findsNothing);
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
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Embedded resource.',
          metadata: const {
            'contentBlocks': [
              {
                'type': 'resource',
                'resource': {
                  'uri': 'file:///workspace/README.md',
                  'mimeType': 'text/markdown',
                  'text': '# Project notes',
                },
              },
            ],
          },
        ),
        ChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Audio content.',
          metadata: const {
            'contentBlocks': [
              {'type': 'audio', 'mimeType': 'audio/wav', 'data': 'YXVkaW8='},
            ],
          },
        ),
      ]),
    );
    await tester.pump();

    expect(find.text('Attached context.'), findsOneWidget);
    expect(find.text('main.dart'), findsOneWidget);
    expect(find.text('text/x-dart'), findsOneWidget);
    expect(find.text('file:///workspace/lib/main.dart'), findsOneWidget);
    expect(find.text('Embedded resource.'), findsOneWidget);
    expect(find.text('README.md'), findsOneWidget);
    expect(find.textContaining('text/markdown'), findsOneWidget);
    expect(find.text('file:///workspace/README.md'), findsOneWidget);
    expect(find.text('# Project notes'), findsOneWidget);
    expect(find.text('Audio content.'), findsOneWidget);
    expect(find.text('Audio'), findsOneWidget);
    expect(find.text('audio/wav · 8 chars'), findsOneWidget);
  });

  testWidgets('ChatTimeline builds only visible content block items', (
    tester,
  ) async {
    final blocks = _CountingList<_FieldReadCountingMap>(
      List<_FieldReadCountingMap>.generate(
        1024,
        (index) => _FieldReadCountingMap({
          'type': 'resource_link',
          'title': 'resource-$index',
          'uri': 'file:///workspace/resource-$index',
        }),
      ),
    );

    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Attached resources.',
          metadata: {'contentBlocks': blocks},
        ),
      ]),
    );
    await tester.pump();

    expect(
      blocks.values.fold<int>(0, (total, block) => total + block.fieldReads),
      lessThan(128),
    );
    expect(blocks.itemReads, lessThan(128));
    final listFinder = find.byKey(const ValueKey('content-blocks-list'));
    expect(listFinder, findsOneWidget);
    final list = tester.widget<ListView>(listFinder);
    expect(list.primary, isFalse);
    expect(list.shrinkWrap, isFalse);
    expect(tester.getSize(listFinder).height, lessThanOrEqualTo(320));
  });

  testWidgets(
    'ChatTimeline pauses non-text projection until exact load more action',
    (tester) async {
      final blocks = _CountingList<_FieldReadCountingMap>(
        List<_FieldReadCountingMap>.generate(
          1024,
          (index) => _FieldReadCountingMap({
            'type': 'resource_link',
            'title': 'resource-$index',
            'uri': 'file:///workspace/resource-$index',
          }),
        ),
      );

      await tester.pumpWidget(
        timeline([
          _TestChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Many resources.',
            metadata: {'contentBlocks': blocks},
          ),
        ]),
      );
      await tester.pump();

      final stableReads = blocks.itemReads;
      expect(stableReads, lessThanOrEqualTo(32));
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump();
      }
      expect(blocks.itemReads, stableReads);

      final listFinder = find.byKey(const ValueKey('content-blocks-list'));
      final loadMoreButton = find.descendant(
        of: listFinder,
        matching: find.widgetWithText(TextButton, 'Load more content'),
      );
      final contentScrollable = find
          .descendant(of: listFinder, matching: find.byType(Scrollable))
          .first;
      await tester.scrollUntilVisible(
        loadMoreButton,
        48,
        scrollable: contentScrollable,
      );
      expect(loadMoreButton, findsOneWidget);

      await tester.tap(loadMoreButton);
      await tester.pump();
      await tester.pump();

      expect(blocks.itemReads, greaterThan(stableReads));
      expect(blocks.itemReads - stableReads, lessThanOrEqualTo(32));
      final nextLoadMoreButton = find.descendant(
        of: listFinder,
        matching: find.widgetWithText(TextButton, 'Load more content'),
      );
      await tester.scrollUntilVisible(
        nextLoadMoreButton,
        48,
        scrollable: contentScrollable,
      );
      expect(nextLoadMoreButton, findsOneWidget);
    },
  );

  testWidgets('ChatTimeline skips mixed text blocks without blank rows', (
    tester,
  ) async {
    final rawBlocks = <_FieldReadCountingMap>[
      for (var index = 0; index < 60; index++)
        _FieldReadCountingMap({'type': 'text', 'text': 'text-$index'}),
      _FieldReadCountingMap({
        'type': 'resource_link',
        'title': 'first-visible-resource',
        'uri': 'file:///workspace/first',
      }),
      for (var index = 0; index < 5; index++)
        _FieldReadCountingMap({'type': 'text', 'text': 'middle-$index'}),
      _FieldReadCountingMap({
        'type': 'resource_link',
        'title': 'second-visible-resource',
        'uri': 'file:///workspace/second',
      }),
      for (var index = 0; index < 5; index++)
        _FieldReadCountingMap({'type': 'text', 'text': 'tail-$index'}),
    ];
    final blocks = _CountingList<_FieldReadCountingMap>(rawBlocks);

    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.assistant,
          text: 'Combined text is rendered above.',
          metadata: {'contentBlocks': blocks},
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('first-visible-resource'), findsOneWidget);
    expect(find.text('second-visible-resource'), findsOneWidget);
    expect(blocks.itemReads, lessThan(128));
    expect(
      rawBlocks.fold<int>(0, (total, block) => total + block.fieldReads),
      lessThan(128),
    );
    expect(
      tester.getSize(find.byKey(const ValueKey('content-blocks-list'))).height,
      lessThanOrEqualTo(220),
    );
  });

  testWidgets(
    'ChatTimeline scans sparse content blocks in bounded frame batches',
    (tester) async {
      final rawBlocks = <_FieldReadCountingMap>[
        for (var index = 0; index < 1023; index++)
          _FieldReadCountingMap({'type': 'text', 'text': 'text-$index'}),
        _FieldReadCountingMap({
          'type': 'resource_link',
          'title': 'last-sparse-resource',
          'uri': 'file:///workspace/last',
        }),
      ];
      final blocks = _CountingList<_FieldReadCountingMap>(rawBlocks);

      await tester.pumpWidget(
        timeline([
          _TestChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Sparse content.',
            metadata: {'contentBlocks': blocks},
          ),
        ]),
      );

      expect(blocks.itemReads, lessThanOrEqualTo(32));
      expect(find.text('Preparing content preview…'), findsOneWidget);
      expect(find.text('last-sparse-resource'), findsNothing);

      var previousReads = blocks.itemReads;
      for (var frame = 0; frame < 80; frame++) {
        await tester.pump();
        expect(blocks.itemReads - previousReads, lessThanOrEqualTo(32));
        previousReads = blocks.itemReads;
        if (find.text('last-sparse-resource').evaluate().isNotEmpty) break;
      }

      expect(find.text('last-sparse-resource'), findsOneWidget);
      expect(find.text('Preparing content preview…'), findsNothing);
      expect(
        rawBlocks.take(1023).every((block) => block.fieldReads == 1),
        isTrue,
      );
      expect(
        tester
            .getSize(find.byKey(const ValueKey('content-blocks-list')))
            .height,
        lessThanOrEqualTo(110),
      );
    },
  );

  testWidgets(
    'ChatTimeline marks partial content while bounded scanning continues',
    (tester) async {
      final rawBlocks = <_FieldReadCountingMap>[
        _FieldReadCountingMap({
          'type': 'resource_link',
          'title': 'early-resource-one',
          'uri': 'file:///workspace/one',
        }),
        _FieldReadCountingMap({
          'type': 'resource_link',
          'title': 'early-resource-two',
          'uri': 'file:///workspace/two',
        }),
        for (var index = 0; index < 1022; index++)
          _FieldReadCountingMap({'type': 'text', 'text': 'tail-$index'}),
      ];
      final blocks = _CountingList<_FieldReadCountingMap>(rawBlocks);

      await tester.pumpWidget(
        timeline([
          _TestChatMessage(
            role: ChatMessageRole.assistant,
            text: 'Early resources.',
            metadata: {'contentBlocks': blocks},
          ),
        ]),
      );
      expect(blocks.itemReads, lessThanOrEqualTo(32));
      expect(find.text('Preparing content preview…'), findsOneWidget);

      await tester.pump();
      expect(find.text('early-resource-one'), findsOneWidget);
      expect(find.text('early-resource-two'), findsOneWidget);
      expect(find.text('Preparing content preview…'), findsOneWidget);

      var previousReads = blocks.itemReads;
      for (var frame = 0; frame < 80; frame++) {
        await tester.pump();
        expect(blocks.itemReads - previousReads, lessThanOrEqualTo(32));
        previousReads = blocks.itemReads;
        if (find.text('Preparing content preview…').evaluate().isEmpty) break;
      }

      expect(find.text('Preparing content preview…'), findsNothing);
      expect(find.text('early-resource-one'), findsOneWidget);
      expect(find.text('early-resource-two'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('content-blocks-list')))
            .height,
        lessThanOrEqualTo(220),
      );
    },
  );

  testWidgets(
    'ChatTimeline removes the pending preview after bounded all-text scan',
    (tester) async {
      final rawBlocks = List<_FieldReadCountingMap>.generate(
        1024,
        (index) =>
            _FieldReadCountingMap({'type': 'text', 'text': 'text-$index'}),
      );
      final blocks = _CountingList<_FieldReadCountingMap>(rawBlocks);

      await tester.pumpWidget(
        timeline([
          _TestChatMessage(
            role: ChatMessageRole.assistant,
            text: 'All text is rendered above.',
            metadata: {'contentBlocks': blocks},
          ),
        ]),
      );
      expect(blocks.itemReads, lessThanOrEqualTo(32));
      expect(find.text('Preparing content preview…'), findsOneWidget);

      var previousReads = blocks.itemReads;
      for (var frame = 0; frame < 80; frame++) {
        await tester.pump();
        expect(blocks.itemReads - previousReads, lessThanOrEqualTo(32));
        previousReads = blocks.itemReads;
        if (find.text('Preparing content preview…').evaluate().isEmpty) break;
      }

      expect(find.text('Preparing content preview…'), findsNothing);
      expect(find.byKey(const ValueKey('content-blocks-list')), findsNothing);
      expect(rawBlocks.every((block) => block.fieldReads == 1), isTrue);
    },
  );

  testWidgets('ChatTimeline hides collections containing only text blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.assistant,
          text: 'All text is rendered above.',
          metadata: const {
            'contentBlocks': [
              {'type': 'text', 'text': 'one'},
              {'type': 'text', 'text': 'two'},
              {'type': 'text', 'text': 'three'},
            ],
          },
        ),
      ]),
    );

    expect(find.byKey(const ValueKey('content-blocks-list')), findsNothing);
  });

  testWidgets('ChatTimeline builds only visible plan items', (tester) async {
    final entries = _CountingList<_FieldReadCountingMap>(
      List<_FieldReadCountingMap>.generate(
        1024,
        (index) => _FieldReadCountingMap({
          'content': 'plan-$index',
          'priority': 'medium',
          'status': 'pending',
        }),
      ),
    );

    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.status,
          text: 'Large plan',
          metadata: {'kind': 'plan', 'entries': entries},
        ),
      ]),
    );

    expect(
      entries.values.fold<int>(0, (total, entry) => total + entry.fieldReads),
      lessThan(128),
    );
    expect(entries.itemReads, lessThan(128));
    final listFinder = find.byKey(const ValueKey('plan-entries-list'));
    expect(listFinder, findsOneWidget);
    final list = tester.widget<ListView>(listFinder);
    expect(list.primary, isFalse);
    expect(list.shrinkWrap, isFalse);
    expect(tester.getSize(listFinder).height, lessThanOrEqualTo(280));
  });

  testWidgets('ChatTimeline renders diff change details', (tester) async {
    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
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
    final diffToggle = tester.getSemantics(
      find.descendant(
        of: find.byKey(const ValueKey('diff-changes-toggle')),
        matching: find.byType(ListTile),
      ),
    );
    expect(
      diffToggle.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(find.text('Changed lines'));
    await tester.pumpAndSettle();

    expect(find.text('Modification'), findsOneWidget);
    expect(find.text('line 12'), findsOneWidget);
    expect(find.textContaining('final oldValue = true;'), findsOneWidget);
    expect(find.textContaining('final newValue = true;'), findsOneWidget);
  });

  testWidgets('ChatTimeline builds only visible diff details', (tester) async {
    final changes = _CountingList<_FieldReadCountingMap>(
      List<_FieldReadCountingMap>.generate(
        1024,
        (index) => _FieldReadCountingMap({
          'type': 'modification',
          'line': index + 1,
          'oldContent': 'old-$index',
          'newContent': 'new-$index',
        }),
      ),
    );
    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.status,
          text: 'file:///workspace/lib/main.dart',
          metadata: {
            'kind': 'diff',
            'uri': 'file:///workspace/lib/main.dart',
            'status': 'started',
            'changes': changes,
          },
        ),
      ]),
    );

    expect(
      changes.values.fold<int>(0, (total, change) => total + change.fieldReads),
      0,
    );
    expect(changes.itemReads, 0);
    await tester.tap(find.text('Changed lines'));
    await tester.pumpAndSettle();

    final listFinder = find.byKey(const ValueKey('diff-changes-list'));
    expect(listFinder, findsOneWidget);
    final list = tester.widget<ListView>(listFinder);
    expect(list.primary, isFalse);
    expect(list.shrinkWrap, isFalse);
    expect(tester.getSize(listFinder).height, lessThanOrEqualTo(280));
    expect(
      changes.values.fold<int>(0, (total, change) => total + change.fieldReads),
      lessThan(128),
    );
    expect(changes.itemReads, lessThan(128));
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

  testWidgets('ChatTimeline builds only visible command details', (
    tester,
  ) async {
    final commands = _CountingList<_FieldReadCountingMap>(
      List<_FieldReadCountingMap>.generate(
        1024,
        (index) => _FieldReadCountingMap({
          'name': 'command-$index',
          'description': 'description-$index',
          'parameters': {'index': index},
        }),
      ),
    );
    await tester.pumpWidget(
      timeline([
        _TestChatMessage(
          role: ChatMessageRole.status,
          text: 'commands',
          metadata: {'kind': 'commands', 'commands': commands},
        ),
      ]),
    );

    expect(
      commands.values.fold<int>(
        0,
        (total, command) => total + command.fieldReads,
      ),
      lessThan(128),
    );
    expect(commands.itemReads, lessThan(128));
    expect(find.text('1019 more'), findsOneWidget);

    await tester.tap(find.text('Command details'));
    await tester.pumpAndSettle();

    final listFinder = find.byKey(const ValueKey('command-details-list'));
    expect(listFinder, findsOneWidget);
    final list = tester.widget<ListView>(listFinder);
    expect(list.primary, isFalse);
    expect(list.shrinkWrap, isFalse);
    expect(tester.getSize(listFinder).height, lessThanOrEqualTo(320));
    expect(
      commands.values.fold<int>(
        0,
        (total, command) => total + command.fieldReads,
      ),
      lessThan(128),
    );
    expect(commands.itemReads, lessThan(128));
  });

  testWidgets('ChatTimeline keeps incomplete status data visible', (
    tester,
  ) async {
    final omission = AcpInputOmission(
      reason: AcpInputOmissionReason.inputLimit,
      resource: 'available commands',
      truncated: false,
      limit: 1024,
      observedAtLeast: 1025,
    );
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'commands unavailable',
          metadata: const {'kind': 'commands', 'commands': []},
          omissions: [omission],
        ),
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'partial plan',
          metadata: const {'kind': 'plan', 'entries': [], 'truncated': true},
        ),
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'diff unavailable',
          metadata: const {'kind': 'diff', 'changes': [], 'truncated': true},
        ),
      ]),
    );

    expect(find.textContaining('available commands'), findsOneWidget);
    expect(find.text('Details omitted'), findsNWidgets(2));
  });

  testWidgets('ChatTimeline renders terminal status output', (tester) async {
    await tester.pumpWidget(
      timeline([
        ChatMessage(
          role: ChatMessageRole.status,
          text: 'printf terminal-output',
          metadata: const {
            'kind': 'terminal',
            'terminalEvent': 'output',
            'terminalId': 'session-1:terminal-1',
            'status': 'completed',
            'command': 'printf',
            'args': ['terminal-output'],
            'cwd': '/workspace',
            'output': 'terminal-output',
            'exitCode': 0,
          },
        ),
      ]),
    );

    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('printf terminal-output'), findsOneWidget);
    expect(find.textContaining('exit 0'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('terminal-output'), findsOneWidget);
  });
}

var _diffGoldenFontsLoaded = false;

Future<void> _loadDiffGoldenFonts() async {
  if (_diffGoldenFontsLoaded) return;
  Future<ByteData> fontData(String path) async =>
      ByteData.sublistView(await File(path).readAsBytes());
  var flutterRoot = File(Platform.resolvedExecutable).parent;
  while (!Directory(
    '${flutterRoot.path}/bin/cache/artifacts/material_fonts',
  ).existsSync()) {
    final parent = flutterRoot.parent;
    if (parent.path == flutterRoot.path) {
      throw StateError('Unable to locate the Flutter SDK font cache.');
    }
    flutterRoot = parent;
  }
  final sans = FontLoader('ACPTestSans')
    ..addFont(
      fontData(
        '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
        'Roboto-Regular.ttf',
      ),
    );
  final mono = FontLoader('monospace')
    ..addFont(
      fontData(
        '${flutterRoot.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/'
        'fonts/Roboto_Mono/RobotoMono-Regular.ttf',
      ),
    );
  final sfMono = FontLoader('SF Mono')
    ..addFont(
      fontData(
        '${flutterRoot.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/'
        'fonts/Roboto_Mono/RobotoMono-Regular.ttf',
      ),
    );
  final icons = FontLoader('MaterialIcons')
    ..addFont(
      fontData(
        '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
        'MaterialIcons-Regular.otf',
      ),
    );
  await Future.wait([sans.load(), mono.load(), sfMono.load(), icons.load()]);
  _diffGoldenFontsLoaded = true;
}

final class _RejectingImageDecoder implements BoundedImageDecoder {
  var createBufferCalls = 0;

  @override
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes) async {
    createBufferCalls += 1;
    throw StateError('IMAGE_DECODER_CANARY');
  }

  @override
  Future<BoundedImageDescriptor> createDescriptor(BoundedImageBuffer buffer) =>
      throw UnimplementedError();

  @override
  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  }) => throw UnimplementedError();

  @override
  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec) =>
      throw UnimplementedError();
}

final class _TestChatMessage implements ChatMessage {
  _TestChatMessage({
    required this.role,
    required this.text,
    required this.metadata,
  });

  @override
  final ChatMessageRole role;

  @override
  String text;

  @override
  final Map<String, Object?> metadata;

  @override
  int revision = 0;

  @override
  List<AcpInputOmission> omissions = const <AcpInputOmission>[];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _CountingPreviewMap extends MapBase<String, Object?> {
  _CountingPreviewMap(String value)
    : _values = <String, Object?>{'value': value};

  _CountingPreviewMap.fromValues(this._values);

  final Map<String, Object?> _values;
  var entriesReads = 0;

  @override
  Object? operator [](Object? key) => _values[key];

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<MapEntry<String, Object?>> get entries {
    entriesReads += 1;
    return _values.entries;
  }

  @override
  Iterable<String> get keys => _values.keys;

  @override
  Object? remove(Object? key) => _values.remove(key);
}

final class _FieldReadCountingMap extends MapBase<String, Object?> {
  _FieldReadCountingMap(this._values);

  final Map<String, Object?> _values;
  var fieldReads = 0;

  @override
  Object? operator [](Object? key) {
    fieldReads += 1;
    return _values[key];
  }

  @override
  void operator []=(String key, Object? value) => _values[key] = value;

  @override
  void clear() => _values.clear();

  @override
  Iterable<String> get keys {
    fieldReads += _values.length;
    return _values.keys;
  }

  @override
  Object? remove(Object? key) => _values.remove(key);
}

final class _CountingList<E> extends ListBase<E> {
  _CountingList(this.values);

  final List<E> values;
  var itemReads = 0;

  @override
  int get length => values.length;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  E operator [](int index) {
    itemReads += 1;
    return values[index];
  }

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('read only');
  }
}
