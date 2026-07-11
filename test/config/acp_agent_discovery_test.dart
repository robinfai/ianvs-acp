import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_agent_discovery.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/secret_store.dart';

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

  test(
    'rejects discovered agent secrets when SecretStore is omitted',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_acp_discovery');
      addTearDown(() => temp.delete(recursive: true));
      final configPath = '${temp.path}/settings.json';

      await expectLater(
        AcpAgentDiscovery.writeSelectedAgentServers(
          AcpClientConfig(configPath: configPath),
          const [
            AgentServerConfig(
              name: 'Private',
              type: 'custom',
              command: '/usr/local/bin/private-agent',
              env: {'TOKEN': 'private-secret'},
            ),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(await File(configPath).exists(), isFalse);
    },
  );

  test(
    'migrates discovered agent secrets when SecretStore is provided',
    () async {
      final temp = await Directory.systemTemp.createTemp('ianvs_acp_discovery');
      addTearDown(() => temp.delete(recursive: true));
      final configPath = '${temp.path}/settings.json';
      final store = _MemorySecretStore();

      final resolved = await AcpAgentDiscovery.writeSelectedAgentServers(
        AcpClientConfig(configPath: configPath),
        const [
          AgentServerConfig(
            name: 'Private',
            type: 'custom',
            command: '/usr/local/bin/private-agent',
            env: {'TOKEN': 'private-secret'},
          ),
        ],
        secretStore: store,
      );

      final contents = await File(configPath).readAsString();
      final raw = jsonDecode(contents) as Map<String, dynamic>;
      final reference =
          raw['agent_servers']['Private']['env_refs']['TOKEN'] as String;
      expect(contents, isNot(contains('private-secret')));
      expect(await store.get(reference), 'private-secret');
      expect(resolved.agentServers.single.env['TOKEN'], 'private-secret');
    },
  );
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<void> delete(String reference) async {
    _values.remove(reference);
  }

  @override
  Future<String?> get(String reference) async => _values[reference];

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async {
    final reference =
        'keychain://ianvs-acp/${_values.length.toString().padLeft(64, '0')}';
    _values[reference] = value;
    return reference;
  }
}
