import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';

void main() {
  testWidgets('ResumeSessionDialog returns selected conversation', (
    tester,
  ) async {
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Resume this project conversation',
          updatedAt: DateTime(2026, 5, 28, 12),
        ),
      ],
    );

    ResumeSessionSelection? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return FilledButton(
                onPressed: () async {
                  selection = await showDialog<ResumeSessionSelection>(
                    context: context,
                    builder: (context) => ResumeSessionDialog(
                      loadSessions: () async => [project],
                    ),
                  );
                },
                child: const Text('Open'),
              );
            },
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();

    expect(find.text('Project'), findsOneWidget);
    expect(find.text('Conversation'), findsOneWidget);
    expect(find.textContaining('2026-05-28 12:00'), findsWidgets);
    expect(find.text('Load'), findsOneWidget);

    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();

    expect(selection?.project.cwd, '/workspace/project-a');
    expect(selection?.conversation.id, 'session-a');
  });

  testWidgets('ResumeSessionDialog filters without mutating selected labels', (
    tester,
  ) async {
    final projectA = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Alpha chat',
          updatedAt: DateTime(2026, 5, 28, 12),
        ),
      ],
    );
    final projectB = AcpProjectSessions(
      cwd: '/workspace/other',
      sessions: [
        AcpSessionEntry(
          id: 'session-other',
          cwd: '/workspace/other',
          title: 'Other chat',
          updatedAt: DateTime(2026, 5, 29, 12),
        ),
        AcpSessionEntry(
          id: 'session-beta',
          cwd: '/workspace/other',
          title: 'Beta task',
          updatedAt: DateTime(2026, 5, 30, 12),
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            loadSessions: () async => [projectA, projectB],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('resume-project-search')),
      'other',
    );
    await tester.pumpAndSettle();

    expect(find.text('other'), findsOneWidget);
    expect(find.textContaining('projotherect-a'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('resume-project-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(projectB.dropdownLabel).last);
    await tester.pumpAndSettle();

    expect(find.text('Other chat'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('resume-conversation-search')),
      'beta',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('resume-conversation-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Beta task').last);
    await tester.pumpAndSettle();

    expect(find.text('Beta task'), findsOneWidget);
    expect(find.textContaining('Othbetaer'), findsNothing);
  });
}
