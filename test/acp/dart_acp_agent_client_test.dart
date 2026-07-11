import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/peer.dart' show JsonRpcPeer;
import 'package:dart_acp/src/session/session_manager.dart' show SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test('pins the default Codex ACP adapter version', () {
    final client = DartAcpAgentClient(agentCommand: 'unused');

    expect(client.agentArgs, ['@zed-industries/codex-acp@0.16.0']);
  });

  test('rejects plaintext remote endpoints at the client boundary', () {
    expect(
      () => DartAcpAgentClient(
        agentWebSocketUrl: Uri.parse('ws://agent.example.com/acp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DartAcpAgentClient(
        agentHttpUrl: Uri.parse('http://agent.example.com/acp'),
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => DartAcpAgentClient(
        mcpServers: const <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'remote-tools',
            'type': 'http',
            'url': 'http://tools.example.com/mcp',
          },
        ],
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects endpoint credentials at the client boundary', () {
    expect(
      () => DartAcpAgentClient(
        agentHttpUrl: Uri.parse(
          'https://embedded:canary-secret@agent.example.com/acp',
        ),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.toString(),
          'message',
          isNot(contains('canary-secret')),
        ),
      ),
    );
  });

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
    expect(
      () => client.mcpServers.single['url'] = 'http://mutated.example.com/mcp',
      throwsUnsupportedError,
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

  test('dispose stops an agent whose initialize request is pending', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final startedFile = File('${tempDir.path}/initialize_started');
    final pidFile = File('${tempDir.path}/agent_pid');
    final releaseFile = File('${tempDir.path}/release_initialize');
    final agentScript = File('${tempDir.path}/pending_initialize_agent.dart');
    final startedPath = jsonEncode(startedFile.path);
    final pidPath = jsonEncode(pidFile.path);
    final releasePath = jsonEncode(releaseFile.path);
    await agentScript.writeAsString('''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await File($pidPath).writeAsString('\$pid');
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] != 'initialize') continue;
    await File($startedPath).writeAsString('started');
    while (!File($releasePath).existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
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
''');
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
    );
    final connecting = client.connect();

    try {
      await _waitForFile(startedFile);
      final connectionFailure = expectLater(connecting, throwsA(anything));
      await client.dispose().timeout(const Duration(seconds: 2));

      await connectionFailure.timeout(const Duration(seconds: 2));
      final agentPid = int.parse(await pidFile.readAsString());
      expect(Process.killPid(agentPid, ProcessSignal.sigterm), isFalse);
    } finally {
      await releaseFile.writeAsString('release');
      try {
        await connecting.timeout(const Duration(seconds: 2));
      } on Object {
        // A disposed pending connection must settle with an error.
      }
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('starts stdio agent in configured working directory', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final launchDir = Directory('${tempDir.path}/launch-root');
    await launchDir.create();
    final cwdFile = File('${tempDir.path}/agent_cwd.txt');
    final cwdFilePath = jsonEncode(cwdFile.path);
    final agentScript = File('${tempDir.path}/fake_cwd_agent.dart');
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    if (message['method'] == 'initialize') {
      await File($cwdFilePath).writeAsString(Directory.current.path);
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
      agentCwd: launchDir.path,
    );

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      await _waitForFile(cwdFile);

      expect(
        await Directory(await cwdFile.readAsString()).resolveSymbolicLinks(),
        await launchDir.resolveSymbolicLinks(),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('agent exit terminates an in-flight prompt', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_crashing_agent.dart');
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
        'result': <String, dynamic>{'sessionId': 'session-crash'},
      }));
    } else if (message['method'] == 'session/prompt') {
      exit(7);
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
          .sendPrompt(sessionId: session.id, prompt: 'crash now')
          .toList()
          .timeout(const Duration(seconds: 2));

      expect(events.any((event) => event.type == AgentEventType.error), isTrue);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('accepts legacy string message chunk content', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_string_content_agent.dart');
    await agentScript.writeAsString('''
import 'dart:async';
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
        'result': <String, dynamic>{'sessionId': 'session-legacy-content'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': 'hello legacy',
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <Object>[
              ' list text',
              <String, dynamic>{'text': ' and untyped text'},
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-legacy-content',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{
              'type': 'resource',
              'resource': <String, dynamic>{
                'url': 'file:///workspace/README.md',
                'name': 'README.md',
                'mime_type': 'text/markdown',
                'content': '# Project notes',
              },
            },
          },
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 25));
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
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(
        events
            .where((event) => event.type == AgentEventType.agentTextDelta)
            .map((event) => event.text),
        [
          'hello legacy',
          ' list text and untyped text',
          'Received resource content.',
        ],
      );
      final resourceEvent = events.firstWhere(
        (event) => event.text == 'Received resource content.',
      );
      expect(resourceEvent.metadata['contentBlocks'], [
        {
          'type': 'resource',
          'resource': {
            'uri': 'file:///workspace/README.md',
            'title': 'README.md',
            'mimeType': 'text/markdown',
            'text': '# Project notes',
          },
        },
      ]);
      expect(events.last.metadata['stopReason'], 'endTurn');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
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

  test(
    'sends additional directories only when the agent advertises support',
    () async {
      final advertised = await _captureSessionSetupParams(
        advertiseAdditionalDirectories: true,
      );
      final unsupported = await _captureSessionSetupParams(
        advertiseAdditionalDirectories: false,
      );

      expect(advertised.calls.map((call) => call['method']), [
        'session/new',
        'session/resume',
        'session/fork',
      ]);
      for (final call in advertised.calls) {
        final params = call['params'] as Map<String, dynamic>;
        expect(params['additionalDirectories'], advertised.directories);
      }
      expect(advertised.listedAdditionalDirectories, advertised.directories);

      for (final call in unsupported.calls) {
        final params = call['params'] as Map<String, dynamic>;
        expect(params, isNot(contains('additionalDirectories')));
      }
      expect(unsupported.listedAdditionalDirectories, unsupported.directories);
    },
  );

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

  test('ignores inline email addresses and empty prompt mentions', () async {
    final promptParams = await _capturePromptParamsForAttachment(
      includeAttachment: false,
      prompt: 'Email dev@example.com, inspect @notes.md, ignore @.',
      extraFiles: const {'notes.md': '# Notes'},
    );
    final prompt = promptParams['prompt'] as List<dynamic>;

    expect(prompt, hasLength(2));
    expect(prompt.first, {
      'type': 'text',
      'text': 'Email dev@example.com, inspect @notes.md, ignore @.',
    });
    final mention = prompt[1] as Map<String, dynamic>;
    expect(mention['type'], 'resource_link');
    expect(mention['name'], 'notes.md');
    expect(mention['uri'], endsWith('/notes.md'));
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
      'session_id': 'session-1',
      'update': update,
    },
  });
}

Future<void> main() async {
  var promptCount = 0;
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
      promptCount += 1;
      if (promptCount == 2) {
        sendSessionUpdate(<String, dynamic>{
          'sessionUpdate': 'tool_call_update',
          'tool_call_id': 'call-a',
          'status': 'pending',
          'raw_output': 'new orphan update',
        });
        await Future<void>.delayed(const Duration(milliseconds: 25));
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'stopReason': 'end_turn'},
        });
        continue;
      }
      sendSessionUpdate(<String, dynamic>{
        'sessionUpdate': 'tool_call',
        'tool_call_id': 'call-a',
        'title': 'Bash A',
        'status': 'pending',
        'content': 'running A',
        'locations': <Object>[
          '/workspace/a.dart',
          <String, dynamic>{'path': '/workspace/b.dart', 'line': 7},
        ],
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
      expect(toolEvents.map((event) => event.metadata['status']), [
        'pending',
        'pending',
        'completed',
        'completed',
      ]);
      expect(toolEvents[2].text, 'Bash A');
      expect(toolEvents.first.metadata['content'], 'running A');
      expect(
        toolEvents.first.metadata['locations'],
        contains('/workspace/a.dart'),
      );
      expect(toolEvents[2].metadata['title'], 'Bash A');
      expect(toolEvents[2].metadata['status'], 'completed');
      expect(toolEvents[2].metadata['rawOutput'], 'a done');
      expect(toolEvents[3].text, 'Bash B');
      expect(toolEvents[3].metadata['title'], 'Bash B');
      expect(toolEvents[3].metadata['status'], 'completed');
      expect(toolEvents[3].metadata['rawOutput'], 'b done');

      final reusedEvents = await client
          .sendPrompt(sessionId: session.id, prompt: 'run orphan update')
          .toList()
          .timeout(const Duration(seconds: 5));
      final reusedToolEvents = reusedEvents
          .where((event) => event.type == AgentEventType.toolCall)
          .toList();

      expect(reusedToolEvents, hasLength(1));
      expect(reusedToolEvents.single.text, 'call-a');
      expect(reusedToolEvents.single.metadata['toolCallId'], 'call-a');
      expect(reusedToolEvents.single.metadata['title'], isNull);
      expect(reusedToolEvents.single.metadata['status'], 'pending');
      expect(
        reusedToolEvents.single.metadata['rawOutput'],
        'new orphan update',
      );
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

  test('rejects filesystem read requests without a session id', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final workspace = Directory('${tempDir.path}/workspace');
    await workspace.create();
    await File('${workspace.path}/fixture.txt').writeAsString('private data');
    final fsResponseFile = File('${tempDir.path}/fs_response.json');
    final agentScript = File('${tempDir.path}/fake_fs_missing_session.dart');
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
        'id': 'fs-read-missing-session',
        'method': 'fs/read_text_file',
        'params': <String, dynamic>{'path': 'fixture.txt'},
      }));
    } else if (message['id'] == 'fs-read-missing-session') {
      await File($fsResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

    final client = DartAcpAgentClient(
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
      await client.createSession(cwd: workspace.path);
      await _waitForFile(fsResponseFile);

      final response =
          jsonDecode(await fsResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(response['id'], 'fs-read-missing-session');
      expect(response, contains('error'));
      expect(response, isNot(contains('result')));
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  for (final scenario in const [
    (
      name: 'filesystem read with unknown session',
      method: 'fs/read_text_file',
      sessionId: 'unknown-session',
    ),
    (
      name: 'filesystem write without session',
      method: 'fs/write_text_file',
      sessionId: null,
    ),
    (
      name: 'filesystem write with unknown session',
      method: 'fs/write_text_file',
      sessionId: 'unknown-session',
    ),
    (
      name: 'permission without session',
      method: 'session/request_permission',
      sessionId: null,
    ),
    (
      name: 'permission with unknown session',
      method: 'session/request_permission',
      sessionId: 'unknown-session',
    ),
  ]) {
    test('rejects ${scenario.name}', () async {
      final result = await _runInvalidSessionRequest(
        method: scenario.method,
        sessionId: scenario.sessionId,
      );

      expect(result.response, contains('error'));
      expect(result.response, isNot(contains('result')));
      expect(result.permissionRequestCount, 0);
      expect(result.writeTargetExists, isFalse);
    });
  }

  test(
    'rejects reusing a session id with a different workspace root',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_reused_session_id.dart');
      await agentScript.writeAsString(r'''
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
              'additionalDirectories': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'reused-session'},
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
        await client.createSession(
          cwd: '/workspace/first',
          additionalDirectories: const ['/workspace/a', '/workspace/b'],
        );

        await client.createSession(
          cwd: '/workspace/first',
          additionalDirectories: const ['/workspace/b', '/workspace/a'],
        );

        await expectLater(
          client.createSession(
            cwd: '/workspace/first',
            additionalDirectories: const ['/workspace/a', '/workspace/c'],
          ),
          throwsA(isA<StateError>()),
        );

        await expectLater(
          client.createSession(cwd: '/workspace/second'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('already bound'),
            ),
          ),
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test(
    'failed resume rolls back only newly registered session state',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File(
        '${tempDir.path}/fake_resume_rollback_agent.dart',
      );
      await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  var resumeCount = 0;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'resume': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      resumeCount += 1;
      if (resumeCount == 1 || resumeCount == 3) {
        if (resumeCount == 1) {
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-rollback',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'stale-mode',
              },
            },
          });
        }
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': <String, dynamic>{
            'code': -32000,
            'message': 'resume failed',
          },
        });
      } else {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
      }
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

      final client = await acp.AcpClient.start(
        config: acp.AcpConfig(
          agentCommand: _dartExecutable(),
          agentArgs: [agentScript.path],
        ),
      );
      var sessionUpdatesDone = false;
      final sessionUpdates = client
          .sessionUpdates('session-rollback')
          .listen((_) {}, onDone: () => sessionUpdatesDone = true);

      try {
        await client.initialize().timeout(const Duration(seconds: 5));
        await pumpEventQueue();

        await expectLater(
          client.resumeSession(
            sessionId: 'session-rollback',
            workspaceRoot: '/workspace/wrong',
          ),
          throwsA(anything),
        );
        await pumpEventQueue();
        expect(sessionUpdatesDone, isFalse);
        expect(client.sessionModes('session-rollback'), isNull);
        expect(
          () => client.prompt(
            sessionId: 'session-rollback',
            content: 'must be invalid',
          ),
          throwsA(isA<StateError>()),
        );

        await client.resumeSession(
          sessionId: 'session-rollback',
          workspaceRoot: '/workspace/correct',
        );
        await expectLater(
          client.resumeSession(
            sessionId: 'session-rollback',
            workspaceRoot: '/workspace/correct',
          ),
          throwsA(anything),
        );

        await client
            .prompt(sessionId: 'session-rollback', content: 'still valid')
            .drain<void>()
            .timeout(const Duration(seconds: 5));
      } finally {
        await sessionUpdates.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  for (final operation in const <String>['new', 'fork']) {
    test(
      '$operation registration waits for a failed resume rollback',
      () => _expectGeneratedSessionRegistrationAfterFailedResume(operation),
    );
  }

  test('failed retry preserves updates owned by an existing session', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_existing_session_retry_agent.dart',
    );
    await agentScript.writeAsString(r'''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  var resumeCount = 0;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{'resume': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      resumeCount += 1;
      if (resumeCount == 1) {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
      } else {
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'existing-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'current_mode_update',
              'currentModeId': 'retry-mode',
            },
          },
        });
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'existing-session',
            'update': <String, dynamic>{
              'sessionUpdate': 'tool_call',
              'toolCallId': 'retry-call',
              'status': 'in_progress',
              'title': 'Preserved tool',
              'kind': 'execute',
            },
          },
        });
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'error': <String, dynamic>{
            'code': -32000,
            'message': 'retry failed',
          },
        });
      }
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'existing-session',
          'update': <String, dynamic>{
            'sessionUpdate': 'tool_call_update',
            'toolCallId': 'retry-call',
            'status': 'completed',
            'rawOutput': 'done',
          },
        },
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      ),
    );

    try {
      await client.initialize().timeout(const Duration(seconds: 5));
      await client.resumeSession(
        sessionId: 'existing-session',
        workspaceRoot: '/workspace/existing',
      );

      await expectLater(
        client.resumeSession(
          sessionId: 'existing-session',
          workspaceRoot: '/workspace/existing',
        ),
        throwsA(anything),
      );
      await pumpEventQueue();

      expect(
        client.sessionModes('existing-session')?.currentModeId,
        'retry-mode',
      );
      final replay = await client
          .sessionUpdates('existing-session')
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));
      expect(replay.whereType<acp.ModeUpdate>(), hasLength(1));
      expect(
        replay.whereType<acp.ToolCallUpdate>().single.toolCall.title,
        'Preserved tool',
      );

      final promptToolUpdate = await client
          .prompt(sessionId: 'existing-session', content: 'finish tool')
          .where((update) => update is acp.ToolCallUpdate)
          .cast<acp.ToolCallUpdate>()
          .single
          .timeout(const Duration(seconds: 5));
      expect(promptToolUpdate.toolCall.title, 'Preserved tool');
      expect(promptToolUpdate.toolCall.rawOutput, 'done');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('session manager prompt requires a workspace binding', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
    final updates = manager.sessionUpdates('unbound-session').listen((_) {});

    try {
      await pumpEventQueue();

      expect(
        () => manager.prompt(
          sessionId: 'unbound-session',
          content: const <Map<String, dynamic>>[],
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      await updates.cancel();
      await manager.dispose();
      await peer.close();
      await channel.local.sink.close();
    }
  });

  test(
    'session updates drop unknown sessions but accept load-time updates after binding',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final updates = <acp.AcpUpdate>[];
      final subscription = manager
          .sessionUpdates('session-route')
          .listen(updates.add);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/load') return;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-route',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'bound',
              },
            },
          }),
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      });

      try {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'session-route',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'unbound',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(updates, isEmpty);

        await manager.loadSession(
          sessionId: 'session-route',
          workspaceRoot: '/workspace',
        );
        await pumpEventQueue();

        expect(
          updates.whereType<acp.ModeUpdate>().single.currentModeId,
          'bound',
        );
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'session replay is item bounded and carries a truncation marker',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxReplayItems: 3,
        maxReplayBytes: 64 * 1024,
      );
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'bounded-replay',
          workspaceRoot: '/workspace',
        );
        for (var index = 0; index < 5; index += 1) {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'method': 'session/update',
              'params': <String, dynamic>{
                'sessionId': 'bounded-replay',
                'update': <String, dynamic>{
                  'sessionUpdate': 'current_mode_update',
                  'currentModeId': 'mode-$index',
                },
              },
            }),
          );
        }
        await pumpEventQueue();

        final replay = await manager
            .sessionUpdates('bounded-replay')
            .take(3)
            .toList();
        expect(replay, hasLength(3));
        expect(
          (replay.first as acp.UnknownUpdate).raw['sessionUpdate'],
          'replay_truncated',
        );
        expect(
          replay.whereType<acp.ModeUpdate>().map(
            (update) => update.currentModeId,
          ),
          ['mode-3', 'mode-4'],
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('session replay is UTF-8 byte bounded', () async {
    final channel = StreamChannelController<String>();
    final peer = JsonRpcPeer(channel.foreign);
    final manager = SessionManager(
      config: acp.AcpConfig(),
      peer: peer,
      maxReplayItems: 10,
      maxReplayBytes: 64,
    );
    final server = channel.local.stream.listen((line) {
      final request = jsonDecode(line) as Map<String, dynamic>;
      if (request['method'] == 'session/resume') {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{},
          }),
        );
      }
    });
    try {
      await manager.resumeSession(
        sessionId: 'byte-replay',
        workspaceRoot: '/workspace',
      );
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': <String, dynamic>{
            'sessionId': 'byte-replay',
            'update': <String, dynamic>{
              'sessionUpdate': 'agent_message_chunk',
              'content': <String, dynamic>{'type': 'text', 'text': '界' * 80},
            },
          },
        }),
      );
      await pumpEventQueue();
      final replay = await manager
          .sessionUpdates('byte-replay')
          .take(1)
          .toList();
      expect((replay.single as acp.UnknownUpdate).raw['truncated'], isTrue);
    } finally {
      await manager.dispose();
      await peer.close();
      await server.cancel();
      await channel.local.sink.close();
    }
  });

  test(
    'tool state evicts completed calls before reporting a manual limit error',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(
        config: acp.AcpConfig(),
        peer: peer,
        maxToolCallItems: 2,
        maxToolCallBytes: 150,
      );
      final errors = <Object>[];
      final subscription = manager
          .sessionUpdates('bounded-tools')
          .listen((_) {}, onError: errors.add);
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        }
      });

      void sendTool(String id, String status) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'bounded-tools',
              'update': <String, dynamic>{
                'sessionUpdate': 'tool_call',
                'toolCallId': id,
                'title': id,
                'status': status,
              },
            },
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'bounded-tools',
          workspaceRoot: '/workspace',
        );
        sendTool('active-a', 'in_progress');
        sendTool('completed', 'completed');
        sendTool('active-b', 'in_progress');
        await pumpEventQueue();
        expect(
          errors,
          isEmpty,
          reason: 'completed state should be evicted first',
        );

        sendTool('active-c', 'in_progress');
        await pumpEventQueue();
        expect(errors.single, isA<acp.SessionToolStateLimitException>());
        expect(
          errors.single.toString(),
          contains('manual intervention required'),
        );
        expect(errors.single.toString(), isNot(contains('active-c')));
      } finally {
        await subscription.cancel();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'session manager close drops later updates and preserves state on RPC failure',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      var failClose = true;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        final method = request['method'];
        if (method == 'session/resume') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': request['id'],
              if (failClose)
                'error': <String, dynamic>{'code': -32000, 'message': 'failed'}
              else
                'result': <String, dynamic>{},
            }),
          );
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'close-state',
          workspaceRoot: '/workspace',
        );
        await expectLater(
          manager.closeSession(sessionId: 'close-state'),
          throwsA(anything),
        );
        expect(manager.getWorkspaceRoot('close-state'), '/workspace');

        failClose = false;
        await manager.closeSession(sessionId: 'close-state');
        expect(() => manager.getWorkspaceRoot('close-state'), throwsStateError);
        expect(manager.sessionModes('close-state'), isNull);

        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'close-state',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('close-state'), isNull);
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'close releases only owned terminals and aggregates cleanup failures',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final provider = _RecordingTerminalProvider(
        failReleaseIds: {'terminal-1'},
      );
      final manager = SessionManager(
        config: acp.AcpConfig(
          terminalProvider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
        ),
        peer: peer,
      );
      final terminalResponses = <String, Completer<void>>{};
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else {
          terminalResponses[message['id']?.toString()]?.complete();
        }
      });

      Future<void> createTerminal(String sessionId, String requestId) async {
        final response = Completer<void>();
        terminalResponses[requestId] = response;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': requestId,
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': sessionId,
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await response.future.timeout(const Duration(seconds: 5));
      }

      try {
        await manager.resumeSession(
          sessionId: 'session-a',
          workspaceRoot: '/a',
        );
        await manager.resumeSession(
          sessionId: 'session-b',
          workspaceRoot: '/b',
        );
        await createTerminal('session-a', 'create-a1');
        await createTerminal('session-a', 'create-a2');
        await createTerminal('session-b', 'create-b1');

        await expectLater(
          manager.closeSession(sessionId: 'session-a'),
          throwsA(isA<acp.SessionCloseCleanupException>()),
        );
        expect(
          provider.releaseAttempts,
          containsAll(['terminal-1', 'terminal-2']),
        );
        expect(provider.releaseAttempts, isNot(contains('terminal-3')));
        expect(() => manager.getWorkspaceRoot('session-a'), throwsStateError);
        expect(manager.getWorkspaceRoot('session-b'), '/b');
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'paused session listener does not block close cleanup or leak provider errors',
    () async {
      const providerSecret = 'terminal-release-provider-secret';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final provider = _RecordingTerminalProvider(
        failReleaseIds: const <String>{'terminal-1'},
        releaseErrorMessage: providerSecret,
      );
      final config = acp.AcpConfig(
        terminalProvider: provider,
        permissionProvider: acp.DefaultPermissionProvider(
          onRequest: (_) async => const acp.PermissionDecision.allow(),
        ),
      );
      final logs = <String>[];
      final logSubscription = config.logger.onRecord.listen(
        (record) => logs.add(record.message),
      );
      final manager = SessionManager(config: config, peer: peer);
      final terminalCreated = Completer<void>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['id'] == 'paused-terminal') {
          terminalCreated.complete();
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'paused-close',
          workspaceRoot: '/workspace',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'paused-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'seeded-mode',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(
          manager.sessionModes('paused-close')?.currentModeId,
          'seeded-mode',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'paused-terminal',
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'paused-close',
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await terminalCreated.future.timeout(const Duration(seconds: 5));
        final updates = manager.sessionUpdates('paused-close').listen((_) {});
        updates.pause();

        await expectLater(
          manager
              .closeSession(sessionId: 'paused-close')
              .timeout(const Duration(seconds: 1)),
          throwsA(isA<acp.SessionCloseCleanupException>()),
        );

        expect(provider.releaseAttempts, ['terminal-1']);
        expect(
          () => manager.getWorkspaceRoot('paused-close'),
          throwsStateError,
        );
        expect(manager.sessionModes('paused-close'), isNull);
        expect(logs.join('\n'), contains('terminals'));
        expect(logs.join('\n'), isNot(contains(providerSecret)));
        await updates.cancel();
      } finally {
        await manager.dispose();
        await logSubscription.cancel();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'late terminal create is released and never registered after close',
    () async {
      const providerSecret = 'late-terminal-release-secret';
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final createBarrier = Completer<void>();
      final createStarted = Completer<void>();
      final provider = _RecordingTerminalProvider(
        failReleaseIds: const <String>{'terminal-1'},
        releaseErrorMessage: providerSecret,
        createBarrier: createBarrier,
        createStarted: createStarted,
      );
      final manager = SessionManager(
        config: acp.AcpConfig(
          terminalProvider: provider,
          permissionProvider: acp.DefaultPermissionProvider(
            onRequest: (_) async => const acp.PermissionDecision.allow(),
          ),
        ),
        peer: peer,
      );
      final terminalResponse = Completer<Map<String, dynamic>>();
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        final method = message['method'];
        if (method == 'session/resume' || method == 'session/close') {
          channel.local.sink.add(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{},
            }),
          );
        } else if (message['id'] == 'late-terminal' &&
            !terminalResponse.isCompleted) {
          terminalResponse.complete(message);
        }
      });

      try {
        await manager.resumeSession(
          sessionId: 'terminal-race',
          workspaceRoot: '/workspace',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'late-terminal',
            'method': 'terminal/create',
            'params': <String, dynamic>{
              'sessionId': 'terminal-race',
              'command': 'unused',
              'args': <String>[],
            },
          }),
        );
        await createStarted.future.timeout(const Duration(seconds: 5));

        await manager.closeSession(sessionId: 'terminal-race');
        createBarrier.complete();
        final response = await terminalResponse.future.timeout(
          const Duration(seconds: 5),
        );

        expect(response, contains('error'));
        expect(response.toString(), contains('closing or closed'));
        expect(response.toString(), isNot(contains(providerSecret)));
        expect(provider.releaseAttempts, ['terminal-1']);
        expect(await manager.readTerminalOutput('terminal-1'), isEmpty);
      } finally {
        if (!createBarrier.isCompleted) createBarrier.complete();
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'concurrent close owners reject queued setup and late registration',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      final closeRequestIds = <Object?>[];
      final closeRequestsReady = Completer<void>();
      final newRequestId = Completer<Object?>();
      var resumeRequests = 0;
      var loadRequests = 0;
      final server = channel.local.stream.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        switch (message['method']) {
          case 'session/resume':
            resumeRequests += 1;
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': message['id'],
                'result': <String, dynamic>{},
              }),
            );
            break;
          case 'session/load':
            loadRequests += 1;
            channel.local.sink.add(
              jsonEncode(<String, dynamic>{
                'jsonrpc': '2.0',
                'id': message['id'],
                'result': <String, dynamic>{},
              }),
            );
            break;
          case 'session/new':
            if (!newRequestId.isCompleted) newRequestId.complete(message['id']);
            break;
          case 'session/close':
            closeRequestIds.add(message['id']);
            if (closeRequestIds.length == 2 &&
                !closeRequestsReady.isCompleted) {
              closeRequestsReady.complete();
            }
            break;
        }
      });

      void respond(Object? id, Map<String, dynamic> result) {
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': result,
          }),
        );
      }

      try {
        await manager.resumeSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        final lateRegistration = manager.newSession(
          workspaceRoot: '/workspace',
        );
        final lateRegistrationFailure = expectLater(
          lateRegistration,
          throwsStateError,
        );
        final pendingNewId = await newRequestId.future.timeout(
          const Duration(seconds: 5),
        );

        final closeOne = manager.closeSession(sessionId: 'shared-close');
        final closeTwo = manager.closeSession(sessionId: 'shared-close');
        await closeRequestsReady.future.timeout(const Duration(seconds: 5));

        final queuedResumeFailure = expectLater(
          manager.resumeSession(
            sessionId: 'shared-close',
            workspaceRoot: '/workspace',
          ),
          throwsStateError,
        );
        final queuedLoadFailure = expectLater(
          manager.loadSession(
            sessionId: 'shared-close',
            workspaceRoot: '/workspace',
          ),
          throwsStateError,
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop-during-close',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('shared-close'), isNull);

        respond(closeRequestIds.first, const <String, dynamic>{});
        await closeOne;
        respond(pendingNewId, const <String, dynamic>{
          'sessionId': 'shared-close',
        });
        await lateRegistrationFailure;
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'must-drop-late-registration',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(manager.sessionModes('shared-close'), isNull);

        respond(closeRequestIds.last, const <String, dynamic>{});
        await closeTwo;
        await queuedResumeFailure;
        await queuedLoadFailure;
        expect(resumeRequests, 1, reason: 'queued resume must not reach peer');
        expect(loadRequests, 0, reason: 'queued load must not reach peer');

        await manager.resumeSession(
          sessionId: 'shared-close',
          workspaceRoot: '/workspace',
        );
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{
              'sessionId': 'shared-close',
              'update': <String, dynamic>{
                'sessionUpdate': 'current_mode_update',
                'currentModeId': 'accepted-after-close',
              },
            },
          }),
        );
        await pumpEventQueue();
        expect(
          manager.sessionModes('shared-close')?.currentModeId,
          'accepted-after-close',
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test('session replay rejects every byte budget below its marker size', () {
    for (var maxBytes = 1; maxBytes < 64; maxBytes += 1) {
      expect(
        () => DartAcpAgentClient(
          agentCommand: 'unused',
          maxSessionReplayBytes: maxBytes,
        ),
        throwsArgumentError,
        reason: 'maxSessionReplayBytes=$maxBytes',
      );
    }
    expect(
      () =>
          DartAcpAgentClient(agentCommand: 'unused', maxSessionReplayBytes: 64),
      returnsNormally,
    );
  });

  test(
    'fork requires a known or explicit workspace before contacting agent',
    () async {
      final channel = StreamChannelController<String>();
      final peer = JsonRpcPeer(channel.foreign);
      final manager = SessionManager(config: acp.AcpConfig(), peer: peer);
      var forkRequestCount = 0;
      final server = channel.local.stream.listen((line) {
        final request = jsonDecode(line) as Map<String, dynamic>;
        if (request['method'] != 'session/fork') return;
        forkRequestCount += 1;
        final params = request['params'] as Map<String, dynamic>;
        final generatedId = params.containsKey('cwd')
            ? 'explicit-fork'
            : 'unexpected-fork';
        channel.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': request['id'],
            'result': <String, dynamic>{'sessionId': generatedId},
          }),
        );
      });

      try {
        Object? missingRootError;
        try {
          await manager.forkSession(sessionId: 'unknown-source');
        } catch (error) {
          missingRootError = error;
        }

        expect(missingRootError, isA<StateError>());
        expect(forkRequestCount, 0);
        expect(
          () => manager.prompt(
            sessionId: 'unexpected-fork',
            content: const <Map<String, dynamic>>[],
          ),
          throwsArgumentError,
        );

        final explicit = await manager.forkSession(
          sessionId: 'unknown-source',
          workspaceRoot: '/workspace/explicit',
        );
        expect(explicit.sessionId, 'explicit-fork');
        expect(forkRequestCount, 1);
        expect(
          manager.getWorkspaceRoot('explicit-fork'),
          '/workspace/explicit',
        );
      } finally {
        await manager.dispose();
        await peer.close();
        await server.cancel();
        await channel.local.sink.close();
      }
    },
  );

  test(
    'filesystem provider allows configured additional directories',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final workspace = Directory('${tempDir.path}/workspace');
      final extraWorkspace = Directory('${tempDir.path}/extra-workspace');
      await workspace.create();
      await extraWorkspace.create();
      final extraFixture = File('${extraWorkspace.path}/fixture.txt');
      final extraCreated = File('${extraWorkspace.path}/created.txt');
      final outsideFile = File('${tempDir.path}/outside.txt');
      await extraFixture.writeAsString('hello extra');
      final readResponseFile = File('${tempDir.path}/fs_read_response.json');
      final writeResponseFile = File('${tempDir.path}/fs_write_response.json');
      final outsideResponseFile = File(
        '${tempDir.path}/fs_outside_response.json',
      );
      final agentScript = File('${tempDir.path}/fake_fs_extra_agent.dart');
      final readResponsePath = jsonEncode(readResponseFile.path);
      final writeResponsePath = jsonEncode(writeResponseFile.path);
      final outsideResponsePath = jsonEncode(outsideResponseFile.path);
      final extraFixturePath = jsonEncode(extraFixture.path);
      final extraCreatedPath = jsonEncode(extraCreated.path);
      final outsidePath = jsonEncode(outsideFile.path);
      await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void request(String id, String method, Map<String, dynamic> params) {
  stdout.writeln(jsonEncode(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': id,
    'method': method,
    'params': params,
  }));
}

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
              'additionalDirectories': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-fs'},
      }));
      request('fs-read-extra', 'fs/read_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $extraFixturePath,
      });
      request('fs-write-extra', 'fs/write_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $extraCreatedPath,
        'content': 'created in extra workspace',
      });
      request('fs-write-outside', 'fs/write_text_file', <String, dynamic>{
        'sessionId': 'session-fs',
        'path': $outsidePath,
        'content': 'outside',
      });
    } else if (message['id'] == 'fs-read-extra') {
      await File($readResponsePath).writeAsString(jsonEncode(message));
    } else if (message['id'] == 'fs-write-extra') {
      await File($writeResponsePath).writeAsString(jsonEncode(message));
    } else if (message['id'] == 'fs-write-outside') {
      await File($outsideResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      late final DartAcpAgentClient client;
      client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
        additionalDirectories: [extraWorkspace.path],
        enableFilesystemReadTextFile: true,
        enableFilesystemWriteTextFile: true,
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
        await _waitForFile(readResponseFile);
        await _waitForFile(writeResponseFile);
        await _waitForFile(outsideResponseFile);

        final readResponse =
            jsonDecode(await readResponseFile.readAsString())
                as Map<String, dynamic>;
        final writeResponse =
            jsonDecode(await writeResponseFile.readAsString())
                as Map<String, dynamic>;
        final outsideResponse =
            jsonDecode(await outsideResponseFile.readAsString())
                as Map<String, dynamic>;

        expect(readResponse['result'], containsPair('content', 'hello extra'));
        expect(writeResponse, containsPair('result', null));
        expect(await extraCreated.readAsString(), 'created in extra workspace');
        expect(outsideResponse, contains('error'));
        expect(await outsideFile.exists(), isFalse);
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

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
        'env': <Map<String, String>>[
          <String, String>{
            'name': 'EXFIL_URL',
            'value': 'https://collector.example/private-secret',
          },
        ],
        'outputByteLimit': 8,
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
      expect(permissionRequests.single.metadata['envKeys'], ['EXFIL_URL']);
      expect(
        permissionRequests.single.metadata.toString(),
        isNot(contains('private-secret')),
      );
      expect(
        permissionRequests.single.transientPolicyContext['environment'],
        containsPair('EXFIL_URL', 'https://collector.example/private-secret'),
      );
      expect(
        permissionRequests.single.toJson().toString(),
        isNot(contains('private-secret')),
      );

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
        'l-output',
      );
      expect(
        terminalEvents
            .where((event) => event.metadata['terminalEvent'] == 'output')
            .single
            .metadata['truncated'],
        isTrue,
      );
      expect(events.last.metadata['stopReason'], 'endTurn');

      final terminalResponse =
          jsonDecode(await terminalResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(terminalResponse['result'], <String, Object?>{
        'output': 'l-output',
        'truncated': true,
        'exitStatus': <String, Object?>{'exitCode': 0},
      });
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('cancelled turn does not cancel permissions in the next turn', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final firstPromptStartedFile = File('${tempDir.path}/first_prompt_started');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File('${tempDir.path}/fake_cancelled_turn_agent.dart');
    final firstPromptStartedPath = jsonEncode(firstPromptStartedFile.path);
    final permissionResponsePath = jsonEncode(permissionResponseFile.path);
    await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  Object? firstPromptId;
  Object? secondPromptId;
  var promptCount = 0;
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
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (message['method'] == 'session/prompt') {
      promptCount += 1;
      if (promptCount == 1) {
        firstPromptId = message['id'];
        await File($firstPromptStartedPath).writeAsString('started');
      } else {
        secondPromptId = message['id'];
        stdout.writeln(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'permission-second-turn',
          'method': 'session/request_permission',
          'params': <String, dynamic>{
            'sessionId': 'session-1',
            'toolCall': <String, dynamic>{
              'title': 'Run second turn command',
              'kind': 'execute',
            },
            'options': <Map<String, dynamic>>[
              <String, dynamic>{
                'optionId': 'allow-once',
                'kind': 'allow_once',
                'name': 'Allow once',
              },
              <String, dynamic>{
                'optionId': 'reject-once',
                'kind': 'reject_once',
                'name': 'Reject once',
              },
            ],
          },
        }));
      }
    } else if (message['method'] == 'session/cancel') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': firstPromptId,
        'result': <String, dynamic>{'stopReason': 'cancelled'},
      }));
    } else if (message['id'] == 'permission-second-turn') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': secondPromptId,
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
    final secondPermission = Completer<AcpPermissionRequest>();
    final subscription = client.permissionRequests.listen((request) {
      if (!secondPermission.isCompleted) {
        secondPermission.complete(request);
      }
    });

    try {
      await client.connect().timeout(const Duration(seconds: 5));
      final session = await client.createSession(cwd: '/workspace');

      final firstTurn = client
          .sendPrompt(sessionId: session.id, prompt: 'first turn')
          .toList();
      await _waitForFile(firstPromptStartedFile);
      await client.cancel();
      await firstTurn.timeout(const Duration(seconds: 5));

      final secondTurn = client
          .sendPrompt(sessionId: session.id, prompt: 'second turn')
          .toList();
      final request = await secondPermission.future.timeout(
        const Duration(seconds: 5),
      );
      expect(request.sessionId, 'session-1');
      await client.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.allow,
        selectedOptionId: 'allow-once',
      );
      await secondTurn.timeout(const Duration(seconds: 5));

      await _waitForFile(permissionResponseFile);
      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('optionId', 'allow-once')),
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
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
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
              'optionId': 'allow-always',
              'kind': 'allow_always',
              'name': 'Always allow',
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
        await client.createSession(cwd: '/workspace');
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
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
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
              'optionId': 'allow-always',
              'kind': 'allow_always',
              'name': 'Always allow',
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
            selectedOptionId: 'allow-always',
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        await _waitForFile(permissionResponseFile);

        expect(request.displayTitle, 'Read file');
        expect(request.displayKind, 'read');
        expect(request.choices.map((choice) => choice.optionId), const [
          'allow',
          'allow-always',
          'deny',
        ]);
        expect(request.choices.map((choice) => choice.kind), const [
          'allow_once',
          'allow_always',
          'reject_once',
        ]);
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
          containsPair('outcome', containsPair('optionId', 'allow-always')),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  for (final scenario in const [
    (
      name: 'does not turn deny into the only allow option',
      optionId: 'allow-once',
      optionKind: 'allow_once',
      optionName: 'Allow once',
      decision: AcpPermissionDecision.deny,
    ),
    (
      name: 'does not turn allow into the only reject option',
      optionId: 'reject-once',
      optionKind: 'reject_once',
      optionName: 'Reject once',
      decision: AcpPermissionDecision.allow,
    ),
  ]) {
    test(scenario.name, () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_single_permission_agent.dart',
      );
      final permissionResponsePath = jsonEncode(permissionResponseFile.path);
      final optionId = jsonEncode(scenario.optionId);
      final optionKind = jsonEncode(scenario.optionKind);
      final optionName = jsonEncode(scenario.optionName);
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
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-single',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Single choice',
            'kind': 'execute',
          },
          'options': <Map<String, dynamic>>[
            <String, dynamic>{
              'optionId': $optionId,
              'kind': $optionKind,
              'name': $optionName,
            },
          ],
        },
      }));
    } else if (message['id'] == 'permission-single') {
      await File($permissionResponsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

      final client = DartAcpAgentClient(
        agentCommand: _dartExecutable(),
        agentArgs: [agentScript.path],
      );
      final subscription = client.permissionRequests.listen((request) {
        unawaited(
          client.respondToPermissionRequest(
            id: request.id,
            decision: scenario.decision,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        await _waitForFile(permissionResponseFile);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;

        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'cancelled')),
        );
        expect(
          jsonEncode(permissionResponse),
          isNot(contains(scenario.optionId)),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }

  for (final scenario in const [
    (
      name: 'selects allow for string permission options',
      decision: AcpPermissionDecision.allow,
      expectedOptionId: 'allow',
    ),
    (
      name: 'selects deny for string permission options',
      decision: AcpPermissionDecision.deny,
      expectedOptionId: 'deny',
    ),
  ]) {
    test(scenario.name, () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final permissionResponseFile = File(
        '${tempDir.path}/permission_response.json',
      );
      final agentScript = File(
        '${tempDir.path}/fake_string_permission_agent.dart',
      );
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
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-strings',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'title': 'Run command',
            'kind': 'execute',
          },
          'options': <String>['always allow', 'allow', 'deny'],
        },
      }));
    } else if (message['id'] == 'permission-strings') {
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
            decision: scenario.decision,
          ),
        );
      });

      try {
        await client.connect().timeout(const Duration(seconds: 5));
        await client.createSession(cwd: '/workspace');
        final request = await requestCompleter.future.timeout(
          const Duration(seconds: 5),
        );
        await _waitForFile(permissionResponseFile);

        expect(request.options, const ['always allow', 'allow', 'deny']);
        final permissionResponse =
            jsonDecode(await permissionResponseFile.readAsString())
                as Map<String, dynamic>;
        expect(permissionResponse['id'], 'permission-strings');
        expect(
          permissionResponse['result'],
          containsPair('outcome', containsPair('outcome', 'selected')),
        );
        expect(
          permissionResponse['result'],
          containsPair(
            'outcome',
            containsPair('optionId', scenario.expectedOptionId),
          ),
        );
      } finally {
        await subscription.cancel();
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    });
  }

  test('accepts legacy permission tool call aliases', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final permissionResponseFile = File(
      '${tempDir.path}/permission_response.json',
    );
    final agentScript = File(
      '${tempDir.path}/fake_permission_alias_agent.dart',
    );
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
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'permission-aliases',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-1',
          'toolCall': <String, dynamic>{
            'tool_call_id': 'call-1',
            'tool_name': 'Bash',
            'tool_kind': 'execute',
            'raw_input': <String, dynamic>{'command': 'echo hi'},
          },
          'options': <String>['allow', 'deny'],
        },
      }));
    } else if (message['id'] == 'permission-aliases') {
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
      await client.createSession(cwd: '/workspace');
      final request = await requestCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      await _waitForFile(permissionResponseFile);

      expect(request.displayTitle, 'Bash');
      expect(request.toolName, 'Bash');
      expect(request.displayKind, 'execute');
      expect(request.toolKind, 'execute');
      expect(
        request.metadata['toolCall'],
        containsPair('raw_input', {'command': 'echo hi'}),
      );
      final permissionResponse =
          jsonDecode(await permissionResponseFile.readAsString())
              as Map<String, dynamic>;
      expect(permissionResponse['id'], 'permission-aliases');
      expect(
        permissionResponse['result'],
        containsPair('outcome', containsPair('optionId', 'allow')),
      );
    } finally {
      await subscription.cancel();
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

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

  test(
    'caches legacy raw config option payloads from session creation',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final agentScript = File('${tempDir.path}/fake_legacy_config_agent.dart');
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
          'session_id': 'session-1',
          'config_options': <Object>[
            <String, dynamic>{
              'key': 'model',
              'label': 'Model',
              'current_value': 'kimi-k2',
              'choices': <Object>[
                'kimi-k2',
                <String, dynamic>{
                  'id': 'glm-4.6',
                  'displayName': 'GLM 4.6',
                },
              ],
              'category': 'model',
            },
            <String, dynamic>{
              'config_id': 'auto_apply',
              'label': 'Auto apply',
              'type': 'boolean',
              'selected': true,
              'values': <Map<String, Object>>[
                <String, Object>{'value': true, 'label': 'On'},
                <String, Object>{'value': false, 'label': 'Off'},
              ],
            },
            'not-a-config-option',
            <String, dynamic>{'name': 'Missing id', 'currentValue': 'x'},
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
          'auto_apply',
        ]);
        expect(settings.currentModelLabel, 'kimi-k2');
        expect(
          settings.configOptions.first.options.map((choice) => choice.value),
          ['kimi-k2', 'glm-4.6'],
        );
        expect(settings.configOptions.first.options.last.name, 'GLM 4.6');
        expect(settings.configOptions.last.type, 'boolean');
        expect(settings.configOptions.last.currentValue, 'true');
        expect(
          settings.configOptions.last.options.map((choice) => choice.name),
          ['On', 'Off'],
        );
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

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
            'current_mode_id': 'plan',
            'available_modes': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'plan', 'name': 'Plan'},
              <String, dynamic>{'mode_id': 'act', 'display_name': 'Act'},
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
      expect(settings.modes.availableModes.map((mode) => mode.name), [
        'Plan',
        'Act',
      ]);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('synthesizes model config option from legacy models state', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_models_agent.dart');
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
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'current_model_id': 'kimi-k2',
            'available_models': <Map<String, dynamic>>[
              <String, dynamic>{
                'model_id': 'kimi-k2',
                'display_name': 'Kimi K2',
                'description': 'Moonshot K2',
              },
              <String, dynamic>{
                'model_id': 'kimi-pro',
                'label': 'Kimi Pro',
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

      expect(settings.configOptions, hasLength(1));
      expect(settings.modelOption?.id, 'model');
      expect(settings.modelOption?.category, 'model');
      expect(settings.currentModelLabel, 'Kimi K2');
      expect(settings.modelOption?.options.map((choice) => choice.value), [
        'kimi-k2',
        'kimi-pro',
      ]);
      expect(settings.modelOption?.options.map((choice) => choice.name), [
        'Kimi K2',
        'Kimi Pro',
      ]);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('setting synthesized model option uses session set model', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final setModelParamsFile = File('${tempDir.path}/set_model_params.json');
    final setModelParamsPath = jsonEncode(setModelParamsFile.path);
    final agentScript = File('${tempDir.path}/fake_set_model_agent.dart');
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
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'currentModelId': 'kimi-k2',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{'modelId': 'kimi-k2', 'name': 'Kimi K2'},
              <String, dynamic>{'modelId': 'kimi-pro', 'name': 'Kimi Pro'},
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/set_model') {
      await File($setModelParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'config_options': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'current_value': 'kimi-pro',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'kimi-k2', 'name': 'Kimi K2'},
                <String, dynamic>{
                  'value': 'kimi-pro',
                  'name': 'Kimi Pro Updated',
                },
              ],
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/set_config_option') {
      await File($setModelParamsPath).writeAsString(
        jsonEncode(<String, dynamic>{'wrongMethod': message['method']}),
      );
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

      final session = await client.createSession(cwd: '/workspace');
      final updatedOptions = await client.setConfigOption(
        sessionId: session.id,
        configId: 'model',
        value: 'kimi-pro',
      );
      await _waitForFile(setModelParamsFile);
      final setModelParams =
          jsonDecode(await setModelParamsFile.readAsString())
              as Map<String, dynamic>;
      final settings = await client.sessionSettings(session.id);

      expect(setModelParams, {
        'sessionId': 'session-models',
        'modelId': 'kimi-pro',
      });
      expect(updatedOptions.single.currentValue, 'kimi-pro');
      expect(updatedOptions.single.options.last.name, 'Kimi Pro Updated');
      expect(settings.currentModelLabel, 'Kimi Pro Updated');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'runtime config option updates clear synthesized model marker',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
      final setConfigParamsFile = File(
        '${tempDir.path}/set_config_params.json',
      );
      final setConfigParamsPath = jsonEncode(setConfigParamsFile.path);
      final agentScript = File(
        '${tempDir.path}/fake_models_then_config_agent.dart',
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
          'agentCapabilities': <String, dynamic>{},
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-models',
          'models': <String, dynamic>{
            'currentModelId': 'legacy-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'legacy-model',
                'name': 'Legacy Model',
              },
            ],
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-models',
          'update': <String, dynamic>{
            'sessionUpdate': 'config_option_update',
            'configOptions': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'model',
                'name': 'Model',
                'type': 'select',
                'currentValue': 'stable-a',
                'category': 'model',
                'options': <Map<String, dynamic>>[
                  <String, dynamic>{'value': 'stable-a', 'name': 'Stable A'},
                  <String, dynamic>{'value': 'stable-b', 'name': 'Stable B'},
                ],
              },
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/set_config_option') {
      await File($setConfigParamsPath).writeAsString(
        jsonEncode(message['params']),
      );
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'model',
              'name': 'Model',
              'type': 'select',
              'currentValue': 'stable-b',
              'category': 'model',
              'options': <Map<String, dynamic>>[
                <String, dynamic>{'value': 'stable-a', 'name': 'Stable A'},
                <String, dynamic>{'value': 'stable-b', 'name': 'Stable B'},
              ],
            },
          ],
        },
      }));
    } else if (message['method'] == 'session/set_model') {
      await File($setConfigParamsPath).writeAsString(
        jsonEncode(<String, dynamic>{'wrongMethod': message['method']}),
      );
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

        final session = await client.createSession(cwd: '/workspace');
        final settings = await client.sessionSettings(session.id);
        await client.setConfigOption(
          sessionId: session.id,
          configId: 'model',
          value: 'stable-b',
        );
        await _waitForFile(setConfigParamsFile);
        final setConfigParams =
            jsonDecode(await setConfigParamsFile.readAsString())
                as Map<String, dynamic>;

        expect(settings.currentModelLabel, 'Stable A');
        expect(setConfigParams, {
          'sessionId': 'session-models',
          'configId': 'model',
          'value': 'stable-b',
        });
      } finally {
        await client.dispose();
        await tempDir.delete(recursive: true);
      }
    },
  );

  test('synthesizes legacy models returned by resume and fork', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_resume_fork_models.dart');
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
              'fork': <String, dynamic>{},
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
          'models': <String, dynamic>{
            'currentModelId': 'resume-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'resume-model',
                'name': 'Resume Model',
              },
            ],
          },
        },
      }));
    } else if (message['method'] == 'session/fork') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'session-forked',
          'models': <String, dynamic>{
            'currentModelId': 'fork-model',
            'availableModels': <Map<String, dynamic>>[
              <String, dynamic>{
                'modelId': 'fork-model',
                'name': 'Fork Model',
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

      final resumeEvents = await client.resumeSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );
      final resumeSettings = await client.sessionSettings('session-resume');
      final forked = await client.forkSession(
        sessionId: 'session-resume',
        cwd: '/workspace',
      );
      final forkSettings = await client.sessionSettings(forked.id);

      expect(resumeEvents, isEmpty);
      expect(resumeSettings.currentModelLabel, 'Resume Model');
      expect(forked.id, 'session-forked');
      expect(forkSettings.currentModelLabel, 'Fork Model');
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
          'session_id': 'session-1',
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
            'availableCommands': <Object>[
              'review',
              <String, dynamic>{
                'id': 'explain',
                'summary': 'Explain the current change.',
                'schema': <String, dynamic>{'type': 'object'},
                'input': 'Optional focus',
              },
              <String, dynamic>{
                'name': 'fix',
                'description': 'Fix the current change.',
                'input': <String, dynamic>{
                  'placeholder': 'Patch instructions',
                },
              },
              42,
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
      expect(event.text, 'review, explain, fix');
      final commands = event.metadata['commands'] as List<dynamic>;
      expect(commands, hasLength(3));
      expect(commands.first, containsPair('name', 'review'));
      expect(
        commands[1],
        containsPair('description', 'Explain the current change.'),
      );
      expect(commands[1], containsPair('parameters', {'type': 'object'}));
      expect(commands[1], containsPair('input', {'hint': 'Optional focus'}));
      expect(
        commands.last,
        containsPair('description', 'Fix the current change.'),
      );
      expect(
        commands.last,
        containsPair('input', {'hint': 'Patch instructions'}),
      );
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('ignores unspecified session updates', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_unspecified_update_agent.dart',
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
            'sessionCapabilities': <String, dynamic>{},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/new') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-empty-update'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-empty-update',
          'update': <String, dynamic>{},
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

      expect(session.id, 'session-empty-update');
      expect(session.initialEvents, isEmpty);
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

  test('maps usage updates during prompt streams', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File('${tempDir.path}/fake_usage_update_agent.dart');
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
        'result': <String, dynamic>{'sessionId': 'session-usage-update'},
      }));
    } else if (message['method'] == 'session/prompt') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-usage-update',
          'update': <String, dynamic>{
            'sessionUpdate': 'usage_update',
            'used': 53000,
            'size': 200000,
            'cost': <String, dynamic>{'amount': 0.045, 'currency': 'USD'},
          },
        },
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'method': 'session/update',
        'params': <String, dynamic>{
          'sessionId': 'session-usage-update',
          'update': <String, dynamic>{
            'sessionUpdate': 'agent_message_chunk',
            'content': <String, dynamic>{'type': 'text', 'text': 'hello'},
          },
        },
      }));
      await Future<void>.delayed(const Duration(milliseconds: 25));
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
      final session = await client.createSession(cwd: '/workspace');
      final events = await client
          .sendPrompt(sessionId: session.id, prompt: 'say hi')
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(events.map((event) => event.text), contains('hello'));
      expect(
        events.map((event) => event.text),
        isNot(contains('[Unknown update: usage_update]')),
      );
      final usageEvent = events.singleWhere(
        (event) => event.metadata['kind'] == 'usage_update',
      );
      expect(usageEvent.text, 'Context 27%');
      expect(usageEvent.metadata['used'], 53000);
      expect(usageEvent.metadata['size'], 200000);
      expect(usageEvent.metadata['cost'], <String, Object?>{
        'amount': 0.045,
        'currency': 'USD',
      });
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
            'current_mode_id': 'plan',
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

  test('session resume accepts boolean config option current values', () async {
    final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
    final agentScript = File(
      '${tempDir.path}/fake_resume_boolean_config_agent.dart',
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
          'configOptions': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'thinking',
              'name': 'Thinking',
              'type': 'boolean',
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

      final events = await client.resumeSession(
        sessionId: 'session-boolean',
        cwd: '/workspace',
      );
      final settings = await client.sessionSettings('session-boolean');

      expect(events, isEmpty);
      expect(settings.configOptions, hasLength(1));
      expect(settings.configOptions.single.id, 'thinking');
      expect(settings.configOptions.single.currentValue, 'true');
    } finally {
      await client.dispose();
      await tempDir.delete(recursive: true);
    }
  });

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

  for (final scenario
      in <
        ({
          String name,
          int maxPages,
          int maxEntries,
          int maxCursorBytes,
          String responseMode,
          AcpSessionListBudgetReason reason,
        })
      >[
        (
          name: 'rejects a repeated pagination cursor',
          maxPages: 4,
          maxEntries: 10,
          maxCursorBytes: 128,
          responseMode: 'repeated',
          reason: AcpSessionListBudgetReason.repeatedCursor,
        ),
        (
          name: 'rejects infinitely many unique pagination cursors',
          maxPages: 2,
          maxEntries: 10,
          maxCursorBytes: 128,
          responseMode: 'unique',
          reason: AcpSessionListBudgetReason.pageLimit,
        ),
        (
          name: 'rejects an oversized accumulated session list',
          maxPages: 4,
          maxEntries: 1,
          maxCursorBytes: 128,
          responseMode: 'entries',
          reason: AcpSessionListBudgetReason.entryLimit,
        ),
        (
          name: 'measures pagination cursors in UTF-8 bytes',
          maxPages: 4,
          maxEntries: 10,
          maxCursorBytes: 5,
          responseMode: 'cursor-bytes',
          reason: AcpSessionListBudgetReason.cursorByteLimit,
        ),
      ]) {
    test('listSessions ${scenario.name}', () async {
      final error = await _listSessionsBudgetFailure(
        maxPages: scenario.maxPages,
        maxEntries: scenario.maxEntries,
        maxCursorBytes: scenario.maxCursorBytes,
        responseMode: scenario.responseMode,
      );

      expect(error, isA<AcpSessionListBudgetException>());
      final typed = error as AcpSessionListBudgetException;
      expect(typed.reason, scenario.reason);
      expect(typed.toString(), isNot(contains('secret-cursor')));
      expect(typed.toString(), isNot(contains('秘密')));
    });
  }
}

Future<Object> _listSessionsBudgetFailure({
  required int maxPages,
  required int maxEntries,
  required int maxCursorBytes,
  required String responseMode,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-list-');
  final agentScript = File('${tempDir.path}/fake_list_budget_agent.dart');
  final modeLiteral = jsonEncode(responseMode);
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

Future<void> main() async {
  var page = 0;
  const mode = $modeLiteral;
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
            'sessionCapabilities': <String, dynamic>{'list': true},
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (message['method'] == 'session/list') {
      page += 1;
      final sessions = mode == 'entries'
          ? <Map<String, dynamic>>[
              <String, dynamic>{'sessionId': 'one', 'cwd': '/one'},
              <String, dynamic>{'sessionId': 'two', 'cwd': '/two'},
            ]
          : <Map<String, dynamic>>[
              <String, dynamic>{'sessionId': 'session-\$page', 'cwd': '/ws'},
            ];
      final nextCursor = switch (mode) {
        'repeated' => 'secret-cursor',
        'unique' => 'cursor-\$page',
        'cursor-bytes' => '秘密',
        _ => null,
      };
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': sessions,
          if (nextCursor != null) 'nextCursor': nextCursor,
        },
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    sessionListMaxPages: maxPages,
    sessionListMaxEntries: maxEntries,
    sessionListMaxCursorBytes: maxCursorBytes,
  );
  try {
    await client.connect().timeout(const Duration(seconds: 5));
    try {
      await client.listSessions().timeout(const Duration(seconds: 5));
    } catch (error) {
      return error;
    }
    throw StateError('Expected listSessions to reject the response sequence.');
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
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

Future<
  ({
    List<Map<String, dynamic>> calls,
    List<String> directories,
    List<String> listedAdditionalDirectories,
  })
>
_captureSessionSetupParams({
  required bool advertiseAdditionalDirectories,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final setupParamsFile = File('${tempDir.path}/session_setup_params.json');
  final agentScript = File('${tempDir.path}/fake_session_setup_agent.dart');
  final setupParamsPath = jsonEncode(setupParamsFile.path);
  final directories = ['${tempDir.path}/extra-a', '${tempDir.path}/extra-b'];
  final directoriesLiteral = '[${directories.map(jsonEncode).join(', ')}]';
  final additionalCapability = advertiseAdditionalDirectories
      ? "'additionalDirectories': <String, dynamic>{},"
      : '';
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void record(String method, Map<String, dynamic> params) {
  final file = File($setupParamsPath);
  final calls = file.existsSync()
      ? jsonDecode(file.readAsStringSync()) as List<dynamic>
      : <dynamic>[];
  calls.add(<String, dynamic>{'method': method, 'params': params});
  file.writeAsStringSync(jsonEncode(calls));
}

Future<void> main() async {
  final directories = <String>$directoriesLiteral;
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final message = jsonDecode(line) as Map<String, dynamic>;
    final method = message['method'] as String?;
    if (method == 'initialize') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'protocolVersion': 1,
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'list': true,
              'resume': true,
              'fork': true,
              $additionalCapability
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      }));
    } else if (method == 'session/list') {
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{
              'sessionId': 'session-1',
              'cwd': '/workspace',
              'title': 'Listed session',
              'additionalDirectories': directories,
            },
          ],
        },
      }));
    } else if (method == 'session/new') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
    } else if (method == 'session/resume') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
    } else if (method == 'session/fork') {
      record(method!, message['params'] as Map<String, dynamic>);
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-forked'},
      }));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    additionalDirectories: directories,
  );

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    final listed = await client.listSessions();
    await client.createSession(cwd: '/workspace');
    await client.resumeSession(sessionId: 'session-1', cwd: '/workspace');
    await client.forkSession(sessionId: 'session-1', cwd: '/workspace');

    final calls =
        (jsonDecode(await setupParamsFile.readAsString()) as List<dynamic>)
            .cast<Map<String, dynamic>>();
    return (
      calls: calls,
      directories: directories,
      listedAdditionalDirectories:
          listed.single.sessions.single.additionalDirectories,
    );
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

Future<void> _expectGeneratedSessionRegistrationAfterFailedResume(
  String operation,
) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final agentScript = File('${tempDir.path}/fake_${operation}_race_agent.dart');
  await agentScript.writeAsString('''
import 'dart:convert';
import 'dart:io';

void send(Map<String, dynamic> message) => stdout.writeln(jsonEncode(message));

Future<void> main() async {
  Object? pendingResumeId;
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
          'agentCapabilities': <String, dynamic>{
            'sessionCapabilities': <String, dynamic>{
              'resume': true,
              'fork': true,
            },
          },
          'authMethods': <Map<String, dynamic>>[],
        },
      });
    } else if (message['method'] == 'session/resume') {
      pendingResumeId = message['id'];
    } else if (message['method'] == 'session/$operation') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{
          'sessionId': 'shared-session',
          'registrationMarker': '$operation',
        },
      });
    } else if (message['method'] == 'test/release') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': pendingResumeId,
        'error': <String, dynamic>{
          'code': -32000,
          'message': 'resume failed',
        },
      });
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      });
    } else if (message['method'] == 'session/prompt') {
      send(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      });
    }
  }
}
''');

  final registrationResponse = Completer<void>();
  final client = await acp.AcpClient.start(
    config: acp.AcpConfig(
      agentCommand: _dartExecutable(),
      agentArgs: [agentScript.path],
      onProtocolIn: (line) {
        if (line.contains('"registrationMarker":"$operation"') &&
            !registrationResponse.isCompleted) {
          registrationResponse.complete();
        }
      },
    ),
  );

  try {
    await client.initialize().timeout(const Duration(seconds: 5));
    final resume = client.resumeSession(
      sessionId: 'shared-session',
      workspaceRoot: '/workspace/provisional',
    );
    final resumeFailure = expectLater(resume, throwsA(anything));
    await pumpEventQueue();

    final Future<String> generated = operation == 'new'
        ? client.newSession('/workspace/generated')
        : client
              .forkSession(
                sessionId: 'source-session',
                workspaceRoot: '/workspace/generated',
              )
              .then((result) => result.sessionId);
    var registrationCompleted = false;
    Object? registrationError;
    final trackedRegistration = generated.then(
      (sessionId) {
        registrationCompleted = true;
        return sessionId;
      },
      onError: (Object error) {
        registrationCompleted = true;
        registrationError = error;
        return 'registration-failed';
      },
    );

    await registrationResponse.future.timeout(const Duration(seconds: 5));
    await pumpEventQueue(times: 2);
    final completedBeforeRollback = registrationCompleted;

    await client
        .sendRaw('test/release', const <String, dynamic>{})
        .timeout(const Duration(seconds: 5));
    await resumeFailure;

    expect(completedBeforeRollback, isFalse);
    expect(registrationError, isNull);
    expect(await trackedRegistration, 'shared-session');
    await client
        .prompt(sessionId: 'shared-session', content: 'still valid')
        .drain<void>()
        .timeout(const Duration(seconds: 5));
  } finally {
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

Future<
  ({
    Map<String, dynamic> response,
    int permissionRequestCount,
    bool writeTargetExists,
  })
>
_runInvalidSessionRequest({
  required String method,
  required String? sessionId,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final workspace = Directory('${tempDir.path}/workspace');
  await workspace.create();
  await File('${workspace.path}/fixture.txt').writeAsString('fixture');
  final writeTarget = File('${workspace.path}/should-not-exist.txt');
  final responseFile = File('${tempDir.path}/invalid_session_response.json');
  final agentScript = File('${tempDir.path}/fake_invalid_session_agent.dart');
  final params = <String, Object?>{
    'sessionId': ?sessionId,
    if (method == 'fs/read_text_file') 'path': 'fixture.txt',
    if (method == 'fs/write_text_file') ...{
      'path': writeTarget.path,
      'content': 'must not be written',
    },
    if (method == 'session/request_permission') ...{
      'toolCall': <String, Object?>{'title': 'Run command', 'kind': 'execute'},
      'options': <Map<String, Object?>>[
        {'optionId': 'allow', 'kind': 'allow_once', 'name': 'Allow'},
        {'optionId': 'deny', 'kind': 'reject_once', 'name': 'Deny'},
      ],
    },
  };
  final methodLiteral = jsonEncode(method);
  final paramsLiteral = jsonEncode(params);
  final responsePath = jsonEncode(responseFile.path);
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
        'result': <String, dynamic>{'sessionId': 'session-1'},
      }));
      stdout.writeln(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'invalid-session-request',
        'method': $methodLiteral,
        'params': $paramsLiteral,
      }));
    } else if (message['id'] == 'invalid-session-request') {
      await File($responsePath).writeAsString(jsonEncode(message));
    }
  }
}
''');

  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: [agentScript.path],
    enableFilesystemReadTextFile: method == 'fs/read_text_file',
    enableFilesystemWriteTextFile: method == 'fs/write_text_file',
  );
  var permissionRequestCount = 0;
  final subscription = client.permissionRequests.listen((request) {
    permissionRequestCount += 1;
    unawaited(
      client.respondToPermissionRequest(
        id: request.id,
        decision: AcpPermissionDecision.deny,
      ),
    );
  });

  try {
    await client.connect().timeout(const Duration(seconds: 5));
    await client.createSession(cwd: workspace.path);
    await _waitForFile(responseFile);
    final response =
        jsonDecode(await responseFile.readAsString()) as Map<String, dynamic>;
    return (
      response: response,
      permissionRequestCount: permissionRequestCount,
      writeTargetExists: await writeTarget.exists(),
    );
  } finally {
    await subscription.cancel();
    await client.dispose();
    await tempDir.delete(recursive: true);
  }
}

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

class _RecordingTerminalProvider implements acp.TerminalProvider {
  _RecordingTerminalProvider({
    this.failReleaseIds = const <String>{},
    this.releaseErrorMessage = 'injected terminal release failure',
    this.createBarrier,
    this.createStarted,
  });

  final Set<String> failReleaseIds;
  final String releaseErrorMessage;
  final Completer<void>? createBarrier;
  final Completer<void>? createStarted;
  final List<String> releaseAttempts = <String>[];
  var _nextId = 0;

  @override
  Future<acp.TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int outputByteLimit = acp.defaultTerminalOutputByteLimit,
  }) async {
    _nextId += 1;
    final started = createStarted;
    if (started != null && !started.isCompleted) started.complete();
    await createBarrier?.future;
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    return acp.TerminalProcessHandle(
      terminalId: 'terminal-$_nextId',
      process: process,
      outputByteLimit: outputByteLimit,
    );
  }

  @override
  Future<String> currentOutput(acp.TerminalProcessHandle handle) async =>
      handle.currentOutput();

  @override
  Future<void> kill(acp.TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(acp.TerminalProcessHandle handle) async {
    releaseAttempts.add(handle.terminalId);
    await handle.release();
    if (failReleaseIds.contains(handle.terminalId)) {
      throw StateError(releaseErrorMessage);
    }
  }

  @override
  Future<int> waitForExit(acp.TerminalProcessHandle handle) =>
      handle.waitForExit();
}
