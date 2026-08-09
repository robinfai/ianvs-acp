import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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

  testWidgets(
    'ProtocolFeatureReviewDialog keeps one scroll position through dismissal',
    (tester) async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await controller.connect();
      await controller.newSession();

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) =>
                        ProtocolFeatureReviewDialog(controller: controller),
                  ),
                  child: const Text('Open coverage'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open coverage'));
      await tester.pumpAndSettle();

      final scrollbar = tester.widget<Scrollbar>(find.byType(Scrollbar));
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollbar.controller, isNotNull);
      expect(scrollbar.controller, same(scrollView.controller));
      expect(scrollbar.controller!.hasClients, isTrue);

      final scrollPosition = tester.getCenter(
        find.byType(SingleChildScrollView),
      );
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: scrollPosition,
          scrollDelta: const Offset(0, 600),
        ),
      );
      await tester.pump(const Duration(milliseconds: 50));
      expect(scrollbar.controller!.offset, greaterThan(0));

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(find.text('Protocol Coverage'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
