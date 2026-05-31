import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
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

  testWidgets('AcpClientApp applies updated config from parent', (
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

    await tester.pumpWidget(
      AcpClientApp(
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Claude Code',
          'agent_servers': {
            'Claude Code': {
              'type': 'custom',
              'command': '/usr/local/bin/claude',
              'args': ['acp'],
            },
            'Gemini': {
              'type': 'custom',
              'command': '/usr/local/bin/gemini',
              'args': ['--experimental-acp'],
            },
          },
        }),
      ),
    );

    await tester.tap(find.widgetWithText(OutlinedButton, 'New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsNothing);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Claude Code'), findsWidgets);
    expect(find.text('Gemini'), findsOneWidget);
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
      find.ancestor(
        of: find.byIcon(Icons.arrow_upward_rounded),
        matching: find.byType(FilledButton),
      ),
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
    expect(controller.canResumeSessions, isFalse);

    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets(
    'AcpClientApp disables resume when agent cannot load listed sessions',
    (tester) async {
      final fake = FakeAgentClient(supportsLoadSession: false);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await controller.connect();

      await tester.pumpWidget(AcpClientApp(controller: controller));

      expect(controller.canListSessions, isTrue);
      expect(controller.canResumeSessions, isFalse);

      await tester.tap(find.byTooltip('Resume'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'AcpClientApp blocks resume after connecting to list-only agents',
    (tester) async {
      final fake = FakeAgentClient(supportsLoadSession: false);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await tester.pumpWidget(AcpClientApp(controller: controller));

      expect(controller.canResumeSessions, isTrue);

      await tester.tap(find.byTooltip('Resume'));
      await tester.pumpAndSettle();

      expect(fake.connected, isTrue);
      expect(controller.canListSessions, isTrue);
      expect(controller.canResumeSessions, isFalse);
      expect(find.text('Could not list ACP sessions'), findsOneWidget);
      expect(
        find.textContaining('session/load or session/resume'),
        findsOneWidget,
      );
      final loadButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Load'),
      );
      expect(loadButton.onPressed, isNull);
    },
  );

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

  testWidgets('AcpClientApp preserves global review target with agent model', (
    tester,
  ) async {
    await tester.pumpWidget(
      AcpClientApp(
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Kimi Code Dev',
          'mcp_servers': [
            {
              'name': 'permission-reviewer',
              'type': 'http',
              'url': 'https://reviewer.example.com/mcp',
            },
          ],
          'client_providers': {
            'permissions': {
              'review_agent': {
                'mcp_server_name': 'permission-reviewer',
                'model': 'global-review-model',
              },
            },
          },
          'agent_servers': {
            'Kimi Code Dev': {
              'type': 'custom',
              'command': '/usr/local/bin/kimi',
              'args': ['acp'],
              'review_agent': {'model': 'agent-review-model'},
            },
          },
        }),
      ),
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent Configuration'));
    await tester.pumpAndSettle();

    expect(find.text('Agent Configuration'), findsOneWidget);
    expect(find.text('permission-reviewer'), findsNWidgets(2));
    expect(find.text('agent-review-model'), findsWidgets);
  });

  testWidgets('AcpClientApp changes tool policy from prompt composer', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    await tester.tap(find.text('自动审查'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完全访问权限'));
    await tester.pumpAndSettle();

    expect(
      controller.toolCallExecutionPolicy,
      AcpToolCallExecutionPolicy.fullAccess,
    );
  });

  testWidgets('AcpClientApp changes model from prompt composer', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      sessionSettings: const AcpSessionSettings(
        configOptions: [
          AcpConfigOption(
            id: 'model',
            name: 'Model',
            type: 'select',
            currentValue: 'gpt-5',
            options: [
              AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5'),
              AcpConfigOptionChoice(value: 'mini', name: 'GPT-5 Mini'),
            ],
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(AcpClientApp(controller: controller));
    expect(find.text('GPT-5'), findsOneWidget);

    await tester.tap(find.text('GPT-5'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('GPT-5 Mini'));
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'mini');
    expect(controller.sessionSettings.currentModelLabel, 'GPT-5 Mini');
  });

  testWidgets('AcpClientApp resolves permission requests from composer', (
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
