import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/connection_state.dart';
import 'package:ianvs_acp/state/workspace_controller.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void main() {
  testWidgets('new session shows handshake and creation loading until ready', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(
        connectDelay: const Duration(seconds: 1),
        createSessionDelay: const Duration(seconds: 1),
      ),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final stages = <NewSessionStage>{};
    controller.addListener(() {
      if (controller.newSessionStage case final stage?) stages.add(stage);
    });
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    final operation = controller.newSession();
    await tester.pump();
    expect(find.text(NewSessionStage.connecting.label), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(NewSessionStage.creating.label), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(await operation, isTrue);
    await tester.pumpAndSettle();
    expect(controller.newSessionStage, isNull);
    expect(
      stages,
      containsAll([
        NewSessionStage.connecting,
        NewSessionStage.creating,
        NewSessionStage.configuring,
      ]),
    );
    expect(find.text(NewSessionStage.creating.label), findsNothing);
    expect(controller.currentSession, isNotNull);
    expect(
      WorkspaceController(
        controllers: [controller],
        currentWorkspacePath: '/workspace',
      ).currentWorkspace.sessions,
      isEmpty,
    );
  });

  test(
    'empty sessions stay hidden through notifications and show on prompt',
    () async {
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      final workspace = WorkspaceController(
        controllers: [controller],
        currentWorkspacePath: '/workspace',
      );
      final visibleWhileCreating = <String>[];
      void observe() {
        visibleWhileCreating.addAll(
          workspace.currentWorkspace.sessions.map((s) => s.id),
        );
      }

      controller.addListener(observe);
      await controller.newSession();
      controller.removeListener(observe);
      expect(visibleWhileCreating, isEmpty);
      final session = controller.currentSession!;
      expect(
        WorkspaceController(
          controllers: [controller],
          currentWorkspacePath: '/workspace',
          includeUnstarted: true,
        ).currentWorkspace.sessions.single.localUnstarted,
        isTrue,
      );
      // A shared catalog may still report the same session without the local flag.
      final catalog = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(catalog.dispose);
      catalog.sessions.add(session.copyWith(localUnstarted: false));
      expect(
        WorkspaceController(
          controllers: [controller, catalog],
          currentWorkspacePath: '/workspace',
        ).currentWorkspace.sessions,
        isEmpty,
      );
      await controller.sendPrompt('Hello');
      expect(workspace.currentWorkspace.sessions.single.id, session.id);
      expect(controller.currentSession!.localUnstarted, isFalse);
      catalog.sessions[0] = session;
      expect(
        WorkspaceController(
          controllers: [controller, catalog],
          currentWorkspacePath: '/workspace',
        ).currentWorkspace.sessions.single.id,
        session.id,
      );
    },
  );

  for (final connectionFailure in [true, false]) {
    test(
      'new session clears loading after ${connectionFailure ? 'connection' : 'creation'} failure',
      () async {
        final controller = ChatController(
          client: FakeAgentClient(
            connectError: connectionFailure
                ? StateError('connection failed')
                : null,
            createSessionError: connectionFailure
                ? null
                : StateError('creation failed'),
          ),
          cwd: '/workspace',
        );
        addTearDown(controller.dispose);
        expect(await controller.newSession(), isFalse);
        expect(controller.newSessionStage, isNull);
        expect(controller.isSessionOperationRunning, isFalse);
        expect(controller.status, ConnectionStatus.error);
      },
    );
  }
}
