import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';

void main() {
  testWidgets('SessionSettingsDialog renders modes and config options', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    expect(find.text('Session Settings'), findsOneWidget);
    expect(find.text('Mode'), findsOneWidget);
    expect(find.text('Ask'), findsOneWidget);
    expect(find.text('Config Options'), findsOneWidget);
    expect(find.text('Approval mode'), findsOneWidget);
    expect(find.text('Suggest first'), findsOneWidget);
  });

  testWidgets('SessionSettingsDialog renders no-session empty state', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    expect(find.text('No active session'), findsOneWidget);
    expect(
      find.text('Create or resume a session to inspect settings.'),
      findsOneWidget,
    );
  });
}
