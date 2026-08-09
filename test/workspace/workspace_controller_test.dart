import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_session.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/state/workspace_controller.dart';
import 'package:ianvs_acp/workspace/workspace.dart';

void main() {
  test('WorkspaceController groups sessions by normalized cwd', () {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    final kimi = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Kimi',
    );
    addTearDown(codex.dispose);
    addTearDown(kimi.dispose);

    final older = AgentSession(
      id: 'older',
      cwd: '/workspace/app/',
      createdAt: DateTime(2026, 5, 1, 10),
      title: 'Older',
      agentName: 'Codex',
    );
    final newer = AgentSession(
      id: 'newer',
      cwd: '/workspace/app',
      createdAt: DateTime(2026, 5, 2, 10),
      title: 'Newer',
      agentName: 'Kimi',
    );
    codex.sessions.add(older);
    kimi.sessions.add(newer);

    final controller = WorkspaceController(
      controllers: [codex, kimi],
      currentWorkspacePath: '/workspace/app/',
      defaultAgentName: 'Codex',
    );

    expect(controller.currentWorkspace.path, '/workspace/app');
    expect(controller.currentWorkspace.name, 'app');
    expect(controller.currentWorkspace.sessions.map((session) => session.id), [
      'newer',
      'older',
    ]);
    expect(controller.currentWorkspace.agentNames, ['Codex', 'Kimi']);
  });

  test(
    'WorkspaceController keeps current workspace visible without sessions',
    () {
      final chat = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/current',
      );
      addTearDown(chat.dispose);
      chat.sessions.add(
        AgentSession(
          id: 'other-session',
          cwd: '/workspace/other',
          createdAt: DateTime(2026, 5, 2, 10),
          title: 'Other',
        ),
      );

      final controller = WorkspaceController(
        controllers: [chat],
        currentWorkspacePath: '/workspace/current',
      );

      expect(controller.workspaces.map((workspace) => workspace.path), [
        '/workspace/other',
        '/workspace/current',
      ]);
      expect(controller.currentWorkspace.sessions, isEmpty);
    },
  );

  test(
    'WorkspaceController does not move the current workspace to the front',
    () {
      final chat = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/older',
      );
      addTearDown(chat.dispose);
      chat.sessions.addAll([
        AgentSession(
          id: 'older-session',
          cwd: '/workspace/older',
          createdAt: DateTime(2026, 5, 1, 10),
          title: 'Older',
        ),
        AgentSession(
          id: 'newer-session',
          cwd: '/workspace/newer',
          createdAt: DateTime(2026, 5, 2, 10),
          title: 'Newer',
        ),
      ]);

      final controller = WorkspaceController(
        controllers: [chat],
        currentWorkspacePath: '/workspace/older',
      );

      expect(controller.currentWorkspace.path, '/workspace/older');
      expect(controller.workspaces.map((workspace) => workspace.path), [
        '/workspace/newer',
        '/workspace/older',
      ]);
    },
  );

  test(
    'WorkspaceController hides archived sessions and sorts pinned first',
    () {
      final chat = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      addTearDown(chat.dispose);

      chat.sessions.addAll([
        AgentSession(
          id: 'newer',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Newer',
          agentName: 'Codex',
        ),
        AgentSession(
          id: 'pinned',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 1, 10),
          title: 'Pinned',
          agentName: 'Codex',
          pinned: true,
        ),
        AgentSession(
          id: 'archived',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 4, 10),
          title: 'Archived',
          agentName: 'Codex',
          archived: true,
        ),
      ]);

      final controller = WorkspaceController(
        controllers: [chat],
        currentWorkspacePath: '/workspace/app',
      );

      expect(
        controller.currentWorkspace.sessions.map((session) => session.id),
        ['pinned', 'newer'],
      );

      final persistenceController = WorkspaceController(
        controllers: [chat],
        currentWorkspacePath: '/workspace/app',
        includeArchived: true,
      );
      expect(
        persistenceController.currentWorkspace.sessions.map(
          (session) => session.id,
        ),
        ['pinned', 'archived', 'newer'],
      );
    },
  );

  test('WorkspaceController deduplicates same-id sessions across agents', () {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
      sessionCatalogSourceKey: 'shared-codex-catalog',
    );
    final fast = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-fast',
      sessionCatalogSourceKey: 'shared-codex-catalog',
    );
    final thinking = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-thinking',
      sessionCatalogSourceKey: 'shared-codex-catalog',
    );
    final worker = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-worker',
      sessionCatalogSourceKey: 'shared-codex-catalog',
    );
    addTearDown(codex.dispose);
    addTearDown(fast.dispose);
    addTearDown(thinking.dispose);
    addTearDown(worker.dispose);

    for (final (index, controller) in [codex, fast, thinking, worker].indexed) {
      controller.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Shared catalog session',
          additionalDirectories: ['/workspace/agent-$index'],
        ),
      );
    }

    final controller = WorkspaceController(
      controllers: [codex, fast, thinking, worker],
      currentWorkspacePath: '/workspace/app',
      defaultAgentName: 'Codex',
    );

    final session = controller.currentWorkspace.sessions.single;
    expect(controller.currentWorkspace.sessionCount, 1);
    expect(session.agentName, 'Codex');
    expect(session.additionalDirectories, ['/workspace/agent-0']);
  });

  test('WorkspaceController deduplicates stale same-id session metadata', () {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
      sessionCatalogSourceKey: 'shared-catalog',
    );
    final pi = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'pi ACP',
      sessionCatalogSourceKey: 'shared-catalog',
    );
    addTearDown(codex.dispose);
    addTearDown(pi.dispose);

    codex.sessions.add(
      AgentSession(
        id: 'shared-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 5, 3, 10),
        agentName: 'Codex',
        additionalDirectories: const ['/workspace/codex-extra'],
      ),
    );
    pi.sessions.add(
      AgentSession(
        id: 'shared-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 5, 3, 9),
        agentName: 'Codex',
        additionalDirectories: const ['/workspace/pi-extra'],
      ),
    );

    final controller = WorkspaceController(
      controllers: [codex, pi],
      currentWorkspacePath: '/workspace/app',
    );
    final session = controller.currentWorkspace.sessions.single;

    expect(session.agentName, 'Codex');
    expect(session.additionalDirectories, ['/workspace/codex-extra']);
  });

  test(
    'WorkspaceController never assigns an unrelated default agent to a catalog',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
        sessionCatalogSourceKey: 'shared-codex-catalog',
      );
      final fast = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'codex-fast',
        sessionCatalogSourceKey: 'shared-codex-catalog',
      );
      addTearDown(codex.dispose);
      addTearDown(fast.dispose);

      codex.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          agentName: 'Codex',
        ),
      );
      fast.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          agentName: 'codex-fast',
        ),
      );

      final session = WorkspaceController(
        controllers: [fast, codex],
        currentWorkspacePath: '/workspace/app',
        defaultAgentName: 'Pi',
      ).currentWorkspace.sessions.single;

      expect(session.agentName, 'Codex');
    },
  );

  test('WorkspaceController keeps same-id sessions from different agents', () {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
      sessionCatalogSourceKey: 'codex-catalog',
    );
    final pi = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'pi ACP',
      sessionCatalogSourceKey: 'pi-catalog',
    );
    addTearDown(codex.dispose);
    addTearDown(pi.dispose);

    for (final controller in [codex, pi]) {
      controller.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: '${controller.agentName} session',
          agentName: controller.agentName,
        ),
      );
    }

    final workspace = WorkspaceController(
      controllers: [codex, pi],
      currentWorkspacePath: '/workspace/app',
    ).currentWorkspace;

    expect(workspace.sessionCount, 2);
    expect(workspace.sessions.map((session) => session.agentName).toSet(), {
      'Codex',
      'pi ACP',
    });
  });

  test(
    'WorkspaceController isolates different agents when catalog keys are absent',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      final pi = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'pi ACP',
      );
      addTearDown(codex.dispose);
      addTearDown(pi.dispose);

      for (final controller in [codex, pi]) {
        controller.sessions.add(
          AgentSession(
            id: 'shared-session',
            cwd: '/workspace/app',
            createdAt: DateTime(2026, 5, 3, 10),
            title: '${controller.agentName} session',
            agentName: controller.agentName,
          ),
        );
      }

      final workspace = WorkspaceController(
        controllers: [codex, pi],
        currentWorkspacePath: '/workspace/app',
      ).currentWorkspace;

      expect(workspace.sessionCount, 2);
      expect(workspace.sessions.map((session) => session.agentName).toSet(), {
        'Codex',
        'pi ACP',
      });
    },
  );

  test(
    'WorkspaceController uses the only source agent for an unattributed session',
    () {
      final pi = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'pi ACP',
      );
      addTearDown(pi.dispose);

      pi.sessions.add(
        AgentSession(
          id: 'pi-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Pi session',
        ),
      );

      final controller = WorkspaceController(
        controllers: [pi],
        currentWorkspacePath: '/workspace/app',
        defaultAgentName: 'Codex',
      );

      expect(controller.currentWorkspace.sessions, hasLength(1));
      expect(controller.currentWorkspace.sessions.single.agentName, 'pi ACP');
    },
  );

  test(
    'WorkspaceController falls back when the controller agent name is blank',
    () {
      final unnamed = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: '  ',
      );
      addTearDown(unnamed.dispose);
      unnamed.sessions.addAll([
        AgentSession(
          id: 'explicit-agent',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          agentName: 'Catalog Agent',
        ),
        AgentSession(
          id: 'default-agent',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 9),
        ),
      ]);

      final controller = WorkspaceController(
        controllers: [unnamed],
        currentWorkspacePath: '/workspace/app',
        defaultAgentName: 'Default Agent',
      );
      final sessionsById = {
        for (final session in controller.currentWorkspace.sessions)
          session.id: session,
      };

      expect(sessionsById['explicit-agent']?.agentName, 'Catalog Agent');
      expect(sessionsById['default-agent']?.agentName, 'Default Agent');
    },
  );

  test(
    'WorkspaceController uses the default agent for conflicting metadata',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
        sessionCatalogSourceKey: 'shared-catalog',
      );
      final fast = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'codex-fast',
        sessionCatalogSourceKey: 'shared-catalog',
      );
      addTearDown(codex.dispose);
      addTearDown(fast.dispose);

      codex.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Shared catalog session',
          agentName: 'Codex',
        ),
      );
      fast.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Shared catalog session',
          agentName: 'codex-fast',
        ),
      );

      final controller = WorkspaceController(
        controllers: [codex, fast],
        currentWorkspacePath: '/workspace/app',
        defaultAgentName: 'Codex',
      );

      final session = controller.currentWorkspace.sessions.single;
      expect(session.agentName, 'Codex');
      expect(session.title, 'Shared catalog session');
    },
  );

  test(
    'WorkspaceController keeps the active agent for conflicting metadata',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
        sessionCatalogSourceKey: 'shared-catalog',
      );
      final worker = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'codex-worker',
        sessionCatalogSourceKey: 'shared-catalog',
      );
      addTearDown(codex.dispose);
      addTearDown(worker.dispose);

      final codexSession = AgentSession(
        id: 'shared-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 5, 3, 10),
        title: 'Shared catalog session',
        agentName: 'Codex',
      );
      final workerSession = AgentSession(
        id: 'shared-session',
        cwd: '/workspace/app',
        createdAt: DateTime(2026, 5, 3, 10),
        title: 'Shared catalog session',
        agentName: 'codex-worker',
      );
      codex.sessions.add(codexSession);
      worker.sessions.add(workerSession);
      worker.currentSession = workerSession;

      final controller = WorkspaceController(
        controllers: [codex, worker],
        currentWorkspacePath: '/workspace/app',
        defaultAgentName: 'Codex',
      );

      expect(controller.currentWorkspace.sessions, hasLength(1));
      expect(
        controller.currentWorkspace.sessions.single.agentName,
        'codex-worker',
      );
    },
  );

  test(
    'WorkspaceController deduplicates repeated ids from the same controller',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      addTearDown(codex.dispose);

      codex.sessions.addAll([
        AgentSession(
          id: 'repeated-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Catalog copy',
        ),
        AgentSession(
          id: 'repeated-session',
          cwd: '/workspace/app/',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Local copy',
        ),
      ]);

      final controller = WorkspaceController(
        controllers: [codex],
        currentWorkspacePath: '/workspace/app',
      );

      expect(controller.currentWorkspace.sessions, hasLength(1));
      expect(controller.currentWorkspace.sessions.single.agentName, 'Codex');
    },
  );

  test('workspaceNameFromPath returns the last path segment', () {
    expect(workspaceNameFromPath('/Users/me/project'), 'project');
    expect(workspaceNameFromPath('/Users/me/project/'), 'project');
    expect(workspaceNameFromPath('/'), '/');
  });
}
