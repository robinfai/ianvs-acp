import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/state/connection_state.dart' as app_state;
import 'package:ianvs_acp/ui/components/agent_toolbar.dart';

void main() {
  Widget toolbar(app_state.ConnectionStatus status) {
    return MaterialApp(
      home: Scaffold(
        body: AgentToolbar(
          status: status,
          onNewSession: () {},
          onResumeSession: () {},
          onReconnect: () {},
        ),
      ),
    );
  }

  testWidgets('AgentToolbar initial rendering shows disconnected', (
    tester,
  ) async {
    await tester.pumpWidget(toolbar(app_state.ConnectionStatus.disconnected));

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
    await tester.pumpWidget(toolbar(app_state.ConnectionStatus.connected));
    expect(find.text('connected'), findsOneWidget);

    await tester.pumpWidget(toolbar(app_state.ConnectionStatus.error));
    expect(find.text('error'), findsOneWidget);
  });

  testWidgets('AgentToolbar renders connecting state', (tester) async {
    await tester.pumpWidget(toolbar(app_state.ConnectionStatus.connecting));

    expect(find.text('connecting'), findsOneWidget);
  });
}
