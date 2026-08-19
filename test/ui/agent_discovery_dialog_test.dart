import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/config/acp_client_config.dart';
import 'package:ianvs_acp/ui/components/agent_discovery_dialog.dart';

void main() {
  testWidgets('AgentDiscoveryDialog hides remote URL and process secrets', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AgentDiscoveryDialog(
            agentServers: <AgentServerConfig>[
              AgentServerConfig(
                name: 'Remote',
                type: 'http',
                url:
                    'https://user:password@agent.example.com/'
                    'path-secret?token=query-secret#fragment-secret',
              ),
              AgentServerConfig(
                name: 'Local',
                type: 'custom',
                command: '/usr/local/bin/agent',
                args: <String>['--token', 'argument-secret'],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.textContaining('https://agent.example.com'), findsOneWidget);
    expect(find.text('/usr/local/bin/agent'), findsOneWidget);
    for (final secret in <String>[
      'user',
      'password',
      'path-secret',
      'query-secret',
      'fragment-secret',
      'argument-secret',
    ]) {
      expect(find.textContaining(secret), findsNothing);
    }
  });
}
