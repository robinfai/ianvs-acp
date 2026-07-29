import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_agent_discovery.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';

void main() {
  test('discovers Codex ACP through npx on PATH', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/usr/local/bin:/bin'},
      fileExists: (path) => path == '/usr/local/bin/npx',
    );

    expect(discovered, hasLength(1));
    expect(discovered.single.name, 'Codex');
    expect(discovered.single.command, '/usr/local/bin/npx');
    expect(discovered.single.args, ['@zed-industries/codex-acp']);
  });

  test('discovers Pi ACP adapter through pi-acp on PATH', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/usr/local/bin:/bin'},
      fileExists: (path) => path == '/usr/local/bin/pi-acp',
    );

    expect(discovered, hasLength(1));
    expect(discovered.single.name, 'Pi');
    expect(discovered.single.command, '/usr/local/bin/pi-acp');
    expect(discovered.single.args, isEmpty);
  });

  test(
    'does not suggest Codex when same ACP adapter is already configured',
    () {
      final discovered = AcpAgentDiscovery.discoverMissing(
        AcpClientConfig.fromJson({
          'agent_servers': {
            'OpenAI Codex': {
              'type': 'custom',
              'command': '/opt/homebrew/bin/npx',
              'args': ['@zed-industries/codex-acp'],
            },
          },
        }),
        environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
        fileExists: (path) => path == '/opt/homebrew/bin/npx',
      );

      expect(discovered, isEmpty);
    },
  );

  test('writes selected discovered agents to settings file', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_acp_discovery');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = '${temp.path}/settings.json';
    final config = AcpClientConfig(configPath: configPath);

    final nextConfig = await AcpAgentDiscovery.writeSelectedAgentServers(
      config,
      const [
        AgentServerConfig(
          name: 'Codex',
          type: 'custom',
          command: '/usr/local/bin/npx',
          args: ['@zed-industries/codex-acp'],
        ),
      ],
    );

    expect(nextConfig.agentName, 'Codex');
    expect(nextConfig.agentServers.map((server) => server.name), ['Codex']);
    expect(await File(configPath).readAsString(), contains('agent_servers'));
    expect(
      await File(configPath).readAsString(),
      contains('default_agent_server'),
    );
  });
}
