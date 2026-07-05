import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/ui/components/workspace_sidebar.dart';
import 'package:ianvs_acp/workspace/workspace.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

void main() {
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

    await tester.tap(find.text('other'));
    await tester.pump();

    expect(selected, isNull);
    expect(find.text('Newer other work'), findsOneWidget);
    expect(find.text('Older other work'), findsOneWidget);

    await tester.tap(find.text('Newer other work'));
    await tester.pump();

    expect(selected, newerOther);
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
    expect(find.widgetWithText(OutlinedButton, 'New Session'), findsOneWidget);
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

  testWidgets('WorkspaceSidebar auto-loads sessions for expanded workspaces', (
    tester,
  ) async {
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

    expect(loadCount, 0);

    await tester.tap(find.text('other'));
    await tester.pump();

    expect(loadCount, 1);
    expect(loadedWorkspace, otherWorkspace);
    expect(find.text('Loading sessions in other...'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.text('No sessions in other'), findsOneWidget);
  });

  testWidgets('WorkspaceSidebar exposes workspace action menu', (tester) async {
    WorkspaceRecord? revealed;
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
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();

    expect(find.text('Pin Project'), findsOneWidget);
    expect(find.text('Show in Finder'), findsOneWidget);
    expect(find.text('Create Permanent Worktree'), findsOneWidget);
    expect(find.text('Rename Project'), findsOneWidget);
    expect(find.text('Archive Conversations'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);

    await tester.tap(find.text('Show in Finder'));
    await tester.pumpAndSettle();
    expect(revealed, workspace);

    await tester.tap(find.byTooltip('New session in this workspace'));
    await tester.pump();
    expect(newSessionCount, 1);
  });

  testWidgets('WorkspaceSidebar can locally rename a workspace', (
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

    await tester.tap(find.byTooltip('Workspace actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename Project'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Renamed workspace');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();

    expect(find.text('Renamed workspace'), findsOneWidget);
    expect(find.text('current'), findsNothing);
  });
}

class _MemoryWorkspaceSidebarStateStore extends WorkspaceSidebarStateStore {
  _MemoryWorkspaceSidebarStateStore(Set<String> initialPaths)
    : expandedWorkspacePaths = Set<String>.from(initialPaths),
      super(path: 'memory');

  Set<String> expandedWorkspacePaths;

  @override
  Future<Set<String>> loadExpandedWorkspacePaths() async {
    return Set<String>.from(expandedWorkspacePaths);
  }

  @override
  Future<void> saveExpandedWorkspacePaths(Set<String> paths) async {
    expandedWorkspacePaths = Set<String>.from(paths);
  }
}
