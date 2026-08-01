import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/memory/memory_runtime_status.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/components/workspace_inspector.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

import '../support/memory_task_repository.dart';

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

    expect(sidebarRect.width, moreOrLessEquals(312));
    expect(promptRect.left, greaterThanOrEqualTo(sidebarRect.right));
    expect(promptRect.right, lessThan(inspectorRect.left));
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

  testWidgets('AppShell renders memory status in inspector diagnostics', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          memoryStatus: MemoryRuntimeStatus.running,
        ),
      ),
    );

    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();

    expect(find.text('On'), findsOneWidget);
  });

  testWidgets('AppShell keeps one visible New Session entry on desktop', (
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
    expect(find.text('New Session'), findsOneWidget);
  });

  testWidgets('AppShell keeps sidebar mode labels on one line', (tester) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    final taskInboxController = TaskInboxController(
      repository: _EmptyTaskStore(),
    );
    addTearDown(taskInboxController.dispose);
    await taskInboxController.load();

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          taskInboxController: taskInboxController,
          agentName: 'Codex',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    final workspacesLabelRects = find.text('Workspaces').evaluate().map((
      element,
    ) {
      final box = element.renderObject! as RenderBox;
      return box.localToGlobal(Offset.zero) & box.size;
    }).toList();
    final modeLabelRect = workspacesLabelRects.reduce(
      (currentTop, rect) => rect.top < currentTop.top ? rect : currentTop,
    );

    expect(modeLabelRect.height, lessThanOrEqualTo(18));
  });

  testWidgets('AppShell stretches active sidebar mode fill to switch height', (
    tester,
  ) async {
    final client = FakeAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    final taskInboxController = TaskInboxController(
      repository: _EmptyTaskStore(),
    );
    addTearDown(taskInboxController.dispose);
    await taskInboxController.load();

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          taskInboxController: taskInboxController,
          agentName: 'Codex',
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(milliseconds: 100));

    final activeFillRects = find
        .byWidgetPredicate(
          (widget) =>
              widget is Material && widget.color == AppColors.surfaceSelected,
        )
        .evaluate()
        .map((element) {
          final box = element.renderObject! as RenderBox;
          return box.localToGlobal(Offset.zero) & box.size;
        })
        .toList();
    final modeFillRect = activeFillRects.reduce(
      (currentTop, rect) => rect.top < currentTop.top ? rect : currentTop,
    );

    expect(modeFillRect.height, 30);
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

    expect(
      find.textContaining('pi ACP - Resume this project conversation'),
      findsWidgets,
    );

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

class _EmptyTaskStore extends MemoryTaskRepository {}

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
