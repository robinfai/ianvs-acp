import 'dart:collection';

import 'package:ianvs_acp/acp/acp_input_budget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_session_catalog.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/resume_session_dialog.dart';
import 'package:ianvs_acp/ui/components/session_workspace_review_dialog.dart';

void main() {
  testWidgets('ResumeSessionDialog labels the unified search for semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final project = AcpProjectSessions(
      cwd: '/workspace/project-a',
      sessions: const [
        AcpSessionEntry(
          id: 'session-a',
          cwd: '/workspace/project-a',
          title: 'Conversation A',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            agents: [
              _agent(() async => [project]),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == 'Filter sessions' &&
            node.hint == 'Search sessions...' &&
            node.getSemanticsData().flagsCollection.isTextField,
      ),
      findsOne,
    );
    semantics.dispose();
  });

  testWidgets('ResumeSessionDialog loads only the selected agent catalog', (
    tester,
  ) async {
    var codexLoads = 0;
    var piLoads = 0;
    final codexProject = AcpProjectSessions(
      cwd: '/workspace/codex-project',
      sessions: const [
        AcpSessionEntry(
          id: 'codex-session',
          cwd: '/workspace/codex-project',
          title: 'Codex session',
        ),
      ],
    );
    final piProject = AcpProjectSessions(
      cwd: '/workspace/pi-project',
      sessions: const [
        AcpSessionEntry(
          id: 'pi-session',
          cwd: '/workspace/pi-project',
          title: 'Pi session',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            agents: [
              _agent(() async {
                codexLoads += 1;
                return [codexProject];
              }),
              _agent(
                () async {
                  piLoads += 1;
                  return [piProject];
                },
                id: 'pi',
                name: 'pi ACP',
                isCurrent: false,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(codexLoads, 1);
    expect(piLoads, 0);
    expect(find.text('Codex session'), findsWidgets);

    final agentList = find.byKey(const ValueKey('resume-agent-list'));
    await tester.tap(
      find.descendant(of: agentList, matching: find.text('pi ACP')),
    );
    await tester.pumpAndSettle();

    expect(codexLoads, 1);
    expect(piLoads, 1);
    expect(find.text('Pi session'), findsWidgets);
    expect(find.text('Codex session'), findsNothing);

    await tester.tap(
      find.descendant(of: agentList, matching: find.text('Codex')),
    );
    await tester.pumpAndSettle();

    expect(codexLoads, 1);
    expect(piLoads, 1);
    expect(find.text('Codex session'), findsWidgets);
  });

  testWidgets('ResumeSessionDialog explains a busy current agent locally', (
    tester,
  ) async {
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            agents: [
              _agent(
                () async {
                  loads += 1;
                  return const <AcpProjectSessions>[];
                },
                enabled: false,
                description: 'Session operation in progress',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Sessions for Codex'), findsOneWidget);
    expect(find.text('Session operation in progress'), findsNWidgets(2));
    expect(
      find.textContaining('cannot list sessions right now'),
      findsOneWidget,
    );
    expect(loads, 0);
    expect(_loadButton(tester).onPressed, isNull);
  });

  testWidgets('ResumeSessionDialog authenticates an agent from the banner', (
    tester,
  ) async {
    var authenticationCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ResumeSessionDialog(
            agents: [
              _agent(() async => const <AcpProjectSessions>[]),
              _agent(
                () async => const <AcpProjectSessions>[],
                id: 'pi',
                name: 'pi ACP',
                isCurrent: false,
                description: 'Authentication required',
                authenticate: () async {
                  authenticationCalls += 1;
                  return true;
                },
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('pi ACP needs new credentials to list sessions.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(OutlinedButton, 'Authenticate'));
    await tester.pumpAndSettle();

    expect(authenticationCalls, 1);
    expect(
      find.text('pi ACP needs new credentials to list sessions.'),
      findsNothing,
    );
  });

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
          body: ResumeSessionDialog(agents: [_agent(() async => projects)]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byWidgetPredicate((widget) => widget is DropdownButtonFormField),
      findsNothing,
    );
    final sessionListFinder = find.byKey(const ValueKey('resume-session-list'));
    expect(sessionListFinder, findsOneWidget);
    expect(tester.widget<ListView>(sessionListFinder).primary, isFalse);
    expect(projects.itemReads, lessThan(128));
    expect(conversations.itemReads, lessThan(128));
    expect(find.text('Conversation 1023'), findsNothing);

    await tester.enterText(
      find.byKey(const ValueKey('resume-session-search')),
      'Conversation 1023',
    );
    await tester.pumpAndSettle();
    expect(find.text('Conversation 1023'), findsWidgets);
    await tester.tap(find.byKey(const ValueKey('resume-session-session-1023')));
    await tester.pumpAndSettle();
    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('resume-session-search')),
      'project-1023',
    );
    await tester.pumpAndSettle();
    expect(find.text('project-1023'), findsWidgets);
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
                      agents: [
                        _agent(() async => [project]),
                      ],
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

    expect(find.text('Select Agent'), findsOneWidget);
    expect(find.text('Sessions for Codex'), findsOneWidget);
    expect(find.text('project-a'), findsOneWidget);
    expect(find.text('Resume this project conversation'), findsOneWidget);
    expect(find.byIcon(Icons.smart_toy_outlined), findsNothing);
    expect(find.text('Open Session'), findsOneWidget);

    await tester.tap(find.text('Open Session'));
    await tester.pumpAndSettle();

    expect(selection?.project.cwd, '/workspace/project-a');
    expect(selection?.conversation.id, 'session-a');
    expect(selection?.agentName, 'Codex');
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
          body: ResumeSessionDialog(
            agents: [
              _agent(() async => [project]),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('resume-session-session-a')));
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
            agents: [
              _agent(() async => [project]),
            ],
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

    await tester.tap(find.byKey(const ValueKey('resume-session-session-a')));
    await tester.pumpAndSettle();
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
          body: ResumeSessionDialog(
            agents: [
              _agent(() async => [project]),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resume-session-session-a')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    expect(find.textContaining('SESSION_A_CANARY'), findsOneWidget);

    await tester.tap(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('resume-session-session-a')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resume-session-session-a')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('resume-session-session-b')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resume-session-session-b')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('resume-session-session-b')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resume-session-session-b')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Metadata'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Metadata'));
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
              agents: [
                _agent(() async => [project]),
              ],
              inputBudget: inputBudget,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('resume-session-session-a')));
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
      find.textContaining(
        'folders this session can use for local files and terminal commands',
      ),
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
            agents: [
              _agent(() async => [projectA, projectB]),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('resume-session-search')),
      'other',
    );
    await tester.pumpAndSettle();

    expect(find.text('other'), findsWidgets);
    expect(find.text('Alpha chat'), findsNothing);
    expect(find.text('Other chat'), findsOneWidget);
    expect(_loadButton(tester).onPressed, isNull);

    await tester.tap(
      find.byKey(const ValueKey('resume-session-session-other')),
    );
    await tester.pumpAndSettle();

    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.enterText(
      find.byKey(const ValueKey('resume-session-search')),
      'beta',
    );
    await tester.pumpAndSettle();
    expect(find.text('Other chat'), findsNothing);
    expect(_loadButton(tester).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('resume-session-session-beta')));
    await tester.pumpAndSettle();

    expect(find.text('Beta task'), findsOneWidget);
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
            agents: [
              _agent(() async {
                loadCount += 1;
                if (loadCount == 1) return [project];
                throw Exception('refresh failed');
              }),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(_loadButton(tester).onPressed, isNotNull);

    await tester.tap(find.widgetWithText(TextButton, 'Refresh'));
    await tester.pumpAndSettle();

    expect(find.text('Could not list Codex sessions'), findsOneWidget);
    expect(find.textContaining('refresh failed'), findsOneWidget);
    expect(_loadButton(tester).onPressed, isNull);
  });
}

FilledButton _loadButton(WidgetTester tester) {
  return tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Open Session'),
  );
}

ResumeSessionAgentOption _agent(
  Future<List<AcpProjectSessions>> Function() loadSessions, {
  String id = 'codex',
  String name = 'Codex',
  bool isCurrent = true,
  bool enabled = true,
  String description = 'Ready',
  Future<bool> Function()? authenticate,
}) {
  return ResumeSessionAgentOption(
    id: id,
    name: name,
    isCurrent: isCurrent,
    enabled: enabled,
    description: description,
    authenticate: authenticate,
    loadSessions: loadSessions,
  );
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
