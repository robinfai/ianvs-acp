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
        '/workspace/current',
        '/workspace/other',
      ]);
      expect(controller.currentWorkspace.sessions, isEmpty);
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

  test('workspaceNameFromPath returns the last path segment', () {
    expect(workspaceNameFromPath('/Users/me/project'), 'project');
    expect(workspaceNameFromPath('/Users/me/project/'), 'project');
    expect(workspaceNameFromPath('/'), '/');
  });
}
