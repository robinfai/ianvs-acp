import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_secret_migrator.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';
import 'package:ianvs_acp/config/secret_store.dart';

void main() {
  test(
    'migrates legacy secrets to refs and keeps resolved runtime values',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_migration',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('''
{"unknown":"kept","agent_servers":{"Remote":{"type":"http","url":"https://agent.example/acp","headers":{"Authorization":"Bearer real-token"}}},"mcp_servers":[{"name":"tools","command":"tool","env":[{"name":"API_KEY","value":"mcp-secret"}]}]}
''');
      final store = FakeSecretStore();

      final config = await AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: store,
      );

      final contents = await file.readAsString();
      expect(contents, isNot(contains('Bearer real-token')));
      expect(contents, isNot(contains('mcp-secret')));
      final json = jsonDecode(contents) as Map<String, dynamic>;
      expect(json['unknown'], 'kept');
      expect(
        json['agent_servers']['Remote']['header_refs']['Authorization'],
        startsWith('keychain://ianvs-acp/'),
      );
      expect(
        config.agentServers.single.headers['Authorization'],
        'Bearer real-token',
      );
      expect(config.mcpServers.single.raw['env'].single['value'], 'mcp-secret');
      expect(config.agentServers.single.explicitHeaderKeys, isEmpty);
      expect(config.mcpServers.single.explicitEnvKeys, isEmpty);
    },
  );

  test('put failure leaves original bytes and deletes new refs', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_failure');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    const original =
        '{ "agent_servers": { "Local": { "type": "custom", "command": "agent", "env": { "A": "one", "B": "two" } } } }\n';
    await file.writeAsString(original);
    final store = FakeSecretStore(failPutAt: 2);
    final foreign = store.referenceFor(
      namespace: 'config/foreign/agent/Other/target/foreign/env',
      key: 'TOKEN',
    );
    store.values[foreign] = 'foreign-secret';

    await expectLater(
      AcpConfigStore.loadConfig(configPath: file.path, secretStore: store),
      throwsA(isA<StateError>()),
    );

    expect(await file.readAsString(), original);
    expect(store.values, {foreign: 'foreign-secret'});
    expect(store.deleted, hasLength(2));
    expect(store.deleted, isNot(contains(foreign)));
  });

  test('atomic write failure restores an updated existing secret', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_rollback');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final initial = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        activeAgentServer: const AgentServerConfig(
          name: 'Local',
          type: 'custom',
          command: 'agent',
          env: {'TOKEN': 'old-value'},
        ),
        agentServers: const [
          AgentServerConfig(
            name: 'Local',
            type: 'custom',
            command: 'agent',
            env: {'TOKEN': 'old-value'},
          ),
        ],
      ),
      secretStore: store,
    );
    final ref = initial.agentServers.single.envRefs['TOKEN']!;
    final original = await file.readAsString();
    final proposal = AcpClientConfig(
      configPath: file.path,
      activeAgentServer: AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
        env: const {'TOKEN': 'new-value'},
        envRefs: {'TOKEN': ref},
      ),
      agentServers: [
        AgentServerConfig(
          name: 'Local',
          type: 'custom',
          command: 'agent',
          env: const {'TOKEN': 'new-value'},
          envRefs: {'TOKEN': ref},
        ),
      ],
    );

    await expectLater(
      AcpConfigStore.writeConfig(
        config: proposal,
        secretStore: store,
        atomicWriter: (_, _) async => throw StateError('rename failed'),
      ),
      throwsA(isA<StateError>()),
    );

    expect(await file.readAsString(), original);
    expect(await store.get(ref), 'old-value');
  });

  test(
    'atomic write failure restores a preexisting owned orphan for plaintext',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_owned_orphan',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('{}');
      final store = FakeSecretStore();
      const server = AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
        env: {'TOKEN': 'new-value'},
      );
      final owner = SecretOwner(
        configIdentity: await configSecretIdentity(file.path),
        targetKind: 'agent/Local',
        targetIdentity: agentSecretTargetIdentity(server),
        fieldName: 'env',
        key: 'TOKEN',
      );
      final reference = await store.put(
        namespace: owner.namespace,
        key: owner.key,
        value: 'orphan-old',
      );

      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: const [server],
          ),
          secretStore: store,
          atomicWriter: (_, _) async => throw StateError('rename failed'),
        ),
        throwsStateError,
      );

      expect(await store.get(reference), 'orphan-old');
      expect(store.deleted, isNot(contains(reference)));
    },
  );

  test(
    'failed legacy migration restores a preexisting current-owner orphan',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_legacy_owned_orphan',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      const server = AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
      );
      final owner = SecretOwner(
        configIdentity: await configSecretIdentity(file.path),
        targetKind: 'agent/Local',
        targetIdentity: agentSecretTargetIdentity(server),
        fieldName: 'env',
        key: 'TOKEN',
      );
      final legacyReference = await store.put(
        namespace: owner.legacyNamespace,
        key: owner.key,
        value: 'legacy-secret',
      );
      final currentReference = await store.put(
        namespace: owner.namespace,
        key: owner.key,
        value: 'orphan-old',
      );
      await file.writeAsString(
        jsonEncode({
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'env_refs': {'TOKEN': legacyReference},
            },
          },
        }),
      );

      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: const [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'agent',
                env: {'TOKEN': 'new-value'},
              ),
            ],
          ),
          secretStore: store,
          atomicWriter: (_, _) async => throw StateError('rename failed'),
        ),
        throwsStateError,
      );

      expect(store.getCount, 2);
      expect(store.putCount, 5);
      expect(await store.get(currentReference), 'orphan-old');
      expect(store.deleted, isNot(contains(currentReference)));
    },
  );

  test(
    'atomic write failure restores existing secret when proposal lost refs',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_ref_inheritance',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final initial = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              env: {'TOKEN': 'old-value'},
            ),
          ],
        ),
        secretStore: store,
      );
      final ref = initial.agentServers.single.envRefs['TOKEN']!;
      final original = await file.readAsString();

      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: const [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'agent',
                env: {'TOKEN': 'new-value'},
              ),
            ],
          ),
          secretStore: store,
          atomicWriter: (_, _) async => throw StateError('rename failed'),
        ),
        throwsA(isA<StateError>()),
      );

      expect(await file.readAsString(), original);
      expect(await store.get(ref), 'old-value');
    },
  );

  test(
    'explicit config path namespaces proposals without an embedded path',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_explicit_path',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();

      final config = await AcpConfigStore.writeConfig(
        config: const AcpClientConfig(
          agentServers: [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              env: {'TOKEN': 'value'},
            ),
          ],
        ),
        configPath: file.path,
        secretStore: store,
      );

      expect(config.configPath, file.path);
      expect(config.agentServers.single.envRefs['TOKEN'], isNotNull);
    },
  );

  test(
    'secret writes advance an opaque runtime generation only in memory',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_generation',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();

      Future<AcpClientConfig> write(String value) {
        return AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'agent',
                env: {'TOKEN': value},
              ),
            ],
          ),
          secretStore: store,
        );
      }

      final first = await write('first');
      final second = await write('second');

      expect(first.runtimeSecretGeneration, greaterThan(0));
      expect(
        second.runtimeSecretGeneration,
        greaterThan(first.runtimeSecretGeneration),
      );
      expect(
        second.withActiveAgentServer('Local').runtimeSecretGeneration,
        second.runtimeSecretGeneration,
      );
      expect(
        await file.readAsString(),
        isNot(contains('runtimeSecretGeneration')),
      );
    },
  );

  test('missing reference identifies agent and field and blocks load', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_missing');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Remote': {
            'type': 'http',
            'url': 'https://agent.example/acp',
            'header_refs': {
              'Authorization':
                  'keychain://ianvs-acp/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff',
            },
          },
        },
      }),
    );

    await expectLater(
      AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: FakeSecretStore(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Remote'),
            contains('headers'),
            contains('Authorization'),
          ),
        ),
      ),
    );
  });

  test('successful write deletes retired refs', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_retired');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final initial = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(
            name: 'Old',
            type: 'custom',
            command: 'old',
            env: {'TOKEN': 'old'},
          ),
        ],
      ),
      secretStore: store,
    );
    final ref = initial.agentServers.single.envRefs['TOKEN']!;

    await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(name: 'New', type: 'custom', command: 'new'),
        ],
      ),
      secretStore: store,
    );

    expect(await store.get(ref), isNull);
    expect(store.deleted, contains(ref));
  });

  test('post-commit cleanup failure reports the committed config', () async {
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_cleanup_failure',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final initial = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(
            name: 'Old',
            type: 'custom',
            command: 'old',
            env: {'TOKEN': 'old'},
          ),
        ],
      ),
      secretStore: store,
    );
    final retired = initial.agentServers.single.envRefs['TOKEN']!;
    store.failDeletes = true;

    late AcpConfigPostCommitCleanupException cleanup;
    try {
      await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(name: 'New', type: 'custom', command: 'new'),
          ],
        ),
        secretStore: store,
      );
      fail('Expected cleanup failure.');
    } on AcpConfigPostCommitCleanupException catch (error) {
      cleanup = error;
    }

    expect(cleanup.committedConfig.agentServers.single.name, 'New');
    expect(await store.get(retired), 'old');
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['agent_servers'], contains('New'));
    expect(json['agent_servers'], isNot(contains('Old')));
    final queue = File(
      '${file.parent.path}/.${file.uri.pathSegments.last}.secret-cleanup.json',
    );
    final pending = jsonDecode(await queue.readAsString()) as Map;
    expect(pending['version'], 1);
    expect((pending['intents'] as List).single['reference'], retired);

    store.failDeletes = false;
    await AcpConfigStore.loadConfig(configPath: file.path, secretStore: store);
    expect(await store.get(retired), isNull);
    expect((jsonDecode(await queue.readAsString()) as Map)['intents'], isEmpty);
  });

  test(
    'rejects an unowned legacy-looking reference without reading it',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_reference_mismatch',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final legacyRef = await store.put(
        namespace: 'legacy',
        key: 'TOKEN',
        value: 'old',
      );
      await file.writeAsString(
        jsonEncode({
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'env_refs': {'TOKEN': legacyRef},
            },
          },
        }),
      );

      await expectLater(
        AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: const [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'agent',
                env: {'TOKEN': 'new'},
              ),
            ],
          ),
          secretStore: store,
        ),
        throwsA(isA<FormatException>()),
      );

      expect(store.getCount, 0);
      expect(await store.get(legacyRef), 'old');
      expect(store.values, {legacyRef: 'old'});
      expect(store.deleted, isNot(contains(legacyRef)));
    },
  );

  test(
    'migrates inline review MCP secrets without dropping unknown fields',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_inline_review',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString(
        jsonEncode({
          'client_providers': {
            'future_provider': {'enabled': true},
            'permissions': {
              'future_permission': 7,
              'approval_agent': {
                'enabled': true,
                'future_review': 'kept',
                'mcp_server': {
                  'name': 'global-review',
                  'command': 'review',
                  'future_mcp': true,
                  'env': [
                    {'name': 'GLOBAL_TOKEN', 'value': 'global-secret'},
                  ],
                },
              },
            },
          },
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'permissions': {
                'future_agent_permission': 'kept',
                'review_agent': {
                  'enabled': true,
                  'mcp_server': {
                    'name': 'agent-review',
                    'type': 'http',
                    'url': 'https://review.example/mcp',
                    'headers': [
                      {'name': 'Authorization', 'value': 'agent-secret'},
                    ],
                  },
                },
              },
            },
          },
        }),
      );

      final config = await AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: FakeSecretStore(),
      );
      final contents = await file.readAsString();
      final json = jsonDecode(contents) as Map<String, dynamic>;

      expect(contents, isNot(contains('global-secret')));
      expect(contents, isNot(contains('agent-secret')));
      expect(json['client_providers']['future_provider'], {'enabled': true});
      expect(json['client_providers']['permissions']['future_permission'], 7);
      expect(
        json['client_providers']['permissions']['approval_agent']['future_review'],
        'kept',
      );
      expect(
        json['agent_servers']['Local']['permissions']['future_agent_permission'],
        'kept',
      );
      expect(config.clientProviders.permissions.reviewAgent.mcpServer?.env, {
        'GLOBAL_TOKEN': 'global-secret',
      });
      expect(
        config.agentServers.single.permissionReviewAgent.mcpServer?.headers,
        {'Authorization': 'agent-secret'},
      );
    },
  );

  test('requires SecretStore for inline review MCP plaintext', () async {
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_inline_requires_store',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    const inline = McpServerConfig(
      raw: {
        'name': 'review',
        'command': 'review',
        'env': [
          {'name': 'TOKEN', 'value': 'secret'},
        ],
      },
    );

    await expectLater(
      AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: inline,
              ),
            ),
          ],
          clientProviders: const AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: inline,
              ),
            ),
          ),
        ),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('SecretStore is required'),
        ),
      ),
    );
    expect(await file.exists(), isFalse);
  });

  test('rollback failure retains the original atomic write cause', () async {
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_rollback_cause',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore(failDeletes: true);

    await expectLater(
      AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              env: {'TOKEN': 'new-value'},
            ),
          ],
        ),
        secretStore: store,
        atomicWriter: (_, _) async => throw StateError('rename failed'),
      ),
      throwsA(
        isA<AcpSecretRollbackException>().having(
          (error) => error.cause.toString(),
          'cause',
          contains('rename failed'),
        ),
      ),
    );
  });

  test('rejects plaintext and ref for the same logical field', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_mixed');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Local': {
            'type': 'custom',
            'command': 'agent',
            'env': {'TOKEN': 'plaintext'},
            'env_refs': {
              'TOKEN':
                  'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            },
          },
        },
      }),
    );

    await expectLater(
      AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: FakeSecretStore(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('both plaintext and a secret reference'),
        ),
      ),
    );
  });

  test('rejects duplicate refs and identifies both logical paths', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_alias');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    const ref =
        'keychain://ianvs-acp/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'One': {
            'type': 'custom',
            'command': 'one',
            'env_refs': {'TOKEN': ref},
          },
          'Two': {
            'type': 'http',
            'url': 'https://two.example/acp',
            'header_refs': {'Authorization': ref},
          },
        },
      }),
    );

    await expectLater(
      AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: FakeSecretStore(),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('agent_servers.One.env_refs.TOKEN'),
            contains('agent_servers.Two.header_refs.Authorization'),
          ),
        ),
      ),
    );
  });

  test('rejects duplicate server names before writing secrets', () async {
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_duplicate_names',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();

    await expectLater(
      AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Duplicate',
              type: 'custom',
              command: 'one',
              env: {'TOKEN': 'one'},
            ),
            AgentServerConfig(
              name: 'Duplicate',
              type: 'custom',
              command: 'two',
              env: {'TOKEN': 'two'},
            ),
          ],
        ),
        secretStore: store,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Duplicate agent server name'),
        ),
      ),
    );
    expect(store.putCount, 0);
  });

  test('preserves unknown agent fields and empty secret values', () async {
    final temp = await Directory.systemTemp.createTemp('acp_secret_unknown');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Remote': {
            'type': 'http',
            'url': 'https://agent.example/acp',
            'future_option': {'enabled': true},
            'headers': {'X-Optional': ''},
          },
        },
      }),
    );

    final config = await AcpConfigStore.loadConfig(
      configPath: file.path,
      secretStore: FakeSecretStore(),
    );
    final json = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(json['agent_servers']['Remote']['future_option'], {'enabled': true});
    expect(config.agentServers.single.headers['X-Optional'], '');
  });

  test(
    'same agent in different config paths receives different refs',
    () async {
      final temp = await Directory.systemTemp.createTemp('acp_secret_paths');
      addTearDown(() => temp.delete(recursive: true));
      final store = FakeSecretStore();
      Future<String> write(String name) async {
        final file = File('${temp.path}/$name/settings.json');
        final config = await AcpConfigStore.writeConfig(
          config: AcpClientConfig(
            configPath: file.path,
            agentServers: const [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'agent',
                env: {'TOKEN': 'value'},
              ),
            ],
          ),
          secretStore: store,
        );
        return config.agentServers.single.envRefs['TOKEN']!;
      }

      expect(await write('one'), isNot(await write('two')));
    },
  );

  test('agent target fingerprint covers every target field', () {
    const base = AgentServerConfig(
      name: 'Local',
      type: 'custom',
      command: 'agent',
      url: 'https://agent.example/acp',
      cwd: '/workspace',
      args: ['one', 'two'],
    );
    final baseline = agentSecretTargetIdentity(base);
    final variants = <String, AgentServerConfig>{
      'type': const AgentServerConfig(
        name: 'Local',
        type: 'http',
        command: 'agent',
        url: 'https://agent.example/acp',
        cwd: '/workspace',
        args: ['one', 'two'],
      ),
      'command whitespace': const AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent ',
        url: 'https://agent.example/acp',
        cwd: '/workspace',
        args: ['one', 'two'],
      ),
      'url': const AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
        url: 'https://other.example/acp',
        cwd: '/workspace',
        args: ['one', 'two'],
      ),
      'cwd': const AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
        url: 'https://agent.example/acp',
        cwd: '/other',
        args: ['one', 'two'],
      ),
      'args order': const AgentServerConfig(
        name: 'Local',
        type: 'custom',
        command: 'agent',
        url: 'https://agent.example/acp',
        cwd: '/workspace',
        args: ['two', 'one'],
      ),
    };

    for (final entry in variants.entries) {
      expect(
        agentSecretTargetIdentity(entry.value),
        isNot(baseline),
        reason: entry.key,
      );
    }
  });

  test(
    'plaintext parsing marks explicit keys without serializing the signal',
    () {
      final agent = AgentServerConfig.fromJson(
        name: 'Local',
        json: {
          'type': 'custom',
          'command': 'agent',
          'env': {'TOKEN': 'secret'},
        },
      );
      final referencedAgent = AgentServerConfig.fromJson(
        name: 'Local',
        json: {
          'type': 'custom',
          'command': 'agent',
          'env_refs': {
            'TOKEN':
                'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
        },
      );
      final mcp = McpServerConfig.fromJson(
        index: 0,
        json: {
          'name': 'tools',
          'type': 'http',
          'url': 'https://tools.example/mcp',
          'headers': [
            {'name': 'Authorization', 'value': 'secret'},
          ],
        },
      );

      expect(agent.explicitEnvKeys, {'TOKEN'});
      expect(referencedAgent.explicitEnvKeys, isEmpty);
      expect(mcp.explicitHeaderKeys, {'Authorization'});
      expect(agent.toJson(), isNot(contains('explicitEnvKeys')));
      expect(mcp.toJson(), isNot(contains('explicitHeaderKeys')));
    },
  );

  test('MCP target fingerprint is canonical and covers every target field', () {
    const baseRaw = <String, dynamic>{
      'name': 'tools',
      'type': 'custom',
      'command': 'tool',
      'url': 'https://mcp.example',
      'id': 'tools-id',
      'args': ['one', 'two'],
      'cwd': '/workspace',
    };
    const base = McpServerConfig(raw: baseRaw);
    final baseline = mcpSecretTargetIdentity(base);
    final variants = <String, Object?>{
      'type': 'http',
      'command whitespace': 'tool ',
      'url': 'https://other.example',
      'id': 'other-id',
      'args': const ['two', 'one'],
      'cwd': '/other',
    };
    final variantFields = <String, String>{
      'type': 'type',
      'command whitespace': 'command',
      'url': 'url',
      'id': 'id',
      'args': 'args',
      'cwd': 'cwd',
    };

    for (final entry in variants.entries) {
      final raw = <String, dynamic>{
        ...baseRaw,
        variantFields[entry.key]!: entry.value,
      };
      expect(
        mcpSecretTargetIdentity(McpServerConfig(raw: raw)),
        isNot(baseline),
        reason: entry.key,
      );
    }

    const reordered = McpServerConfig(
      raw: {
        'cwd': '/workspace',
        'args': ['one', 'two'],
        'id': 'tools-id',
        'url': 'https://mcp.example',
        'command': 'tool',
        'type': 'custom',
        'name': 'tools',
      },
    );
    expect(mcpSecretTargetIdentity(reordered), baseline);
  });

  test(
    'rejects cross-config references before reading every secret location',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_cross_config',
      );
      addTearDown(() => temp.delete(recursive: true));
      final sourceFile = File('${temp.path}/source/settings.json');
      final targetFile = File('${temp.path}/target/settings.json');
      final store = FakeSecretStore();
      const reviewMcp = McpServerConfig(
        raw: {
          'name': 'review-tools',
          'command': 'review-tool',
          'env': [
            {'name': 'REVIEW_TOKEN', 'value': 'review-secret'},
          ],
        },
      );
      const topMcp = McpServerConfig(
        raw: {
          'name': 'tools',
          'command': 'tool',
          'env': [
            {'name': 'TOP_TOKEN', 'value': 'top-secret'},
          ],
        },
      );
      const globalReviewMcp = McpServerConfig(
        raw: {
          'name': 'global-review',
          'command': 'global-review-tool',
          'env': [
            {'name': 'GLOBAL_TOKEN', 'value': 'global-secret'},
          ],
        },
      );
      final source = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: sourceFile.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              env: {'TOKEN': 'env-secret'},
              headers: {'Authorization': 'header-secret'},
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: reviewMcp,
              ),
            ),
          ],
          mcpServers: const [topMcp],
          clientProviders: const AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: globalReviewMcp,
              ),
            ),
          ),
        ),
        secretStore: store,
      );
      final sourceAgent = source.agentServers.single;
      final sourceTopMcp = source.mcpServers.single;
      final sourceGlobalReview =
          source.clientProviders.permissions.reviewAgent.mcpServer!;
      final cases = <Map<String, dynamic>>[
        {
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'env_refs': {'TOKEN': sourceAgent.envRefs['TOKEN']},
            },
          },
        },
        {
          'agent_servers': {
            'Local': {
              'type': 'http',
              'url': 'https://agent.example/acp',
              'header_refs': {
                'Authorization': sourceAgent.headerRefs['Authorization'],
              },
            },
          },
        },
        {
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'permissions': {
                'review_agent': {
                  'enabled': true,
                  'mcp_server': {
                    'name': 'review-tools',
                    'command': 'review-tool',
                    'env_refs': {
                      'REVIEW_TOKEN': sourceAgent
                          .permissionReviewAgent
                          .mcpServer!
                          .envRefs['REVIEW_TOKEN'],
                    },
                  },
                },
              },
            },
          },
        },
        {
          'mcp_servers': [
            {
              'name': 'tools',
              'command': 'tool',
              'env_refs': {'TOP_TOKEN': sourceTopMcp.envRefs['TOP_TOKEN']},
            },
          ],
        },
        {
          'client_providers': {
            'permissions': {
              'review_agent': {
                'enabled': true,
                'mcp_server': {
                  'name': 'global-review',
                  'command': 'global-review-tool',
                  'env_refs': {
                    'GLOBAL_TOKEN': sourceGlobalReview.envRefs['GLOBAL_TOKEN'],
                  },
                },
              },
            },
          },
        },
      ];

      for (final raw in cases) {
        store.getCount = 0;
        final parsed = AcpClientConfig.fromJson(
          raw,
          configPath: targetFile.path,
        );
        await expectLater(
          AcpConfigSecretMigrator(store).prepare(parsed),
          throwsFormatException,
        );
        expect(store.getCount, 0);
      }
    },
  );

  test(
    'migrates an exact same-config legacy reference to target owner',
    () async {
      final temp = await Directory.systemTemp.createTemp('acp_secret_legacy');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final configIdentity = await configSecretIdentity(file.path);
      final legacyReference = await store.put(
        namespace: '$configIdentity/agent/Local/env',
        key: 'TOKEN',
        value: 'legacy-secret',
      );
      await file.writeAsString(
        jsonEncode({
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'env_refs': {'TOKEN': legacyReference},
            },
          },
        }),
      );

      final loaded = await AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: store,
      );
      final migratedReference = loaded.agentServers.single.envRefs['TOKEN']!;

      expect(migratedReference, isNot(legacyReference));
      expect(loaded.agentServers.single.env['TOKEN'], 'legacy-secret');
      expect(await store.get(migratedReference), 'legacy-secret');
      expect(await store.get(legacyReference), isNull);
      expect(store.deleted, contains(legacyReference));
    },
  );

  test('failed legacy load persistence keeps the legacy reference', () async {
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_legacy_persist_failure',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final configIdentity = await configSecretIdentity(file.path);
    final legacyReference = await store.put(
      namespace: '$configIdentity/agent/Local/env',
      key: 'TOKEN',
      value: 'legacy-secret',
    );
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Local': {
            'type': 'custom',
            'command': 'agent',
            'env_refs': {'TOKEN': legacyReference},
          },
        },
      }),
    );

    await expectLater(
      AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: store,
        atomicWriter: (_, _) async => throw StateError('rename failed'),
      ),
      throwsStateError,
    );

    expect(await store.get(legacyReference), 'legacy-secret');
    expect(store.deleted, isNot(contains(legacyReference)));
  });

  test(
    'failed legacy cleanup is queued after load returns resolved config',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_legacy_cleanup_queue',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final configIdentity = await configSecretIdentity(file.path);
      final legacyReference = await store.put(
        namespace: '$configIdentity/agent/Local/env',
        key: 'TOKEN',
        value: 'legacy-secret',
      );
      await file.writeAsString(
        jsonEncode({
          'agent_servers': {
            'Local': {
              'type': 'custom',
              'command': 'agent',
              'env_refs': {'TOKEN': legacyReference},
            },
          },
        }),
      );
      store.failDeletes = true;

      final loaded = await AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: store,
      );

      expect(loaded.agentServers.single.env, {'TOKEN': 'legacy-secret'});
      expect(
        loaded.agentServers.single.envRefs['TOKEN'],
        isNot(legacyReference),
      );
      expect(await store.get(legacyReference), 'legacy-secret');
      final queue = File(
        '${file.parent.path}/.${file.uri.pathSegments.last}.secret-cleanup.json',
      );
      final queued = jsonDecode(await queue.readAsString()) as Map;
      expect(queued['version'], 1);
      expect((queued['intents'] as List).single['reference'], legacyReference);
    },
  );

  test('agent command change does not inherit resolved secret', () async {
    final temp = await Directory.systemTemp.createTemp('acp_target_agent');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final initial = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(
            name: 'Local',
            type: 'custom',
            command: 'old-agent',
            env: {'TOKEN': 'old-secret'},
          ),
        ],
      ),
      secretStore: store,
    );
    final putCount = store.putCount;

    final changed = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: [
          AgentServerConfig(
            name: 'Local',
            type: 'custom',
            command: 'new-agent',
            env: initial.agentServers.single.env,
          ),
        ],
      ),
      secretStore: store,
    );

    expect(changed.agentServers.single.env, isEmpty);
    expect(changed.agentServers.single.envRefs, isEmpty);
    expect(store.putCount, putCount);
  });

  test(
    'MCP target changes do not inherit top-level or review secrets',
    () async {
      final temp = await Directory.systemTemp.createTemp('acp_target_mcp');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final initial = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'agent-review',
                    'type': 'http',
                    'url': 'https://old-review.example/mcp',
                    'headers': [
                      {'name': 'Authorization', 'value': 'agent-secret'},
                    ],
                  },
                ),
              ),
            ),
          ],
          mcpServers: [
            McpServerConfig(
              raw: {
                'name': 'tools',
                'type': 'http',
                'url': 'https://old.example/mcp',
                'headers': [
                  {'name': 'Authorization', 'value': 'top-secret'},
                ],
              },
            ),
          ],
          clientProviders: AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'global-review',
                    'command': 'old-global-review',
                    'env': [
                      {'name': 'TOKEN', 'value': 'global-secret'},
                    ],
                  },
                ),
              ),
            ),
          ),
        ),
        secretStore: store,
      );
      final putCount = store.putCount;
      final oldAgentReview =
          initial.agentServers.single.permissionReviewAgent.mcpServer!;
      final oldTop = initial.mcpServers.single;
      final oldGlobal =
          initial.clientProviders.permissions.reviewAgent.mcpServer!;

      final changed = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'agent-review',
                    'type': 'http',
                    'url': 'https://new-review.example/mcp',
                    'headers': [
                      for (final entry in oldAgentReview.headers.entries)
                        {'name': entry.key, 'value': entry.value},
                    ],
                  },
                ),
              ),
            ),
          ],
          mcpServers: [
            McpServerConfig(
              raw: {
                'name': 'tools',
                'type': 'http',
                'url': 'https://new.example/mcp',
                'headers': [
                  for (final entry in oldTop.headers.entries)
                    {'name': entry.key, 'value': entry.value},
                ],
              },
            ),
          ],
          clientProviders: AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'global-review',
                    'command': 'new-global-review',
                    'env': [
                      for (final entry in oldGlobal.env.entries)
                        {'name': entry.key, 'value': entry.value},
                    ],
                  },
                ),
              ),
            ),
          ),
        ),
        secretStore: store,
      );

      final changedAgentReview =
          changed.agentServers.single.permissionReviewAgent.mcpServer!;
      final changedGlobal =
          changed.clientProviders.permissions.reviewAgent.mcpServer!;
      expect(changedAgentReview.headers, isEmpty);
      expect(changedAgentReview.headerRefs, isEmpty);
      expect(changed.mcpServers.single.headers, isEmpty);
      expect(changed.mcpServers.single.headerRefs, isEmpty);
      expect(changedGlobal.env, isEmpty);
      expect(changedGlobal.envRefs, isEmpty);
      expect(store.putCount, putCount);
    },
  );

  test(
    'explicit same-key secrets are rekeyed for every changed target',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_target_explicit_secrets',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      final store = FakeSecretStore();
      final initial = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'old-agent',
              env: const {'TOKEN': 'old-agent-secret'},
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
                    'name': 'agent-review',
                    'type': 'http',
                    'url': 'https://old-agent-review.example/mcp',
                    'headers': [
                      {'name': 'Authorization', 'value': 'old-agent-review'},
                    ],
                  },
                ),
              ),
            ),
          ],
          mcpServers: [
            McpServerConfig.fromJson(
              index: 0,
              json: {
                'name': 'tools',
                'type': 'http',
                'url': 'https://old-tools.example/mcp',
                'headers': [
                  {'name': 'Authorization', 'value': 'old-top-secret'},
                ],
              },
            ),
          ],
          clientProviders: AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
                    'name': 'global-review',
                    'command': 'old-global-review',
                    'env': [
                      {'name': 'TOKEN', 'value': 'old-global-secret'},
                    ],
                  },
                ),
              ),
            ),
          ),
        ),
        secretStore: store,
      );
      final oldAgent = initial.agentServers.single;
      final oldAgentReview = oldAgent.permissionReviewAgent.mcpServer!;
      final oldTop = initial.mcpServers.single;
      final oldGlobal =
          initial.clientProviders.permissions.reviewAgent.mcpServer!;

      final changed = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: const [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'new-agent',
              env: {'TOKEN': 'new-agent-secret'},
              explicitEnvKeys: {'TOKEN'},
              permissionReviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'agent-review',
                    'type': 'http',
                    'url': 'https://new-agent-review.example/mcp',
                    'headers': [
                      {'name': 'Authorization', 'value': 'new-agent-review'},
                    ],
                  },
                  explicitHeaderKeys: {'Authorization'},
                ),
              ),
            ),
          ],
          mcpServers: const [
            McpServerConfig(
              raw: {
                'name': 'tools',
                'type': 'http',
                'url': 'https://new-tools.example/mcp',
                'headers': [
                  {'name': 'Authorization', 'value': 'new-top-secret'},
                ],
              },
              explicitHeaderKeys: {'Authorization'},
            ),
          ],
          clientProviders: const AcpClientProviderConfig(
            permissions: AcpPermissionProviderConfig(
              reviewAgent: AcpPermissionReviewAgentConfig(
                enabled: true,
                mcpServer: McpServerConfig(
                  raw: {
                    'name': 'global-review',
                    'command': 'new-global-review',
                    'env': [
                      {'name': 'TOKEN', 'value': 'new-global-secret'},
                    ],
                  },
                  explicitEnvKeys: {'TOKEN'},
                ),
              ),
            ),
          ),
        ),
        secretStore: store,
      );

      final agent = changed.agentServers.single;
      final agentReview = agent.permissionReviewAgent.mcpServer!;
      final top = changed.mcpServers.single;
      final global = changed.clientProviders.permissions.reviewAgent.mcpServer!;
      expect(agent.env, {'TOKEN': 'new-agent-secret'});
      expect(agent.envRefs['TOKEN'], isNot(oldAgent.envRefs['TOKEN']));
      expect(agentReview.headers, {'Authorization': 'new-agent-review'});
      expect(
        agentReview.headerRefs['Authorization'],
        isNot(oldAgentReview.headerRefs['Authorization']),
      );
      expect(top.headers, {'Authorization': 'new-top-secret'});
      expect(
        top.headerRefs['Authorization'],
        isNot(oldTop.headerRefs['Authorization']),
      );
      expect(global.env, {'TOKEN': 'new-global-secret'});
      expect(global.envRefs['TOKEN'], isNot(oldGlobal.envRefs['TOKEN']));
      expect(agent.explicitEnvKeys, isEmpty);
      expect(agentReview.explicitHeaderKeys, isEmpty);
      expect(top.explicitHeaderKeys, isEmpty);
      expect(global.explicitEnvKeys, isEmpty);

      final changedAgain = await AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: file.path,
          agentServers: [
            AgentServerConfig(
              name: agent.name,
              type: agent.type,
              command: 'third-agent',
              env: agent.env,
              explicitEnvKeys: agent.explicitEnvKeys,
            ),
          ],
        ),
        secretStore: store,
      );
      expect(changedAgain.agentServers.single.env, isEmpty);
      expect(changedAgain.agentServers.single.envRefs, isEmpty);
      final persisted = await file.readAsString();
      expect(persisted, isNot(contains('explicitEnvKeys')));
      expect(persisted, isNot(contains('explicitHeaderKeys')));
      expect(persisted, isNot(contains('new-agent-secret')));
      expect(persisted, isNot(contains('new-global-secret')));
    },
  );

  test('saving never deletes a forged reference from the old config', () async {
    final temp = await Directory.systemTemp.createTemp('acp_forged_retired');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final forged = await store.put(
      namespace: 'foreign/config/agent/Other/env',
      key: 'TOKEN',
      value: 'foreign-secret',
    );
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Old': {
            'type': 'custom',
            'command': 'old-agent',
            'env_refs': {'TOKEN': forged},
          },
        },
      }),
    );

    await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(name: 'New', type: 'custom', command: 'new-agent'),
        ],
      ),
      secretStore: store,
    );

    expect(store.deleted, isNot(contains(forged)));
    expect(await store.get(forged), 'foreign-secret');
  });

  test('legacy and forged cleanup sidecars never delete secrets', () async {
    final temp = await Directory.systemTemp.createTemp('acp_forged_sidecar');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString('{}');
    final queue = File(
      '${file.parent.path}/.${file.uri.pathSegments.last}.secret-cleanup.json',
    );
    final store = FakeSecretStore();
    final foreign = await store.put(
      namespace: 'foreign/config/agent/Other/env',
      key: 'TOKEN',
      value: 'foreign-secret',
    );

    await queue.writeAsString(jsonEncode([foreign]));
    await AcpConfigStore.loadConfig(configPath: file.path, secretStore: store);
    expect(store.deleted, isNot(contains(foreign)));

    final configIdentity = await configSecretIdentity(file.path);
    final forgedOwner = SecretOwner(
      configIdentity: configIdentity,
      targetKind: 'agent/Local',
      targetIdentity: 'forged-target',
      fieldName: 'env',
      key: 'TOKEN',
    );
    await queue.writeAsString(
      jsonEncode({
        'version': 1,
        'intents': [
          SecretCleanupIntent(owner: forgedOwner, reference: foreign).toJson(),
        ],
      }),
    );
    await AcpConfigStore.loadConfig(configPath: file.path, secretStore: store);
    expect(store.deleted, isNot(contains(foreign)));
    expect(await store.get(foreign), 'foreign-secret');

    final wrongConfigOwner = SecretOwner(
      configIdentity: 'config/another-config',
      targetKind: 'agent/Other',
      targetIdentity: 'other-target',
      fieldName: 'env',
      key: 'TOKEN',
    );
    final wrongConfigReference = await store.put(
      namespace: wrongConfigOwner.namespace,
      key: wrongConfigOwner.key,
      value: 'another-config-secret',
    );
    await queue.writeAsString(
      jsonEncode({
        'version': 1,
        'intents': [
          SecretCleanupIntent(
            owner: wrongConfigOwner,
            reference: wrongConfigReference,
          ).toJson(),
        ],
      }),
    );
    await AcpConfigStore.loadConfig(configPath: file.path, secretStore: store);
    expect(store.deleted, isNot(contains(wrongConfigReference)));
    expect(await store.get(wrongConfigReference), 'another-config-secret');
  });

  test(
    'forged queue intent cannot shadow a later valid reference intent',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_cleanup_queue_shadow',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('{}');
      final store = FakeSecretStore();
      final configIdentity = await configSecretIdentity(file.path);
      final validOwner = SecretOwner(
        configIdentity: configIdentity,
        targetKind: 'agent/Retired',
        targetIdentity: 'retired-target',
        fieldName: 'env',
        key: 'TOKEN',
      );
      final reference = await store.put(
        namespace: validOwner.namespace,
        key: validOwner.key,
        value: 'retired-secret',
      );
      final forgedOwner = SecretOwner(
        configIdentity: configIdentity,
        targetKind: 'agent/Forged',
        targetIdentity: 'forged-target',
        fieldName: 'env',
        key: 'TOKEN',
      );
      final queue = File(
        '${file.parent.path}/.${file.uri.pathSegments.last}.secret-cleanup.json',
      );
      await queue.writeAsString(
        jsonEncode({
          'version': 1,
          'intents': [
            SecretCleanupIntent(
              owner: forgedOwner,
              reference: reference,
            ).toJson(),
            SecretCleanupIntent(
              owner: validOwner,
              reference: reference,
            ).toJson(),
          ],
        }),
      );

      await AcpConfigStore.loadConfig(
        configPath: file.path,
        secretStore: store,
      );

      expect(store.deleted, contains(reference));
      expect(await store.get(reference), isNull);
    },
  );

  test('cleanup queue never deletes a protected current reference', () async {
    final temp = await Directory.systemTemp.createTemp('acp_protected_cleanup');
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final store = FakeSecretStore();
    final initial = await AcpConfigStore.writeConfig(
      config: AcpClientConfig(
        configPath: file.path,
        agentServers: const [
          AgentServerConfig(
            name: 'Local',
            type: 'custom',
            command: 'agent',
            env: {'TOKEN': 'current-secret'},
          ),
        ],
      ),
      secretStore: store,
    );
    final reference = initial.agentServers.single.envRefs['TOKEN']!;
    final owner = (await collectSecretReferenceOwners(initial))[reference]!;
    final queue = File(
      '${file.parent.path}/.${file.uri.pathSegments.last}.secret-cleanup.json',
    );
    await queue.writeAsString(
      jsonEncode({
        'version': 1,
        'intents': [
          SecretCleanupIntent(owner: owner, reference: reference).toJson(),
        ],
      }),
    );

    await AcpConfigStore.loadConfig(configPath: file.path, secretStore: store);

    expect(store.deleted, isNot(contains(reference)));
    expect(await store.get(reference), 'current-secret');
  });

  test('symlink alias uses the same namespace and stable reference', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final temp = await Directory.systemTemp.createTemp(
      'acp_secret_symlink_path',
    );
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/settings.json');
    final alias = File('${temp.path}/settings-alias.json');
    final store = FakeSecretStore();

    Future<AcpClientConfig> write(String path, String value) {
      return AcpConfigStore.writeConfig(
        config: AcpClientConfig(
          configPath: path,
          agentServers: [
            AgentServerConfig(
              name: 'Local',
              type: 'custom',
              command: 'agent',
              env: {'TOKEN': value},
            ),
          ],
        ),
        secretStore: store,
      );
    }

    final first = await write(target.path, 'first');
    await Link(alias.path).create(target.path);
    final second = await write(alias.path, 'second');

    expect(
      second.agentServers.single.envRefs['TOKEN'],
      first.agentServers.single.envRefs['TOKEN'],
    );
    expect(
      await store.get(first.agentServers.single.envRefs['TOKEN']!),
      'second',
    );
    expect(
      await FileSystemEntity.type(alias.path, followLinks: false),
      FileSystemEntityType.link,
    );
    final targetJson =
        jsonDecode(await target.readAsString()) as Map<String, dynamic>;
    expect(
      targetJson['agent_servers']['Local']['env_refs']['TOKEN'],
      first.agentServers.single.envRefs['TOKEN'],
    );
  });

  test(
    'rejects duplicate structural aliases before migrating secrets',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'acp_secret_structural_alias',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString(
        jsonEncode({
          'agent_servers': {
            'Snake': {
              'type': 'custom',
              'command': 'snake',
              'env': {'TOKEN': 'snake-secret'},
            },
          },
          'agentServers': {
            'Camel': {
              'type': 'custom',
              'command': 'camel',
              'env': {'TOKEN': 'camel-secret'},
            },
          },
        }),
      );

      await expectLater(
        AcpConfigStore.loadConfig(
          configPath: file.path,
          secretStore: FakeSecretStore(),
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('agent_servers'),
          ),
        ),
      );
      final contents = await file.readAsString();
      expect(contents, contains('snake-secret'));
      expect(contents, contains('camel-secret'));
    },
  );
}

final class FakeSecretStore implements SecretStore {
  FakeSecretStore({this.failPutAt, this.failDeletes = false});

  final int? failPutAt;
  bool failDeletes;
  final Map<String, String> values = <String, String>{};
  final Map<String, String> _references = <String, String>{};
  final List<String> deleted = <String>[];
  int _putCount = 0;
  int getCount = 0;

  int get putCount => _putCount;

  @override
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  }) async {
    _putCount += 1;
    if (_putCount == failPutAt) throw StateError('injected put failure');
    final identity = '$namespace\u0000$key';
    final reference = _references.putIfAbsent(
      identity,
      () => referenceFor(namespace: namespace, key: key),
    );
    values[reference] = value;
    return reference;
  }

  @override
  Future<String?> get(String reference) async {
    getCount += 1;
    return values[reference];
  }

  @override
  Future<void> delete(String reference) async {
    deleted.add(reference);
    if (failDeletes) throw StateError('injected delete failure');
    values.remove(reference);
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
