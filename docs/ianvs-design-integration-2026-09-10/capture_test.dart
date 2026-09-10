import 'dart:io';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import '../settings-redesign-2026-09-09/fixture.dart';

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
    testWidgets(
      'shared design ${brightness.name} at desktop and narrow widths',
      (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1440, 1024);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(settingsFixtureApp());
        await tester.pumpAndSettle();
        Future<void> capture(String scene) async {
          expect(tester.takeException(), isNull, reason: scene);
          await expectLater(
            find.byType(AcpClientApp),
            matchesGoldenFile('screenshots/${brightness.name}-$scene.png'),
          );
        }

        await capture('workspace');
        await tester.tap(find.byTooltip('Agents'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('管理 Agent…'));
        await tester.pumpAndSettle();
        await capture('settings');
        await tester.tap(find.byKey(const Key('settings-section-permissions')));
        await tester.pumpAndSettle();
        await capture('permissions');
        tester.view.physicalSize = const Size(600, 850);
        await tester.pumpAndSettle();
        await capture('narrow');
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        await tester.pumpAndSettle();
        await capture('large-text');
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }
}
