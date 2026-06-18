import 'task_center_models.dart';
import 'task_center_store.dart';

typedef TaskCenterChanged = Future<void> Function();

class TaskCenterAgentApi {
  TaskCenterAgentApi({required this.store, this.onChanged});

  final TaskCenterStore store;
  final TaskCenterChanged? onChanged;

  static const List<String> _toolNames = <String>[
    'task_center_create_workspace',
    'task_center_list_workspaces',
    'task_center_configure_workspace_agents',
    'task_center_create_task',
    'task_center_update_task',
    'task_center_update_task_details',
    'task_center_set_acceptance',
    'task_center_transfer_owner',
    'task_center_request_human_confirmation',
    'task_center_answer_human_question',
    'task_center_list_role_tasks',
    'task_center_claim_work_task',
    'task_center_start_work_run',
    'task_center_heartbeat_work_run',
    'task_center_report_work_blocker',
    'task_center_release_work_task',
    'task_center_recover_stalled_task',
    'task_center_list_stalled_work',
    'task_center_record_execution_result',
    'task_center_list_task_events',
    'task_center_move_task',
    'task_center_list_tasks',
    'task_center_delete_task',
    'task_center_post_workspace_message',
    'task_center_list_workspace_messages',
    'task_center_record_admission_decision',
    'task_center_request_thinking_alignment',
    'task_center_deliver_work_result',
  ];

  List<String> get toolNames => _toolNames;

  Future<Map<String, Object?>> call(
    String toolName,
    Map<String, Object?> arguments,
  ) async {
    return switch (toolName) {
      'task_center_create_workspace' => _createWorkspace(arguments),
      'task_center_list_workspaces' => _listWorkspaces(),
      'task_center_configure_workspace_agents' => _configureWorkspaceAgents(
        arguments,
      ),
      'task_center_create_task' => _createTask(arguments),
      'task_center_update_task' => _updateTask(arguments),
      'task_center_update_task_details' => _updateTaskDetails(arguments),
      'task_center_set_acceptance' => _setAcceptance(arguments),
      'task_center_transfer_owner' => _transferOwner(arguments),
      'task_center_request_human_confirmation' => _requestHumanConfirmation(
        arguments,
      ),
      'task_center_answer_human_question' => _answerHumanQuestion(arguments),
      'task_center_list_role_tasks' => _listRoleTasks(arguments),
      'task_center_claim_work_task' => _claimWorkTask(arguments),
      'task_center_start_work_run' => _startWorkRun(arguments),
      'task_center_heartbeat_work_run' => _heartbeatWorkRun(arguments),
      'task_center_report_work_blocker' => _reportWorkBlocker(arguments),
      'task_center_release_work_task' => _releaseWorkTask(arguments),
      'task_center_recover_stalled_task' => _recoverStalledTask(arguments),
      'task_center_list_stalled_work' => _listStalledWork(arguments),
      'task_center_record_execution_result' => _recordExecutionResult(
        arguments,
      ),
      'task_center_list_task_events' => _listTaskEvents(arguments),
      'task_center_move_task' => _moveTask(arguments),
      'task_center_list_tasks' => _listTasks(arguments),
      'task_center_delete_task' => _deleteTask(arguments),
      'task_center_post_workspace_message' => _postWorkspaceMessage(arguments),
      'task_center_list_workspace_messages' => _listWorkspaceMessages(
        arguments,
      ),
      'task_center_record_admission_decision' => _recordAdmissionDecision(
        arguments,
      ),
      'task_center_request_thinking_alignment' => _requestThinkingAlignment(
        arguments,
      ),
      'task_center_deliver_work_result' => _deliverWorkResult(arguments),
      _ => throw FormatException('Unknown task center tool "$toolName".'),
    };
  }

  Future<Map<String, Object?>> _createWorkspace(
    Map<String, Object?> arguments,
  ) async {
    final workspace = await store.createWorkspace(
      title: _requiredString(arguments, 'title'),
      description: _optionalString(arguments, 'description') ?? '',
      workspaceCwd: _optionalString(arguments, 'workspace_cwd') ?? '',
      agentConfig: _agentConfig(arguments),
    );
    await _notifyChanged();
    return <String, Object?>{'workspace': workspace.toAgentJson()};
  }

  Future<Map<String, Object?>> _listWorkspaces() async {
    final snapshot = await store.load();
    return <String, Object?>{
      'workspaces': snapshot.workspaces
          .map((workspace) => workspace.toAgentJson())
          .toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _configureWorkspaceAgents(
    Map<String, Object?> arguments,
  ) async {
    final workspace = await store.updateWorkspaceAgentConfig(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      agentConfig: _agentConfig(arguments),
      workspaceCwd: _optionalString(arguments, 'workspace_cwd'),
    );
    await _notifyChanged();
    return <String, Object?>{'workspace': workspace.toAgentJson()};
  }

  Future<Map<String, Object?>> _createTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.createTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      title: _requiredString(arguments, 'title'),
      description: _optionalString(arguments, 'description') ?? '',
      details: _optionalString(arguments, 'details') ?? '',
      objective: _optionalString(arguments, 'objective') ?? '',
      acceptanceCriteria: _stringList(arguments['acceptance_criteria']),
      currentOwner:
          _optionalOwner(arguments['current_owner']) ??
          const TaskCenterTaskOwner.unassigned(),
      suggestedOwner: _optionalOwner(arguments['suggested_owner']),
      readiness:
          _optionalReadiness(arguments, 'readiness') ??
          TaskCenterReadiness.needsInfo,
      routeReason: _optionalString(arguments, 'route_reason') ?? '',
      status: _optionalStatus(arguments, 'status') ?? TaskCenterStatus.todo,
      metadata: _metadata(arguments['metadata']),
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _updateTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.updateTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      title: _optionalString(arguments, 'title'),
      description: _optionalString(arguments, 'description'),
      details: _optionalString(arguments, 'details'),
      objective: _optionalString(arguments, 'objective'),
      acceptanceCriteria: arguments.containsKey('acceptance_criteria')
          ? _stringList(arguments['acceptance_criteria'])
          : null,
      currentOwner: _optionalOwner(arguments['current_owner']),
      suggestedOwner: _optionalOwner(arguments['suggested_owner']),
      readiness: _optionalReadiness(arguments, 'readiness'),
      routeReason: _optionalString(arguments, 'route_reason'),
      executionResult: _optionalString(arguments, 'execution_result'),
      verificationNotes: _optionalString(arguments, 'verification_notes'),
      status: _optionalStatus(arguments, 'status'),
      metadata: arguments.containsKey('metadata')
          ? _metadata(arguments['metadata'])
          : null,
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _updateTaskDetails(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.updateTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      description: _optionalString(arguments, 'description'),
      details: _optionalString(arguments, 'details'),
      objective: _optionalString(arguments, 'objective'),
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _setAcceptance(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.updateTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      acceptanceCriteria: _stringList(arguments['acceptance_criteria']),
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _transferOwner(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.transferTaskOwner(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      owner: _requiredOwner(arguments['owner']),
      readiness: _optionalReadiness(arguments, 'readiness'),
      routeReason: _optionalString(arguments, 'route_reason') ?? '',
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _requestHumanConfirmation(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.requestHumanConfirmation(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      questions: _stringList(arguments['questions']),
      routeReason: _optionalString(arguments, 'route_reason') ?? '',
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _answerHumanQuestion(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.answerHumanQuestion(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      questionId: _requiredString(arguments, 'question_id'),
      answer: _requiredString(arguments, 'answer'),
      actor: _optionalString(arguments, 'actor') ?? 'human',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _listRoleTasks(
    Map<String, Object?> arguments,
  ) async {
    final tasks = await store.listRoleTasks(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      ownerKind: TaskCenterOwnerKind.fromId(
        _requiredString(arguments, 'owner_kind'),
      ),
      agentName: _optionalString(arguments, 'agent_name'),
    );
    return <String, Object?>{
      'tasks': tasks.map((task) => task.toAgentJson()).toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _claimWorkTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.claimWorkTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      agentName: _requiredString(arguments, 'agent_name'),
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _startWorkRun(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.startWorkRun(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      agentName: _requiredString(arguments, 'agent_name'),
      sessionId: _optionalString(arguments, 'session_id') ?? '',
      progressSummary: _optionalString(arguments, 'progress_summary') ?? '',
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _heartbeatWorkRun(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.heartbeatWorkRun(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      runId: _requiredString(arguments, 'run_id'),
      state: _requiredWorkRunState(arguments, 'state'),
      progressSummary: _optionalString(arguments, 'progress_summary') ?? '',
      nextCheckMinutes: _optionalInt(arguments, 'next_check_minutes'),
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _reportWorkBlocker(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.reportWorkBlocker(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      runId: _requiredString(arguments, 'run_id'),
      blockerType: _requiredBlockerType(arguments, 'blocker_type'),
      blockerReason: _requiredString(arguments, 'blocker_reason'),
      questions: _stringList(arguments['questions']),
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _releaseWorkTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.releaseWorkTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      runId: _requiredString(arguments, 'run_id'),
      reason: _requiredString(arguments, 'reason'),
      actor: _optionalString(arguments, 'actor') ?? 'agent',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _recoverStalledTask(
    Map<String, Object?> arguments,
  ) async {
    final task = await store.recoverStalledTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      action: _requiredRecoverAction(arguments, 'action'),
      agentName: _optionalString(arguments, 'agent_name') ?? '',
      reason: _optionalString(arguments, 'reason') ?? '',
      actor: _optionalString(arguments, 'actor') ?? 'human',
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _listStalledWork(
    Map<String, Object?> arguments,
  ) async {
    final tasks = await store.listStalledWork(
      workspaceId: _requiredString(arguments, 'workspace_id'),
    );
    return <String, Object?>{
      'tasks': tasks.map((task) => task.toAgentJson()).toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _recordExecutionResult(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspace_id');
    final taskId = _requiredString(arguments, 'task_id');
    final executionResult = _requiredString(arguments, 'execution_result');
    final verificationNotes =
        _optionalString(arguments, 'verification_notes') ?? '';
    final actor = _optionalString(arguments, 'actor') ?? 'agent';
    final snapshot = await store.load();
    final workspace = snapshot.workspaces.firstWhere(
      (candidate) => candidate.id == workspaceId,
      orElse: () => throw FormatException('Unknown workspace "$workspaceId".'),
    );
    final beforeTask = workspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
      orElse: () => throw FormatException('Unknown task "$taskId".'),
    );
    final cleanActor = actor.trim();
    final activeWorkerRun =
        cleanActor.isNotEmpty &&
        beforeTask.workRuns.any(
          (run) => run.isActive && run.agentName == cleanActor,
        );

    var task = await store.recordExecutionResult(
      workspaceId: workspaceId,
      taskId: taskId,
      executionResult: executionResult,
      verificationNotes: verificationNotes,
      actor: actor,
    );
    TaskWorkspaceChatMessage? message;
    if (activeWorkerRun) {
      task = await store.updateTask(
        workspaceId: workspaceId,
        taskId: taskId,
        status: TaskCenterStatus.done,
      );
      message = await store.postWorkspaceChatMessage(
        workspaceId: workspaceId,
        role: TaskWorkspaceChatRole.workAgent,
        actor: cleanActor,
        agentName: cleanActor,
        content: executionResult,
        taskId: taskId,
        metadata: <String, Object?>{
          'delivery': 'record_execution_result_fallback',
          if (verificationNotes.isNotEmpty)
            'verification_notes': verificationNotes,
        },
      );
    }
    await _notifyChanged();
    return <String, Object?>{
      'task': task.toAgentJson(),
      if (message != null) 'message': message.toAgentJson(),
    };
  }

  Future<Map<String, Object?>> _listTaskEvents(
    Map<String, Object?> arguments,
  ) async {
    final events = await store.listTaskEvents(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
    );
    return <String, Object?>{
      'events': events.map((event) => event.toAgentJson()).toList(),
    };
  }

  Future<Map<String, Object?>> _moveTask(Map<String, Object?> arguments) async {
    final task = await store.moveTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
      status: _requiredStatus(arguments, 'status'),
      index: _optionalInt(arguments, 'index') ?? 0,
    );
    await _notifyChanged();
    return <String, Object?>{'task': task.toAgentJson()};
  }

  Future<Map<String, Object?>> _listTasks(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspace_id');
    final status = _optionalStatus(arguments, 'status');
    final snapshot = await store.load();
    final workspace = snapshot.workspaces.firstWhere(
      (candidate) => candidate.id == workspaceId,
      orElse: () => throw FormatException('Unknown workspace "$workspaceId".'),
    );
    final tasks =
        workspace.tasks
            .where((task) => status == null || task.status == status)
            .toList()
          ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return <String, Object?>{
      'workspace': workspace.toAgentJson(),
      'tasks': tasks.map((task) => task.toAgentJson()).toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _deleteTask(
    Map<String, Object?> arguments,
  ) async {
    final deleted = await store.deleteTask(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      taskId: _requiredString(arguments, 'task_id'),
    );
    if (deleted) await _notifyChanged();
    return <String, Object?>{'deleted': deleted};
  }

  Future<Map<String, Object?>> _postWorkspaceMessage(
    Map<String, Object?> arguments,
  ) async {
    final message = await store.postWorkspaceChatMessage(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      role: _requiredChatRole(arguments, 'role'),
      actor: _requiredString(arguments, 'actor'),
      agentName: _optionalString(arguments, 'agent_name') ?? '',
      content: _requiredString(arguments, 'content'),
      taskId: _optionalString(arguments, 'task_id'),
      metadata: _metadata(arguments['metadata']),
    );
    await _notifyChanged();
    return <String, Object?>{'message': message.toAgentJson()};
  }

  Future<Map<String, Object?>> _listWorkspaceMessages(
    Map<String, Object?> arguments,
  ) async {
    final messages = await store.listWorkspaceChatMessages(
      workspaceId: _requiredString(arguments, 'workspace_id'),
    );
    return <String, Object?>{
      'messages': messages
          .map((message) => message.toAgentJson())
          .toList(growable: false),
    };
  }

  Future<Map<String, Object?>> _recordAdmissionDecision(
    Map<String, Object?> arguments,
  ) async {
    final decision = _requiredAdmissionDecision(arguments, 'decision');
    final reason = _optionalString(arguments, 'reason') ?? '';
    final agentName = _requiredString(arguments, 'agent_name');
    final content =
        _optionalString(arguments, 'content') ??
        _admissionDecisionMessage(decision: decision, reason: reason);
    final message = await store.postWorkspaceChatMessage(
      workspaceId: _requiredString(arguments, 'workspace_id'),
      role: TaskWorkspaceChatRole.fastAgent,
      actor: agentName,
      agentName: agentName,
      content: content,
      taskId: _optionalString(arguments, 'task_id'),
      metadata: <String, Object?>{
        'admission': decision,
        if (reason.isNotEmpty) 'reason': reason,
      },
    );
    await _notifyChanged();
    return <String, Object?>{'message': message.toAgentJson()};
  }

  Future<Map<String, Object?>> _requestThinkingAlignment(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspace_id');
    final taskId = _requiredString(arguments, 'task_id');
    final fastAgentName = _requiredString(arguments, 'fast_agent_name');
    final thinkingAgentName = _requiredString(arguments, 'thinking_agent_name');
    final question = _requiredString(arguments, 'question');
    final routeReason = _optionalString(arguments, 'route_reason') ?? question;
    final task = await store.transferTaskOwner(
      workspaceId: workspaceId,
      taskId: taskId,
      owner: TaskCenterTaskOwner.thinkingAgent(thinkingAgentName),
      readiness: TaskCenterReadiness.needsThinking,
      routeReason: routeReason,
      actor: fastAgentName,
    );
    final message = await store.postWorkspaceChatMessage(
      workspaceId: workspaceId,
      role: TaskWorkspaceChatRole.fastAgent,
      actor: fastAgentName,
      agentName: fastAgentName,
      content: question,
      taskId: taskId,
      metadata: <String, Object?>{
        'alignment': 'thinking_requested',
        'target_agent': thinkingAgentName,
      },
    );
    await _notifyChanged();
    return <String, Object?>{
      'task': task.toAgentJson(),
      'message': message.toAgentJson(),
    };
  }

  Future<Map<String, Object?>> _deliverWorkResult(
    Map<String, Object?> arguments,
  ) async {
    final workspaceId = _requiredString(arguments, 'workspace_id');
    final taskId = _requiredString(arguments, 'task_id');
    final agentName = _requiredString(arguments, 'agent_name');
    final executionResult = _requiredString(arguments, 'execution_result');
    final verificationNotes =
        _optionalString(arguments, 'verification_notes') ?? '';
    final snapshot = await store.load();
    final workspace = snapshot.workspaces.firstWhere(
      (candidate) => candidate.id == workspaceId,
      orElse: () => throw FormatException('Unknown workspace "$workspaceId".'),
    );
    final beforeTask = workspace.tasks.firstWhere(
      (candidate) => candidate.id == taskId,
      orElse: () => throw FormatException('Unknown task "$taskId".'),
    );
    final workRunForAgent = beforeTask.workRuns.any(
      (run) =>
          run.agentName == agentName &&
          (run.isActive || run.state == TaskCenterWorkRunState.delivered),
    );
    final legacyOwnerForAgent =
        beforeTask.workRuns.isEmpty &&
        beforeTask.currentOwner.matches(
          kind: TaskCenterOwnerKind.workAgent,
          agentName: agentName,
        );
    await store.recordExecutionResult(
      workspaceId: workspaceId,
      taskId: taskId,
      executionResult: executionResult,
      verificationNotes: verificationNotes,
      actor: agentName,
    );
    final requestedStatus = _optionalStatus(arguments, 'status');
    final isActiveWorker = workRunForAgent || legacyOwnerForAgent;
    final status = !isActiveWorker || requestedStatus == TaskCenterStatus.review
        ? TaskCenterStatus.review
        : TaskCenterStatus.done;
    final task = await store.updateTask(
      workspaceId: workspaceId,
      taskId: taskId,
      status: status,
    );
    final message = await store.postWorkspaceChatMessage(
      workspaceId: workspaceId,
      role: TaskWorkspaceChatRole.workAgent,
      actor: agentName,
      agentName: agentName,
      content: executionResult,
      taskId: taskId,
      metadata: <String, Object?>{
        'delivery': 'work_result',
        if (verificationNotes.isNotEmpty)
          'verification_notes': verificationNotes,
      },
    );
    await _notifyChanged();
    return <String, Object?>{
      'task': task.toAgentJson(),
      'message': message.toAgentJson(),
    };
  }

  Future<void> _notifyChanged() async {
    final callback = onChanged;
    if (callback != null) await callback();
  }
}

String _requiredString(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('$key is required.');
  }
  return value.trim();
}

String? _optionalString(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string.');
  return value.trim();
}

int? _optionalInt(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  throw FormatException('$key must be a number.');
}

TaskCenterStatus _requiredStatus(Map<String, Object?> arguments, String key) {
  final value = _requiredString(arguments, key);
  return TaskCenterStatus.fromId(value);
}

TaskCenterStatus? _optionalStatus(Map<String, Object?> arguments, String key) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string.');
  return TaskCenterStatus.fromId(value);
}

TaskCenterReadiness? _optionalReadiness(
  Map<String, Object?> arguments,
  String key,
) {
  final value = arguments[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('$key must be a string.');
  return TaskCenterReadiness.fromId(value);
}

TaskCenterWorkRunState _requiredWorkRunState(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterWorkRunState.fromId(_requiredString(arguments, key));
}

TaskCenterWorkBlockerType _requiredBlockerType(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterWorkBlockerType.fromId(_requiredString(arguments, key));
}

TaskCenterRecoverAction _requiredRecoverAction(
  Map<String, Object?> arguments,
  String key,
) {
  return TaskCenterRecoverAction.fromId(_requiredString(arguments, key));
}

TaskWorkspaceChatRole _requiredChatRole(
  Map<String, Object?> arguments,
  String key,
) {
  final value = _requiredString(arguments, key);
  return TaskWorkspaceChatRole.fromId(value);
}

String _requiredAdmissionDecision(Map<String, Object?> arguments, String key) {
  final value = _requiredString(arguments, key);
  const allowed = <String>{
    'accepted',
    'needs_thinking',
    'needs_human',
    'rejected',
  };
  if (!allowed.contains(value)) {
    throw FormatException('$key must be one of ${allowed.join(', ')}.');
  }
  return value;
}

String _admissionDecisionMessage({
  required String decision,
  required String reason,
}) {
  final suffix = reason.isEmpty ? '' : '：$reason';
  return switch (decision) {
    'accepted' => '已准入$suffix',
    'needs_thinking' => '需要先和 thinking agent 对齐$suffix',
    'needs_human' => '需要人工补充信息$suffix',
    'rejected' => '暂不准入$suffix',
    _ => decision,
  };
}

TaskWorkspaceAgentConfig _agentConfig(Map<String, Object?> arguments) {
  return TaskWorkspaceAgentConfig(
    fastAgentName: _optionalString(arguments, 'fast_agent_name') ?? '',
    thinkingAgentName: _optionalString(arguments, 'thinking_agent_name') ?? '',
    workAgentNames: _stringList(arguments['work_agent_names']),
    fastAgentPrompt: _optionalString(arguments, 'fast_agent_prompt') ?? '',
    thinkingAgentPrompt:
        _optionalString(arguments, 'thinking_agent_prompt') ?? '',
    workAgentPrompt: _optionalString(arguments, 'work_agent_prompt') ?? '',
  );
}

TaskCenterTaskOwner _requiredOwner(Object? raw) {
  if (raw == null) throw const FormatException('owner is required.');
  return TaskCenterTaskOwner.fromJson(raw);
}

TaskCenterTaskOwner? _optionalOwner(Object? raw) {
  if (raw == null) return null;
  return TaskCenterTaskOwner.fromJson(raw);
}

List<String> _stringList(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is! List) throw const FormatException('value must be a list.');
  return raw
      .map((item) {
        if (item is! String) {
          throw const FormatException('list entries must be strings.');
        }
        return item.trim();
      })
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

Map<String, Object?> _metadata(Object? raw) {
  if (raw == null) return const <String, Object?>{};
  if (raw is! Map) throw const FormatException('metadata must be an object.');
  final result = <String, Object?>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('metadata keys must be strings.');
    }
    result[key] = entry.value;
  }
  return result;
}
