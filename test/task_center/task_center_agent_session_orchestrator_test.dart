import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/task_center/task_center_agent_session_orchestrator.dart';
import 'package:ianvs_acp/task_center/task_center_controller.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test(
    'starts a worker session for an active run without session id',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_auto_worker_session',
      );
      addTearDown(() => temp.delete(recursive: true));
      final taskController = TaskCenterController(
        store: TaskCenterStore(
          path: '${temp.path}/task_center.json',
          now: () => DateTime.utc(2026, 6, 17, 10),
        ),
      );
      addTearDown(taskController.dispose);
      final workspace = await taskController.createWorkspace(
        title: 'Auto worker workspace',
        agentConfig: const TaskWorkspaceAgentConfig(
          workAgentNames: <String>['Codex'],
        ),
      );
      final task = await taskController.createTask(
        workspaceId: workspace.id,
        title: 'Check TAPD due items',
        objective: 'Count due TAPD requirements in the current project.',
        acceptanceCriteria: const <String>['Return the due item count.'],
      );
      await taskController.startWorkRun(
        workspaceId: workspace.id,
        taskId: task.id,
        agentName: 'Codex',
      );

      final fake = FakeAgentClient();
      final chatController = ChatController(
        client: fake,
        cwd: '/workspace/bk-sec-ai',
        agentName: 'Codex',
      );
      addTearDown(chatController.dispose);

      final orchestrator = TaskCenterAgentSessionOrchestrator(
        taskCenterController: taskController,
        controllerForAgent: (agentName, workspace) =>
            agentName == 'Codex' ? chatController : null,
      );
      await orchestrator.syncActiveWorkRuns();
      await Future<void>.delayed(Duration.zero);

      expect(fake.sessionCount, 1);
      expect(chatController.sessions.single.agentName, 'Codex');
      expect(fake.lastPrompt, contains('Check TAPD due items'));
      expect(fake.lastPrompt, contains('task_id: ${task.id}'));

      final updatedTask = taskController.selectedWorkspace!.tasks.single;
      expect(updatedTask.workRuns.single.sessionId, 'fake-session-1');
    },
  );

  test(
    'starts worker sessions inside the workspace working directory',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs_worker_workspace_cwd',
      );
      addTearDown(() => temp.delete(recursive: true));
      final taskController = TaskCenterController(
        store: TaskCenterStore(
          path: '${temp.path}/task_center.json',
          now: () => DateTime.utc(2026, 6, 17, 10, 30),
        ),
      );
      addTearDown(taskController.dispose);
      final workspace = await taskController.createWorkspace(
        title: 'Workspace cwd',
        workspaceCwd: '/workspace/bk-sec-ai',
        agentConfig: const TaskWorkspaceAgentConfig(
          workAgentNames: <String>['Codex'],
        ),
      );
      final task = await taskController.createTask(
        workspaceId: workspace.id,
        title: 'Run inside workspace cwd',
      );
      await taskController.startWorkRun(
        workspaceId: workspace.id,
        taskId: task.id,
        agentName: 'Codex',
      );

      final fake = FakeAgentClient();
      final chatController = ChatController(
        client: fake,
        cwd: '/workspace/ianvs-acp',
        agentName: 'Codex',
      );
      addTearDown(chatController.dispose);

      final orchestrator = TaskCenterAgentSessionOrchestrator(
        taskCenterController: taskController,
        controllerForAgent: (agentName, workspace) =>
            agentName == 'Codex' ? chatController : null,
      );
      await orchestrator.syncActiveWorkRuns();
      await Future<void>.delayed(Duration.zero);

      expect(fake.lastCreateCwd, '/workspace/bk-sec-ai');
      expect(chatController.currentSession?.cwd, '/workspace/bk-sec-ai');
    },
  );

  test('starts a thinking session for a needs-thinking task', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_thinking_session',
    );
    addTearDown(() => temp.delete(recursive: true));
    final taskController = TaskCenterController(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 10, 45),
      ),
    );
    addTearDown(taskController.dispose);
    final workspace = await taskController.createWorkspace(
      title: 'Thinking workspace',
      workspaceCwd: '/workspace/bk-sec-ai',
      agentConfig: const TaskWorkspaceAgentConfig(
        thinkingAgentName: 'Thinker',
        workAgentNames: <String>['Worker'],
      ),
    );
    final task = await taskController.createTask(
      workspaceId: workspace.id,
      title: 'Clarify complex routing',
      objective: 'Think through risks and human questions.',
      currentOwner: const TaskCenterTaskOwner.thinkingAgent('Thinker'),
      readiness: TaskCenterReadiness.needsThinking,
      status: TaskCenterStatus.inProgress,
    );

    final fake = FakeAgentClient();
    final chatController = ChatController(
      client: fake,
      cwd: '/workspace/ianvs-acp',
      agentName: 'Thinker',
    );
    addTearDown(chatController.dispose);

    final orchestrator = TaskCenterAgentSessionOrchestrator(
      taskCenterController: taskController,
      controllerForAgent: (agentName, workspace) =>
          agentName == 'Thinker' ? chatController : null,
    );
    await orchestrator.syncActiveWorkRuns();
    await Future<void>.delayed(Duration.zero);

    expect(fake.sessionCount, 1);
    expect(fake.lastCreateCwd, '/workspace/bk-sec-ai');
    expect(fake.lastPrompt, contains('主思考agent'));
    expect(fake.lastPrompt, contains('task_id: ${task.id}'));
    expect(fake.lastPrompt, contains('不要先读取本地文件'));
    expect(
      fake.lastPrompt,
      contains('第一步必须调用 task_center_request_human_confirmation'),
    );

    final updatedTask = taskController.selectedWorkspace!.tasks.single;
    expect(updatedTask.metadata['thinking_session_id'], 'fake-session-1');
  });

  test('resumes the transcript for an active run with session id', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_resume_worker_session',
    );
    addTearDown(() => temp.delete(recursive: true));
    final taskController = TaskCenterController(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 11),
      ),
    );
    addTearDown(taskController.dispose);
    final workspace = await taskController.createWorkspace(
      title: 'Resume worker workspace',
      agentConfig: const TaskWorkspaceAgentConfig(
        workAgentNames: <String>['Codex'],
      ),
    );
    final task = await taskController.createTask(
      workspaceId: workspace.id,
      title: 'Resume TAPD due check',
    );
    await taskController.startWorkRun(
      workspaceId: workspace.id,
      taskId: task.id,
      agentName: 'Codex',
      sessionId: 'worker-session-1',
    );

    final fake = FakeAgentClient();
    final chatController = ChatController(
      client: fake,
      cwd: '/workspace/bk-sec-ai',
      agentName: 'Codex',
    );
    addTearDown(chatController.dispose);

    final orchestrator = TaskCenterAgentSessionOrchestrator(
      taskCenterController: taskController,
      controllerForAgent: (agentName, workspace) =>
          agentName == 'Codex' ? chatController : null,
    );
    await orchestrator.syncActiveWorkRuns();

    expect(fake.sessionCount, 0);
    expect(fake.lastResumeCwd, '/workspace/bk-sec-ai');
    expect(chatController.currentSession?.id, 'worker-session-1');
    expect(
      chatController.messages.map((message) => message.text),
      contains(contains('resumed Codex session')),
    );
  });

  test('does not repeatedly resume an already hydrated run session', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_no_repeat_worker_resume',
    );
    addTearDown(() => temp.delete(recursive: true));
    final taskController = TaskCenterController(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 12),
      ),
    );
    addTearDown(taskController.dispose);
    final workspace = await taskController.createWorkspace(
      title: 'No repeat resume workspace',
      agentConfig: const TaskWorkspaceAgentConfig(
        workAgentNames: <String>['Codex'],
      ),
    );
    final task = await taskController.createTask(
      workspaceId: workspace.id,
      title: 'Keep worker transcript stable',
    );
    await taskController.startWorkRun(
      workspaceId: workspace.id,
      taskId: task.id,
      agentName: 'Codex',
      sessionId: 'worker-session-1',
    );

    final fake = _CountingResumeAgentClient();
    final chatController = ChatController(
      client: fake,
      cwd: '/workspace/bk-sec-ai',
      agentName: 'Codex',
    );
    addTearDown(chatController.dispose);

    final orchestrator = TaskCenterAgentSessionOrchestrator(
      taskCenterController: taskController,
      controllerForAgent: (agentName, workspace) =>
          agentName == 'Codex' ? chatController : null,
    );
    await orchestrator.syncActiveWorkRuns();
    expect(fake.resumeCount, 1);
    expect(chatController.currentSession?.id, 'worker-session-1');

    await chatController.newSession();
    expect(chatController.currentSession?.id, 'fake-session-1');

    await orchestrator.syncActiveWorkRuns();
    expect(fake.resumeCount, 1);
    expect(chatController.currentSession?.id, 'fake-session-1');
  });

  test('resumes a thinking session stored in task metadata', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_resume_thinking_session',
    );
    addTearDown(() => temp.delete(recursive: true));
    final taskController = TaskCenterController(
      store: TaskCenterStore(
        path: '${temp.path}/task_center.json',
        now: () => DateTime.utc(2026, 6, 17, 11, 15),
      ),
    );
    addTearDown(taskController.dispose);
    final workspace = await taskController.createWorkspace(
      title: 'Resume thinking workspace',
      workspaceCwd: '/workspace/bk-sec-ai',
      agentConfig: const TaskWorkspaceAgentConfig(thinkingAgentName: 'Thinker'),
    );
    await taskController.createTask(
      workspaceId: workspace.id,
      title: 'Resume thinking',
      currentOwner: const TaskCenterTaskOwner.thinkingAgent('Thinker'),
      readiness: TaskCenterReadiness.needsThinking,
      status: TaskCenterStatus.inProgress,
    );
    await taskController.updateTask(
      workspaceId: workspace.id,
      taskId: taskController.selectedWorkspace!.tasks.single.id,
      metadata: const <String, Object?>{
        'thinking_session_id': 'thinking-session-1',
      },
    );

    final fake = FakeAgentClient();
    final chatController = ChatController(
      client: fake,
      cwd: '/workspace/bk-sec-ai',
      agentName: 'Thinker',
    );
    addTearDown(chatController.dispose);

    final orchestrator = TaskCenterAgentSessionOrchestrator(
      taskCenterController: taskController,
      controllerForAgent: (agentName, workspace) =>
          agentName == 'Thinker' ? chatController : null,
    );
    await orchestrator.syncActiveWorkRuns();

    expect(fake.sessionCount, 0);
    expect(fake.lastResumeCwd, '/workspace/bk-sec-ai');
    expect(chatController.currentSession?.id, 'thinking-session-1');
    expect(fake.lastPrompt, isNull);
  });
}

class _CountingResumeAgentClient extends FakeAgentClient {
  int resumeCount = 0;

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    resumeCount += 1;
    return super.resumeSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
  }
}
