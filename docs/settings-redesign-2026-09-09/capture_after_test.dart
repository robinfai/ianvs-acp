import 'dart:io';

import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';

import 'fixture.dart';

final _captureTheme = IanvsTheme.build(platform: TargetPlatform.macOS);

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
    await Future.wait([
      (FontLoader(_captureTheme.textTheme.bodyMedium!.fontFamily!)..addFont(
            bytes('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
          ))
          .load(),
      (FontLoader('PingFang SC')..addFont(
            bytes('/System/Library/Fonts/Supplemental/Arial Unicode.ttf'),
          ))
          .load(),
      (FontLoader(
            _captureTheme.extension<IanvsTypography>()!.code.fontFamily!,
          )..addFont(
            bytes(
              '${sdk.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
            ),
          ))
          .load(),
      (FontLoader('MaterialIcons')..addFont(
            bytes(
              '${sdk.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
            ),
          ))
          .load(),
    ]);
  });

  testWidgets('capture implemented settings journey', (tester) async {
    tester.view.physicalSize = const Size(1440, 1024);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(settingsFixtureApp());
    await tester.pumpAndSettle();
    final controller = tester
        .widget<AppShell>(find.byType(AppShell))
        .controller;
    await controller.newSession();
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull, reason: name);
      await expectLater(
        find.byType(AcpClientApp),
        matchesGoldenFile('screenshots/after/$name.png'),
      );
    }

    Future<void> section(String name) async {
      await tester.tap(find.byKey(Key('settings-section-$name')));
      await tester.pumpAndSettle();
    }

    await capture('01-workspace');
    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await capture('02-agent-menu');
    await tester.tap(find.text('管理 Agent…'));
    await tester.pumpAndSettle();
    await capture('03-agent-clean');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('agent-name-field')),
        matching: find.byType(TextField),
      ),
      'Codex local',
    );
    await tester.pumpAndSettle();
    await capture('04-agent-draft');
    await section('tools');
    await capture('05-directories');
    await tester.tap(find.byKey(const Key('settings-mcp-Project tools')));
    await tester.pumpAndSettle();
    await capture('06-mcp');
    await section('permissions');
    await capture('07-permissions');
    await tester.ensureVisible(
      find.byKey(const Key('review-agent-enabled-switch')),
    );
    await tester.tap(find.byKey(const Key('review-agent-enabled-switch')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('review-timeout-field')));
    await tester.pumpAndSettle();
    await capture('08-review-source');
    await section('assistant');
    await capture('09-assistant-disabled');
    await tester.tap(find.byKey(const Key('assistant-agent-enabled-switch')));
    await tester.pumpAndSettle();
    await capture('10-assistant-enabled');
    await section('storage');
    await capture('11-storage');
    await section('agents');
    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
    await capture('12-discard-confirmation');
    await tester.tap(find.widgetWithText(TextButton, '继续编辑'));
    await tester.pumpAndSettle();
    tester.view.physicalSize = const Size(480, 860);
    await tester.pumpAndSettle();
    await capture('13-narrow');
    tester.view.physicalSize = const Size(1440, 1024);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-discard')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '放弃更改'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byKey(const Key('agent-name-field')),
        matching: find.byType(TextField),
      ),
      'Codex local',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(find.text('更改已保存'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await capture('14-saved');
    await tester.tap(find.byKey(const Key('settings-back')));
    await tester.pumpAndSettle();
    final nextController = tester
        .widget<AppShell>(find.byType(AppShell))
        .controller;
    await nextController.newSession();
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    showDialog<void>(
      context: context,
      builder: (_) => SessionSettingsDialog(controller: nextController),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await capture('15-session-settings');
  });
}
