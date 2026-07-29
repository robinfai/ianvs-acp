import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/memory/memory_api_client.dart';
import 'package:ianvs_acp/memory/memory_config.dart';
import 'package:ianvs_acp/memory/memory_runtime_status.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/memory_explorer_page.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void _noop() {}

MemoryExplorerActions _emptyMemoryExplorerActions() {
  return MemoryExplorerActions(
    loadMemory: () async => const <MemoryRecord>[],
    loadCandidates: () async => const <MemoryCandidate>[],
    loadChangeRequests: () async => const <MemoryChangeRequest>[],
    loadAudit: () async => const <MemoryAuditEvent>[],
    approveCandidate: (_) async {},
    rejectCandidate: (_) async {},
    approveChangeRequest: (_) async {},
    rejectChangeRequest: (_) async {},
    runMaintenance: () async => const MaintenanceRunResult(
      autoApplied: 0,
      needsReview: 0,
      skipped: 0,
      changeRequests: <MemoryChangeRequest>[],
    ),
    clearData: (_) async => const MemoryClearResult(
      clearedMemory: 0,
      rejectedCandidates: 0,
      rejectedChangeRequests: 0,
    ),
  );
}

void main() {
  test('MemoryAutomationNotice labels automatic cleanup', () {
    const notice = MemoryAutomationNotice(
      sequence: 1,
      maintenanceAutoRejectedCandidates: 1,
      maintenanceAutoRejectedChangeRequests: 2,
    );

    expect(notice.shouldPrompt, isTrue);
    expect(notice.label, '3 memory reviews cleaned');
  });

  test('MemoryAutomationNotice routes review by automatic event type', () {
    expect(
      const MemoryAutomationNotice(
        sequence: 1,
        maintenanceAutoApplied: 1,
      ).initialReviewTab(0),
      MemoryExplorerInitialTab.changeRequests,
    );
    expect(
      const MemoryAutomationNotice(
        sequence: 2,
        maintenanceAutoRejectedChangeRequests: 1,
      ).initialReviewTab(0),
      MemoryExplorerInitialTab.changeRequests,
    );
    expect(
      const MemoryAutomationNotice(
        sequence: 3,
        maintenanceAutoRejectedCandidates: 1,
      ).initialReviewTab(0),
      MemoryExplorerInitialTab.candidates,
    );
    expect(
      const MemoryAutomationNotice(
        sequence: 4,
        approvedCandidates: 1,
      ).initialReviewTab(0),
      MemoryExplorerInitialTab.candidates,
    );
    expect(
      const MemoryAutomationNotice(sequence: 5).initialReviewTab(1),
      MemoryExplorerInitialTab.candidates,
    );
  });

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

  testWidgets('AppShell renders memory status in the bottom bar', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          memoryStatus: MemoryRuntimeStatus.running,
        ),
      ),
    );

    expect(find.text('memory on'), findsOneWidget);
  });

  testWidgets('AppShell prompts review when memory pending count increases', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    Widget app(int pendingCount) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryPendingCount: pendingCount,
          memoryExplorerActions: _emptyMemoryExplorerActions(),
        ),
      );
    }

    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(3));
    await tester.pumpAndSettle();

    expect(find.text('3 memory reviews pending'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
  });

  testWidgets('pending review prompt opens memory candidates directly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    final actions = MemoryExplorerActions(
      loadMemory: () async => const <MemoryRecord>[],
      loadCandidates: () async => const [
        MemoryCandidate(
          id: 'cand_review',
          kind: 'user_preference',
          scope: 'global',
          text: '用户希望被称呼为 Rodriguez。',
          confidence: 0.82,
          source: 'extractor',
          status: 'pending',
        ),
      ],
      loadChangeRequests: () async => const <MemoryChangeRequest>[],
      loadAudit: () async => const <MemoryAuditEvent>[],
      approveCandidate: (_) async {},
      rejectCandidate: (_) async {},
      approveChangeRequest: (_) async {},
      rejectChangeRequest: (_) async {},
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 0,
        needsReview: 0,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
      clearData: (_) async => const MemoryClearResult(
        clearedMemory: 0,
        rejectedCandidates: 0,
        rejectedChangeRequests: 0,
      ),
    );

    Widget app(int pendingCount) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryPendingCount: pendingCount,
          memoryExplorerActions: actions,
        ),
      );
    }

    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(1));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
  });

  testWidgets('pending review prompt opens change requests when present', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    final actions = MemoryExplorerActions(
      loadMemory: () async => const <MemoryRecord>[],
      loadCandidates: () async => const <MemoryCandidate>[],
      loadChangeRequests: () async => const [
        MemoryChangeRequest(
          id: 'req_pending',
          action: 'update',
          targetMemoryIds: ['mem_pref'],
          targetMemoryText: '用户名字是 Rod。',
          proposedKind: 'user_preference',
          proposedScope: 'global',
          proposedText: '用户希望被称呼为 Rodriguez。',
          reason: 'MCP proposed an update that needs review.',
          confidence: 0.78,
          source: 'mcp',
          status: 'pending',
          createdAt: 1,
        ),
      ],
      loadAudit: () async => const <MemoryAuditEvent>[],
      approveCandidate: (_) async {},
      rejectCandidate: (_) async {},
      approveChangeRequest: (_) async {},
      rejectChangeRequest: (_) async {},
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 0,
        needsReview: 0,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
      clearData: (_) async => const MemoryClearResult(
        clearedMemory: 0,
        rejectedCandidates: 0,
        rejectedChangeRequests: 0,
      ),
    );

    Widget app({
      required int pendingCount,
      required int pendingChangeRequestCount,
    }) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryPendingCount: pendingCount,
          memoryPendingChangeRequestCount: pendingChangeRequestCount,
          memoryExplorerActions: actions,
        ),
      );
    }

    await tester.pumpWidget(app(pendingCount: 0, pendingChangeRequestCount: 0));
    await tester.pumpWidget(app(pendingCount: 1, pendingChangeRequestCount: 1));
    await tester.pumpAndSettle();

    expect(find.text('1 memory reviews pending'), findsOneWidget);

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
  });

  testWidgets('AppShell respects disabled memory review prompts', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    Widget app(int pendingCount) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(
            enabled: true,
            review: MemoryReviewConfig(autoOpen: 'never'),
          ),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryPendingCount: pendingCount,
          memoryExplorerActions: _emptyMemoryExplorerActions(),
        ),
      );
    }

    await tester.pumpWidget(app(0));
    await tester.pumpWidget(app(2));
    await tester.pump();

    expect(find.text('2 memory reviews pending'), findsNothing);
  });

  testWidgets('AppShell prompts after automatic memory processing', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    Widget app(MemoryAutomationNotice? notice) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryAutomationNotice: notice,
          memoryExplorerActions: _emptyMemoryExplorerActions(),
        ),
      );
    }

    await tester.pumpWidget(app(null));
    await tester.pumpWidget(
      app(
        const MemoryAutomationNotice(
          sequence: 1,
          approvedCandidates: 1,
          autoAppliedChangeRequests: 1,
          maintenanceNeedsReview: 1,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('2 memory changes auto applied · 1 needs review'),
      findsOneWidget,
    );

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('Memory'), findsOneWidget);
  });

  testWidgets('maintenance review prompt opens change requests directly', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    final actions = MemoryExplorerActions(
      loadMemory: () async => const <MemoryRecord>[],
      loadCandidates: () async => const <MemoryCandidate>[],
      loadChangeRequests: () async => const [
        MemoryChangeRequest(
          id: 'req_review',
          action: 'merge',
          targetMemoryIds: ['mem_a', 'mem_b'],
          targetMemoryText: '用户名字是 Rodriguez。',
          proposedKind: 'user_preference',
          proposedScope: 'global',
          proposedText: '用户希望被称呼为 Rodriguez。',
          reason: 'Two name memories should be merged.',
          confidence: 0.82,
          source: 'maintenance',
          status: 'pending',
          createdAt: 1,
        ),
      ],
      loadAudit: () async => const <MemoryAuditEvent>[],
      approveCandidate: (_) async {},
      rejectCandidate: (_) async {},
      approveChangeRequest: (_) async {},
      rejectChangeRequest: (_) async {},
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 0,
        needsReview: 1,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
      clearData: (_) async => const MemoryClearResult(
        clearedMemory: 0,
        rejectedCandidates: 0,
        rejectedChangeRequests: 0,
      ),
    );

    Widget app(MemoryAutomationNotice? notice) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryAutomationNotice: notice,
          memoryExplorerActions: actions,
        ),
      );
    }

    await tester.pumpWidget(app(null));
    await tester.pumpWidget(
      app(const MemoryAutomationNotice(sequence: 1, maintenanceNeedsReview: 1)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
  });

  testWidgets('auto-applied change request prompt opens reviewed requests', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    final actions = MemoryExplorerActions(
      loadMemory: () async => const <MemoryRecord>[],
      loadCandidates: () async => const <MemoryCandidate>[],
      loadChangeRequests: () async => const [
        MemoryChangeRequest(
          id: 'req_auto',
          action: 'supersede',
          targetMemoryIds: ['mem_old'],
          targetMemoryText: '用户名字是 Rod。',
          proposedKind: 'user_preference',
          proposedScope: 'global',
          proposedText: '用户希望被称呼为 Rodriguez。',
          reason: 'High-confidence correction was applied automatically.',
          confidence: 0.94,
          source: 'maintenance',
          status: 'approved',
          createdAt: 1,
          reviewedAt: 2,
        ),
      ],
      loadAudit: () async => const <MemoryAuditEvent>[],
      approveCandidate: (_) async {},
      rejectCandidate: (_) async {},
      approveChangeRequest: (_) async {},
      rejectChangeRequest: (_) async {},
      runMaintenance: () async => const MaintenanceRunResult(
        autoApplied: 1,
        needsReview: 0,
        skipped: 0,
        changeRequests: <MemoryChangeRequest>[],
      ),
      clearData: (_) async => const MemoryClearResult(
        clearedMemory: 0,
        rejectedCandidates: 0,
        rejectedChangeRequests: 0,
      ),
    );

    Widget app(MemoryAutomationNotice? notice) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(enabled: true),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryAutomationNotice: notice,
          memoryExplorerActions: actions,
        ),
      );
    }

    await tester.pumpWidget(app(null));
    await tester.pumpWidget(
      app(const MemoryAutomationNotice(sequence: 1, maintenanceAutoApplied: 1)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Review'));
    await tester.pumpAndSettle();

    expect(find.text('用户希望被称呼为 Rodriguez。'), findsOneWidget);
    expect(
      find.text('supersede · 94% · approved · maintenance'),
      findsOneWidget,
    );
  });

  testWidgets(
    'automation prompt opens pending candidates when candidate review remains',
    (tester) async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/work',
      );
      addTearDown(controller.dispose);

      final actions = MemoryExplorerActions(
        loadMemory: () async => const <MemoryRecord>[],
        loadCandidates: () async => const [
          MemoryCandidate(
            id: 'cand_left_for_review',
            kind: 'project_rule',
            scope: 'repo',
            text: '本项目的验证暗号可能是蓝色灯塔-43130。',
            confidence: 0.74,
            source: 'extractor',
            status: 'pending',
          ),
        ],
        loadChangeRequests: () async => const <MemoryChangeRequest>[],
        loadAudit: () async => const <MemoryAuditEvent>[],
        approveCandidate: (_) async {},
        rejectCandidate: (_) async {},
        approveChangeRequest: (_) async {},
        rejectChangeRequest: (_) async {},
        runMaintenance: () async => const MaintenanceRunResult(
          autoApplied: 0,
          needsReview: 0,
          skipped: 0,
          changeRequests: <MemoryChangeRequest>[],
        ),
        clearData: (_) async => const MemoryClearResult(
          clearedMemory: 0,
          rejectedCandidates: 0,
          rejectedChangeRequests: 0,
        ),
      );

      Widget app({required int pendingCount, MemoryAutomationNotice? notice}) {
        return MaterialApp(
          home: AppShell(
            controller: controller,
            memory: const MemoryConfig(enabled: true),
            memoryStatus: MemoryRuntimeStatus.running,
            memoryPendingCount: pendingCount,
            memoryAutomationNotice: notice,
            memoryExplorerActions: actions,
          ),
        );
      }

      await tester.pumpWidget(app(pendingCount: 0));
      await tester.pumpWidget(
        app(
          pendingCount: 0,
          notice: const MemoryAutomationNotice(
            sequence: 1,
            approvedCandidates: 1,
            pendingCandidateReviews: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('1 memory change auto applied · 1 needs review'),
        findsOneWidget,
      );

      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();

      expect(find.text('本项目的验证暗号可能是蓝色灯塔-43130。'), findsOneWidget);
    },
  );

  testWidgets('AppShell suppresses automatic memory prompt when disabled', (
    tester,
  ) async {
    final controller = ChatController(client: FakeAgentClient(), cwd: '/work');
    addTearDown(controller.dispose);

    Widget app(MemoryAutomationNotice? notice) {
      return MaterialApp(
        home: AppShell(
          controller: controller,
          memory: const MemoryConfig(
            enabled: true,
            review: MemoryReviewConfig(autoOpen: 'never'),
          ),
          memoryStatus: MemoryRuntimeStatus.running,
          memoryAutomationNotice: notice,
          memoryExplorerActions: _emptyMemoryExplorerActions(),
        ),
      );
    }

    await tester.pumpWidget(app(null));
    await tester.pumpWidget(
      app(const MemoryAutomationNotice(sequence: 1, approvedCandidates: 1)),
    );
    await tester.pump();

    expect(find.text('1 memory change auto applied'), findsNothing);
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
