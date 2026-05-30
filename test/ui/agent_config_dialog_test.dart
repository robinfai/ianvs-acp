import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';

void main() {
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
            clientProviders: AcpClientProviderConfig(
              filesystem: AcpFilesystemProviderConfig(
                readTextFile: true,
                writeTextFile: false,
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
            ],
            agentServers: [
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
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Remote HTTP Agent'), findsOneWidget);
    expect(find.text('https://agent.example.com/acp'), findsOneWidget);
    expect(find.text('Authorization'), findsOneWidget);
    expect(find.text('MCP Servers'), findsOneWidget);
    expect(find.text('filesystem'), findsOneWidget);
    expect(find.text('/usr/local/bin/mcp-filesystem'), findsOneWidget);
    expect(find.text('api-tools'), findsOneWidget);
    expect(find.text('https://api.example.com/mcp'), findsOneWidget);
    expect(find.text('X-MCP-Token'), findsOneWidget);
    expect(find.text('secret'), findsNothing);
    expect(find.text('Client Providers'), findsOneWidget);
    expect(find.text('FS read'), findsOneWidget);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Trust rules'), findsOneWidget);
    expect(find.text('Rule'), findsOneWidget);
    expect(find.text('read_text_file / read -> Allow'), findsOneWidget);
    expect(find.text('1'), findsWidgets);
    expect(find.text('Enabled'), findsWidgets);
    expect(find.text('@zed-industries/codex-acp'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });
}
