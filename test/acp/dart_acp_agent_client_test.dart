import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';

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
