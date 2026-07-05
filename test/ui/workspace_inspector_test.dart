import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/workspace_inspector.dart';
import 'package:ianvs_acp/workspace/workspace.dart';

void main() {
  testWidgets('WorkspaceInspector renders overview and context details', (
    tester,
  ) async {
    final workspace = WorkspaceRecord(
      path: '/workspace/app',
      name: 'app',
      sessions: [
        AgentSession(
          id: 'session-1',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 2, 10),
          title: 'Build workspace shell',
          agentName: 'Codex',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 620,
            child: WorkspaceInspector(
              workspace: workspace,
              agentName: 'Codex',
              currentSession: workspace.sessions.single,
              mcpServers: const [
                McpServerConfig(
                  raw: {
                    'name': 'Filesystem MCP',
                    'type': 'stdio',
                    'command': 'mcp-filesystem',
                  },
                ),
              ],
              additionalDirectories: const ['/workspace/shared'],
              clientProviders: const AcpClientProviderConfig(
                filesystem: AcpFilesystemProviderConfig(readTextFile: true),
                terminal: AcpTerminalProviderConfig(enabled: true),
              ),
              configPath: '/tmp/settings.json',
            ),
          ),
        ),
      ),
    );

    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    expect(find.text('Build workspace shell'), findsWidgets);

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();

    expect(find.text('/workspace/shared'), findsOneWidget);
    expect(find.text('Filesystem MCP'), findsOneWidget);
    expect(find.text('read'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
  });
}
