import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/new_session_agent_dialog.dart';

void main() {
  testWidgets('NewSessionAgentDialog returns selected agent', (tester) async {
    AgentServerConfig? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<AgentServerConfig>(
                    context: context,
                    builder: (context) => const NewSessionAgentDialog(
                      currentAgentName: 'Kimi Code Dev',
                      agentServers: [
                        AgentServerConfig(
                          name: 'Kimi Code Dev',
                          type: 'custom',
                          command: '/usr/local/bin/kimi',
                          args: ['acp'],
                        ),
                        AgentServerConfig(
                          name: 'Codex',
                          type: 'custom',
                          command: '/usr/local/bin/npx',
                          args: ['@zed-industries/codex-acp'],
                        ),
                      ],
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('New Session'), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);

    await tester.tap(find.text('Codex'));
    await tester.pumpAndSettle();

    expect(selected?.name, 'Codex');
  });
}
