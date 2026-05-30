import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';

void main() {
  test('copies configured MCP servers for session setup', () {
    final mcpServer = <String, dynamic>{
      'name': 'filesystem',
      'command': '/usr/local/bin/mcp-filesystem',
      'args': ['--mode', 'readonly'],
    };

    final client = DartAcpAgentClient(mcpServers: [mcpServer]);
    mcpServer['name'] = 'mutated';

    expect(client.mcpServers, hasLength(1));
    expect(client.mcpServers.single['name'], 'filesystem');
    expect(
      client.mcpServers.single['command'],
      '/usr/local/bin/mcp-filesystem',
    );
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
            'mcpCapabilities': <String, dynamic>{'sse': true},
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
          'type': 'sse',
          'url': 'https://events.example.com/mcp',
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
        ['stdio-tools', 'sse-tools'],
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

  test(
    'cancels agent permission requests until interactive UI exists',
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
}

Future<Map<String, dynamic>> _capturePromptParamsForAttachment({
  required bool embeddedContext,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('ianvs-acp-test-');
  final promptParamsFile = File('${tempDir.path}/prompt_params.json');
  final attachmentFile = File('${tempDir.path}/attachment.txt');
  final agentScript = File('${tempDir.path}/fake_prompt_agent.dart');
  final promptParamsPath = jsonEncode(promptParamsFile.path);
  final agentCapabilities = embeddedContext
      ? "<String, dynamic>{'promptCapabilities': <String, dynamic>{'embeddedContext': true}}"
      : '<String, dynamic>{}';
  await attachmentFile.writeAsString('embedded attachment text');
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
          prompt: 'Please inspect this.',
          attachments: [
            PromptAttachment.fromPath(
              path: attachmentFile.path,
              size: await attachmentFile.length(),
            ),
          ],
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
