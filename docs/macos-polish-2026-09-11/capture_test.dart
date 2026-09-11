import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:ianvs_acp/app.dart';
import '../settings-redesign-2026-09-09/fixture.dart';
import 'fixture.dart';

// Supplementary layout captures use fallback fonts. Native CUA captures are
// authoritative for macOS font rendering and window chrome.
void main() {
  setUpAll(() async {
    Future<ByteData> bytes(String path) async =>
        ByteData.sublistView(await File(path).readAsBytes());
    var sdk = File(Platform.resolvedExecutable).parent;
    while (!Directory(
      '${sdk.path}/bin/cache/artifacts/material_fonts',
    ).existsSync()) {
      if (sdk.parent.path == sdk.path) {
        throw StateError('Flutter font cache missing');
      }
      sdk = sdk.parent;
    }
    final sans = bytes('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    final mono = bytes(
      '${sdk.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
    );
    await Future.wait([
      for (final name in ['.AppleSystemUIFont', 'Arial', 'PingFang SC'])
        (FontLoader(name)..addFont(sans)).load(),
      for (final name in ['Menlo', 'monospace'])
        (FontLoader(name)..addFont(mono)).load(),
      (FontLoader('MaterialIcons')..addFont(
            bytes(
              '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ))
          .load(),
    ]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('macOS polish ${brightness.name} settings and chat layouts', (
      tester,
    ) async {
      tester.platformDispatcher.platformBrightnessTestValue = brightness;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1440, 1024);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      Future<void> capture(String scene) async {
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: scene);
        await expectLater(
          find.byType(AcpClientApp),
          matchesGoldenFile('layout-checks/${brightness.name}-$scene.png'),
        );
      }

      await tester.pumpWidget(settingsFixtureApp());
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Agents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('管理 Agent…'));
      await capture('settings-agent');
      for (final section in ['tools', 'permissions', 'assistant', 'storage']) {
        await tester.tap(find.byKey(Key('settings-section-$section')));
        await capture('settings-$section');
      }
      await tester.tap(find.byKey(const Key('settings-section-permissions')));
      tester.view.physicalSize = const Size(600, 850);
      await capture('settings-narrow');
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await capture('settings-large-text');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
      tester.view.physicalSize = const Size(1440, 1024);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpWidget(await polishFixtureApp());
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('tool-activity-toggle-tool-1')),
      );
      await capture('chat-tool-output');
      if (find.byTooltip('打开会话参数').evaluate().isEmpty) {
        await tester.tap(find.byTooltip('Show Context (⌘⌥I)'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('打开会话参数'));
      await capture('session-settings');
      tester.view.physicalSize = const Size(600, 850);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await capture('session-settings-large-text');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(1440, 1024);
      tester.platformDispatcher.textScaleFactorTestValue = 1;
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看会话详情'));
      await capture('session-details');
      await tester.tap(find.byTooltip('关闭会话详情'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('活动与诊断'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Runtime'));
      await capture('runtime');
      tester.view.physicalSize = const Size(600, 850);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await capture('runtime-large-text');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });
  }
}
