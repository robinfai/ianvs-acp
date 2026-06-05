import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';

import 'audit_fixture.dart';

void main() {
  setUpAll(() async {
    final regular = await File(
      '/System/Library/Fonts/Supplemental/Arial.ttf',
    ).readAsBytes();
    final bold = await File(
      '/System/Library/Fonts/Supplemental/Arial Bold.ttf',
    ).readAsBytes();
    final loader = FontLoader('SF Pro Display')
      ..addFont(Future<ByteData>.value(ByteData.sublistView(regular)))
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bold)));
    await loader.load();
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
    await tester.tap(find.byTooltip('Session settings'));
    await tester.pumpAndSettle();
    await capture('06-session-settings-dialog');
  });

  testWidgets('07 capabilities dialog', (tester) async {
    await pumpScenario(tester, 'active');
    await tester.tap(find.byTooltip('ACP compatibility'));
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
