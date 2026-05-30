import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';

void main() {
  test('loads custom agent server config', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_acp_config_test');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/config.json');
    await file.writeAsString('''
{
  "agent_servers": {
    "Kimi Code Dev": {
      "type": "custom",
      "command": "/Users/luobinghui/projects/kimi/kimi-code/apps/kimi-code/dist/main.mjs",
      "args": ["acp"]
    }
  }
}
''');

    final config = await AcpClientConfig.load(path: file.path);

    expect(config.agentName, 'Kimi Code Dev');
    expect(
      config.activeAgentServer?.command,
      '/Users/luobinghui/projects/kimi/kimi-code/apps/kimi-code/dist/main.mjs',
    );
    expect(config.activeAgentServer?.args, ['acp']);
  });

  test('uses requested default agent server when multiple are configured', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Kimi Code Dev',
      'agent_servers': {
        'Other Agent': {'type': 'custom', 'command': '/usr/local/bin/other'},
        'Kimi Code Dev': {
          'type': 'custom',
          'command': '/usr/local/bin/kimi',
          'args': ['acp'],
        },
      },
    });

    expect(config.agentName, 'Kimi Code Dev');
    expect(config.activeAgentServer?.command, '/usr/local/bin/kimi');
  });

  test('missing config file keeps built-in Codex default', () async {
    final config = await AcpClientConfig.load(
      path: '/tmp/ianvs-acp-does-not-exist.json',
      environment: const <String, String>{},
    );

    expect(config.agentName, 'Codex');
    expect(config.activeAgentServer, isNull);
  });

  test('resolves default config path under user home', () {
    final path = AcpClientConfig.resolveConfigPath(
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/Users/example/.ianvs_acp/config.json');
  });
}
