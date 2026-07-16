import 'dart:collection';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';
import 'package:ianvs_acp/ui/components/session_workspace_review_dialog.dart';

void main() {
  testWidgets('ResumeSessionDialog lazily builds 1024 searchable entries', (
    tester,
  ) async {
    final conversations = _CountingList<AcpSessionEntry>(
      List<AcpSessionEntry>.generate(
        1024,
        (index) => AcpSessionEntry(
          id: 'session-$index',
          cwd: '/workspace/project-0',
          title: 'Conversation $index',
        ),
      ),
    );
    final projects = _CountingList<AcpProjectSessions>(
      List<AcpProjectSessions>.generate(
        1024,
        (index) => AcpProjectSessions(
          cwd: '/workspace/project-$index',
          sessions: index == 0
              ? conversations
              : [
                  AcpSessionEntry(
                    id: 'project-$index-session',
                    cwd: '/workspace/project-$index',
                    title: 'Project $index conversation',
                  ),
                ],
        ),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(loadSessions: () async => projects),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
      findsNothing,
    );
    final projectListFinder = find.byKey(const ValueKey('resume-project-list'));
    final conversationListFinder = find.byKey(
      const ValueKey('resume-conversation-list'),
    );
    expect(projectListFinder, findsOneWidget);
    expect(conversationListFinder, findsOneWidget);
    expect(tester.widget<ListView>(projectListFinder).primary, isFalse);
    expect(tester.widget<ListView>(conversationListFinder).primary, isFalse);
    expect(projects.itemReads, lessThan(128));
    expect(conversations.itemReads, lessThan(128));
    expect(find.text('Conversation 1023'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('resume-conversation-search')),
      'Conversation 1023',
    );
    await tester.pumpAndSettle();
    expect(find.text('Conversation 1023'), findsWidgets);
    await tester.ensureVisible(conversationListFinder);
    await tester.pumpAndSettle();
    final conversationTile = _listTileContaining(
      conversationListFinder,
      'Conversation 1023',
    );
    await tester.tap(conversationTile);
    await tester.pumpAndSettle();
    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('resume-project-search')),
      'project-1023',
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('/workspace/project-1023'), findsOneWidget);
    await tester.ensureVisible(projectListFinder);
    await tester.pumpAndSettle();
    final projectTile = _listTileContaining(
      projectListFinder,
      '/workspace/project-1023',
    );
    await tester.tap(projectTile);
    await tester.pumpAndSettle();
    expect(find.text('Project 1023 conversation'), findsWidgets);
  });

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

  testWidgets('ResumeSessionDialog encodes metadata only after expansion', (
    tester,
  ) async {
    final metadata = _ThrowingEntriesMetadata();
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Bounded metadata',
          meta: metadata,
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            loadSessions: () async => [project],
            inputBudget: const AcpInputBudget(
              maxMetadataPreviewChars: 8,
              maxMetadataPreviewBytes: 8,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(metadata.entriesReads, 0);
    expect(tester.takeException(), isNull);

    await tester.ensureVisible(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata'));
    await tester.pump();

    expect(metadata.entriesReads, 1);
    expect(tester.takeException(), isNull);
    expect(find.textContaining('metadata preview'), findsOneWidget);
  });

  testWidgets('ResumeSessionDialog replaces expanded metadata with selection', (
    tester,
  ) async {
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: const [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Session A',
          meta: {'value': 'SESSION_A_CANARY'},
        ),
        AcpSessionEntry(
          id: 'session-b',
          cwd: '/workspace/project-a',
          title: 'Session B',
          meta: {'value': 'SESSION_B_CANARY'},
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
    await tester.ensureVisible(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SESSION_A_CANARY'), findsOneWidget);

    final conversationList = find.byKey(
      const ValueKey('resume-conversation-list'),
    );
    await tester.ensureVisible(conversationList);
    await tester.pumpAndSettle();
    await tester.tap(
      find
          .descendant(
            of: conversationList,
            matching: find.textContaining('Session B'),
          )
          .first,
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('SESSION_A_CANARY'), findsNothing);
    expect(find.textContaining('SESSION_B_CANARY'), findsOneWidget);
  });

  testWidgets('ResumeSessionDialog invalidates collapsed preview on budget', (
    tester,
  ) async {
    final budget = ValueNotifier<AcpInputBudget>(const AcpInputBudget());
    addTearDown(budget.dispose);
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: const [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Budget session',
          meta: {'value': 'BUDGET_CANARY'},
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder<AcpInputBudget>(
            valueListenable: budget,
            builder: (context, inputBudget, _) => ResumeSessionDialog(
              loadSessions: () async => [project],
              inputBudget: inputBudget,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    expect(find.textContaining('BUDGET_CANARY'), findsOneWidget);

    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    budget.value = const AcpInputBudget(
      maxMetadataPreviewChars: 8,
      maxMetadataPreviewBytes: 8,
    );
    await tester.pump();
    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();

    expect(find.textContaining('BUDGET_CANARY'), findsNothing);
    expect(find.textContaining('metadata preview'), findsOneWidget);
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

    final projectList = find.byKey(const ValueKey('resume-project-list'));
    await tester.ensureVisible(projectList);
    await tester.pumpAndSettle();
    final projectTile = _listTileContaining(projectList, '/workspace/other');
    await tester.tap(projectTile);
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

    final conversationList = find.byKey(
      const ValueKey('resume-conversation-list'),
    );
    await tester.ensureVisible(conversationList);
    await tester.pumpAndSettle();
    final conversationTile = _listTileContaining(conversationList, 'Beta task');
    await tester.tap(conversationTile);
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

Finder _listTileContaining(Finder list, String text) {
  final textInList = find.descendant(
    of: list,
    matching: find.textContaining(text),
  );
  return find.ancestor(of: textInList, matching: find.byType(ListTile));
}

final class _ThrowingEntriesMetadata extends MapBase<String, Object?> {
  var entriesReads = 0;

  @override
  Object? operator [](Object? key) => key == 'payload' ? 'CANARY' : null;

  @override
  void operator []=(String key, Object? value) =>
      throw UnsupportedError('immutable');

  @override
  void clear() => throw UnsupportedError('immutable');

  @override
  Object? remove(Object? key) => throw UnsupportedError('immutable');

  @override
  Iterable<String> get keys => const <String>['payload'];

  @override
  Iterable<MapEntry<String, Object?>> get entries {
    entriesReads += 1;
    throw StateError('hostile entries');
  }
}

final class _CountingList<E> extends ListBase<E> {
  _CountingList(this._values);

  final List<E> _values;
  var itemReads = 0;

  @override
  int get length => _values.length;

  @override
  set length(int value) => throw UnsupportedError('immutable');

  @override
  E operator [](int index) {
    itemReads += 1;
    return _values[index];
  }

  @override
  void operator []=(int index, E value) => throw UnsupportedError('immutable');
}
