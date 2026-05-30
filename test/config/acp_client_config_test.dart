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
