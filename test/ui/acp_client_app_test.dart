import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_inbox_sqlite_store.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';

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
    expect(find.text('Codex'), findsOneWidget);

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

  testWidgets(
    'AcpClientApp asks for an agent before starting sessions without config',
    (tester) async {
      await pumpWithWindowSize(
        tester,
        const AcpClientApp(
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

  testWidgets('AcpClientApp creates Inbox tasks without configured agents', (
    tester,
  ) async {
    final taskController = TaskInboxController(
      store: _MemoryTaskStore(),
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: (_) => 'task-1',
    );
    addTearDown(taskController.dispose);
    await taskController.load();

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: const AcpClientConfig(),
        autoLoadWorkspaceSessions: false,
        taskInboxController: taskController,
      ),
      const Size(1400, 900),
    );

    await tester.tap(find.text('Inbox').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New task'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('task-title-field')),
      'Round2 no-agent task',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(taskController.tasks.single.title, 'Round2 no-agent task');
    expect(taskController.tasks.single.agentName, 'Codex');
  });

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

  testWidgets('AcpClientApp shows startup config errors without crashing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const AcpClientApp(startupError: 'Could not load ACP config: bad json'),
    );

    expect(find.textContaining('bad json'), findsOneWidget);
    expect(find.text('ACP Client'), findsOneWidget);
  });

  testWidgets('AcpClientApp migrates legacy tasks before enabling Inbox', (
    tester,
  ) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('acp-app-migration-'),
    ))!;
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final configPath = '${temp.path}/settings.json';
    final source = File('${temp.path}/task_inbox_state.json');
    final createdAt = DateTime.utc(2026, 7, 10, 9);
    final snapshot = TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [
        TaskRecord(
          id: 'legacy-task',
          title: 'Legacy task survived',
          description: 'Migrate before scheduling.',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ],
    );
    await tester.runAsync(
      () => source.writeAsString(jsonEncode(snapshot.toJson())),
    );

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: AcpClientConfig(configPath: configPath),
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) async => const <AgentServerConfig>[],
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(tester, () => !source.existsSync());
    await _pumpUntil(tester, () => find.text('Inbox').evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    expect(find.text('Inbox'), findsOneWidget);
    await tester.tap(find.text('Inbox'));
    await tester.pumpAndSettle();
    expect(find.text('Legacy task survived'), findsOneWidget);
    expect(source.existsSync(), isFalse);
    expect(
      temp.listSync().any(
        (entity) => entity is File && entity.path.contains('.migrated.'),
      ),
      isTrue,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
  });

  testWidgets('AcpClientApp keeps Inbox disabled when migration fails', (
    tester,
  ) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('acp-app-migration-'),
    ))!;
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final configPath = '${temp.path}/settings.json';
    final source = File('${temp.path}/task_inbox_state.json');
    await tester.runAsync(() => source.writeAsString('{broken'));

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        config: AcpClientConfig(configPath: configPath),
        autoLoadWorkspaceSessions: false,
        discoverAgentServers: (_) async => const <AgentServerConfig>[],
      ),
      const Size(1400, 900),
    );
    await _pumpUntil(
      tester,
      () => File('${temp.path}/task_inbox_state.sqlite3').existsSync(),
    );
    await _pumpUntil(
      tester,
      () => find
          .textContaining('Could not initialize Task Inbox')
          .evaluate()
          .isNotEmpty,
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Could not initialize Task Inbox'),
      findsOneWidget,
    );
    expect(find.text('Inbox'), findsNothing);
    expect(source.readAsStringSync(), '{broken');

    await tester.pumpWidget(const SizedBox.shrink());
    final repository = TaskInboxSqliteStore(
      path: '${temp.path}/task_inbox_state.sqlite3',
    );
    addTearDown(repository.close);
    expect(await tester.runAsync(repository.isActive), isFalse);
  });

  testWidgets('AcpClientApp waits for injected scheduler startup', (
    tester,
  ) async {
    final store = _FailingSecondLoadTaskStore();
    final taskController = TaskInboxController(store: store);
    addTearDown(taskController.dispose);
    await taskController.load();

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        autoLoadWorkspaceSessions: false,
        taskInboxController: taskController,
      ),
      const Size(1400, 900),
    );

    expect(
      find.textContaining('Could not initialize Task Inbox'),
      findsOneWidget,
    );
    expect(find.text('Inbox'), findsNothing);
  });

  testWidgets('AcpClientApp drains tasks before replacing configured agents', (
    tester,
  ) async {
    final createdAt = DateTime(2026, 7, 10, 9);
    final taskController = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [
            TaskRecord(
              id: 'queued-task',
              title: 'Long-running task',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.queued,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ],
        ),
      ),
    );
    addTearDown(taskController.dispose);
    final clients = <_TrackingHangingAgentClient>[];
    AcpClientConfig config(String version) => AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/codex',
          'args': [version],
        },
      },
    });
    AcpClientApp app(String version) => AcpClientApp(
      key: const ValueKey('config-replacement-app'),
      config: config(version),
      autoLoadWorkspaceSessions: false,
      taskInboxController: taskController,
      createAgentClient: (_) {
        final client = _TrackingHangingAgentClient();
        clients.add(client);
        return client;
      },
    );

    await tester.pumpWidget(app('v1'));
    await _pumpUntil(
      tester,
      () => clients.isNotEmpty && clients.first.lastPrompt != null,
    );
    final oldClient = clients.single;

    await tester.pumpWidget(app('v2'));
    await _pumpUntil(
      tester,
      () =>
          oldClient.cancelled &&
          oldClient.disposed &&
          taskController.taskById('queued-task')?.status == TaskStatus.failed,
    );

    expect(oldClient.cancelled, isTrue);
    expect(oldClient.disposed, isTrue);
    expect(
      taskController.taskById('queued-task')?.error,
      contains('cancelled'),
    );
    expect(clients.length, 2);
  });

  testWidgets('AcpClientApp serializes config changes during task startup', (
    tester,
  ) async {
    final store = _BlockingFirstLoadTaskStore();
    final taskController = TaskInboxController(store: store);
    addTearDown(taskController.dispose);
    AcpClientConfig config(String version) => AcpClientConfig.fromJson({
      'default_agent_server': 'Codex',
      'agent_servers': {
        'Codex': {
          'type': 'custom',
          'command': '/usr/local/bin/codex',
          'args': [version],
        },
      },
    });
    AcpClientApp app(String version) => AcpClientApp(
      key: const ValueKey('serial-config-app'),
      config: config(version),
      autoLoadWorkspaceSessions: false,
      taskInboxController: taskController,
      createAgentClient: (_) => FakeAgentClient(),
    );

    await tester.pumpWidget(app('v1'));
    await store.firstLoadStarted.future;
    await tester.pumpWidget(app('v2'));
    await tester.pumpWidget(app('v3'));
    await tester.pump();

    expect(store.loadCount, 1);
    expect(store.maxConcurrentLoads, 1);

    store.releaseFirstLoad();
    await _pumpUntil(
      tester,
      () => store.loadCount == 2 && find.text('Inbox').evaluate().isNotEmpty,
    );

    expect(store.maxConcurrentLoads, 1);
  });

  testWidgets('AcpClientApp reopens a pending task after migration retry', (
    tester,
  ) async {
    final temp = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('acp-app-migration-retry-'),
    ))!;
    addTearDown(() {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    });
    final configPath = '${temp.path}/settings.json';
    final source = File('${temp.path}/task_inbox_state.json');
    await tester.runAsync(() => source.writeAsString('{broken'));
    AcpClientApp app() => AcpClientApp(
      key: const ValueKey('migration-retry-app'),
      config: AcpClientConfig(configPath: configPath),
      autoLoadWorkspaceSessions: false,
      initialTaskId: 'legacy-task',
      discoverAgentServers: (_) async => const <AgentServerConfig>[],
    );

    await pumpWithWindowSize(tester, app(), const Size(1400, 900));
    await _pumpUntil(
      tester,
      () => find
          .textContaining('Could not initialize Task Inbox')
          .evaluate()
          .isNotEmpty,
    );
    final createdAt = DateTime.utc(2026, 7, 10, 9);
    final snapshot = TaskInboxSnapshot(
      updatedAt: createdAt,
      tasks: [
        TaskRecord(
          id: 'legacy-task',
          title: 'Retry migration task',
          description: '',
          workspacePath: '/workspace/app',
          agentName: 'Codex',
          status: TaskStatus.inbox,
          priority: TaskPriority.normal,
          createdAt: createdAt,
          updatedAt: createdAt,
        ),
      ],
    );
    await tester.runAsync(
      () => source.writeAsString(jsonEncode(snapshot.toJson())),
    );

    await tester.pumpWidget(app());
    await _pumpUntil(tester, () => !source.existsSync());
    await _pumpUntil(
      tester,
      () => find.text('Retry migration task').evaluate().isNotEmpty,
    );

    expect(find.text('Retry migration task'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
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

  testWidgets(
    'AcpClientApp acknowledges runtime session deep links before resume finishes',
    (tester) async {
      const deepLinkChannel = MethodChannel('ianvs_acp/deep_links');
      final fake = FakeAgentClient(
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
        ),
      );
      await tester.pumpAndSettle();

      var platformMessageReplied = false;
      final replyFuture = tester.binding.defaultBinaryMessenger
          .handlePlatformMessage(
            deepLinkChannel.name,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall(
                'openDeepLink',
                'ianvs-acp://session?id=session-runtime&cwd=/workspace/runtime',
              ),
            ),
            null,
          )
          .then((_) => platformMessageReplied = true);
      await tester.pump();

      expect(platformMessageReplied, isTrue);
      await replyFuture;
      await tester.pump();

      expect(find.text('Loading session'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();

      expect(fake.lastResumeCwd, '/workspace/runtime');
      expect(find.text('Loading session'), findsNothing);
    },
  );

  testWidgets('AcpClientApp opens task review deep links in the Inbox', (
    tester,
  ) async {
    const deepLinkChannel = MethodChannel('ianvs_acp/deep_links');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      deepLinkChannel,
      (call) async {
        if (call.method == 'getInitialDeepLinks') {
          return <Object?>['ianvs-acp://task-review?id=task-review-1'];
        }
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        deepLinkChannel,
        null,
      );
    });

    final taskController = TaskInboxController(
      store: _MemoryTaskStore(
        TaskInboxSnapshot(
          updatedAt: DateTime(2026, 7, 7, 9),
          tasks: [
            TaskRecord(
              id: 'task-review-1',
              title: 'Review from deep link',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.needsHumanReview,
              priority: TaskPriority.normal,
              createdAt: DateTime(2026, 7, 7, 8),
              updatedAt: DateTime(2026, 7, 7, 9),
            ),
          ],
        ),
      ),
    );
    addTearDown(taskController.dispose);
    await taskController.load();

    await pumpWithWindowSize(
      tester,
      AcpClientApp(
        taskInboxController: taskController,
        autoLoadWorkspaceSessions: false,
      ),
      const Size(1400, 900),
    );

    expect(find.text('Review from deep link'), findsWidgets);
    expect(find.text('Needs Review'), findsOneWidget);
    expect(find.byKey(const Key('task-approve-export-button')), findsNothing);
    expect(
      find.byKey(const Key('task-mark-done-locally-button')),
      findsOneWidget,
    );
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
      AcpClientApp(controller: controller),
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

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
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

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Working Directory'));
    await tester.pump();

    expect(clipboardText, '/workspace/current');
    expect(find.text('Working directory copied.'), findsOneWidget);

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy Session ID'));
    await tester.pump();

    expect(clipboardText, sessionId);

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as Unread'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .unread,
      isTrue,
    );

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
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
    await controller.newSession(cwd: '/workspace/current');
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

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in New Window'));
    await tester.pumpAndSettle();

    expect(openedArgs, [
      '--resume-session-id',
      sessionId,
      '--resume-cwd',
      '/workspace/current',
      '--resume-agent',
      'Codex',
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

    expect(controller.currentSession?.id, 'other-session');
    expect(
      controller.sessions
          .singleWhere((session) => session.id == 'other-session')
          .unread,
      isFalse,
    );
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

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
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

  testWidgets('AcpClientApp opens session worktree fork dialog from menu', (
    tester,
  ) async {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace/current');
    addTearDown(controller.dispose);
    await controller.newSession(cwd: '/workspace/current');

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fork to New Worktree'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Fork to New Worktree'), findsOneWidget);
    expect(find.text('/workspace/current-fake-ses-fork'), findsOneWidget);
    expect(fake.lastForkedSessionId, isNull);
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

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin Conversation'));
    await tester.pumpAndSettle();

    expect(
      controller.sessions
          .singleWhere((session) => session.id == sessionId)
          .pinned,
      isTrue,
    );

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
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

    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
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
    final sessionId = controller.currentSession!.id;
    controller.setSessionUnread(sessionId, true);

    await pumpWithWindowSize(
      tester,
      AcpClientApp(controller: controller),
      const Size(1400, 900),
    );

    await tester.tap(find.byTooltip('Workspace actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Archive Conversations'));
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
    await tester.tap(find.text('GPT-5 Mini'));
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
    await tester.tap(find.text('High'));
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
    await tester.pump();
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

class _TrackingHangingAgentClient extends FakeAgentClient {
  final StreamController<AgentEvent> _events = StreamController<AgentEvent>();
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
  Future<void> dispose() async {
    disposed = true;
    if (!_events.isClosed) await _events.close();
    await super.dispose();
  }
}

class _MemoryTaskStore implements TaskStore {
  _MemoryTaskStore([TaskInboxSnapshot? snapshot])
    : _snapshot = snapshot ?? TaskInboxSnapshot.empty();

  TaskInboxSnapshot _snapshot;

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}

class _FailingSecondLoadTaskStore implements TaskStore {
  int loadCount = 0;

  @override
  Future<TaskInboxSnapshot> load() async {
    loadCount += 1;
    if (loadCount > 1) throw StateError('scheduler startup failed');
    return TaskInboxSnapshot.empty();
  }

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {}
}

class _BlockingFirstLoadTaskStore implements TaskStore {
  final Completer<void> firstLoadStarted = Completer<void>();
  final Completer<void> _firstLoadReleased = Completer<void>();
  int loadCount = 0;
  int activeLoads = 0;
  int maxConcurrentLoads = 0;

  @override
  Future<TaskInboxSnapshot> load() async {
    loadCount += 1;
    activeLoads += 1;
    if (activeLoads > maxConcurrentLoads) maxConcurrentLoads = activeLoads;
    try {
      if (loadCount == 1) {
        firstLoadStarted.complete();
        await _firstLoadReleased.future;
      }
      return TaskInboxSnapshot.empty();
    } finally {
      activeLoads -= 1;
    }
  }

  void releaseFirstLoad() {
    if (!_firstLoadReleased.isCompleted) _firstLoadReleased.complete();
  }

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {}
}
