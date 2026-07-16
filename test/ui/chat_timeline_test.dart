import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dart_acp/dart_acp.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/bounded_image_preview.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';
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
    VoidCallback? onNewSession,
    ThemeData? theme,
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpImageDecodeBudgetLedger? imageDecodeLedger,
    BoundedImageDecoder boundedImageDecoder = const DartUiBoundedImageDecoder(),
  }) {
    return MaterialApp(
      theme: theme,
      home: Scaffold(
        body: ChatTimeline(
          messages: messages,
          agentName: agentName,
          hasActiveSession: hasActiveSession,
          activeSessionLabel: activeSessionLabel,
          isLoadingSession: isLoadingSession,
          messageListRevision: messageListRevision,
          onNewSession: onNewSession,
          inputBudget: inputBudget,
          imageDecodeLedger: imageDecodeLedger,
          boundedImageDecoder: boundedImageDecoder,
        ),
      ),
    );
  }

  testWidgets('ChatTimeline renders empty state', (tester) async {
    await tester.pumpWidget(timeline(const []));

    expect(find.text('Start a session to chat with Codex'), findsOneWidget);
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
            'title': 'exec_command',
            'status': 'completed',
            'rawInput': {'secret': 'TOOL_METADATA_CANARY'},
          },
        ),
      ], inputBudget: budget),
    );

    expect(find.textContaining('TOOL_METADATA_CANARY'), findsNothing);
    await tester.tap(find.byType(ExpansionTile));
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
    await tester.tap(find.byType(ExpansionTile));
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

    expect(find.text('User'), findsOneWidget);
    expect(find.text('Agent'), findsOneWidget);
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

    expect(find.text('Agent'), findsOneWidget);
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
        return tester
            .widget<ListView>(find.byKey(const ValueKey('chat-timeline-list')))
            .controller!
            .position;
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
      return tester
          .widget<ListView>(find.byKey(const ValueKey('chat-timeline-list')))
          .controller!
          .position;
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
      final controller = tester
          .widget<ListView>(find.byKey(const ValueKey('chat-timeline-list')))
          .controller!;
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

  testWidgets('ChatTimeline limits initial render for large histories', (
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
    await tester.pump();

    expect(find.text('Showing latest 200 of 260 messages'), findsOneWidget);
    expect(find.text('Large history message 0'), findsNothing);
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

    expect(find.text('2 tool calls'), findsOneWidget);
    expect(find.text('1 failed'), findsOneWidget);
    expect(find.text('1 pending'), findsNothing);
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

    expect(find.text('2 tool calls'), findsOneWidget);
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
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();

    expect(find.text('call-1'), findsOneWidget);
    expect(find.textContaining('echo hi'), findsOneWidget);
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
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('Completed'), findsOneWidget);
    expect(find.text('call-1'), findsNothing);

    await tester.tap(find.byType(ExpansionTile));
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
      expect(find.text('Bash'), findsOneWidget);
      expect(find.text('Completed'), findsOneWidget);
      expect(find.text('call-1'), findsNothing);

      await tester.tap(find.byType(ExpansionTile));
      await tester.pumpAndSettle();

      expect(find.text('call-1'), findsOneWidget);
      expect(find.textContaining('echo hi'), findsOneWidget);
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
