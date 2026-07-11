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
    expect(store.deleted, hasLength(1));
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
        ),
        secretStore: store,
      );
      final sourceAgent = source.agentServers.single;
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
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
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
            McpServerConfig.fromJson(
              index: 0,
              json: {
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
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
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
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
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
            McpServerConfig.fromJson(
              index: 0,
              json: {
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
                mcpServer: McpServerConfig.fromJson(
                  index: 0,
                  json: {
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
