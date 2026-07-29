import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/memory/memory_runtime_status.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/ui/components/status_bar.dart';

void main() {
  Widget statusBar({
    required ChatController controller,
    required double width,
    MemoryRuntimeStatus memoryStatus = MemoryRuntimeStatus.disabled,
    int memoryPendingCount = 0,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: StatusBar(
              controller: controller,
              memoryStatus: memoryStatus,
              memoryPendingCount: memoryPendingCount,
              onShowCapabilities: () {},
              onShowSessionSettings: () {},
            ),
          ),
        ),
      ),
    );
  }

  ChatController controller() =>
      ChatController(client: FakeAgentClient(), cwd: '/workspace');

  testWidgets('StatusBar keeps secondary actions on desktop widths', (
    tester,
  ) async {
    final chatController = controller();
    addTearDown(chatController.dispose);

    await tester.pumpWidget(statusBar(controller: chatController, width: 900));

    expect(find.byTooltip('Session settings'), findsOneWidget);
    expect(find.byTooltip('ACP compatibility'), findsOneWidget);
    expect(find.byTooltip('Theme'), findsOneWidget);
  });

  testWidgets('StatusBar hides secondary actions in narrow widths', (
    tester,
  ) async {
    final chatController = controller();
    addTearDown(chatController.dispose);

    await tester.pumpWidget(statusBar(controller: chatController, width: 320));

    expect(tester.takeException(), isNull);
    expect(find.byTooltip('Session settings'), findsNothing);
    expect(find.byTooltip('ACP compatibility'), findsNothing);
    expect(find.byTooltip('Theme'), findsNothing);
    expect(find.text('disconnected'), findsOneWidget);
    expect(find.text('idle'), findsOneWidget);
  });

  testWidgets('StatusBar displays memory runtime status', (tester) async {
    final chatController = controller();
    addTearDown(chatController.dispose);

    await tester.pumpWidget(
      statusBar(
        controller: chatController,
        width: 900,
        memoryStatus: MemoryRuntimeStatus.running,
        memoryPendingCount: 3,
      ),
    );

    expect(find.text('memory on · 3 pending'), findsOneWidget);
    expect(find.byTooltip('Memory enabled and running'), findsOneWidget);
  });
}
