import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/startup/deep_link_request.dart';
import 'package:ianvs_acp/ui/components/agent_discovery_dialog.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';
import 'package:ianvs_acp/ui/components/permission_history_view.dart';
import 'package:ianvs_acp/ui/components/session_workspace_review_dialog.dart';
import 'package:ianvs_acp/ui/components/deep_link_confirmation_dialog.dart';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:ianvs_acp/app.dart';
import '../settings-redesign-2026-09-09/fixture.dart';
import '../macos-polish-2026-09-11/fixture.dart';

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
    final configFile = File('.dart_tool/package_config.json').absolute;
    final config =
        jsonDecode(await configFile.readAsString()) as Map<String, dynamic>;
    final cupertino = (config['packages'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((p) => p['name'] == 'cupertino_icons');
    final cupertinoFont = configFile.uri
        .resolve('${cupertino['rootUri']}/')
        .resolve('assets/CupertinoIcons.ttf')
        .toFilePath();
    final sans = bytes('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    final mono = bytes(
      '${sdk.path}/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts/Roboto_Mono/RobotoMono-Regular.ttf',
    );
    await Future.wait([
      (FontLoader(
        'packages/cupertino_icons/CupertinoIcons',
      )..addFont(bytes(cupertinoFont))).load(),
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
    testWidgets('secondary surfaces ${brightness.name}', (tester) async {
      debugDisableShadows = false;
      tester.view.physicalSize = const Size(1100, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scenes = <String, Widget Function()>{
        'discovery': () => const AgentDiscoveryDialog(
          agentServers: [
            AgentServerConfig(name: 'Codex', type: 'custom', command: 'codex'),
            AgentServerConfig(
              name: 'Remote Agent',
              type: 'http',
              url: 'https://agent.example.com',
            ),
          ],
        ),
        'resume': () => ResumeSessionDialog(
          agents: [
            ResumeSessionAgentOption(
              id: 'codex',
              name: 'Codex',
              isCurrent: true,
              loadSessions: () async => [
                AcpProjectSessions(
                  cwd: '/workspace/shift',
                  sessions: const [
                    AcpSessionEntry(
                      id: 'conversation-1',
                      cwd: '/workspace/shift',
                      title: 'Review interface consistency',
                    ),
                    AcpSessionEntry(
                      id: 'conversation-2',
                      cwd: '/workspace/shift',
                      title: 'Refine composer interactions',
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
        'workspace-review': () => SessionWorkspaceReviewDialog(
          session: AgentSession(
            id: 'conversation-1',
            cwd: '/workspace/shift',
            title: 'Review interface consistency',
            agentName: 'Codex',
            createdAt: DateTime(2026, 9, 12),
            additionalDirectories: const ['/workspace/shared'],
          ),
        ),
        'external-session': () => const DeepLinkConfirmationDialog(
          request: DeepLinkRequest(
            rawLink: 'shift://session/conversation-1',
            source: DeepLinkSource.external,
            kind: DeepLinkRequestKind.session,
            sessionId: 'conversation-1',
            cwd: '/workspace/shift',
            agentName: 'Codex',
          ),
        ),
        'permission-record': () => Dialog(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: PermissionHistoryView(
              entries: [
                AcpPermissionAuditEntry(
                  request: AcpPermissionRequest(
                    id: 'read-1',
                    title: 'Read project configuration',
                    rationale:
                        'Inspect the workspace configuration before making changes.',
                    sessionId: 'conversation-1',
                    toolName: 'read_text_file',
                    toolKind: 'read',
                    options: const ['Allow', 'Deny'],
                    requestedAt: DateTime(2026, 9, 12, 10),
                  ),
                  status: AcpPermissionAuditStatus.allowed,
                  recordedAt: DateTime(2026, 9, 12, 10),
                  decisionSource: AcpPermissionDecisionSource.trustRule,
                ),
              ],
            ),
          ),
        ),
      };
      for (final scene in scenes.entries) {
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: IanvsTheme.build(
              platform: TargetPlatform.macOS,
              brightness: brightness,
            ),
            home: Scaffold(body: scene.value()),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: scene.key);
        await tester.pump();
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            '${const String.fromEnvironment('CAPTURE_STAGE', defaultValue: 'before')}/${brightness.name}-${scene.key}.png',
          ),
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
      }
      debugDisableShadows = true;
    });

    testWidgets('macOS polish ${brightness.name} settings and chat layouts', (
      tester,
    ) async {
      debugDisableShadows = false;
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
        await tester.pump();
        await expectLater(
          find.byType(AcpClientApp),
          matchesGoldenFile(
            '${const String.fromEnvironment('CAPTURE_STAGE', defaultValue: 'before')}/${brightness.name}-$scene.png',
          ),
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
      debugDisableShadows = true;
    });
  }
}
