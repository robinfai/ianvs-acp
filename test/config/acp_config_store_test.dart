import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_agent_discovery.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';

void main() {
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
            mcpServerName: 'api-tools',
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
    expect(decoded['agent_servers']['Remote HTTP Agent']['headers'], {
      'Authorization': 'Bearer token',
    });
    expect(decoded['mcp_servers'], hasLength(1));
    expect(decoded['mcp_servers'].single['name'], 'api-tools');
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
      decoded['client_providers']['permissions']['review_agent']['mcp_server_name'],
      'api-tools',
    );
    expect(
      decoded['client_providers']['permissions']['review_agent']['timeout_ms'],
      5000,
    );
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
