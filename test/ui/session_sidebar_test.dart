import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/session_sidebar.dart';
import 'package:ianvs_acp/ui/components/session_time_label.dart';

void main() {
  testWidgets('SessionSidebar shows each session agent', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 500,
            child: SessionSidebar(
              agentName: 'Codex',
              currentSession: AgentSession(
                id: 'session-codex',
                cwd: '/workspace',
                createdAt: DateTime(2026, 5, 30, 10),
                title: 'Fix UX',
                agentName: 'Codex',
              ),
              sessions: [
                AgentSession(
                  id: 'session-codex',
                  cwd: '/workspace',
                  createdAt: DateTime(2026, 5, 30, 10),
                  title: 'Fix UX',
                  agentName: 'Codex',
                ),
              ],
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Fix UX'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
  });

  testWidgets('SessionSidebar can select an inactive session', (tester) async {
    AgentSession? selected;
    final current = AgentSession(
      id: 'session-codex',
      cwd: '/workspace',
      createdAt: DateTime(2026, 5, 30, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final previous = AgentSession(
      id: 'session-kimi',
      cwd: '/workspace/other',
      createdAt: DateTime(2026, 5, 29, 10),
      title: 'Previous work',
      agentName: 'Kimi',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 500,
            child: SessionSidebar(
              agentName: 'Codex',
              currentSession: current,
              sessions: [current, previous],
              onNewSession: () {},
              onResumeSession: () {},
              onSelectSession: (session) => selected = session,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Previous work'));
    await tester.pump();

    expect(selected, previous);
  });

  testWidgets('SessionSidebar shows relative session times', (tester) async {
    final now = DateTime(2026, 7, 8, 12);
    debugSessionTimeNow = () => now;
    addTearDown(() {
      debugSessionTimeNow = null;
    });
    final session = AgentSession(
      id: 'session-codex',
      cwd: '/workspace',
      createdAt: now.subtract(const Duration(days: 3, hours: 1)),
      title: 'Fix UX',
      agentName: 'Codex',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 260,
            height: 500,
            child: SessionSidebar(
              agentName: 'Codex',
              currentSession: session,
              sessions: [session],
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('3d ago'), findsOneWidget);
  });
}
