import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
            mcpServers: [
              McpServerConfig(
                raw: {
                  'name': 'filesystem',
                  'command': '/usr/local/bin/mcp-filesystem',
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
    expect(find.text('MCP Servers'), findsOneWidget);
    expect(find.text('filesystem'), findsOneWidget);
    expect(find.text('/usr/local/bin/mcp-filesystem'), findsOneWidget);
    expect(find.text('@zed-industries/codex-acp'), findsOneWidget);
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });
}
