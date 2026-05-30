import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
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

  testWidgets('SessionSettingsDialog promotes model config option', (
    tester,
  ) async {
    final fake = FakeAgentClient(sessionSettings: _settingsWithModel);
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    expect(find.text('Model'), findsOneWidget);
    expect(find.text('GPT-5'), findsOneWidget);
    expect(find.text('Approval mode'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Sonnet 4').last);
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'claude-sonnet-4');
    expect(controller.sessionSettings.currentModelLabel, 'Claude Sonnet 4');
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

const _settingsWithModel = AcpSessionSettings(
  modes: AcpSessionModeInfo(
    currentModeId: 'ask',
    availableModes: [
      AcpSessionMode(id: 'ask', name: 'Ask'),
      AcpSessionMode(id: 'edit', name: 'Edit'),
    ],
  ),
  configOptions: [
    AcpConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: 'gpt-5',
      options: [
        AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
        AcpConfigOptionChoice(
          value: 'claude-sonnet-4',
          name: 'Claude Sonnet 4',
        ),
      ],
    ),
    AcpConfigOption(
      id: 'approval',
      name: 'Approval mode',
      type: 'select',
      currentValue: 'suggest',
      description: 'Controls how the agent asks before changing files.',
      group: 'Safety',
      options: [
        AcpConfigOptionChoice(value: 'suggest', name: 'Suggest first'),
        AcpConfigOptionChoice(value: 'auto', name: 'Auto apply'),
      ],
    ),
  ],
);
