import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void main() {
  testWidgets('AppShell authenticates advertised method from agent menu', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      authMethods: const [
        {
          'id': 'browser',
          'name': 'Browser sign-in',
          'description': 'Continue in the agent browser flow.',
        },
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authenticate'));
    await tester.pumpAndSettle();

    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(controller.lastError, isNull);
  });
}
