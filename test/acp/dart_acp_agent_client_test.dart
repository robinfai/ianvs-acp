import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';

void main() {
  test('copies configured MCP servers for session setup', () {
    final mcpServer = <String, dynamic>{
      'name': 'filesystem',
      'type': ' STDIO ',
      'command': '/usr/local/bin/mcp-filesystem',
      'args': ['--mode', 'readonly'],
    };

    final client = DartAcpAgentClient(mcpServers: [mcpServer]);
    mcpServer['name'] = 'mutated';

    expect(client.mcpServers, hasLength(1));
    expect(client.mcpServers.single['name'], 'filesystem');
    expect(client.mcpServers.single['type'], 'stdio');
    expect(
      client.mcpServers.single['command'],
      '/usr/local/bin/mcp-filesystem',
    );
  });

  test('dispose closes permission request stream', () async {
    final client = DartAcpAgentClient(agentCommand: 'unused');
    var streamClosed = false;
    final subscription = client.permissionRequests.listen(
      (_) {},
      onDone: () {
        streamClosed = true;
      },
    );

    await client.dispose();
    await pumpEventQueue();

    expect(streamClosed, isTrue);
    await subscription.cancel();
  });

  test('filters MCP server transports by agent capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final sessionParamsFile = File('${tempDir.path}/session_params.json');
    final agentScript = File('${tempDir.path}/fake_mcp_agent.dart');
    final sessionParamsPath = jsonEncode(sessionParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'mcpCapabilities': <String, dynamic>{'sse': true, 'acp': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      await File($sessionParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      mcpServers: const [
        {
          'name': 'stdio-tools',
          'command': '/usr/local/bin/mcp-tools',
          'args': <String>[],
          'env': <Map<String, String>>[],
        },
        {
          'name': 'http-tools',
          'type': 'http',
          'url': 'https://api.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
        {
          'name': 'sse-tools',
          'type': ' SSE ',
          'url': 'https://events.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
        {'name': 'acp-tools', 'type': 'acp', 'id': 'nested-agent'},
        {
          'name': 'typo-tools',
          'type': 'htp',
          'url': 'https://typo.example.com/mcp',
          'headers': <Map<String, String>>[],
        },
      ],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: '/workspace');

      final sessionParams =
          jsonDecode(await sessionParamsFile.readAsString())
              as Map<String, dynamic>;
      final forwardedServers = sessionParams['mcpServers'] as List<dynamic>;

      expect(
        forwardedServers.cast<Map<String, dynamic>>().map(
          (server) => server['name'],
        ),
        ['stdio-tools', 'sse-tools', 'acp-tools'],
      );
      expect(forwardedServers.cast<Map<String, dynamic>>()[1]['type'], 'sse');
      expect(
        forwardedServers.cast<Map<String, dynamic>>().last['id'],
        'nested-agent',
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('embeds text attachments when embedded context is advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      embeddedContext: true,
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {'type': 'text', 'text': 'Please inspect this.'});

    final resourceBlock = prompt.last as Map<String, dynamic>;
    expect(resourceBlock['type'], 'resource');
    expect(
      resourceBlock['resource'],
      containsPair('text', 'embedded attachment text'),
    );
    expect(resourceBlock['resource'], containsPair('mimeType', 'text/plain'));
  });

  test(
    'falls back to resource links without embedded context support',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: false,
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceLink = prompt.last as Map<String, dynamic>;
      expect(resourceLink['type'], 'resource_link');
      expect(resourceLink['name'], 'attachment.txt');
      expect(resourceLink['uri'], startsWith('file://'));
    },
  );

  test('embeds image attachments when image prompts are advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      image: true,
      attachmentName: 'pixel.png',
      attachmentBytes: _transparentPngBytes,
      mimeType: 'image/png',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final imageBlock = prompt.last as Map<String, dynamic>;
    expect(imageBlock['type'], 'image');
    expect(imageBlock['mimeType'], 'image/png');
    expect(imageBlock['data'], base64Encode(_transparentPngBytes));
    expect(imageBlock['uri'], startsWith('file://'));
  });

  test('falls back to resource links without image prompt support', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      image: false,
      attachmentName: 'pixel.png',
      attachmentBytes: _transparentPngBytes,
      mimeType: 'image/png',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final resourceLink = prompt.last as Map<String, dynamic>;
    expect(resourceLink['type'], 'resource_link');
    expect(resourceLink['name'], 'pixel.png');
    expect(resourceLink['mimeType'], 'image/png');
  });

  test('embeds audio attachments when audio prompts are advertised', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      audio: true,
      attachmentName: 'sample.wav',
      attachmentBytes: _tinyWavBytes,
      mimeType: 'audio/wav',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final audioBlock = prompt.last as Map<String, dynamic>;
    expect(audioBlock['type'], 'audio');
    expect(audioBlock['mimeType'], 'audio/wav');
    expect(audioBlock['data'], base64Encode(_tinyWavBytes));
    expect(audioBlock, isNot(contains('uri')));
  });

  test('falls back to resource links without audio prompt support', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      audio: false,
      attachmentName: 'sample.wav',
      attachmentBytes: _tinyWavBytes,
      mimeType: 'audio/wav',
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    final resourceLink = prompt.last as Map<String, dynamic>;
    expect(resourceLink['type'], 'resource_link');
    expect(resourceLink['name'], 'sample.wav');
    expect(resourceLink['mimeType'], 'audio/wav');
  });

  test(
    'embeds binary attachments when embedded context is advertised',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: true,
        attachmentName: 'sample.bin',
        attachmentBytes: _binaryBytes,
        mimeType: 'application/octet-stream',
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceBlock = prompt.last as Map<String, dynamic>;
      expect(resourceBlock['type'], 'resource');
      final resource = resourceBlock['resource'] as Map<String, dynamic>;
      expect(resource['mimeType'], 'application/octet-stream');
      expect(resource['blob'], base64Encode(_binaryBytes));
      expect(resource['uri'], startsWith('file://'));
    },
  );

  test(
    'falls back to resource links for binary attachments without embedded context',
    () async {
      final promptParams = await _capturePromptParamsForAttachment(
        embeddedContext: false,
        attachmentName: 'sample.bin',
        attachmentBytes: _binaryBytes,
        mimeType: 'application/octet-stream',
      );
      final prompt = promptParams['prompt'] as List<dynamic>;

      expect(prompt, hasLength(2));
      final resourceLink = prompt.last as Map<String, dynamic>;
      expect(resourceLink['type'], 'resource_link');
      expect(resourceLink['name'], 'sample.bin');
      expect(resourceLink['mimeType'], 'application/octet-stream');
    },
  );

  test('preserves prompt mentions when sending attachments', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      prompt: 'Please inspect @notes.md with this.',
      attachmentName: 'attachment.bin',
      attachmentBytes: _binaryBytes,
      mimeType: 'application/octet-stream',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(3));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Please inspect @notes.md with this.',
    });
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
    expect(mention['mimeType'], 'text/markdown');

    final attachment = prompt[2] as Map<String, dynamic>;
    expect(attachment['type'], 'resource_link');
    expect(attachment['name'], 'attachment.bin');
    expect(attachment['mimeType'], 'application/octet-stream');
  });

  test('preserves prompt mentions without selected attachments', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Please inspect @notes.md.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {'type': 'text', 'text': 'Please inspect @notes.md.'});
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
    expect(mention['mimeType'], 'text/markdown');
  });

  test('trims sentence punctuation from prompt mention links', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Compare (@notes.md) with @https://example.com/readme.md.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(3));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Compare (@notes.md) with @https://example.com/readme.md.',
    });
    final fileMention = prompt[1] as Map<String, dynamic>;
    expect(fileMention['name'], 'notes.md');
    expect(fileMention['uri'], endsWith('/notes.md'));

    final urlMention = prompt[2] as Map<String, dynamic>;
    expect(urlMention['name'], 'readme.md');
    expect(urlMention['uri'], 'https://example.com/readme.md');
  });

  test('sends clientInfo and preserves agentInfo during initialize', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] != 'initialize') continue;
    await File($initializeParamsPath).writeAsString(
      jsonEncode(message['params']),
    );
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': message['id'],
      'result': <String, dynamic>{
        'protocolVersion': 1,
        'agentInfo': <String, dynamic>{
          'name': 'Test Agent',
          'version': '0.0.1',
        },
        'agentCapabilities': <String, dynamic>{
          'sessionCapabilities': <String, dynamic>{
            'list': <String, dynamic>{},
          },
        },
        'authMethods': <Map<String, dynamic>>[],
      },
    }));
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities, isNotNull);
      expect(capabilities!.clientInfo['name'], 'ACP Client');
      expect(capabilities.clientInfo['version'], '1.0.0');
      expect(capabilities.agentInfo['name'], 'Test Agent');
      expect(capabilities.agentInfo['version'], '0.0.1');
      expect(capabilities.session.list, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientInfo'],
        containsPair('name', 'ACP Client'),
      );
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('readTextFile', false)),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('connects to websocket ACP agent servers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    String? authorizationHeader;
    final serverSubscription = server.listen((request) async {
      authorizationHeader = request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((data) async {
        final message = jsonDecode(data as String) as Map<String, dynamic>;
        final id = message['id'];
        final method = message['method'];
        if (method == 'initialize') {
          await initializeParamsFile.writeAsString(
            jsonEncode(message['params']),
          );
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'protocolVersion': 1,
                'agentInfo': <String, dynamic>{'name': 'Remote Agent'},
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        } else if (method == 'session/new') {
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{'sessionId': 'ws-session'},
            }),
          );
        } else if (method == 'session/prompt') {
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'ws-session',
                'update': <String, dynamic>{
                  'sessionUpdate': 'agent_message_chunk',
                  'content': <String, dynamic>{
                    'type': 'text',
                    'text': 'hello websocket',
                  },
                },
              },
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 25));
          socket.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{'stopReason': 'end_turn'},
            }),
          );
        }
      });
    });
    final client = DartAcpAgentClient(
      agentWebSocketUrl: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      agentHeaders: const {'Authorization': 'Bearer test-token'},
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(authorizationHeader, 'Bearer test-token');
      expect(client.capabilities?.agentInfo['name'], 'Remote Agent');
      expect(session.id, 'ws-session');
      expect(events.map((event) => event.text), contains('hello websocket'));
      expect(events.last.metadata['stopReason'], 'endTurn');
      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientInfo'],
        containsPair('name', 'ACP Client'),
      );
    } finally {
      await client.dispose();
      await serverSubscription.cancel();
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    }
  });

  test('preserves snake case tool call ids from raw session updates', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_snake_tool_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) {
  stdout.writeln(jsonEncode(message));
}

void sendSessionUpdate(Map<String, dynamic> update) {
  send(<String, dynamic>{
    'jsonrpc': '2.0',
    'method': 'session/update',
    'params': <String, dynamic>{
      'sessionId': 'session-1',
      'update': update,
    },
  });
}

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/new') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      });
    } else if (message['method'] == 'session/prompt') {
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-a',
        'title': 'Bash A',
        'status': 'pending',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-b',
        'title': 'Bash B',
        'status': 'pending',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-a',
        'status': 'completed',
        'raw_output': 'a done',
      });
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call_update',
        'tool_call_id': 'call-b',
        'status': 'completed',
        'raw_output': 'b done',
      });
      await Future<void>.delayed(const Duration(milliseconds: 25));
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'run tools')
          .toList()
          .timeout(const Duration(seconds: 5));

      final toolEvents = events
          .where((event) => event.type == AgentEventType.toolCall)
          .toList();

      expect(toolEvents.map((event) => event.metadata['toolCallId']), [
        'call-a',
        'call-b',
        'call-a',
        'call-b',
      ]);
      expect(toolEvents[2].text, 'Bash A');
      expect(toolEvents[2].metadata['title'], 'Bash A');
      expect(toolEvents[2].metadata['status'], 'completed');
      expect(toolEvents[2].metadata['rawOutput'], 'a done');
      expect(toolEvents[3].text, 'Bash B');
      expect(toolEvents[3].metadata['title'], 'Bash B');
      expect(toolEvents[3].metadata['status'], 'completed');
      expect(toolEvents[3].metadata['rawOutput'], 'b done');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('connects to streamable HTTP ACP agent servers', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final connectionStream = Completer<HttpResponse>();
    final sessionStream = Completer<HttpResponse>();
    String? authorizationHeader;
    String? connectionHeader;
    String? sessionHeader;
    String? cookieHeader;
    String? deleteConnectionHeader;
    String? deleteCookieHeader;
    String? connectionStreamProtocolHeader;
    String? sessionPostProtocolHeader;
    String? deleteProtocolHeader;
    var disposed = false;

    Future<void> sendSse(
      Completer<HttpResponse> stream,
      Map<String, dynamic> message,
    ) async {
      final response = await stream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    Future<void> openSse(HttpRequest request) async {
      final sessionId = request.headers.value('Acp-Session-Id');
      connectionStreamProtocolHeader ??= request.headers.value(
        'Acp-Protocol-Version',
      );
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (sessionId == null) {
        if (!connectionStream.isCompleted) {
          connectionStream.complete(request.response);
        }
      } else if (!sessionStream.isCompleted) {
        sessionStream.complete(request.response);
      }
    }

    final serverSubscription = server.listen((request) async {
      authorizationHeader ??= request.headers.value(
        HttpHeaders.authorizationHeader,
      );
      if (request.method == 'DELETE') {
        deleteConnectionHeader = request.headers.value('Acp-Connection-Id');
        deleteCookieHeader = request.headers.value(HttpHeaders.cookieHeader);
        deleteProtocolHeader = request.headers.value('Acp-Protocol-Version');
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final id = message['id'];
      final method = message['method'];
      if (method == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..cookies.add(Cookie('sticky', 'yes'))
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentInfo': <String, dynamic>{'name': 'HTTP Agent'},
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        await request.response.close();
      } else if (method == 'session/new') {
        connectionHeader = request.headers.value('Acp-Connection-Id');
        cookieHeader = request.headers.value(HttpHeaders.cookieHeader);
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(connectionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-session'},
        });
      } else if (method == 'session/prompt') {
        sessionHeader = request.headers.value('Acp-Session-Id');
        sessionPostProtocolHeader = request.headers.value(
          'Acp-Protocol-Version',
        );
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(sessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'http-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <String, dynamic>{
                'type': 'text',
                'text': 'hello http',
              },
            },
          },
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));
        await sendSse(sessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        });
      }
    });

    final client = DartAcpAgentClient(
      agentHttpUrl: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      agentHeaders: const {'Authorization': 'Bearer test-token'},
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(authorizationHeader, 'Bearer test-token');
      expect(connectionHeader, 'connection-1');
      expect(connectionStreamProtocolHeader, '1');
      expect(sessionHeader, 'http-session');
      expect(sessionPostProtocolHeader, '1');
      expect(cookieHeader, contains('sticky=yes'));
      expect(client.capabilities?.agentInfo['name'], 'HTTP Agent');
      expect(session.id, 'http-session');
      expect(events.map((event) => event.text), contains('hello http'));
      expect(events.last.metadata['stopReason'], 'endTurn');
      await client.dispose().timeout(const Duration(seconds: 5));
      disposed = true;
      expect(deleteConnectionHeader, 'connection-1');
      expect(deleteCookieHeader, contains('sticky=yes'));
      expect(deleteProtocolHeader, '1');
    } finally {
      if (!disposed) {
        await client.dispose();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('opens streamable HTTP SSE stream for forked sessions', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final connectionStream = Completer<HttpResponse>();
    final originalSessionStream = Completer<HttpResponse>();
    final forkedSessionStream = Completer<HttpResponse>();
    String? forkPostSessionHeader;
    var disposed = false;

    Future<void> sendSse(
      Completer<HttpResponse> stream,
      Map<String, dynamic> message,
    ) async {
      final response = await stream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    Future<void> openSse(HttpRequest request) async {
      final sessionId = request.headers.value('Acp-Session-Id');
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (sessionId == null) {
        if (!connectionStream.isCompleted) {
          connectionStream.complete(request.response);
        }
      } else if (sessionId == 'http-session') {
        if (!originalSessionStream.isCompleted) {
          originalSessionStream.complete(request.response);
        }
      } else if (sessionId == 'http-fork') {
        if (!forkedSessionStream.isCompleted) {
          forkedSessionStream.complete(request.response);
        }
      }
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final id = message['id'];
      final method = message['method'];
      if (method == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{
                  'sessionCapabilities': <String, dynamic>{
                    'fork': <String, dynamic>{},
                  },
                },
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
        await request.response.close();
      } else if (method == 'session/new') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(connectionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-session'},
        });
      } else if (method == 'session/fork') {
        forkPostSessionHeader = request.headers.value('Acp-Session-Id');
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        await sendSse(originalSessionStream, <String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'result': <String, dynamic>{'sessionId': 'http-fork'},
        });
      }
    });

    final client = DartAcpAgentClient(
      agentHttpUrl: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final forked = await client
          .forkSession(sessionId: session.id, cwd: '/workspace')
          .timeout(const Duration(seconds: 5));

      await forkedSessionStream.future.timeout(const Duration(seconds: 5));

      expect(session.id, 'http-session');
      expect(forked.id, 'http-fork');
      expect(forkPostSessionHeader, 'http-session');
      await client.dispose().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      if (!disposed) {
        await client.dispose();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('sends custom extension JSON-RPC requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final extensionParamsFile = File('${tempDir.path}/extension_params.json');
    final agentScript = File('${tempDir.path}/fake_extension_agent.dart');
    final extensionParamsPath = jsonEncode(extensionParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            '_meta': <String, dynamic>{
              'example.dev': <String, dynamic>{'ping': true},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == '_example.dev/ping') {
      await File($extensionParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'pong': true},
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      expect(client.capabilities?.extensionMeta['example.dev'], isNotNull);
      final result = await client
          .sendExtensionRequest(
            method: '_example.dev/ping',
            params: const {'message': 'hello'},
          )
          .timeout(const Duration(seconds: 5));

      expect(result, containsPair('pong', true));
      final extensionParams =
          jsonDecode(await extensionParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(extensionParams, {'message': 'hello'});
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('advertises configured filesystem provider capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_fs_caps_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($initializeParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      allowFilesystemReadOutsideWorkspace: true,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities?.client.fsReadTextFile, isTrue);
      expect(capabilities?.client.fsWriteTextFile, isTrue);
      expect(capabilities?.client.hasFsProvider, isTrue);
      expect(capabilities?.client.allowReadOutsideWorkspace, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('readTextFile', true)),
      );
      expect(
        initializeParams['clientCapabilities'],
        containsPair('fs', containsPair('writeTextFile', true)),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('advertises configured terminal provider capabilities', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final initializeParamsFile = File('${tempDir.path}/initialize_params.json');
    final agentScript = File('${tempDir.path}/fake_terminal_caps_agent.dart');
    final initializeParamsPath = jsonEncode(initializeParamsFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($initializeParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableTerminalProvider: true,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final capabilities = client.capabilities;
      expect(capabilities?.client.terminal, isTrue);
      expect(capabilities?.client.hasTerminalProvider, isTrue);

      final initializeParams =
          jsonDecode(await initializeParamsFile.readAsString())
              as Map<String, dynamic>;
      expect(
        initializeParams['clientCapabilities'],
        containsPair('terminal', true),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('serves filesystem read requests after permission approval', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    await File('${workspace.path}/fixture.txt').writeAsString('hello fs');
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_read_agent.dart');
    final fsResponsePath = jsonEncode(fsResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'fs-read-1',
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{
          'sessionId': 'session-fs',
          'path': 'fixture.txt',
        },
      }));
    } else if (message['id'] == 'fs-read-1') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableFilesystemReadTextFile: true,
    );
    final subscription = client.permissionRequests.listen((request) {
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      expect(session.id, 'session-fs');
      final fsResponse =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(fsResponse['id'], 'fs-read-1');
      expect(fsResponse['result'], containsPair('content', 'hello fs'));
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('rejects unadvertised filesystem write requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_write_agent.dart');
    final fsResponsePath = jsonEncode(fsResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'fs-write-1',
        'method': 'fs/write_text_file',
        'params': <String, dynamic>{
          'sessionId': 'session-fs',
          'path': 'created.txt',
          'content': 'should not write',
        },
      }));
    } else if (message['id'] == 'fs-write-1') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: false,
    );
    final subscription = client.permissionRequests.listen((request) {
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      final fsResponse =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(fsResponse['id'], 'fs-write-1');
      expect(fsResponse, contains('error'));
      expect(await File('${workspace.path}/created.txt').exists(), isFalse);
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('emits terminal lifecycle events after permission approval', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    final terminalResponseFile = File('${tempDir.path}/terminal_response.json');
    final agentScript = File('${tempDir.path}/fake_terminal_agent.dart');
    final terminalResponsePath = jsonEncode(terminalResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? promptId;
  String? terminalId;

  void respond(Object? id, Object? result) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'result': result,
    }));
  }

  void request(String id, String method, Map<String, dynamic> params) {
    stdout.writeln(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
  }

  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      respond(message['id'], <String, dynamic>{
        'protocolVersion': 1,
        'agentCapabilities': <String, dynamic>{},
        'authMethods': <Map<String, dynamic>>[],
      });
    } else if (message['method'] == 'session/new') {
      respond(message['id'], <String, dynamic>{'sessionId': 'session-term'});
    } else if (message['method'] == 'session/prompt') {
      promptId = message['id'];
      request('terminal-create-1', 'terminal/create', <String, dynamic>{
        'sessionId': 'session-term',
        'command': 'printf terminal-output',
        'args': <String>[],
      });
    } else if (message['id'] == 'terminal-create-1') {
      terminalId = (message['result'] as Map<String, dynamic>)['terminalId']
          as String;
      request('terminal-wait-1', 'terminal/wait_for_exit', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-wait-1') {
      request('terminal-output-1', 'terminal/output', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-output-1') {
      await File($terminalResponsePath).writeAsString(jsonEncode(message));
      request('terminal-release-1', 'terminal/release', <String, dynamic>{
        'terminalId': terminalId,
      });
    } else if (message['id'] == 'terminal-release-1') {
      respond(promptId, <String, dynamic>{'stopReason': 'end_turn'});
    }
  }
}
''');

    late final DartAcpAgentClient client;
    client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      enableTerminalProvider: true,
    );
    final permissionRequests = <AcpPermissionRequest>[];
    final subscription = client.permissionRequests.listen((request) {
      permissionRequests.add(request);
      unawaited(
        client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ),
      );
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: workspace.path);
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'run command')
          .toList()
          .timeout(const Duration(seconds: 5));
      await _waitForFile(terminalResponseFile);

      expect(permissionRequests, hasLength(1));
      expect(permissionRequests.single.toolName, 'terminal');
      expect(permissionRequests.single.toolKind, 'execute');

      final terminalEvents = events
          .where((event) => event.metadata['kind'] == 'terminal')
          .toList();
      expect(
        terminalEvents.map((event) => event.metadata['terminalEvent']),
        containsAll(['created', 'exited', 'output', 'released']),
      );
      expect(
        terminalEvents.first.metadata['command'],
        'printf terminal-output',
      );
      expect(
        terminalEvents
            .where((event) => event.metadata['terminalEvent'] == 'output')
            .single
            .metadata['output'],
        'terminal-output',
      );
      expect(events.last.metadata['stopReason'], 'endTurn');

      final terminalResponse =
          jsonDecode(await terminalResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(
        terminalResponse['result'],
        containsPair('outputmode', 'terminal-output'),
      );
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'cancels agent permission requests when no interactive UI is listening',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_permission_agent.dart');
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-1') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await _waitForFile(permissionResponseFile);

        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-1');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'approves agent permission requests through interactive response',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_permission_agent.dart');
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-1',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-1') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      late final DartAcpAgentClient client;
      client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) {
          requestCompleter.complete(request);
        }
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: AcpPermissionDecision.allow,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        await _waitForFile(permissionResponseFile);

        expect(request.displayTitle, 'Read file');
        expect(request.displayKind, 'read');
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-1');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'selected')),
        );
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('optionId', 'allow')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'closeSession cancels pending permission requests for the session',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final closeRequestFile = File('${tempDir.path}/close_request.json');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_close_permission_agent.dart',
      );
      final closeRequestPath = jsonEncode(closeRequestFile.path);
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'close': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-close'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-close',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-close',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/close') {
      await File($closeRequestPath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (message['id'] == 'permission-close') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final requestCompleter = Completer<AcpPermissionRequest>();
      final subscription = client.permissionRequests.listen((request) {
        if (!requestCompleter.isCompleted) {
          requestCompleter.complete(request);
        }
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        final session = await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );

        expect(session.id, 'session-close');
        expect(request.sessionId, 'session-close');

        await client.closeSession(sessionId: session.id);
        await _waitForFile(closeRequestFile);
        await _waitForFile(permissionResponseFile);

        final closeRequest =
            jsonDecode(await closeRequestFile.readAsString())
                as Map<String, dynamic>;
        expect(closeRequest['method'], 'session/close');
        expect(
          closeRequest['params'],
          containsPair('sessionId', 'session-close'),
        );

        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-close');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('logout cancels pending permission requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final logoutRequestFile = File('${tempDir.path}/logout_request.json');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File(
      '${tempDir.path}/fake_logout_permission_agent.dart',
    );
    final logoutRequestPath = jsonEncode(logoutRequestFile.path);
    final permissionResponsePath = jsonEncode(permissionResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'auth': <String, dynamic>{'logout': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-logout'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-logout',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-logout',
          'toolCall': <String, dynamic>{
            'title': 'Run command',
            'kind': 'execute',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'allow',
              'kind': 'allow_once',
              'name': 'Allow',
            },
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
    } else if (message['method'] == 'logout') {
      await File($logoutRequestPath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (message['id'] == 'permission-logout') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final requestCompleter = Completer<AcpPermissionRequest>();
    final subscription = client.permissionRequests.listen((request) {
      if (!requestCompleter.isCompleted) {
        requestCompleter.complete(request);
      }
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');
      final request = await requestCompleter.future.timeout(
        const Duration(seconds: 5),
      );

      expect(session.id, 'session-logout');
      expect(request.sessionId, 'session-logout');

      await client.logout();
      await _waitForFile(logoutRequestFile);
      await _waitForFile(permissionResponseFile);

      final logoutRequest =
          jsonDecode(await logoutRequestFile.readAsString())
              as Map<String, dynamic>;
      expect(logoutRequest['method'], 'logout');

      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(permissionResponse['id'], 'permission-logout');
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('outcome', 'cancelled')),
      );
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'prefers config options over modes returned by session creation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_session_result_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5',
                  'name': 'GPT-5',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);

        expect(session.id, 'session-1');
        expect(settings.configOptions, hasLength(1));
        expect(settings.currentModelLabel, 'GPT-5');
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('raw session result capture ignores colliding agent requests', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_colliding_request_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Read file',
            'kind': 'read',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': 'deny',
              'kind': 'reject_once',
              'name': 'Deny',
            },
          ],
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(session.id, 'session-1');
      expect(settings.configOptions.map((option) => option.id), ['model']);
      expect(settings.currentModelLabel, 'GPT-5');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('ignores unsupported raw config option types', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_unknown_config_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-1',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': ' SELECT ',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
            <String, dynamic>{
              'id': 'temperature',
              'name': 'Temperature',
              'type': 'slider',
              'currentValue': '0.3',
              'options': <Map<String, dynamic>>[],
            },
            <String, dynamic>{
              'id': 'bad-select',
              'name': 'Bad select',
              'type': 'select',
              'currentValue': true,
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'true', 'name': 'True'},
              ],
            },
            <String, dynamic>{
              'id': 'read_only',
              'name': 'Read only',
              'type': ' BOOLEAN ',
              'currentValue': true,
              'options': <Map<String, dynamic>>[],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(settings.configOptions.map((option) => option.id), [
        'model',
        'read_only',
      ]);
      expect(settings.configOptions.first.type, 'select');
      expect(settings.configOptions.last.type, 'boolean');
      expect(settings.configOptions.last.currentValue, 'true');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('caches legacy modes when config options are omitted', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_legacy_modes_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-legacy',
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');
      final settings = await client.sessionSettings(session.id);

      expect(session.id, 'session-legacy');
      expect(settings.configOptions, isEmpty);
      expect(settings.modes.currentModeId, 'plan');
      expect(settings.modes.availableModes.map((mode) => mode.id), [
        'plan',
        'act',
      ]);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'caches immediate config option updates after session creation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_config_agent.dart');
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'gpt-5',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{
                    'value': 'gpt-5',
                    'name': 'GPT-5',
                  },
                ],
              },
            ],
          },
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);

        expect(session.id, 'session-1');
        expect(settings.configOptions, hasLength(1));
        expect(settings.configOptions.single.id, 'model');
        expect(settings.currentModelLabel, 'GPT-5');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('returns immediate command updates with created sessions', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_commands_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-commands'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-commands',
          'update': <String, dynamic>{
            'sessionUpdate': 'available_commands_update',
            'availableCommands': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'review',
                'description': 'Review the current change.',
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final session = await client.createSession(cwd: '/workspace');

      expect(session.id, 'session-commands');
      expect(session.initialEvents, hasLength(1));
      final event = session.initialEvents.single;
      expect(event.metadata['kind'], 'commands');
      expect(
        event.metadata['commands'],
        contains(containsPair('description', 'Review the current change.')),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('returns immediate command updates after session resume', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_resume_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-resume',
          'update': <String, dynamic>{
            'sessionUpdate': 'available_commands_update',
            'availableCommands': <Map<String, dynamic>>[
              <String, dynamic>{
                'name': 'summarize',
                'description': 'Summarize the resumed session.',
              },
            ],
          },
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final events = await client.resumeSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );

      expect(events, hasLength(1));
      expect(events.single.metadata['kind'], 'commands');
      expect(
        events.single.metadata['commands'],
        contains(containsPair('name', 'summarize')),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('caches config options returned by session load', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_load_settings_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5-pro',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5-pro',
                  'name': 'GPT-5 Pro',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final events = await client.resumeSession(
        sessionId: 'session-load',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-load');

      expect(events, isEmpty);
      expect(settings.configOptions, hasLength(1));
      expect(settings.currentModelLabel, 'GPT-5 Pro');
      expect(settings.modes.currentModeId, isNull);
      expect(settings.modes.availableModes, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'session load mode updates use the loaded session config state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_load_mode_update_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-with-config',
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
              ],
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-mode',
          'update': <String, dynamic>{
            'sessionUpdate': 'current_mode_update',
            'currentModeId': 'plan',
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');

        final events = await client.resumeSession(
          sessionId: 'session-legacy-mode',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-legacy-mode');

        expect(events, hasLength(1));
        expect(events.single.type, AgentEventType.status);
        expect(events.single.text, 'plan');
        expect(events.single.metadata['kind'], 'mode');
        expect(settings.modes.currentModeId, 'plan');
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'session load keeps immediate config options when result only has modes',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_load_config_update_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
            'sessionCapabilities': <String, dynamic>{
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/load') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-load',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'gpt-5',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'gpt-5', 'name': 'GPT-5'},
                ],
              },
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'plan',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
            ],
          },
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final events = await client.resumeSession(
          sessionId: 'session-load',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-load');

        expect(events, hasLength(1));
        expect(events.single.metadata['kind'], 'config_option_update');
        expect(settings.configOptions, hasLength(1));
        expect(settings.currentModelLabel, 'GPT-5');
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('ignores prompt stream errors while loading session history', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_load_prompt_error_agent.dart',
    );
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Object? pendingLoadId;

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'loadSession': true,
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-load',
        },
      }));
    } else if (message['method'] == 'session/load') {
      pendingLoadId = message['id'];
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'error': <String, dynamic>{
          'code': -32000,
          'message': 'prompt failed',
        },
      }));
      final loadId = pendingLoadId;
      if (loadId != null) {
        pendingLoadId = null;
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': loadId,
          'result': <String, dynamic>{},
        }));
      }
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');

      final resumeFuture = client.resumeSession(
        sessionId: session.id,
        cwd: '/workspace',
      );
      await Future<void>.delayed(Duration.zero);
      final promptEvents = await client
          .sendPrompt(sessionId: session.id, prompt: 'fail now')
          .toList();
      final loadEvents = await resumeFuture.timeout(const Duration(seconds: 5));

      expect(loadEvents, isEmpty);
      expect(promptEvents, hasLength(1));
      expect(promptEvents.single.type, AgentEventType.error);
      expect(promptEvents.single.text, contains('prompt failed'));
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'prefers config options over modes returned by session resume',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_resume_settings_agent.dart',
      );
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': <String, dynamic>{},
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/resume') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'modes': <String, dynamic>{
            'currentModeId': 'act',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'id': 'act', 'name': 'Act'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5-mini',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5-mini',
                  'name': 'GPT-5 Mini',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );

      try {
        await client.connect().timeout(const Duration(seconds: 5));

        final events = await client.resumeSession(
          sessionId: 'session-resume',
          cwd: '/workspace',
        );
        final settings = await client.sessionSettings('session-resume');

        expect(events, isEmpty);
        expect(settings.currentModelLabel, 'GPT-5 Mini');
        expect(settings.modes.currentModeId, isNull);
        expect(settings.modes.availableModes, isEmpty);
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('prefers config options over modes returned by session fork', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_fork_settings_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'fork': <String, dynamic>{},
              'configOptions': <String, dynamic>{},
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/fork') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-forked',
          'modes': <String, dynamic>{
            'currentModeId': 'review',
            'availableModes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'act', 'name': 'Act'},
              <String, dynamic>{'id': 'review', 'name': 'Review'},
            ],
          },
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'gpt-5',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{
                  'value': 'gpt-5',
                  'name': 'GPT-5',
                },
              ],
            },
          ],
        },
      }));
    }
  }
}
''');

    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));

      final forked = await client.forkSession(
        sessionId: 'session-original',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-forked');

      expect(forked.id, 'session-forked');
      expect(forked.initialEvents, isEmpty);
      expect(settings.currentModelLabel, 'GPT-5');
      expect(settings.modes.currentModeId, isNull);
      expect(settings.modes.availableModes, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });
}

Future<Map<String, dynamic>> _capturePromptParamsForAttachment({
  bool embeddedContext = false,
  bool image = false,
  bool audio = false,
  bool includeAttachment = true,
  String prompt = 'Please inspect this.',
  String attachmentName = 'attachment.txt',
  List<int>? attachmentBytes,
  String? mimeType,
  Map<String, String> extraFiles = const <String, String>{},
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final promptParamsFile = File('${tempDir.path}/prompt_params.json');
  final attachmentFile = File('${tempDir.path}/$attachmentName');
  final agentScript = File('${tempDir.path}/fake_prompt_agent.dart');
  final promptParamsPath = jsonEncode(promptParamsFile.path);
  final promptCapabilities = <String>[
    if (embeddedContext) "'embeddedContext': true",
    if (image) "'image': true",
    if (audio) "'audio': true",
  ].join(', ');
  final agentCapabilities = promptCapabilities.isEmpty
      ? '<String, dynamic>{}'
      : "<String, dynamic>{'promptCapabilities': <String, dynamic>{$promptCapabilities}}";
  final bytes = attachmentBytes ?? utf8.encode('embedded attachment text');
  await attachmentFile.writeAsBytes(bytes);
  for (final entry in extraFiles.entries) {
    await File('${tempDir.path}/${entry.key}').writeAsString(entry.value);
  }
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': $agentCapabilities,
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      await File($promptParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
  );

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final session = await client.createSession(cwd: tempDir.path);
    final events = await client
        .sendPrompt(
          sessionId: session.id,
          prompt: prompt,
          attachments: includeAttachment
              ? [
                  PromptAttachment.fromPath(
                    path: attachmentFile.path,
                    mimeType: mimeType,
                    size: await attachmentFile.length(),
                  ),
                ]
              : const <PromptAttachment>[],
        )
        .toList()
        .timeout(const Duration(seconds: 5));
    expect(events.last.metadata['stopReason'], 'endTurn');
    return jsonDecode(await promptParamsFile.readAsString())
        as Map<String, dynamic>;
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

const _transparentPngBytes = <int>[
  0x89,
  0x50,
  0x4e,
  0x47,
  0x0d,
  0x0a,
  0x1a,
  0x0a,
  0x00,
  0x00,
  0x00,
  0x0d,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1f,
  0x15,
  0xc4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0a,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9c,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0d,
  0x0a,
  0x2d,
  0xb4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4e,
  0x44,
  0xae,
  0x42,
  0x60,
  0x82,
];

const _tinyWavBytes = <int>[
  0x52,
  0x49,
  0x46,
  0x46,
  0x24,
  0x00,
  0x00,
  0x00,
  0x57,
  0x41,
  0x56,
  0x45,
  0x66,
  0x6d,
  0x74,
  0x20,
  0x10,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x01,
  0x00,
  0x40,
  0x1f,
  0x00,
  0x00,
  0x80,
  0x3e,
  0x00,
  0x00,
  0x02,
  0x00,
  0x10,
  0x00,
  0x64,
  0x61,
  0x74,
  0x61,
  0x00,
  0x00,
  0x00,
  0x00,
];

const _binaryBytes = <int>[0x00, 0xff, 0x10, 0x80, 0x42, 0x24];

String _dartExecutable() {
  final executable = Platform.resolvedExecutable;
  final cacheMarker =
      '${Platform.pathSeparator}bin${Platform.pathSeparator}'
      'cache${Platform.pathSeparator}';
  final cacheIndex = executable.indexOf(cacheMarker);
  if (cacheIndex != -1) {
    return '${executable.substring(0, cacheIndex)}'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache'
        '${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}dart';
  }
  return executable.endsWith('${Platform.pathSeparator}dart')
      ? executable
      : 'dart';
}

Future<void> _waitForFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
