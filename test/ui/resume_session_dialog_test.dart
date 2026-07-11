import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';
import 'package:ianvs_acp/ui/components/session_workspace_review_dialog.dart';

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

  testWidgets('ResumeSessionDialog previews every workspace root', (
    tester,
  ) async {
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Workspace-aware conversation',
          additionalDirectories: const [
            '/workspace/shared-one',
            '/workspace/shared-two',
          ],
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(loadSessions: () async => [project]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('/workspace/project-a'), findsWidgets);
    expect(
      find.widgetWithText(SelectableText, '/workspace/shared-one'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SelectableText, '/workspace/shared-two'),
      findsOneWidget,
    );
  });

  testWidgets('SessionWorkspaceReviewDialog returns only explicit approval', (
    tester,
  ) async {
    final session = AgentSession(
      id: 'session-a',
      cwd: '/workspace/project-a',
      createdAt: DateTime(2026, 7, 11),
      title: 'Workspace-aware conversation',
      agentName: 'Codex',
      additionalDirectories: const [
        '',
        ' /workspace/shared-one ',
        '/workspace/shared-one',
        '/workspace/shared-two',
      ],
    );
    bool? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => FilledButton(
              onPressed: () async {
                result = await showSessionWorkspaceReviewDialog(
                  context,
                  session,
                );
              },
              child: const Text('Open Review'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Review'));
    await tester.pumpAndSettle();

    expect(find.text('Workspace-aware conversation'), findsOneWidget);
    expect(find.text('Codex'), findsOneWidget);
    expect(
      find.widgetWithText(SelectableText, '/workspace/project-a'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SelectableText, '/workspace/shared-one'),
      findsOneWidget,
    );
    expect(
      find.widgetWithText(SelectableText, '/workspace/shared-two'),
      findsOneWidget,
    );
    expect(
      find.textContaining('local file and terminal access roots'),
      findsOneWidget,
    );

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);

    await tester.tap(find.text('Open Review'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Resume Session'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
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
    expect(find.text('Alpha chat'), findsNothing);
    expect(find.text('Select a conversation'), findsWidgets);
    expect(_loadButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('resume-project-dropdown')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(projectB.dropdownLabel).last);
    await tester.pumpAndSettle();

    expect(find.text('Other chat'), findsOneWidget);
    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('resume-conversation-search')),
      'beta',
    );
    await tester.pumpAndSettle();
    expect(find.text('Other chat'), findsNothing);
    expect(find.text('Select a conversation'), findsWidgets);
    expect(_loadButton(tester).onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('resume-conversation-dropdown')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Beta task').last);
    await tester.pumpAndSettle();

    expect(find.text('Beta task'), findsOneWidget);
    expect(find.textContaining('Othbetaer'), findsNothing);
    expect(_loadButton(tester).onPressed, isNotNull);
  });

  testWidgets('ResumeSessionDialog disables load after refresh fails', (
    tester,
  ) async {
    final project = AcpProjectSessions(
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
    var loadCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            loadSessions: () async {
              loadCount += 1;
              if (loadCount == 1) return [project];
              throw Exception('refresh failed');
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('Could not list ACP sessions'), findsOneWidget);
    expect(find.textContaining('refresh failed'), findsOneWidget);
    expect(_loadButton(tester).onPressed, isNull);
  });
}

FilledButton _loadButton(WidgetTester tester) {
  return tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Load'));
}
