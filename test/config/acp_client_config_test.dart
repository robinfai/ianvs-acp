import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/platform/bounded_file_snapshot.dart';
import 'package:path/path.dart' as path_utils;

void main() {
  test('rejects an oversized config before JSON decoding', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-oversized-config-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsBytes(
      List<int>.filled(AcpClientConfig.maxConfigFileBytes + 1, 0x20),
    );

    await expectLater(
      AcpClientConfig.load(path: file.path),
      throwsA(isA<BoundedFileSnapshotOverflowException>()),
    );
  });

  test(
    'loads assistant agent config and preserves it when switching agents',
    () {
      final config = AcpClientConfig.fromJson({
        'assistant_agent': {
          'enabled': true,
          'agent': 'Codex',
          'model': 'gpt-5.6-terra',
          'generate_session_titles': true,
          'summarize_turns': true,
          'collapse_execution_process': true,
          'fallback_title_characters': 32,
          'timeout_ms': 15000,
        },
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex'},
          'Pi': {'type': 'custom', 'command': '/usr/local/bin/pi'},
        },
      });

      expect(config.assistantAgent.isConfigured, isTrue);
      expect(config.assistantAgent.agentName, 'Codex');
      expect(config.assistantAgent.model, 'gpt-5.6-terra');
      expect(config.assistantAgent.fallbackTitleCharacters, 32);
      expect(config.assistantAgent.timeout, const Duration(seconds: 15));

      final selected = config.withActiveAgentServer('Pi');
      expect(selected.assistantAgent.agentName, 'Codex');
      expect(selected.assistantAgent.summarizeTurns, isTrue);
    },
  );

  test('rejects out-of-range assistant fallback title limits', () {
    expect(
      () => AcpClientConfig.fromJson({
        'assistant_agent': {'fallback_title_characters': 4},
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('loads and resolves versioned declarative session templates', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'default_session_template': 'fast-review',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex'},
        'Reviewer': {'type': 'custom', 'command': '/usr/local/bin/reviewer'},
      },
      'mcp_servers': [
        {'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
        {'name': 'browser', 'command': '/usr/local/bin/browser-mcp'},
      ],
      'additional_directories': ['/workspace/shared'],
      'session_templates': {
        'fast-review': {
          'name': 'Fast review',
          'version': 3,
          'description': 'Review with a focused runtime.',
          'agent_server': 'Reviewer',
          'mode': 'review',
          'model': 'fast',
          'reasoning_effort': 'medium',
          'additional_directories': ['/workspace/review'],
          'mcp_servers': ['repo'],
          'permissions': {
            'trust_rules': [
              {'tool_name': 'read_file', 'decision': 'allow'},
            ],
          },
          'assistant_agent': {
            'enabled': true,
            'agent': 'Codex',
            'summarize_turns': true,
          },
        },
      },
    });

    final template = config.defaultSessionTemplate!;
    expect(template.identity, 'fast-review@3');
    expect(template.mode, 'review');
    expect(template.model, 'fast');
    expect(template.reasoningEffort, 'medium');

    final runtime = config.forSessionTemplate(template);
    expect(runtime.agentName, 'Reviewer');
    expect(runtime.mcpServers.map((server) => server.name), ['repo']);
    expect(runtime.additionalDirectories, [
      '/workspace/shared',
      '/workspace/review',
    ]);
    expect(runtime.clientProviders.permissions.trustRules, hasLength(1));
    expect(runtime.assistantAgent.agentName, 'Codex');
    expect(runtime.sessionTemplates.single.identity, 'fast-review@3');
  });

  test('rejects duplicate trimmed MCP server names', () {
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'tools', 'command': '/usr/local/bin/wide-tools'},
          {'name': ' tools ', 'command': '/usr/local/bin/restricted-tools'},
        ],
        'session_templates': {
          'restricted': {
            'name': 'Restricted',
            'mcp_servers': ['tools'],
          },
        },
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('MCP server name "tools" is duplicated'),
        ),
      ),
    );
  });

  test('distinguishes inherited and explicitly empty template MCP sets', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
      ],
      'session_templates': {
        'inherit': {'name': 'Inherit'},
        'isolated': {'name': 'Isolated', 'mcp_servers': []},
      },
    });

    expect(
      config
          .forSessionTemplate(config.sessionTemplateNamed('inherit')!)
          .mcpServers,
      hasLength(1),
    );
    expect(
      config
          .forSessionTemplate(config.sessionTemplateNamed('isolated')!)
          .mcpServers,
      isEmpty,
    );
  });

  test('rejects templates that exclude their effective review MCP', () {
    final globalReviewer = AcpClientConfig.fromJson({
      'mcp_servers': [
        {'name': 'reviewer', 'command': '/usr/local/bin/reviewer-mcp'},
      ],
      'client_providers': {
        'permissions': {
          'review_agent': {'mcp_server_name': 'reviewer'},
        },
      },
      'session_templates': {
        'isolated': {'name': 'Isolated', 'mcp_servers': []},
      },
    });

    expect(
      () => globalReviewer.forSessionTemplate(
        globalReviewer.sessionTemplateNamed('isolated')!,
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('excludes permission-review MCP server "reviewer"'),
        ),
      ),
    );

    final agentReviewer = AcpClientConfig.fromJson({
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/codex',
          'review_agent': {'mcp_server_name': 'reviewer'},
        },
      },
      'mcp_servers': [
        {'name': 'reviewer', 'command': '/usr/local/bin/reviewer-mcp'},
      ],
      'session_templates': {
        'isolated': {'name': 'Isolated', 'mcp_servers': []},
      },
    });
    expect(
      () => agentReviewer.forSessionTemplate(
        agentReviewer.sessionTemplateNamed('isolated')!,
      ),
      throwsFormatException,
    );
  });

  test(
    'rejects malformed template string fields and trimmed duplicate ids',
    () {
      for (final entry in <String, Object?>{
        'name': 3,
        'agent_server': 3,
        'mode': false,
        'model': <String>[],
        'reasoning_effort': 9,
      }.entries) {
        expect(
          () => AcpClientConfig.fromJson({
            'session_templates': {
              'review': {entry.key: entry.value},
            },
          }),
          throwsFormatException,
          reason: entry.key,
        );
      }
      expect(
        () => AcpClientConfig.fromJson({
          'default_session_template': 7,
          'session_templates': {
            'review': {'name': 'Review'},
          },
        }),
        throwsFormatException,
      );
      expect(
        () => AcpClientConfig.fromJson({
          'session_templates': {
            'review': {'name': 'First'},
            ' review ': {'name': 'Second'},
          },
        }),
        throwsFormatException,
      );
    },
  );

  test('rejects an unknown default session template', () {
    expect(
      () => AcpClientConfig.fromJson({'default_session_template': 'missing'}),
      throwsFormatException,
    );
  });

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
      "cwd": "/Users/luobinghui/projects/kimi/kimi-code",
      "args": ["acp"],
      "env": {
        "KIMI_API_KEY": "test-key"
      }
    }
  }
}
''');

    final config = await AcpClientConfig.load(path: file.path);

    expect(config.agentName, 'Kimi Code Dev');
    expect(config.agentServers.map((server) => server.name), ['Kimi Code Dev']);
    expect(config.configPath, file.path);
    expect(
      config.activeAgentServer?.command,
      '/Users/luobinghui/projects/kimi/kimi-code/apps/kimi-code/dist/main.mjs',
    );
    expect(
      config.activeAgentServer?.displayTarget,
      '/Users/luobinghui/projects/kimi/kimi-code/apps/kimi-code/dist/main.mjs',
    );
    expect(
      config.activeAgentServer?.cwd,
      '/Users/luobinghui/projects/kimi/kimi-code',
    );
    expect(config.activeAgentServer?.args, ['acp']);
    expect(config.activeAgentServer?.env, {'KIMI_API_KEY': 'test-key'});
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
          'env': {'KIMI_API_KEY': 'test-key'},
        },
      },
    });

    expect(config.agentName, 'Kimi Code Dev');
    expect(config.activeAgentServer?.command, '/usr/local/bin/kimi');
    expect(config.activeAgentServer?.env, {'KIMI_API_KEY': 'test-key'});
    expect(config.defaultAgentServerName, 'Kimi Code Dev');
  });

  test('resolves saved Codex sessions without configured agent servers', () {
    const config = AcpClientConfig();

    expect(config.configForSessionIndexAgent('Codex'), same(config));
    expect(config.configForSessionIndexAgent(''), same(config));
    expect(config.configForSessionIndexAgent('Kimi'), isNull);
  });

  test('keeps persistence identity across display name changes', () {
    final original = AcpClientConfig.fromJson({
      'agent_servers': {
        'Original name': {'type': 'custom', 'command': '/usr/local/bin/agent'},
      },
    }).activeAgentServer!;
    final renamed = AcpClientConfig.fromJson({
      'agent_servers': {'Renamed agent': original.toJson()},
    });

    expect(
      renamed.activeAgentServer!.persistenceIdentity,
      original.persistenceIdentity,
    );
    expect(
      renamed
          .configForSessionIndexAgent(original.persistenceIdentity)
          ?.agentName,
      'Renamed agent',
    );
    expect(
      renamed.configForSessionIndexAgent('Original name')?.agentName,
      'Renamed agent',
    );
  });

  test('matches native persistence identity and alias boundaries', () {
    final acceptedName = '中' * 85;
    final accepted = AcpClientConfig.fromJson({
      'agent_servers': {
        acceptedName: {
          'type': 'custom',
          'command': '/usr/local/bin/agent',
          'persistence_id': acceptedName,
        },
      },
    }).activeAgentServer!;
    expect(utf8.encode(accepted.persistenceIdentity), hasLength(255));
    expect(utf8.encode(accepted.persistenceNames.single), hasLength(255));

    final tooLong = '中' * 86;
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          tooLong: {'type': 'custom', 'command': '/usr/local/bin/agent'},
        },
      }),
      throwsFormatException,
    );
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Agent': {
            'type': 'custom',
            'command': '/usr/local/bin/agent',
            'persistence_id': tooLong,
          },
        },
      }),
      throwsFormatException,
    );
  });

  test('keeps the 64 most recent persistence aliases', () {
    final server = AcpClientConfig.fromJson({
      'agent_servers': {
        'Current name': {
          'type': 'custom',
          'command': '/usr/local/bin/agent',
          'persistence_aliases': List<String>.generate(
            70,
            (index) => 'Previous $index',
          ),
        },
      },
    }).activeAgentServer!;

    expect(server.persistenceNames, hasLength(64));
    expect(server.persistenceNames, isNot(contains('Previous 0')));
    expect(server.persistenceNames, contains('Previous 7'));
    expect(server.persistenceNames.last, 'Current name');
  });

  test('migration identities distinguish same-target config entries', () {
    final config = AcpClientConfig.fromJson({
      'agent_servers': {
        'Work account': {
          'type': 'custom',
          'command': '/usr/local/bin/agent',
          'env': {'TOKEN': 'work-secret'},
        },
        'Personal account': {
          'type': 'custom',
          'command': '/usr/local/bin/agent',
          'env': {'TOKEN': 'personal-secret'},
        },
      },
    });

    expect(
      config.agentServers.map((server) => server.persistenceIdentity).toSet(),
      hasLength(2),
    );
  });

  test('does not guess an ambiguous persistence alias', () {
    final config = AcpClientConfig.fromJson({
      'agent_servers': {
        'First': {
          'type': 'custom',
          'command': '/usr/local/bin/first',
          'persistence_id': 'first-id',
          'persistence_aliases': ['Shared old name'],
        },
        'Second': {
          'type': 'custom',
          'command': '/usr/local/bin/second',
          'persistence_id': 'second-id',
          'persistence_aliases': ['Shared old name'],
        },
      },
    });

    expect(config.configForSessionIndexAgent('Shared old name'), isNull);
  });

  test('rejects duplicate persistence identities', () {
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'First': {
            'type': 'custom',
            'command': '/usr/local/bin/first',
            'persistence_id': 'shared-id',
          },
          'Second': {
            'type': 'custom',
            'command': '/usr/local/bin/second',
            'persistence_id': 'shared-id',
          },
        },
      }),
      throwsFormatException,
    );
  });

  test('drops historical aliases owned by another configured agent', () {
    final config = AcpClientConfig.fromJson({
      'agent_servers': {
        'Current owner': {
          'type': 'custom',
          'command': '/usr/local/bin/current',
        },
        'Renamed agent': {
          'type': 'custom',
          'command': '/usr/local/bin/renamed',
          'persistence_aliases': ['Current owner', 'Unique old name'],
        },
      },
    });

    final renamed = config.agentServerNamed('Renamed agent')!;
    expect(renamed.persistenceNames, isNot(contains('Current owner')));
    expect(renamed.persistenceNames, contains('Unique old name'));
    expect(
      config.configForSessionIndexAgent('Current owner')?.agentName,
      'Current owner',
    );
  });

  test('rejects a display name that collides with another identity', () {
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'First': {
            'type': 'custom',
            'command': '/usr/local/bin/first',
            'persistence_id': 'Second',
          },
          'Second': {'type': 'custom', 'command': '/usr/local/bin/second'},
        },
      }),
      throwsFormatException,
    );
  });

  test('resolves the pi ACP alias to the single Pi adapter', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        'Pi': {'type': 'custom', 'command': '/Users/example/.local/bin/pi-acp'},
      },
    });

    final resolved = config.configForSessionIndexAgent('pi ACP');

    expect(resolved?.agentName, 'Pi');
    expect(resolved?.activeAgentServer?.command, endsWith('/pi-acp'));
  });

  test('does not guess the Pi alias when multiple adapters remain', () {
    final config = AcpClientConfig.fromJson({
      'agent_servers': {
        'Pi local': {
          'type': 'custom',
          'command': '/Users/example/.local/bin/pi-acp',
        },
        'Pi npx': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['-y', 'pi-acp'],
        },
      },
    });

    expect(config.configForSessionIndexAgent('pi ACP'), isNull);
  });

  test('loads camelCase agent server config aliases', () {
    final config = AcpClientConfig.fromJson({
      'defaultAgentServer': 'Remote Agent',
      'agentServers': {
        'Local Agent': {
          'type': 'custom',
          'command': '/usr/local/bin/local',
          'workingDirectory': '/Users/example/local-agent',
        },
        'Remote Agent': {'type': 'websocket', 'url': 'ws://127.0.0.1:8765/acp'},
      },
    });

    expect(config.agentName, 'Remote Agent');
    expect(config.defaultAgentServerName, 'Remote Agent');
    expect(config.agentServers.map((server) => server.name), [
      'Local Agent',
      'Remote Agent',
    ]);
    expect(config.agentServers.first.cwd, '/Users/example/local-agent');
    expect(config.activeAgentServer?.type, 'websocket');
    expect(config.activeAgentServer?.url, 'ws://127.0.0.1:8765/acp');
  });

  test('loads websocket agent server config', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Remote Agent',
      'agent_servers': {
        'Remote Agent': {
          'type': 'websocket',
          'url': 'ws://127.0.0.1:8765/acp',
          'headers': {'Authorization': 'Bearer test-token'},
        },
      },
    });

    expect(config.agentName, 'Remote Agent');
    expect(config.activeAgentServer?.type, 'websocket');
    expect(config.activeAgentServer?.isWebSocket, isTrue);
    expect(config.activeAgentServer?.url, 'ws://127.0.0.1:8765/acp');
    expect(config.activeAgentServer?.headers, {
      'Authorization': 'Bearer test-token',
    });
  });

  test('loads streamable HTTP agent server config', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'HTTP Agent',
      'agent_servers': {
        'HTTP Agent': {
          'type': 'http',
          'url': 'https://agent.example.com/acp',
          'headers': [
            {'name': 'Authorization', 'value': 'Bearer test-token'},
          ],
        },
      },
    });

    expect(config.agentName, 'HTTP Agent');
    expect(config.activeAgentServer?.type, 'http');
    expect(config.activeAgentServer?.isStreamableHttp, isTrue);
    expect(config.activeAgentServer?.isStdio, isFalse);
    expect(config.activeAgentServer?.url, 'https://agent.example.com/acp');
    expect(config.activeAgentServer?.headers, {
      'Authorization': 'Bearer test-token',
    });
    expect(
      config.activeAgentServer?.displayTarget,
      'https://agent.example.com/acp',
    );
  });

  test('requires TLS for non-loopback remote agent endpoints', () {
    for (final entry in <(String, String)>[
      ('websocket', 'ws://agent.example.com/acp'),
      ('http', 'http://10.0.0.5/acp'),
    ]) {
      expect(
        () => AcpClientConfig.fromJson({
          'agent_servers': {
            'Remote Agent': {'type': entry.$1, 'url': entry.$2},
          },
        }),
        throwsA(isA<FormatException>()),
      );
    }

    for (final entry in <(String, String)>[
      ('websocket', 'ws://[::1]:8765/acp'),
      ('http', 'http://localhost:8080/acp'),
      ('websocket', 'wss://agent.example.com/acp'),
      ('http', 'https://agent.example.com/acp'),
    ]) {
      final config = AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {'type': entry.$1, 'url': entry.$2},
        },
      });

      expect(config.activeAgentServer?.url, entry.$2);
    }
  });

  test('rejects credentials embedded in remote endpoint URLs', () {
    for (final entry in <(String, String)>[
      ('http', 'https://embedded:canary-secret@agent.example.com/acp'),
      ('websocket', 'wss://embedded:canary-secret@agent.example.com/acp'),
    ]) {
      expect(
        () => AcpClientConfig.fromJson({
          'agent_servers': {
            'Remote Agent': {'type': entry.$1, 'url': entry.$2},
          },
        }),
        throwsA(
          isA<FormatException>().having(
            (error) => error.toString(),
            'message',
            isNot(contains('canary-secret')),
          ),
        ),
      );
    }
  });

  test('normalizes agent server transport type casing', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'HTTP Agent',
      'agent_servers': {
        'Local Agent': {'type': ' STDIO ', 'command': '/usr/local/bin/local'},
        'HTTP Agent': {
          'type': ' HTTP ',
          'url': 'https://agent.example.com/acp',
        },
        'Web Agent': {
          'type': ' WebSocket ',
          'url': 'wss://agent.example.com/acp',
        },
      },
    });

    expect(config.activeAgentServer?.type, 'http');
    expect(config.activeAgentServer?.isStreamableHttp, isTrue);
    expect(config.agentServers.map((server) => server.type), [
      'stdio',
      'http',
      'websocket',
    ]);
  });

  test('loads top-level MCP server config', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {
          'name': 'filesystem',
          'command': '/usr/local/bin/mcp-filesystem',
          'args': ['--mode', 'readonly'],
          'env': [
            {'name': 'ROOT', 'value': '/workspace'},
          ],
        },
        {
          'name': 'api-tools',
          'type': 'http',
          'url': 'https://api.example.com/mcp',
          'headers': {'Authorization': 'Bearer test-token'},
        },
      ],
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    expect(config.mcpServers, hasLength(2));
    expect(config.mcpServers.first.name, 'filesystem');
    expect(config.mcpServers.first.command, '/usr/local/bin/mcp-filesystem');
    expect(config.mcpServers.last.type, 'http');
    expect(config.mcpServers.last.url, 'https://api.example.com/mcp');
    expect(config.mcpServers.first.toJson()['env'], [
      {'name': 'ROOT', 'value': '/workspace'},
    ]);
    expect(config.mcpServers.first.toRuntimeJson()['env'], [
      {'name': 'ROOT', 'value': '/workspace'},
    ]);
    expect(config.mcpServers.last.toJson(), isNot(contains('headers')));
    expect(config.mcpServers.last.toRuntimeJson()['headers'], [
      {'name': 'Authorization', 'value': 'Bearer test-token'},
    ]);

    final selected = config.withActiveAgentServer('Codex');
    expect(selected.mcpServers.map((server) => server.name), [
      'filesystem',
      'api-tools',
    ]);
  });

  test('requires TLS for non-loopback remote MCP endpoints', () {
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'type': 'http',
            'url': 'http://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    for (final url in <String>[
      'http://127.0.0.1:8080/mcp',
      'https://api.example.com/mcp',
    ]) {
      final config = AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'api-tools', 'type': 'http', 'url': url},
        ],
      });

      expect(config.mcpServers.single.url, url);
    }
  });

  test('loads ACP transport MCP server config', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {'name': 'nested-agent-tools', 'type': 'acp', 'id': 'nested-agent'},
      ],
    });

    expect(config.mcpServers.single.name, 'nested-agent-tools');
    expect(config.mcpServers.single.type, 'acp');
    expect(config.mcpServers.single.id, 'nested-agent');
    expect(config.mcpServers.single.toJson(), {
      'name': 'nested-agent-tools',
      'type': 'acp',
      'serverId': 'nested-agent',
    });
  });

  test('normalizes MCP server transport type casing', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {
          'name': 'stdio-tools',
          'type': ' STDIO ',
          'command': '/usr/local/bin/mcp-filesystem',
        },
        {
          'name': 'api-tools',
          'type': ' HTTP ',
          'url': 'https://api.example.com/mcp',
        },
      ],
    });

    expect(config.mcpServers.first.type, 'stdio');
    expect(config.mcpServers.first.toJson()['type'], 'stdio');
    expect(config.mcpServers.last.type, 'http');
    expect(config.mcpServers.last.toJson()['type'], 'http');
  });

  test('loads additional directories with aliases and de-duplicates paths', () {
    final config = AcpClientConfig.fromJson({
      'additional_directories': [
        '/Users/example/project-a',
        ' /Users/example/project-b ',
        '/Users/example/project-a',
      ],
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    expect(config.additionalDirectories, [
      '/Users/example/project-a',
      '/Users/example/project-b',
    ]);
    expect(
      config.withActiveAgentServer('Codex').additionalDirectories,
      config.additionalDirectories,
    );

    final camelCaseConfig = AcpClientConfig.fromJson({
      'additionalDirectories': ['/Users/example/extra'],
    });
    expect(camelCaseConfig.additionalDirectories, ['/Users/example/extra']);
  });

  test('rejects invalid additional directories config', () {
    expect(
      () => AcpClientConfig.fromJson({'additional_directories': 'extra'}),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AcpClientConfig.fromJson({
        'additional_directories': ['relative/path'],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AcpClientConfig.fromJson({
        'additional_directories': [''],
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('loads opt-in client filesystem provider config', () {
    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'filesystem': {
          'read_text_file': true,
          'write_text_file': false,
          'allow_read_outside_workspace': true,
        },
      },
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    expect(config.clientProviders.filesystem.readTextFile, isTrue);
    expect(config.clientProviders.filesystem.writeTextFile, isFalse);
    expect(config.clientProviders.filesystem.allowReadOutsideWorkspace, isTrue);

    final selected = config.withActiveAgentServer('Codex');
    expect(selected.clientProviders.filesystem.readTextFile, isTrue);
  });

  test('loads opt-in client terminal provider config', () {
    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'terminal': {'enabled': true},
      },
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    expect(config.clientProviders.terminal.enabled, isTrue);

    final selected = config.withActiveAgentServer('Codex');
    expect(selected.clientProviders.terminal.enabled, isTrue);
  });

  test('loads opt-in client permission trust rules', () {
    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'permissions': {
          'trust_rules': [
            {
              'tool_name': 'read_text_file',
              'tool_kind': 'read',
              'decision': 'allow',
            },
            {'toolName': 'terminal', 'decision': 'deny'},
          ],
        },
      },
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    final rules = config.clientProviders.permissions.trustRules;
    expect(rules, hasLength(2));
    expect(config.clientProviders.permissions.hasTrustRules, isTrue);
    expect(rules[0].toolName, 'read_text_file');
    expect(rules[0].toolKind, 'read');
    expect(rules[0].decision, AcpPermissionDecision.allow);
    expect(rules[1].toolName, 'terminal');
    expect(rules[1].toolKind, isNull);
    expect(rules[1].decision, AcpPermissionDecision.deny);

    final selected = config.withActiveAgentServer('Codex');
    expect(selected.clientProviders.permissions.trustRules, hasLength(2));
  });

  test('loads permission review agent config', () {
    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'permissions': {
          'review_agent': {
            'mcp_server': {
              'name': 'permission-reviewer',
              'command': '/usr/local/bin/review-agent',
              'args': ['mcp'],
            },
            'tool_name': 'review_permission',
            'model': 'review-model',
            'timeout_ms': 5000,
          },
        },
      },
    });

    final reviewAgent = config.clientProviders.permissions.reviewAgent;
    expect(reviewAgent.enabled, isTrue);
    expect(reviewAgent.mcpServer?.name, 'permission-reviewer');
    expect(reviewAgent.mcpServer?.command, '/usr/local/bin/review-agent');
    expect(reviewAgent.toolName, 'review_permission');
    expect(reviewAgent.model, 'review-model');
    expect(reviewAgent.timeout, const Duration(milliseconds: 5000));
    expect(config.clientProviders.permissions.hasReviewAgent, isTrue);
  });

  test('requires TLS for inline remote MCP permission reviewers', () {
    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'review_agent': {
              'mcp_server': {
                'name': 'permission-reviewer',
                'type': 'http',
                'url': 'http://reviewer.example.com/mcp',
              },
            },
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'permissions': {
          'review_agent': {
            'mcp_server': {
              'name': 'permission-reviewer',
              'type': 'http',
              'url': 'http://localhost:8080/mcp',
            },
          },
        },
      },
    });

    expect(
      config.clientProviders.permissions.reviewAgent.mcpServer?.url,
      'http://localhost:8080/mcp',
    );
  });

  test('loads permission review agent by top-level MCP server name', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {
          'name': 'permission-reviewer',
          'type': 'http',
          'url': 'https://reviewer.example.com/mcp',
        },
      ],
      'client_providers': {
        'permissions': {
          'review_agent': {
            'mcp_server_name': 'permission-reviewer',
            'model': 'review-model',
          },
        },
      },
    });

    final reviewAgent = config.clientProviders.permissions.reviewAgent;
    expect(reviewAgent.enabled, isTrue);
    expect(reviewAgent.mcpServerName, 'permission-reviewer');
    expect(reviewAgent.mcpServer, isNull);
    expect(reviewAgent.displayTarget, 'permission-reviewer');
    expect(reviewAgent.model, 'review-model');
  });

  test('loads permission review agent by configured ACP agent name', () {
    final config = AcpClientConfig.fromJson({
      'client_providers': {
        'permissions': {
          'review_agent': {
            'agent_server_name': 'Codex',
            'model': 'review-model',
          },
        },
      },
    });

    final reviewAgent = config.clientProviders.permissions.reviewAgent;
    expect(reviewAgent.enabled, isTrue);
    expect(reviewAgent.agentServerName, 'Codex');
    expect(reviewAgent.hasAgentTarget, isTrue);
    expect(reviewAgent.hasMcpTarget, isFalse);
    expect(reviewAgent.displayTarget, 'Codex');
    expect(reviewAgent.model, 'review-model');
    expect(reviewAgent.toJson()['agent_server_name'], 'Codex');
  });

  test('rejects simultaneous ACP and MCP permission review targets', () {
    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'review_agent': {
              'agent_server_name': 'Codex',
              'mcp_server_name': 'permission-reviewer',
            },
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('loads permission review model from agent server config', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Kimi Code Dev',
      'agent_servers': {
        'Kimi Code Dev': {
          'type': 'custom',
          'command': '/usr/local/bin/kimi',
          'args': ['acp'],
          'review_agent': {'model': 'review-model'},
        },
      },
    });

    final reviewAgent = config.activeAgentServer!.permissionReviewAgent;
    expect(reviewAgent.enabled, isTrue);
    expect(reviewAgent.hasMcpTarget, isFalse);
    expect(reviewAgent.model, 'review-model');
    expect(reviewAgent.isConfigured, isTrue);
  });

  test('rejects invalid client provider config', () {
    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': ['filesystem'],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {'filesystem': true},
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'filesystem': {'read_text_file': 'yes'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'terminal': {'enabled': 'yes'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {'permissions': true},
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {'trust_rules': 'always'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'trust_rules': ['read_text_file'],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'trust_rules': [
              {'decision': 'allow'},
            ],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'trust_rules': [
              {'tool_name': 'read_text_file', 'decision': 'cancel'},
            ],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'review_agent': ['permission-reviewer'],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'review_agent': {
              'mcp_server': {
                'name': 'permission-reviewer',
                'command': '/usr/local/bin/reviewer',
              },
              'mcp_server_name': 'permission-reviewer',
            },
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'client_providers': {
          'permissions': {
            'review_agent': {'timeout_ms': 0},
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('fills required MCP transport arrays when omitted', () {
    final config = AcpClientConfig.fromJson({
      'mcp_servers': [
        {'name': 'stdio-tools', 'command': '/usr/local/bin/mcp-tools'},
        {
          'name': 'api-tools',
          'type': 'http',
          'url': 'https://api.example.com/mcp',
        },
      ],
    });

    expect(config.mcpServers.first.toJson(), {
      'name': 'stdio-tools',
      'command': '/usr/local/bin/mcp-tools',
      'args': <String>[],
    });
    expect(config.mcpServers.last.toJson(), {
      'name': 'api-tools',
      'type': 'http',
      'url': 'https://api.example.com/mcp',
    });
    expect(config.mcpServers.first.toRuntimeJson(), {
      'name': 'stdio-tools',
      'command': '/usr/local/bin/mcp-tools',
      'args': <String>[],
      'env': <Map<String, String>>[],
    });
    expect(config.mcpServers.last.toRuntimeJson(), {
      'name': 'api-tools',
      'type': 'http',
      'url': 'https://api.example.com/mcp',
      'headers': <Map<String, String>>[],
    });
  });

  test('rejects invalid MCP server config', () {
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'command': '/usr/local/bin/mcp-filesystem'},
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'filesystem'},
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'filesystem', 'command': '/usr/local/bin/mcp', 'args': 42},
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'typo-tools',
            'type': 'htp',
            'url': 'https://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'type': 'http',
            'url': 'https://api.example.com/mcp',
            'headers': [
              {'name': 'Authorization'},
            ],
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'type': 'http',
            'command': '/usr/local/bin/mcp-http',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'type': 'http',
            'url': 'ws://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'api-tools', 'type': 'http', 'url': 'https:///mcp'},
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {'name': 'nested-agent-tools', 'type': 'acp'},
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'nested-agent-tools',
            'type': 'acp',
            'id': 'nested-agent',
            'url': 'https://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'nested-agent-tools',
            'type': 'acp',
            'id': 'nested-agent',
            'command': '/usr/local/bin/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'stdio-tools',
            'type': 'stdio',
            'url': 'https://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'command': '/usr/local/bin/mcp-http',
            'url': 'https://api.example.com/mcp',
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'url': 'https://api.example.com/mcp',
            'headers': {'Bad Header': 'token'},
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'url': 'https://api.example.com/mcp',
            'headers': [
              {'name': 'Bad Header', 'value': 'token'},
            ],
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'api-tools',
            'url': 'https://api.example.com/mcp',
            'headers': [
              {'name': 'Authorization', 'value': 'Bearer\nbad'},
            ],
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects duplicate snake and camel secret reference fields', () {
    const first =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const second =
        'keychain://ianvs-acp/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'tools',
            'command': '/usr/local/bin/tools',
            'env_refs': {'TOKEN': first},
            'envRefs': {'TOKEN': second},
          },
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('must not define both env_refs'),
        ),
      ),
    );
  });

  test('rejects invalid websocket agent server config', () {
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {'type': 'websocket'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {'type': 'websocket', 'url': 'https://127.0.0.1/acp'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {'type': 'websocket', 'url': 'ws:///acp'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {
            'type': 'websocket',
            'url': 'ws://127.0.0.1/acp',
            'headers': {'': 'Bearer test-token'},
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    final emptySecret = AcpClientConfig.fromJson({
      'agent_servers': {
        'Remote Agent': {
          'type': 'websocket',
          'url': 'ws://127.0.0.1/acp',
          'headers': {'Authorization': ''},
        },
      },
    });
    expect(emptySecret.agentServers.single.headers['Authorization'], '');
  });

  test('rejects invalid stdio agent cwd config', () {
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Local Agent': {
            'type': 'custom',
            'command': '/usr/local/bin/local',
            'cwd': 'relative/path',
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Local Agent': {
            'type': 'custom',
            'command': '/usr/local/bin/local',
            'working_directory': '',
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects invalid streamable HTTP agent server config', () {
    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'HTTP Agent': {'type': 'http'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'HTTP Agent': {'type': 'http', 'url': 'ws://127.0.0.1/acp'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'HTTP Agent': {'type': 'http', 'url': 'https:///acp'},
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'HTTP Agent': {
            'type': 'http',
            'url': 'https://agent.example.com/acp',
            'headers': [
              {'name': 'Bad Header', 'value': 'token'},
            ],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'HTTP Agent': {
            'type': 'http',
            'url': 'https://agent.example.com/acp',
            'headers': [
              {'name': 'Authorization', 'value': 'Bearer\nbad'},
            ],
          },
        },
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects duplicate MCP env and case-insensitive header names', () {
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'stdio-tools',
            'command': 'tools',
            'env': [
              {'name': 'TOKEN', 'value': 'first'},
              {'name': 'TOKEN', 'value': 'second'},
            ],
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => AcpClientConfig.fromJson({
        'mcp_servers': [
          {
            'name': 'http-tools',
            'type': 'http',
            'url': 'https://tools.example/mcp',
            'headers': [
              {'name': 'Authorization', 'value': 'first'},
              {'name': 'authorization', 'value': 'second'},
            ],
          },
        ],
      }),
      throwsA(isA<FormatException>()),
    );
  });

  test('system config active agent does not override default', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Kimi Code Dev',
      'active_agent_server': 'Codex',
      'agent_servers': {
        'Kimi Code Dev': {
          'type': 'custom',
          'command': '/usr/local/bin/kimi',
          'args': ['acp'],
        },
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    expect(config.agentName, 'Kimi Code Dev');
    expect(config.activeAgentServer?.command, '/usr/local/bin/kimi');
    expect(config.agentServers.map((server) => server.name), [
      'Kimi Code Dev',
      'Codex',
    ]);
  });

  test('selecting an agent is a runtime config change only', () {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Kimi Code Dev',
      'agent_servers': {
        'Kimi Code Dev': {
          'type': 'custom',
          'command': '/usr/local/bin/kimi',
          'args': ['acp'],
        },
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/npx',
          'args': ['@zed-industries/codex-acp'],
        },
      },
    });

    final selected = config.withActiveAgentServer('Codex');

    expect(selected.agentName, 'Codex');
    expect(selected.defaultAgentServerName, 'Kimi Code Dev');
    expect(config.agentName, 'Kimi Code Dev');
  });

  test('missing config file keeps built-in Codex default', () async {
    final config = await AcpClientConfig.load(
      path: '/tmp/ianvs-acp-does-not-exist.json',
      environment: const <String, String>{},
    );

    expect(config.agentName, 'Codex');
    expect(config.activeAgentServer, isNull);
    expect(config.configPath, '/tmp/ianvs-acp-does-not-exist.json');
  });

  test('loads a relative config path and records its absolute path', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-relative-config-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString(
      jsonEncode({
        'agent_servers': {
          'Relative Agent': {'type': 'custom', 'command': 'relative-agent'},
        },
      }),
    );
    final relativePath = path_utils.relative(
      file.path,
      from: Directory.current.path,
    );

    final config = await AcpClientConfig.load(path: relativePath);

    expect(config.agentName, 'Relative Agent');
    expect(
      config.configPath,
      File.fromUri(file.absolute.uri.normalizePath()).path,
    );
  });

  test('resolves default config path under user home', () {
    final path = AcpClientConfig.resolveConfigPath(
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/Users/example/.config/ianvs-acp/settings.json');
  });

  test('resolves default config path from XDG_CONFIG_HOME', () {
    final path = AcpClientConfig.resolveConfigPath(
      environment: const {
        'HOME': '/Users/example',
        'XDG_CONFIG_HOME': '/Users/example/.config-alt',
      },
    );

    expect(path, '/Users/example/.config-alt/ianvs-acp/settings.json');
  });

  test('resolves relative config overrides to absolute paths', () {
    for (final variable in const ['ACP_CONFIG_PATH', 'IANVS_ACP_CONFIG']) {
      final relativePath = [
        'profiles',
        variable.toLowerCase(),
        'settings.json',
      ].join(Platform.pathSeparator);

      expect(
        AcpClientConfig.resolveConfigPath(
          environment: <String, String>{variable: relativePath},
        ),
        File.fromUri(File(relativePath).absolute.uri.normalizePath()).path,
      );
    }
  });

  test('resolves workspace cwd from explicit environment override', () {
    final cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: '/Users/example/app',
      environment: const {'ACP_WORKSPACE_CWD': '/Users/example/workspace'},
    );

    expect(cwd, '/Users/example/workspace');
  });

  test('resolves workspace cwd from current directory when useful', () {
    final cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: '/Users/example/app',
      environment: const {'HOME': '/Users/example'},
    );

    expect(cwd, '/Users/example/app');
  });

  test('falls back to home when GUI launch current directory is root', () {
    final cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: '/',
      environment: const {'HOME': '/Users/example'},
    );

    expect(cwd, '/Users/example');
  });

  test('uses PWD before home when current directory is root', () {
    final cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: '/',
      environment: const {
        'HOME': '/Users/example',
        'PWD': '/Users/example/project',
      },
    );

    expect(cwd, '/Users/example/project');
  });
}
