import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/memory/memory_pending_review_summary.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/memory_explorer_page.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void _noop() {}

void main() {
  Widget toolbar(
    app_state.ConnectionStatus status, {
    String agentName = 'Codex',
    List<AgentServerConfig> agentServers = const <AgentServerConfig>[],
    ValueChanged<String>? onSelectAgent,
    VoidCallback? onShowAgentConfig,
    VoidCallback? onShowProtocolCoverage,
    VoidCallback? onShowMemoryExplorer,
    VoidCallback? onAuthenticate,
    VoidCallback? onShowPermissionHistory,
    VoidCallback? onExtensionRequest,
    VoidCallback? onLogout,
    VoidCallback? onReconnect,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AgentToolbar(
          agentName: agentName,
          agentServers: agentServers,
          status: status,
          onSelectAgent: onSelectAgent,
          onShowAgentConfig: onShowAgentConfig,
          onShowProtocolCoverage: onShowProtocolCoverage,
          onShowMemoryExplorer: onShowMemoryExplorer,
          onAuthenticate: onAuthenticate,
          onShowPermissionHistory: onShowPermissionHistory,
          onExtensionRequest: onExtensionRequest,
          onLogout: onLogout,
          onNewSession: () {},
          onResumeSession: () {},
          onReconnect: onReconnect,
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
    VoidCallback? onShowProtocolCoverage,
    VoidCallback? onShowMemoryExplorer,
    VoidCallback? onAuthenticate,
    VoidCallback? onShowPermissionHistory,
    VoidCallback? onExtensionRequest,
    VoidCallback? onLogout,
    VoidCallback? onReconnect = _noop,
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
        onShowProtocolCoverage: onShowProtocolCoverage,
        onShowMemoryExplorer: onShowMemoryExplorer,
        onAuthenticate: onAuthenticate,
        onShowPermissionHistory: onShowPermissionHistory,
        onExtensionRequest: onExtensionRequest,
        onLogout: onLogout,
        onReconnect: onReconnect,
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

  testWidgets('AgentToolbar shows remote agent URLs in menu', (tester) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.disconnected,
      agentName: 'Remote HTTP Agent',
      agentServers: const [
        AgentServerConfig(
          name: 'Remote HTTP Agent',
          type: 'http',
          url: 'https://agent.example.com/acp',
        ),
        AgentServerConfig(
          name: 'Remote WS Agent',
          type: 'websocket',
          url: 'wss://agent.example.com/acp',
        ),
      ],
      onSelectAgent: (_) {},
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();

    expect(find.text('https://agent.example.com/acp'), findsOneWidget);
    expect(find.text('wss://agent.example.com/acp'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders connected and error states', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connected);
    expect(find.text('connected'), findsOneWidget);

    await pumpToolbar(tester, app_state.ConnectionStatus.error);
    expect(find.text('error'), findsOneWidget);
  });

  testWidgets('AgentToolbar hides reconnect when it is unavailable', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onReconnect: null,
    );

    expect(find.text('Reconnect'), findsNothing);
    expect(find.byTooltip('Reconnect'), findsNothing);
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

  testWidgets('AgentToolbar exposes permission history when available', (
    tester,
  ) async {
    var openedPermissionHistory = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onShowPermissionHistory: () {
        openedPermissionHistory = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Permission History'), findsOneWidget);

    await tester.tap(find.text('Permission History'));
    await tester.pumpAndSettle();

    expect(openedPermissionHistory, isTrue);
  });

  testWidgets('AgentToolbar exposes protocol coverage review', (tester) async {
    var openedProtocolCoverage = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onShowProtocolCoverage: () {
        openedProtocolCoverage = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Protocol Coverage'), findsOneWidget);

    await tester.tap(find.text('Protocol Coverage'));
    await tester.pumpAndSettle();

    expect(openedProtocolCoverage, isTrue);
  });

  testWidgets('AgentToolbar exposes memory explorer', (tester) async {
    var openedMemoryExplorer = false;
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      onShowMemoryExplorer: () {
        openedMemoryExplorer = true;
      },
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    expect(find.text('Memory'), findsOneWidget);

    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();

    expect(openedMemoryExplorer, isTrue);
  });

  testWidgets('AppShell opens memory explorer with provided actions', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          memoryExplorerActions: MemoryExplorerActions(
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_1',
                action: 'update',
                source: 'maintenance',
                targetMemoryIds: ['mem_1'],
                targetMemoryText: 'The user goes by Rod.',
                proposedText: 'The user goes by Rodriguez.',
                confidence: 0.82,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change requests'));
    await tester.pumpAndSettle();

    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);
  });

  testWidgets('AppShell shows memory pending review count in status bar', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryPendingReviewCount: 4,
        ),
      ),
    );

    expect(find.text('memory on · 4 pending'), findsOneWidget);
  });

  testWidgets('AppShell opens memory explorer from status bar memory count', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryPendingReviewCount: 2,
          memoryExplorerActions: MemoryExplorerActions(
            loadChangeRequests: () async => const [
              MemoryChangeRequest(
                id: 'cr_review',
                action: 'merge',
                source: 'maintenance',
                targetMemoryIds: ['mem_1', 'mem_2'],
                proposedText: 'The user goes by Rodriguez.',
                confidence: 0.82,
                status: 'pending',
                createdAt: 1,
              ),
            ],
            approveChangeRequest: (_) async {},
            rejectChangeRequest: (_) async {},
          ),
        ),
      ),
    );

    await tester.tap(find.text('memory on · 2 pending'));
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
    expect(find.text('Change requests'), findsOneWidget);
    expect(find.text('The user goes by Rodriguez.'), findsOneWidget);
  });

  testWidgets(
    'AppShell opens candidates from status bar when only candidates are pending',
    (tester) async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(
            controller: controller,
            memory: const MemoryConfig(enabled: true),
            memoryPendingReview: const MemoryPendingReviewSummary(
              candidateCount: 2,
              changeRequestCount: 0,
            ),
            memoryExplorerActions: MemoryExplorerActions(
              loadCandidates: () async => const [
                MemoryCandidate(
                  id: 'cand_review',
                  kind: 'project_rule',
                  scope: 'repo',
                  text: 'Use curl for local service checks.',
                  confidence: 0.82,
                  status: 'pending',
                  createdAt: 1,
                ),
              ],
              approveCandidate: (_) async {},
              rejectCandidate: (_) async {},
              loadChangeRequests: () async => const <MemoryChangeRequest>[],
              approveChangeRequest: (_) async {},
              rejectChangeRequest: (_) async {},
            ),
          ),
        ),
      );

      await tester.tap(find.text('memory on · 2 pending'));
      await tester.pumpAndSettle();

      expect(find.text('Candidates'), findsOneWidget);
      expect(find.text('Use curl for local service checks.'), findsOneWidget);
    },
  );

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
