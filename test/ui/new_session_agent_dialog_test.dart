import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/new_session_agent_dialog.dart';

void main() {
  testWidgets('NewSessionAgentDialog returns selected agent and cwd', (
    tester,
  ) async {
    NewSessionSelection? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await showDialog<NewSessionSelection>(
                    context: context,
                    builder: (context) => const NewSessionAgentDialog(
                      currentAgentName: 'Kimi Code Dev',
                      initialCwd: '/workspace',
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
                        AgentServerConfig(
                          name: 'Remote HTTP Agent',
                          type: 'http',
                          url: 'https://agent.example.com/acp',
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
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('New Session'), findsOneWidget);
    expect(find.text('Kimi Code Dev'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('/usr/local/bin/kimi'), findsOneWidget);
    expect(find.text('/usr/local/bin/npx'), findsOneWidget);
    expect(find.text('Remote HTTP Agent'), findsOneWidget);
    expect(find.text('https://agent.example.com/acp'), findsOneWidget);

    await tester.tap(find.text('Codex'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    expect(selected?.agentServer?.name, 'Codex');
    expect(selected?.cwd, '/workspace');
  });

  test('newSessionPathSuggestions autocompletes directory paths', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs-acp-cwd-');
    addTearDown(() => temp.delete(recursive: true));
    final alpha = Directory('${temp.path}/alpha');
    await alpha.create();
    await Directory('${temp.path}/alpine').create();
    await Directory('${temp.path}/beta').create();

    final suggestions = newSessionPathSuggestions('${temp.path}/al').toList();

    expect(suggestions, contains(alpha.path));
    expect(suggestions, contains('${temp.path}/alpine'));
    expect(suggestions, isNot(contains('${temp.path}/beta')));
  });
}
