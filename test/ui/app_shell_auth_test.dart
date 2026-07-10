import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

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

  testWidgets('AppShell authenticates advertised method from agent menu', (
    tester,
  ) async {
    final fake = FakeAgentClient(
      authMethods: const [
        {
          'id': 'browser',
          'name': 'Browser sign-in',
          'description': 'Continue in the agent browser flow.',
        },
      ],
    );
    final controller = ChatController(client: fake, cwd: '/workspace');
    addTearDown(controller.dispose);

    await controller.connect();
    String? authenticatedAgent;
    String? authenticatedMethod;
    await tester.pumpWidget(
      MaterialApp(
        home: AppShell(
          controller: controller,
          onAgentAuthenticated: (agentName, methodId) {
            authenticatedAgent = agentName;
            authenticatedMethod = methodId;
          },
        ),
      ),
    );

    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Authenticate'));
    await tester.pumpAndSettle();

    expect(fake.lastAuthenticatedMethodId, 'browser');
    expect(authenticatedAgent, 'Codex');
    expect(authenticatedMethod, 'browser');
    expect(controller.lastError, isNull);
  });

  testWidgets('AppShell reveals workspaces in the platform file browser', (
    tester,
  ) async {
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/current',
    );
    addTearDown(controller.dispose);
    final processCalls = <({String executable, List<String> arguments})>[];

    await pumpWithWindowSize(
      tester,
      MaterialApp(
        home: AppShell(
          controller: controller,
          processRunner: (executable, arguments) async {
            processCalls.add((executable: executable, arguments: arguments));
            return ProcessResult(0, 0, '', '');
          },
        ),
      ),
      const Size(1400, 900),
    );

    await tester.tap(
      find.byKey(const ValueKey<String>('workspace-actions:/workspace/current')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Show in Finder'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(processCalls, hasLength(1));
    if (Platform.isMacOS) {
      expect(processCalls.single.executable, 'open');
      expect(processCalls.single.arguments, ['/workspace/current']);
    } else if (Platform.isWindows) {
      expect(processCalls.single.executable, 'explorer');
      expect(processCalls.single.arguments, ['/workspace/current']);
    } else {
      expect(processCalls.single.executable, 'xdg-open');
      expect(processCalls.single.arguments, ['/workspace/current']);
    }
  });
}
