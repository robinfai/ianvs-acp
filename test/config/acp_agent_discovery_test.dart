import 'dart:convert';
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
    expect(discovered.single.args, ['@agentclientprotocol/codex-acp']);
  });

  test('discovers pi ACP through npx when pi is installed', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{
        'PATH': '/usr/local/bin:/bin',
        'UNRELATED_API_KEY': 'test-key',
      },
      fileExists: (path) =>
          path == '/usr/local/bin/npx' || path == '/usr/local/bin/pi',
    );

    expect(discovered, hasLength(2));
    final pi = discovered.singleWhere((server) => server.name == 'pi ACP');
    expect(pi.command, '/usr/local/bin/npx');
    expect(pi.args, ['-y', 'pi-acp']);
    expect(pi.env, isEmpty);
  });

  test('does not discover pi ACP when pi is not installed', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/usr/local/bin:/bin'},
      fileExists: (path) => path == '/usr/local/bin/npx',
    );

    expect(discovered.map((server) => server.name), isNot(contains('pi ACP')));
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
              'args': ['@agentclientprotocol/codex-acp'],
            },
          },
        }),
        environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
        fileExists: (path) => path == '/opt/homebrew/bin/npx',
      );

      expect(discovered, isEmpty);
    },
  );

  test(
    'does not suggest pi ACP when same ACP adapter is already configured',
    () {
      final discovered = AcpAgentDiscovery.discoverMissing(
        AcpClientConfig.fromJson({
          'agent_servers': {
            'pi': {
              'type': 'custom',
              'command': '/opt/homebrew/bin/npx',
              'args': ['-y', 'pi-acp'],
            },
          },
        }),
        environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
        fileExists: (path) =>
            path == '/opt/homebrew/bin/npx' || path == '/opt/homebrew/bin/pi',
      );

      expect(
        discovered.map((server) => server.name),
        isNot(contains('pi ACP')),
      );
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
          args: ['@agentclientprotocol/codex-acp'],
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

  test('offers and applies migration from the legacy Codex adapter', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_acp_migration');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = '${temp.path}/settings.json';
    final file = File(configPath);
    await file.writeAsString('''
{
  "default_agent_server": "OpenAI Codex",
  "agent_servers": {
    "OpenAI Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "args": ["@zed-industries/codex-acp"],
      "env": {"KEEP_ME": "yes"}
    }
  }
}
''');
    final config = AcpClientConfig.fromJson(
      jsonDecode(await file.readAsString()) as Map<String, dynamic>,
      configPath: configPath,
    );

    final migration = AcpAgentDiscovery.discoverMissing(
      config,
      environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
      fileExists: (path) => path == '/opt/homebrew/bin/npx',
    );
    expect(migration.single.args, ['@agentclientprotocol/codex-acp']);

    final migrated = await AcpAgentDiscovery.writeSelectedAgentServers(
      config,
      migration,
    );
    final server = migrated.agentServers.single;
    expect(server.name, 'OpenAI Codex');
    expect(server.args, ['@agentclientprotocol/codex-acp']);
    expect(server.env, {'KEEP_ME': 'yes'});
    expect(migrated.agentName, 'OpenAI Codex');
  });
}
