import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/agent_config_dialog.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_acp/ui/shell/macos_workspace_layout.dart';
import 'package:ianvs_agent_chat/ui/components/accessible_text_field.dart';
import 'package:ianvs_design/ianvs_design.dart';

void main() {
  testWidgets(
    'mouse resize releases its blue highlight without another click',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: IanvsTheme.light().copyWith(platform: TargetPlatform.macOS),
          home: AppShell(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final handle = find.byKey(const Key('sidebar-resize-handle'));
      final line = find.descendant(
        of: handle,
        matching: find.byType(ColoredBox),
      );
      final tokens = tester.element(handle).ianvs;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      final start = tester.getCenter(handle);
      await mouse.addPointer(location: start);
      await mouse.down(start);
      await mouse.moveBy(const Offset(20, 0));
      await mouse.moveBy(const Offset(20, 0));
      await tester.pumpAndSettle();
      expect(
        tester.getSize(find.byType(WorkspaceSidebar)).width,
        greaterThan(260),
      );
      await mouse.up();
      await tester.pumpAndSettle();
      expect(tester.widget<ColoredBox>(line).color, isNot(tokens.focus));
      expect(tester.getSize(line).width, 1);
      await mouse.moveTo(const Offset(900, 300));
      await tester.pumpAndSettle();
      expect(tester.widget<ColoredBox>(line).color, tokens.separator);

      // The same control still offers visible feedback when using the keyboard.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<ColoredBox>(line).color, tokens.focus);
      expect(tester.getSize(line).width, 2);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

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
    void expectFlushSidebarEdge() {
      final sidebar = tester.getRect(find.byType(WorkspaceSidebar));
      final workspace = tester.getRect(
        find.byKey(const ValueKey('conversation-workspace')),
      );
      final handle = tester.getRect(
        find.byKey(const Key('sidebar-resize-handle')),
      );
      expect(workspace.left, sidebar.right);
      expect(handle.center.dx, sidebar.right);
      expect(handle.width, greaterThanOrEqualTo(8));
    }

    expectFlushSidebarEdge();
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
    expectFlushSidebarEdge();
    await tester.dragFrom(
      tester.getCenter(find.byKey(const Key('sidebar-resize-handle'))) +
          const Offset(3, 0),
      const Offset(40, 0),
    );
    await tester.pumpAndSettle();
    final resizedWidth = tester.getSize(find.byType(WorkspaceSidebar)).width;
    expect(resizedWidth, greaterThan(260));
    expectFlushSidebarEdge();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(WorkspaceSidebar)).width,
      resizedWidth - 20,
    );
    expectFlushSidebarEdge();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(WorkspaceSidebar)).width, 260);
    expectFlushSidebarEdge();
    tester.view.physicalSize = const Size(760, 560);
    await tester.pumpAndSettle();
    expect(find.byType(WorkspaceSidebar), findsNothing);
    expect(find.text('Keep my draft'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native menu and Command-comma share the settings route guard', (
    tester,
  ) async {
    final settingsClosed = Completer<void>();
    var opens = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MacosWorkspaceLayout(
          builder: (context, constraints, layout) {
            layout.onSettingsMenu = () {
              opens += 1;
              return settingsClosed.future;
            };
            return const Focus(autofocus: true, child: SizedBox.expand());
          },
        ),
      ),
    );
    await tester.pump();

    Future<void> pressSettingsShortcut() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'com.ianvs.acp/workspace-layout',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('openSettings'),
      ),
      (_) {},
    );
    await tester.pump();
    await pressSettingsShortcut();
    expect(opens, 1);

    settingsClosed.complete();
    await tester.pump();

    await pressSettingsShortcut();
    expect(opens, 2);
  });

  testWidgets('replacement layout keeps the newest native channel handler', (
    tester,
  ) async {
    var firstOpens = 0;
    var secondOpens = 0;

    Widget app(Key key, VoidCallback onOpen) => MaterialApp(
      home: MacosWorkspaceLayout(
        key: key,
        builder: (context, constraints, layout) {
          layout.onSettingsMenu = () async => onOpen();
          return const SizedBox.expand();
        },
      ),
    );

    await tester.pumpWidget(
      app(const ValueKey('first-layout'), () => firstOpens += 1),
    );
    await tester.pumpWidget(
      app(const ValueKey('second-layout'), () => secondOpens += 1),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'com.ianvs.acp/workspace-layout',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('openSettings'),
      ),
      (_) {},
    );
    await tester.pump();

    expect(firstOpens, 0);
    expect(secondOpens, 1);
  });

  testWidgets('sidebar settings blocks native menu and shortcut duplicates', (
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
    final observer = _SettingsRouteObserver();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        navigatorObservers: [observer],
        home: AppShell(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(AgentConfigDialog), findsOneWidget);
    expect(observer.settingsPushes, 1);

    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'com.ianvs.acp/workspace-layout',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('openSettings'),
      ),
      (_) {},
    );
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pumpAndSettle();

    expect(find.byType(AgentConfigDialog), findsOneWidget);
    expect(observer.settingsPushes, 1);
  });
}

class _SettingsRouteObserver extends NavigatorObserver {
  int settingsPushes = 0;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    if (route.settings.name == '/settings') settingsPushes += 1;
  }
}
