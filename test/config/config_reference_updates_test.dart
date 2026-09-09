import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/config/config_reference_updates.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';

void main() {
  test('returns the original config when no reference changes', () {
    const config = AcpClientConfig(
      defaultAgentServerName: 'Agent',
      assistantAgent: AssistantAgentConfig(enabled: true, agentName: 'Agent'),
    );

    expect(remapConfigurationReferences(config), same(config));
    expect(
      remapConfigurationReferences(
        config,
        agentNames: const {'Other': 'Renamed'},
        mcpNames: const {'Other MCP': 'Renamed MCP'},
      ),
      same(config),
    );
  });

  test(
    'remaps every named Agent and MCP reference without changing definitions',
    () {
      const inlineReviewer = McpServerConfig(
        raw: {
          'name': 'Inline reviewer',
          'command': 'inline-reviewer',
          'future_inline': 'preserved',
        },
        envRefs: {'INLINE_TOKEN': 'keychain:inline'},
        explicitEnvKeys: {'INLINE_PLAIN'},
        secretRefsResolved: false,
      );
      const renamedAgent = AgentServerConfig(
        name: 'Agent New',
        type: 'custom',
        persistenceId: 'agent-stable-id',
        persistenceAliases: ['Agent Old'],
        command: '/usr/local/bin/agent',
        cwd: '/workspace',
        args: ['--acp'],
        env: {'PLAIN': 'value'},
        headers: {'X-Plain': 'value'},
        envRefs: {'TOKEN': 'keychain:agent'},
        headerRefs: {'Authorization': 'keychain:header'},
        explicitEnvKeys: {'PLAIN'},
        explicitHeaderKeys: {'X-Plain'},
        secretRefsResolved: false,
        additionalProperties: {'future_agent': 'preserved'},
        permissionReviewAgent: AcpPermissionReviewAgentConfig(
          enabled: true,
          agentServerName: 'Reviewer Old',
          toolName: 'approve',
          model: 'review-model',
          timeout: Duration(seconds: 17),
        ),
      );
      const renamedReviewer = AgentServerConfig(
        name: 'Reviewer New',
        type: 'custom',
        command: '/usr/local/bin/reviewer',
        permissionReviewAgent: AcpPermissionReviewAgentConfig(
          enabled: true,
          mcpServerName: 'MCP Old',
        ),
      );
      const inlineReviewAgent = AgentServerConfig(
        name: 'Inline review Agent',
        type: 'custom',
        command: '/usr/local/bin/inline-agent',
        permissionReviewAgent: AcpPermissionReviewAgentConfig(
          enabled: true,
          mcpServer: inlineReviewer,
        ),
      );
      const oldActiveAgent = AgentServerConfig(
        name: 'Agent Old',
        type: 'custom',
        command: '/usr/local/bin/agent',
      );
      const renamedMcp = McpServerConfig(
        raw: {
          'name': 'MCP New',
          'command': 'mcp-server',
          'future_mcp': 'preserved',
        },
        envRefs: {'TOKEN': 'keychain:mcp'},
        headerRefs: {'Authorization': 'keychain:mcp-header'},
        explicitEnvKeys: {'PLAIN'},
        explicitHeaderKeys: {'X-Plain'},
        secretRefsResolved: false,
      );
      const inheritedMcpTemplate = SessionTemplateConfig(
        id: 'inherit',
        name: 'Inherit MCP',
        mcpServerNames: null,
      );
      const emptyMcpTemplate = SessionTemplateConfig(
        id: 'none',
        name: 'No MCP',
        mcpServerNames: [],
      );
      const referencedTemplate = SessionTemplateConfig(
        id: 'review',
        name: 'Review',
        version: 7,
        description: 'Preserve this template',
        agentServerName: 'Agent Old',
        mode: 'ask',
        model: 'session-model',
        reasoningEffort: 'high',
        additionalDirectories: ['/workspace/shared'],
        mcpServerNames: ['MCP Old', 'Untouched MCP'],
        permissions: AcpPermissionProviderConfig(
          reviewAgent: AcpPermissionReviewAgentConfig(
            enabled: true,
            agentServerName: 'Reviewer Old',
            toolName: 'template-review',
            timeout: Duration(seconds: 23),
          ),
        ),
        assistantAgent: AssistantAgentConfig(
          enabled: true,
          agentName: 'Agent Old',
          model: 'assistant-model',
          generateSessionTitles: false,
          summarizeTurns: false,
          collapseExecutionProcess: false,
          fallbackTitleCharacters: 48,
          timeout: Duration(seconds: 41),
        ),
      );
      const mcpReviewerTemplate = SessionTemplateConfig(
        id: 'mcp-review',
        name: 'MCP Review',
        permissions: AcpPermissionProviderConfig(
          reviewAgent: AcpPermissionReviewAgentConfig(
            enabled: true,
            mcpServerName: 'MCP Old',
          ),
        ),
      );
      const config = AcpClientConfig(
        activeAgentServer: oldActiveAgent,
        agentServers: [renamedAgent, renamedReviewer, inlineReviewAgent],
        mcpServers: [renamedMcp],
        additionalDirectories: ['/workspace/global'],
        clientProviders: AcpClientProviderConfig(
          filesystem: AcpFilesystemProviderConfig(
            readTextFile: true,
            writeTextFile: true,
            allowReadOutsideWorkspace: true,
          ),
          terminal: AcpTerminalProviderConfig(enabled: true),
          permissions: AcpPermissionProviderConfig(
            reviewAgent: AcpPermissionReviewAgentConfig(
              enabled: true,
              mcpServerName: 'MCP Old',
              toolName: 'global-review',
              model: 'global-model',
              timeout: Duration(seconds: 29),
            ),
          ),
        ),
        storage: SqliteStorageConfig(maxSizeGb: 80, retentionDays: 90),
        assistantAgent: AssistantAgentConfig(
          enabled: true,
          agentName: 'Agent Old',
          model: 'global-assistant-model',
          generateSessionTitles: false,
          summarizeTurns: false,
          collapseExecutionProcess: false,
          fallbackTitleCharacters: 64,
          timeout: Duration(seconds: 37),
        ),
        sessionTemplates: [
          inheritedMcpTemplate,
          emptyMcpTemplate,
          referencedTemplate,
          mcpReviewerTemplate,
        ],
        configPath: '/tmp/settings.json',
        defaultAgentServerName: 'Agent Old',
        defaultSessionTemplateId: 'review',
        runtimeSecretGeneration: 11,
      );

      final result = remapConfigurationReferences(
        config,
        agentNames: const {
          'Agent Old': 'Agent New',
          'Reviewer Old': 'Reviewer New',
        },
        mcpNames: const {'MCP Old': 'MCP New'},
      );

      expect(result, isNot(same(config)));
      expect(result.defaultAgentServerName, 'Agent New');
      expect(result.activeAgentServer, same(result.agentServers.first));
      expect(result.activeAgentServer!.name, 'Agent New');
      expect(result.assistantAgent.agentName, 'Agent New');
      expect(
        result.clientProviders.permissions.reviewAgent.mcpServerName,
        'MCP New',
      );

      final agent = result.agentServers.first;
      expect(agent.permissionReviewAgent.agentServerName, 'Reviewer New');
      expect(agent.type, 'custom');
      expect(agent.persistenceId, 'agent-stable-id');
      expect(agent.persistenceAliases, ['Agent Old']);
      expect(agent.command, '/usr/local/bin/agent');
      expect(agent.cwd, '/workspace');
      expect(agent.args, ['--acp']);
      expect(agent.env, {'PLAIN': 'value'});
      expect(agent.headers, {'X-Plain': 'value'});
      expect(agent.envRefs, {'TOKEN': 'keychain:agent'});
      expect(agent.headerRefs, {'Authorization': 'keychain:header'});
      expect(agent.explicitEnvKeys, {'PLAIN'});
      expect(agent.explicitHeaderKeys, {'X-Plain'});
      expect(agent.secretRefsResolved, isFalse);
      expect(agent.additionalProperties['future_agent'], 'preserved');
      expect(agent.permissionReviewAgent.toolName, 'approve');
      expect(agent.permissionReviewAgent.model, 'review-model');
      expect(agent.permissionReviewAgent.timeout, const Duration(seconds: 17));
      expect(
        result.agentServers[1].permissionReviewAgent.mcpServerName,
        'MCP New',
      );

      final inline = result.agentServers[2].permissionReviewAgent.mcpServer!;
      expect(inline, same(inlineReviewer));
      expect(inline.name, 'Inline reviewer');
      expect(inline.raw['future_inline'], 'preserved');
      expect(inline.envRefs, {'INLINE_TOKEN': 'keychain:inline'});
      expect(inline.explicitEnvKeys, {'INLINE_PLAIN'});

      expect(result.mcpServers.single, same(renamedMcp));
      expect(result.mcpServers.single.name, 'MCP New');
      expect(result.mcpServers.single.raw['future_mcp'], 'preserved');
      expect(result.mcpServers.single.envRefs, {'TOKEN': 'keychain:mcp'});
      expect(result.mcpServers.single.headerRefs, {
        'Authorization': 'keychain:mcp-header',
      });
      expect(result.mcpServers.single.explicitEnvKeys, {'PLAIN'});
      expect(result.mcpServers.single.explicitHeaderKeys, {'X-Plain'});
      expect(result.mcpServers.single.secretRefsResolved, isFalse);

      expect(result.sessionTemplates[0], same(inheritedMcpTemplate));
      expect(result.sessionTemplates[0].mcpServerNames, isNull);
      expect(result.sessionTemplates[1], same(emptyMcpTemplate));
      expect(result.sessionTemplates[1].mcpServerNames, isEmpty);
      final template = result.sessionTemplates[2];
      expect(template.id, 'review');
      expect(template.version, 7);
      expect(template.agentServerName, 'Agent New');
      expect(template.mcpServerNames, ['MCP New', 'Untouched MCP']);
      expect(template.permissions!.reviewAgent.agentServerName, 'Reviewer New');
      expect(template.assistantAgent!.agentName, 'Agent New');
      expect(template.assistantAgent!.fallbackTitleCharacters, 48);
      expect(template.assistantAgent!.timeout, const Duration(seconds: 41));
      expect(
        result.sessionTemplates[3].permissions!.reviewAgent.mcpServerName,
        'MCP New',
      );

      expect(result.additionalDirectories, same(config.additionalDirectories));
      expect(
        result.clientProviders.filesystem,
        same(config.clientProviders.filesystem),
      );
      expect(
        result.clientProviders.terminal,
        same(config.clientProviders.terminal),
      );
      expect(result.storage, same(config.storage));
      expect(result.configPath, '/tmp/settings.json');
      expect(result.defaultSessionTemplateId, 'review');
      expect(result.runtimeSecretGeneration, 11);
      expect(result.assistantAgent.model, 'global-assistant-model');
      expect(result.assistantAgent.generateSessionTitles, isFalse);
      expect(result.assistantAgent.summarizeTurns, isFalse);
      expect(result.assistantAgent.collapseExecutionProcess, isFalse);
      expect(result.assistantAgent.fallbackTitleCharacters, 64);
      expect(result.assistantAgent.timeout, const Duration(seconds: 37));

      expect(config.activeAgentServer, same(oldActiveAgent));
      expect(config.defaultAgentServerName, 'Agent Old');
      expect(config.assistantAgent.agentName, 'Agent Old');
      expect(
        config.agentServers.first.permissionReviewAgent.agentServerName,
        'Reviewer Old',
      );
      expect(config.sessionTemplates[2].mcpServerNames, [
        'MCP Old',
        'Untouched MCP',
      ]);
    },
  );

  test('uses each original reference for a single map lookup', () {
    const agentB = AgentServerConfig(name: 'B', type: 'custom', command: 'b');
    const agentC = AgentServerConfig(name: 'C', type: 'custom', command: 'c');
    const config = AcpClientConfig(
      activeAgentServer: AgentServerConfig(
        name: 'A',
        type: 'custom',
        command: 'a',
      ),
      agentServers: [agentB, agentC],
      defaultAgentServerName: 'A',
      assistantAgent: AssistantAgentConfig(enabled: true, agentName: 'B'),
      sessionTemplates: [
        SessionTemplateConfig(
          id: 'chain',
          name: 'Chain',
          agentServerName: 'A',
          mcpServerNames: ['MCP A', 'MCP B'],
        ),
      ],
    );

    final result = remapConfigurationReferences(
      config,
      agentNames: const {'A': 'B', 'B': 'C'},
      mcpNames: const {'MCP A': 'MCP B', 'MCP B': 'MCP C'},
    );

    expect(result.defaultAgentServerName, 'B');
    expect(result.activeAgentServer, same(agentB));
    expect(result.assistantAgent.agentName, 'C');
    expect(result.sessionTemplates.single.agentServerName, 'B');
    expect(result.sessionTemplates.single.mcpServerNames, ['MCP B', 'MCP C']);
  });
}
