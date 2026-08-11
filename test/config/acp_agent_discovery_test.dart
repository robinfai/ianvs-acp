import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_agent_discovery.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/secret_store.dart';
import 'package:ianvs_acp/platform/bounded_file_snapshot.dart';

void main() {
  test('uses reviewed package invocations for npx-backed agents', () {
    final agents = AcpAgentDiscovery.discover(
      environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
      fileExists: (_) => true,
    );

    expect(
      agents.singleWhere((agent) => agent.name == 'Codex').args.single,
      '@agentclientprotocol/codex-acp',
    );
    expect(
      agents.singleWhere((agent) => agent.name == 'Pi').args.last,
      'pi-acp@0.0.31',
    );
    expect(agents.singleWhere((agent) => agent.name == 'CodeBuddy').args, [
      '--acp',
    ]);
  });

  test('discovers npx-backed ACP agents through npx on PATH', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/usr/local/bin:/bin'},
      fileExists: (path) => path == '/usr/local/bin/npx',
    );

    final codex = discovered.singleWhere((agent) => agent.name == 'Codex');
    expect(codex.command, '/usr/local/bin/npx');
    expect(codex.args, ['@agentclientprotocol/codex-acp']);

    final codeBuddy = discovered.singleWhere(
      (agent) => agent.name == 'CodeBuddy',
    );
    expect(codeBuddy.command, '/usr/local/bin/npx');
    expect(codeBuddy.args, ['-y', '@tencent-ai/codebuddy-code', '--acp']);
  });

  test('discovers Pi through npx when pi is installed', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{
        'PATH': '/usr/local/bin:/bin',
        'UNRELATED_API_KEY': 'test-key',
      },
      fileExists: (path) =>
          path == '/usr/local/bin/npx' || path == '/usr/local/bin/pi',
    );

    final pi = discovered.singleWhere((server) => server.name == 'Pi');
    expect(pi.command, '/usr/local/bin/npx');
    expect(pi.args, ['-y', 'pi-acp@0.0.31']);
    expect(pi.env, isEmpty);
  });

  test('does not discover Pi when pi is not installed', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/usr/local/bin:/bin'},
      fileExists: (path) => path == '/usr/local/bin/npx',
    );

    expect(discovered.map((server) => server.name), isNot(contains('Pi')));
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

      expect(discovered.map((server) => server.name), isNot(contains('Codex')));
    },
  );

  test('discovers Cursor from its default standalone CLI location', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{
        'HOME': '/Users/example',
        'PATH': '/usr/bin:/bin',
      },
      fileExists: (path) => path == '/Users/example/.local/bin/agent',
    );

    expect(discovered, hasLength(1));
    expect(discovered.single.name, 'Cursor');
    expect(discovered.single.command, '/Users/example/.local/bin/agent');
    expect(discovered.single.args, ['acp']);
  });

  test('discovers Cursor through the cursor-agent CLI alias', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/custom/bin:/usr/bin'},
      fileExists: (path) => path == '/custom/bin/cursor-agent',
    );

    expect(discovered, hasLength(1));
    expect(discovered.single.name, 'Cursor');
    expect(discovered.single.command, '/custom/bin/cursor-agent');
    expect(discovered.single.args, ['acp']);
  });

  test('prefers an installed CodeBuddy CLI over the npx package', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      const AcpClientConfig(),
      environment: const <String, String>{'PATH': '/opt/homebrew/bin:/bin'},
      fileExists: (path) =>
          path == '/opt/homebrew/bin/npx' ||
          path == '/opt/homebrew/bin/codebuddy',
    );

    final codeBuddy = discovered.singleWhere(
      (agent) => agent.name == 'CodeBuddy',
    );
    expect(codeBuddy.command, '/opt/homebrew/bin/codebuddy');
    expect(codeBuddy.args, ['--acp']);
  });

  test('does not duplicate Cursor across its CLI aliases', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig.fromJson({
        'agent_servers': {
          'Cursor Agent': {
            'type': 'custom',
            'command': '/custom/bin/cursor-agent',
            'args': ['acp'],
          },
        },
      }),
      environment: const <String, String>{
        'HOME': '/Users/example',
        'PATH': '/usr/bin:/bin',
      },
      fileExists: (path) => path == '/Users/example/.local/bin/agent',
    );

    expect(discovered.map((server) => server.name), isNot(contains('Cursor')));
  });

  test('does not duplicate direct and npx CodeBuddy invocations', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig.fromJson({
        'agent_servers': {
          'CodeBuddy Code': {
            'type': 'custom',
            'command': '/usr/local/bin/npx',
            'args': ['--yes', '@tencent-ai/codebuddy-code@2.106.7', '--acp'],
          },
        },
      }),
      environment: const <String, String>{'PATH': '/opt/homebrew/bin:/bin'},
      fileExists: (path) => path == '/opt/homebrew/bin/codebuddy',
    );

    expect(
      discovered.map((server) => server.name),
      isNot(contains('CodeBuddy')),
    );
  });

  test('does not suggest Pi when the versioned npx adapter is configured', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig.fromJson({
        'agent_servers': {
          'pi': {
            'type': 'custom',
            'command': '/opt/homebrew/bin/npx',
            'args': ['-y', 'pi-acp@0.0.31'],
          },
        },
      }),
      environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
      fileExists: (path) =>
          path == '/opt/homebrew/bin/npx' || path == '/opt/homebrew/bin/pi',
    );

    expect(discovered.map((server) => server.name), isNot(contains('Pi')));
  });

  test('does not suggest Pi when a direct pi-acp wrapper is configured', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig.fromJson({
        'agent_servers': {
          'Pi': {
            'type': 'custom',
            'command': '/Users/example/.local/bin/pi-acp',
          },
        },
      }),
      environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
      fileExists: (path) =>
          path == '/opt/homebrew/bin/npx' || path == '/opt/homebrew/bin/pi',
    );

    expect(discovered.map((server) => server.name), isNot(contains('Pi')));
  });

  test('does not suggest Pi when an unversioned npx adapter is configured', () {
    final discovered = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig.fromJson({
        'agent_servers': {
          'Pi': {
            'type': 'custom',
            'command': '/opt/homebrew/bin/npx',
            'args': ['--yes', 'pi-acp'],
          },
        },
      }),
      environment: const <String, String>{'PATH': '/opt/homebrew/bin'},
      fileExists: (path) =>
          path == '/opt/homebrew/bin/npx' || path == '/opt/homebrew/bin/pi',
    );

    expect(discovered.map((server) => server.name), isNot(contains('Pi')));
  });

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

  test('agent discovery rejects an oversized config merge snapshot', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-discovery-oversized-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsBytes(
      List<int>.filled(AcpClientConfig.maxConfigFileBytes + 1, 0x20),
    );

    await expectLater(
      AcpAgentDiscovery.writeSelectedAgentServers(
        AcpClientConfig(configPath: file.path),
        const <AgentServerConfig>[
          AgentServerConfig(
            name: 'Codex',
            type: 'custom',
            command: '/usr/local/bin/codex',
          ),
        ],
      ),
      throwsA(isA<BoundedFileSnapshotOverflowException>()),
    );
  });

  test('upgrades the Zed Codex package to the ACP package', () async {
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
    ).singleWhere((server) => server.name == 'Codex');
    expect(migration.args, ['@agentclientprotocol/codex-acp']);

    final migrated = await AcpAgentDiscovery.writeSelectedAgentServers(config, [
      migration,
    ]);
    final server = migrated.agentServers.single;
    expect(server.name, 'OpenAI Codex');
    expect(server.args, ['@agentclientprotocol/codex-acp']);
    expect(server.env, {'KEEP_ME': 'yes'});
    expect(migrated.agentName, 'OpenAI Codex');
  });

  test('package upgrade updates every Zed Codex profile', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_acp_migration');
    addTearDown(() => temp.delete(recursive: true));
    final configPath = '${temp.path}/settings.json';
    final file = File(configPath);
    await file.writeAsString('''
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "args": ["@zed-industries/codex-acp"]
    },
    "codex-fast": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "args": ["@zed-industries/codex-acp@0.16.0"]
    },
    "Other": {
      "type": "custom",
      "command": "/usr/local/bin/other-acp",
      "args": ["serve"]
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
    ).singleWhere((server) => server.name == 'Codex');

    final migrated = await AcpAgentDiscovery.writeSelectedAgentServers(config, [
      migration,
    ]);

    expect(
      migrated.agentServers
          .where(
            (server) =>
                server.name.startsWith('Codex') ||
                server.name.startsWith('codex'),
          )
          .map((server) => server.args.single),
      everyElement('@agentclientprotocol/codex-acp'),
    );
    expect(
      migrated.agentServers
          .singleWhere((server) => server.name == 'Other')
          .args,
      ['serve'],
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
    final reference = referenceFor(namespace: namespace, key: key);
    _values[reference] = value;
    return reference;
  }

  @override
  String referenceFor({required String namespace, required String key}) =>
      keychainReferenceFor(namespace: namespace, key: key);

  @override
  bool referenceMatches(
    String reference, {
    required String namespace,
    required String key,
  }) => reference == referenceFor(namespace: namespace, key: key);
}
