import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_agent_chat/ui/components/accessible_text_field.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

void main() {
  testWidgets('sidebar toggles and resizes without losing the prompt draft', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace',
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(home: AppShell(controller: controller)),
    );
    await tester.pumpAndSettle();
    final field = find
        .descendant(
          of: find.byType(AccessibleTextField),
          matching: find.byType(TextField),
        )
        .last;
    await tester.enterText(field, 'Keep my draft');
    await tester.tap(find.byKey(const Key('compact-workspaces-button')));
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceSidebar), findsNothing);
    expect(find.text('Keep my draft'), findsOneWidget);
    await tester.tap(field);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceSidebar), findsOneWidget);
    expect(find.text('Keep my draft'), findsOneWidget);
    await tester.drag(
      find.byKey(const Key('sidebar-resize-handle')),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(WorkspaceSidebar)).width,
      greaterThan(260),
    );
    tester.view.physicalSize = const Size(760, 560);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceSidebar), findsNothing);
    expect(find.text('Keep my draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
