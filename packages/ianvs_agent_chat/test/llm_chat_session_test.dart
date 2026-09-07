import 'dart:async';
import 'dart:convert';
import 'package:ianvs_agent_chat/llm.dart';
import 'package:ianvs_agent_chat/ianvs_agent_chat.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

String event(Map<String, Object?> delta, {String? finish}) =>
    'data: ${jsonEncode({
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finish},
      ],
    })}\n\n';
String reply(String text) =>
    '${event({'content': text})}${event({}, finish: 'stop')}data: [DONE]\n\n';
String toolCall({String name = 'sum', String args = '{"a":2,"b":3}'}) =>
    '${event({
      'tool_calls': [
        {
          'index': 0,
          'id': 'call_1',
          'type': 'function',
          'function': {'name': name, 'arguments': args.substring(0, 4)},
        },
      ],
    })}${event({
      'tool_calls': [
        {
          'index': 0,
          'function': {'arguments': args.substring(4)},
        },
      ],
    }, finish: 'tool_calls')}data: [DONE]\n\n';

class WireClient extends http.BaseClient {
  WireClient(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
  @override
  void close() {
    closed = true;
  }
}

http.StreamedResponse response(String s, {int code = 200}) =>
    http.StreamedResponse(
      Stream.fromIterable(utf8.encode(s).map((b) => [b])),
      code,
      headers: {'content-type': 'text/event-stream'},
    );
OpenAiChatClient client(http.Client Function() factory) => OpenAiChatClient(
  endpoint: Uri.parse('https://provider.example/v1/chat/completions'),
  model: 'test-model',
  apiKey: 'test-secret',
  clientFactory: factory,
);
Future<void> until(bool Function() condition) async {
  for (var i = 0; i < 1000 && !condition(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(condition(), isTrue, reason: 'condition did not become true');
}

void main() {
  test(
    'SSE handles every UTF-8 byte boundary, CRLF, comments and multiline data',
    () async {
      final bytes = utf8.encode(
        '\uFEFF: comment\r\ndata: 你好\r\ndata: 世界\r\n\r\ndata: [DONE]\r\n\r\n',
      );
      expect(
        await decodeServerSentEvents(
          Stream.fromIterable(bytes.map((b) => [b])),
        ).toList(),
        ['你好\n世界', '[DONE]'],
      );
    },
  );
  test('SSE rejects oversized lines before their terminator', () async {
    await expectLater(
      decodeServerSentEvents(
        Stream.value(List.filled(20, 65)),
        maxEventBytes: 8,
      ).toList(),
      throwsA(isA<ChatApiException>()),
    );
  });
  test('real request shape, streamed text and whole-turn history', () async {
    final requests = <Map<String, dynamic>>[];
    final wires = <WireClient>[];
    final session = LlmChatSession(
      client: client(() {
        final wire = WireClient((request) async {
          expect(request.url.path, '/v1/chat/completions');
          expect(request.headers['Authorization'], 'Bearer test-secret');
          expect(request.followRedirects, isFalse);
          requests.add(
            jsonDecode(utf8.decode(await request.finalize().toBytes()))
                as Map<String, dynamic>,
          );
          return response(reply('你好'));
        });
        wires.add(wire);
        return wire;
      }),
      systemPrompt: 'Be concise.',
    );
    addTearDown(session.dispose);
    await session.send('first');
    await session.send('second');
    expect(requests.first['stream'], isTrue);
    expect(requests.first['model'], 'test-model');
    expect((requests[1]['messages'] as List).map((m) => m['role']), [
      'system',
      'user',
      'assistant',
      'user',
    ]);
    expect(session.state.messages.last.text, '你好');
    expect(wires.every((w) => w.closed), isTrue);
    expect(session.state.isSending, isFalse);
  });
  test(
    'fragmented tool calls wait for approval and send matching results',
    () async {
      var requests = 0, executions = 0;
      Map<String, dynamic>? followup;
      final session = LlmChatSession(
        client: client(
          () => WireClient((request) async {
            final body =
                jsonDecode(utf8.decode(await request.finalize().toBytes()))
                    as Map<String, dynamic>;
            requests++;
            if (requests == 1) return response(toolCall());
            followup = body;
            return response(reply('5'));
          }),
        ),
        tools: [
          ChatTool(
            name: 'sum',
            description: 'Add two integers',
            parameters: const {'type': 'object'},
            execute: (args, cancellation) async {
              executions++;
              return '${(args['a'] as int) + (args['b'] as int)}';
            },
          ),
        ],
      );
      addTearDown(session.dispose);
      final running = session.send('Add 2 and 3');
      await until(() => session.state.permission != null);
      expect(executions, 0);
      await session.selectPermissionOption('allow_once');
      await running;
      expect(executions, 1);
      final messages = followup!['messages'] as List;
      expect(messages.last['tool_call_id'], 'call_1');
      expect(messages.last['content'], '5');
      expect(session.state.messages.last.text, '5');
      expect(
        session.state.messages
            .where((m) => m.role == ChatMessageRole.tool)
            .single
            .metadata['status'],
        'completed',
      );
    },
  );
  test(
    'denial never executes tool, but supplies a result to the model',
    () async {
      var requests = 0, executions = 0;
      final session = LlmChatSession(
        client: client(
          () => WireClient((request) async {
            requests++;
            return response(requests == 1 ? toolCall() : reply('Denied'));
          }),
        ),
        tools: [
          ChatTool(
            name: 'sum',
            description: '',
            parameters: const {},
            execute: (_, _) async {
              executions++;
              return 'bad';
            },
          ),
        ],
      );
      addTearDown(session.dispose);
      final running = session.send('sum');
      await until(() => session.state.permission != null);
      await session.resolvePermission(ChatPermissionDecision.deny);
      await running;
      expect(executions, 0);
      expect(requests, 2);
      expect(session.state.permission, isNull);
    },
  );
  test(
    'stop interrupts pending approval without executing or leaking state',
    () async {
      var executions = 0;
      final session = LlmChatSession(
        client: client(() => WireClient((_) async => response(toolCall()))),
        tools: [
          ChatTool(
            name: 'sum',
            description: '',
            parameters: const {},
            execute: (_, _) async {
              executions++;
              return 'bad';
            },
          ),
        ],
      );
      addTearDown(session.dispose);
      final running = session.send('sum');
      await until(() => session.state.permission != null);
      await session.stop();
      await running;
      expect(executions, 0);
      expect(session.state.isSending, isFalse);
      expect(session.state.permission, isNull);
      expect(
        session.state.messages
            .where((m) => m.role == ChatMessageRole.tool)
            .single
            .metadata['status'],
        'cancelled',
      );
    },
  );
  test(
    'stop before response headers returns promptly and another session survives',
    () async {
      final pending = Completer<http.StreamedResponse>();
      var started = false;
      final wire = WireClient((_) {
        started = true;
        return pending.future;
      });
      final a = LlmChatSession(client: client(() => wire));
      final b = LlmChatSession(
        client: client(
          () => WireClient((_) async => response(reply('independent'))),
        ),
      );
      addTearDown(a.dispose);
      addTearDown(b.dispose);
      final running = a.send('hang');
      await until(() => started);
      await a.stop();
      await running.timeout(const Duration(seconds: 1));
      await b.send('continue');
      expect(wire.closed, isTrue);
      expect(b.state.messages.last.text, 'independent');
      expect(a.state.error, isNull);
    },
  );
  test(
    'HTTP and malformed stream failures do not expose provider bodies',
    () async {
      final session = LlmChatSession(
        client: client(
          () => WireClient(
            (_) async => response('secret-key-and-user-data', code: 401),
          ),
        ),
      );
      addTearDown(session.dispose);
      await session.send('hello');
      expect(session.state.error, contains('401'));
      expect(session.state.error, isNot(contains('secret-key')));
    },
  );
  test(
    'truncated stream fails without committing incomplete context',
    () async {
      var n = 0;
      Map<String, dynamic>? next;
      final session = LlmChatSession(
        client: client(
          () => WireClient((request) async {
            n++;
            if (n == 1) return response(event({'content': 'partial'}));
            next =
                jsonDecode(utf8.decode(await request.finalize().toBytes()))
                    as Map<String, dynamic>;
            return response(reply('ok'));
          }),
        ),
      );
      addTearDown(session.dispose);
      await session.send('failed prompt');
      expect(session.state.error, isNotNull);
      await session.send('new prompt');
      expect((next!['messages'] as List).length, 1);
      expect(session.state.error, isNull);
    },
  );
  test('unsupported attachments fail before any request', () async {
    var requests = 0;
    final session = LlmChatSession(
      client: client(
        () => WireClient((_) async {
          requests++;
          return response(reply('bad'));
        }),
      ),
    );
    addTearDown(session.dispose);
    await expectLater(
      session.send(
        'image',
        attachments: [PromptAttachment.fromPath(path: '/tmp/a.png')],
      ),
      throwsA(isA<ChatApiException>()),
    );
    expect(requests, 0);
    expect(session.state.messages, isEmpty);
  });
}
