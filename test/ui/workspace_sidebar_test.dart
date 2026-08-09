import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/session_time_label.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/workspace/workspace.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

void main() {
  testWidgets('WorkspaceSidebar manually adds a workspace directory', (
    tester,
  ) async {
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const [],
    );
    final store = _MemoryWorkspaceSidebarStateStore(<String>{});

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              workspaces: [currentWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
              pickWorkspaceDirectory: () async => '/workspace/manual',
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-workspace-button')));
    await tester.pumpAndSettle();

    expect(find.text('manual'), findsOneWidget);
    expect(store.expandedWorkspacePaths, contains('/workspace/manual'));
    expect(
      store.workspaceStates.any(
        (state) => state.path == '/workspace/manual' && state.manuallyAdded,
      ),
      isTrue,
    );
  });

  testWidgets('WorkspaceSidebar expands workspaces before selecting sessions', (
    tester,
  ) async {
    AgentSession? selected;
    final currentSession = AgentSession(
      id: 'current',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final olderOther = AgentSession(
      id: 'older-other',
      cwd: '/workspace/other',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Older other work',
      agentName: 'Codex',
    );
    final newerOther = AgentSession(
      id: 'newer-other',
      cwd: '/workspace/other',
      createdAt: DateTime(2026, 5, 2, 10),
      title: 'Newer other work',
      agentName: 'Kimi',
    );
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: [newerOther, olderOther],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              onSelectSession: (session) => selected = session,
            ),
          ),
        ),
      ),
    );

    expect(find.text('Current work'), findsOneWidget);
    expect(find.text('Newer other work'), findsNothing);
    expect(find.text('Older other work'), findsNothing);

    await tester.tap(find.byTooltip('Expand other'));
    await tester.pump();

    expect(selected, isNull);
    expect(find.text('Newer other work'), findsOneWidget);
    expect(find.text('Older other work'), findsOneWidget);

    await tester.tap(find.text('Newer other work'));
    await tester.pump();

    expect(selected, newerOther);
  });

  testWidgets('WorkspaceSidebar session semantics can activate a session', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    AgentSession? selected;
    final session = AgentSession(
      id: 'accessible-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Accessible session',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [session],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              onSelectSession: (value) => selected = value,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    tester.semantics.tap(find.semantics.byLabel(RegExp('Accessible session')));
    await tester.pump();

    expect(selected, same(session));
    semantics.dispose();
  });

  testWidgets('WorkspaceSidebar opens the top session from a workspace row', (
    tester,
  ) async {
    AgentSession? selected;
    final currentSession = AgentSession(
      id: 'current',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final olderOther = AgentSession(
      id: 'older-other',
      cwd: '/workspace/other',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Older other work',
      agentName: 'Codex',
    );
    final pinnedOther = AgentSession(
      id: 'pinned-other',
      cwd: '/workspace/other',
      createdAt: DateTime(2026, 5, 2, 10),
      title: 'Pinned other work',
      agentName: 'Codex',
      pinned: true,
    );
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: [pinnedOther, olderOther],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              onSelectSession: (session) => selected = session,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('other'));
    await tester.pump();

    expect(selected, pinnedOther);
    expect(find.text('Pinned other work'), findsNothing);
  });

  testWidgets('WorkspaceSidebar keeps workspace order when current changes', (
    tester,
  ) async {
    final firstSession = AgentSession(
      id: 'first-session',
      cwd: '/workspace/first',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'First work',
      agentName: 'Codex',
    );
    final secondSession = AgentSession(
      id: 'second-session',
      cwd: '/workspace/second',
      createdAt: DateTime(2026, 5, 2, 10),
      title: 'Second work',
      agentName: 'Codex',
    );
    final firstWorkspace = WorkspaceRecord(
      path: '/workspace/first',
      name: 'first',
      sessions: [firstSession],
    );
    final secondWorkspace = WorkspaceRecord(
      path: '/workspace/second',
      name: 'second',
      sessions: [secondSession],
    );

    Widget buildSidebar({
      required WorkspaceRecord currentWorkspace,
      required AgentSession currentSession,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [firstWorkspace, secondWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      );
    }

    double workspaceTop(String label) {
      return tester.getTopLeft(find.text(label).first).dy;
    }

    await tester.pumpWidget(
      buildSidebar(
        currentWorkspace: firstWorkspace,
        currentSession: firstSession,
      ),
    );

    expect(workspaceTop('first'), lessThan(workspaceTop('second')));

    await tester.pumpWidget(
      buildSidebar(
        currentWorkspace: secondWorkspace,
        currentSession: secondSession,
      ),
    );
    await tester.pump();

    expect(workspaceTop('first'), lessThan(workspaceTop('second')));
  });

  testWidgets('WorkspaceSidebar shows an empty state for new workspaces', (
    tester,
  ) async {
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Workspaces'), findsOneWidget);
    expect(find.text('No sessions yet'), findsOneWidget);
    expect(find.text('Sessions'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'New Session'), findsNothing);
  });

  testWidgets('WorkspaceSidebar filters workspaces from the search field', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    expect(
      find.widgetWithText(TextField, 'Search workspaces...'),
      findsOneWidget,
    );
    expect(
      tester
          .getSize(find.widgetWithText(TextField, 'Search workspaces...'))
          .height,
      34,
    );
    expect(find.bySemanticsLabel('2 workspaces'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'current.*0 sessions')),
      findsOneWidget,
    );
    expect(
      find.semantics.byPredicate(
        (node) =>
            node.label == 'Search workspaces' &&
            node.hint == 'Filter the workspace list' &&
            node.getSemanticsData().flagsCollection.isTextField,
      ),
      findsOne,
    );

    await tester.enterText(
      find.widgetWithText(TextField, 'Search workspaces...'),
      'other',
    );
    await tester.pump();

    expect(find.text('other'), findsNWidgets(2));
    final clearSearchSemantics = tester.getSemantics(
      find.byTooltip('Clear workspace search'),
    );
    expect(clearSearchSemantics.tooltip, 'Clear workspace search');
    expect(find.text('current'), findsNothing);

    tester.semantics.tap(
      find.semantics.byPredicate(
        (node) => node.tooltip == 'Clear workspace search',
      ),
    );
    await tester.pump();

    expect(find.text('current'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('WorkspaceSidebar restores and saves expanded workspaces', (
    tester,
  ) async {
    final store = _MemoryWorkspaceSidebarStateStore({'/workspace/other'});

    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: [
        AgentSession(
          id: 'other-session',
          cwd: '/workspace/other',
          createdAt: DateTime(2026, 5, 1, 10),
          title: 'Other loaded session',
          agentName: 'Codex',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Other loaded session'), findsOneWidget);

    await tester.tap(find.text('other'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));

    expect(find.text('Other loaded session'), findsNothing);
    expect(store.expandedWorkspacePaths, isNot(contains('/workspace/other')));
  });

  testWidgets('WorkspaceSidebar persists collapsing the current workspace', (
    tester,
  ) async {
    final store = _MemoryWorkspaceSidebarStateStore({'/workspace/current'});
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Current work'), findsOneWidget);

    await tester.tap(find.byTooltip('Collapse current'));
    await tester.pumpAndSettle();

    expect(find.text('Current work'), findsNothing);
    expect(store.expandedWorkspacePaths, isNot(contains('/workspace/current')));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Current work'), findsNothing);
  });

  testWidgets(
    'WorkspaceSidebar defaults current workspace open before state is saved',
    (tester) async {
      final store = _MemoryWorkspaceSidebarStateStore(
        const <String>{},
        hasSavedExpandedPaths: false,
      );
      final currentSession = AgentSession(
        id: 'current-session',
        cwd: '/workspace/current',
        createdAt: DateTime(2026, 5, 1, 10),
        title: 'Current work',
        agentName: 'Codex',
      );
      final currentWorkspace = WorkspaceRecord(
        path: '/workspace/current',
        name: 'current',
        sessions: [currentSession],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 520,
              child: WorkspaceSidebar(
                agentName: 'Codex',
                workspaces: [currentWorkspace],
                currentWorkspace: currentWorkspace,
                currentSession: currentSession,
                onNewSession: () {},
                onResumeSession: () {},
                stateStore: store,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      expect(find.text('Current work'), findsOneWidget);
    },
  );

  testWidgets('WorkspaceSidebar restores workspace metadata', (tester) async {
    final store = _MemoryWorkspaceSidebarStateStore(
      const <String>{},
      initialWorkspaceStates: const [
        WorkspaceSidebarWorkspaceState(
          path: '/workspace/pinned',
          displayName: 'Pinned Alias',
          pinned: true,
        ),
        WorkspaceSidebarWorkspaceState(path: '/workspace/hidden', hidden: true),
      ],
    );
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final hiddenWorkspace = WorkspaceRecord(
      path: '/workspace/hidden',
      name: 'hidden',
      sessions: const <AgentSession>[],
    );
    final pinnedWorkspace = WorkspaceRecord(
      path: '/workspace/pinned',
      name: 'pinned',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, hiddenWorkspace, pinnedWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    expect(find.text('Pinned Alias'), findsOneWidget);
    expect(find.text('hidden'), findsNothing);
  });

  testWidgets('WorkspaceSidebar ignores stale state store restores', (
    tester,
  ) async {
    final staleStore = _DelayedWorkspaceSidebarStateStore(path: 'memory-a');
    final currentStore = _MemoryWorkspaceSidebarStateStore(
      {'/workspace/b'},
      path: 'memory-b',
      initialWorkspaceStates: const [
        WorkspaceSidebarWorkspaceState(
          path: '/workspace/b',
          displayName: 'Current Alias',
          pinned: true,
        ),
      ],
    );
    final selectedStore = ValueNotifier<WorkspaceSidebarStateStore>(staleStore);
    addTearDown(selectedStore.dispose);
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final workspaceA = WorkspaceRecord(
      path: '/workspace/a',
      name: 'workspace-a',
      sessions: [
        AgentSession(
          id: 'session-a',
          cwd: '/workspace/a',
          createdAt: DateTime(2026, 5, 1),
          title: 'Session A',
        ),
      ],
    );
    final workspaceB = WorkspaceRecord(
      path: '/workspace/b',
      name: 'workspace-b',
      sessions: [
        AgentSession(
          id: 'session-b',
          cwd: '/workspace/b',
          createdAt: DateTime(2026, 5, 2),
          title: 'Session B',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: ValueListenableBuilder<WorkspaceSidebarStateStore>(
              valueListenable: selectedStore,
              builder: (context, store, _) => WorkspaceSidebar(
                workspaces: [currentWorkspace, workspaceA, workspaceB],
                currentWorkspace: currentWorkspace,
                currentSession: null,
                onNewSession: () {},
                onResumeSession: () {},
                stateStore: store,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(staleStore.expandedLoadStarted.isCompleted, isTrue);
    expect(staleStore.workspaceLoadStarted.isCompleted, isTrue);

    selectedStore.value = currentStore;
    await tester.pumpAndSettle();

    expect(find.text('Current Alias'), findsOneWidget);
    expect(find.text('Session B'), findsOneWidget);
    expect(find.text('Session A'), findsNothing);

    staleStore.complete(
      expandedPaths: {'/workspace/a'},
      workspaceStates: const [
        WorkspaceSidebarWorkspaceState(
          path: '/workspace/a',
          displayName: 'Stale Alias',
          pinned: true,
        ),
      ],
    );
    await tester.pumpAndSettle();

    expect(find.text('Current Alias'), findsOneWidget);
    expect(find.text('Stale Alias'), findsNothing);
    expect(find.text('Session B'), findsOneWidget);
    expect(find.text('Session A'), findsNothing);
  });

  testWidgets(
    'WorkspaceSidebar auto-loads the current workspace on first render',
    (tester) async {
      final completer = Completer<void>();
      var loadCount = 0;
      WorkspaceRecord? loadedWorkspace;
      final currentWorkspace = WorkspaceRecord(
        path: '/workspace/current',
        name: 'current',
        sessions: const <AgentSession>[],
      );
      final otherWorkspace = WorkspaceRecord(
        path: '/workspace/other',
        name: 'other',
        sessions: const <AgentSession>[],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 520,
              child: WorkspaceSidebar(
                agentName: 'Codex',
                workspaces: [currentWorkspace, otherWorkspace],
                currentWorkspace: currentWorkspace,
                currentSession: null,
                onNewSession: () {},
                onResumeSession: () {},
                onLoadWorkspaceSessions: (workspace) {
                  loadCount += 1;
                  loadedWorkspace = workspace;
                  return completer.future;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));

      expect(loadCount, 1);
      expect(loadedWorkspace, currentWorkspace);
      expect(find.text('Loading sessions in current...'), findsOneWidget);

      await tester.tap(find.text('other'));
      await tester.pump();

      expect(loadCount, 2);
      expect(loadedWorkspace, otherWorkspace);
      expect(find.text('Loading sessions in other...'), findsOneWidget);

      completer.complete();
      await tester.pumpAndSettle();

      expect(find.text('No sessions in other'), findsOneWidget);
    },
  );

  testWidgets('WorkspaceSidebar auto-loads each workspace independently', (
    tester,
  ) async {
    final loadedPaths = <String>[];
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final firstWorkspace = WorkspaceRecord(
      path: '/workspace/first',
      name: 'first',
      sessions: const <AgentSession>[],
    );
    final secondWorkspace = WorkspaceRecord(
      path: '/workspace/second',
      name: 'second',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, firstWorkspace, secondWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              onLoadWorkspaceSessions: (workspace) async {
                loadedPaths.add(workspace.path);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('second'));
    await tester.pumpAndSettle();

    expect(loadedPaths, [
      '/workspace/current',
      '/workspace/first',
      '/workspace/second',
    ]);
  });

  testWidgets('WorkspaceSidebar starts new sessions in expanded workspace', (
    tester,
  ) async {
    WorkspaceRecord? newSessionWorkspace;
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onNewSessionInWorkspace: (workspace) {
                newSessionWorkspace = workspace;
              },
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    final otherCenter = tester.getCenter(find.text('other'));
    await mouse.moveTo(otherCenter);
    await tester.pump();

    await tester.tap(find.byTooltip('Workspace actions').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Session').last);
    await tester.pumpAndSettle();

    expect(newSessionWorkspace?.path, otherWorkspace.path);
  });

  testWidgets('WorkspaceSidebar exposes workspace action menu', (tester) async {
    WorkspaceRecord? revealed;
    WorkspaceRecord? worktreeWorkspace;
    var newSessionCount = 0;
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [
        AgentSession(
          id: 'current-session',
          cwd: '/workspace/current',
          createdAt: DateTime(2026, 5, 1, 10),
          title: 'Current work',
          agentName: 'Codex',
        ),
      ],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: workspace.sessions.single,
              onNewSession: () => newSessionCount += 1,
              onResumeSession: () {},
              onRevealWorkspace: (workspace) => revealed = workspace,
              onCreateWorkspaceWorktree: (workspace) =>
                  worktreeWorkspace = workspace,
              gitWorkspaceDetector: (_) => true,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();

    expect(find.text('New Session'), findsOneWidget);
    expect(find.text('Pin Project'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Create Permanent Worktree'), findsOneWidget);
    expect(find.text('Rename Project'), findsOneWidget);
    expect(find.text('Archive Conversations'), findsOneWidget);
    expect(find.text('Hide from Sidebar'), findsOneWidget);

    await tester.tap(find.text('Create Permanent Worktree'));
    await tester.pumpAndSettle();
    expect(worktreeWorkspace, workspace);

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show in Finder'));
    await tester.pumpAndSettle();
    expect(revealed, workspace);

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New Session'));
    await tester.pump();
    expect(newSessionCount, 1);
  });

  testWidgets('WorkspaceSidebar hides worktree actions outside Git', (
    tester,
  ) async {
    final session = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [session],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: session,
              onNewSession: () {},
              onResumeSession: () {},
              onCreateWorkspaceWorktree: (_) {},
              canForkSession: (_) => true,
              onSessionMenuAction: (_, _) {},
              gitWorkspaceDetector: (_) => false,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    expect(find.text('Create Permanent Worktree'), findsNothing);
    await tester.tap(find.text('New Session'));
    await tester.pumpAndSettle();

    await tester.tapAt(
      tester.getCenter(find.text('Current work')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    expect(find.text('Fork Locally'), findsOneWidget);
    expect(find.text('Fork to New Worktree'), findsNothing);
  });

  testWidgets('WorkspaceSidebar loads sessions when expanding a workspace', (
    tester,
  ) async {
    final store = _MemoryWorkspaceSidebarStateStore(const <String>{});
    final loadedPaths = <String>[];
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 560,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              onLoadWorkspaceSessions: (workspace) async {
                loadedPaths.add(workspace.path);
              },
              stateStore: store,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    loadedPaths.clear();

    await tester.tap(find.text('other'));
    await tester.pumpAndSettle();

    expect(loadedPaths, ['/workspace/other']);
    expect(store.expandedWorkspacePaths, contains('/workspace/other'));
    expect(find.text('No sessions in other'), findsOneWidget);
  });

  testWidgets('WorkspaceSidebar exposes workspace context menu', (
    tester,
  ) async {
    WorkspaceRecord? revealed;
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              onRevealWorkspace: (workspace) => revealed = workspace,
              gitWorkspaceDetector: (_) => true,
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('current')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Pin Project'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Create Permanent Worktree'), findsOneWidget);
    expect(find.text('Rename Project'), findsOneWidget);
    expect(find.text('Archive Conversations'), findsOneWidget);
    expect(find.text('Hide from Sidebar'), findsOneWidget);

    await tester.tap(find.text('Show in Finder'));
    await tester.pumpAndSettle();
    expect(revealed, workspace);
  });

  testWidgets('WorkspaceSidebar exposes session action menu', (tester) async {
    AgentSession? actionSession;
    WorkspaceSessionMenuAction? action;
    final session = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [session],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: session,
              onNewSession: () {},
              onResumeSession: () {},
              canForkSession: (_) => true,
              onSessionMenuAction: (session, selectedAction) {
                actionSession = session;
                action = selectedAction;
              },
              gitWorkspaceDetector: (_) => true,
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Current work')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Pin Conversation'), findsOneWidget);
    expect(find.text('Rename Conversation'), findsOneWidget);
    expect(find.text('Archive Conversation'), findsOneWidget);
    expect(find.text('Mark as Unread'), findsOneWidget);
    expect(find.text('Open Side Session'), findsOneWidget);
    expect(find.text('Copy Session ID'), findsOneWidget);
    expect(find.text('Copy Deep Link'), findsOneWidget);
    expect(find.text('Copy as Markdown'), findsOneWidget);
    expect(find.text('Fork Locally'), findsOneWidget);
    expect(find.text('Fork to New Worktree'), findsOneWidget);
    expect(find.text('Open in New Window'), findsOneWidget);

    await tester.tap(find.text('Copy Session ID'));
    await tester.pumpAndSettle();

    expect(actionSession, session);
    expect(action, WorkspaceSessionMenuAction.copySessionId);
  });

  testWidgets('WorkspaceSidebar keeps active session aligned with history', (
    tester,
  ) async {
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final historySession = AgentSession(
      id: 'history-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 9),
      title: 'History work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, historySession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    final activeTile = find.byKey(
      const Key('workspace-session-active:current-session'),
    );
    final historyRow = find.byKey(
      const Key('workspace-session-history:history-session'),
    );

    expect(
      find.byKey(const Key('workspace-project-strip:/workspace/current')),
      findsOneWidget,
    );
    expect(activeTile, findsOneWidget);
    expect(historyRow, findsOneWidget);
    expect(
      tester.getRect(activeTile).height,
      moreOrLessEquals(tester.getRect(historyRow).height),
    );
    expect(
      tester.getRect(activeTile).left,
      moreOrLessEquals(tester.getRect(historyRow).left),
    );
    expect(
      tester.getRect(activeTile).left,
      moreOrLessEquals(
        tester
            .getRect(
              find.byKey(
                const Key('workspace-project-strip:/workspace/current'),
              ),
            )
            .left,
      ),
    );
    expect(
      (tester.widget<Container>(activeTile).decoration as BoxDecoration).color,
      isNot(Colors.transparent),
    );
    expect(
      (tester.widget<Container>(historyRow).decoration as BoxDecoration).color,
      Colors.transparent,
    );
    expect(find.byIcon(Icons.chat_bubble_outline_rounded), findsNothing);
  });

  testWidgets(
    'WorkspaceSidebar lists sessions flat and exposes agent in preview',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final currentSession = AgentSession(
        id: 'current-session',
        cwd: '/workspace/current',
        createdAt: DateTime(2026, 5, 1, 10),
        title: 'Current work',
        agentName: 'Codex',
      );
      final fastSession = AgentSession(
        id: 'fast-session',
        cwd: '/workspace/current',
        createdAt: DateTime(2026, 5, 1, 9),
        title: 'Fast follow-up',
        agentName: 'codex-fast',
      );
      final codexHistory = AgentSession(
        id: 'codex-history',
        cwd: '/workspace/current',
        createdAt: DateTime(2026, 5, 1, 8),
        title: 'Codex history',
        agentName: 'Codex',
      );
      final workspace = WorkspaceRecord(
        path: '/workspace/current',
        name: 'current',
        sessions: [currentSession, fastSession, codexHistory],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 340,
              height: 520,
              child: WorkspaceSidebar(
                agentName: 'Codex',
                workspaces: [workspace],
                currentWorkspace: workspace,
                currentSession: currentSession,
                onNewSession: () {},
                onResumeSession: () {},
              ),
            ),
          ),
        ),
      );

      final fastRow = find.byKey(
        const Key('workspace-session-history:fast-session'),
      );
      final codexHistoryRow = find.byKey(
        const Key('workspace-session-history:codex-history'),
      );

      expect(fastRow, findsOneWidget);
      expect(codexHistoryRow, findsOneWidget);
      expect(
        tester.getTopLeft(fastRow).dy,
        lessThan(tester.getTopLeft(codexHistoryRow).dy),
      );

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(fastRow));
      await tester.pump(const Duration(milliseconds: 250));
      final preview = find.byKey(
        const Key('workspace-session-preview:fast-session'),
      );
      expect(
        find.descendant(of: preview, matching: find.text('codex-fast')),
        findsOneWidget,
      );
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 150));
    },
  );

  testWidgets('WorkspaceSidebar limits workspace sessions until expanded', (
    tester,
  ) async {
    final sessions = List<AgentSession>.generate(14, (index) {
      final number = index + 1;
      return AgentSession(
        id: 'session-$number',
        cwd: '/workspace/current',
        createdAt: DateTime(2026, 5, number, 10),
        title: 'Session $number',
        agentName: 'Codex',
      );
    });
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: sessions,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 340,
            height: 640,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: sessions.first,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.text('Session 12'), findsOneWidget);
    expect(find.text('Session 13'), findsNothing);
    expect(find.text('Session 14'), findsNothing);
    expect(find.text('展开显示'), findsOneWidget);

    await tester.tap(find.text('展开显示'));
    await tester.pump();

    expect(find.text('Session 13'), findsOneWidget);
    expect(find.text('Session 14'), findsOneWidget);
    expect(find.text('折叠显示'), findsOneWidget);

    await tester.ensureVisible(find.text('折叠显示'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('折叠显示'));
    await tester.pump();

    expect(find.text('Session 13'), findsNothing);
    expect(find.text('Session 14'), findsNothing);
    expect(find.text('展开显示'), findsOneWidget);
  });

  testWidgets('WorkspaceSidebar only highlights the active agent session', (
    tester,
  ) async {
    AgentSession? selectedSession;
    final currentSession = AgentSession(
      id: 'shared-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Codex active work',
      agentName: 'Codex',
    );
    final kimiSession = AgentSession(
      id: 'shared-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 9),
      title: 'Kimi same id work',
      agentName: 'Kimi',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, kimiSession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              onSelectSession: (session) => selectedSession = session,
            ),
          ),
        ),
      ),
    );

    expect(
      find.byKey(const Key('workspace-session-active:shared-session')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('workspace-session-history:shared-session')),
      findsOneWidget,
    );

    await tester.tap(find.text('Kimi same id work'));
    expect(selectedSession, kimiSession);
  });

  testWidgets('WorkspaceSidebar shows relative time in session preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final now = DateTime(2026, 7, 8, 12);
    debugSessionTimeNow = () => now;
    addTearDown(() {
      debugSessionTimeNow = null;
    });
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: now.subtract(const Duration(minutes: 5)),
      title: 'Current work',
      agentName: 'Codex',
    );
    final historySession = AgentSession(
      id: 'history-session',
      cwd: '/workspace/current',
      createdAt: now.subtract(const Duration(hours: 2)),
      title: 'History work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, historySession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);

    await mouse.moveTo(tester.getCenter(find.text('Current work')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('5m ago'), findsOneWidget);

    await mouse.moveTo(tester.getCenter(find.text('History work')));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2h ago'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 150));
  });

  testWidgets('WorkspaceSidebar leaves project row neutral without a session', (
    tester,
  ) async {
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    final projectStrip = tester.widget<Container>(
      find.byKey(const Key('workspace-project-strip:/workspace/current')),
    );
    final groupFrame = tester.widget<Container>(
      find.byKey(const Key('workspace-group:/workspace/current')),
    );
    final stripDecoration = projectStrip.decoration! as BoxDecoration;
    final groupDecoration = groupFrame.decoration! as BoxDecoration;

    expect(stripDecoration.color, Colors.transparent);
    expect(stripDecoration.border, isNull);
    expect(groupDecoration.color, Colors.transparent);
    expect(groupDecoration.border, isNull);
  });

  testWidgets('WorkspaceSidebar keeps workspace row height stable on hover', (
    tester,
  ) async {
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
            ),
          ),
        ),
      ),
    );

    final groupFrame = find.byKey(
      const Key('workspace-group:/workspace/other'),
    );
    final projectStrip = find.byKey(
      const Key('workspace-project-strip:/workspace/other'),
    );
    final beforeGroupHeight = tester.getRect(groupFrame).height;
    final beforeStripHeight = tester.getRect(projectStrip).height;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('other')));
    await tester.pump();

    expect(tester.getRect(groupFrame).height, beforeGroupHeight);
    expect(tester.getRect(projectStrip).height, beforeStripHeight);
  });

  testWidgets('WorkspaceSidebar keeps session row height stable on hover', (
    tester,
  ) async {
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final historySession = AgentSession(
      id: 'history-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 9),
      title: 'History work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, historySession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              onSessionMenuAction: (_, _) {},
            ),
          ),
        ),
      ),
    );

    final historyRow = find.byKey(
      const Key('workspace-session-history:history-session'),
    );
    final beforeHoverHeight = tester.getRect(historyRow).height;

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('History work')));
    await tester.pump();

    expect(tester.getRect(historyRow).height, beforeHoverHeight);
  });

  testWidgets('WorkspaceSidebar shows session actions on hover', (
    tester,
  ) async {
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final otherSession = AgentSession(
      id: 'other-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 11),
      title: 'Other work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, otherSession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              canForkSession: (_) => true,
              onSessionMenuAction: (_, _) {},
            ),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Pin Conversation'), findsNothing);
    expect(find.byTooltip('Archive Conversation'), findsNothing);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Other work')));
    await tester.pump();

    expect(find.byTooltip('Pin Conversation'), findsOneWidget);
    expect(find.byTooltip('Archive Conversation'), findsOneWidget);

    await mouse.moveTo(Offset.zero);
    await tester.pump();

    expect(find.byTooltip('Pin Conversation'), findsNothing);
    expect(find.byTooltip('Archive Conversation'), findsNothing);
  });

  testWidgets('WorkspaceSidebar shows Codex-style session preview on hover', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final historySession = AgentSession(
      id: 'history-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 9),
      title: 'Evaluate main branch',
      agentName: 'Codex',
      initialEvents: const [
        AgentEvent(
          type: AgentEventType.status,
          text: '',
          metadata: {
            'branch': 'codex/workspace-sidebar-actions',
            'ciStatus': 'No CI checks',
          },
        ),
        AgentEvent(
          type: AgentEventType.agentTextDone,
          text: 'Advance the Rust ACP runtime and workspace tooling.',
        ),
      ],
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, historySession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 300,
                height: 520,
                child: WorkspaceSidebar(
                  agentName: 'Codex',
                  workspaces: [workspace],
                  currentWorkspace: workspace,
                  currentSession: currentSession,
                  onNewSession: () {},
                  onResumeSession: () {},
                  canForkSession: (_) => true,
                  onSessionMenuAction: (_, _) {},
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final historyRow = find.byKey(
      const Key('workspace-session-history:history-session'),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(historyRow));
    await tester.pump(const Duration(milliseconds: 250));

    final preview = find.byKey(
      const Key('workspace-session-preview:history-session'),
    );
    expect(preview, findsOneWidget);
    expect(
      find.descendant(of: preview, matching: find.text('current')),
      findsOneWidget,
    );
    expect(find.text('codex/workspace-sidebar-actions'), findsOneWidget);
    expect(
      find.text('Advance the Rust ACP runtime and workspace tooling.'),
      findsOneWidget,
    );
    expect(find.text('No CI checks'), findsOneWidget);
    expect(tester.getRect(preview).width, 320);
    expect(tester.getRect(preview).height, inInclusiveRange(130, 150));

    await mouse.moveTo(Offset.zero);
    await tester.pump(const Duration(milliseconds: 150));
    expect(preview, findsNothing);
  });

  testWidgets('WorkspaceSidebar avoids covering narrow content with preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final historySession = AgentSession(
      id: 'history-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 9),
      title: 'Evaluate main branch',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [historySession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 300,
                child: WorkspaceSidebar(
                  agentName: 'Codex',
                  workspaces: [workspace],
                  currentWorkspace: workspace,
                  currentSession: null,
                  onNewSession: () {},
                  onResumeSession: () {},
                ),
              ),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(
        find.byKey(const Key('workspace-session-history:history-session')),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(
      find.byKey(const Key('workspace-session-preview:history-session')),
      findsNothing,
    );
  });

  testWidgets('WorkspaceSidebar keeps inactive session menu actions mounted', (
    tester,
  ) async {
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final otherSession = AgentSession(
      id: 'other-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 11),
      title: 'Other work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, otherSession],
    );
    WorkspaceSessionMenuAction? selectedAction;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              onSessionMenuAction: (_, action) => selectedAction = action,
            ),
          ),
        ),
      ),
    );

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Other work')));
    await tester.pump();

    await tester.tapAt(
      tester.getCenter(find.text('Other work')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.text('Copy Session ID')));
    await tester.pump();
    await tester.tap(find.text('Copy Session ID'));
    await tester.pumpAndSettle();

    expect(selectedAction, WorkspaceSessionMenuAction.copySessionId);
  });

  testWidgets('WorkspaceSidebar exposes session context menu from row', (
    tester,
  ) async {
    AgentSession? actionSession;
    WorkspaceSessionMenuAction? action;
    final currentSession = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final otherSession = AgentSession(
      id: 'other-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 11),
      title: 'Other work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [currentSession, otherSession],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: currentSession,
              onNewSession: () {},
              onResumeSession: () {},
              canForkSession: (_) => true,
              onSessionMenuAction: (session, selectedAction) {
                actionSession = session;
                action = selectedAction;
              },
              gitWorkspaceDetector: (_) => true,
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Other work')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    expect(find.text('Pin Conversation'), findsOneWidget);
    expect(find.text('Rename Conversation'), findsOneWidget);
    expect(find.text('Archive Conversation'), findsOneWidget);
    expect(find.text('Mark as Unread'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Copy Working Directory'), findsOneWidget);
    expect(find.text('Copy Session ID'), findsOneWidget);
    expect(find.text('Copy Deep Link'), findsOneWidget);
    expect(find.text('Fork Locally'), findsOneWidget);
    expect(find.text('Fork to New Worktree'), findsOneWidget);
    expect(find.text('Open in New Window'), findsOneWidget);

    await tester.tap(find.text('Archive Conversation'));
    await tester.pumpAndSettle();

    expect(actionSession, otherSession);
    expect(action, WorkspaceSessionMenuAction.archive);
  });

  testWidgets('WorkspaceSidebar disables fork actions when unsupported', (
    tester,
  ) async {
    final session = AgentSession(
      id: 'current-session',
      cwd: '/workspace/current',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Current work',
      agentName: 'Codex',
    );
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: [session],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: session,
              onNewSession: () {},
              onResumeSession: () {},
              canForkSession: (_) => false,
              onSessionMenuAction: (_, _) {},
              gitWorkspaceDetector: (_) => true,
            ),
          ),
        ),
      ),
    );

    await tester.tapAt(
      tester.getCenter(find.text('Current work')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();

    final forkLocallyItem = tester
        .widget<PopupMenuItem<WorkspaceSessionMenuAction>>(
          find.ancestor(
            of: find.text('Fork Locally'),
            matching: find.byType(PopupMenuItem<WorkspaceSessionMenuAction>),
          ),
        );
    final forkWorktreeItem = tester
        .widget<PopupMenuItem<WorkspaceSessionMenuAction>>(
          find.ancestor(
            of: find.text('Fork to New Worktree'),
            matching: find.byType(PopupMenuItem<WorkspaceSessionMenuAction>),
          ),
        );

    expect(forkLocallyItem.enabled, isFalse);
    expect(forkWorktreeItem.enabled, isFalse);
  });

  testWidgets('WorkspaceSidebar can locally rename a workspace', (
    tester,
  ) async {
    final store = _MemoryWorkspaceSidebarStateStore(const <String>{});
    final workspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [workspace],
              currentWorkspace: workspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename Project'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Renamed workspace',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Renamed workspace'), findsOneWidget);
    expect(find.text('current'), findsNothing);
    expect(store.workspaceStates.single.displayName, 'Renamed workspace');
  });

  testWidgets('WorkspaceSidebar persists pinned workspaces', (tester) async {
    final store = _MemoryWorkspaceSidebarStateStore(const <String>{});
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workspace actions').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin Project'));
    await tester.pump();

    expect(
      store.workspaceStates
          .where((state) => state.path == '/workspace/current')
          .single
          .pinned,
      isTrue,
    );
  });

  testWidgets('WorkspaceSidebar can undo removing a workspace', (tester) async {
    final store = _MemoryWorkspaceSidebarStateStore(const <String>{});
    final currentWorkspace = WorkspaceRecord(
      path: '/workspace/current',
      name: 'current',
      sessions: const <AgentSession>[],
    );
    final otherWorkspace = WorkspaceRecord(
      path: '/workspace/other',
      name: 'other',
      sessions: const <AgentSession>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 520,
            child: WorkspaceSidebar(
              agentName: 'Codex',
              workspaces: [currentWorkspace, otherWorkspace],
              currentWorkspace: currentWorkspace,
              currentSession: null,
              onNewSession: () {},
              onResumeSession: () {},
              stateStore: store,
            ),
          ),
        ),
      ),
    );

    expect(find.text('other'), findsOneWidget);

    await tester.tapAt(
      tester.getCenter(find.text('other')),
      buttons: kSecondaryMouseButton,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide from Sidebar'));
    await tester.pumpAndSettle();

    expect(find.text('other'), findsNothing);
    expect(
      store.workspaceStates
          .where((state) => state.path == '/workspace/other')
          .single
          .hidden,
      isTrue,
    );
    expect(find.text('Undo'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();

    expect(find.text('other'), findsOneWidget);
    expect(
      store.workspaceStates.where(
        (state) => state.path == '/workspace/other' && state.hidden,
      ),
      isEmpty,
    );
  });
}

class _MemoryWorkspaceSidebarStateStore extends WorkspaceSidebarStateStore {
  _MemoryWorkspaceSidebarStateStore(
    Set<String> initialPaths, {
    List<WorkspaceSidebarWorkspaceState> initialWorkspaceStates = const [],
    this.hasSavedExpandedPaths = true,
    String path = 'memory',
  }) : expandedWorkspacePaths = Set<String>.from(initialPaths),
       workspaceStates = List<WorkspaceSidebarWorkspaceState>.from(
         initialWorkspaceStates,
       ),
       super(path: path);

  Set<String> expandedWorkspacePaths;
  List<WorkspaceSidebarWorkspaceState> workspaceStates;
  bool hasSavedExpandedPaths;

  @override
  Future<Set<String>> loadExpandedWorkspacePaths() async {
    return Set<String>.from(expandedWorkspacePaths);
  }

  @override
  Future<bool> hasSavedExpandedWorkspacePaths() async {
    return hasSavedExpandedPaths;
  }

  @override
  Future<void> saveExpandedWorkspacePaths(Set<String> paths) async {
    expandedWorkspacePaths = Set<String>.from(paths);
    hasSavedExpandedPaths = true;
  }

  @override
  Future<List<WorkspaceSidebarWorkspaceState>> loadWorkspaceStates() async {
    return List<WorkspaceSidebarWorkspaceState>.from(workspaceStates);
  }

  @override
  Future<void> saveWorkspaceStates(
    Iterable<WorkspaceSidebarWorkspaceState> workspaces,
  ) async {
    workspaceStates = List<WorkspaceSidebarWorkspaceState>.from(workspaces);
  }
}

class _DelayedWorkspaceSidebarStateStore extends WorkspaceSidebarStateStore {
  _DelayedWorkspaceSidebarStateStore({required super.path});

  final Completer<void> expandedLoadStarted = Completer<void>();
  final Completer<void> workspaceLoadStarted = Completer<void>();
  final Completer<Set<String>> _expandedPaths = Completer<Set<String>>();
  final Completer<List<WorkspaceSidebarWorkspaceState>> _workspaceStates =
      Completer<List<WorkspaceSidebarWorkspaceState>>();

  @override
  Future<bool> hasSavedExpandedWorkspacePaths() async => true;

  @override
  Future<Set<String>> loadExpandedWorkspacePaths() {
    expandedLoadStarted.complete();
    return _expandedPaths.future;
  }

  @override
  Future<List<WorkspaceSidebarWorkspaceState>> loadWorkspaceStates() {
    workspaceLoadStarted.complete();
    return _workspaceStates.future;
  }

  void complete({
    required Set<String> expandedPaths,
    required List<WorkspaceSidebarWorkspaceState> workspaceStates,
  }) {
    _expandedPaths.complete(expandedPaths);
    _workspaceStates.complete(workspaceStates);
  }
}
