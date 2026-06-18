import '../state/chat_controller.dart';
import 'task_center_controller.dart';
import 'task_center_models.dart';

typedef TaskCenterAgentControllerResolver =
    ChatController? Function(String agentName, TaskWorkspace workspace);
typedef TaskCenterAgentControllerChanged = void Function(ChatController);

class TaskCenterAgentSessionOrchestrator {
  TaskCenterAgentSessionOrchestrator({
    required this.taskCenterController,
    required this.controllerForAgent,
    this.onControllerChanged,
  });

  final TaskCenterController taskCenterController;
  final TaskCenterAgentControllerResolver controllerForAgent;
  final TaskCenterAgentControllerChanged? onControllerChanged;

  final Set<String> _syncingRunIds = <String>{};
  final Set<String> _syncingThinkingTaskIds = <String>{};
  final Set<String> _promptedRunIds = <String>{};
  final Set<String> _promptedThinkingTaskIds = <String>{};
  final Set<String> _hydratedSessionIds = <String>{};

  Future<void> syncActiveWorkRuns() async {
    if (!taskCenterController.loaded) {
      await taskCenterController.load();
    }
    final workspaces = taskCenterController.workspaces;
    for (final workspace in workspaces) {
      for (final task in workspace.tasks) {
        for (final run in task.workRuns) {
          if (!_shouldSyncRun(run)) continue;
          await _syncRun(workspace: workspace, task: task, run: run);
        }
        if (!_shouldSyncThinkingTask(task)) continue;
        await _syncThinkingTask(workspace: workspace, task: task);
      }
    }
  }

  bool _shouldSyncRun(TaskCenterWorkRun run) {
    if (!run.isActive) return false;
    if (run.agentName.trim().isEmpty) return false;
    return !_syncingRunIds.contains(run.id);
  }

  bool _shouldSyncThinkingTask(TaskCenterTask task) {
    if (task.readiness != TaskCenterReadiness.needsThinking) return false;
    if (task.currentOwner.kind != TaskCenterOwnerKind.thinkingAgent) {
      return false;
    }
    if (task.currentOwner.agentName.trim().isEmpty) return false;
    if (task.status == TaskCenterStatus.done) return false;
    return !_syncingThinkingTaskIds.contains(task.id);
  }

  Future<void> _syncRun({
    required TaskWorkspace workspace,
    required TaskCenterTask task,
    required TaskCenterWorkRun run,
  }) async {
    _syncingRunIds.add(run.id);
    try {
      final agentName = run.agentName.trim();
      final controller = controllerForAgent(agentName, workspace);
      if (controller == null) return;
      final workspaceCwd = _workspaceCwd(workspace, controller);

      final sessionId = run.sessionId.trim();
      if (sessionId.isNotEmpty) {
        if (_hydratedSessionIds.contains(sessionId)) return;
        final hydrated = await _resumeSessionIfNeeded(
          controller: controller,
          sessionId: sessionId,
          cwd: workspaceCwd,
          title: task.title,
        );
        if (hydrated) _hydratedSessionIds.add(sessionId);
        return;
      }

      await controller.newSession(cwd: workspaceCwd);
      final session = controller.currentSession;
      if (session == null) return;
      await taskCenterController.bindWorkRunSession(
        workspaceId: workspace.id,
        taskId: task.id,
        runId: run.id,
        sessionId: session.id,
        actor: 'task_center_app',
      );
      onControllerChanged?.call(controller);
      await _sendWorkerPromptOnce(
        controller: controller,
        workspace: workspace,
        task: task,
        run: run,
      );
    } finally {
      _syncingRunIds.remove(run.id);
    }
  }

  Future<void> _syncThinkingTask({
    required TaskWorkspace workspace,
    required TaskCenterTask task,
  }) async {
    _syncingThinkingTaskIds.add(task.id);
    try {
      final agentName = task.currentOwner.agentName.trim();
      final controller = controllerForAgent(agentName, workspace);
      if (controller == null) return;
      final workspaceCwd = _workspaceCwd(workspace, controller);
      final sessionId = _thinkingSessionId(task);

      if (sessionId.isNotEmpty) {
        if (_hydratedSessionIds.contains(sessionId)) return;
        final hydrated = await _resumeSessionIfNeeded(
          controller: controller,
          sessionId: sessionId,
          cwd: workspaceCwd,
          title: task.title,
        );
        if (hydrated) _hydratedSessionIds.add(sessionId);
        return;
      }

      await controller.newSession(cwd: workspaceCwd);
      final session = controller.currentSession;
      if (session == null) return;
      await taskCenterController.updateTask(
        workspaceId: workspace.id,
        taskId: task.id,
        metadata: <String, Object?>{
          ...task.metadata,
          'thinking_session_id': session.id,
          'thinking_session_bound_at': DateTime.now().toUtc().toIso8601String(),
          'thinking_session_bound_by': 'task_center_app',
        },
      );
      onControllerChanged?.call(controller);
      await _sendThinkingPromptOnce(
        controller: controller,
        workspace: workspace,
        task: task,
      );
    } finally {
      _syncingThinkingTaskIds.remove(task.id);
    }
  }

  Future<bool> _resumeSessionIfNeeded({
    required ChatController controller,
    required String sessionId,
    required String cwd,
    required String title,
  }) async {
    if (controller.currentSession?.id == sessionId) return true;
    if (controller.isStreaming || controller.isSessionOperationRunning) {
      return false;
    }
    await controller.resumeSession(sessionId, cwd: cwd, title: title);
    onControllerChanged?.call(controller);
    return controller.currentSession?.id == sessionId;
  }

  Future<void> _sendWorkerPromptOnce({
    required ChatController controller,
    required TaskWorkspace workspace,
    required TaskCenterTask task,
    required TaskCenterWorkRun run,
  }) async {
    if (_promptedRunIds.contains(run.id)) return;
    _promptedRunIds.add(run.id);
    await controller.sendPrompt(
      _workerPrompt(workspace: workspace, task: task, run: run),
    );
    onControllerChanged?.call(controller);
  }

  Future<void> _sendThinkingPromptOnce({
    required ChatController controller,
    required TaskWorkspace workspace,
    required TaskCenterTask task,
  }) async {
    if (_promptedThinkingTaskIds.contains(task.id)) return;
    _promptedThinkingTaskIds.add(task.id);
    await controller.sendPrompt(
      _thinkingPrompt(workspace: workspace, task: task),
    );
    onControllerChanged?.call(controller);
  }
}

String _workspaceCwd(TaskWorkspace workspace, ChatController controller) {
  final workspaceCwd = workspace.workspaceCwd.trim();
  return workspaceCwd.isEmpty ? controller.cwd : workspaceCwd;
}

String _workerPrompt({
  required TaskWorkspace workspace,
  required TaskCenterTask task,
  required TaskCenterWorkRun run,
}) {
  final rolePrompt = workspace.agentConfig.workAgentPrompt.trim();
  return [
    '你是这个 workspace 的主工作agent，负责具体执行任务。',
    'workspace_id: ${workspace.id}',
    'workspace_title: ${workspace.title}',
    'task_id: ${task.id}',
    'work_run_id: ${run.id}',
    'task_title: ${task.title}',
    if (task.description.trim().isNotEmpty)
      'description: ${task.description.trim()}',
    if (task.details.trim().isNotEmpty) 'details: ${task.details.trim()}',
    if (task.objective.trim().isNotEmpty) 'objective: ${task.objective.trim()}',
    if (task.acceptanceCriteria.isNotEmpty) 'acceptance_criteria:',
    for (final item in task.acceptanceCriteria) '- $item',
    if (rolePrompt.isNotEmpty) 'role_prompt: $rolePrompt',
    '',
    '执行要求:',
    '1. 先校验目标和验收条件是否清晰。',
    '2. 如果目标或验收条件不清晰，调用 task_center_report_work_blocker 打回，不要继续执行。',
    '3. 执行过程中用 task_center_heartbeat_work_run 更新进度。',
    '4. 完成后调用 task_center_deliver_work_result 交付结果。',
    '5. 过程写在自己的执行记录里，群聊只交付认领和最终结果。',
  ].join('\n');
}

String _thinkingSessionId(TaskCenterTask task) {
  final value =
      task.metadata['thinking_session_id'] ??
      task.metadata['thinkingSessionId'];
  if (value is String && value.trim().isNotEmpty) return value.trim();
  return '';
}

String _thinkingPrompt({
  required TaskWorkspace workspace,
  required TaskCenterTask task,
}) {
  final rolePrompt = workspace.agentConfig.thinkingAgentPrompt.trim();
  final workAgents = workspace.agentConfig.workAgentNames
      .map((agent) => agent.trim())
      .where((agent) => agent.isNotEmpty)
      .join(', ');
  return [
    '你是这个 workspace 的主思考agent，负责深度思考和人工确认清单。',
    'workspace_id: ${workspace.id}',
    'workspace_title: ${workspace.title}',
    'task_id: ${task.id}',
    'task_title: ${task.title}',
    if (task.description.trim().isNotEmpty)
      'description: ${task.description.trim()}',
    if (task.details.trim().isNotEmpty) 'details: ${task.details.trim()}',
    if (task.objective.trim().isNotEmpty) 'objective: ${task.objective.trim()}',
    if (task.acceptanceCriteria.isNotEmpty) 'acceptance_criteria:',
    for (final item in task.acceptanceCriteria) '- $item',
    if (workAgents.isNotEmpty) 'work_agents: $workAgents',
    if (rolePrompt.isNotEmpty) 'role_prompt: $rolePrompt',
    '',
    '执行要求:',
    '1. 不要执行具体实现工作；不要先读取本地文件、运行终端命令或进入实现上下文，除非 human 明确要求你检查代码。',
    '2. 先用当前 prompt 内的任务信息梳理问题、风险和需要 human 判断的清单。',
    '3. 如果任务文字包含风险、确认、清单、ask human、confirmation、checklist，第一步必须调用 task_center_request_human_confirmation，把待确认问题写清楚。',
    '4. 如果需要 human 判断，调用 task_center_request_human_confirmation，不要只在自然语言里说需要确认。',
    '5. 如果已经清晰且无需 human 判断，调用 task_center_transfer_owner 交给 work_agent 或 work_agent_pool。',
    '6. 过程写在自己的执行记录里；群聊只呈现认领、问题清单和最终交接结果。',
  ].join('\n');
}
