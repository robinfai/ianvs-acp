enum TaskCenterStatus {
  todo('todo', 'To Do'),
  inProgress('in_progress', 'In Progress'),
  review('review', 'Review'),
  done('done', 'Done');

  const TaskCenterStatus(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterStatus fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final status in values) {
      if (status.id == normalized) return status;
    }
    throw FormatException('Unknown task status "$id".');
  }
}

enum TaskCenterOwnerKind {
  unassigned('unassigned', 'Unassigned'),
  fastAgent('fast_agent', 'Main Fast Agent'),
  thinkingAgent('thinking_agent', 'Main Thinking Agent'),
  human('human', 'Human Confirm'),
  workAgentPool('work_agent_pool', 'Work Agent Pool'),
  workAgent('work_agent', 'Work Agent');

  const TaskCenterOwnerKind(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterOwnerKind fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final kind in values) {
      if (kind.id == normalized) return kind;
    }
    throw FormatException('Unknown task owner kind "$id".');
  }
}

enum TaskCenterReadiness {
  needsInfo('needs_info', 'Needs Info'),
  needsThinking('needs_thinking', 'Needs Thinking'),
  waitingHuman('waiting_human', 'Waiting Human'),
  ready('ready', 'Ready'),
  blocked('blocked', 'Blocked');

  const TaskCenterReadiness(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterReadiness fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final readiness in values) {
      if (readiness.id == normalized) return readiness;
    }
    throw FormatException('Unknown task readiness "$id".');
  }
}

enum TaskCenterWorkRunState {
  claimed('claimed', 'Claimed'),
  running('running', 'Running'),
  waitingPermission('waiting_permission', 'Waiting Permission'),
  waitingHuman('waiting_human', 'Waiting Human'),
  blocked('blocked', 'Blocked'),
  stale('stale', 'Stale'),
  failed('failed', 'Failed'),
  released('released', 'Released'),
  delivered('delivered', 'Delivered');

  const TaskCenterWorkRunState(this.id, this.label);

  final String id;
  final String label;

  static TaskCenterWorkRunState fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final state in values) {
      if (state.id == normalized) return state;
    }
    throw FormatException('Unknown work run state "$id".');
  }
}

enum TaskCenterWorkBlockerType {
  unclearGoal('unclear_goal'),
  missingAcceptance('missing_acceptance'),
  needsHuman('needs_human'),
  permission('permission'),
  toolError('tool_error'),
  externalDependency('external_dependency'),
  other('other');

  const TaskCenterWorkBlockerType(this.id);

  final String id;

  static TaskCenterWorkBlockerType fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final type in values) {
      if (type.id == normalized) return type;
    }
    throw FormatException('Unknown work blocker type "$id".');
  }
}

enum TaskCenterRecoverAction {
  nudgeWorker('nudge_worker'),
  reassignWorker('reassign_worker'),
  returnToFast('return_to_fast'),
  sendToThinking('send_to_thinking'),
  askHuman('ask_human'),
  markFailed('mark_failed');

  const TaskCenterRecoverAction(this.id);

  final String id;

  static TaskCenterRecoverAction fromId(String id) {
    final normalized = id.trim().toLowerCase();
    for (final action in values) {
      if (action.id == normalized) return action;
    }
    throw FormatException('Unknown recovery action "$id".');
  }
}

class TaskCenterWorkRun {
  const TaskCenterWorkRun({
    required this.id,
    required this.taskId,
    required this.agentName,
    required this.state,
    required this.startedAt,
    required this.lastHeartbeatAt,
    this.sessionId = '',
    this.completedAt,
    this.progressSummary = '',
    this.blockerReason = '',
    this.nextCheckAt,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String taskId;
  final String agentName;
  final String sessionId;
  final TaskCenterWorkRunState state;
  final DateTime startedAt;
  final DateTime lastHeartbeatAt;
  final DateTime? completedAt;
  final String progressSummary;
  final String blockerReason;
  final DateTime? nextCheckAt;
  final Map<String, Object?> metadata;

  bool get isActive {
    return switch (state) {
      TaskCenterWorkRunState.claimed ||
      TaskCenterWorkRunState.running ||
      TaskCenterWorkRunState.waitingPermission ||
      TaskCenterWorkRunState.waitingHuman => true,
      _ => false,
    };
  }

  TaskCenterWorkRun copyWith({
    String? sessionId,
    TaskCenterWorkRunState? state,
    DateTime? lastHeartbeatAt,
    DateTime? completedAt,
    String? progressSummary,
    String? blockerReason,
    DateTime? nextCheckAt,
    Map<String, Object?>? metadata,
  }) {
    return TaskCenterWorkRun(
      id: id,
      taskId: taskId,
      agentName: agentName,
      sessionId: sessionId ?? this.sessionId,
      state: state ?? this.state,
      startedAt: startedAt,
      lastHeartbeatAt: lastHeartbeatAt ?? this.lastHeartbeatAt,
      completedAt: completedAt ?? this.completedAt,
      progressSummary: progressSummary ?? this.progressSummary,
      blockerReason: blockerReason ?? this.blockerReason,
      nextCheckAt: nextCheckAt ?? this.nextCheckAt,
      metadata: metadata ?? this.metadata,
    );
  }

  factory TaskCenterWorkRun.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('work run entries must be objects.');
    }
    final json = _jsonMap(raw);
    return TaskCenterWorkRun(
      id: _requiredString(json['id'], 'work_run.id'),
      taskId: _requiredString(
        json['task_id'] ?? json['taskId'],
        'work_run.task_id',
      ),
      agentName: _requiredString(
        json['agent_name'] ?? json['agentName'],
        'work_run.agent_name',
      ),
      sessionId: _stringValue(json['session_id'] ?? json['sessionId']) ?? '',
      state: TaskCenterWorkRunState.fromId(
        _requiredString(json['state'], 'work_run.state'),
      ),
      startedAt: _dateTimeValue(json['started_at'], 'work_run.started_at'),
      lastHeartbeatAt: _dateTimeValue(
        json['last_heartbeat_at'] ?? json['lastHeartbeatAt'],
        'work_run.last_heartbeat_at',
      ),
      completedAt: _optionalDateTimeValue(
        json['completed_at'] ?? json['completedAt'],
        'work_run.completed_at',
      ),
      progressSummary:
          _stringValue(json['progress_summary'] ?? json['progressSummary']) ??
          '',
      blockerReason:
          _stringValue(json['blocker_reason'] ?? json['blockerReason']) ?? '',
      nextCheckAt: _optionalDateTimeValue(
        json['next_check_at'] ?? json['nextCheckAt'],
        'work_run.next_check_at',
      ),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'task_id': taskId,
      'agent_name': agentName,
      if (sessionId.isNotEmpty) 'session_id': sessionId,
      'state': state.id,
      'started_at': startedAt.toIso8601String(),
      'last_heartbeat_at': lastHeartbeatAt.toIso8601String(),
      if (completedAt != null) 'completed_at': completedAt!.toIso8601String(),
      if (progressSummary.isNotEmpty) 'progress_summary': progressSummary,
      if (blockerReason.isNotEmpty) 'blocker_reason': blockerReason,
      if (nextCheckAt != null) 'next_check_at': nextCheckAt!.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{...toJson(), 'state_label': state.label};
  }
}

class TaskCenterTaskOwner {
  const TaskCenterTaskOwner({
    required this.kind,
    this.agentName = '',
    this.workAgentIndex,
  });

  const TaskCenterTaskOwner.unassigned()
    : this(kind: TaskCenterOwnerKind.unassigned);

  const TaskCenterTaskOwner.fastAgent(String agentName)
    : this(kind: TaskCenterOwnerKind.fastAgent, agentName: agentName);

  const TaskCenterTaskOwner.thinkingAgent(String agentName)
    : this(kind: TaskCenterOwnerKind.thinkingAgent, agentName: agentName);

  const TaskCenterTaskOwner.human() : this(kind: TaskCenterOwnerKind.human);

  const TaskCenterTaskOwner.workAgentPool()
    : this(kind: TaskCenterOwnerKind.workAgentPool);

  const TaskCenterTaskOwner.workAgent(String agentName, {int? index})
    : this(
        kind: TaskCenterOwnerKind.workAgent,
        agentName: agentName,
        workAgentIndex: index,
      );

  final TaskCenterOwnerKind kind;
  final String agentName;
  final int? workAgentIndex;

  String get label {
    final cleanAgentName = agentName.trim();
    if (cleanAgentName.isEmpty) return kind.label;
    return '${kind.label}: $cleanAgentName';
  }

  bool matches({required TaskCenterOwnerKind kind, String? agentName}) {
    if (this.kind != kind) return false;
    final cleanAgent = agentName?.trim();
    if (cleanAgent == null || cleanAgent.isEmpty) return true;
    return this.agentName == cleanAgent;
  }

  factory TaskCenterTaskOwner.fromJson(Object? raw) {
    if (raw == null) return const TaskCenterTaskOwner.unassigned();
    if (raw is String) {
      return TaskCenterTaskOwner(kind: TaskCenterOwnerKind.fromId(raw));
    }
    if (raw is! Map) {
      throw const FormatException('current_owner must be an object.');
    }
    final json = _jsonMap(raw);
    return TaskCenterTaskOwner(
      kind: TaskCenterOwnerKind.fromId(
        _requiredString(json['kind'], 'owner.kind'),
      ),
      agentName: _stringValue(json['agent_name'] ?? json['agentName']) ?? '',
      workAgentIndex: _intValue(
        json['work_agent_index'] ?? json['workAgentIndex'],
      ),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'kind': kind.id,
      if (agentName.isNotEmpty) 'agent_name': agentName,
      if (workAgentIndex != null) 'work_agent_index': workAgentIndex,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{...toJson(), 'label': label};
  }
}

class TaskWorkspaceAgentConfig {
  const TaskWorkspaceAgentConfig({
    this.fastAgentName = '',
    this.thinkingAgentName = '',
    this.workAgentNames = const <String>[],
    this.fastAgentPrompt = '',
    this.thinkingAgentPrompt = '',
    this.workAgentPrompt = '',
  });

  final String fastAgentName;
  final String thinkingAgentName;
  final List<String> workAgentNames;
  final String fastAgentPrompt;
  final String thinkingAgentPrompt;
  final String workAgentPrompt;

  bool get isEmpty =>
      fastAgentName.isEmpty &&
      thinkingAgentName.isEmpty &&
      workAgentNames.isEmpty &&
      fastAgentPrompt.isEmpty &&
      thinkingAgentPrompt.isEmpty &&
      workAgentPrompt.isEmpty;

  TaskWorkspaceAgentConfig copyWith({
    String? fastAgentName,
    String? thinkingAgentName,
    List<String>? workAgentNames,
    String? fastAgentPrompt,
    String? thinkingAgentPrompt,
    String? workAgentPrompt,
  }) {
    return TaskWorkspaceAgentConfig(
      fastAgentName: fastAgentName ?? this.fastAgentName,
      thinkingAgentName: thinkingAgentName ?? this.thinkingAgentName,
      workAgentNames: workAgentNames ?? this.workAgentNames,
      fastAgentPrompt: fastAgentPrompt ?? this.fastAgentPrompt,
      thinkingAgentPrompt: thinkingAgentPrompt ?? this.thinkingAgentPrompt,
      workAgentPrompt: workAgentPrompt ?? this.workAgentPrompt,
    );
  }

  factory TaskWorkspaceAgentConfig.fromJson(Object? raw) {
    if (raw == null) return const TaskWorkspaceAgentConfig();
    if (raw is! Map) {
      throw const FormatException('workspace agent_config must be an object.');
    }
    final json = _jsonMap(raw);
    return TaskWorkspaceAgentConfig(
      fastAgentName:
          _stringValue(json['fast_agent_name'] ?? json['fastAgentName']) ?? '',
      thinkingAgentName:
          _stringValue(
            json['thinking_agent_name'] ?? json['thinkingAgentName'],
          ) ??
          '',
      workAgentNames: _stringListValue(
        json['work_agent_names'] ?? json['workAgentNames'],
      ),
      fastAgentPrompt:
          _stringValue(json['fast_agent_prompt'] ?? json['fastAgentPrompt']) ??
          '',
      thinkingAgentPrompt:
          _stringValue(
            json['thinking_agent_prompt'] ?? json['thinkingAgentPrompt'],
          ) ??
          '',
      workAgentPrompt:
          _stringValue(json['work_agent_prompt'] ?? json['workAgentPrompt']) ??
          '',
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      if (fastAgentName.isNotEmpty) 'fast_agent_name': fastAgentName,
      if (thinkingAgentName.isNotEmpty)
        'thinking_agent_name': thinkingAgentName,
      if (workAgentNames.isNotEmpty) 'work_agent_names': workAgentNames,
      if (fastAgentPrompt.isNotEmpty) 'fast_agent_prompt': fastAgentPrompt,
      if (thinkingAgentPrompt.isNotEmpty)
        'thinking_agent_prompt': thinkingAgentPrompt,
      if (workAgentPrompt.isNotEmpty) 'work_agent_prompt': workAgentPrompt,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'fast_agent_name': fastAgentName,
      'thinking_agent_name': thinkingAgentName,
      'work_agent_names': workAgentNames,
      'fast_agent_prompt': fastAgentPrompt,
      'thinking_agent_prompt': thinkingAgentPrompt,
      'work_agent_prompt': workAgentPrompt,
    };
  }
}

class TaskCenterHumanQuestion {
  const TaskCenterHumanQuestion({
    required this.id,
    required this.question,
    this.answer = '',
    this.resolved = false,
  });

  final String id;
  final String question;
  final String answer;
  final bool resolved;

  TaskCenterHumanQuestion copyWith({String? answer, bool? resolved}) {
    return TaskCenterHumanQuestion(
      id: id,
      question: question,
      answer: answer ?? this.answer,
      resolved: resolved ?? this.resolved,
    );
  }

  factory TaskCenterHumanQuestion.fromJson(Object? raw) {
    if (raw is String) {
      return TaskCenterHumanQuestion(id: raw, question: raw);
    }
    if (raw is! Map) {
      throw const FormatException('human question entries must be objects.');
    }
    final json = _jsonMap(raw);
    return TaskCenterHumanQuestion(
      id: _requiredString(json['id'], 'human_question.id'),
      question: _requiredString(json['question'], 'human_question.question'),
      answer: _stringValue(json['answer']) ?? '',
      resolved: _boolValue(json['resolved']) ?? false,
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'question': question,
      if (answer.isNotEmpty) 'answer': answer,
      if (resolved) 'resolved': true,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'question': question,
      'answer': answer,
      'resolved': resolved,
    };
  }
}

enum TaskWorkspaceChatRole {
  human('human', 'Human'),
  fastAgent('fast_agent', 'Fast Agent'),
  thinkingAgent('thinking_agent', 'Thinking Agent'),
  workAgent('work_agent', 'Work Agent'),
  system('system', 'System');

  const TaskWorkspaceChatRole(this.id, this.label);

  final String id;
  final String label;

  static TaskWorkspaceChatRole fromId(String id) {
    for (final role in values) {
      if (role.id == id) return role;
    }
    throw FormatException('Unknown workspace chat role "$id".');
  }
}

class TaskWorkspaceChatMessage {
  const TaskWorkspaceChatMessage({
    required this.id,
    required this.workspaceId,
    required this.role,
    required this.actor,
    required this.content,
    required this.createdAt,
    this.agentName = '',
    this.taskId,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String workspaceId;
  final TaskWorkspaceChatRole role;
  final String actor;
  final String agentName;
  final String content;
  final String? taskId;
  final DateTime createdAt;
  final Map<String, Object?> metadata;

  factory TaskWorkspaceChatMessage.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('workspace chat entries must be objects.');
    }
    final json = _jsonMap(raw);
    return TaskWorkspaceChatMessage(
      id: _requiredString(json['id'], 'workspace_chat.id'),
      workspaceId: _requiredString(
        json['workspace_id'] ?? json['workspaceId'],
        'workspace_chat.workspace_id',
      ),
      role: TaskWorkspaceChatRole.fromId(
        _requiredString(json['role'], 'workspace_chat.role'),
      ),
      actor: _stringValue(json['actor']) ?? 'unknown',
      agentName: _stringValue(json['agent_name'] ?? json['agentName']) ?? '',
      content: _stringValue(json['content']) ?? '',
      taskId: _stringValue(json['task_id'] ?? json['taskId']),
      createdAt: _dateTimeValue(
        json['created_at'] ?? json['createdAt'],
        'workspace_chat.created_at',
      ),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'role': role.id,
      'actor': actor,
      if (agentName.isNotEmpty) 'agent_name': agentName,
      'content': content,
      if (taskId != null) 'task_id': taskId,
      'created_at': createdAt.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'role': role.id,
      'role_label': role.label,
      'actor': actor,
      'agent_name': agentName,
      'content': content,
      'task_id': taskId,
      'created_at': createdAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}

class TaskCenterEvent {
  const TaskCenterEvent({
    required this.id,
    required this.type,
    required this.actor,
    required this.message,
    required this.createdAt,
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String type;
  final String actor;
  final String message;
  final DateTime createdAt;
  final Map<String, Object?> metadata;

  factory TaskCenterEvent.fromJson(Object? raw) {
    if (raw is! Map) {
      throw const FormatException('task event entries must be objects.');
    }
    final json = _jsonMap(raw);
    return TaskCenterEvent(
      id: _requiredString(json['id'], 'event.id'),
      type: _requiredString(json['type'], 'event.type'),
      actor: _stringValue(json['actor']) ?? 'unknown',
      message: _stringValue(json['message']) ?? '',
      createdAt: _dateTimeValue(json['created_at'], 'event.created_at'),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'type': type,
      'actor': actor,
      'message': message,
      'created_at': createdAt.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'type': type,
      'actor': actor,
      'message': message,
      'created_at': createdAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}

class TaskCenterSnapshot {
  const TaskCenterSnapshot({
    this.version = 1,
    this.workspaces = const <TaskWorkspace>[],
  });

  final int version;
  final List<TaskWorkspace> workspaces;

  TaskCenterSnapshot copyWith({List<TaskWorkspace>? workspaces}) {
    return TaskCenterSnapshot(
      version: version,
      workspaces: workspaces ?? this.workspaces,
    );
  }

  factory TaskCenterSnapshot.fromJson(Map<String, dynamic> json) {
    final workspacesRaw = json['workspaces'];
    if (workspacesRaw == null) return const TaskCenterSnapshot();
    if (workspacesRaw is! List) {
      throw const FormatException('task center workspaces must be a list.');
    }
    return TaskCenterSnapshot(
      version: _intValue(json['version']) ?? 1,
      workspaces: workspacesRaw
          .map<TaskWorkspace>((item) {
            if (item is! Map) {
              throw const FormatException('workspace entries must be objects.');
            }
            return TaskWorkspace.fromJson(_jsonMap(item));
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'version': version,
      'workspaces': workspaces.map((workspace) => workspace.toJson()).toList(),
    };
  }
}

class TaskWorkspace {
  const TaskWorkspace({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.workspaceCwd = '',
    this.agentConfig = const TaskWorkspaceAgentConfig(),
    this.chatMessages = const <TaskWorkspaceChatMessage>[],
    this.tasks = const <TaskCenterTask>[],
  });

  final String id;
  final String title;
  final String description;
  final String workspaceCwd;
  final DateTime createdAt;
  final DateTime updatedAt;
  final TaskWorkspaceAgentConfig agentConfig;
  final List<TaskWorkspaceChatMessage> chatMessages;
  final List<TaskCenterTask> tasks;

  TaskWorkspace copyWith({
    String? title,
    String? description,
    String? workspaceCwd,
    DateTime? updatedAt,
    TaskWorkspaceAgentConfig? agentConfig,
    List<TaskWorkspaceChatMessage>? chatMessages,
    List<TaskCenterTask>? tasks,
  }) {
    return TaskWorkspace(
      id: id,
      title: title ?? this.title,
      description: description ?? this.description,
      workspaceCwd: workspaceCwd ?? this.workspaceCwd,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      agentConfig: agentConfig ?? this.agentConfig,
      chatMessages: chatMessages ?? this.chatMessages,
      tasks: tasks ?? this.tasks,
    );
  }

  factory TaskWorkspace.fromJson(Map<String, dynamic> json) {
    final tasksRaw = json['tasks'];
    if (tasksRaw != null && tasksRaw is! List) {
      throw const FormatException('workspace tasks must be a list.');
    }
    final chatRaw = json['chat_messages'] ?? json['chatMessages'];
    if (chatRaw != null && chatRaw is! List) {
      throw const FormatException('workspace chat_messages must be a list.');
    }
    return TaskWorkspace(
      id: _requiredString(json['id'], 'workspace.id'),
      title: _requiredString(json['title'], 'workspace.title'),
      description: _stringValue(json['description']) ?? '',
      workspaceCwd:
          _stringValue(json['workspace_cwd'] ?? json['workspaceCwd']) ?? '',
      createdAt: _dateTimeValue(json['created_at'], 'workspace.created_at'),
      updatedAt: _dateTimeValue(json['updated_at'], 'workspace.updated_at'),
      agentConfig: TaskWorkspaceAgentConfig.fromJson(
        json['agent_config'] ?? json['agentConfig'],
      ),
      chatMessages: (chatRaw ?? const <Object?>[])
          .map<TaskWorkspaceChatMessage>(TaskWorkspaceChatMessage.fromJson)
          .toList(growable: false),
      tasks: (tasksRaw ?? const <Object?>[])
          .map<TaskCenterTask>((item) {
            if (item is! Map) {
              throw const FormatException('task entries must be objects.');
            }
            return TaskCenterTask.fromJson(_jsonMap(item));
          })
          .toList(growable: false),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      if (description.isNotEmpty) 'description': description,
      if (workspaceCwd.isNotEmpty) 'workspace_cwd': workspaceCwd,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (!agentConfig.isEmpty) 'agent_config': agentConfig.toJson(),
      if (chatMessages.isNotEmpty)
        'chat_messages': chatMessages
            .map((message) => message.toJson())
            .toList(growable: false),
      'tasks': tasks.map((task) => task.toJson()).toList(),
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'title': title,
      'description': description,
      'workspace_cwd': workspaceCwd,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'task_count': tasks.length,
      'chat_message_count': chatMessages.length,
      'agent_config': agentConfig.toAgentJson(),
    };
  }
}

class TaskCenterTask {
  const TaskCenterTask({
    required this.id,
    required this.workspaceId,
    required this.title,
    required this.status,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
    this.description = '',
    this.details = '',
    this.objective = '',
    this.acceptanceCriteria = const <String>[],
    this.humanQuestions = const <TaskCenterHumanQuestion>[],
    this.currentOwner = const TaskCenterTaskOwner.unassigned(),
    this.suggestedOwner,
    this.readiness = TaskCenterReadiness.needsInfo,
    this.routeReason = '',
    this.executionResult = '',
    this.verificationNotes = '',
    this.workRuns = const <TaskCenterWorkRun>[],
    this.events = const <TaskCenterEvent>[],
    this.metadata = const <String, Object?>{},
  });

  final String id;
  final String workspaceId;
  final String title;
  final String description;
  final String details;
  final String objective;
  final List<String> acceptanceCriteria;
  final List<TaskCenterHumanQuestion> humanQuestions;
  final TaskCenterTaskOwner currentOwner;
  final TaskCenterTaskOwner? suggestedOwner;
  final TaskCenterReadiness readiness;
  final String routeReason;
  final String executionResult;
  final String verificationNotes;
  final List<TaskCenterWorkRun> workRuns;
  final List<TaskCenterEvent> events;
  final TaskCenterStatus status;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Map<String, Object?> metadata;

  TaskCenterTask copyWith({
    String? title,
    String? description,
    String? details,
    String? objective,
    List<String>? acceptanceCriteria,
    List<TaskCenterHumanQuestion>? humanQuestions,
    TaskCenterTaskOwner? currentOwner,
    TaskCenterTaskOwner? suggestedOwner,
    TaskCenterReadiness? readiness,
    String? routeReason,
    String? executionResult,
    String? verificationNotes,
    List<TaskCenterWorkRun>? workRuns,
    List<TaskCenterEvent>? events,
    TaskCenterStatus? status,
    int? sortOrder,
    DateTime? updatedAt,
    Map<String, Object?>? metadata,
  }) {
    return TaskCenterTask(
      id: id,
      workspaceId: workspaceId,
      title: title ?? this.title,
      description: description ?? this.description,
      details: details ?? this.details,
      objective: objective ?? this.objective,
      acceptanceCriteria: acceptanceCriteria ?? this.acceptanceCriteria,
      humanQuestions: humanQuestions ?? this.humanQuestions,
      currentOwner: currentOwner ?? this.currentOwner,
      suggestedOwner: suggestedOwner ?? this.suggestedOwner,
      readiness: readiness ?? this.readiness,
      routeReason: routeReason ?? this.routeReason,
      executionResult: executionResult ?? this.executionResult,
      verificationNotes: verificationNotes ?? this.verificationNotes,
      workRuns: workRuns ?? this.workRuns,
      events: events ?? this.events,
      status: status ?? this.status,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      metadata: metadata ?? this.metadata,
    );
  }

  factory TaskCenterTask.fromJson(Map<String, dynamic> json) {
    return TaskCenterTask(
      id: _requiredString(json['id'], 'task.id'),
      workspaceId: _requiredString(json['workspace_id'], 'task.workspace_id'),
      title: _requiredString(json['title'], 'task.title'),
      description: _stringValue(json['description']) ?? '',
      details: _stringValue(json['details']) ?? '',
      objective: _stringValue(json['objective']) ?? '',
      acceptanceCriteria: _stringListValue(
        json['acceptance_criteria'] ?? json['acceptanceCriteria'],
      ),
      humanQuestions: _humanQuestions(
        json['human_questions'] ?? json['humanQuestions'],
      ),
      currentOwner: TaskCenterTaskOwner.fromJson(
        json['current_owner'] ?? json['currentOwner'],
      ),
      suggestedOwner: _optionalOwner(
        json['suggested_owner'] ?? json['suggestedOwner'],
      ),
      readiness: TaskCenterReadiness.fromId(
        _stringValue(json['readiness']) ?? TaskCenterReadiness.needsInfo.id,
      ),
      routeReason:
          _stringValue(json['route_reason'] ?? json['routeReason']) ?? '',
      executionResult:
          _stringValue(json['execution_result'] ?? json['executionResult']) ??
          '',
      verificationNotes:
          _stringValue(
            json['verification_notes'] ?? json['verificationNotes'],
          ) ??
          '',
      workRuns: _workRuns(json['work_runs'] ?? json['workRuns']),
      events: _events(json['events']),
      status: TaskCenterStatus.fromId(
        _requiredString(json['status'], 'task.status'),
      ),
      sortOrder: _intValue(json['sort_order']) ?? 0,
      createdAt: _dateTimeValue(json['created_at'], 'task.created_at'),
      updatedAt: _dateTimeValue(json['updated_at'], 'task.updated_at'),
      metadata: _objectMap(json['metadata']),
    );
  }

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'title': title,
      if (description.isNotEmpty) 'description': description,
      if (details.isNotEmpty) 'details': details,
      if (objective.isNotEmpty) 'objective': objective,
      if (acceptanceCriteria.isNotEmpty)
        'acceptance_criteria': acceptanceCriteria,
      if (humanQuestions.isNotEmpty)
        'human_questions': humanQuestions
            .map((question) => question.toJson())
            .toList(),
      'current_owner': currentOwner.toJson(),
      if (suggestedOwner != null) 'suggested_owner': suggestedOwner!.toJson(),
      'readiness': readiness.id,
      if (routeReason.isNotEmpty) 'route_reason': routeReason,
      if (executionResult.isNotEmpty) 'execution_result': executionResult,
      if (verificationNotes.isNotEmpty) 'verification_notes': verificationNotes,
      if (workRuns.isNotEmpty)
        'work_runs': workRuns.map((run) => run.toJson()).toList(),
      if (events.isNotEmpty)
        'events': events.map((event) => event.toJson()).toList(),
      'status': status.id,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      if (metadata.isNotEmpty) 'metadata': metadata,
    };
  }

  Map<String, Object?> toAgentJson() {
    return <String, Object?>{
      'id': id,
      'workspace_id': workspaceId,
      'title': title,
      'description': description,
      'details': details,
      'objective': objective,
      'acceptance_criteria': acceptanceCriteria,
      'human_questions': humanQuestions
          .map((question) => question.toAgentJson())
          .toList(),
      'current_owner': currentOwner.toAgentJson(),
      'suggested_owner': suggestedOwner?.toAgentJson(),
      'readiness': readiness.id,
      'readiness_label': readiness.label,
      'route_reason': routeReason,
      'execution_result': executionResult,
      'verification_notes': verificationNotes,
      'work_runs': workRuns.map((run) => run.toAgentJson()).toList(),
      'status': status.id,
      'status_label': status.label,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'metadata': metadata,
    };
  }
}

String _requiredString(Object? value, String fieldName) {
  final result = _stringValue(value);
  if (result == null) throw FormatException('$fieldName is required.');
  return result;
}

String? _stringValue(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

bool? _boolValue(Object? value) {
  if (value is bool) return value;
  return null;
}

int? _intValue(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return null;
}

DateTime _dateTimeValue(Object? value, String fieldName) {
  final raw = _requiredString(value, fieldName);
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) throw FormatException('$fieldName must be a date.');
  return parsed;
}

DateTime? _optionalDateTimeValue(Object? value, String fieldName) {
  if (value == null) return null;
  return _dateTimeValue(value, fieldName);
}

Map<String, dynamic> _jsonMap(Map raw) {
  final result = <String, dynamic>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String) {
      throw const FormatException('JSON object keys must be strings.');
    }
    result[key] = entry.value;
  }
  return result;
}

Map<String, Object?> _objectMap(Object? raw) {
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

List<String> _stringListValue(Object? raw) {
  if (raw == null) return const <String>[];
  if (raw is! List) throw const FormatException('value must be a list.');
  return raw
      .map((item) {
        final value = _stringValue(item);
        if (value == null) {
          throw const FormatException('list entries must be strings.');
        }
        return value;
      })
      .toList(growable: false);
}

TaskCenterTaskOwner? _optionalOwner(Object? raw) {
  if (raw == null) return null;
  return TaskCenterTaskOwner.fromJson(raw);
}

List<TaskCenterHumanQuestion> _humanQuestions(Object? raw) {
  if (raw == null) return const <TaskCenterHumanQuestion>[];
  if (raw is! List) {
    throw const FormatException('human_questions must be a list.');
  }
  return raw
      .map((item) => TaskCenterHumanQuestion.fromJson(item))
      .toList(growable: false);
}

List<TaskCenterWorkRun> _workRuns(Object? raw) {
  if (raw == null) return const <TaskCenterWorkRun>[];
  if (raw is! List) {
    throw const FormatException('work_runs must be a list.');
  }
  return raw.map(TaskCenterWorkRun.fromJson).toList(growable: false);
}

List<TaskCenterEvent> _events(Object? raw) {
  if (raw == null) return const <TaskCenterEvent>[];
  if (raw is! List) throw const FormatException('events must be a list.');
  return raw
      .map((item) => TaskCenterEvent.fromJson(item))
      .toList(growable: false);
}
