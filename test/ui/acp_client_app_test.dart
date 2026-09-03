import 'dart:async';
import 'dart:io';

import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_client.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_permission_reviewer.dart'
    show AcpAgentPermissionReviewer;
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/startup/deep_link_request.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';
import 'package:ianvs_acp/ui/components/bounded_image_preview.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/image_decode_budget.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

void main() {
  Future<void> pumpWithWindowSize(
    WidgetTester tester,
    Widget widget,
    Size size,
  ) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(widget);
    await tester.pumpAndSettle();
  }

  Future<void> sendDeepLink(WidgetTester tester, String link) async {
    const channel = MethodChannel('ianvs_acp/deep_links');
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('openDeepLink', link),
      ),
      null,
    );
  }

  Future<DeepLinkWorkspaceValidation> validateDeepLinkWorkspaceSync(
    String? value,
  ) async {
    final syntax = validateDeepLinkWorkspaceSyntax(value);
    if (syntax.errors.isNotEmpty || syntax.path == null) return syntax;
    final directory = Directory(syntax.path!);
    if (!directory.existsSync()) {
      return DeepLinkWorkspaceValidation(
        path: syntax.path,
        errors: const <String>['Workspace does not exist.'],
      );
    }
    try {
      return DeepLinkWorkspaceValidation(
        path: directory.resolveSymbolicLinksSync(),
        errors: const <String>[],
      );
    } on FileSystemException {
      return DeepLinkWorkspaceValidation(
        path: syntax.path,
        errors: const <String>['Workspace could not be resolved.'],
      );
    }
  }

  testWidgets('AcpClientApp validates and forwards the same input budget', (
    tester,
  ) async {
    const budget = AcpInputBudget(
      maxMarkdownSyntaxTokens: 3,
      maxMetadataPreviewChars: 7,
      maxMetadataPreviewBytes: 9,
    );
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AcpClientApp(
        controller: controller,
        inputBudget: budget,
        autoLoadWorkspaceSessions: false,
      ),
    );
    await tester.pump();

    final shell = tester.widget<AppShell>(find.byType(AppShell));
    expect(identical(shell.inputBudget, budget), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      AcpClientApp(
        controller: controller,
        inputBudget: const AcpInputBudget(maxMarkdownSyntaxTokens: 0),
        autoLoadWorkspaceSessions: false,
      ),
    );
    expect(tester.takeException(), isArgumentError);
  });

  testWidgets('AcpClientApp owns and forwards one image decode budget chain', (
    tester,
  ) async {
    const budget = AcpInputBudget();
    final ledger = AcpImageDecodeBudgetLedger(budget: budget);
    const decoder = DartUiBoundedImageDecoder();
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AcpClientApp(
        controller: controller,
        inputBudget: budget,
        imageDecodeLedger: ledger,
        boundedImageDecoder: decoder,
        autoLoadWorkspaceSessions: false,
      ),
    );
    await tester.pump();

    final shell = tester.widget<AppShell>(find.byType(AppShell));
    expect(identical(shell.imageDecodeLedger, ledger), isTrue);
    expect(identical(shell.boundedImageDecoder, decoder), isTrue);
  });

  testWidgets('AcpClientApp keeps one default image ledger across rebuilds', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    final replacementController = ChatController(
      client: FakeAgentClient(),
      cwd: '/replacement-workspace',
    );
    addTearDown(controller.dispose);
    addTearDown(replacementController.dispose);

    Widget app(ChatController activeController) => AcpClientApp(
      controller: activeController,
      autoLoadWorkspaceSessions: false,
    );

    await tester.pumpWidget(app(controller));
    await tester.pump();
    final first = tester.widget<AppShell>(find.byType(AppShell));
    final ledger = first.imageDecodeLedger;
    final decoder = first.boundedImageDecoder;
    expect(ledger, isNotNull);

    await tester.pumpWidget(app(replacementController));
    await tester.pump();
    final second = tester.widget<AppShell>(find.byType(AppShell));
    expect(identical(second.imageDecodeLedger, ledger), isTrue);
    expect(identical(second.boundedImageDecoder, decoder), isTrue);
  });

  testWidgets('AcpClientApp prompts to add discovered agents on startup', (
    tester,
  ) async {
    final writtenServers = <AgentServerConfig>[];

    await tester.pumpWidget(
      AcpClientApp(
        config: const AcpClientConfig(configPath: '/tmp/ianvs-acp.json'),
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) async => const [
          AgentServerConfig(
            name: 'Codex',
            type: 'custom',
            command: '/usr/local/bin/npx',
            args: ['@zed-industries/codex-acp'],
          ),
        ],
        writeDiscoveredAgentServers: (config, servers) async {
          writtenServers.addAll(servers);
          return AcpClientConfig.fromJson({
            'default_agent_server': 'Codex',
            'agent_servers': {
              for (final server in servers) server.name: server.toJson(),
            },
          }, configPath: config.configPath);
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Discovered ACP Agents'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Codex'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Add Agents'));
    await tester.pumpAndSettle();

    expect(writtenServers.map((server) => server.name), ['Codex']);
    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
  });

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

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsWidgets);
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('AcpClientApp starts a session with its template runtime', (
    tester,
  ) async {
    final runtimeConfigs = <AcpClientConfig>[];
    final clients = <FakeAgentClient>[];
    const settings = AcpSessionSettings(
      configOptions: [
        AcpConfigOption(
          id: 'model',
          name: 'Model',
          type: 'select',
          currentValue: 'balanced',
          options: [
            AcpConfigOptionChoice(value: 'balanced', name: 'Balanced'),
            AcpConfigOptionChoice(value: 'fast', name: 'Fast'),
          ],
        ),
        AcpConfigOption(
          id: 'reasoning_effort',
          name: 'Reasoning effort',
          type: 'select',
          currentValue: 'low',
          options: [
            AcpConfigOptionChoice(value: 'low', name: 'Low'),
            AcpConfigOptionChoice(value: 'high', name: 'High'),
          ],
        ),
      ],
    );
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'default_session_template': 'review',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex'},
      },
      'mcp_servers': [
        {'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
        {'name': 'browser', 'command': '/usr/local/bin/browser-mcp'},
      ],
      'additional_directories': ['/workspace/shared'],
      'session_templates': {
        'review': {
          'name': 'Review',
          'version': 2,
          'model': 'fast',
          'reasoning_effort': 'high',
          'mcp_servers': ['repo'],
          'additional_directories': ['/workspace/review'],
        },
      },
    });

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (runtimeConfig) {
          runtimeConfigs.add(runtimeConfig);
          final client = FakeAgentClient(sessionSettings: settings);
          clients.add(client);
          return client;
        },
      ),
    );

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();
    expect(find.text('Review'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    expect(runtimeConfigs.last.mcpServers.map((server) => server.name), [
      'repo',
    ]);
    expect(runtimeConfigs.last.additionalDirectories, [
      '/workspace/shared',
      '/workspace/review',
    ]);
    expect(clients.last.lastConfigId, 'reasoning_effort');
    expect(clients.last.lastConfigValue, 'high');
  });

  testWidgets(
    'assistant-only template changes reuse the authoritative ACP runtime',
    (tester) async {
      final clients = <FakeAgentClient>[];
      final config = AcpClientConfig.fromJson(<String, Object?>{
        'default_agent_server': 'Codex',
        'default_session_template': 'assistant-policy',
        'agent_servers': <String, Object?>{
          'Codex': <String, Object?>{
            'type': 'custom',
            'command': '/usr/local/bin/codex',
          },
        },
        'session_templates': <String, Object?>{
          'assistant-policy': <String, Object?>{
            'name': 'Assistant policy',
            'version': 1,
            'assistant_agent': <String, Object?>{
              'enabled': false,
              'fallback_title_characters': 32,
            },
          },
        },
      });

      await tester.pumpWidget(
        AcpClientApp(
          config: config,
          autoLoadWorkspaceSessions: false,
          createAgentClient: (_) {
            final client = FakeAgentClient();
            clients.add(client);
            return client;
          },
        ),
      );
      expect(clients, hasLength(1));

      await tester.tap(find.byTooltip('New Session'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await tester.pumpAndSettle();

      expect(clients, hasLength(1));
      expect(
        tester.widget<AppShell>(find.byType(AppShell)).sessionControllers,
        hasLength(2),
      );
    },
  );

  testWidgets('startup resume waits for the indexed template runtime', (
    tester,
  ) async {
    final workspace = Directory.current.resolveSymbolicLinksSync();
    final creations =
        <({AcpClientConfig config, _CountingResumeAgentClient client})>[];
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex'},
      },
      'mcp_servers': [
        {'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
        {'name': 'browser', 'command': '/usr/local/bin/browser-mcp'},
      ],
      'session_templates': {
        'review': {
          'name': 'Review',
          'version': 2,
          'mcp_servers': ['repo'],
        },
      },
    });
    final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
      AgentSession(
        id: 'template-resume',
        cwd: workspace,
        createdAt: DateTime(2026),
        agentName: config.activeAgentServer!.persistenceIdentity,
        sessionTemplateId: 'review',
        sessionTemplateVersion: 2,
      ),
    ]);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: store,
        initialResumeSessionId: 'template-resume',
        initialResumeCwd: workspace,
        initialResumeAgentName: 'Codex',
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (runtime) {
          final client = _CountingResumeAgentClient();
          creations.add((config: runtime, client: client));
          return client;
        },
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(
      tester,
      () => creations.any((entry) => entry.client.resumeCalls == 1),
    );

    final resumed = creations.singleWhere(
      (entry) => entry.client.resumeCalls == 1,
    );
    expect(resumed.config.mcpServers.map((server) => server.name), ['repo']);
    final shell = tester.widget<AppShell>(find.byType(AppShell));
    expect(shell.controller.currentSession?.sessionTemplateId, 'review');
    expect(shell.controller.currentSession?.sessionTemplateVersion, 2);

    await _openSidebarSessionMenu(tester, shell.controller);
    await tester.tap(find.text('Fork Locally'));
    await tester.pumpAndSettle();
    expect(resumed.client.lastForkedSessionId, 'template-resume');
    expect(shell.controller.currentSession?.sessionTemplateId, 'review');
    expect(shell.controller.currentSession?.sessionTemplateVersion, 2);

    final forkedSessionId = shell.controller.currentSession!.id;
    await _openSidebarSessionMenu(tester, shell.controller);
    await tester.tap(find.text('Open Side Session'));
    await tester.pumpAndSettle();
    expect(shell.controller.currentSession?.id, isNot(forkedSessionId));
    expect(shell.controller.currentSession?.sessionTemplateId, 'review');
    expect(shell.controller.currentSession?.sessionTemplateVersion, 2);
  });

  testWidgets(
    'startup resume follows a replacement hydration after stale failure',
    (tester) async {
      final workspace = Directory.current.resolveSymbolicLinksSync();
      final indexed = AgentSession(
        id: 'replacement-hydration-session',
        cwd: workspace,
        createdAt: DateTime(2026),
        agentName: 'Codex',
        sessionTemplateId: 'strict',
        sessionTemplateVersion: 1,
      );
      final store = _ReplacingHydrationWorkspaceStateStore(<AgentSession>[
        indexed,
      ]);
      final clients =
          <({AcpClientConfig config, _CountingResumeAgentClient client})>[];
      var factoryKey = 1;
      late StateSetter updateHost;
      final config = AcpClientConfig.fromJson(<String, Object?>{
        'default_agent_server': 'Codex',
        'agent_servers': <String, Object?>{
          'Codex': <String, Object?>{
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
          },
        },
        'mcp_servers': <Object?>[
          <String, Object?>{
            'name': 'repo',
            'command': '/usr/local/bin/repo-mcp',
          },
        ],
        'session_templates': <String, Object?>{
          'strict': <String, Object?>{
            'name': 'Strict',
            'version': 1,
            'mcp_servers': <String>[],
          },
        },
      });

      await tester.pumpWidget(
        StatefulBuilder(
          builder: (context, setState) {
            updateHost = setState;
            return AcpClientApp(
              config: config,
              workspaceStateStore: store,
              initialResumeSessionId: indexed.id,
              initialResumeCwd: workspace,
              initialResumeAgentName: 'Codex',
              agentClientFactoryKey: factoryKey,
              autoLoadWorkspaceSessions: false,
              discoverAgentServers: (_) => const <AgentServerConfig>[],
              createAgentClient: (runtime) {
                final client = _CountingResumeAgentClient();
                clients.add((config: runtime, client: client));
                return client;
              },
            );
          },
        ),
      );
      await tester.pump();
      expect(store.loadCalls, 1);

      updateHost(() => factoryKey = 2);
      await tester.pump();
      await _pumpUntil(tester, () => store.loadCalls == 2);
      store.failFirstLoad();
      await tester.pump();
      expect(clients.every((entry) => entry.client.resumeCalls == 0), isTrue);
      store.completeReplacementLoad();
      await _pumpUntil(
        tester,
        () => clients.any((entry) => entry.client.resumeCalls == 1),
      );

      final resumed = clients.singleWhere(
        (entry) => entry.client.resumeCalls == 1,
      );
      expect(resumed.config.mcpServers, isEmpty);

      expect(
        find.textContaining('Could not load the local session index'),
        findsNothing,
      );
      expect(
        tester
            .widget<AppShell>(find.byType(AppShell))
            .controller
            .currentSession
            ?.id,
        indexed.id,
      );
    },
  );

  testWidgets('template agent drift cannot reroute an indexed session', (
    tester,
  ) async {
    final workspace = Directory.current.resolveSymbolicLinksSync();
    final creations =
        <({AcpClientConfig config, _CountingResumeAgentClient client})>[];
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Agent A',
      'agent_servers': {
        'Agent A': {'type': 'custom', 'command': '/usr/local/bin/agent-a'},
        'Agent B': {'type': 'custom', 'command': '/usr/local/bin/agent-b'},
      },
      'session_templates': {
        'review': {'name': 'Review', 'version': 1, 'agent_server': 'Agent B'},
      },
    });
    final agentA = config.agentServerNamed('Agent A')!;
    final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
      AgentSession(
        id: 'agent-a-template-session',
        cwd: workspace,
        createdAt: DateTime(2026),
        agentName: agentA.persistenceIdentity,
        sessionTemplateId: 'review',
        sessionTemplateVersion: 1,
      ),
    ]);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: store,
        initialResumeSessionId: 'agent-a-template-session',
        initialResumeCwd: workspace,
        initialResumeAgentName: 'Agent A',
        initialResumeSessionTemplateId: 'review',
        initialResumeSessionTemplateVersion: 1,
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (runtime) {
          final client = _CountingResumeAgentClient();
          creations.add((config: runtime, client: client));
          return client;
        },
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(
      tester,
      () => creations.any((entry) => entry.client.resumeCalls == 1),
    );

    final resumed = creations.singleWhere(
      (entry) => entry.client.resumeCalls == 1,
    );
    expect(resumed.config.agentName, 'Agent A');
    expect(
      creations
          .where((entry) => entry.config.agentName == 'Agent B')
          .every((entry) => entry.client.resumeCalls == 0),
      isTrue,
    );
    expect(store.lastSaved.single.agentName, agentA.persistenceIdentity);
  });

  testWidgets('template selection never reuses a base runtime snapshot', (
    tester,
  ) async {
    final workspace = Directory.current.resolveSymbolicLinksSync();
    final creations =
        <({AcpClientConfig config, _CountingResumeAgentClient client})>[];
    final config = AcpClientConfig.fromJson(<String, Object?>{
      'default_agent_server': 'Codex',
      'agent_servers': <String, Object?>{
        'Codex': <String, Object?>{
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
        },
      },
      'mcp_servers': <Object?>[
        <String, Object?>{'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
        <String, Object?>{
          'name': 'browser',
          'command': '/usr/local/bin/browser-mcp',
        },
      ],
      'session_templates': <String, Object?>{
        'review': <String, Object?>{
          'name': 'Review',
          'version': 1,
          'mcp_servers': <String>['repo'],
        },
      },
    });
    final indexed = AgentSession(
      id: 'same-runtime-session',
      cwd: workspace,
      createdAt: DateTime(2026),
      agentName: config.activeAgentServer!.persistenceIdentity,
      sessionTemplateId: 'review',
      sessionTemplateVersion: 1,
    );
    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: _SessionIndexWorkspaceStateStore(<AgentSession>[
          indexed,
        ]),
        initialResumeSessionId: indexed.id,
        initialResumeCwd: workspace,
        initialResumeAgentName: 'Codex',
        initialResumeSessionTemplateId: 'review',
        initialResumeSessionTemplateVersion: 999,
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (runtime) {
          final client = _CountingResumeAgentClient();
          creations.add((config: runtime, client: client));
          return client;
        },
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(
      tester,
      () => creations.any(
        (entry) =>
            entry.config.mcpServers.length == 2 &&
            entry.client.resumeCalls == 1,
      ),
    );

    tester.widget<AppShell>(find.byType(AppShell)).onSelectSession!(indexed);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await _pumpUntil(
      tester,
      () => creations.any(
        (entry) =>
            entry.config.mcpServers.length == 1 &&
            entry.client.resumeCalls == 1,
      ),
    );

    final active = tester.widget<AppShell>(find.byType(AppShell)).controller;
    expect(active.currentSession?.sessionTemplateVersion, 1);
    expect(
      creations
          .singleWhere((entry) => entry.config.mcpServers.length == 2)
          .client
          .resumeCalls,
      1,
    );
  });

  testWidgets('fork lookup never falls back across template runtimes', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'ianvs-template-fork-runtime-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/workspace')..createSync();
    const targetId = 'template-fork-target';
    final config = AcpClientConfig.fromJson(<String, Object?>{
      'default_agent_server': 'Codex',
      'agent_servers': <String, Object?>{
        'Codex': <String, Object?>{
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
        },
      },
      'mcp_servers': <Object?>[
        <String, Object?>{'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
      ],
      'session_templates': <String, Object?>{
        'strict': <String, Object?>{
          'name': 'Strict',
          'version': 1,
          'mcp_servers': <String>[],
        },
      },
    }, configPath: '${temp.path}/settings.json');
    late _TemplateAliasCatalogClient baseClient;
    final templateClients = <_ConcurrentPromptAgentClient>[];

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: _SessionIndexWorkspaceStateStore(
          const <AgentSession>[],
        ),
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (runtime) {
          if (runtime.mcpServers.isNotEmpty) {
            return baseClient = _TemplateAliasCatalogClient(
              sessionId: targetId,
              cwd: workspace.path,
            );
          }
          final client = _ConcurrentPromptAgentClient();
          templateClients.add(client);
          return client;
        },
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(tester, () => baseClient.listCalls > 0);

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Strict'));
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();
    final shell = tester.widget<AppShell>(find.byType(AppShell));
    await shell.controller.sendPrompt('Keep template runtime occupied');
    await tester.pump();
    expect(shell.controller.isStreaming, isTrue);
    expect(shell.controller.client.supportsConcurrentPrompts, isTrue);

    final indexedTarget = AgentSession(
      id: targetId,
      cwd: workspace.path,
      createdAt: DateTime(2026),
      agentName: config.activeAgentServer!.persistenceIdentity,
      sessionTemplateId: 'strict',
      sessionTemplateVersion: 1,
    );
    await shell.onSessionMenuAction!(
      tester.element(find.byType(AppShell)),
      indexedTarget,
      WorkspaceSessionMenuAction.forkLocally,
    );
    await tester.pump();

    expect(baseClient.lastForkedSessionId, isNull);
    expect(templateClients, isNotEmpty);
    expect(
      tester.widget<AppShell>(find.byType(AppShell)).controller,
      same(shell.controller),
    );
    await shell.controller.stop();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'AcpClientApp asks for an agent before starting sessions without config',
    (tester) async {
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: AcpClientConfig(),
          autoLoadWorkspaceSessions: false,
        ),
        const Size(1400, 900),
      );

      await tester.tap(find.byTooltip('New Session'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.text('Add an ACP agent before starting a session.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('AcpClientApp saves edited agent config', (tester) async {
    AcpClientConfig? savedConfig;

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
        }, configPath: '/tmp/ianvs-acp-test-settings.json'),
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        writeConfig: (config) async {
          savedConfig = config;
          return config;
        },
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agent Configuration'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Agent Configuration'), findsOneWidget);

    expect(find.byTooltip('Set Codex as default'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('Set Codex as default')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('Set Codex as default')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byTooltip('Set Kimi Code Dev as default'), findsOneWidget);
    final saveButton = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save'),
    );
    expect(saveButton.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(savedConfig?.defaultAgentServerName, 'Codex');
    expect(find.textContaining('Saved agent configuration'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('New Session'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
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

    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsNothing);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('Claude Code'), findsWidgets);
    expect(find.text('Gemini'), findsOneWidget);
  });

  testWidgets('equivalent runtime config replacement reuses its ACP client', (
    tester,
  ) async {
    var factoryCalls = 0;
    final client = _TrackingHangingAgentClient();
    AcpClientConfig config({required bool includeTemplate}) =>
        AcpClientConfig.fromJson({
          'default_agent_server': 'Codex',
          'agent_servers': {
            'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          },
          if (includeTemplate)
            'session_templates': {
              'review': {'name': 'Review', 'version': 1},
            },
        });
    AcpClientApp app(bool includeTemplate) => AcpClientApp(
      config: config(includeTemplate: includeTemplate),
      autoLoadWorkspaceSessions: false,
      createAgentClient: (_) {
        factoryCalls += 1;
        return client;
      },
    );

    await tester.pumpWidget(app(false));
    expect(factoryCalls, 1);

    await tester.pumpWidget(app(true));
    await tester.pump();

    expect(factoryCalls, 1);
    expect(client.disposed, isFalse);
  });

  testWidgets('session store recipe changes replace the ACP client', (
    tester,
  ) async {
    final clients = <_TrackingHangingAgentClient>[];
    AcpClientConfig config({required String path, required int maxSizeGb}) =>
        AcpClientConfig.fromJson(<String, dynamic>{
          'default_agent_server': 'Codex',
          'agent_servers': <String, Object?>{
            'Codex': <String, Object?>{
              'type': 'custom',
              'command': '/usr/local/bin/codex-acp',
            },
          },
          'storage': <String, Object?>{
            'max_size_gb': maxSizeGb,
            'retention_days': 30,
          },
        }, configPath: path);
    AcpClientApp app({required String path, required int maxSizeGb}) =>
        AcpClientApp(
          config: config(path: path, maxSizeGb: maxSizeGb),
          autoLoadWorkspaceSessions: false,
          createAgentClient: (_) {
            final client = _TrackingHangingAgentClient();
            clients.add(client);
            return client;
          },
        );

    await tester.pumpWidget(
      app(path: '/tmp/ianvs-a/settings.json', maxSizeGb: 50),
    );
    expect(clients, hasLength(1));

    await tester.pumpWidget(
      app(path: '/tmp/ianvs-a/settings.json', maxSizeGb: 51),
    );
    await _pumpUntil(tester, () => clients.length == 2 && clients[0].disposed);
    expect(clients[1].disposed, isFalse);

    await tester.pumpWidget(
      app(path: '/tmp/ianvs-b/settings.json', maxSizeGb: 51),
    );
    await _pumpUntil(tester, () => clients.length == 3 && clients[1].disposed);
    expect(clients[2].disposed, isFalse);
  });

  testWidgets('AcpClientApp shows startup config errors without crashing', (
    tester,
  ) async {
    var retries = 0;
    await tester.pumpWidget(
      AcpClientApp(
        config: const AcpClientConfig(configPath: '/tmp/settings.json'),
        startupError: 'Could not load ACP config: bad json at line 8',
        onRetryStartup: () => retries += 1,
      ),
    );

    expect(find.textContaining('bad json'), findsOneWidget);
    expect(find.text('/tmp/settings.json'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Open config'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
    expect(find.byTooltip('Copy diagnostics'), findsOneWidget);
    expect(find.text('ACP Client'), findsOneWidget);

    final retry = find.widgetWithText(TextButton, 'Retry');
    await tester.ensureVisible(retry);
    tester.widget<TextButton>(retry).onPressed?.call();
    expect(retries, 1);
  });

  testWidgets('startup config failure keeps discovery and writes disabled', (
    tester,
  ) async {
    var discoveryCalled = false;
    await tester.pumpWidget(
      AcpClientApp(
        config: const AcpClientConfig(configPath: '/tmp/broken-settings.json'),
        startupError: 'Could not load ACP config: missing Keychain secret',
        configurationWritable: false,
        discoverAgentServers: (config) {
          discoveryCalled = true;
          return const <AgentServerConfig>[
            AgentServerConfig(
              name: 'Codex',
              type: 'custom',
              command: '/usr/local/bin/codex-acp',
            ),
          ];
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(discoveryCalled, isFalse);
    expect(find.textContaining('missing Keychain secret'), findsOneWidget);
  });

  testWidgets('AcpClientApp replaces owned clients when factory changes', (
    tester,
  ) async {
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final oldClients = <_TrackingHangingAgentClient>[];
    final newClients = <_TrackingHangingAgentClient>[];
    _TrackingHangingAgentClient oldFactory(AcpClientConfig _) {
      final client = _TrackingHangingAgentClient();
      oldClients.add(client);
      return client;
    }

    _TrackingHangingAgentClient newFactory(AcpClientConfig _) {
      final client = _TrackingHangingAgentClient();
      newClients.add(client);
      return client;
    }

    AcpClientApp app(AcpAgentClientFactory factory, Object factoryKey) =>
        AcpClientApp(
          key: const ValueKey('foreground-factory-replacement'),
          config: config,
          autoLoadWorkspaceSessions: false,
          createAgentClient: factory,
          agentClientFactoryKey: factoryKey,
        );

    await tester.pumpWidget(app(oldFactory, 'old'));
    expect(oldClients, isNotEmpty);
    final oldClient = oldClients.first;

    await tester.pumpWidget(app(newFactory, 'new'));
    await _pumpUntil(tester, () => oldClient.disposed && newClients.isNotEmpty);

    expect(oldClient.disposed, isTrue);
    expect(newClients.single.disposed, isFalse);
  });

  testWidgets(
    'config and factory replacement cannot retain the previous client pool',
    (tester) async {
      AcpClientConfig config({required bool summarizeTurns}) {
        return AcpClientConfig.fromJson({
          'default_agent_server': 'Codex',
          'agent_servers': {
            'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          },
          'assistant_agent': <String, Object?>{
            'enabled': false,
            'summarize_turns': summarizeTurns,
          },
        });
      }

      final oldClients = <_TrackingHangingAgentClient>[];
      final newClients = <_TrackingHangingAgentClient>[];
      _TrackingHangingAgentClient oldFactory(AcpClientConfig _) {
        final client = _TrackingHangingAgentClient();
        oldClients.add(client);
        return client;
      }

      _TrackingHangingAgentClient newFactory(AcpClientConfig _) {
        final client = _TrackingHangingAgentClient();
        newClients.add(client);
        return client;
      }

      Widget app({
        required AcpClientConfig config,
        required AcpAgentClientFactory factory,
        required Object factoryKey,
      }) {
        return AcpClientApp(
          key: const ValueKey('combined-config-factory-replacement'),
          config: config,
          autoLoadWorkspaceSessions: false,
          createAgentClient: factory,
          agentClientFactoryKey: factoryKey,
        );
      }

      await tester.pumpWidget(
        app(
          config: config(summarizeTurns: true),
          factory: oldFactory,
          factoryKey: 'old-factory',
        ),
      );
      final oldClient = oldClients.single;

      await tester.pumpWidget(
        app(
          config: config(summarizeTurns: false),
          factory: newFactory,
          factoryKey: 'new-factory',
        ),
      );
      await _pumpUntil(
        tester,
        () => oldClient.disposed && newClients.isNotEmpty,
      );

      expect(oldClient.disposed, isTrue);
      expect(newClients.single.disposed, isFalse);
    },
  );

  testWidgets('AcpClientApp replaces owned client when only secret changes', (
    tester,
  ) async {
    const ref =
        'keychain://ianvs-acp/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    AcpClientConfig config(String value) {
      final server = AgentServerConfig(
        name: 'Codex',
        type: 'custom',
        command: '/usr/local/bin/codex-acp',
        env: <String, String>{'TOKEN': value},
        envRefs: const <String, String>{'TOKEN': ref},
      );
      return AcpClientConfig(
        activeAgentServer: server,
        agentServers: <AgentServerConfig>[server],
        defaultAgentServerName: 'Codex',
      );
    }

    final clients = <_TrackingHangingAgentClient>[];
    _TrackingHangingAgentClient factory(AcpClientConfig _) {
      final client = _TrackingHangingAgentClient();
      clients.add(client);
      return client;
    }

    AcpClientApp app(AcpClientConfig config) => AcpClientApp(
      key: const ValueKey('secret-only-config-change'),
      config: config,
      autoLoadWorkspaceSessions: false,
      createAgentClient: factory,
      agentClientFactoryKey: 'stable-factory',
    );

    await tester.pumpWidget(app(config('first')));
    final oldClient = clients.first;
    await tester.pumpWidget(app(config('second')));
    await _pumpUntil(tester, () => oldClient.disposed && clients.length >= 2);

    expect(oldClient.disposed, isTrue);
    expect(clients.last.disposed, isFalse);
  });

  testWidgets(
    'AcpClientApp replaces owned client when inline reviewer secret changes',
    (tester) async {
      const ref =
          'keychain://ianvs-acp/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      AcpClientConfig config(String value) {
        final reviewer = McpServerConfig(
          raw: <String, dynamic>{
            'name': 'inline-reviewer',
            'command': 'reviewer',
            'env': <Map<String, String>>[
              <String, String>{'name': 'TOKEN', 'value': value},
            ],
          },
          envRefs: const <String, String>{'TOKEN': ref},
        );
        final server = AgentServerConfig(
          name: 'Codex',
          type: 'custom',
          command: '/usr/local/bin/codex-acp',
          permissionReviewAgent: AcpPermissionReviewAgentConfig(
            enabled: true,
            mcpServer: reviewer,
          ),
        );
        return AcpClientConfig(
          activeAgentServer: server,
          agentServers: <AgentServerConfig>[server],
          defaultAgentServerName: 'Codex',
        );
      }

      final clients = <_TrackingHangingAgentClient>[];
      _TrackingHangingAgentClient factory(AcpClientConfig _) {
        final client = _TrackingHangingAgentClient();
        clients.add(client);
        return client;
      }

      AcpClientApp app(AcpClientConfig value) => AcpClientApp(
        key: const ValueKey('inline-reviewer-secret-change'),
        config: value,
        autoLoadWorkspaceSessions: false,
        createAgentClient: factory,
        agentClientFactoryKey: 'stable-factory',
      );

      await tester.pumpWidget(app(config('first')));
      final oldClient = clients.first;
      await tester.pumpWidget(app(config('second')));
      await _pumpUntil(tester, () => oldClient.disposed && clients.length >= 2);

      expect(oldClient.disposed, isTrue);
      expect(clients.last.disposed, isFalse);
    },
  );

  testWidgets('AcpClientApp detects in-place runtime secret changes', (
    tester,
  ) async {
    final env = <String, String>{'TOKEN': 'first'};
    final server = AgentServerConfig(
      name: 'Codex',
      type: 'custom',
      command: '/usr/local/bin/codex-acp',
      env: env,
      envRefs: const <String, String>{
        'TOKEN':
            'keychain://ianvs-acp/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      },
    );
    final config = AcpClientConfig(
      activeAgentServer: server,
      agentServers: <AgentServerConfig>[server],
      defaultAgentServerName: 'Codex',
    );
    final clients = <_TrackingHangingAgentClient>[];
    _TrackingHangingAgentClient factory(AcpClientConfig _) {
      final client = _TrackingHangingAgentClient();
      clients.add(client);
      return client;
    }

    AcpClientApp app() => AcpClientApp(
      key: const ValueKey('mutable-secret-change'),
      config: config,
      autoLoadWorkspaceSessions: false,
      createAgentClient: factory,
      agentClientFactoryKey: 'stable-factory',
    );

    await tester.pumpWidget(app());
    final oldClient = clients.first;
    env['TOKEN'] = 'second';
    await tester.pumpWidget(app());
    await _pumpUntil(tester, () => oldClient.disposed && clients.length >= 2);

    expect(oldClient.disposed, isTrue);
    expect(clients.last.disposed, isFalse);
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

  testWidgets('AcpClientApp starts new sessions with entered cwd', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await tester.pumpWidget(AcpClientApp(controller: controller));
    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();

    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '/other/project');
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    expect(controller.currentSession?.cwd, '/other/project');
  });

  testWidgets('AcpClientApp starts workspace sessions with workspace cwd', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    controller.mergeSessionIndex([
      AgentSession(
        id: 'other-session',
        cwd: '/workspace/other',
        createdAt: DateTime(2026, 7, 6, 12),
        title: 'Other session',
        agentName: 'Codex',
      ),
    ]);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('other')));
    await tester.pump();

    final otherCenter = tester.getCenter(find.text('other'));
    await mouse.moveTo(otherCenter);
    await tester.pump();

    Offset? workspaceMenuButtonCenter;
    for (final element in find.byTooltip('Workspace actions').evaluate()) {
      final renderObject = element.renderObject;
      if (renderObject is! RenderBox) continue;
      final center = renderObject.localToGlobal(
        renderObject.size.center(Offset.zero),
      );
      if ((center.dy - otherCenter.dy).abs() < 24) {
        workspaceMenuButtonCenter = center;
        break;
      }
    }
    expect(workspaceMenuButtonCenter, isNotNull);
    await tester.tapAt(workspaceMenuButtonCenter!);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Session').last);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller?.text, '/workspace/other');
  });

  testWidgets('AcpClientApp auto-loads workspaces on startup before sessions', (
    tester,
  ) async {
    final fake = _WorkspaceCatalogAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace/project-a',
    );
    addTearDown(controller.dispose);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    expect(fake.connected, isTrue);
    expect(
      controller.sessions.map((session) => session.id),
      contains('session-a'),
    );
    expect(
      controller.sessions.map((session) => session.id),
      contains('session-b'),
    );
    expect(find.text('project-a'), findsWidgets);
    expect(find.text('project-b'), findsOneWidget);
  });

  testWidgets('AcpClientApp resumes initial session arguments', (tester) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      AcpClientApp(
        controller: controller,
        initialResumeSessionId: 'session-from-link',
        initialResumeCwd: '/workspace/from-link',
      ),
    );
    await tester.pumpAndSettle();

    expect(controller.currentSession?.id, 'session-from-link');
    expect(controller.currentSession?.cwd, '/workspace/from-link');
  });

  testWidgets(
    'AcpClientApp shows loading state during initial session resume',
    (tester) async {
      final fake = FakeAgentClient(
        resumeDelay: const Duration(milliseconds: 50),
      );
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        AcpClientApp(
          controller: controller,
          initialResumeSessionId: 'session-from-link',
          initialResumeCwd: '/workspace/from-link',
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(controller.isSessionReplayLoading, isTrue);
      expect(find.text('Loading session'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(find.text('Loading session'), findsNothing);
      expect(controller.currentSession?.id, 'session-from-link');
      expect(controller.currentSession?.cwd, '/workspace/from-link');
    },
  );

  testWidgets('AcpClientApp confirms runtime session links before resuming', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/runtime')..createSync();
    final fake = _CountingResumeAgentClient(
      resumeDelay: const Duration(milliseconds: 50),
    );
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    var platformMessageReplied = false;
    final replyFuture = sendDeepLink(
      tester,
      'ianvs-acp://session?id=session-runtime&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
    ).then((_) => platformMessageReplied = true);
    await tester.pump();

    expect(platformMessageReplied, isTrue);
    await replyFuture;
    await tester.pumpAndSettle();

    expect(find.text('Open external session?'), findsOneWidget);
    expect(find.text('session-runtime'), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(find.text(workspace.path), findsOneWidget);
    expect(fake.lastResumeCwd, isNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(
      tester,
      () => find.text('Loading session').evaluate().isNotEmpty,
    );

    expect(find.text('Loading session'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpAndSettle();

    expect(fake.lastResumeCwd, workspace.resolveSymbolicLinksSync());
    expect(find.text('Loading session'), findsNothing);

    await sendDeepLink(
      tester,
      'ianvs-acp://session?id=session-runtime&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
    );
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);
    expect(fake.resumeCalls, 1);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'external links cannot override indexed templates and remain distinct',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'ianvs-deep-link-template-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      final creations =
          <({AcpClientConfig config, _CountingResumeAgentClient client})>[];
      final config = AcpClientConfig.fromJson(<String, Object?>{
        'default_agent_server': 'Codex',
        'agent_servers': <String, Object?>{
          'Codex': <String, Object?>{
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
          },
        },
        'mcp_servers': <Object?>[
          <String, Object?>{
            'name': 'repo',
            'command': '/usr/local/bin/repo-mcp',
          },
        ],
        'session_templates': <String, Object?>{
          'strict': <String, Object?>{
            'name': 'Strict',
            'version': 1,
            'mcp_servers': <String>[],
          },
          'broad': <String, Object?>{
            'name': 'Broad',
            'version': 1,
            'mcp_servers': <String>['repo'],
          },
        },
      });
      final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
        AgentSession(
          id: 'indexed-template-session',
          cwd: workspace.path,
          createdAt: DateTime(2026),
          agentName: config.activeAgentServer!.persistenceIdentity,
          sessionTemplateId: 'strict',
          sessionTemplateVersion: 1,
        ),
      ]);
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          workspaceStateStore: store,
          autoLoadWorkspaceSessions: false,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
          createAgentClient: (runtime) {
            final client = _CountingResumeAgentClient();
            creations.add((config: runtime, client: client));
            return client;
          },
        ),
        const Size(1400, 900),
      );
      await tester.pumpAndSettle();

      final encodedWorkspace = Uri.encodeQueryComponent(workspace.path);
      await Future.wait(<Future<void>>[
        sendDeepLink(
          tester,
          'ianvs-acp://session?id=indexed-template-session&cwd=$encodedWorkspace&agent=Codex&template=broad&template_version=1',
        ),
        sendDeepLink(
          tester,
          'ianvs-acp://session?id=indexed-template-session&cwd=$encodedWorkspace&agent=Codex&template=strict&template_version=1',
        ),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('broad@1'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => find.text('strict@1').evaluate().isNotEmpty,
      );
      expect(
        find.textContaining('template does not match the local session index'),
        findsOneWidget,
      );
      expect(find.text('strict@1'), findsOneWidget);
      expect(creations.every((entry) => entry.client.resumeCalls == 0), isTrue);

      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => creations.any((entry) => entry.client.resumeCalls == 1),
      );
      final resumed = creations.singleWhere(
        (entry) => entry.client.resumeCalls == 1,
      );
      expect(resumed.config.mcpServers, isEmpty);
    },
  );

  testWidgets(
    'external resume prefers a valid indexed template over a catalog alias',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'ianvs-catalog-template-alias-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      final config = AcpClientConfig.fromJson(<String, Object?>{
        'default_agent_server': 'Codex',
        'agent_servers': <String, Object?>{
          'Codex': <String, Object?>{
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
          },
        },
        'mcp_servers': <Object?>[
          <String, Object?>{
            'name': 'repo',
            'command': '/usr/local/bin/repo-mcp',
          },
        ],
        'session_templates': <String, Object?>{
          'strict': <String, Object?>{
            'name': 'Strict',
            'version': 1,
            'mcp_servers': <String>[],
          },
        },
      }, configPath: '${temp.path}/settings.json');
      final indexed = AgentSession(
        id: 'catalog-template-alias',
        cwd: workspace.path,
        createdAt: DateTime(2026),
        agentName: config.activeAgentServer!.persistenceIdentity,
        sessionTemplateId: 'strict',
        sessionTemplateVersion: 1,
      );
      final creations =
          <({AcpClientConfig config, _TemplateAliasCatalogClient client})>[];

      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          workspaceStateStore: _SessionIndexWorkspaceStateStore(<AgentSession>[
            indexed,
          ]),
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
          createAgentClient: (runtime) {
            final client = _TemplateAliasCatalogClient(
              sessionId: indexed.id,
              cwd: workspace.path,
            );
            creations.add((config: runtime, client: client));
            return client;
          },
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () => creations.any((entry) => entry.client.listCalls > 0),
      );

      await sendDeepLink(
        tester,
        'ianvs-acp://session?id=${indexed.id}'
        '&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => creations.any((entry) => entry.client.resumeCalls == 1),
      );

      final resumed = creations.singleWhere(
        (entry) => entry.client.resumeCalls == 1,
      );
      expect(resumed.config.mcpServers, isEmpty);
      expect(
        tester
            .widget<AppShell>(find.byType(AppShell))
            .controller
            .currentSession
            ?.sessionTemplateId,
        'strict',
      );
    },
  );

  testWidgets('AcpClientApp disables confirmation for a dangerous workspace', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    await sendDeepLink(
      tester,
      'ianvs-acp://session?id=session-root&cwd=%2F&agent=Codex',
    );
    await tester.pumpAndSettle();

    expect(find.text('Open external session?'), findsOneWidget);
    expect(find.text('Workspace is too broad.'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Open Session'),
    );
    expect(confirm.onPressed, isNull);
    expect(fake.lastResumeCwd, isNull);
  });

  testWidgets('AcpClientApp revalidates the workspace after confirmation', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final workspace = Directory('${temp.path}/removed')..createSync();
    final fake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final link =
        'ianvs-acp://session?id=session-removed&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    workspace.deleteSync();

    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await tester.pumpAndSettle();

    expect(fake.lastResumeCwd, isNull);
    expect(find.textContaining('Workspace does not exist.'), findsOneWidget);

    workspace.createSync();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('AcpClientApp recovers from a workspace validator failure', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/validator')..createSync();
    final fake = FakeAgentClient();
    var validationCalls = 0;
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final link =
        'ianvs-acp://session?id=session-validator&cwd='
        '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: (path) {
          validationCalls += 1;
          if (validationCalls == 1) {
            return Future<DeepLinkWorkspaceValidation>.error(
              StateError('injected validator failure'),
            );
          }
          return validateDeepLinkWorkspaceSync(path);
        },
      ),
    );
    await tester.pumpAndSettle();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await tester.pumpAndSettle();

    expect(fake.lastResumeCwd, isNull);
    expect(find.textContaining('injected validator failure'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('AcpClientApp allows a cancelled link to be requested again', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/retry')..createSync();
    final fake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final link =
        'ianvs-acp://session?id=session-retry&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    await sendDeepLink(tester, link);
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(fake.lastResumeCwd, isNull);

    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);
    expect(find.text('session-retry'), findsOneWidget);
  });

  testWidgets('malformed and valid deep links do not share an in-flight key', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/validity')..createSync();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final base =
        'ianvs-acp://session?id=session-validity&cwd='
        '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => FakeAgentClient(),
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    await sendDeepLink(tester, '$base&template_version=oops');
    await tester.pumpAndSettle();
    expect(
      find.text('Template version must be a positive integer.'),
      findsOneWidget,
    );
    await sendDeepLink(tester, base);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('session-validity'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Open Session'),
    );
    expect(confirm.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('deep-link teardown releases only its own active token', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/active-token')..createSync();
    final firstValidation = Completer<DeepLinkWorkspaceValidation>();
    var validationCalls = 0;
    final injected = ChatController(
      client: FakeAgentClient(),
      cwd: workspace.path,
    );
    addTearDown(injected.dispose);
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final link =
        'ianvs-acp://session?id=session-active-token&cwd='
        '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';
    Future<DeepLinkWorkspaceValidation> validator(String? path) {
      validationCalls += 1;
      if (validationCalls == 1) return firstValidation.future;
      return validateDeepLinkWorkspaceSync(path);
    }

    Widget ownedApp() => AcpClientApp(
      config: config,
      autoLoadWorkspaceSessions: false,
      createAgentClient: (_) => FakeAgentClient(),
      deepLinkWorkspaceValidator: validator,
    );

    await tester.pumpWidget(ownedApp());
    await tester.pumpAndSettle();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await tester.pump();
    expect(validationCalls, 1);

    await tester.pumpWidget(
      AcpClientApp(
        controller: injected,
        config: config,
        autoLoadWorkspaceSessions: false,
      ),
    );
    await tester.pumpAndSettle();
    await tester.pumpWidget(ownedApp());
    await tester.pumpAndSettle();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('session-active-token'), findsOneWidget);

    firstValidation.complete(validateDeepLinkWorkspaceSyntax(workspace.path));
    await tester.pump();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Open external session?'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets('deep-link teardown retains a key until resume finishes', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/resume-token')..createSync();
    final injected = ChatController(
      client: FakeAgentClient(),
      cwd: workspace.path,
    );
    addTearDown(injected.dispose);
    final clients = <_ControlledDeepLinkResumeAgentClient>[];
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    final link =
        'ianvs-acp://session?id=session-resume-token&cwd='
        '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

    Widget ownedApp() => AcpClientApp(
      config: config,
      autoLoadWorkspaceSessions: false,
      createAgentClient: (_) {
        final client = _ControlledDeepLinkResumeAgentClient();
        clients.add(client);
        return client;
      },
      deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
    );

    await tester.pumpWidget(ownedApp());
    await tester.pumpAndSettle();
    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(tester, () => clients.single.restoreCalls == 1);
    await clients.single.restoreStarted;
    expect(clients.single.restoreCalls, 1);

    await tester.pumpWidget(
      AcpClientApp(
        controller: injected,
        config: config,
        autoLoadWorkspaceSessions: false,
      ),
    );
    await tester.pump();
    await tester.pumpWidget(ownedApp());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(clients, hasLength(2));

    await sendDeepLink(tester, link);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Open external session?'), findsNothing);
    expect(clients.fold<int>(0, (sum, client) => sum + client.restoreCalls), 1);

    clients.first.releaseRestore();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Could not open external session'),
      findsNothing,
    );

    await sendDeepLink(tester, link);
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'deep-link resume dedupe survives AcpClientApp State replacement',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync(
        'ianvs-deep-link-state-',
      );
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/workspace')..createSync();
      final clients = <_ControlledDeepLinkResumeAgentClient>[];
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      });
      final link =
          'ianvs-acp://session?id=session-cross-state&cwd='
          '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

      Widget app(String key) => AcpClientApp(
        key: ValueKey<String>(key),
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) {
          final client = _ControlledDeepLinkResumeAgentClient();
          clients.add(client);
          return client;
        },
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      );

      await tester.pumpWidget(app('first-state'));
      await tester.pumpAndSettle();
      await sendDeepLink(tester, link);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(tester, () => clients.first.restoreCalls == 1);
      await clients.first.restoreStarted;

      await tester.pumpWidget(app('second-state'));
      await tester.pump();
      expect(clients, hasLength(2));
      await sendDeepLink(tester, link);
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Open external session?'), findsNothing);
      expect(
        clients.fold<int>(0, (sum, client) => sum + client.restoreCalls),
        1,
      );

      clients.first.releaseRestore();
      await tester.pump();
      await tester.pumpAndSettle();
      await sendDeepLink(tester, link);
      await tester.pumpAndSettle();
      expect(find.text('Open external session?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('cross-State hung deep-link resumes remain globally bounded', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-bound-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/workspace')..createSync();
    final clients = <_ControlledDeepLinkResumeAgentClient>[];
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });

    Widget app(int generation) => AcpClientApp(
      key: ValueKey<String>('bounded-state-$generation'),
      config: config,
      autoLoadWorkspaceSessions: false,
      createAgentClient: (_) {
        final client = _ControlledDeepLinkResumeAgentClient();
        clients.add(client);
        return client;
      },
      deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
    );

    for (var generation = 0; generation < 8; generation += 1) {
      await tester.pumpWidget(app(generation));
      await tester.pump();
      final link =
          'ianvs-acp://session?id=hung-$generation&cwd='
          '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';
      await sendDeepLink(tester, link);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () =>
            clients.fold<int>(0, (sum, client) => sum + client.restoreCalls) ==
            generation + 1,
      );
    }

    await tester.pumpWidget(app(8));
    await tester.pump();
    await sendDeepLink(
      tester,
      'ianvs-acp://session?id=hung-overflow&cwd='
      '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('Open external session?'), findsNothing);
    expect(clients.fold<int>(0, (sum, client) => sum + client.restoreCalls), 8);

    for (final client in clients) {
      client.releaseRestore();
    }
    await tester.pump();
    await tester.pumpAndSettle();
  });

  testWidgets('AcpClientApp serializes distinct session confirmations', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final first = Directory('${temp.path}/first')..createSync();
    final second = Directory('${temp.path}/second')..createSync();
    final fake = _CountingResumeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });
    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
      ),
    );
    await tester.pumpAndSettle();

    await Future.wait([
      sendDeepLink(
        tester,
        'ianvs-acp://session?id=session-first&cwd=${Uri.encodeQueryComponent(first.path)}&agent=Codex',
      ),
      sendDeepLink(
        tester,
        'ianvs-acp://session?id=session-second&cwd=${Uri.encodeQueryComponent(second.path)}&agent=Codex',
      ),
    ]);
    await tester.pumpAndSettle();

    expect(find.text('session-first'), findsOneWidget);
    expect(find.text('session-second'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(
      tester,
      () => find.text('session-second').evaluate().isNotEmpty,
    );

    expect(find.text('session-second'), findsOneWidget);
    expect(fake.resumeCalls, 1);

    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(tester, () => fake.resumeCalls == 2);

    expect(fake.resumeCalls, 2);
    expect(fake.lastResumeCwd, second.resolveSymbolicLinksSync());
  });

  testWidgets('AcpClientApp does not resume a link after app disposal', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/dispose')..createSync();
    final fake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
      ),
    );
    await tester.pumpAndSettle();
    await sendDeepLink(
      tester,
      'ianvs-acp://session?id=session-dispose&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
    );
    await tester.pumpAndSettle();
    expect(find.text('Open external session?'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(fake.lastResumeCwd, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'AcpClientApp invalidates queued links when handler ownership changes',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final workspace = Directory('${temp.path}/ownership')..createSync();
      final owned = _CountingResumeAgentClient();
      final injected = ChatController(
        client: FakeAgentClient(),
        cwd: workspace.path,
      );
      addTearDown(injected.dispose);
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      });
      final firstLink =
          'ianvs-acp://session?id=session-owned-1&cwd='
          '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';
      final secondLink =
          'ianvs-acp://session?id=session-owned-2&cwd='
          '${Uri.encodeQueryComponent(workspace.path)}&agent=Codex';

      await tester.pumpWidget(
        AcpClientApp(
          config: config,
          autoLoadWorkspaceSessions: false,
          createAgentClient: (_) => owned,
        ),
      );
      await tester.pumpAndSettle();
      await sendDeepLink(tester, firstLink);
      await sendDeepLink(tester, secondLink);
      await tester.pumpAndSettle();
      expect(find.text('session-owned-1'), findsOneWidget);

      await tester.pumpWidget(
        AcpClientApp(
          controller: injected,
          config: config,
          autoLoadWorkspaceSessions: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(owned.resumeCalls, 0);
      expect(injected.currentSession, isNull);
      expect(find.text('Open external session?'), findsNothing);
      expect(find.text('session-owned-2'), findsNothing);
      await sendDeepLink(tester, firstLink);
      await tester.pumpAndSettle();
      expect(find.text('Open external session?'), findsNothing);
    },
  );

  testWidgets('AcpClientApp bounds the external session confirmation queue', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync('ianvs-deep-link-ui-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/bounded')..createSync();
    final fake = FakeAgentClient();
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    });

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 1; index <= 9; index += 1) {
      await sendDeepLink(
        tester,
        'ianvs-acp://session?id=session-$index&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
      );
    }
    await tester.pumpAndSettle();

    for (var index = 1; index <= 8; index += 1) {
      expect(find.text('session-$index'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
    }

    expect(find.text('Open external session?'), findsNothing);
    expect(find.text('session-9'), findsNothing);
    expect(fake.lastResumeCwd, isNull);
  });

  testWidgets('AcpClientApp opens workspace worktree dialog from sidebar', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller, gitWorkspaceDetector: (_) => true),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Workspace actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create Permanent Worktree'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Create Permanent Worktree'), findsOneWidget);
    expect(find.text('/workspace/current-worktree'), findsOneWidget);
  });

  testWidgets('AcpClientApp copies session deep links with agent metadata', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments;
          if (args is Map) clipboardText = args['text'] as String?;
          return null;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace/current',
      agentName: 'Kimi Code Dev',
    );
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Copy Deep Link'));
    await tester.pump();

    final uri = Uri.parse(clipboardText!);
    expect(uri.scheme, 'ianvs-acp');
    expect(uri.host, 'session');
    expect(uri.queryParameters['id'], sessionId);
    expect(uri.queryParameters['cwd'], '/workspace/current');
    expect(uri.queryParameters['agent'], 'Kimi Code Dev');
    expect(find.text('Deep link copied.'), findsOneWidget);
  });

  testWidgets('AcpClientApp handles session copy and unread menu actions', (
    tester,
  ) async {
    String? clipboardText;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final args = call.arguments;
          if (args is Map) clipboardText = args['text'] as String?;
          return null;
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace/current',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sessionId = controller.currentSession!.id;
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.user, text: 'Review this change'),
      startsNewTurn: true,
    );
    controller.addMessageForTesting(
      ChatMessage(role: ChatMessageRole.assistant, text: 'Review complete'),
    );

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Copy Working Directory'));
    await tester.pump();

    expect(clipboardText, '/workspace/current');
    expect(find.text('Working directory copied.'), findsOneWidget);

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Copy Session ID'));
    await tester.pump();

    expect(clipboardText, sessionId);

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Copy as Markdown'));
    await tester.pump();

    expect(clipboardText, contains('# fake-ses'));
    expect(clipboardText, contains('## User\n\nReview this change'));
    expect(clipboardText, contains('## Agent\n\nReview complete'));

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Mark as Unread'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .unread,
      isTrue,
    );

    await _openSidebarSessionMenu(tester, controller);
    expect(find.text('Mark as Read'), findsOneWidget);
    await tester.tap(find.text('Mark as Read'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .unread,
      isFalse,
    );
  });

  testWidgets('AcpClientApp reports clipboard failures from session actions', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          throw PlatformException(code: 'clipboard-unavailable');
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
    });

    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/current',
    );
    addTearDown(controller.dispose);
    await controller.newSession();

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller, autoLoadWorkspaceSessions: false),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Copy Session ID'));
    await tester.pump();

    expect(find.textContaining('Could not copy Session ID'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('AcpClientApp queues session selection behind session listing', (
    tester,
  ) async {
    final client = _ControllableListAgentClient();
    final controller = ChatController(
      client: client,
      cwd: '/workspace/current',
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    controller.mergeSessionIndex([
      AgentSession(
        id: 'remote-history',
        cwd: '/workspace/current',
        createdAt: DateTime(2025),
        title: 'Remote history',
      ),
    ]);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller, autoLoadWorkspaceSessions: false),
      const Size(1400, 900),
    );

    final listing = controller.listSessions();
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('workspace-session-history:remote-history')),
    );
    await tester.pumpAndSettle(const Duration(milliseconds: 10));

    expect(find.text('Review Session Workspace'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await tester.pump();
    expect(controller.currentSession?.id, 'fake-session-1');

    client.releaseList();
    await tester.pump();
    await listing;
    await tester.pumpAndSettle();

    expect(controller.currentSession?.id, 'remote-history');
    expect(client.lastResumeCwd, '/workspace/current');
  });

  testWidgets(
    'AcpClientApp keeps prompts active while switching between sessions',
    (tester) async {
      final workspace = Directory.current.resolveSymbolicLinksSync();
      final clients = <_ConcurrentPromptAgentClient>[];
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      });
      final firstSession = AgentSession(
        id: 'concurrent-session-a',
        cwd: workspace,
        createdAt: DateTime(2026, 8, 11, 10),
        title: 'Concurrent session A',
        agentName: 'Codex',
      );
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          initialResumeSessionId: firstSession.id,
          initialResumeCwd: firstSession.cwd,
          initialResumeAgentName: 'Codex',
          autoLoadWorkspaceSessions: false,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) {
            final client = _ConcurrentPromptAgentClient();
            clients.add(client);
            return client;
          },
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () =>
            tester
                .widget<AppShell>(find.byType(AppShell))
                .controller
                .currentSession
                ?.id ==
            firstSession.id,
      );

      final firstController = tester
          .widget<AppShell>(find.byType(AppShell))
          .controller;
      await firstController.sendPrompt('Run session A');
      await tester.pump();
      expect(firstController.isStreaming, isTrue);
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byTooltip('New Session'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNotNull,
      );

      await tester.tap(find.byTooltip('New Session'));
      await tester.pumpAndSettle();
      final workspaceField = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(workspaceField, workspace);
      await tester.tap(find.widgetWithText(FilledButton, 'Start'));
      await _pumpUntil(tester, () {
        final active = tester
            .widget<AppShell>(find.byType(AppShell))
            .controller;
        return !identical(active, firstController) &&
            active.currentSession != null;
      });

      final concurrentShell = tester.widget<AppShell>(find.byType(AppShell));
      final secondController = concurrentShell.controller;
      final secondSession = secondController.currentSession!;
      expect(secondController, isNot(same(firstController)));
      expect(concurrentShell.sessionControllers, hasLength(2));
      expect(clients, hasLength(1));

      await secondController.sendPrompt('Run session B');
      await tester.pump();
      expect(firstController.isStreaming, isTrue);
      expect(secondController.isStreaming, isTrue);

      tester.widget<AppShell>(find.byType(AppShell)).onSelectSession!(
        firstSession,
      );
      await _pumpUntil(
        tester,
        () => identical(
          tester.widget<AppShell>(find.byType(AppShell)).controller,
          firstController,
        ),
      );
      expect(find.text('Review Session Workspace'), findsNothing);
      expect(firstController.isStreaming, isTrue);
      expect(secondController.isStreaming, isTrue);

      await sendDeepLink(
        tester,
        'ianvs-acp://session?id=${Uri.encodeQueryComponent(secondSession.id)}'
        '&cwd=${Uri.encodeQueryComponent(workspace)}&agent=Codex',
      );
      await tester.pumpAndSettle();
      expect(find.text('Open external session?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => identical(
          tester.widget<AppShell>(find.byType(AppShell)).controller,
          secondController,
        ),
      );
      expect(find.text('Review Session Workspace'), findsNothing);

      await secondController.stop();
      await tester.pump();
      expect(firstController.isStreaming, isTrue);
      expect(secondController.isStreaming, isFalse);
      expect(clients.single.cancelledSessionIds, contains(secondSession.id));
      expect(
        clients.single.cancelledSessionIds,
        isNot(contains(firstSession.id)),
      );

      await firstController.stop();
      await tester.pump();
      expect(firstController.isStreaming, isFalse);
      expect(clients.single.cancelledSessionIds, contains(firstSession.id));

      await tester.pumpWidget(const SizedBox.shrink());
      await _pumpUntil(
        tester,
        () => clients.every((client) => client.disposed),
      );
    },
  );

  testWidgets(
    'AcpClientApp switches idle local snapshots back and forth without resume',
    (tester) async {
      final clients = <_CountingResumeAgentClient>[];
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      });
      final firstSession = AgentSession(
        id: 'idle-snapshot-session-a',
        cwd: '/workspace/idle-snapshots',
        createdAt: DateTime(2026, 8, 11, 11),
        title: 'Idle snapshot session A',
        agentName: 'Codex',
      );
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          initialResumeSessionId: firstSession.id,
          initialResumeCwd: firstSession.cwd,
          initialResumeAgentName: 'Codex',
          autoLoadWorkspaceSessions: false,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) {
            final client = _CountingResumeAgentClient();
            clients.add(client);
            return client;
          },
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () =>
            tester
                .widget<AppShell>(find.byType(AppShell))
                .controller
                .currentSession
                ?.id ==
            firstSession.id,
      );

      final controller = tester
          .widget<AppShell>(find.byType(AppShell))
          .controller;
      await controller.newSession(cwd: firstSession.cwd);
      final secondSession = controller.currentSession!;
      expect(secondSession.id, isNot(firstSession.id));

      tester.widget<AppShell>(find.byType(AppShell)).onSelectSession!(
        firstSession,
      );
      await _pumpUntil(
        tester,
        () => controller.currentSession?.id == firstSession.id,
      );
      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Resume Session'), findsNothing);

      final result = await controller.sendPrompt('Continue snapshot A');
      await tester.pumpAndSettle();

      expect(result, ChatPromptSubmissionResult.submitted);
      expect(clients, hasLength(1));
      expect(clients.single.resumeCalls, 1);
      expect(clients.single.lastPrompt, 'Continue snapshot A');

      tester.widget<AppShell>(find.byType(AppShell)).onSelectSession!(
        secondSession,
      );
      await _pumpUntil(
        tester,
        () => controller.currentSession?.id == secondSession.id,
      );
      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Resume Session'), findsNothing);
      expect(clients.single.resumeCalls, 1);

      tester.widget<AppShell>(find.byType(AppShell)).onSelectSession!(
        firstSession,
      );
      await _pumpUntil(
        tester,
        () => controller.currentSession?.id == firstSession.id,
      );
      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.widgetWithText(FilledButton, 'Resume Session'), findsNothing);
      expect(clients.single.resumeCalls, 1);
    },
  );

  testWidgets(
    'AcpClientApp disables concurrent session actions for legacy clients',
    (tester) async {
      final workspace = Directory.current.resolveSymbolicLinksSync();
      final client = _LegacyHangingAgentClient();
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      });
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          initialResumeSessionId: 'legacy-session',
          initialResumeCwd: workspace,
          initialResumeAgentName: 'Codex',
          autoLoadWorkspaceSessions: false,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) => client,
        ),
        const Size(1400, 900),
      );
      final shell = tester.widget<AppShell>(find.byType(AppShell));
      await shell.controller.sendPrompt('Keep running');
      await tester.pump();

      final updatedShell = tester.widget<AppShell>(find.byType(AppShell));
      expect(updatedShell.supportsConcurrentSessions, isFalse);
      expect(
        tester
            .widget<FilledButton>(
              find.descendant(
                of: find.byTooltip('New Session'),
                matching: find.byType(FilledButton),
              ),
            )
            .onPressed,
        isNull,
      );

      await client.finishPrompt();
      await tester.pumpAndSettle();
    },
  );

  testWidgets('busy legacy template blocks an idle concurrent base runtime', (
    tester,
  ) async {
    final temp = Directory.systemTemp.createTempSync(
      'ianvs-mixed-concurrency-',
    );
    addTearDown(() => temp.deleteSync(recursive: true));
    final workspace = Directory('${temp.path}/workspace')..createSync();
    final legacy = _LegacyHangingAgentClient();
    final concurrent = _ConcurrentPromptAgentClient();
    final config = AcpClientConfig.fromJson(<String, Object?>{
      'default_agent_server': 'Codex',
      'default_session_template': 'strict',
      'agent_servers': <String, Object?>{
        'Codex': <String, Object?>{
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
        },
      },
      'mcp_servers': <Object?>[
        <String, Object?>{'name': 'repo', 'command': '/usr/local/bin/repo-mcp'},
      ],
      'session_templates': <String, Object?>{
        'strict': <String, Object?>{
          'name': 'Strict',
          'mcp_servers': <String>[],
        },
      },
    }, configPath: '${temp.path}/settings.json');
    final baseSession = AgentSession(
      id: 'idle-base-session',
      cwd: workspace.path,
      createdAt: DateTime(2026),
      title: 'Idle base session',
      agentName: config.activeAgentServer!.persistenceIdentity,
    );
    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: _SessionIndexWorkspaceStateStore(<AgentSession>[
          baseSession,
        ]),
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        deepLinkWorkspaceValidator: validateDeepLinkWorkspaceSync,
        createAgentClient: (runtime) =>
            runtime.mcpServers.isEmpty ? legacy : concurrent,
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(tester, () => concurrent.connected);
    await tester.tap(find.byTooltip('New Session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    final shell = tester.widget<AppShell>(find.byType(AppShell));
    expect(shell.controller.client.supportsConcurrentPrompts, isFalse);
    await shell.controller.sendPrompt('Keep the strict runtime busy');
    await tester.pump();

    await sendDeepLink(
      tester,
      'ianvs-acp://session?id=base-target&cwd=${Uri.encodeQueryComponent(workspace.path)}&agent=Codex',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(
      tester,
      () => find
          .textContaining('Wait for the current response')
          .evaluate()
          .isNotEmpty,
    );

    expect(concurrent.lastResumeCwd, isNull);
    expect(
      find.textContaining('Wait for the current response'),
      findsOneWidget,
    );

    final activeShell = tester.widget<AppShell>(find.byType(AppShell));
    final baseController = activeShell.sessionControllers.firstWhere(
      (controller) =>
          !identical(controller, activeShell.controller) &&
          controller.supportsSessionFork &&
          controller.sessions.isNotEmpty,
    );
    final forkTarget = baseController.sessions.first;
    await activeShell.onSessionMenuAction!(
      tester.element(find.byType(AppShell)),
      forkTarget,
      WorkspaceSessionMenuAction.forkLocally,
    );
    await tester.pump();
    expect(concurrent.lastForkedSessionId, isNull);
    expect(
      tester.widget<AppShell>(find.byType(AppShell)).controller,
      same(activeShell.controller),
    );

    await legacy.finishPrompt();
    await tester.pumpAndSettle();
  });

  testWidgets(
    'AcpClientApp keeps deep links on the requested same-source agent',
    (tester) async {
      final workspace = Directory.current.resolveSymbolicLinksSync();
      final clients = <String, _CountingResumeAgentClient>{};
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Agent A',
        'agent_servers': {
          'Agent A': {
            'type': 'custom',
            'command': '/usr/local/bin/shared-acp',
            'default_reasoning_effort': 'low',
          },
          'Agent B': {
            'type': 'custom',
            'command': '/usr/local/bin/shared-acp',
            'default_reasoning_effort': 'high',
          },
        },
      });
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          initialResumeSessionId: 'same-source-session',
          initialResumeCwd: workspace,
          initialResumeAgentName: 'Agent A',
          autoLoadWorkspaceSessions: false,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (agentConfig) => clients.putIfAbsent(
            agentConfig.agentName,
            _CountingResumeAgentClient.new,
          ),
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(tester, () => clients['Agent A']?.resumeCalls == 1);

      await sendDeepLink(
        tester,
        'ianvs-acp://session?id=same-source-session'
        '&cwd=${Uri.encodeQueryComponent(workspace)}&agent=Agent%20B',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(tester, () => clients['Agent B']?.resumeCalls == 1);

      final shell = tester.widget<AppShell>(find.byType(AppShell));
      expect(shell.agentName, 'Agent B');
      expect(shell.controller.agentName, 'Agent B');
      expect(clients['Agent A']?.resumeCalls, 1);
    },
  );

  testWidgets('AcpClientApp opens sessions in a new window from the menu', (
    tester,
  ) async {
    List<String>? openedArgs;
    final fake = FakeAgentClient();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace/current',
      agentName: 'Codex',
    );
    addTearDown(controller.dispose);
    await controller.newSession(
      cwd: '/workspace/current',
      template: const SessionTemplateConfig(
        id: 'review',
        name: 'Review',
        version: 2,
      ),
    );
    final sessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        controller: controller,
        openSessionWindow: (args) async {
          openedArgs = args;
        },
      ),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Open in New Window'));
    await tester.pumpAndSettle();

    expect(openedArgs, [
      '--resume-session-id=$sessionId',
      '--resume-cwd=/workspace/current',
      '--resume-agent=Codex',
      '--resume-template=review',
      '--resume-template-version=2',
    ]);
  });

  testWidgets('AcpClientApp marks unread sessions read when opened', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    controller.mergeSessionIndex([
      AgentSession(
        id: 'other-session',
        cwd: '/workspace/other',
        createdAt: DateTime(2026, 7, 6, 12),
        title: 'Unread other session',
        agentName: 'Codex',
        unread: true,
      ),
    ]);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    expect(
      controller.sessions
          .singleWhere((session) => session.id == 'other-session')
          .unread,
      isTrue,
    );

    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();

    expect(find.text('Review Session Workspace'), findsOneWidget);
    expect(controller.currentSession?.id, isNot('other-session'));
    expect(
      controller.sessions
          .singleWhere((session) => session.id == 'other-session')
          .unread,
      isTrue,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await tester.pumpAndSettle();

    expect(controller.currentSession?.id, 'other-session');
    expect(
      controller.sessions
          .singleWhere((session) => session.id == 'other-session')
          .unread,
      isFalse,
    );
  });

  testWidgets('AcpClientApp serializes automatic session catalog refreshes', (
    tester,
  ) async {
    final tracker = _CatalogConcurrencyTracker();
    final clients = <String, _TrackingCatalogAgentClient>{};
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        'Pi': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
      },
    }, configPath: '/tmp/ianvs-acp-catalog-serialization.json');

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        workspaceStateStore: _SessionIndexWorkspaceStateStore(
          const <AgentSession>[],
        ),
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (agentConfig) => clients.putIfAbsent(
          agentConfig.agentName,
          () => _TrackingCatalogAgentClient(tracker),
        ),
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(
      tester,
      () =>
          clients.values.fold<int>(
            0,
            (count, client) => count + client.listCalls,
          ) >=
          2,
    );

    expect(tracker.maxActive, 1);
  });

  testWidgets(
    'AcpClientApp confirms sidebar workspace roots before switching agents',
    (tester) async {
      final temp = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('ianvs-acp-remote-workspace-'),
      ))!;
      addTearDown(() {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      });
      final clients = <String, _RemoteWorkspaceSessionClient>{};
      final factoryCalls = <String, int>{};
      final configPath = '${temp.path}/settings.json';
      final workspaceStateStore = WorkspaceSidebarStateStore(
        path: WorkspaceSidebarStateStore.defaultPath(configPath: configPath),
      );
      await tester.runAsync(
        () => workspaceStateStore.saveExpandedWorkspacePaths({'/workspace/pi'}),
      );
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          'pi ACP': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
        },
      }, configPath: configPath);

      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        AcpClientApp(
          config: config,
          workspaceStateStore: workspaceStateStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (agentConfig) {
            factoryCalls.update(
              agentConfig.agentName,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            return clients.putIfAbsent(
              agentConfig.agentName,
              () => _RemoteWorkspaceSessionClient(agentConfig.agentName),
            );
          },
        ),
      );
      await _pumpUntil(
        tester,
        () => find.text('Remote Pi Session').evaluate().isNotEmpty,
      );
      final piFactoryCallsBeforeCancel = factoryCalls['pi ACP'] ?? 0;

      await tester.tap(find.text('Remote Pi Session'));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Review Session Workspace'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('/workspace/pi'),
        ),
        findsOneWidget,
      );
      expect(find.text('/workspace/shared-a'), findsOneWidget);
      expect(find.text('/workspace/shared-b'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isEmpty,
      );

      expect(clients['pi ACP']?.resumeCalls, 0);
      expect(factoryCalls['pi ACP'] ?? 0, piFactoryCallsBeforeCancel);
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'Codex',
      );

      await tester.tap(find.text('Remote Pi Session'));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      final targetController = tester
          .widget<AppShell>(find.byType(AppShell))
          .sessionControllers
          .singleWhere((controller) => controller.agentName == 'pi ACP');
      expect(targetController.isSessionOperationRunning, isFalse);
      final resumeButton = find
          .widgetWithText(FilledButton, 'Resume Session')
          .hitTestable();
      expect(resumeButton, findsOneWidget);
      await tester.tap(resumeButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isEmpty,
      );
      await _pumpUntil(tester, () => clients['pi ACP']?.resumeCalls == 1);
      await _pumpUntil(
        tester,
        () =>
            tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName ==
            'pi ACP',
      );

      expect(clients['pi ACP']?.resumeCalls, 1);
      expect(clients['pi ACP']?.lastResumeSessionId, 'remote-pi-session');
      expect(clients['pi ACP']?.lastResumeWorkspace, '/workspace/pi');
      expect(clients['pi ACP']?.lastResumeAdditionalDirectories, [
        '/workspace/shared-a',
        '/workspace/shared-b',
      ]);
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'pi ACP',
      );
    },
  );

  testWidgets(
    'AcpClientApp rejects changed roots for the active remote session id',
    (tester) async {
      final fake = _CountingResumeAgentClient();
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);
      await tester.runAsync(
        () => controller.resumeSession(
          'session-a',
          cwd: '/workspace/current',
          additionalDirectories: const ['/workspace/current-extra'],
        ),
      );
      expect(fake.resumeCalls, 1);
      controller.mergeSessionIndex(<AgentSession>[
        AgentSession(
          id: 'project-a-workspace-anchor',
          cwd: '/workspace/project-a',
          createdAt: DateTime(2026),
          agentName: 'Codex',
        ),
      ]);

      await pumpWithWindowSize(
        tester,
        AcpClientApp(controller: controller, autoLoadWorkspaceSessions: false),
        const Size(1400, 900),
      );

      await _openWorkspaceResume(tester, '/workspace/project-a');
      await _pumpUntil(tester, () {
        final loadButton = find.widgetWithText(FilledButton, 'Open Session');
        return loadButton.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(loadButton).onPressed != null;
      });
      await tester.pump(const Duration(milliseconds: 300));
      final loadButton = find
          .widgetWithText(FilledButton, 'Open Session')
          .hitTestable();
      expect(loadButton, findsOneWidget);
      await tester.tap(loadButton);
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.textContaining('different workspace').evaluate().isNotEmpty,
      );

      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.textContaining('different workspace'), findsOneWidget);
      expect(fake.resumeCalls, 1);
      expect(fake.lastResumeCwd, '/workspace/current');
      expect(controller.currentSession?.cwd, '/workspace/current');
      expect(controller.currentSession?.additionalDirectories, [
        '/workspace/current-extra',
      ]);
    },
  );

  testWidgets(
    'AcpClientApp preflights changed roots on an inactive cached agent',
    (tester) async {
      final clients = <String, _RemoteWorkspaceSessionClient>{};
      final factoryCalls = <String, int>{};
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          'pi ACP': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
        },
      });

      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          initialResumeSessionId: 'remote-pi-session',
          initialResumeCwd: '/workspace/pi-active',
          initialResumeAgentName: 'pi ACP',
          createAgentClient: (agentConfig) {
            factoryCalls.update(
              agentConfig.agentName,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            return clients.putIfAbsent(
              agentConfig.agentName,
              () => _RemoteWorkspaceSessionClient(agentConfig.agentName),
            );
          },
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () =>
            tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName ==
                'pi ACP' &&
            clients['pi ACP']?.resumeCalls == 1,
      );
      expect(clients['pi ACP']?.lastResumeWorkspace, '/workspace/pi-active');
      clients['pi ACP']!.resetResumeTracking();

      await tester.tap(find.byTooltip('Agents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Codex').last);
      await tester.pumpAndSettle();
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'Codex',
      );
      final piFactoryCallsBeforeSelection = factoryCalls['pi ACP'] ?? 0;
      final piController = tester
          .widget<AppShell>(find.byType(AppShell))
          .sessionControllers
          .singleWhere((controller) => controller.agentName == 'pi ACP');
      piController.mergeSessionIndex(<AgentSession>[
        AgentSession(
          id: 'pi-workspace-anchor',
          cwd: '/workspace/pi',
          createdAt: DateTime(2026),
          agentName: 'pi ACP',
        ),
      ]);
      await tester.pump();

      await _openWorkspaceResume(tester, '/workspace/pi');
      await _selectResumeAgent(tester, 'pi ACP');
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await tester.pumpAndSettle();

      expect(find.text('Review Session Workspace'), findsNothing);
      expect(find.textContaining('different workspace'), findsOneWidget);
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'Codex',
      );
      expect(clients['pi ACP']?.resumeCalls, 0);
      expect(factoryCalls['pi ACP'] ?? 0, piFactoryCallsBeforeSelection);
    },
  );

  testWidgets(
    'AcpClientApp rechecks a target bound while workspace review is open',
    (tester) async {
      final clients = <String, _RemoteWorkspaceSessionClient>{};
      final factoryCalls = <String, int>{};
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          'pi ACP': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
        },
      });

      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          createAgentClient: (agentConfig) {
            factoryCalls.update(
              agentConfig.agentName,
              (count) => count + 1,
              ifAbsent: () => 1,
            );
            return clients.putIfAbsent(
              agentConfig.agentName,
              () => _RemoteWorkspaceSessionClient(agentConfig.agentName),
            );
          },
        ),
        const Size(1400, 900),
      );
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'Codex',
      );
      final piController = tester
          .widget<AppShell>(find.byType(AppShell))
          .sessionControllers
          .singleWhere((controller) => controller.agentName == 'pi ACP');
      piController.mergeSessionIndex(<AgentSession>[
        AgentSession(
          id: 'pi-workspace-anchor',
          cwd: '/workspace/pi',
          createdAt: DateTime(2026),
          agentName: 'pi ACP',
        ),
      ]);
      await tester.pump();

      await _openWorkspaceResume(tester, '/workspace/pi');
      await _selectResumeAgent(tester, 'pi ACP');
      await _pumpUntil(tester, () {
        final loadButton = find.widgetWithText(FilledButton, 'Open Session');
        return loadButton.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(loadButton).onPressed != null;
      });
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));

      final targetController = tester
          .widget<AppShell>(find.byType(AppShell))
          .sessionControllers
          .singleWhere((controller) => controller.agentName == 'pi ACP');
      final piFactoryCallsBeforeConfirmation = factoryCalls['pi ACP'] ?? 0;
      await tester.runAsync(
        () => targetController.resumeSession(
          'remote-pi-session',
          cwd: '/workspace/pi-race',
        ),
      );
      expect(clients['pi ACP']?.resumeCalls, 1);
      expect(targetController.currentSession?.cwd, '/workspace/pi-race');

      final resumeButton = find
          .widgetWithText(FilledButton, 'Resume Session')
          .hitTestable();
      expect(resumeButton, findsOneWidget);
      await tester.tap(resumeButton);
      await tester.pump();
      await _pumpUntil(
        tester,
        () => find.textContaining('different workspace').evaluate().isNotEmpty,
      );

      expect(clients['pi ACP']?.resumeCalls, 1);
      expect(factoryCalls['pi ACP'] ?? 0, piFactoryCallsBeforeConfirmation);
      expect(targetController.currentSession?.cwd, '/workspace/pi-race');
      expect(
        tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
        'Codex',
      );
    },
  );

  testWidgets('AcpClientApp keeps identical session ids isolated by agent', (
    tester,
  ) async {
    final clients = <String, _SameIdAcrossAgentsClient>{};
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        'pi ACP': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
      },
    });

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: config,
        initialResumeSessionId: 'shared-session',
        initialResumeCwd: '/workspace/codex-bound',
        initialResumeAgentName: 'Codex',
        createAgentClient: (agentConfig) => clients.putIfAbsent(
          agentConfig.agentName,
          () => _SameIdAcrossAgentsClient(agentConfig.agentName),
        ),
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(tester, () => clients['Codex']?.resumeCalls == 1);

    final initialShell = tester.widget<AppShell>(find.byType(AppShell));
    final codexController = initialShell.sessionControllers.singleWhere(
      (controller) => controller.agentName == 'Codex',
    );
    expect(codexController.currentSession?.id, 'shared-session');
    expect(codexController.currentSession?.cwd, '/workspace/codex-bound');
    expect(codexController.currentSession?.agentName, 'Codex');
    codexController.mergeSessionIndex(<AgentSession>[
      AgentSession(
        id: 'codex-catalog-workspace-anchor',
        cwd: '/workspace/codex-catalog',
        createdAt: DateTime(2026),
        agentName: 'Codex',
      ),
    ]);
    final piController = initialShell.sessionControllers.singleWhere(
      (controller) => controller.agentName == 'pi ACP',
    );
    piController.mergeSessionIndex(<AgentSession>[
      AgentSession(
        id: 'pi-workspace-anchor',
        cwd: '/workspace/pi',
        createdAt: DateTime(2026),
        agentName: 'pi ACP',
      ),
    ]);
    await tester.pump();

    await _openWorkspaceResume(tester, '/workspace/codex-catalog');
    await _pumpUntil(tester, () {
      final loadButton = find.widgetWithText(FilledButton, 'Open Session');
      return loadButton.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(loadButton).onPressed != null;
    });
    final sessionList = find.byKey(const ValueKey('resume-session-list'));
    final codexProject = find.descendant(
      of: sessionList,
      matching: find.text('codex-catalog'),
    );
    final piProject = find.descendant(
      of: sessionList,
      matching: find.text('pi'),
    );
    expect(codexProject, findsOneWidget);
    expect(piProject, findsNothing);

    expect(
      find.descendant(
        of: sessionList,
        matching: find.text('Codex shared session'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(
      tester,
      () => find.textContaining('different workspace').evaluate().isNotEmpty,
    );

    expect(find.text('Review Session Workspace'), findsNothing);
    expect(clients['Codex']?.resumeCalls, 1);
    expect(clients['pi ACP']?.resumeCalls, 0);
    expect(
      tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName,
      'Codex',
    );
    ScaffoldMessenger.of(
      tester.element(find.byType(AppShell)),
    ).hideCurrentSnackBar();
    await tester.pumpAndSettle();
    expect(find.textContaining('different workspace'), findsNothing);

    await _openWorkspaceResume(tester, '/workspace/pi');
    await _selectResumeAgent(tester, 'pi ACP');
    await _pumpUntil(tester, () {
      final loadButton = find.widgetWithText(FilledButton, 'Open Session');
      return loadButton.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(loadButton).onPressed != null;
    });
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('resume-session-list')),
        matching: find.text('codex-catalog'),
      ),
      findsNothing,
    );
    final reloadedPiProject = find.descendant(
      of: find.byKey(const ValueKey('resume-session-list')),
      matching: find.text('pi'),
    );
    expect(reloadedPiProject, findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('resume-session-list')),
        matching: find.text('Pi shared session'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
    await _pumpUntil(
      tester,
      () => find.text('Review Session Workspace').evaluate().isNotEmpty,
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('different workspace'), findsNothing);
    expect(find.text('/workspace/pi'), findsWidgets);
    final resumeButton = find
        .widgetWithText(FilledButton, 'Resume Session')
        .hitTestable();
    expect(resumeButton, findsOneWidget);
    await tester.tap(resumeButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(clients['pi ACP']?.resumeCalls, 1);
    await _pumpUntil(
      tester,
      () =>
          tester.widget<AgentToolbar>(find.byType(AgentToolbar)).agentName ==
          'pi ACP',
    );

    expect(clients['pi ACP']?.lastResumeSessionId, 'shared-session');
    expect(clients['pi ACP']?.lastResumeWorkspace, '/workspace/pi');
    expect(codexController.currentSession?.id, 'shared-session');
    expect(codexController.currentSession?.cwd, '/workspace/codex-bound');
    expect(codexController.currentSession?.agentName, 'Codex');
  });

  testWidgets('AcpClientApp forks sessions from the session menu', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sourceSessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Fork Locally'));
    await tester.pumpAndSettle();

    expect(fake.lastForkedSessionId, sourceSessionId);
    expect(controller.currentSession?.id, 'fake-fork-2');
    expect(controller.currentSession?.cwd, '/workspace/current');
    expect(controller.currentSession?.displayTitle, 'Fork of fake-ses');
    expect(controller.sessions.first.id, 'fake-fork-2');
    expect(
      controller.sessions.map((session) => session.id),
      containsAll(['fake-fork-2', sourceSessionId]),
    );
  });

  testWidgets('AcpClientApp opens a blank side session from the session menu', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sourceSessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open Side Session'));
    await tester.pumpAndSettle();

    expect(controller.currentSession?.id, isNot(sourceSessionId));
    expect(controller.currentSession?.cwd, '/workspace/current');
    expect(
      controller.sessions.map((session) => session.id),
      contains(sourceSessionId),
    );
  });

  testWidgets('AcpClientApp opens session worktree fork dialog from menu', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller, gitWorkspaceDetector: (_) => true),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in New Worktree'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Fork to New Worktree'), findsOneWidget);
    expect(find.text('/workspace/current-fake-ses-fork'), findsOneWidget);
    expect(fake.lastForkedSessionId, isNull);
  });

  testWidgets('AcpClientApp rolls back a worktree when ACP fork fails', (
    tester,
  ) async {
    final fake = FakeAgentClient(forkError: StateError('fork failed'));
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final commands = <List<String>>[];
    final worktreePath =
        '/private/tmp/ianvs-acp-worktree-rollback-'
        '${DateTime.now().microsecondsSinceEpoch}';

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        controller: controller,
        gitWorkspaceDetector: (_) => true,
        processRunner: (executable, arguments) async {
          commands.add(<String>[executable, ...arguments]);
          if (arguments.contains('--show-toplevel')) {
            return ProcessResult(1, 0, '/workspace/current\n', '');
          }
          return ProcessResult(1, 0, '', '');
        },
      ),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in...'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue in New Worktree'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), worktreePath);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(
      commands.any(
        (command) => command.contains('worktree') && command.contains('add'),
      ),
      isTrue,
    );
    expect(
      commands.any(
        (command) =>
            command.contains('worktree') &&
            command.contains('remove') &&
            command.contains('--force') &&
            command.contains(worktreePath),
      ),
      isTrue,
    );
    expect(
      commands.any(
        (command) => command.contains('branch') && command.contains('-D'),
      ),
      isTrue,
    );
  });

  testWidgets('AcpClientApp hides toolbar worktree action outside Git', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller, gitWorkspaceDetector: (_) => false),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions').first);
    await tester.pumpAndSettle();

    expect(find.text('Continue in...'), findsOneWidget);
    await tester.tap(find.text('Continue in...'));
    await tester.pumpAndSettle();
    expect(find.text('Continue in New Session'), findsOneWidget);
    expect(find.text('Continue in New Worktree'), findsNothing);
  });

  testWidgets('AcpClientApp pins and renames sessions from the session menu', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Pin Conversation'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .pinned,
      isTrue,
    );

    await _openSidebarSessionMenu(tester, controller);
    expect(find.text('Unpin Conversation'), findsOneWidget);
    await tester.tap(find.text('Rename Conversation'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Renamed conversation',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(controller.currentSession?.displayTitle, 'Renamed conversation');
    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .displayTitle,
      'Renamed conversation',
    );
    expect(find.text('Renamed conversation'), findsWidgets);
  });

  testWidgets('AcpClientApp offers undo after archiving a session', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final sessionId = controller.currentSession!.id;
    controller.setSessionUnread(sessionId, true);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await _openSidebarSessionMenu(tester, controller);
    await tester.tap(find.text('Archive Conversation'));
    await tester.pump();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .archived,
      isTrue,
    );
    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .unread,
      isFalse,
    );
    expect(controller.currentSession, isNull);
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .archived,
      isFalse,
    );
    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .unread,
      isTrue,
    );
    expect(controller.currentSession?.id, sessionId);
  });

  testWidgets('AcpClientApp offers undo after archiving workspace sessions', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final firstSessionId = controller.currentSession!.id;
    controller.setSessionUnread(firstSessionId, true);
    await controller.newSession(cwd: '/workspace/current');
    final secondSessionId = controller.currentSession!.id;
    controller.setSessionUnread(secondSessionId, true);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Workspace actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive Conversations'));
    await tester.pump();

    for (final sessionId in <String>[firstSessionId, secondSessionId]) {
      final session = controller.sessions.singleWhere(
        (session) => session.id == sessionId,
      );
      expect(session.archived, isTrue);
      expect(session.unread, isFalse);
    }
    expect(controller.currentSession, isNull);
    expect(controller.debugUiStateRetainedBytes, greaterThan(0));
    await tester.pumpAndSettle();
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    for (final sessionId in <String>[firstSessionId, secondSessionId]) {
      final session = controller.sessions.singleWhere(
        (session) => session.id == sessionId,
      );
      expect(session.archived, isFalse);
      expect(session.unread, isTrue);
    }
    expect(controller.currentSession?.id, secondSessionId);
  });

  testWidgets('workspace archive close discards every snapshot lease', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/current',
    );
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');
    final firstSessionId = controller.currentSession!.id;
    await controller.newSession(cwd: '/workspace/current');
    final secondSessionId = controller.currentSession!.id;

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );
    await tester.tap(find.byTooltip('Workspace actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive Conversations'));
    await tester.pumpAndSettle();

    expect(controller.currentSession, isNull);
    expect(controller.debugUiStateRetainedBytes, greaterThan(0));

    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger).first)
        .hideCurrentSnackBar();
    await tester.pumpAndSettle();
    await tester.pump();

    expect(controller.debugUiStateRetainedBytes, 0);
    for (final sessionId in <String>[firstSessionId, secondSessionId]) {
      expect(
        controller.sessions
            .singleWhere((session) => session.id == sessionId)
            .archived,
        isTrue,
      );
    }
  });

  testWidgets('archive snackbar discards its lease on every close path', (
    tester,
  ) async {
    Future<({ChatController controller, String sessionId})> archiveOne() async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/current',
      );
      await controller.newSession(cwd: '/workspace/current');
      final sessionId = controller.currentSession!.id;
      await pumpWithWindowSize(
        tester,
        AcpClientApp(controller: controller),
        const Size(1400, 900),
      );
      await _openSidebarSessionMenu(tester, controller);
      await tester.tap(find.text('Archive Conversation'));
      await tester.pumpAndSettle();
      expect(controller.debugActiveUiStateRetainedBytes, 0);
      expect(controller.debugUiStateRetainedBytes, greaterThan(0));
      expect(find.text('Undo'), findsOneWidget);
      return (controller: controller, sessionId: sessionId);
    }

    for (final closePath in <String>[
      'hide',
      'dismiss',
      'remove replacement',
      'timeout',
      'swipe',
      'app dispose',
    ]) {
      final archived = await archiveOne();
      final messenger = tester.state<ScaffoldMessengerState>(
        find.byType(ScaffoldMessenger).first,
      );
      switch (closePath) {
        case 'hide':
          messenger.hideCurrentSnackBar();
          await tester.pumpAndSettle();
          break;
        case 'dismiss':
          messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.dismiss);
          await tester.pumpAndSettle();
          break;
        case 'remove replacement':
          messenger.removeCurrentSnackBar();
          messenger.showSnackBar(
            const SnackBar(content: Text('Replacement notification')),
          );
          await tester.pumpAndSettle();
          break;
        case 'timeout':
          messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.timeout);
          await tester.pumpAndSettle();
          break;
        case 'swipe':
          messenger.hideCurrentSnackBar(reason: SnackBarClosedReason.swipe);
          await tester.pumpAndSettle();
          break;
        case 'app dispose':
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          break;
      }
      await tester.pump();

      expect(
        archived.controller.debugUiStateRetainedBytes,
        0,
        reason: closePath,
      );
      expect(
        archived.controller.sessions
            .singleWhere((session) => session.id == archived.sessionId)
            .archived,
        isTrue,
        reason: closePath,
      );
      if (closePath != 'app dispose') {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      }
      archived.controller.dispose();
    }
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
    final promptField = find.descendant(
      of: find.byKey(const Key('prompt-input-surface')),
      matching: find.byType(TextField),
    );
    await tester.enterText(promptField, 'Keep this draft');
    await tester.pump();

    final loading = controller.listSessions();
    await tester.pump();

    expect(controller.isSessionOperationRunning, isTrue);
    final textField = tester.widget<TextField>(promptField);
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
    expect(tester.widget<TextField>(promptField).enabled, isTrue);
  });

  testWidgets('AcpClientApp keeps active sessions usable in narrow windows', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      createSessionEvents: const [
        AgentEvent(
          type: AgentEventType.userMessage,
          text: 'Review the ACP client implementation and identify UI gaps.',
        ),
        AgentEvent(
          type: AgentEventType.agentTextDelta,
          text:
              'I inspected the app shell, session controls, timeline grouping, permission banner, and configuration dialogs.',
        ),
        AgentEvent(
          type: AgentEventType.status,
          text: 'Implementation plan',
          metadata: {
            'kind': 'plan',
            'title': 'Implementation plan',
            'entries': [
              {
                'content': 'Check prompt composer states and permission review',
                'priority': 'high',
                'status': 'in_progress',
              },
            ],
          },
        ),
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();
    await controller.newSession();

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(390, 844),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Sessions'), findsNothing);
    expect(find.text('Implementation plan'), findsOneWidget);
    expect(
      find.text('Check prompt composer states and permission review'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('compact-workspaces-button')), findsOneWidget);
    expect(find.byKey(const Key('compact-context-button')), findsOneWidget);
    expect(
      tester.getSize(find.byKey(const Key('compact-workspaces-button'))).height,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getSize(find.byKey(const Key('compact-context-button'))).height,
      greaterThanOrEqualTo(44),
    );

    await tester.tap(find.byKey(const Key('compact-context-button')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close Context'), findsOneWidget);
    expect(find.text('会话'), findsWidgets);
    await tester.tap(find.byTooltip('Close Context'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('compact-workspaces-button')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Close Workspaces'), findsOneWidget);
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

    await _openWorkspaceActions(tester, '/workspace');
    await tester.tap(find.text('Resume Session'));
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

      await _openWorkspaceActions(tester, '/workspace');
      await tester.tap(find.text('Resume Session'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets(
    'AcpClientApp disables workspace resume after connecting list-only agents',
    (tester) async {
      final fake = FakeAgentClient(supportsLoadSession: false);
      final controller = ChatController(client: fake, cwd: '/workspace');
      addTearDown(controller.dispose);

      await tester.pumpWidget(AcpClientApp(controller: controller));

      expect(controller.canResumeSessions, isTrue);

      await _openWorkspaceResume(tester, '/workspace');

      expect(fake.connected, isTrue);
      expect(controller.canListSessions, isTrue);
      expect(controller.canResumeSessions, isFalse);
      expect(find.byType(AlertDialog), findsNothing);

      await _openWorkspaceActions(tester, '/workspace');
      await tester.tap(find.text('Resume Session'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('AcpClientApp opens protocol coverage dialog', (tester) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Protocol Coverage'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Protocol Coverage'), findsOneWidget);
    expect(find.text('ACP Registry'), findsOneWidget);
  });

  testWidgets('AcpClientApp keeps empty permission history discoverable', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Permission History'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('No permission requests yet.'), findsOneWidget);
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

  testWidgets('AcpClientApp uses an independent configured ACP reviewer', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    await tester.pumpWidget(
      AcpClientApp(
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Cursor',
          'agent_servers': {
            'Cursor': {
              'type': 'custom',
              'command': '/usr/local/bin/cursor-agent',
            },
            'Codex': {
              'type': 'custom',
              'command': '/usr/local/bin/npx',
              'args': ['@agentclientprotocol/codex-acp'],
            },
          },
          'client_providers': {
            'permissions': {
              'review_agent': {
                'agent_server_name': 'Codex',
                'model': 'review-model',
              },
            },
          },
        }),
      ),
    );
    await tester.pump();

    final shell = tester.widget<AppShell>(find.byType(AppShell));
    final reviewer =
        shell.controller.permissionReviewer as AcpAgentPermissionReviewer;
    expect(reviewer.agentName, 'Codex');
    expect(reviewer.modelOverride, 'review-model');
    expect(reviewer.canAutoApprove, isTrue);
  });

  testWidgets('AcpClientApp trusts an isolated same-agent reviewer', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    await tester.pumpWidget(
      AcpClientApp(
        autoLoadWorkspaceSessions: false,
        createAgentClient: (_) => fake,
        config: AcpClientConfig.fromJson({
          'default_agent_server': 'Codex',
          'agent_servers': {
            'Codex': {
              'type': 'custom',
              'command': '/usr/local/bin/npx',
              'args': ['@agentclientprotocol/codex-acp'],
            },
          },
        }),
      ),
    );
    await tester.pump();

    final shell = tester.widget<AppShell>(find.byType(AppShell));
    final reviewer =
        shell.controller.permissionReviewer as AcpAgentPermissionReviewer;
    expect(reviewer.agentName, 'Codex');
    expect(reviewer.modelOverride, isNull);
    expect(reviewer.canAutoApprove, isTrue);
  });

  testWidgets('AcpClientApp changes tool policy from prompt composer', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.connect();

    await tester.pumpWidget(AcpClientApp(controller: controller));

    expect(
      controller.toolCallExecutionPolicy,
      AcpToolCallExecutionPolicy.defaultPermissions,
    );
    await tester.tap(find.text('默认权限'));
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
    await tester.tap(
      find.byKey(const Key('prompt-session-config-option-model')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('prompt-session-config-choice-model-mini')),
    );
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'model');
    expect(fake.lastConfigValue, 'mini');
    expect(controller.sessionSettings.currentModelLabel, 'GPT-5 Mini');
  });

  testWidgets('AcpClientApp changes reasoning effort from prompt composer', (
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
            options: [AcpConfigOptionChoice(value: 'gpt-5', name: 'GPT-5')],
          ),
          AcpConfigOption(
            id: 'reasoning_effort',
            name: 'Reasoning Effort',
            type: 'select',
            currentValue: 'medium',
            options: [
              AcpConfigOptionChoice(value: 'medium', name: 'Medium'),
              AcpConfigOptionChoice(value: 'high', name: 'High'),
            ],
          ),
        ],
      ),
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);
    await controller.newSession();

    await tester.pumpWidget(AcpClientApp(controller: controller));
    expect(find.text('Medium'), findsOneWidget);

    await tester.tap(find.text('Medium'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('prompt-session-config-option-reasoning_effort')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        const Key('prompt-session-config-choice-reasoning_effort-high'),
      ),
    );
    await tester.pumpAndSettle();

    expect(fake.lastConfigId, 'reasoning_effort');
    expect(fake.lastConfigValue, 'high');
    expect(controller.sessionSettings.currentReasoningEffortLabel, 'High');
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

  testWidgets('AcpClientApp normalizes pi ACP session index entries to Pi', (
    tester,
  ) async {
    final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
      AgentSession(
        id: 'pi-session',
        cwd: '/workspace/pi',
        createdAt: DateTime(2026, 7, 1),
        title: 'Pi session',
        agentName: 'pi ACP',
        localUnstarted: true,
        initialEvents: const [
          AgentEvent(type: AgentEventType.status, text: 'Draft session'),
        ],
      ),
    ]);
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        'Pi': {'type': 'custom', 'command': '/Users/example/.local/bin/pi-acp'},
      },
    }, configPath: '/tmp/ianvs-acp/settings.json');

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        workspaceStateStore: store,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (_) => FakeAgentClient(supportsListSessions: false),
      ),
    );
    await _pumpUntil(tester, () => store.lastSaved.isNotEmpty);

    final savedPiSessions = store.lastSaved
        .where((session) => session.id == 'pi-session')
        .toList(growable: false);
    expect(savedPiSessions, hasLength(1));
    expect(
      savedPiSessions.single.agentName,
      config.agentServerNamed('Pi')!.persistenceIdentity,
    );
    expect(savedPiSessions.single.localUnstarted, isTrue);
    expect(savedPiSessions.single.initialEvents.single.text, 'Draft session');
  });

  testWidgets(
    'AcpClientApp restores indexed sessions after agent rename and restart',
    (tester) async {
      final workspace = Directory.current.path;
      final originalConfig = AcpClientConfig.fromJson({
        'default_agent_server': 'Original agent',
        'agent_servers': {
          'Original agent': {
            'type': 'custom',
            'command': '/usr/local/bin/agent-acp',
          },
        },
      }, configPath: '/tmp/ianvs-acp/settings.json');
      final persistenceIdentity =
          originalConfig.activeAgentServer!.persistenceIdentity;
      final initialStore = _SessionIndexWorkspaceStateStore(<AgentSession>[
        AgentSession(
          id: 'rename-session',
          cwd: workspace,
          createdAt: DateTime(2026, 7, 3),
          title: 'Rename-safe session',
          agentName: 'Original agent',
          localUnstarted: true,
        ),
      ]);

      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: originalConfig,
          workspaceStateStore: initialStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(tester, () => initialStore.lastSaved.isNotEmpty);
      expect(initialStore.lastSaved.single.agentName, persistenceIdentity);

      final renamedConfig = AcpClientConfig.fromJson({
        'default_agent_server': 'Renamed agent',
        'agent_servers': {
          'Renamed agent': originalConfig.activeAgentServer!.toJson(),
        },
      }, configPath: originalConfig.configPath);
      final restartedStore = _SessionIndexWorkspaceStateStore(
        initialStore.initialSessions,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: renamedConfig,
          workspaceStateStore: restartedStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () => find.text('Rename-safe session').evaluate().isNotEmpty,
      );

      expect(renamedConfig.agentName, 'Renamed agent');
      expect(
        renamedConfig.activeAgentServer!.persistenceIdentity,
        persistenceIdentity,
      );
      expect(restartedStore.lastSaved.single.agentName, persistenceIdentity);
    },
  );

  testWidgets(
    'AcpClientApp preserves unresolved sessions through remove restart and readd',
    (tester) async {
      final workspace = Directory.current.path;
      AcpClientConfig configured() => AcpClientConfig.fromJson({
        'default_agent_server': 'Temporary agent',
        'agent_servers': {
          'Temporary agent': {
            'type': 'custom',
            'command': '/usr/local/bin/temporary-agent-acp',
          },
        },
      }, configPath: '/tmp/ianvs-acp/settings.json');
      final initialConfig = configured();
      final persistenceIdentity =
          initialConfig.activeAgentServer!.persistenceIdentity;
      final removedConfig = const AcpClientConfig(
        configPath: '/tmp/ianvs-acp/settings.json',
      );
      final removedStore = _SessionIndexWorkspaceStateStore(<AgentSession>[
        AgentSession(
          id: 'temporarily-unresolved',
          cwd: workspace,
          createdAt: DateTime(2026, 7, 4),
          title: 'Recover after readd',
          agentName: persistenceIdentity,
          localUnstarted: true,
        ),
      ]);

      await tester.pumpWidget(
        AcpClientApp(
          config: removedConfig,
          workspaceStateStore: removedStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
      );
      await _pumpUntil(tester, () => removedStore.lastSaved.isNotEmpty);
      expect(removedStore.lastSaved.single.agentName, persistenceIdentity);

      final restartedWithoutAgent = _SessionIndexWorkspaceStateStore(
        removedStore.lastSaved,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        AcpClientApp(
          config: removedConfig,
          workspaceStateStore: restartedWithoutAgent,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
      );
      await _pumpUntil(
        tester,
        () => restartedWithoutAgent.lastSaved.isNotEmpty,
      );
      expect(
        restartedWithoutAgent.lastSaved.single.agentName,
        persistenceIdentity,
      );

      final readdedConfig = configured();
      expect(
        readdedConfig.activeAgentServer!.persistenceIdentity,
        persistenceIdentity,
      );
      final readdedStore = _SessionIndexWorkspaceStateStore(
        restartedWithoutAgent.lastSaved,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: readdedConfig,
          workspaceStateStore: readdedStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(
        tester,
        () => find.text('Recover after readd').evaluate().isNotEmpty,
      );
      expect(readdedStore.lastSaved.single.agentName, persistenceIdentity);
    },
  );

  testWidgets('AcpClientApp persists archived sessions outside the sidebar', (
    tester,
  ) async {
    final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
      AgentSession(
        id: 'archived-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 7, 2),
        title: 'Archived session',
        agentName: 'Codex',
        archived: true,
      ),
    ]);
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
      },
    }, configPath: '/tmp/ianvs-acp/settings.json');

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        workspaceStateStore: store,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (_) => FakeAgentClient(supportsListSessions: false),
      ),
    );
    await _pumpUntil(tester, () => store.lastSaved.isNotEmpty);

    final saved = store.lastSaved.singleWhere(
      (session) => session.id == 'archived-session',
    );
    expect(saved.archived, isTrue);
    expect(find.text('Archived session'), findsNothing);
  });

  testWidgets('AcpClientApp deduplicates shared ids across configured agents', (
    tester,
  ) async {
    final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
      AgentSession(
        id: 'shared-stale-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 7, 1),
        title: 'Shared stale session',
        agentName: 'codex-fast',
      ),
      AgentSession(
        id: 'shared-stale-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 7, 1),
        title: 'Shared stale session',
        agentName: 'codex-thinking',
      ),
      AgentSession(
        id: 'shared-stale-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 7, 1),
        title: 'Shared stale session',
        agentName: 'codex-worker',
      ),
    ]);
    final config = AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        'codex-fast': {
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
          'default_reasoning_effort': 'low',
        },
        'codex-thinking': {
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
          'default_reasoning_effort': 'high',
        },
        'codex-worker': {
          'type': 'custom',
          'command': '/usr/local/bin/codex-acp',
          'default_model': 'worker-model',
        },
      },
    }, configPath: '/tmp/ianvs-acp/settings.json');

    await tester.pumpWidget(
      AcpClientApp(
        config: config,
        workspaceStateStore: store,
        discoverAgentServers: (_) => const <AgentServerConfig>[],
        createAgentClient: (_) => FakeAgentClient(supportsListSessions: false),
      ),
    );
    await _pumpUntil(tester, () => store.lastSaved.isNotEmpty);

    final restored = store.lastSaved
        .where((session) => session.id == 'shared-stale-session')
        .toList(growable: false);
    expect(restored, hasLength(1));
    expect(
      restored.single.agentName,
      config.agentServerNamed('Codex')!.persistenceIdentity,
    );
  });

  testWidgets(
    'AcpClientApp restores an archived alias session across restart',
    (tester) async {
      final workspacePath = Directory.current.path;
      final clients = <String, _SharedAliasCatalogClient>{};
      final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
        for (final agentName in const [
          'codex-fast',
          'codex-thinking',
          'codex-worker',
        ])
          AgentSession(
            id: 'shared-alias-session',
            cwd: workspacePath,
            createdAt: DateTime(2026, 7, 1),
            title: 'Shared alias session',
            agentName: agentName,
          ),
      ]);
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          'codex-fast': {
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
            'default_reasoning_effort': 'low',
          },
          'codex-thinking': {
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
            'default_reasoning_effort': 'high',
          },
          'codex-worker': {
            'type': 'custom',
            'command': '/usr/local/bin/codex-acp',
            'default_model': 'worker-model',
          },
        },
      }, configPath: '/tmp/ianvs-acp/settings.json');

      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          workspaceStateStore: store,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (agentConfig) => clients.putIfAbsent(
            agentConfig.agentName,
            () =>
                _SharedAliasCatalogClient(agentConfig.agentName, workspacePath),
          ),
        ),
        const Size(1400, 900),
      );
      await _pumpUntil(tester, () => store.lastSaved.isNotEmpty);
      List<AgentSession> savedAliasSessions() => store.lastSaved
          .where((session) => session.id == 'shared-alias-session')
          .toList(growable: false);

      await _openSidebarSessionMenuForTitle(tester, 'Shared alias session');
      await tester.tap(find.text('Pin Conversation'));
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () =>
            savedAliasSessions().isNotEmpty &&
            savedAliasSessions().every((session) => session.pinned),
      );

      await _openSidebarSessionMenuForTitle(tester, 'Shared alias session');
      await tester.tap(find.text('Rename Conversation'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Canonical session title',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
      await _pumpUntil(
        tester,
        () =>
            savedAliasSessions().isNotEmpty &&
            savedAliasSessions().every(
              (session) => session.titleOverride == 'Canonical session title',
            ),
      );

      await _openSidebarSessionMenuForTitle(tester, 'Canonical session title');
      await tester.tap(find.text('Mark as Unread'));
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () =>
            savedAliasSessions().isNotEmpty &&
            savedAliasSessions().every((session) => session.unread),
      );

      await _openSidebarSessionMenuForTitle(tester, 'Canonical session title');
      await tester.tap(find.text('Archive Conversation'));
      await tester.pumpAndSettle();
      await _pumpUntil(
        tester,
        () =>
            savedAliasSessions().isNotEmpty &&
            savedAliasSessions().every(
              (session) => session.archived && !session.unread,
            ),
      );
      expect(find.text('Canonical session title'), findsNothing);

      await _openWorkspaceResume(tester, workspacePath);
      await _selectResumeAgent(tester, 'codex-thinking');
      await _pumpUntil(tester, () {
        final loadButton = find.widgetWithText(FilledButton, 'Open Session');
        return loadButton.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(loadButton).onPressed != null;
      });
      await tester.tap(find.widgetWithText(FilledButton, 'Open Session'));
      await _pumpUntil(
        tester,
        () => find.text('Review Session Workspace').evaluate().isNotEmpty,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(
        find.widgetWithText(FilledButton, 'Resume Session').hitTestable(),
      );
      await _pumpUntil(
        tester,
        () => clients['codex-thinking']?.resumeCalls == 1,
      );
      await _pumpUntil(
        tester,
        () =>
            savedAliasSessions().length == 1 &&
            !savedAliasSessions().single.archived,
      );
      expect(
        find.descendant(
          of: find.byType(WorkspaceSidebar),
          matching: find.text('Canonical session title'),
        ),
        findsOneWidget,
      );

      final restartedStore = _SessionIndexWorkspaceStateStore(store.lastSaved);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpWithWindowSize(
        tester,
        AcpClientApp(
          config: config,
          workspaceStateStore: restartedStore,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
        const Size(1400, 900),
      );

      await _pumpUntil(
        tester,
        () => find.text('Canonical session title').evaluate().isNotEmpty,
      );
      expect(
        restartedStore.initialSessions
            .where((session) => session.id == 'shared-alias-session')
            .single
            .archived,
        isFalse,
      );
    },
  );

  testWidgets(
    'AcpClientApp preserves same ids from independent agent catalogs',
    (tester) async {
      final store = _SessionIndexWorkspaceStateStore(<AgentSession>[
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 7, 1),
          title: 'Codex session',
          agentName: 'Codex',
        ),
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 7, 2),
          title: 'Pi session',
          agentName: 'Pi',
        ),
      ]);
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
          'Pi': {'type': 'custom', 'command': '/usr/local/bin/pi-acp'},
        },
      }, configPath: '/tmp/ianvs-acp/settings.json');

      await tester.pumpWidget(
        AcpClientApp(
          config: config,
          workspaceStateStore: store,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
      );
      await _pumpUntil(tester, () => store.lastSaved.isNotEmpty);

      final persisted = store.lastSaved
          .where((session) => session.id == 'shared-session')
          .toList(growable: false);
      expect(persisted, hasLength(2));
      expect(persisted.map((session) => session.agentName).toSet(), {
        config.agentServerNamed('Codex')!.persistenceIdentity,
        config.agentServerNamed('Pi')!.persistenceIdentity,
      });
    },
  );

  testWidgets(
    'AcpClientApp retries an unchanged session index after a save failure',
    (tester) async {
      final store = _FailOnceWorkspaceStateStore();
      final config = AcpClientConfig.fromJson({
        'default_agent_server': 'Codex',
        'agent_servers': {
          'Codex': {'type': 'custom', 'command': '/usr/local/bin/codex-acp'},
        },
      }, configPath: '/tmp/ianvs-acp/settings.json');

      await tester.pumpWidget(
        AcpClientApp(
          config: config,
          workspaceStateStore: store,
          discoverAgentServers: (_) => const <AgentServerConfig>[],
          createAgentClient: (_) =>
              FakeAgentClient(supportsListSessions: false),
        ),
      );
      await _pumpUntil(tester, () => store.saveAttempts >= 2);

      expect(store.successfulSaves, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _openSidebarSessionMenu(
  WidgetTester tester,
  ChatController controller,
) async {
  final title = controller.currentSession!.displayTitle;
  await _openSidebarSessionMenuForTitle(tester, title);
}

Future<void> _openSidebarSessionMenuForTitle(
  WidgetTester tester,
  String title,
) async {
  final sessionTitle = find.descendant(
    of: find.byType(WorkspaceSidebar),
    matching: find.text(title),
  );
  await _pumpUntil(tester, () => sessionTitle.evaluate().isNotEmpty);
  await tester.tapAt(
    tester.getCenter(sessionTitle.first),
    buttons: kSecondaryMouseButton,
  );
  await tester.pumpAndSettle();
}

Future<void> _openWorkspaceActions(
  WidgetTester tester,
  String workspacePath,
) async {
  final actions = find.byKey(
    ValueKey<String>('workspace-actions:$workspacePath'),
  );
  await _pumpUntil(tester, () => actions.evaluate().isNotEmpty);
  await tester.tap(actions);
  await tester.pumpAndSettle();
}

Future<void> _openWorkspaceResume(
  WidgetTester tester,
  String workspacePath,
) async {
  await _openWorkspaceActions(tester, workspacePath);
  await tester.tap(find.text('Resume Session'));
  await tester.pumpAndSettle();
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

Future<void> _selectResumeAgent(WidgetTester tester, String agentName) async {
  final agentList = find.byKey(const ValueKey('resume-agent-list'));
  final agent = find.descendant(of: agentList, matching: find.text(agentName));
  expect(agent, findsOneWidget);
  await tester.tap(agent);
  await tester.pumpAndSettle();
}

class _SameIdAcrossAgentsClient extends FakeAgentClient {
  _SameIdAcrossAgentsClient(this.agentName);

  final String agentName;
  int resumeCalls = 0;
  String? lastResumeSessionId;
  String? lastResumeWorkspace;

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) throw StateError('Fake client is not connected.');
    final isCodex = agentName == 'Codex';
    final workspace = isCodex ? '/workspace/codex-catalog' : '/workspace/pi';
    return <AcpProjectSessions>[
      AcpProjectSessions(
        cwd: workspace,
        sessions: <AcpSessionEntry>[
          AcpSessionEntry(
            id: 'shared-session',
            cwd: workspace,
            title: isCodex ? 'Codex shared session' : 'Pi shared session',
            meta: const <String, Object?>{'agentName': 'pi ACP'},
          ),
        ],
      ),
    ];
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    resumeCalls += 1;
    lastResumeSessionId = sessionId;
    lastResumeWorkspace = cwd;
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}

class _SharedAliasCatalogClient extends FakeAgentClient {
  _SharedAliasCatalogClient(this.agentName, this.workspacePath);

  final String agentName;
  final String workspacePath;
  int resumeCalls = 0;

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) throw StateError('Fake client is not connected.');
    return <AcpProjectSessions>[
      AcpProjectSessions(
        cwd: workspacePath,
        sessions: <AcpSessionEntry>[
          AcpSessionEntry(
            id: 'shared-alias-session',
            cwd: workspacePath,
            title: 'Shared alias session',
          ),
        ],
      ),
    ];
  }

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

class _TemplateAliasCatalogClient extends _CountingResumeAgentClient {
  _TemplateAliasCatalogClient({required this.sessionId, required this.cwd});

  final String sessionId;
  final String cwd;
  int listCalls = 0;

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) throw StateError('Fake client is not connected.');
    listCalls += 1;
    return <AcpProjectSessions>[
      AcpProjectSessions(
        cwd: cwd,
        sessions: <AcpSessionEntry>[
          AcpSessionEntry(
            id: sessionId,
            cwd: cwd,
            title: 'Catalog alias without a template marker',
          ),
        ],
      ),
    ];
  }
}

class _RemoteWorkspaceSessionClient extends FakeAgentClient {
  _RemoteWorkspaceSessionClient(this.agentName);

  final String agentName;
  int resumeCalls = 0;
  String? lastResumeSessionId;
  String? lastResumeWorkspace;
  List<String>? lastResumeAdditionalDirectories;

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) throw StateError('Fake client is not connected.');
    if (agentName != 'pi ACP') return const <AcpProjectSessions>[];
    return [
      AcpProjectSessions(
        cwd: '/workspace/pi',
        sessions: [
          AcpSessionEntry(
            id: 'remote-pi-session',
            cwd: '/workspace/pi',
            title: 'Remote Pi Session',
            additionalDirectories: const [
              '/workspace/shared-a',
              '/workspace/shared-b',
            ],
            meta: const {'agentName': 'pi ACP'},
          ),
        ],
      ),
    ];
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    resumeCalls += 1;
    lastResumeSessionId = sessionId;
    lastResumeWorkspace = cwd;
    lastResumeAdditionalDirectories = List.of(additionalDirectories);
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }

  void resetResumeTracking() {
    resumeCalls = 0;
    lastResumeSessionId = null;
    lastResumeWorkspace = null;
    lastResumeAdditionalDirectories = null;
  }
}

class _CountingResumeAgentClient extends FakeAgentClient {
  _CountingResumeAgentClient({super.resumeDelay});

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

class _ControlledDeepLinkResumeAgentClient extends FakeAgentClient {
  final Completer<void> _restoreStarted = Completer<void>();
  final Completer<void> _restoreGate = Completer<void>();
  int restoreCalls = 0;

  Future<void> get restoreStarted => _restoreStarted.future;

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    restoreCalls += 1;
    if (!_restoreStarted.isCompleted) _restoreStarted.complete();
    await _restoreGate.future;
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
}

class _WorkspaceCatalogAgentClient extends FakeAgentClient {
  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    if (!connected) {
      throw StateError('Fake client is not connected.');
    }
    return [
      AcpProjectSessions(
        cwd: '/workspace/project-b',
        sessions: [
          AcpSessionEntry(
            id: 'session-b',
            cwd: '/workspace/project-b',
            title: 'Project B session',
            updatedAt: DateTime(2026, 7, 6, 12),
          ),
        ],
      ),
      AcpProjectSessions(
        cwd: '/workspace/project-a',
        sessions: [
          AcpSessionEntry(
            id: 'session-a',
            cwd: '/workspace/project-a',
            title: 'Project A session',
            updatedAt: DateTime(2026, 7, 6, 11),
          ),
        ],
      ),
    ];
  }
}

class _ControllableListAgentClient extends FakeAgentClient {
  final Completer<void> _listReleased = Completer<void>();

  void releaseList() {
    if (!_listReleased.isCompleted) _listReleased.complete();
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    await _listReleased.future;
    return super.listSessions();
  }
}

class _ConcurrentPromptAgentClient extends FakeAgentClient {
  final Map<String, StreamController<AgentEvent>> _promptEvents =
      <String, StreamController<AgentEvent>>{};
  final Set<String> cancelledSessionIds = <String>{};
  bool disposed = false;

  @override
  bool get supportsConcurrentPrompts => true;

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    lastPrompt = prompt;
    lastAttachments = attachments;
    final events = StreamController<AgentEvent>();
    _promptEvents[sessionId] = events;
    return events.stream;
  }

  @override
  Future<void> cancel() async {
    if (_promptEvents.length != 1) {
      throw StateError('Expected exactly one active prompt.');
    }
    await cancelSession(sessionId: _promptEvents.keys.single);
  }

  @override
  Future<void> cancelSession({required String sessionId}) async {
    cancelledSessionIds.add(sessionId);
    final events = _promptEvents.remove(sessionId);
    if (events != null && !events.isClosed) await events.close();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    for (final events in _promptEvents.values.toList(growable: false)) {
      if (!events.isClosed) await events.close();
    }
    _promptEvents.clear();
    await super.dispose();
  }
}

class _LegacyHangingAgentClient extends FakeAgentClient {
  final StreamController<AgentEvent> _events = StreamController<AgentEvent>();

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    return _events.stream;
  }

  Future<void> finishPrompt() async {
    if (!_events.isClosed) await _events.close();
  }

  @override
  Future<void> dispose() async {
    await finishPrompt();
    await super.dispose();
  }
}

class _CatalogConcurrencyTracker {
  int active = 0;
  int maxActive = 0;
}

class _TrackingCatalogAgentClient extends FakeAgentClient {
  _TrackingCatalogAgentClient(this.tracker);

  final _CatalogConcurrencyTracker tracker;
  int listCalls = 0;

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    listCalls += 1;
    tracker.active += 1;
    if (tracker.active > tracker.maxActive) tracker.maxActive = tracker.active;
    try {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      return await super.listSessions();
    } finally {
      tracker.active -= 1;
    }
  }
}

class _TrackingHangingAgentClient extends FakeAgentClient {
  final StreamController<AgentEvent> _events =
      StreamController<AgentEvent>.broadcast();
  bool disposed = false;

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    lastPrompt = prompt;
    lastAttachments = attachments;
    return _events.stream;
  }

  @override
  Future<void> cancel() async {
    await super.cancel();
    if (!_events.isClosed) await _events.close();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    if (!_events.isClosed) await _events.close();
    await super.dispose();
  }
}

class _FailOnceWorkspaceStateStore extends WorkspaceSidebarStateStore {
  _FailOnceWorkspaceStateStore() : super(path: null);

  int saveAttempts = 0;
  int successfulSaves = 0;

  @override
  Future<List<AgentSession>> loadSessionIndex() async {
    return const <AgentSession>[];
  }

  @override
  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) async {
    saveAttempts += 1;
    if (saveAttempts == 1) {
      throw const FileSystemException('injected session index failure');
    }
    successfulSaves += 1;
  }
}

class _SessionIndexWorkspaceStateStore extends WorkspaceSidebarStateStore {
  _SessionIndexWorkspaceStateStore(this.initialSessions) : super(path: null);

  final List<AgentSession> initialSessions;
  List<AgentSession> lastSaved = const <AgentSession>[];

  @override
  Future<List<AgentSession>> loadSessionIndex() async => initialSessions;

  @override
  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) async {
    lastSaved = List<AgentSession>.unmodifiable(sessions);
  }
}

class _ReplacingHydrationWorkspaceStateStore
    extends WorkspaceSidebarStateStore {
  _ReplacingHydrationWorkspaceStateStore(this.sessions) : super(path: null);

  final List<AgentSession> sessions;
  final Completer<List<AgentSession>> _firstLoad =
      Completer<List<AgentSession>>();
  final Completer<List<AgentSession>> _replacementLoad =
      Completer<List<AgentSession>>();
  int loadCalls = 0;

  @override
  Future<List<AgentSession>> loadSessionIndex() {
    loadCalls += 1;
    if (loadCalls == 1) return _firstLoad.future;
    if (loadCalls == 2) return _replacementLoad.future;
    return Future<List<AgentSession>>.value(sessions);
  }

  void failFirstLoad() {
    _firstLoad.completeError(
      const FileSystemException('obsolete hydration failure'),
    );
  }

  void completeReplacementLoad() {
    _replacementLoad.complete(sessions);
  }
}
