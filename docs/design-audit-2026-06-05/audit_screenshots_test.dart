import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/ui/components/session_time_label.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

import 'audit_fixture.dart';

void main() {
  setUpAll(() async {
    Future<ByteData> fontData(String path) async =>
        ByteData.sublistView(await File(path).readAsBytes());
    var flutterRoot = File(Platform.resolvedExecutable).parent;
    while (!Directory(
      '${flutterRoot.path}/bin/cache/artifacts/material_fonts',
    ).existsSync()) {
      final parent = flutterRoot.parent;
      if (parent.path == flutterRoot.path) {
        throw StateError('Unable to locate the Flutter SDK font cache.');
      }
      flutterRoot = parent;
    }

    // Keep the audit renderer deterministic while covering every visible
    // surface. One sans face is deliberately synthesized across 400/500/600;
    // loading a second face into the same test family caused dialog text to
    // rasterize as solid blocks. Arial Unicode supplies the Chinese fallback,
    // and Material Icons prevents icon-codepoint tofu squares.
    final sans = FontLoader(AppTypography.family)
      ..addFont(fontData('/System/Library/Fonts/Supplemental/Arial.ttf'));
    final cjk = FontLoader('PingFang SC')
      ..addFont(fontData('/System/Library/Fonts/Hiragino Sans GB.ttc'));
    final mono = FontLoader(AppTypography.monoFamily)
      ..addFont(
        fontData(
          '${flutterRoot.path}/bin/cache/dart-sdk/bin/resources/devtools/'
          'assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
        ),
      );
    final monoFallback = FontLoader('Menlo')
      ..addFont(
        fontData(
          '${flutterRoot.path}/bin/cache/dart-sdk/bin/resources/devtools/'
          'assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
        ),
      );
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        fontData(
          '${flutterRoot.path}/bin/cache/artifacts/material_fonts/'
          'MaterialIcons-Regular.otf',
        ),
      );
    await Future.wait([
      sans.load(),
      cjk.load(),
      mono.load(),
      monoFallback.load(),
      icons.load(),
    ]);
    debugSessionTimeNow = () => DateTime(2026, 7, 8, 12);
  });

  tearDownAll(() {
    debugSessionTimeNow = null;
  });

  Future<AuditFixture> pumpScenario(
    WidgetTester tester,
    String scenario, {
    Size size = const Size(1440, 900),
    String? startupError,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final fixture = await createAuditFixture(scenario);
    addTearDown(fixture.dispose);
    await tester.pumpWidget(fixture.app(startupError: startupError));
    await tester.pumpAndSettle();
    return fixture;
  }

  Future<void> capture(String name) async {
    await expectLater(
      find.byType(AcpClientApp),
      matchesGoldenFile('screenshots/$name.png'),
    );
  }

  testWidgets('01 empty desktop state', (tester) async {
    await pumpScenario(tester, 'empty');
    await capture('01-empty-desktop');
  });

  testWidgets('02 new session dialog', (tester) async {
    await pumpScenario(tester, 'empty');
    await tester.tap(find.widgetWithText(FilledButton, 'New Session').last);
    await tester.pumpAndSettle();
    await capture('02-new-session-dialog');
  });

  testWidgets('03 active conversation', (tester) async {
    await pumpScenario(tester, 'active');
    await capture('03-active-conversation');
  });

  testWidgets('04 agent menu', (tester) async {
    await pumpScenario(tester, 'active');
    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await capture('04-agent-menu');
  });

  testWidgets('05 resume dialog', (tester) async {
    await pumpScenario(tester, 'active');
    await tester.tap(find.byTooltip('Resume'));
    await tester.pumpAndSettle();
    await capture('05-resume-dialog');
  });

  testWidgets('06 session settings dialog', (tester) async {
    await pumpScenario(tester, 'active');
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Session settings'));
    await tester.pumpAndSettle();
    await capture('06-session-settings-dialog');
  });

  testWidgets('07 capabilities dialog', (tester) async {
    await pumpScenario(tester, 'active');
    await tester.tap(find.text('Context'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnostics'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ACP compatibility'));
    await tester.pumpAndSettle();
    await capture('07-capabilities-dialog');
  });

  testWidgets('08 permission request state', (tester) async {
    await pumpScenario(tester, 'permission');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await capture('08-permission-request');
  });

  testWidgets('09 startup error state', (tester) async {
    await pumpScenario(
      tester,
      'empty',
      startupError: 'Could not load ACP config: unexpected trailing comma',
    );
    await capture('09-startup-error');
  });

  testWidgets('10 narrow width state', (tester) async {
    await pumpScenario(tester, 'active', size: const Size(390, 844));
    for (var index = 0; index < 10; index += 1) {
      if (tester.takeException() == null) break;
    }
    await capture('10-narrow-width');
  });
}
