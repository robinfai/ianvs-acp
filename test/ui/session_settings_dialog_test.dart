import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';

void main() {
  testWidgets('SessionSettingsDialog prefers config options over modes', (
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
    expect(find.text('Model'), findsNothing);
    expect(find.text('No model option exposed by this session.'), findsNothing);
    expect(find.text('Mode'), findsNothing);
    expect(find.text('Ask'), findsNothing);
    expect(find.text('Config Options'), findsOneWidget);
    expect(find.text('Approval mode'), findsOneWidget);
    expect(find.text('Suggest first'), findsOneWidget);
  });

  testWidgets(
    'SessionSettingsDialog renders legacy modes without config options',
    (tester) async {
      final controller = ChatController(
        client: FakeAgentClient(sessionSettings: _settingsWithModesOnly),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await controller.newSession();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionSettingsDialog(controller: controller)),
        ),
      );

      expect(find.text('Mode'), findsOneWidget);
      expect(find.text('Ask'), findsOneWidget);
      expect(find.text('Config Options'), findsOneWidget);
      expect(
        find.text('No config options exposed by this session.'),
        findsOneWidget,
      );
    },
  );

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

    expect(find.text('Session Configuration'), findsOneWidget);
    expect(find.text('Active model'), findsOneWidget);
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

  testWidgets('SessionSettingsDialog promotes reasoning effort config option', (
    tester,
  ) async {
    final fake = FakeAgentClient(sessionSettings: _settingsWithReasoning);
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    expect(find.text('Session Configuration'), findsOneWidget);
    expect(find.text('Reasoning effort'), findsOneWidget);
    expect(find.text('High'), findsOneWidget);
    expect(find.text('ACP config option: reasoning_effort'), findsOneWidget);
    expect(find.text('Approval mode'), findsOneWidget);

    await tester.tap(find.text('Medium'));
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'reasoning_effort');
    expect(fake.lastConfigValue, 'medium');
    expect(controller.sessionSettings.currentReasoningEffortLabel, 'Medium');
    expect(
      controller.sessionSettings.nonModelConfigOptions.map(
        (option) => option.id,
      ),
      ['approval'],
    );
  });

  testWidgets(
    'SessionSettingsDialog renders boolean config options as switches',
    (tester) async {
      final fake = FakeAgentClient(sessionSettings: _settingsWithBoolean);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await controller.newSession();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionSettingsDialog(controller: controller)),
        ),
      );

      expect(find.text('Read only'), findsOneWidget);
      expect(find.byType(Switch), findsOneWidget);

      await tester.ensureVisible(find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(fake.lastConfigId, 'read_only');
      expect(fake.lastConfigValue, isTrue);
      expect(
        controller.sessionSettings.configOptions.single.currentValue,
        'true',
      );
    },
  );

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

  testWidgets('SessionSettingsDialog confirms and closes active session', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Close Session'));
    await tester.pumpAndSettle();

    expect(find.text('Close Session?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Close Session'));
    await tester.pumpAndSettle();

    expect(fake.lastClosedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
  });

  testWidgets('SessionSettingsDialog stays open when close fails', (
    tester,
  ) async {
    final fake = FakeAgentClient(closeError: Exception('close failed'));
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Close Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Close Session'));
    await tester.pumpAndSettle();

    expect(find.text('Session Settings'), findsOneWidget);
    expect(controller.currentSession?.id, 'fake-session-1');
    expect(controller.lastError, contains('close failed'));
  });

  testWidgets('SessionSettingsDialog confirms and deletes active session', (
    tester,
  ) async {
    final fake = FakeAgentClient(supportsDelete: true);
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Delete Session'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Session?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete Session'));
    await tester.pumpAndSettle();

    expect(fake.lastDeletedSessionId, 'fake-session-1');
    expect(controller.currentSession, isNull);
  });

  testWidgets('SessionSettingsDialog disables settings during operations', (
    tester,
  ) async {
    final fake = _DelayedForkAgentClient(sessionSettings: _settingsWithModel);
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Fork Session'));
    await fake.forkStarted.future;
    await tester.pump();

    expect(controller.isSessionOperationRunning, isTrue);
    final dropdowns = tester.widgetList<DropdownButtonFormField<String>>(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(dropdowns, isNotEmpty);
    expect(dropdowns.every((dropdown) => dropdown.onChanged == null), isTrue);
    final refreshButton = tester.widget<TextButton>(
      find.widgetWithText(TextButton, 'Refresh'),
    );
    expect(refreshButton.onPressed, isNull);

    fake.allowFork.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('SessionSettingsDialog forks active session when supported', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await tester.tap(find.widgetWithText(TextButton, 'Fork Session'));
    await tester.pumpAndSettle();

    expect(fake.lastForkedSessionId, 'fake-session-1');
    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(find.text('Session fake-for'), findsOneWidget);
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

const _settingsWithModesOnly = AcpSessionSettings(
  modes: AcpSessionModeInfo(
    currentModeId: 'ask',
    availableModes: [
      AcpSessionMode(id: 'ask', name: 'Ask'),
      AcpSessionMode(id: 'edit', name: 'Edit'),
    ],
  ),
);

const _settingsWithReasoning = AcpSessionSettings(
  configOptions: [
    AcpConfigOption(
      id: 'model',
      name: 'Model',
      type: 'select',
      currentValue: 'gpt-5',
      options: [AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5')],
    ),
    AcpConfigOption(
      id: 'reasoning_effort',
      name: 'Reasoning Effort',
      type: 'select',
      currentValue: 'high',
      options: [
        AcpConfigOptionChoice(value: 'low', name: 'Low'),
        AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
        AcpConfigOptionChoice(value: 'high', name: 'High'),
      ],
    ),
    AcpConfigOption(
      id: 'approval',
      name: 'Approval mode',
      type: 'select',
      currentValue: 'suggest',
      options: [
        AcpConfigOptionChoice(value: 'suggest', name: 'Suggest first'),
        AcpConfigOptionChoice(value: 'auto', name: 'Auto apply'),
      ],
    ),
  ],
);

const _settingsWithBoolean = AcpSessionSettings(
  configOptions: [
    AcpConfigOption(
      id: 'read_only',
      name: 'Read only',
      type: 'boolean',
      currentValue: 'false',
      description: 'Prevent the agent from writing files.',
      options: [],
    ),
  ],
);

class _DelayedForkAgentClient extends FakeAgentClient {
  _DelayedForkAgentClient({super.sessionSettings});

  final Completer<void> forkStarted = Completer<void>();
  final Completer<void> allowFork = Completer<void>();

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    if (!forkStarted.isCompleted) {
      forkStarted.complete();
    }
    await allowFork.future;
    return super.forkSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}
