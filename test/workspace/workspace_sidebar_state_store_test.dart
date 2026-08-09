import 'dart:async';
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
        localUnstarted: true,
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
    expect(sessions.first.localUnstarted, isTrue);
  });

  test(
    'WorkspaceSidebarStateStore normalizes and bounds persisted session titles',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/workspace_ui_state.json');
      final store = WorkspaceSidebarStateStore(path: file.path);
      final longTitle = '  ${List<String>.filled(300, '会').join()}\nignored  ';

      await store.saveSessionIndex([
        AgentSession(
          id: 'session-long-title',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 29, 8),
          title: longTitle,
          titleOverride: '  Slow\n\nstartup\t diagnosis  ',
          agentName: 'Codex',
        ),
      ]);

      final loaded = (await store.loadSessionIndex()).single;
      expect(loaded.title?.runes, hasLength(256));
      expect(loaded.title, endsWith('…'));
      expect(loaded.titleOverride, 'Slow startup diagnosis');

      final persisted = jsonDecode(await file.readAsString()) as Map;
      final rawSession = (persisted['session_index'] as List).single as Map;
      expect((rawSession['title'] as String).runes, hasLength(256));
      expect(rawSession['title_override'], 'Slow startup diagnosis');
    },
  );

  test(
    'WorkspaceSidebarStateStore preserves agent-scoped session ids',
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
          id: 'shared-session',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 1, 8),
          title: 'Codex copy',
          agentName: 'Codex',
        ),
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 1, 8),
          title: 'Alias copy',
          agentName: 'codex-fast',
        ),
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/other',
          createdAt: DateTime(2026, 7, 1, 8),
          title: 'Different workspace',
          agentName: 'Codex',
        ),
      ]);

      final sessions = await store.loadSessionIndex();
      expect(sessions, hasLength(3));
      expect(
        sessions
            .where((session) => session.cwd == '/workspace/project')
            .map((session) => session.agentName)
            .toSet(),
        {'Codex', 'codex-fast'},
      );
      expect(
        sessions.where((session) => session.cwd == '/workspace/other'),
        hasLength(1),
      );
    },
  );

  test('WorkspaceSidebarStateStore recognizes blank session entries', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'ianvs-acp-sidebar-store-',
    );
    addTearDown(() async => tempDir.delete(recursive: true));
    final file = File('${tempDir.path}/workspace_ui_state.json');
    await file.writeAsString(
      jsonEncode({
        'session_index': [
          {
            'id': 'blank-session',
            'cwd': '/workspace/project',
            'created_at': '2026-07-15T20:47:46.586319',
            'agent_name': 'Codex',
          },
        ],
      }),
    );

    final sessions = await WorkspaceSidebarStateStore(
      path: file.path,
    ).loadSessionIndex();

    expect(sessions.single.localUnstarted, isTrue);
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
      const WorkspaceSidebarWorkspaceState(
        path: '/workspace/manual',
        manuallyAdded: true,
      ),
    ]);

    expect(await store.loadExpandedWorkspacePaths(), {'/workspace/project'});

    final states = await store.loadWorkspaceStates();
    expect(states.map((state) => state.path), [
      '/workspace/hidden',
      '/workspace/manual',
      '/workspace/project',
    ]);
    expect(states.first.hidden, isTrue);
    expect(states[1].manuallyAdded, isTrue);
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

  test(
    'WorkspaceSidebarStateStore serializes writes across instances without losing fields',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/nested/workspace_ui_state.json';
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);

      await Future.wait([
        firstStore.saveExpandedWorkspacePaths({'/workspace/expanded'}),
        firstStore.saveWorkspaceStates([
          const WorkspaceSidebarWorkspaceState(
            path: '/workspace/pinned',
            displayName: 'Pinned workspace',
            pinned: true,
          ),
        ]),
        secondStore.saveSessionIndex([
          AgentSession(
            id: 'session-concurrent',
            cwd: '/workspace/session',
            createdAt: DateTime(2026, 7, 10, 18),
            agentName: 'Codex',
          ),
        ]),
      ]);

      final raw = jsonDecode(await File(path).readAsString()) as Map;
      expect(raw['expanded_workspaces'], ['/workspace/expanded']);
      expect(raw['workspace_index'], hasLength(1));
      expect(raw['session_index'], hasLength(1));
      expect((await File(path).stat()).mode & 0x1ff, 0x180);
      expect((await File(path).parent.stat()).mode & 0x1ff, 0x1c0);
    },
  );

  test(
    'independent stores merge workspace fields and retain deletion tombstones',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/workspace_ui_state.json';
      final seedStore = WorkspaceSidebarStateStore(path: path);
      await seedStore.saveWorkspaceStates([
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/shared',
          displayName: 'Original name',
        ),
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/removed',
          pinned: true,
        ),
      ]);
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);
      expect(await firstStore.loadWorkspaceStates(), hasLength(2));
      expect(await secondStore.loadWorkspaceStates(), hasLength(2));

      await firstStore.saveWorkspaceStates([
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/shared',
          displayName: 'Original name',
          pinned: true,
        ),
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/from-first',
          manuallyAdded: true,
        ),
      ]);
      await secondStore.saveWorkspaceStates([
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/shared',
          displayName: 'Renamed elsewhere',
          hidden: true,
        ),
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/removed',
          pinned: true,
        ),
        const WorkspaceSidebarWorkspaceState(
          path: '/workspace/new',
          manuallyAdded: true,
        ),
      ]);

      final states = await WorkspaceSidebarStateStore(
        path: path,
      ).loadWorkspaceStates();
      expect(states.map((state) => state.path).toSet(), {
        '/workspace/shared',
        '/workspace/from-first',
        '/workspace/new',
      });
      final shared = states.singleWhere(
        (state) => state.path == '/workspace/shared',
      );
      expect(shared.displayName, 'Renamed elsewhere');
      expect(shared.pinned, isTrue);
      expect(shared.hidden, isTrue);
      expect(
        states
            .singleWhere((state) => state.path == '/workspace/new')
            .manuallyAdded,
        isTrue,
      );
    },
  );

  test(
    'independent stores merge expanded workspace additions and deletions',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/workspace_ui_state.json';
      final seedStore = WorkspaceSidebarStateStore(path: path);
      await seedStore.saveExpandedWorkspacePaths({
        '/workspace/shared',
        '/workspace/removed',
      });
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);
      expect(await firstStore.loadExpandedWorkspacePaths(), hasLength(2));
      expect(await secondStore.loadExpandedWorkspacePaths(), hasLength(2));

      await firstStore.saveExpandedWorkspacePaths({
        '/workspace/shared',
        '/workspace/from-first',
      });
      await secondStore.saveExpandedWorkspacePaths({
        '/workspace/shared',
        '/workspace/removed',
        '/workspace/from-second',
      });

      expect(
        await WorkspaceSidebarStateStore(
          path: path,
        ).loadExpandedWorkspacePaths(),
        {
          '/workspace/shared',
          '/workspace/from-first',
          '/workspace/from-second',
        },
      );
    },
  );

  test(
    'independent stores preserve sessions added after their base snapshot',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/workspace_ui_state.json';
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);
      expect(await firstStore.loadSessionIndex(), isEmpty);
      expect(await secondStore.loadSessionIndex(), isEmpty);

      await firstStore.saveSessionIndex([
        AgentSession(
          id: 'session-from-first',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 11, 8),
          agentName: 'Codex',
        ),
      ]);
      await secondStore.saveSessionIndex([
        AgentSession(
          id: 'session-from-second',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 11, 9),
          agentName: 'Codex',
        ),
      ]);

      expect(
        (await WorkspaceSidebarStateStore(
          path: path,
        ).loadSessionIndex()).map((session) => session.id).toSet(),
        {'session-from-first', 'session-from-second'},
      );
    },
  );

  test(
    'independent stores merge fields and retain deletion tombstones',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/workspace_ui_state.json';
      final seedStore = WorkspaceSidebarStateStore(path: path);
      final original = AgentSession(
        id: 'shared-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 12, 8),
        title: 'Original title',
        agentName: 'Codex',
      );
      final removed = AgentSession(
        id: 'removed-session',
        cwd: '/workspace/project',
        createdAt: DateTime(2026, 7, 12, 7),
        agentName: 'Codex',
      );
      await seedStore.saveSessionIndex([original, removed]);
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);
      expect(await firstStore.loadSessionIndex(), hasLength(2));
      expect(await secondStore.loadSessionIndex(), hasLength(2));

      await firstStore.saveSessionIndex([original.copyWith(pinned: true)]);
      await secondStore.saveSessionIndex([
        original.copyWith(titleOverride: 'Renamed elsewhere', archived: true),
        removed,
        AgentSession(
          id: 'session-from-second',
          cwd: '/workspace/project',
          createdAt: DateTime(2026, 7, 12, 9),
          agentName: 'Codex',
        ),
      ]);

      final sessions = await WorkspaceSidebarStateStore(
        path: path,
      ).loadSessionIndex();
      final shared = sessions.singleWhere(
        (session) => session.id == 'shared-session',
      );
      expect(shared.pinned, isTrue);
      expect(shared.archived, isTrue);
      expect(shared.titleOverride, 'Renamed elsewhere');
      expect(sessions.map((session) => session.id).toSet(), {
        'shared-session',
        'session-from-second',
      });
    },
  );

  test(
    'WorkspaceSidebarStateStore does not publish failed mutations or poison its queue',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final path = '${tempDir.path}/workspace_ui_state.json';
      final file = File(path);
      final backup = File('$path.backup');
      final firstStore = WorkspaceSidebarStateStore(path: path);
      final secondStore = WorkspaceSidebarStateStore(path: path);
      await firstStore.saveExpandedWorkspacePaths({'/workspace/expanded'});

      await file.rename(backup.path);
      await Directory(path).create();
      await expectLater(
        firstStore.saveWorkspaceStates([
          const WorkspaceSidebarWorkspaceState(
            path: '/workspace/failed',
            pinned: true,
          ),
        ]),
        throwsA(isA<FileSystemException>()),
      );
      await Directory(path).delete();
      await backup.rename(path);

      await secondStore.saveSessionIndex([
        AgentSession(
          id: 'session-after-failure',
          cwd: '/workspace/session',
          createdAt: DateTime(2026, 7, 10, 19),
          agentName: 'Codex',
        ),
      ]);

      final raw = jsonDecode(await file.readAsString()) as Map;
      expect(raw['expanded_workspaces'], ['/workspace/expanded']);
      expect(raw['session_index'], hasLength(1));
      expect(raw, isNot(contains('workspace_index')));
      expect(
        await tempDir
            .list()
            .where((entry) => entry.path.contains('.tmp-'))
            .toList(),
        isEmpty,
      );
    },
  );

  test(
    'session index persistence keeps the final A in an A-B-A race',
    () async {
      final store = _BlockingSessionIndexStore();
      final queue = WorkspaceSessionIndexPersistenceQueue(store: store);
      final original = _session(pinned: false);
      final changed = _session(pinned: true);

      queue.enqueue(sessions: <AgentSession>[original], signature: 'A');
      await queue.idle;
      queue.enqueue(sessions: <AgentSession>[changed], signature: 'B');
      await store.blockedSaveStarted.future;
      queue.enqueue(sessions: <AgentSession>[original], signature: 'A');
      store.releaseBlockedSave();
      await queue.idle;

      expect(store.savedPinnedStates, <bool>[false, true, false]);
    },
  );

  test(
    'WorkspaceSidebarStateStore preserves an external replacement',
    () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'ianvs-acp-sidebar-store-',
      );
      addTearDown(() async => tempDir.delete(recursive: true));
      final file = File('${tempDir.path}/workspace_ui_state.json');
      final store = WorkspaceSidebarStateStore(path: file.path);
      await store.saveExpandedWorkspacePaths({'/workspace/a'});
      final original = await file.readAsString();
      final external = original.replaceFirst(
        'expanded_workspaces',
        'external_workspaces',
      );
      expect(external.length, original.length);
      await file.writeAsString(external);

      await store.saveSessionIndex(<AgentSession>[_session(pinned: false)]);

      final persisted = jsonDecode(await file.readAsString()) as Map;
      expect(persisted['external_workspaces'], ['/workspace/a']);
      expect(persisted, isNot(contains('expanded_workspaces')));
      expect(persisted['session_index'], hasLength(1));
    },
  );

  test('session index persistence recovers from a synchronous throw', () async {
    final store = _SyncThrowOnceSessionIndexStore();
    final queue = WorkspaceSessionIndexPersistenceQueue(store: store);

    queue.enqueue(
      sessions: <AgentSession>[_session(pinned: false)],
      signature: 'A',
    );
    await queue.idle;
    queue.enqueue(
      sessions: <AgentSession>[_session(pinned: true)],
      signature: 'B',
    );
    await queue.idle;

    expect(store.savedPinnedStates, <bool>[true]);
  });
}

AgentSession _session({required bool pinned}) {
  return AgentSession(
    id: 'session-a',
    cwd: '/workspace/project',
    createdAt: DateTime(2026, 7, 10, 20),
    agentName: 'Codex',
    pinned: pinned,
  );
}

class _BlockingSessionIndexStore extends WorkspaceSidebarStateStore {
  _BlockingSessionIndexStore() : super(path: 'memory');

  final Completer<void> blockedSaveStarted = Completer<void>();
  final Completer<void> _releaseBlockedSave = Completer<void>();
  final List<bool> savedPinnedStates = <bool>[];
  int _saveAttempts = 0;

  @override
  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) async {
    _saveAttempts += 1;
    if (_saveAttempts == 2) {
      blockedSaveStarted.complete();
      await _releaseBlockedSave.future;
    }
    savedPinnedStates.add(sessions.single.pinned);
  }

  void releaseBlockedSave() {
    if (!_releaseBlockedSave.isCompleted) _releaseBlockedSave.complete();
  }
}

class _SyncThrowOnceSessionIndexStore extends WorkspaceSidebarStateStore {
  _SyncThrowOnceSessionIndexStore() : super(path: 'memory');

  final List<bool> savedPinnedStates = <bool>[];
  bool _shouldThrow = true;

  @override
  Future<void> saveSessionIndex(Iterable<AgentSession> sessions) {
    if (_shouldThrow) {
      _shouldThrow = false;
      throw StateError('injected synchronous save failure');
    }
    savedPinnedStates.add(sessions.single.pinned);
    return Future<void>.value();
  }
}
