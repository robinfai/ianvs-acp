import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
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
    expect(config.mcpServers.last.toJson()['headers'], [
      {'name': 'Authorization', 'value': 'Bearer test-token'},
    ]);

    final selected = config.withActiveAgentServer('Codex');
    expect(selected.mcpServers.map((server) => server.name), [
      'filesystem',
      'api-tools',
    ]);
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
      'id': 'nested-agent',
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
      'env': <Map<String, String>>[],
    });
    expect(config.mcpServers.last.toJson(), {
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

    expect(
      () => AcpClientConfig.fromJson({
        'agent_servers': {
          'Remote Agent': {
            'type': 'websocket',
            'url': 'ws://127.0.0.1/acp',
            'headers': {'Authorization': ''},
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
