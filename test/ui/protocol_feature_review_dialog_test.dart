import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/protocol_feature_review_dialog.dart';

void main() {
  testWidgets('ProtocolFeatureReviewDialog maps ACP areas to GUI surfaces', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      authMethods: const [
        {'id': 'agent-login', 'name': 'Agent login'},
      ],
    );
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionTrustRules: const [
        AcpPermissionTrustRule(
          toolName: 'read_text_file',
          toolKind: 'read',
          decision: AcpPermissionDecision.allow,
        ),
      ],
    );
    addTearDown(controller.dispose);
    await controller.connect();
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProtocolFeatureReviewDialog(
            controller: controller,
            configPath: '/Users/example/.config/ianvs-acp/settings.json',
            agentServers: const [
              AgentServerConfig(
                name: 'Codex',
                type: 'custom',
                command: '/usr/local/bin/npx',
              ),
              AgentServerConfig(
                name: 'Remote Agent',
                type: 'websocket',
                url: 'wss://agent.example.com/acp',
              ),
            ],
            mcpServers: const [
              McpServerConfig(
                raw: {
                  'name': 'filesystem',
                  'command': '/usr/local/bin/mcp-filesystem',
                },
              ),
            ],
            additionalDirectories: const ['/workspace/related'],
            clientProviders: const AcpClientProviderConfig(
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
          ),
        ),
      ),
    );

    expect(find.text('Protocol Coverage'), findsOneWidget);
    expect(find.text('ACP Registry'), findsOneWidget);
    expect(find.text('Follow-up'), findsOneWidget);
    expect(find.text('Session Config Options'), findsOneWidget);
    expect(find.textContaining('Agent Configuration'), findsWidgets);
    expect(find.textContaining('Permission History'), findsOneWidget);
    expect(find.text('protocol/v1/initialization'), findsOneWidget);
    expect(find.textContaining('configured terminal on'), findsOneWidget);
    expect(find.textContaining('configured read on'), findsOneWidget);
    expect(find.textContaining('trust rules on'), findsOneWidget);
  });
}
