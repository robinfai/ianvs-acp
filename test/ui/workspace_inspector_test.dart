import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/acp_session_usage.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/session_time_label.dart';
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
    String? selectedConfigId;
    Object? selectedConfigValue;

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
              sessionSettings: const AcpSessionSettings(
                configOptions: [
                  AcpConfigOption(
                    id: 'model',
                    name: 'Model',
                    type: 'select',
                    currentValue: 'sol',
                    options: [
                      AcpConfigOptionChoice(value: 'sol', name: '5.6 Sol'),
                      AcpConfigOptionChoice(value: 'terra', name: '5.6 Terra'),
                    ],
                  ),
                  AcpConfigOption(
                    id: 'fast_mode',
                    name: 'Fast',
                    type: 'boolean',
                    currentValue: 'true',
                    options: [],
                  ),
                ],
              ),
              sessionUsage: const AcpSessionUsage(used: 2000, size: 8000),
              lastLatency: const Duration(milliseconds: 42),
              onConfigOptionSelected: (configId, value) {
                selectedConfigId = configId;
                selectedConfigValue = value;
              },
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
    // Active sessions open directly on Context, matching the selected design.
    expect(find.text('5.6 Sol'), findsOneWidget);
    expect(find.text('On'), findsOneWidget);
    expect(find.text('25%  2K / 8K'), findsOneWidget);
    expect(find.text('/workspace/shared'), findsOneWidget);
    expect(find.text('Filesystem MCP'), findsOneWidget);
    expect(find.text('read'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('Build workspace shell'), findsWidgets);

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();
    expect(selectedConfigId, 'fast_mode');
    expect(selectedConfigValue, isFalse);

    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    expect(find.text('42 ms'), findsOneWidget);
  });

  testWidgets('WorkspaceInspector shows relative recent session times', (
    tester,
  ) async {
    final now = DateTime(2026, 7, 8, 12);
    debugSessionTimeNow = () => now;
    addTearDown(() {
      debugSessionTimeNow = null;
    });
    final session = AgentSession(
      id: 'session-1',
      cwd: '/workspace/app',
      createdAt: now.subtract(const Duration(hours: 4, minutes: 5)),
      title: 'Build workspace shell',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/app',
      name: 'app',
      sessions: [session],
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
              currentSession: session,
              mcpServers: const [],
              additionalDirectories: const [],
              clientProviders: const AcpClientProviderConfig(),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    expect(find.text('Codex - 4h ago'), findsOneWidget);
  });
}
