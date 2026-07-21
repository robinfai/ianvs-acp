import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/workspace_header.dart';
import 'package:ianvs_acp/workspace/workspace.dart';

void main() {
  testWidgets('WorkspaceHeader separates current workspace and session', (
    tester,
  ) async {
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final session = AgentSession(
      id: 'session-a',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Implementation plan',
      agentName: 'Codex',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            child: WorkspaceHeader(
              workspace: workspace,
              agentName: 'Codex',
              currentSession: session,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('workspace-header-workspace-surface')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('workspace-header-session-surface')),
      findsOneWidget,
    );
    expect(find.text('current'), findsOneWidget);
    expect(find.text('Implementation plan'), findsOneWidget);
    expect(find.text('Implementation plan - /workspace/current'), findsNothing);
  });
}
