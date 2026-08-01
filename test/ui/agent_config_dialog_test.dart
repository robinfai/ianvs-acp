import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/config/assistant_agent_config.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/storage/sqlite_storage_config.dart';
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';

void main() {
  testWidgets('AgentConfigDialog edits the shared SQLite storage policy', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            storage: const SqliteStorageConfig(
              maxSizeGb: 50,
              retentionDays: 30,
              cleanupIntervalHours: 24,
            ),
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [],
          ),
        ),
      ),
    );

    await tester.ensureVisible(
      find.byKey(const Key('storage-max-size-gb-field')),
    );
    await tester.enterText(
      find.byKey(const Key('storage-max-size-gb-field')),
      '80',
    );
    await tester.enterText(
      find.byKey(const Key('storage-retention-days-field')),
      '60',
    );
    await tester.enterText(
      find.byKey(const Key('storage-cleanup-interval-hours-field')),
      '12',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.storage.maxSizeGb, 80);
    expect(savedConfig?.storage.retentionDays, 60);
    expect(savedConfig?.storage.cleanupIntervalHours, 12);
  });

  testWidgets('AgentConfigDialog saves memory configuration', (tester) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            memory: const MemoryConfig(
              maintenance: MemoryMaintenanceConfig(idleEnabled: true),
            ),
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.text('Memory'));
    await tester.pump();
    expect(find.text('Enable memory'), findsOneWidget);
    expect(find.text('Memory daemon URL'), findsNothing);

    await tester.tap(find.byKey(const Key('memory-enabled-switch')));
    await tester.enterText(
      find.byKey(const Key('memory-profile-max-items-field')),
      '2',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.memory.enabled, isTrue);
    expect(savedConfig?.memory.profile.maxItems, 2);
    expect(savedConfig?.memory.maintenance.idleEnabled, isTrue);
  });

  testWidgets('AgentConfigDialog saves the Assistant Agent profile', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    AssistantAgentConfig? validatedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            onValidateAssistantAgent: (config) async {
              validatedConfig = config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/codex',
              ),
              AgentServerConfig(
                name: 'Pi',
                type: 'custom',
                command: '/usr/local/bin/pi',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(
      find.byKey(const Key('assistant-agent-enabled-switch')),
    );
    final enabledSwitch = tester.widget<Switch>(
      find.descendant(
        of: find.byKey(const Key('assistant-agent-enabled-switch')),
        matching: find.byType(Switch),
      ),
    );
    enabledSwitch.onChanged?.call(true);
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('assistant-agent-name-field')),
    );
    final dropdown = tester.widget<DropdownButton<String>>(
      find.descendant(
        of: find.byKey(const Key('assistant-agent-name-field')),
        matching: find.byType(DropdownButton<String>),
      ),
    );
    dropdown.onChanged?.call('Pi');
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('assistant-agent-model-field')),
    );
    await tester.enterText(
      find.byKey(const Key('assistant-agent-model-field')),
      'deepseek-v3',
    );
    await tester.ensureVisible(
      find.byKey(const Key('assistant-title-character-limit-field')),
    );
    await tester.enterText(
      find.byKey(const Key('assistant-title-character-limit-field')),
      '32',
    );
    await tester.ensureVisible(
      find.byKey(const Key('assistant-agent-validate-button')),
    );
    tester
        .widget<OutlinedButton>(
          find.byKey(const Key('assistant-agent-validate-button')),
        )
        .onPressed
        ?.call();
    await tester.pump();

    expect(find.text('Connection and model verified'), findsOneWidget);
    expect(validatedConfig?.agentName, 'Pi');
    expect(validatedConfig?.model, 'deepseek-v3');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.assistantAgent.enabled, isTrue);
    expect(savedConfig?.assistantAgent.agentName, 'Pi');
    expect(savedConfig?.assistantAgent.model, 'deepseek-v3');
    expect(savedConfig?.assistantAgent.fallbackTitleCharacters, 32);
    expect(savedConfig?.assistantAgent.generateSessionTitles, isTrue);
    expect(savedConfig?.assistantAgent.summarizeTurns, isTrue);
    expect(savedConfig?.assistantAgent.collapseExecutionProcess, isTrue);
  });

  testWidgets('AgentConfigDialog renders user config and agent servers', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            defaultAgentName: 'Kimi Code Dev',
            additionalDirectories: [
              '/Users/example/workspace-a',
              '/Users/example/workspace-b',
            ],
            clientProviders: AcpClientProviderConfig(
              filesystem: AcpFilesystemProviderConfig(
                readTextFile: true,
                writeTextFile: false,
              ),
              terminal: AcpTerminalProviderConfig(enabled: true),
              permissions: AcpPermissionProviderConfig(
                reviewAgent: AcpPermissionReviewAgentConfig(
                  enabled: true,
                  mcpServerName: 'permission-reviewer',
                  model: 'review-model',
                ),
                trustRules: [
                  AcpPermissionTrustRule(
                    toolName: 'read_text_file',
                    toolKind: 'read',
                    decision: AcpPermissionDecision.allow,
                  ),
                ],
              ),
            ),
            mcpServers: [
              McpServerConfig(
                raw: {
                  'name': 'filesystem',
                  'command': '/usr/local/bin/mcp-filesystem',
                },
              ),
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
              McpServerConfig(
                raw: {
                  'name': 'nested-agent-tools',
                  'type': 'acp',
                  'id': 'nested-agent',
                },
              ),
            ],
            agentServers: [
              AgentServerConfig(
                name: 'Kimi Code Dev',
                type: 'custom',
                command: '/usr/local/bin/kimi',
                cwd: '/Users/example/kimi-code',
                args: ['acp'],
                permissionReviewAgent: AcpPermissionReviewAgentConfig(
                  enabled: true,
                  model: 'agent-review-model',
                ),
              ),
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
                args: ['@zed-industries/codex-acp'],
              ),
              AgentServerConfig(
                name: 'Remote HTTP Agent',
                type: 'http',
                url: 'https://agent.example.com/acp',
                headers: {'Authorization': 'Bearer test-token'},
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Agent Configuration'), findsOneWidget);
    expect(
      find.text('/Users/example/.config/ianvs-acp/settings.json'),
      findsOneWidget,
    );
    expect(find.text('Kimi Code Dev'), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(find.text('Remote HTTP Agent'), findsOneWidget);
    expect(find.text('Additional Directories'), findsOneWidget);
    expect(find.text('/Users/example/workspace-a'), findsOneWidget);
    expect(find.text('/Users/example/workspace-b'), findsOneWidget);
    expect(find.text('https://agent.example.com/acp'), findsOneWidget);
    expect(find.text('Authorization'), findsOneWidget);
    expect(find.text('MCP Servers'), findsOneWidget);
    expect(find.text('filesystem'), findsOneWidget);
    expect(find.text('/usr/local/bin/mcp-filesystem'), findsOneWidget);
    expect(find.text('api-tools'), findsOneWidget);
    expect(find.text('https://api.example.com/mcp'), findsOneWidget);
    expect(find.text('X-MCP-Token'), findsOneWidget);
    expect(find.text('nested-agent-tools'), findsOneWidget);
    expect(find.text('nested-agent'), findsOneWidget);
    expect(find.text('secret'), findsNothing);
    expect(find.text('Client Providers'), findsOneWidget);
    expect(find.text('FS read'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Trust rules'), findsOneWidget);
    expect(find.text('Review agent'), findsOneWidget);
    expect(find.text('permission-reviewer'), findsOneWidget);
    expect(find.text('Review model'), findsWidgets);
    expect(find.text('review-model'), findsOneWidget);
    expect(find.text('agent-review-model'), findsOneWidget);
    expect(find.text('Same agent'), findsOneWidget);
    expect(find.text('Rule'), findsOneWidget);
    expect(find.text('read_text_file / read -> Allow'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('Enabled'), findsWidgets);
    expect(find.text('@zed-industries/codex-acp'), findsOneWidget);
    expect(find.text('CWD'), findsOneWidget);
    expect(find.text('/Users/example/kimi-code'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('AgentConfigDialog exposes editable configuration controls', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Kimi Code Dev',
            defaultAgentName: 'Kimi Code Dev',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Kimi Code Dev',
                type: 'custom',
                command: '/usr/local/bin/kimi',
                args: ['acp'],
              ),
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
                args: ['@zed-industries/codex-acp'],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.widgetWithText(TextButton, 'Add Agent'), findsOneWidget);
    expect(find.byTooltip('Edit Kimi Code Dev'), findsOneWidget);
    expect(find.byTooltip('Delete Codex'), findsOneWidget);
    expect(find.byTooltip('Set Codex as default'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('Set Codex as default')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('Set Codex as default')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.defaultAgentServerName, 'Codex');
  });

  testWidgets('AgentConfigDialog disables save when config path is missing', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            activeAgentName: 'Codex',
            onSaveConfig: (config) async => config,
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
            ],
          ),
        ),
      ),
    );

    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton.onPressed, isNull);
  });

  testWidgets('AgentConfigDialog rejects invalid review timeout', (
    tester,
  ) async {
    var saved = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            onSaveConfig: (config) async {
              saved = true;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byKey(const Key('review-timeout-field')));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('review-timeout-field')),
      'soon',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(saved, isFalse);
    expect(find.textContaining('positive integer'), findsOneWidget);
  });

  testWidgets('AgentConfigDialog adds and deletes agent servers', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Kimi Code Dev',
            defaultAgentName: 'Kimi Code Dev',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Kimi Code Dev',
                type: 'custom',
                command: '/usr/local/bin/kimi',
                args: ['acp'],
              ),
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
                args: ['@zed-industries/codex-acp'],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pumpAndSettle();
    expect(find.text('Agent Server'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('agent-name-field')),
      'Local Tools',
    );
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      '/usr/local/bin/local-agent',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save Agent'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-name-field')),
      'Remote HTTP Agent',
    );
    await tester.tap(find.byKey(const Key('agent-type-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('http').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-url-field')),
      'https://agent.example.com/acp',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Add Header'));
    await tester.pump();
    await tester.enterText(
      find.byKey(const Key('agent-header-name-0-field')),
      'Authorization',
    );
    await tester.enterText(
      find.byKey(const Key('agent-header-value-0-field')),
      'Bearer token',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save Agent'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('Delete Codex')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('Delete Codex')));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.agentServers.map((server) => server.name), [
      'Kimi Code Dev',
      'Local Tools',
      'Remote HTTP Agent',
    ]);
    expect(
      savedConfig?.agentServerNamed('Local Tools')?.command,
      '/usr/local/bin/local-agent',
    );
    expect(savedConfig?.agentServerNamed('Remote HTTP Agent')?.headers, {
      'Authorization': 'Bearer token',
    });
  });

  testWidgets('AgentConfigDialog adds a preset agent without advanced input', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Existing',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Existing',
                type: 'custom',
                command: '/usr/local/bin/existing',
              ),
            ],
            agentPresets: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
                args: ['@agentclientprotocol/codex-acp'],
              ),
              AgentServerConfig(
                name: 'Pi',
                type: 'custom',
                command: '/usr/local/bin/npx',
                args: ['-y', 'pi-acp@0.0.31'],
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.tap(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('agent-preset-field')), findsOneWidget);
    expect(find.text('Codex is ready to add'), findsOneWidget);
    expect(find.text('Advanced settings'), findsOneWidget);
    expect(
      find.byKey(const Key('agent-command-field')).hitTestable(),
      findsNothing,
    );

    await tester.tap(find.byKey(const Key('agent-preset-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pi').last);
    await tester.pumpAndSettle();

    expect(find.text('Pi is ready to add'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Save Agent'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    final pi = savedConfig?.agentServerNamed('Pi');
    expect(pi?.command, '/usr/local/bin/npx');
    expect(pi?.args, ['-y', 'pi-acp@0.0.31']);
  });

  testWidgets('AgentConfigDialog adds MCP servers', (tester) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Add MCP Server'));
    await tester.pumpAndSettle();
    expect(find.text('MCP Server'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('mcp-name-field')),
      'filesystem',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-command-field')),
      '/usr/local/bin/mcp-filesystem',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save MCP Server'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add MCP Server'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-name-field')),
      'nested-agent-tools',
    );
    await tester.tap(find.byKey(const Key('mcp-type-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('acp').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-id-field')),
      'nested-agent',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save MCP Server'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.mcpServers.map((server) => server.name), [
      'filesystem',
      'nested-agent-tools',
    ]);
    expect(
      savedConfig?.mcpServers.first.command,
      '/usr/local/bin/mcp-filesystem',
    );
    expect(savedConfig?.mcpServers.last.type, 'acp');
    expect(savedConfig?.mcpServers.last.id, 'nested-agent');
  });

  testWidgets('AgentConfigDialog edits directories and client providers', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Add Directory'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('directory-path-field')),
      '/Users/example/extra',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save Directory'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('filesystem-read-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('filesystem-read-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('filesystem-write-switch')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('terminal-enabled-switch')));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, 'Add Trust Rule'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('trust-tool-name-field')),
      'read_text_file',
    );
    await tester.enterText(
      find.byKey(const Key('trust-tool-kind-field')),
      'read',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save Rule'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('review-mcp-server-name-field')),
      'permission-reviewer',
    );
    await tester.enterText(
      find.byKey(const Key('review-model-field')),
      'review-model',
    );
    await tester.enterText(
      find.byKey(const Key('review-timeout-field')),
      '5000',
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.additionalDirectories, ['/Users/example/extra']);
    expect(savedConfig?.clientProviders.filesystem.readTextFile, isTrue);
    expect(savedConfig?.clientProviders.filesystem.writeTextFile, isTrue);
    expect(savedConfig?.clientProviders.terminal.enabled, isTrue);
    expect(
      savedConfig?.clientProviders.permissions.trustRules.single.toolName,
      'read_text_file',
    );
    expect(
      savedConfig?.clientProviders.permissions.trustRules.single.toolKind,
      'read',
    );
    expect(
      savedConfig?.clientProviders.permissions.trustRules.single.decision,
      AcpPermissionDecision.allow,
    );
    expect(
      savedConfig?.clientProviders.permissions.reviewAgent.mcpServerName,
      'permission-reviewer',
    );
    expect(
      savedConfig?.clientProviders.permissions.reviewAgent.model,
      'review-model',
    );
    expect(
      savedConfig?.clientProviders.permissions.reviewAgent.timeout,
      const Duration(milliseconds: 5000),
    );
  });

  testWidgets('saving unrelated fields keeps configured reviewer disabled', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Codex',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
            ],
            clientProviders: const AcpClientProviderConfig(
              permissions: AcpPermissionProviderConfig(
                reviewAgent: AcpPermissionReviewAgentConfig(
                  enabled: false,
                  mcpServerName: 'permission-reviewer',
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    final review = savedConfig?.clientProviders.permissions.reviewAgent;
    expect(review?.enabled, isFalse);
    expect(review?.mcpServerName, 'permission-reviewer');
  });

  testWidgets('editing secret rows stays explicit after text is restored', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    const ref =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Local',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: 'old-agent',
                env: {'TOKEN': 'resolved-agent-secret'},
                envRefs: {'TOKEN': ref},
              ),
            ],
            mcpServers: const [
              McpServerConfig(
                raw: {
                  'name': 'tools',
                  'command': 'old-tool',
                  'env': [
                    {'name': 'TOKEN', 'value': 'resolved-mcp-secret'},
                  ],
                },
                envRefs: {'TOKEN': ref},
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byTooltip('Edit Local'));
    await tester.tap(find.byTooltip('Edit Local'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('agent-command-field')),
      'new-agent',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-name-0-field')),
      'OTHER',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-name-0-field')),
      'TOKEN',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-value-0-field')),
      'changed',
    );
    await tester.enterText(
      find.byKey(const Key('agent-env-value-0-field')),
      'resolved-agent-secret',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save Agent'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byTooltip('Edit tools'));
    await tester.tap(find.byTooltip('Edit tools'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mcp-command-field')),
      'new-tool',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-env-value-0-field')),
      'changed',
    );
    await tester.enterText(
      find.byKey(const Key('mcp-env-value-0-field')),
      'resolved-mcp-secret',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save MCP Server'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    expect(savedConfig?.agentServers.single.explicitEnvKeys, {'TOKEN'});
    expect(savedConfig?.mcpServers.single.explicitEnvKeys, {'TOKEN'});
    expect(
      savedConfig?.agentServers.single.toJson(),
      isNot(contains('explicitEnvKeys')),
    );
    expect(
      savedConfig?.mcpServers.single.toJson(),
      isNot(contains('explicitEnvKeys')),
    );
  });

  testWidgets('renaming agent preserves inline reviewer values for rekeying', (
    tester,
  ) async {
    AcpClientConfig? savedConfig;
    const ref =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentConfigDialog(
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            activeAgentName: 'Old',
            onSaveConfig: (config) async {
              savedConfig = config;
              return config;
            },
            agentServers: const [
              AgentServerConfig(
                name: 'Old',
                type: 'custom',
                command: '/usr/local/bin/agent',
                permissionReviewAgent: AcpPermissionReviewAgentConfig(
                  enabled: true,
                  mcpServer: McpServerConfig(
                    raw: {
                      'name': 'inline-review',
                      'command': '/usr/local/bin/review',
                      'env': [
                        {'name': 'TOKEN', 'value': 'resolved-secret'},
                      ],
                    },
                    envRefs: {'TOKEN': ref},
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.ensureVisible(find.byTooltip('Edit Old'));
    await tester.pump();
    await tester.tap(find.byTooltip('Edit Old'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('agent-name-field')), 'New');
    await tester.tap(find.widgetWithText(FilledButton, 'Save Agent'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump();

    final review = savedConfig?.agentServers.single.permissionReviewAgent;
    expect(savedConfig?.agentServers.single.name, 'New');
    expect(review?.enabled, isTrue);
    expect(review?.mcpServer?.env, {'TOKEN': 'resolved-secret'});
    expect(review?.mcpServer?.envRefs, isEmpty);
  });
}
