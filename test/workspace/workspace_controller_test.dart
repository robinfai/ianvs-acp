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
    },
  );

  test('WorkspaceController keeps same-id sessions separate across agents', () {
    final codex = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'Codex',
    );
    final fast = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-fast',
    );
    final thinking = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-thinking',
    );
    final worker = ChatController(
      client: FakeAgentClient(),
      cwd: '/workspace/app',
      agentName: 'codex-worker',
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

    final sessionsByAgent = {
      for (final session in controller.currentWorkspace.sessions)
        session.agentName: session,
    };
    expect(controller.currentWorkspace.sessions, hasLength(4));
    expect(controller.currentWorkspace.sessionCount, 4);
    expect(sessionsByAgent.keys, {
      'Codex',
      'codex-fast',
      'codex-thinking',
      'codex-worker',
    });
    expect(sessionsByAgent['Codex']?.additionalDirectories, [
      '/workspace/agent-0',
    ]);
    expect(sessionsByAgent['codex-fast']?.additionalDirectories, [
      '/workspace/agent-1',
    ]);
    expect(sessionsByAgent['codex-thinking']?.additionalDirectories, [
      '/workspace/agent-2',
    ]);
    expect(sessionsByAgent['codex-worker']?.additionalDirectories, [
      '/workspace/agent-3',
    ]);
  });

  test(
    'WorkspaceController trusts controller agents over stale session metadata',
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
      final sessions = controller.currentWorkspace.sessions;
      final sessionsByAgent = {
        for (final session in sessions) session.agentName: session,
      };
      final controllersByAgent = {
        for (final controller in [codex, pi]) controller.agentName: controller,
      };

      expect(sessions, hasLength(2));
      expect(sessionsByAgent.keys, {'Codex', 'pi ACP'});
      expect(sessionsByAgent['Codex']?.additionalDirectories, [
        '/workspace/codex-extra',
      ]);
      expect(sessionsByAgent['pi ACP']?.additionalDirectories, [
        '/workspace/pi-extra',
      ]);
      expect(
        controllersByAgent[sessionsByAgent['pi ACP']?.agentName],
        same(pi),
      );
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
    'WorkspaceController keeps same-id session metadata scoped to each agent',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      final fast = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'codex-fast',
      );
      addTearDown(codex.dispose);
      addTearDown(fast.dispose);

      codex.sessions.add(
        AgentSession(
          id: 'shared-session',
          cwd: '/workspace/app',
          createdAt: DateTime(2026, 5, 3, 10),
          title: 'Shared catalog session',
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

      final sessionsByAgent = {
        for (final session in controller.currentWorkspace.sessions)
          session.agentName: session,
      };
      expect(controller.currentWorkspace.sessions, hasLength(2));
      expect(sessionsByAgent.keys, {'Codex', 'codex-fast'});
      expect(sessionsByAgent['Codex']?.title, 'Shared catalog session');
      expect(sessionsByAgent['codex-fast']?.title, 'Shared catalog session');
    },
  );

  test(
    'WorkspaceController keeps current same-id sessions separate by agent',
    () {
      final codex = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'Codex',
      );
      final worker = ChatController(
        client: FakeAgentClient(),
        cwd: '/workspace/app',
        agentName: 'codex-worker',
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

      expect(controller.currentWorkspace.sessions, hasLength(2));
      expect(
        controller.currentWorkspace.sessions.map(
          (session) => session.agentName,
        ),
        containsAll(<String?>['Codex', 'codex-worker']),
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
