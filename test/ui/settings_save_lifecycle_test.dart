import 'package:ianvs_design/ianvs_design.dart';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_client.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';
import 'package:ianvs_agent_chat/models/prompt_attachment.dart';

void main() {
  testWidgets(
    'settings receive global providers without the active Agent override',
    (tester) async {
      const globalReview = AcpPermissionReviewAgentConfig(
        enabled: true,
        mcpServerName: 'global-reviewer',
      );
      const agentReview = AcpPermissionReviewAgentConfig(
        enabled: true,
        agentServerName: 'Agent Reviewer',
      );
      const activeAgent = AgentServerConfig(
        name: 'Primary',
        type: 'custom',
        command: 'primary-agent',
        permissionReviewAgent: agentReview,
      );
      const config = AcpClientConfig(
        activeAgentServer: activeAgent,
        agentServers: [activeAgent],
        clientProviders: AcpClientProviderConfig(
          filesystem: AcpFilesystemProviderConfig(readTextFile: true),
          terminal: AcpTerminalProviderConfig(enabled: true),
          permissions: AcpPermissionProviderConfig(reviewAgent: globalReview),
        ),
        configPath: '/tmp/ianvs-settings-lifecycle.json',
        defaultAgentServerName: 'Primary',
      );

      await _pumpOwnedApp(tester, config: config);

      final shell = tester.widget<AppShell>(find.byType(AppShell));
      expect(
        shell.clientProviders.permissions.reviewAgent.agentServerName,
        'Agent Reviewer',
      );
      expect(shell.settingsClientProviders, same(config.clientProviders));
      expect(
        shell.settingsClientProviders!.permissions.reviewAgent.mcpServerName,
        'global-reviewer',
      );
      expect(shell.settingsClientProviders!.filesystem.readTextFile, isTrue);
      expect(shell.settingsClientProviders!.terminal.enabled, isTrue);
      await _disposeOwnedApp(tester);
    },
  );

  testWidgets(
    'save is rejected while background controllers stream and restore',
    (tester) async {
      const alpha = AgentServerConfig(
        name: 'Alpha',
        type: 'custom',
        command: 'alpha-agent',
      );
      const beta = AgentServerConfig(
        name: 'Beta',
        type: 'custom',
        command: 'beta-agent',
      );
      const config = AcpClientConfig(
        activeAgentServer: alpha,
        agentServers: [alpha, beta],
        configPath: '/tmp/ianvs-settings-lifecycle.json',
        defaultAgentServerName: 'Alpha',
      );
      final alphaClient = _ControlledLifecycleClient(holdPrompt: true);
      final betaClient = _ControlledLifecycleClient(holdRestore: true);
      var writerCalls = 0;

      await _pumpOwnedApp(
        tester,
        config: config,
        createAgentClient: (runtime) => switch (runtime.agentName) {
          'Alpha' => alphaClient,
          'Beta' => betaClient,
          _ => throw StateError('Unexpected Agent ${runtime.agentName}'),
        },
        writeConfig: (candidate) async {
          writerCalls += 1;
          return candidate;
        },
      );
      final initialShell = tester.widget<AppShell>(find.byType(AppShell));
      final alphaController = initialShell.sessionControllers.singleWhere(
        (controller) => controller.agentName == 'Alpha',
      );
      final betaController = initialShell.sessionControllers.singleWhere(
        (controller) => controller.agentName == 'Beta',
      );

      expect(await alphaController.newSession(), isTrue);
      expect(
        await alphaController.sendPrompt('Keep streaming'),
        ChatPromptSubmissionResult.submitted,
      );
      await alphaClient.promptStarted.future;
      final resume = betaController.resumeSession(
        'background-resume',
        cwd: '/workspace/beta',
      );
      await _pumpUntil(tester, () => betaClient.restoreStarted.isCompleted);
      await tester.pump();

      final busyShell = tester.widget<AppShell>(find.byType(AppShell));
      expect(alphaController.isStreaming, isTrue);
      expect(betaController.isSessionOperationRunning, isTrue);
      expect(busyShell.settingsRuntimeBusy!.value, isTrue);
      await expectLater(
        busyShell.onSaveConfig!(config),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('会话仍在运行或切换'),
          ),
        ),
      );
      expect(writerCalls, 0);

      final promptFinished = alphaClient.finishPrompt();
      await _pumpUntil(tester, () => !alphaController.isStreaming);
      await promptFinished;
      expect(betaController.isSessionOperationRunning, isTrue);
      await expectLater(
        busyShell.onSaveConfig!(config),
        throwsA(isA<StateError>()),
      );
      expect(writerCalls, 0);

      betaClient.releaseRestore();
      await resume;
      await _pumpUntil(
        tester,
        () =>
            !alphaController.isStreaming &&
            !betaController.isSessionOperationRunning,
      );
      await _disposeOwnedApp(tester);
    },
  );

  testWidgets(
    'a late resume defers committed configuration until every controller is idle',
    (tester) async {
      final oldClient = _ControlledLifecycleClient(holdRestore: true);
      final writerStarted = Completer<AcpClientConfig>();
      final writerGate = Completer<AcpClientConfig>();
      const oldAgent = AgentServerConfig(
        name: 'Primary',
        type: 'custom',
        command: 'old-agent',
      );
      const oldConfig = AcpClientConfig(
        activeAgentServer: oldAgent,
        agentServers: [oldAgent],
        configPath: '/tmp/ianvs-settings-lifecycle.json',
        defaultAgentServerName: 'Primary',
      );
      const newAgent = AgentServerConfig(
        name: 'Primary',
        type: 'custom',
        command: 'new-agent',
      );
      const committedConfig = AcpClientConfig(
        activeAgentServer: newAgent,
        agentServers: [newAgent],
        configPath: '/tmp/ianvs-settings-lifecycle.json',
        defaultAgentServerName: 'Primary',
      );

      await _pumpOwnedApp(
        tester,
        config: oldConfig,
        createAgentClient: (runtime) =>
            runtime.activeAgentServer?.command == 'old-agent'
            ? oldClient
            : FakeAgentClient(supportsListSessions: false),
        writeConfig: (candidate) {
          if (!writerStarted.isCompleted) writerStarted.complete(candidate);
          return writerGate.future;
        },
      );
      final oldShell = tester.widget<AppShell>(find.byType(AppShell));
      final oldController = oldShell.controller;

      final save = oldShell.onSaveConfig!(committedConfig);
      expect(await writerStarted.future, same(committedConfig));
      final resume = oldController.resumeSession(
        'late-resume',
        cwd: '/workspace/late',
      );
      await _pumpUntil(tester, () => oldClient.restoreStarted.isCompleted);
      await tester.pump();
      expect(oldController.isSessionOperationRunning, isTrue);

      writerGate.complete(committedConfig);
      expect(await save, same(committedConfig));
      await tester.pump();

      var shell = tester.widget<AppShell>(find.byType(AppShell));
      expect(shell.controller, same(oldController));
      expect(shell.agentServers.single.command, 'old-agent');
      expect(find.textContaining('配置已保存，将在当前操作结束后应用。'), findsOneWidget);

      oldClient.releaseRestore();
      await resume;
      await _pumpUntil(
        tester,
        () => !identical(
          tester.widget<AppShell>(find.byType(AppShell)).controller,
          oldController,
        ),
      );

      shell = tester.widget<AppShell>(find.byType(AppShell));
      expect(shell.controller, isNot(same(oldController)));
      expect(shell.agentServers.single.command, 'new-agent');
      expect(shell.settingsRuntimeBusy!.value, isFalse);
      await _disposeOwnedApp(tester);
    },
  );

  testWidgets('writer failure keeps the controller and settings draft', (
    tester,
  ) async {
    const agent = AgentServerConfig(
      name: 'Primary',
      type: 'custom',
      command: 'primary-agent',
    );
    const config = AcpClientConfig(
      activeAgentServer: agent,
      agentServers: [agent],
      configPath: '/tmp/ianvs-settings-lifecycle.json',
      defaultAgentServerName: 'Primary',
    );
    AcpClientConfig? attemptedConfig;

    await _pumpOwnedApp(
      tester,
      config: config,
      size: const Size(1400, 900),
      writeConfig: (candidate) async {
        attemptedConfig = candidate;
        throw StateError('injected writer failure');
      },
    );
    final originalController = tester
        .widget<AppShell>(find.byType(AppShell))
        .controller;

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('本地存储'));
    await tester.pumpAndSettle();
    final storageField = find.descendant(
      of: find.byKey(const Key('storage-max-size-gb-field')),
      matching: find.byType(TextField),
    );
    expect(storageField, findsOneWidget);
    await tester.enterText(storageField, '81');
    await tester.pump();
    expect(
      tester
          .widget<IanvsButton>(find.byKey(const Key('settings-save')))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();

    expect(attemptedConfig!.storage.maxSizeGb, 81);
    expect(tester.widget<TextField>(storageField).controller!.text, '81');
    expect(find.text('有未保存的更改'), findsOneWidget);
    expect(find.textContaining('injected writer failure'), findsOneWidget);
    final shellBehindSettings = tester.widget<AppShell>(
      find.byType(AppShell, skipOffstage: false),
    );
    expect(shellBehindSettings.controller, same(originalController));
    expect(shellBehindSettings.storage.maxSizeGb, 50);
    await _disposeOwnedApp(tester);
  });
}

Future<void> _pumpOwnedApp(
  WidgetTester tester, {
  required AcpClientConfig config,
  AcpAgentClientFactory? createAgentClient,
  AcpConfigWriter? writeConfig,
  Size? size,
}) async {
  if (size != null) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }
  await tester.pumpWidget(
    AcpClientApp(
      config: config,
      workspaceStateStore: WorkspaceSidebarStateStore(path: null),
      discoverAgentServers: (_) => const <AgentServerConfig>[],
      createAgentClient:
          createAgentClient ??
          (_) => FakeAgentClient(supportsListSessions: false),
      writeConfig: writeConfig,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _disposeOwnedApp(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(
    ChatController.defaultCleanupTimeout + const Duration(milliseconds: 100),
  );
  await tester.pump();
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met within $timeout.');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
}

class _ControlledLifecycleClient extends FakeAgentClient {
  _ControlledLifecycleClient({
    this.holdPrompt = false,
    this.holdRestore = false,
  }) : _promptEvents = holdPrompt ? StreamController<AgentEvent>() : null,
       super(supportsListSessions: false);

  final bool holdPrompt;
  final bool holdRestore;
  final Completer<void> promptStarted = Completer<void>();
  final Completer<void> restoreStarted = Completer<void>();
  final Completer<void> _restoreGate = Completer<void>();
  final StreamController<AgentEvent>? _promptEvents;
  bool _disposed = false;

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    if (!promptStarted.isCompleted) promptStarted.complete();
    if (holdPrompt) return _promptEvents!.stream;
    return super.sendPrompt(
      sessionId: sessionId,
      prompt: prompt,
      attachments: attachments,
    );
  }

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    if (!restoreStarted.isCompleted) restoreStarted.complete();
    if (holdRestore) await _restoreGate.future;
    return super.restoreSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
      replayHistory: replayHistory,
      onEvent: onEvent,
    );
  }

  void releaseRestore() {
    if (!_restoreGate.isCompleted) _restoreGate.complete();
  }

  Future<void> finishPrompt() async {
    final promptEvents = _promptEvents;
    if (promptEvents == null || promptEvents.isClosed) return;
    promptEvents.add(
      const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
    );
    await promptEvents.close();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    releaseRestore();
    final promptEvents = _promptEvents;
    if (promptEvents != null && !promptEvents.isClosed) {
      await promptEvents.close();
    }
    await super.dispose();
  }
}
