import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
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

  testWidgets('AcpClientApp disables prompt input during session operations', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      listSessionsDelay: const Duration(milliseconds: 20),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));
    await tester.enterText(find.byType(TextField), 'Keep this draft');
    await tester.pump();

    final loading = controller.listSessions();
    await tester.pump();

    expect(controller.isSessionOperationRunning, isTrue);
    final textField = tester.widget<TextField>(find.byType(TextField));
    final sendButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Send'),
    );
    expect(textField.enabled, isFalse);
    expect(textField.controller?.text, 'Keep this draft');
    expect(sendButton.onPressed, isNull);

    await tester.pump(const Duration(milliseconds: 20));
    await loading;
    await tester.pump();

    expect(controller.isSessionOperationRunning, isFalse);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('AcpClientApp disables resume when agent cannot list sessions', (
    tester,
  ) async {
    final fake = FakeAgentClient(supportsListSessions: false);
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    expect(controller.canListSessions, isFalse);

    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('AcpClientApp opens extension request dialog', (tester) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Extension Request'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Extension Request'), findsOneWidget);
    expect(find.text('Method'), findsOneWidget);
    expect(find.text('Params JSON'), findsOneWidget);
  });

  testWidgets('AcpClientApp resolves permission requests from banner', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await tester.pumpWidget(AcpClientApp(controller: controller));
    fake.emitPermissionRequest(
      AcpPermissionRequest(
        id: 'permission-1',
        title: 'Read file',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'read_text_file',
        toolKind: 'read',
        options: const ['Allow', 'Deny'],
        requestedAt: DateTime(2026, 5, 31, 12),
      ),
    );
    await tester.pump();

    expect(find.text('Read file'), findsOneWidget);
    expect(find.text('Allow Once'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Allow Once'));
    await tester.pump();

    expect(fake.lastPermissionRequestId, 'permission-1');
    expect(fake.lastPermissionDecision, AcpPermissionDecision.allow);
    expect(find.text('Read file'), findsNothing);

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Permission History'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Permission History'), findsOneWidget);
    expect(find.text('Read file'), findsOneWidget);
    expect(find.text('Allowed'), findsOneWidget);
  });
}
