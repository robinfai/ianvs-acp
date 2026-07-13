import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';

void main() {
  testWidgets('SessionSettingsDialog accepts the injected input budget', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMetadataPreviewChars: 7,
      maxMetadataPreviewBytes: 9,
    );
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    final dialog = SessionSettingsDialog(
      controller: controller,
      inputBudget: budget,
    );

    await tester.pumpWidget(MaterialApp(home: Scaffold(body: dialog)));

    expect(identical(dialog.inputBudget, budget), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('SessionSettingsDialog lazily builds 1024 config options', (
    tester,
  ) async {
    final settings = AcpSessionSettings(
      configOptions: List<AcpConfigOption>.generate(
        1024,
        (index) => AcpConfigOption(
          id: 'option-$index',
          name: 'Option $index',
          type: 'boolean',
          currentValue: 'false',
          options: const [],
        ),
      ),
    );
    final controller = ChatController(
      client: FakeAgentClient(sessionSettings: settings),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    expect(
      find.byKey(const ValueKey('session-settings-scroll')),
      findsOneWidget,
    );
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(find.byType(SliverList), findsOneWidget);
    expect(find.text('Option 0'), findsOneWidget);
    expect(find.text('Option 1023'), findsNothing);
    expect(
      find.textContaining(RegExp(r'^Option \d+$')).evaluate().length,
      lessThan(32),
    );

    await _jumpSettingsToEnd(tester);
    expect(find.text('Option 1023'), findsOneWidget);
  });

  testWidgets(
    'SessionSettingsDialog does not rescan unchanged config options',
    (tester) async {
      final options = _CountingList<AcpConfigOption>(
        List<AcpConfigOption>.generate(
          1024,
          (index) => AcpConfigOption(
            id: 'option-$index',
            name: 'Option $index',
            type: 'boolean',
            currentValue: 'false',
            options: const [],
          ),
        ),
      );
      final controller = ChatController(
        client: FakeAgentClient(
          sessionSettings: AcpSessionSettings(configOptions: options),
        ),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await controller.newSession();

      Widget app() => MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      );

      await tester.pumpWidget(app());
      expect(options.itemReads, greaterThanOrEqualTo(1024));

      options.resetReads();
      await tester.pumpWidget(app());

      expect(options.itemReads, lessThan(128));
    },
  );

  testWidgets(
    'SessionSettingsDialog projection depends only on config option identity',
    (tester) async {
      final options = _CountingList<AcpConfigOption>(
        List<AcpConfigOption>.generate(
          1024,
          (index) => AcpConfigOption(
            id: 'option-$index',
            name: 'Option $index',
            type: 'boolean',
            currentValue: 'false',
            options: const [],
          ),
        ),
      );
      final initialSettings = AcpSessionSettings(configOptions: options);
      final controller = ChatController(
        client: FakeAgentClient(sessionSettings: initialSettings),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await controller.newSession();

      Widget app(AcpInputBudget budget) => MaterialApp(
        home: Scaffold(
          body: SessionSettingsDialog(
            controller: controller,
            inputBudget: budget,
          ),
        ),
      );

      await tester.pumpWidget(
        app(const AcpInputBudget(maxMetadataPreviewChars: 16)),
      );
      expect(options.itemReads, greaterThanOrEqualTo(1024));

      final omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'session settings',
        truncated: false,
        limit: 1024,
        observedAtLeast: 1025,
      );
      controller.sessionSettings = initialSettings.copyWith(
        truncated: true,
        omissions: [omission],
      );
      expect(
        identical(controller.sessionSettings.configOptions, options),
        isTrue,
      );
      options.resetReads();

      await tester.pumpWidget(
        app(const AcpInputBudget(maxMetadataPreviewChars: 24)),
      );

      expect(options.itemReads, lessThan(128));
      await _jumpSettingsToEnd(tester);
      expect(find.text('Settings incomplete'), findsOneWidget);
    },
  );

  testWidgets('SessionSettingsDialog searches large choices lazily', (
    tester,
  ) async {
    final choices = List<AcpConfigOptionChoice>.generate(
      1024,
      (index) => AcpConfigOptionChoice(
        value: 'model-$index',
        name: 'Model $index',
        description: index == 1023
            ? 'MODEL_DESCRIPTION_CANARY_THAT_MUST_BE_BOUNDED'
            : null,
      ),
    );
    final fake = FakeAgentClient(
      sessionSettings: AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-0',
            options: choices,
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSettingsDialog(
            controller: controller,
            inputBudget: const AcpInputBudget(
              maxMetadataPreviewChars: 12,
              maxMetadataPreviewBytes: 12,
            ),
          ),
        ),
      ),
    );

    expect(find.text('1019 more'), findsOneWidget);
    expect(find.text('Model 0'), findsOneWidget);
    expect(find.text('Model 1023'), findsNothing);

    final settingsScroll = find.byKey(
      const ValueKey('session-settings-scroll'),
    );
    final moreButton = find.descendant(
      of: settingsScroll,
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    await tester.ensureVisible(moreButton);
    await tester.pumpAndSettle();
    await tester.tap(moreButton);
    await tester.pumpAndSettle();
    final listFinder = find.byKey(const ValueKey('settings-choice-list'));
    expect(listFinder, findsOneWidget);
    final list = tester.widget<ListView>(listFinder);
    expect(list.primary, isFalse);
    expect(list.shrinkWrap, isFalse);
    expect(find.text('Model 1023'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('settings-choice-search')),
      'Model 1023',
    );
    await tester.pumpAndSettle();
    expect(find.text('Model 1023'), findsNWidgets(2));
    expect(find.textContaining('MODEL_DESCRIPTION_CANARY'), findsNothing);
    expect(find.textContaining('metadata preview'), findsOneWidget);

    final choiceTile = find.descendant(
      of: listFinder,
      matching: find.widgetWithText(ListTile, 'Model 1023'),
    );
    await tester.tap(choiceTile);
    await tester.pumpAndSettle();
    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'model-1023');
  });

  testWidgets('large choice dialog closes when settings become disabled', (
    tester,
  ) async {
    final choices = List<AcpConfigOptionChoice>.generate(
      1024,
      (index) =>
          AcpConfigOptionChoice(value: 'model-$index', name: 'Model $index'),
    );
    final fake = _DelayedForkAgentClient(
      sessionSettings: AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-0',
            options: choices,
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );
    final moreButton = find.descendant(
      of: find.byKey(const ValueKey('session-settings-scroll')),
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    await tester.ensureVisible(moreButton);
    await tester.pumpAndSettle();
    await tester.tap(moreButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-choice-search')),
      findsOneWidget,
    );

    final forkFuture = controller.forkCurrentSession();
    await fake.forkStarted.future;
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-choice-search')), findsNothing);
    expect(fake.lastConfigId, isNull);
    final disabledMoreButton = find.descendant(
      of: find.byKey(const ValueKey('session-settings-scroll')),
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    expect(tester.widget<TextButton>(disabledMoreButton).onPressed, isNull);

    fake.allowFork.complete();
    await forkFuture;
    await tester.pumpAndSettle();
  });

  testWidgets('large choice dialog closes when its parent unmounts', (
    tester,
  ) async {
    final choices = List<AcpConfigOptionChoice>.generate(
      1024,
      (index) =>
          AcpConfigOptionChoice(value: 'model-$index', name: 'Model $index'),
    );
    final fake = FakeAgentClient(
      sessionSettings: AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-0',
            options: choices,
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );
    final moreButton = find.descendant(
      of: find.byKey(const ValueKey('session-settings-scroll')),
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    await tester.ensureVisible(moreButton);
    await tester.pumpAndSettle();
    await tester.tap(moreButton);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('settings-choice-search')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-choice-search')), findsNothing);
    expect(fake.lastConfigId, isNull);
  });

  testWidgets('large choice late builder closes after immediate disable', (
    tester,
  ) async {
    final choices = List<AcpConfigOptionChoice>.generate(
      1024,
      (index) =>
          AcpConfigOptionChoice(value: 'model-$index', name: 'Model $index'),
    );
    final fake = _DelayedForkAgentClient(
      sessionSettings: AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-0',
            options: choices,
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );
    final moreButton = find.descendant(
      of: find.byKey(const ValueKey('session-settings-scroll')),
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    await tester.ensureVisible(moreButton);
    await tester.pumpAndSettle();

    await tester.tap(moreButton);
    final forkFuture = controller.forkCurrentSession();
    await fake.forkStarted.future;
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-choice-search')), findsNothing);
    expect(fake.lastConfigId, isNull);

    fake.allowFork.complete();
    await forkFuture;
    await tester.pumpAndSettle();
  });

  testWidgets('large choice late builder closes after immediate unmount', (
    tester,
  ) async {
    final choices = List<AcpConfigOptionChoice>.generate(
      1024,
      (index) =>
          AcpConfigOptionChoice(value: 'model-$index', name: 'Model $index'),
    );
    final fake = FakeAgentClient(
      sessionSettings: AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'model-0',
            options: choices,
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );
    final moreButton = find.descendant(
      of: find.byKey(const ValueKey('session-settings-scroll')),
      matching: find.widgetWithText(TextButton, '1019 more'),
    );
    await tester.ensureVisible(moreButton);
    await tester.pumpAndSettle();

    await tester.tap(moreButton);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('settings-choice-search')), findsNothing);
    expect(fake.lastConfigId, isNull);
  });

  testWidgets('SessionSettingsDialog keeps incomplete settings visible', (
    tester,
  ) async {
    final omission = AcpInputOmission(
      reason: AcpInputOmissionReason.inputLimit,
      resource: 'session settings',
      truncated: false,
      limit: 1024,
      observedAtLeast: 1025,
    );
    final controller = ChatController(
      client: FakeAgentClient(
        sessionSettings: AcpSessionSettings(
          omissions: [omission],
          truncated: true,
        ),
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );

    await _jumpSettingsToEnd(tester);
    expect(find.text('Settings incomplete'), findsOneWidget);
    expect(find.textContaining('session settings'), findsOneWidget);
  });

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
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Claude Sonnet 4').last);
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'claude-sonnet-4');
    expect(controller.sessionSettings.currentModelLabel, 'Claude Sonnet 4');
    await _jumpSettingsToEnd(tester);
    expect(find.text('Approval mode'), findsOneWidget);
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
    await _jumpSettingsToEnd(tester);
    expect(find.text('Approval mode'), findsOneWidget);
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

Future<void> _jumpSettingsToEnd(WidgetTester tester) async {
  await tester.fling(
    find.byKey(const ValueKey('session-settings-scroll')),
    const Offset(0, -100000),
    100000,
  );
  await tester.pumpAndSettle();
}

final class _CountingList<E> extends ListBase<E> {
  _CountingList(this._values);

  final List<E> _values;
  int itemReads = 0;

  void resetReads() => itemReads = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => throw UnsupportedError('read only');

  @override
  E operator [](int index) {
    itemReads += 1;
    return _values[index];
  }

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('read only');
  }
}
