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
}
