import 'dart:io';
import 'dart:ui' show SemanticsAction, Tristate;

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
                          url:
                              'https://user:password@agent.example.com/'
                              'path-secret?token=query-secret#fragment-secret',
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
    expect(find.textContaining('https://agent.example.com'), findsOneWidget);
    expect(find.textContaining('path-secret'), findsNothing);
    expect(find.textContaining('query-secret'), findsNothing);
    expect(find.textContaining('password'), findsNothing);
    final codexChoice = find.bySemanticsLabel('Codex, /usr/local/bin/npx');
    expect(codexChoice, findsOneWidget);
    expect(
      tester
          .getSemantics(codexChoice)
          .getSemanticsData()
          .hasAction(SemanticsAction.tap),
      isTrue,
    );
    expect(find.byTooltip('/usr/local/bin/kimi'), findsOneWidget);

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

    final exactSuggestions = newSessionPathSuggestions(alpha.path).toList();
    expect(exactSuggestions, isNot(contains(alpha.path)));
  });

  testWidgets('NewSessionAgentDialog returns the default session template', (
    tester,
  ) async {
    NewSessionSelection? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showDialog<NewSessionSelection>(
                  context: context,
                  builder: (context) => const NewSessionAgentDialog(
                    currentAgentName: 'Codex',
                    initialCwd: '/workspace',
                    agentServers: [
                      AgentServerConfig(
                        name: 'Codex',
                        type: 'custom',
                        command: '/usr/local/bin/codex',
                      ),
                    ],
                    defaultSessionTemplateId: 'review',
                    sessionTemplates: [
                      SessionTemplateConfig(
                        id: 'fast',
                        name: 'Fast coding',
                        model: 'fast',
                      ),
                      SessionTemplateConfig(
                        id: 'review',
                        name: 'Deep review',
                        version: 2,
                        agentServerName: 'Codex',
                        reasoningEffort: 'high',
                      ),
                    ],
                  ),
                );
              },
              child: const Text('Open templates'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open templates'));
    await tester.pumpAndSettle();

    expect(find.text('Session template'), findsOneWidget);
    expect(find.text('Fast coding'), findsOneWidget);
    expect(find.text('Deep review'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    final selectedTemplate = find.bySemanticsLabel(
      'Deep review, template version 2',
    );
    expect(
      tester.getSemantics(selectedTemplate).flagsCollection.isSelected,
      Tristate.isTrue,
    );

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    expect(selected?.sessionTemplate?.identity, 'review@2');
    expect(selected?.agentServer, isNull);
    expect(selected?.cwd, '/workspace');
  });

  testWidgets('templates do not become implicit defaults', (tester) async {
    NewSessionSelection? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                selected = await showDialog<NewSessionSelection>(
                  context: context,
                  builder: (context) => const NewSessionAgentDialog(
                    currentAgentName: 'Codex',
                    initialCwd: '/workspace',
                    agentServers: <AgentServerConfig>[
                      AgentServerConfig(
                        name: 'Codex',
                        type: 'custom',
                        command: '/usr/local/bin/codex',
                      ),
                    ],
                    sessionTemplates: <SessionTemplateConfig>[
                      SessionTemplateConfig(id: 'review', name: 'Review'),
                    ],
                  ),
                );
              },
              child: const Text('Open without default'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open without default'));
    await tester.pumpAndSettle();

    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Custom session'))
          .flagsCollection
          .isSelected,
      Tristate.isTrue,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();

    expect(selected?.sessionTemplate, isNull);
    expect(selected?.agentServer?.name, 'Codex');
  });
}
