import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/components/workspace_inspector.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_terminal_core/ianvs_terminal_core.dart';

void _noop() {}

void main() {
  Widget toolbar(
    app_state.ConnectionStatus status, {
    String agentName = 'Codex',
    List<AgentServerConfig> agentServers = const <AgentServerConfig>[],
    ValueChanged<String>? onSelectAgent,
    VoidCallback? onShowAgentConfig,
    VoidCallback? onShowProtocolCoverage,
    VoidCallback? onAuthenticate,
    VoidCallback? onShowPermissionHistory,
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
          onAuthenticate: onAuthenticate,
          onShowPermissionHistory: onShowPermissionHistory,
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
    VoidCallback? onAuthenticate,
    VoidCallback? onShowPermissionHistory,
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
        onAuthenticate: onAuthenticate,
        onShowPermissionHistory: onShowPermissionHistory,
        onLogout: onLogout,
        onReconnect: onReconnect,
      ),
    );
  }

  testWidgets('AgentToolbar initial rendering shows disconnected', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.disconnected);

    expect(find.text('Codex'), findsWidgets);
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
    expect(find.text('Codex'), findsWidgets);
    expect(find.text('Agent Configuration'), findsOneWidget);

    await tester.tap(find.text('Codex').last);
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

  testWidgets('AgentToolbar hides healthy status and shows errors', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connected);
    expect(find.text('connected'), findsNothing);

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

    expect(find.text('Codex'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.manage_accounts_outlined), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.text('Agents'), findsNothing);
    expect(find.text('New Session'), findsNothing);

    final resumeButton = find
        .ancestor(
          of: find.byIcon(Icons.play_circle_outline),
          matching: find.byType(InkWell),
        )
        .first;
    final newSessionButton = find
        .ancestor(
          of: find.byIcon(Icons.add_rounded),
          matching: find.byType(FilledButton),
        )
        .first;
    final resumeSize = tester.getSize(resumeButton);
    final newSessionSize = tester.getSize(newSessionButton);
    expect(resumeSize.width, 34);
    expect(newSessionSize.width, 34);
    expect(resumeSize.height, greaterThanOrEqualTo(31));
    expect(newSessionSize.height, resumeSize.height);
  });

  testWidgets('AgentToolbar uses conversation labels for session actions', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentToolbar(
            title: 'UI review',
            status: app_state.ConnectionStatus.sessionReady,
            onNewSession: _noop,
            onResumeSession: _noop,
            onReconnect: null,
            currentSession: AgentSession(
              id: 'session-1',
              cwd: '/workspace/app',
              createdAt: DateTime(2026, 8, 7),
            ),
            onSessionMenuAction: (_) {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();

    expect(find.text('Pin Conversation'), findsOneWidget);
    expect(find.text('Rename Conversation'), findsOneWidget);
    expect(find.text('Archive Conversation'), findsOneWidget);

    final actionRect = tester.getRect(
      find.byKey(const Key('toolbar-session-actions')),
    );
    final menuRect = tester.getRect(
      find.ancestor(
        of: find.text('Pin Conversation'),
        matching: find.byType(MenuItemButton),
      ),
    );
    expect(
      actionRect.center.dx,
      inInclusiveRange(menuRect.left, menuRect.right),
    );
    expect(menuRect.top, greaterThan(actionRect.bottom));
  });

  testWidgets('AppShell loads session catalogs for every controller', (
    tester,
  ) async {
    final codexClient = FakeAgentClient();
    final piClient = FakeAgentClient();
    final codex = ChatController(
      client: codexClient,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    final pi = ChatController(
      client: piClient,
      cwd: '/workspace/app',
      agentName: 'pi ACP',
    );
    addTearDown(codex.dispose);
    addTearDown(pi.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: codex,
          agentName: 'Codex',
          sessionControllers: [codex, pi],
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(codexClient.connected, isTrue);
    expect(piClient.connected, isTrue);
    expect(codex.sessions.map((session) => session.id), contains('session-a'));
    expect(pi.sessions.map((session) => session.id), contains('session-a'));
  });

  testWidgets('AppShell docks prompt and status inside conversation column', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(controller: controller, agentName: 'Codex'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    final promptRect = tester.getRect(
      find.byKey(const Key('prompt-input-surface')),
    );
    final sidebarRect = tester.getRect(find.byType(WorkspaceSidebar));
    final inspectorRect = tester.getRect(find.byType(WorkspaceInspector));

    expect(sidebarRect.width, moreOrLessEquals(320));
    expect(promptRect.left, greaterThanOrEqualTo(sidebarRect.right));
    expect(promptRect.right, lessThan(inspectorRect.left));
  });

  testWidgets('AppShell terminal follows the active ACP session lifecycle', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    final backend = _RecordingTerminalBackend();
    TerminalRuntimeController createRuntime() => TerminalRuntimeController(
      backend: backend,
      copyToClipboard: (_) async {},
      readClipboard: () async => '',
      enableSessionPolling: false,
    );
    addTearDown(controller.dispose);
    await tester.runAsync(controller.newSession);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          agentName: 'Codex',
          terminalRuntimeFactory: createRuntime,
        ),
      ),
    );
    await tester.pump();

    final toggle = find.byKey(const Key('acp-terminal-panel-toggle'));
    expect(toggle, findsOneWidget);
    expect(find.byKey(const Key('acp-terminal-panel')), findsNothing);
    expect(backend.createdSessionIds, isEmpty);

    await tester.tap(toggle);
    await tester.pump();

    final panel = find.byKey(const Key('acp-terminal-panel'));
    expect(panel, findsOneWidget);
    expect(
      find.descendant(of: panel, matching: find.text('app')),
      findsOneWidget,
    );
    expect(backend.createdSessionIds, ['terminal-session-1']);
    final panelRect = tester.getRect(panel);
    final sidebarRect = tester.getRect(find.byType(WorkspaceSidebar));
    final inspectorRect = tester.getRect(find.byType(WorkspaceInspector));
    expect(panelRect.left, moreOrLessEquals(sidebarRect.right, epsilon: 1.1));
    expect(panelRect.right, greaterThan(inspectorRect.right - 1));
    expect(panelRect.height, moreOrLessEquals(261, epsilon: 1.1));

    await tester.tap(find.byKey(const Key('terminal-panel-add')));
    await tester.pump();
    expect(
      find.descendant(of: panel, matching: find.text('app 2')),
      findsOneWidget,
    );
    expect(backend.createdSessionIds, [
      'terminal-session-1',
      'terminal-session-2',
    ]);

    await tester.runAsync(controller.newSession);
    await tester.pump();

    expect(find.byKey(const Key('acp-terminal-panel')), findsNothing);
    expect(
      backend.closedSessionIds,
      containsAll(['terminal-session-1', 'terminal-session-2']),
    );

    await tester.tap(toggle);
    await tester.pump();
    expect(backend.createdSessionIds.last, 'terminal-session-3');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(backend.closedSessionIds, contains('terminal-session-3'));
  });

  testWidgets(
    'AppShell queues composer submissions while the active turn is streaming',
    (tester) async {
      final client = FakeAgentClient(chunkDelay: const Duration(seconds: 1));
      final controller = ChatController(
        client: client,
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);
      await tester.runAsync(controller.newSession);

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(controller: controller, agentName: 'Codex'),
        ),
      );
      await tester.pump();

      await tester.runAsync(() => controller.sendPrompt('active turn'));
      await tester.pump();
      expect(controller.isStreaming, isTrue);

      final promptField = find.descendant(
        of: find.byKey(const Key('prompt-input-surface')),
        matching: find.byType(TextField),
      );
      await tester.enterText(promptField, 'queued follow-up');
      await tester.pump();
      await tester.tap(find.byKey(const Key('prompt-queue-button')));
      await tester.pump();

      expect(controller.queuedPrompts, hasLength(1));
      expect(controller.queuedPrompts.single.text, 'queued follow-up');
      expect(find.byKey(const Key('prompt-queue-tray')), findsOneWidget);

      controller.clearQueuedPrompts();
      await tester.runAsync(controller.stop);
    },
  );

  testWidgets('AppShell adds an explicit empty-state action on desktop', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(controller: controller, agentName: 'Codex'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('ACP Client'), findsOneWidget);
    expect(find.text('New Session'), findsNWidgets(2));
  });

  testWidgets('AppShell keeps an explicit New Session action when compact', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(800, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(controller: controller, agentName: 'Codex'),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.widgetWithText(FilledButton, 'New Session'), findsOneWidget);
  });

  testWidgets('AppShell resumes sessions from another agent', (tester) async {
    final codexClient = FakeAgentClient(
      supportsListSessions: false,
      supportsLoadSession: false,
    );
    final piClient = FakeAgentClient();
    final codex = ChatController(
      client: codexClient,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    final pi = ChatController(
      client: piClient,
      cwd: '/workspace/app',
      agentName: 'pi ACP',
    );
    AgentSession? selectedSession;
    addTearDown(codex.dispose);
    addTearDown(pi.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: codex,
          agentName: 'Codex',
          sessionControllers: [codex, pi],
          onSelectSession: (session) => selectedSession = session,
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();

    expect(find.text('Resume this project conversation'), findsWidgets);

    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();

    expect(find.text('Review Session Workspace'), findsNothing);
    expect(selectedSession?.agentName, 'pi ACP');
    expect(selectedSession?.id, 'session-a');
    expect(selectedSession?.cwd, '/workspace/project-a');
    expect(codexClient.lastResumeCwd, isNull);
    expect(piClient.lastResumeCwd, isNull);
  });

  testWidgets('AppShell direct resume requires workspace confirmation', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(controller: controller, agentName: 'Codex'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();

    expect(find.text('Review Session Workspace'), findsOneWidget);
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'Cancel')).height,
      greaterThanOrEqualTo(40),
    );
    expect(
      tester
          .getSize(find.widgetWithText(FilledButton, 'Resume Session'))
          .height,
      greaterThanOrEqualTo(40),
    );
    expect(client.lastResumeCwd, isNull);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.lastResumeCwd, isNull);

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await tester.pumpAndSettle();

    expect(client.lastResumeCwd, '/workspace/project-a');
  });

  testWidgets('AppShell direct resume restores every shared catalog alias', (
    tester,
  ) async {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
      sessionCatalogSourceKey: 'shared-catalog',
    );
    final pi = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'pi ACP',
      sessionCatalogSourceKey: 'shared-catalog',
    );
    addTearDown(codex.dispose);
    addTearDown(pi.dispose);
    for (final controller in <ChatController>[codex, pi]) {
      controller.mergeSessionIndex(<AgentSession>[
        AgentSession(
          id: 'session-a',
          cwd: '/workspace/project-a',
          createdAt: DateTime(2026, 8, 9),
          title: 'Resume this project conversation',
          agentName: controller.agentName,
          archived: true,
          unread: true,
        ),
      ]);
    }

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: codex,
          agentName: 'Codex',
          sessionControllers: <ChatController>[codex, pi],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    final piConversation = find.descendant(
      of: find.byKey(const ValueKey('resume-conversation-list')),
      matching: find.textContaining('pi ACP ·'),
    );
    expect(piConversation, findsOneWidget);
    await tester.tap(piConversation);
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await _pumpUntil(
      tester,
      () =>
          pi.currentSession?.id == 'session-a' && !pi.isSessionOperationRunning,
    );

    expect(codex.sessions.single.archived, isFalse);
    expect(pi.sessions.single.archived, isFalse);
    expect(codex.sessions.single.unread, isFalse);
    expect(pi.sessions.single.unread, isFalse);
  });

  testWidgets('AppShell rejects changed roots for the active session id', (
    tester,
  ) async {
    final client = _CountingResumeClient();
    final controller = ChatController(client: client, cwd: '/workspace/app');
    addTearDown(controller.dispose);
    await tester.runAsync(
      () => controller.resumeSession('session-a', cwd: '/workspace/current'),
    );
    expect(client.resumeCalls, 1);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(controller: controller, agentName: 'Codex'),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Resume'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Load'));
    await _pumpUntil(
      tester,
      () => find.textContaining('different workspace').evaluate().isNotEmpty,
    );

    expect(find.text('Review Session Workspace'), findsNothing);
    expect(find.textContaining('different workspace'), findsOneWidget);
    expect(client.resumeCalls, 1);
    expect(client.lastResumeCwd, '/workspace/current');
    expect(controller.currentSession?.cwd, '/workspace/current');
  });

  testWidgets(
    'AppShell rejects changed roots for an inactive snapshot session id',
    (tester) async {
      final client = _CountingResumeClient();
      final controller = ChatController(
        client: client,
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.resumeSession(
          'session-a',
          cwd: '/workspace/current',
          additionalDirectories: const <String>['/workspace/current-extra'],
        ),
      );
      await tester.runAsync(
        () => controller.resumeSession('session-b', cwd: '/workspace/active-b'),
      );
      expect(client.resumeCalls, 2);
      expect(controller.debugInactiveSnapshotIds, contains('session-a'));

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: AppShell(controller: controller, agentName: 'Codex'),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Resume'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Load'));
      await _pumpUntil(
        tester,
        () => find.textContaining('different workspace').evaluate().isNotEmpty,
      );

      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.textContaining('different workspace'), findsOneWidget);
      expect(client.resumeCalls, 2);
      expect(controller.currentSession?.id, 'session-b');
      expect(controller.currentSession?.cwd, '/workspace/active-b');
      expect(controller.debugInactiveSnapshotIds, contains('session-a'));
      expect(client.lastResumeCwd, '/workspace/active-b');

      await tester.runAsync(
        () => controller.resumeSession(
          'session-a',
          cwd: '/workspace/current',
          additionalDirectories: const <String>['/workspace/current-extra'],
        ),
      );
      expect(controller.currentSession?.id, 'session-a');
      expect(client.resumeCalls, 2);
      expect(client.lastResumeCwd, '/workspace/active-b');
    },
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  int attempts = 20,
}) async {
  for (var attempt = 0; attempt < attempts; attempt += 1) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
  fail('Condition was not met before timeout.');
}

class _CountingResumeClient extends FakeAgentClient {
  int resumeCalls = 0;

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    resumeCalls += 1;
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

class _RecordingTerminalBackend implements PtySessionBackend {
  final List<String> createdSessionIds = <String>[];
  final List<String> closedSessionIds = <String>[];
  int _nextSessionId = 0;

  @override
  int ping() => 1;

  @override
  String createSession(String sessionConfigJson) {
    final sessionId = 'terminal-session-${++_nextSessionId}';
    createdSessionIds.add(sessionId);
    return sessionId;
  }

  @override
  void closeSession(String sessionId) {
    closedSessionIds.add(sessionId);
  }

  @override
  List<PtyEvent> pollEvents(String sessionId) => const <PtyEvent>[];

  @override
  void resizeSession(
    String sessionId, {
    required int cols,
    required int rows,
    required int pixelWidth,
    required int pixelHeight,
    int cellWidth = 0,
    int cellHeight = 0,
  }) {}

  @override
  void scrollViewport(String sessionId, int deltaLines) {}

  @override
  void scrollViewportTo(String sessionId, int offset) {}

  @override
  String? takeFrameDiffJson(String sessionId) => null;

  @override
  void writeInput(String sessionId, List<int> bytes) {}
}
