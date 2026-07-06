import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/workspace/workspace_sidebar_state_store.dart';

void main() {
  test('WorkspaceSidebarStateStore saves and loads expanded paths', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-sidebar-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = WorkspaceSidebarStateStore(
      path: '${tempDir.path}/nested/workspace_ui_state.json',
    );

    expect(await store.hasSavedExpandedWorkspacePaths(), isFalse);

    await store.saveExpandedWorkspacePaths({
      '/workspace/b',
      '/workspace/a',
      '',
    });

    expect(await store.hasSavedExpandedWorkspacePaths(), isTrue);
    expect(await store.loadExpandedWorkspacePaths(), {
      '/workspace/a',
      '/workspace/b',
    });

    final raw =
        jsonDecode(
              await File(
                '${tempDir.path}/nested/workspace_ui_state.json',
              ).readAsString(),
            )
            as Map<String, Object?>;
    expect(raw['expanded_workspaces'], ['/workspace/a', '/workspace/b']);
  });

  test('WorkspaceSidebarStateStore resolves default path near config', () {
    final path = WorkspaceSidebarStateStore.defaultPath(
      configPath: '/tmp/ianvs-acp/settings.json',
      environment: const {'HOME': '/Users/example'},
    );

    expect(path, '/tmp/ianvs-acp/workspace_ui_state.json');
  });

  test('WorkspaceSidebarStateStore resolves default path from XDG config', () {
    final path = WorkspaceSidebarStateStore.defaultPath(
      environment: const {
        'XDG_CONFIG_HOME': '/Users/example/.config-alt',
        'HOME': '/Users/example',
      },
    );

    expect(
      path,
      '/Users/example/.config-alt/ianvs-acp/workspace_ui_state.json',
    );
  });

  test(
    'WorkspaceSidebarStateStore tolerates missing and invalid files',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/workspace_ui_state.json');
      final store = WorkspaceSidebarStateStore(path: file.path);

      expect(await store.hasSavedExpandedWorkspacePaths(), isFalse);
      expect(await store.loadExpandedWorkspacePaths(), isEmpty);

      await file.writeAsString('{bad json');

      expect(await store.hasSavedExpandedWorkspacePaths(), isFalse);
      expect(await store.loadExpandedWorkspacePaths(), isEmpty);
    },
  );

  test('WorkspaceSidebarStateStore saves and loads session index', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-sidebar-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = WorkspaceSidebarStateStore(
      path: '${tempDir.path}/workspace_ui_state.json',
    );

    await store.saveExpandedWorkspacePaths({'/workspace/project'});
    await store.saveSessionIndex([
      AgentSession(
        id: 'session-b',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 1, 8),
        title: 'Older indexed session',
        updatedAt: DateTime(2026, 7, 1, 9),
        agentName: 'Codex',
      ),
      AgentSession(
        id: 'session-a',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 2, 8),
        additionalDirectories: const ['/workspace/extra'],
        title: 'Newer indexed session',
        titleOverride: 'User renamed session',
        updatedAt: DateTime(2026, 7, 2, 9),
        agentName: 'Kimi',
        pinned: true,
        archived: true,
        unread: true,
      ),
    ]);

    expect(await store.loadExpandedWorkspacePaths(), {'/workspace/project'});

    final sessions = await store.loadSessionIndex();
    expect(sessions.map((session) => session.id), ['session-a', 'session-b']);
    expect(sessions.first.cwd, '/workspace/project');
    expect(sessions.first.title, 'Newer indexed session');
    expect(sessions.first.titleOverride, 'User renamed session');
    expect(sessions.first.agentName, 'Kimi');
    expect(sessions.first.additionalDirectories, ['/workspace/extra']);
    expect(sessions.first.pinned, isTrue);
    expect(sessions.first.archived, isTrue);
    expect(sessions.first.unread, isTrue);
  });

  test('WorkspaceSidebarStateStore saves and loads workspace states', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-sidebar-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final store = WorkspaceSidebarStateStore(
      path: '${tempDir.path}/workspace_ui_state.json',
    );

    await store.saveExpandedWorkspacePaths({'/workspace/project'});
    await store.saveWorkspaceStates([
      const WorkspaceSidebarWorkspaceState(
        path: '/workspace/project',
        displayName: 'Renamed Project',
        pinned: true,
      ),
      const WorkspaceSidebarWorkspaceState(
        path: '/workspace/hidden',
        hidden: true,
      ),
    ]);

    expect(await store.loadExpandedWorkspacePaths(), {'/workspace/project'});

    final states = await store.loadWorkspaceStates();
    expect(states.map((state) => state.path), [
      '/workspace/hidden',
      '/workspace/project',
    ]);
    expect(states.first.hidden, isTrue);
    expect(states.last.displayName, 'Renamed Project');
    expect(states.last.pinned, isTrue);
  });

  test(
    'WorkspaceSidebarStateStore preserves session index when saving expansion',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final store = WorkspaceSidebarStateStore(
        path: '${tempDir.path}/workspace_ui_state.json',
      );

      await store.saveSessionIndex([
        AgentSession(
          id: 'session-a',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 2, 8),
          title: 'Indexed session',
          agentName: 'Codex',
        ),
      ]);
      await store.saveExpandedWorkspacePaths({'/workspace/project'});

      expect(await store.loadSessionIndex(), hasLength(1));
      expect((await store.loadSessionIndex()).single.id, 'session-a');
      expect(await store.loadExpandedWorkspacePaths(), {'/workspace/project'});
    },
  );

  test(
    'WorkspaceSidebarStateStore preserves workspace states when saving sessions',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final store = WorkspaceSidebarStateStore(
        path: '${tempDir.path}/workspace_ui_state.json',
      );

      await store.saveWorkspaceStates([
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/project',
          displayName: 'Renamed Project',
          pinned: true,
        ),
      ]);
      await store.saveSessionIndex([
        AgentSession(
          id: 'session-a',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 2, 8),
          title: 'Indexed session',
          agentName: 'Codex',
        ),
      ]);

      final states = await store.loadWorkspaceStates();
      expect(states, hasLength(1));
      expect(states.single.displayName, 'Renamed Project');
      expect(states.single.pinned, isTrue);
    },
  );
}
