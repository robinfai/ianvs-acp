import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/app.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';
import 'package:ianvs_acp/ui/shell/app_shell.dart';
import 'package:ianvs_agent_chat/ui/theme/app_design_tokens.dart';

import 'fixture.dart';

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
      (FontLoader(
        AppTypography.family,
      )..addFont(bytes('/System/Library/Fonts/Supplemental/Arial.ttf'))).load(),
      (FontLoader(
        'PingFang SC',
      )..addFont(bytes('/System/Library/Fonts/Hiragino Sans GB.ttc'))).load(),
      (FontLoader(AppTypography.monoFamily)..addFont(
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

  testWidgets('capture current settings journey', (tester) async {
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
    Future<void> capture(String name) => expectLater(
      find.byType(AcpClientApp),
      matchesGoldenFile('screenshots/before/$name.png'),
    );
    await capture('01-workspace');
    await tester.tap(find.byTooltip('Agents'));
    await tester.pumpAndSettle();
    await capture('02-agent-menu');
    await tester.tap(find.text('Agent Configuration'));
    await tester.pumpAndSettle();
    await capture('03-global-settings-top');
    await tester.ensureVisible(
      find.byKey(const Key('review-agent-enabled-switch')),
    );
    await tester.pumpAndSettle();
    await capture('04-permissions');
    await tester.ensureVisible(find.widgetWithText(TextButton, 'Add Agent'));
    await tester.pumpAndSettle();
    await capture('05-agents-bottom');
    await tester.tap(find.byTooltip('Edit Codex'));
    await tester.pumpAndSettle();
    await capture('06-agent-editor');
    await tester.tap(find.text('Advanced settings'));
    await tester.pumpAndSettle();
    await capture('06b-agent-editor-expanded');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextButton, 'Add MCP Server'),
    );
    await tester.tap(find.widgetWithText(TextButton, 'Add MCP Server'));
    await tester.pumpAndSettle();
    await capture('07-mcp-editor');
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(Scaffold).first);
    showDialog<void>(
      context: context,
      builder: (_) => SessionSettingsDialog(controller: controller),
    );
    await tester.pumpAndSettle();
    await capture('08-session-settings');
  });
}
