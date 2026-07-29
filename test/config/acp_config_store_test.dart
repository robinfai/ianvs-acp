import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/acp_config_store.dart';
import 'package:ianvs_acp/memory/memory_config.dart';

void main() {
  test('serializes memory config', () {
    final settings = AcpConfigStore.toSettingsJson(
      const AcpClientConfig(
        memory: MemoryConfig(
          enabled: true,
          extractor: MemoryExtractorConfig(agent: 'Codex', model: 'gpt-5-mini'),
          llm: MemoryLlmConfig(apiKeyEnv: 'OLLAMA_API_KEY'),
          maintenance: MemoryMaintenanceConfig(
            idleEnabled: true,
            idleAfterTurns: 4,
            idleMaxPendingReviews: 2,
          ),
        ),
      ),
    );

    final memory = settings['memory'] as Map<String, Object?>;
    expect(memory['enabled'], isTrue);
    expect((memory['extractor'] as Map<String, Object?>)['agent'], 'Codex');
    expect(
      (memory['extractor'] as Map<String, Object?>)['model'],
      'gpt-5-mini',
    );
    expect(
      (memory['llm'] as Map<String, Object?>)['api_key_env'],
      'OLLAMA_API_KEY',
    );
    final maintenance = memory['maintenance'] as Map<String, Object?>;
    expect(maintenance['idle_enabled'], true);
    expect(maintenance['idle_after_turns'], 4);
    expect(maintenance['idle_max_pending_reviews'], 2);
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

  test(
    'writes memory config while preserving future fields and dropping deprecated daemon fields',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_acp_config_store_memory',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('''
{
  "memory": {
    "enabled": true,
    "daemon_base_url": "http://127.0.0.1:43129",
    "daemonTokenEnv": "OLD_TOKEN_ENV",
    "future_policy": {
      "idle_compaction": true
    },
    "extractor": {
      "provider": "acp-sidecar",
      "agent": "Old Agent",
      "experimental_prompt_budget": 512
    },
    "maintenance": {
      "mode": "manual_review",
      "future_window": "weekly"
    }
  }
}
''');

      await AcpConfigStore.writeConfig(
        config: const AcpClientConfig(
          memory: MemoryConfig(
            enabled: true,
            extractor: MemoryExtractorConfig(agent: 'Codex'),
            maintenance: MemoryMaintenanceConfig(mode: 'high_confidence_auto'),
          ),
        ),
        configPath: file.path,
      );

      final decoded =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final memory = decoded['memory'] as Map<String, dynamic>;
      expect(memory['enabled'], isTrue);
      expect(memory, isNot(contains('daemon_base_url')));
      expect(memory, isNot(contains('daemonTokenEnv')));
      expect(memory['future_policy'], {'idle_compaction': true});
      expect(memory['extractor']['agent'], 'Codex');
      expect(memory['extractor']['experimental_prompt_budget'], 512);
      expect(memory['maintenance']['mode'], 'high_confidence_auto');
      expect(memory['maintenance']['future_window'], 'weekly');
    },
  );

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
}
