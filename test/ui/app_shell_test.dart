import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';

void main() {
  Widget toolbar(
    app_state.ConnectionStatus status, {
    String agentName = 'Codex',
    List<AgentServerConfig> agentServers = const <AgentServerConfig>[],
    ValueChanged<String>? onSelectAgent,
    VoidCallback? onShowAgentConfig,
    VoidCallback? onAuthenticate,
    VoidCallback? onExtensionRequest,
    VoidCallback? onLogout,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AgentToolbar(
          agentName: agentName,
          agentServers: agentServers,
          status: status,
          onSelectAgent: onSelectAgent,
          onShowAgentConfig: onShowAgentConfig,
          onAuthenticate: onAuthenticate,
          onExtensionRequest: onExtensionRequest,
          onLogout: onLogout,
          onNewSession: () {},
          onResumeSession: () {},
          onReconnect: () {},
        ),
      ),
    );
  }

  Future<void> pumpToolbar(
    WidgetTester tester,
    app_state.ConnectionStatus status, {
    Size size = const Size(1400, 720),
    String agentName = 'Codex',
    List<AgentServerConfig> agentServers = const <AgentServerConfig>[],
    ValueChanged<String>? onSelectAgent,
    VoidCallback? onShowAgentConfig,
    VoidCallback? onAuthenticate,
    VoidCallback? onExtensionRequest,
    VoidCallback? onLogout,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      toolbar(
        status,
        agentName: agentName,
        agentServers: agentServers,
        onSelectAgent: onSelectAgent,
        onShowAgentConfig: onShowAgentConfig,
        onAuthenticate: onAuthenticate,
        onExtensionRequest: onExtensionRequest,
        onLogout: onLogout,
      ),
    );
  }

  testWidgets('AgentToolbar initial rendering shows disconnected', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.disconnected);

    expect(find.text('ACP Client'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('disconnected'), findsOneWidget);
    expect(find.text('New Session'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('AgentToolbar lets users select configured agents', (
    tester,
  ) async {
    String? selectedAgent;
    var openedConfig = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.disconnected,
      agentName: 'Kimi Code Dev',
      agentServers: const [
        AgentServerConfig(
          name: 'Kimi Code Dev',
          type: 'custom',
          command: '/usr/local/bin/kimi',
          args: ['acp'],
        ),
        AgentServerConfig(
          name: 'Codex',
          type: 'custom',
          command: '/usr/local/bin/npx',
          args: ['@zed-industries/codex-acp'],
        ),
      ],
      onSelectAgent: (name) {
        selectedAgent = name;
      },
      onShowAgentConfig: () {
        openedConfig = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();

    expect(find.text('Kimi Code Dev'), findsWidgets);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Agent Configuration'), findsOneWidget);

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    expect(selectedAgent, 'Codex');

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent Configuration'));
    await tester.pumpAndSettle();

    expect(openedConfig, isTrue);
  });

  testWidgets('AgentToolbar renders connected and error states', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connected);
    expect(find.text('connected'), findsOneWidget);

    await pumpToolbar(tester, app_state.ConnectionStatus.error);
    expect(find.text('error'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders custom agent name', (tester) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      agentName: 'Kimi Code Dev',
    );

    expect(find.text('Kimi Code Dev'), findsOneWidget);
  });

  testWidgets('AgentToolbar exposes logout when supported', (tester) async {
    var loggedOut = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onLogout: () {
        loggedOut = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Log Out'), findsOneWidget);

    await tester.tap(find.text('Log Out'));
    await tester.pumpAndSettle();

    expect(loggedOut, isTrue);
  });

  testWidgets('AgentToolbar exposes authenticate when auth methods exist', (
    tester,
  ) async {
    var authenticated = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onAuthenticate: () {
        authenticated = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Authenticate'), findsOneWidget);

    await tester.tap(find.text('Authenticate'));
    await tester.pumpAndSettle();

    expect(authenticated, isTrue);
  });

  testWidgets('AgentToolbar exposes extension requests when available', (
    tester,
  ) async {
    var openedExtensionDialog = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onExtensionRequest: () {
        openedExtensionDialog = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Extension Request'), findsOneWidget);

    await tester.tap(find.text('Extension Request'));
    await tester.pumpAndSettle();

    expect(openedExtensionDialog, isTrue);
  });

  testWidgets('AgentToolbar renders connecting state', (tester) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connecting);

    expect(find.text('connecting'), findsOneWidget);
  });

  testWidgets('AgentToolbar compacts actions in narrow windows', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.disconnected,
      size: const Size(800, 720),
    );

    expect(find.text('ACP Client'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.manage_accounts_outlined), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Agents'), findsNothing);
    expect(find.text('New Session'), findsNothing);
  });
}
