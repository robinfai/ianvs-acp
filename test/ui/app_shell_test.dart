import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';

void main() {
  Widget toolbar(
    app_state.ConnectionStatus status, {
    String agentName = 'Codex',
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AgentToolbar(
          agentName: agentName,
          status: status,
          onNewSession: () {},
          onResumeSession: () {},
          onReconnect: () {},
        ),
      ),
    );
  }

  Future<void> pumpToolbar(
    WidgetTester tester,
    app_state.ConnectionStatus status, {
    Size size = const Size(1400, 720),
    String agentName = 'Codex',
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(toolbar(status, agentName: agentName));
  }

  testWidgets('AgentToolbar initial rendering shows disconnected', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.disconnected);

    expect(find.text('ACP Client'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('disconnected'), findsOneWidget);
    expect(find.text('New Session'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders connected and error states', (
    tester,
  ) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connected);
    expect(find.text('connected'), findsOneWidget);

    await pumpToolbar(tester, app_state.ConnectionStatus.error);
    expect(find.text('error'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders custom agent name', (tester) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.connected,
      agentName: 'Kimi Code Dev',
    );

    expect(find.text('Kimi Code Dev'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders connecting state', (tester) async {
    await pumpToolbar(tester, app_state.ConnectionStatus.connecting);

    expect(find.text('connecting'), findsOneWidget);
  });

  testWidgets('AgentToolbar compacts actions in narrow windows', (
    tester,
  ) async {
    await pumpToolbar(
      tester,
      app_state.ConnectionStatus.disconnected,
      size: const Size(800, 720),
    );

    expect(find.text('ACP Client'), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsOneWidget);
    expect(find.byIcon(Icons.add_rounded), findsOneWidget);
    expect(find.text('Codex'), findsNothing);
    expect(find.text('New Session'), findsNothing);
  });
}
