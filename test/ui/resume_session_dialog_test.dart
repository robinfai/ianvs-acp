import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/codex_session_catalog.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';

void main() {
  testWidgets('ResumeSessionDialog returns selected conversation', (
    tester,
  ) async {
    final project = CodexProjectSessions(
      cwd: '/workspace/project-a',
      conversations: const [
        CodexConversationEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Resume this project conversation',
          sourcePath: '/tmp/session-a.jsonl',
          turnCount: 3,
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
                    builder: (context) =>
                        ResumeSessionDialog(catalog: _FakeCatalog([project])),
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
    expect(find.textContaining('3 turns'), findsWidgets);
    expect(find.text('Load'), findsOneWidget);

    await tester.tap(find.text('Load'));
    await tester.pumpAndSettle();

    expect(selection?.project.cwd, '/workspace/project-a');
    expect(selection?.conversation.id, 'session-a');
  });
}

class _FakeCatalog extends CodexSessionCatalog {
  const _FakeCatalog(this.projects);

  final List<CodexProjectSessions> projects;

  @override
  Future<List<CodexProjectSessions>> load({
    bool includeTurnCounts = true,
  }) async {
    return projects;
  }
}
