import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_design/ianvs_design.dart';
import 'package:ianvs_acp/acp/acp_session_settings.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/session_settings_dialog.dart';
import 'package:ianvs_acp/ui/shell/independent_llm_page.dart';

void main() {
  testWidgets('macOS chat chrome leaves room for window buttons and returns', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      MaterialApp(
        theme: IanvsTheme.light().copyWith(platform: TargetPlatform.macOS),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(builder: (_) => const IndependentLlmPage()),
              ),
              child: const Text('Open chat'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open chat'));
    await tester.pumpAndSettle();
    final back = find.byKey(const Key('independent-llm-back'));
    expect(tester.getRect(back).left, greaterThanOrEqualTo(88));
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.byKey(const Key('llm-connect')));
    await tester.tap(find.byKey(const Key('llm-connect')));
    await tester.pumpAndSettle();
    // The compact form still validates locally without starting a connection.
    expect(find.text('Enter a model name.'), findsOneWidget);
    await tester.tap(back);
    await tester.pumpAndSettle();
    expect(find.text('Open chat'), findsOneWidget);
  });

  testWidgets('narrow enlarged session options retain usable controls', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(600, 850);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final controller = ChatController(
      client: FakeAgentClient(
        sessionSettings: const AcpSessionSettings(
          configOptions: [
            AcpConfigOption(
              id: 'workspace-check',
              name: 'Check the active workspace before running tools',
              description:
                  'Keep a readable explanation beside this configurable value.',
              type: 'boolean',
              currentValue: 'false',
              options: [],
            ),
          ],
        ),
      ),
      cwd: '/workspace/app',
    );
    addTearDown(controller.dispose);
    await controller.newSession();
    await tester.pumpWidget(
      MaterialApp(
        theme: IanvsTheme.light().copyWith(platform: TargetPlatform.macOS),
        home: Scaffold(body: SessionSettingsDialog(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(Switch));
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(
      controller.sessionSettings.configOptions.single.currentBoolValue,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });
}
