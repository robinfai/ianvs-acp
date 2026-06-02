import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/chat_timeline.dart';

void main() {
  Widget timeline(
    List<ChatMessage> messages, {
    String agentName = 'Codex',
    bool hasActiveSession = false,
    String? activeSessionLabel,
    VoidCallback? onNewSession,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ChatTimeline(
          messages: messages,
          agentName: agentName,
          hasActiveSession: hasActiveSession,
          activeSessionLabel: activeSessionLabel,
          onNewSession: onNewSession,
        ),
      ),
    );
  }

  testWidgets('ChatTimeline renders empty state', (tester) async {
    await tester.pumpWidget(timeline(const []));

    expect(find.text('Start a session to chat with Codex'), findsOneWidget);
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
            .widget<ListView>(find.byType(ListView))
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
          .widget<ListView>(find.byType(ListView))
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
    expect(find.textContaining('{"command"'), findsNothing);
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
