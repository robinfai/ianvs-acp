import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';

void main() {
  testWidgets('AcpClientApp opens new session agent picker', (tester) async {
    await tester.pumpWidget(
      AcpClientApp(
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Kimi Code Dev',
          'agent_servers': {
            'Kimi Code Dev': {
              'type': 'custom',
              'command': '/usr/local/bin/kimi',
              'args': ['acp'],
            },
            'Codex': {
              'type': 'custom',
              'command': '/usr/local/bin/npx',
              'args': ['@zed-industries/codex-acp'],
            },
          },
        }),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsWidgets);
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('AcpClientApp toolbar new session opens agent picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      AcpClientApp(
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Kimi Code Dev',
          'agent_servers': {
            'Kimi Code Dev': {
              'type': 'custom',
              'command': '/usr/local/bin/kimi',
              'args': ['acp'],
            },
            'Codex': {
              'type': 'custom',
              'command': '/usr/local/bin/npx',
              'args': ['@zed-industries/codex-acp'],
            },
          },
        }),
      ),
    );

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsWidgets);
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('AcpClientApp shows startup config errors without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const AcpClientApp(startupError: 'Could not load ACP config: bad json'),
    );

    expect(find.textContaining('bad json'), findsOneWidget);
    expect(find.text('ACP Client'), findsOneWidget);
  });

  testWidgets('AcpClientApp does not dispose injected controller', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    expect(fake.connected, isTrue);

    await tester.pumpWidget(AcpClientApp(controller: controller));
    await tester.pumpWidget(const SizedBox.shrink());

    expect(fake.connected, isTrue);
  });
}
