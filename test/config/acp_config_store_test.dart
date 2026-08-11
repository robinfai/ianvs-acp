import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_agent_discovery.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/config/secret_store.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';

void main() {
  test('migrates existing agent settings to a stable persistence id', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_agent_identity_migration',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Original name': {
            'type': 'custom',
            'command': '/usr/local/bin/agent',
          },
        },
      }),
    );

    final loaded = await AcpConfigStore.loadConfig(
      configPath: file.path,
      secretStore: _MemorySecretStore(),
    );
    final identity = loaded.activeAgentServer!.persistenceIdentity;
    final migrated = jsonDecode(await file.readAsString());

    expect(
      migrated['agent_servers']['Original name']['persistence_id'],
      identity,
    );
    expect(
      migrated['agent_servers']['Original name']['persistence_aliases'],
      <String>['Original name'],
    );
    expect(identity, startsWith('agent-'));
  });

  test('serializes assistant agent config', () {
    final settings = AcpConfigStore.toSettingsJson(
      const AcpClientConfig(
        assistantAgent: AssistantAgentConfig(
          enabled: true,
          agentName: 'Codex',
          model: 'gpt-5.6-sol',
          fallbackTitleCharacters: 28,
        ),
      ),
    );

    expect(settings['assistant_agent'], {
      'enabled': true,
      'agent': 'Codex',
      'model': 'gpt-5.6-sol',
      'generate_session_titles': true,
      'summarize_turns': true,
      'collapse_execution_process': true,
      'fallback_title_characters': 28,
      'timeout_ms': 30000,
    });
  });

  test('writes config while preserving unknown top-level fields', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString('''
{
  "unknown_top_level": "kept",
  "agent_servers": {
    "Old Agent": {
      "type": "custom",
      "command": "/usr/local/bin/old"
    }
  }
}
''');

    const editedConfig = AcpClientConfig(
      configPath: 'ignored-by-explicit-path',
      defaultAgentServerName: 'Codex',
      activeAgentServer: AgentServerConfig(
        name: 'Codex',
        type: 'custom',
        command: '/usr/local/bin/npx',
        args: ['@zed-industries/codex-acp'],
      ),
      agentServers: [
        AgentServerConfig(
          name: 'Codex',
          type: 'custom',
          command: '/usr/local/bin/npx',
          args: ['@zed-industries/codex-acp'],
          permissionReviewAgent: AcpPermissionReviewAgentConfig(
            enabled: true,
            model: 'agent-review-model',
          ),
        ),
        AgentServerConfig(
          name: 'Remote HTTP Agent',
          type: 'http',
          url: 'https://agent.example.com/acp',
          headers: {'Authorization': 'Bearer token'},
        ),
      ],
      mcpServers: [
        McpServerConfig(
          raw: {
            'name': 'api-tools',
            'type': 'http',
            'url': 'https://api.example.com/mcp',
            'headers': [
              {'name': 'X-MCP-Token', 'value': 'secret'},
            ],
          },
        ),
      ],
      additionalDirectories: ['/Users/example/extra'],
      clientProviders: AcpClientProviderConfig(
        filesystem: AcpFilesystemProviderConfig(
          readTextFile: true,
          writeTextFile: true,
          allowReadOutsideWorkspace: true,
        ),
        terminal: AcpTerminalProviderConfig(enabled: true),
        permissions: AcpPermissionProviderConfig(
          trustRules: [
            AcpPermissionTrustRule(
              toolName: 'read_text_file',
              toolKind: 'read',
              decision: AcpPermissionDecision.allow,
            ),
          ],
          reviewAgent: AcpPermissionReviewAgentConfig(
            enabled: true,
            agentServerName: 'Codex',
            toolName: 'review_permission',
            model: 'review-model',
            timeout: Duration(milliseconds: 5000),
          ),
        ),
      ),
    );

    final nextConfig = await AcpConfigStore.writeConfig(
      config: editedConfig,
      configPath: file.path,
      secretStore: _MemorySecretStore(),
    );

    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(nextConfig.agentName, 'Codex');
    expect(nextConfig.configPath, file.path);
    expect(decoded['unknown_top_level'], 'kept');
    expect(decoded['default_agent_server'], 'Codex');
    expect(decoded['agent_servers'], isNot(contains('Old Agent')));
    expect(decoded['agent_servers']['Codex']['command'], '/usr/local/bin/npx');
    expect(
      decoded['agent_servers']['Codex']['review_agent']['model'],
      'agent-review-model',
    );
    expect(
      decoded['agent_servers']['Remote HTTP Agent']['header_refs']['Authorization'],
      startsWith('keychain://ianvs-acp/'),
    );
    expect(nextConfig.agentServerNamed('Remote HTTP Agent')?.headers, {
      'Authorization': 'Bearer token',
    });
    expect(decoded['mcp_servers'], hasLength(1));
    expect(decoded['mcp_servers'].single['name'], 'api-tools');
    expect(
      decoded['mcp_servers'].single['header_refs']['X-MCP-Token'],
      startsWith('keychain://ianvs-acp/'),
    );
    expect(await file.readAsString(), isNot(contains('Bearer token')));
    expect(await file.readAsString(), isNot(contains('"secret"')));
    expect(decoded['additional_directories'], ['/Users/example/extra']);
    expect(decoded['client_providers']['filesystem']['read_text_file'], isTrue);
    expect(
      decoded['client_providers']['filesystem']['write_text_file'],
      isTrue,
    );
    expect(
      decoded['client_providers']['filesystem']['allow_read_outside_workspace'],
      isTrue,
    );
    expect(decoded['client_providers']['terminal']['enabled'], isTrue);
    expect(decoded['client_providers']['permissions']['trust_rules'].single, {
      'tool_name': 'read_text_file',
      'tool_kind': 'read',
      'decision': 'allow',
    });
    expect(
      decoded['client_providers']['permissions']['review_agent']['agent_server_name'],
      'Codex',
    );
    expect(
      decoded['client_providers']['permissions']['review_agent']['timeout_ms'],
      5000,
    );
  });

  test('writes edited config without dropping unknown nested fields', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store_unknown_nested',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Local': {
            'type': 'custom',
            'command': 'old-agent',
            'future_agent': {'kept': true},
            'permissions': {
              'future_permission': 7,
              'approval_agent': {
                'enabled': false,
                'model': 'old-model',
                'future_reviewer': 'kept',
              },
            },
          },
        },
        'client_providers': {
          'future_provider': {'kept': true},
          'filesystem': {'read_text_file': false, 'future_fs': 9},
          'permissions': {
            'future_permission': 'kept',
            'approval_agent': {
              'enabled': false,
              'model': 'old-global-model',
              'future_reviewer': true,
            },
          },
        },
      }),
    );
    final current = await AcpConfigStore.loadConfig(
      configPath: file.path,
      secretStore: _MemorySecretStore(),
    );
    final server = current.agentServers.single;

    await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        activeAgentServer: AgentServerConfig(
          name: server.name,
          type: server.type,
          command: 'new-agent',
          permissionReviewAgent: const AcpPermissionReviewAgentConfig(
            enabled: true,
            model: 'new-model',
          ),
        ),
        agentServers: [
          AgentServerConfig(
            name: server.name,
            type: server.type,
            command: 'new-agent',
            permissionReviewAgent: const AcpPermissionReviewAgentConfig(
              enabled: true,
              model: 'new-model',
            ),
          ),
        ],
        clientProviders: const AcpClientProviderConfig(
          filesystem: AcpFilesystemProviderConfig(readTextFile: true),
          permissions: AcpPermissionProviderConfig(
            reviewAgent: AcpPermissionReviewAgentConfig(
              enabled: true,
              model: 'new-global-model',
            ),
          ),
        ),
      ),
      secretStore: _MemorySecretStore(),
    );

    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(raw['agent_servers']['Local']['command'], 'new-agent');
    expect(raw['agent_servers']['Local']['future_agent'], {'kept': true});
    expect(
      raw['agent_servers']['Local']['permissions']['future_permission'],
      7,
    );
    expect(
      raw['agent_servers']['Local']['permissions']['approval_agent']['model'],
      'new-model',
    );
    expect(
      raw['agent_servers']['Local']['permissions']['approval_agent']['future_reviewer'],
      'kept',
    );
    expect(raw['client_providers']['future_provider'], {'kept': true});
    expect(raw['client_providers']['filesystem']['future_fs'], 9);
    expect(raw['client_providers']['permissions']['future_permission'], 'kept');
    expect(
      raw['client_providers']['permissions']['approval_agent']['model'],
      'new-global-model',
    );
    expect(
      raw['client_providers']['permissions']['approval_agent']['future_reviewer'],
      isTrue,
    );
  });

  test('removes only retired storage cleanup fields when saving', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store_retired_storage',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'storage': {
          'max_size_gb': 20,
          'retention_days': 14,
          'cleanup_interval_hours': 24,
          'cleanupIntervalHours': 12,
          'future_storage': {'enabled': true, 'policy': 'keep'},
        },
      }),
    );

    await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        storage: const SqliteStorageConfig(maxSizeGb: 40, retentionDays: 60),
      ),
      secretStore: _MemorySecretStore(),
    );

    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final storage = raw['storage'] as Map<String, dynamic>;
    expect(storage['max_size_gb'], 40);
    expect(storage['retention_days'], 60);
    expect(storage, isNot(contains('cleanup_interval_hours')));
    expect(storage, isNot(contains('cleanupIntervalHours')));
    expect(storage['future_storage'], {'enabled': true, 'policy': 'keep'});
  });

  test('writes edited MCP config without dropping unknown fields', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store_unknown_mcp',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'mcp_servers': [
          {
            'name': 'tools',
            'command': 'old-tools',
            'future_mcp': {'kept': true},
          },
        ],
      }),
    );

    await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        mcpServers: [
          McpServerConfig.fromJson(
            index: 0,
            json: {'name': 'tools', 'command': 'new-tools'},
          ),
        ],
      ),
    );

    final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(raw['mcp_servers'].single['command'], 'new-tools');
    expect(raw['mcp_servers'].single['future_mcp'], {'kept': true});
  });

  test('creates config file when it does not exist', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/nested/settings.json');

    final nextConfig = await AcpConfigStore.writeConfig(
      config: const AcpClientConfig(
        defaultAgentServerName: 'Codex',
        activeAgentServer: AgentServerConfig(
          name: 'Codex',
          type: 'custom',
          command: '/usr/local/bin/npx',
        ),
        agentServers: [
          AgentServerConfig(
            name: 'Codex',
            type: 'custom',
            command: '/usr/local/bin/npx',
          ),
        ],
      ),
      configPath: file.path,
    );

    expect(await file.exists(), isTrue);
    expect(nextConfig.agentName, 'Codex');
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(decoded['default_agent_server'], 'Codex');
    expect(decoded['agent_servers']['Codex']['command'], '/usr/local/bin/npx');
    expect((await file.stat()).mode & 0x1ff, 0x180);
    expect((await file.parent.stat()).mode & 0x1ff, 0x1c0);
  });

  test('rejects missing config path', () async {
    expect(
      () => AcpConfigStore.writeConfig(
        config: const AcpClientConfig(),
        configPath: ' ',
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'rejects duplicate server names without requiring SecretStore',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_acp_config_store_duplicates',
      );
      addTearDown(() => temp.delete(recursive: true));
      final agentFile = File('${temp.path}/agents.json');
      final mcpFile = File('${temp.path}/mcp.json');

      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: agentFile.path,
            agentServers: const [
              AgentServerConfig(name: 'Same', type: 'custom', command: 'one'),
              AgentServerConfig(name: 'Same', type: 'custom', command: 'two'),
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: mcpFile.path,
            mcpServers: [
              McpServerConfig.fromJson(
                index: 0,
                json: {'name': 'Same', 'command': 'one'},
              ),
              McpServerConfig.fromJson(
                index: 1,
                json: {'name': 'Same', 'command': 'two'},
              ),
            ],
          ),
        ),
        throwsA(isA<FormatException>()),
      );
      expect(await agentFile.exists(), isFalse);
      expect(await mcpFile.exists(), isFalse);
    },
  );

  test('does not change permissions of an existing config parent', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_acp_config_store',
    );
    addTearDown(() => temp.delete(recursive: true));
    final chmod = await Process.run('/bin/chmod', ['0755', temp.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    final file = File('${temp.path}/settings.json');

    await AcpConfigStore.writeConfig(
      config: const AcpClientConfig(),
      configPath: file.path,
    );

    expect((await temp.stat()).mode & 0x1ff, 0x1ed);
    expect((await file.stat()).mode & 0x1ff, 0x180);
  });

  test(
    'serializes config edits and discovered agents for the same file',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_acp_config_store',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('{"unknown":"kept"}\n');
      final edited = AcpClientConfig(
        configPath: file.path,
        defaultAgentServerName: 'Configured',
        agentServers: const [
          AgentServerConfig(
            name: 'Configured',
            type: 'custom',
            command: '/usr/local/bin/configured',
          ),
        ],
        additionalDirectories: const ['/workspace/extra'],
      );

      await Future.wait([
        AcpConfigStore.writeConfig(config: edited),
        AcpAgentDiscovery.writeSelectedAgentServers(edited, const [
          AgentServerConfig(
            name: 'Codex',
            type: 'custom',
            command: '/usr/local/bin/npx',
            args: ['@zed-industries/codex-acp'],
          ),
        ]),
      ]);

      final raw = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      expect(raw['unknown'], 'kept');
      expect(raw['additional_directories'], ['/workspace/extra']);
      expect(raw['agent_servers'], containsPair('Configured', isA<Map>()));
      expect(raw['agent_servers'], containsPair('Codex', isA<Map>()));
    },
  );
}

final class _MemorySecretStore implements SecretStore {
  final Map<String, String> _values = <String, String>{};
  final Map<String, String> _references = <String, String>{};

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async {
    final identity = '$namespace\u0000$key';
    final reference = _references.putIfAbsent(
      identity,
      () => referenceFor(namespace: namespace, key: key),
    );
    _values[reference] = value;
    return reference;
  }

  @override
  Future<String?> get(String reference) async => _values[reference];

  @override
  Future<void> delete(String reference) async {
    _values.remove(reference);
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
