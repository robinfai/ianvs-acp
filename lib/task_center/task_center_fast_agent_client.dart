import 'dart:async';
import 'dart:convert';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_permission_request.dart';
import '../acp/acp_session_catalog.dart';
import '../acp/acp_session_settings.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import '../acp/prompt_attachment.dart';
import 'task_center_agent_api.dart';

class TaskCenterFastAgentClient implements AcpAgentClient {
  TaskCenterFastAgentClient({
    required this.api,
    required this.agentName,
    required this.workspaceCwd,
  });

  final TaskCenterAgentApi api;
  final String agentName;
  final String workspaceCwd;

  final StreamController<AcpPermissionRequest> _permissionRequests =
      StreamController<AcpPermissionRequest>.broadcast();
  final Map<String, _FastSession> _sessions = <String, _FastSession>{};
  var _connected = false;
  var _cancelled = false;
  var _sessionSequence = 0;
  var _toolSequence = 0;

  @override
  AcpAgentCapabilities? get capabilities => _connected
      ? const AcpAgentCapabilities(
          protocolVersion: 1,
          loadSession: true,
          prompt: AcpPromptCapabilities(
            image: false,
            audio: false,
            embeddedContext: false,
          ),
          mcp: AcpMcpCapabilities(http: false, sse: false, acp: false),
          session: AcpSessionCapabilities(
            list: true,
            resume: true,
            fork: false,
            configOptions: false,
            additionalDirectories: false,
            close: true,
            rawKeys: <String>['close', 'list', 'resume'],
          ),
          auth: AcpAuthCapabilities(logout: false),
          client: AcpClientCapabilities(
            fsReadTextFile: false,
            fsWriteTextFile: false,
            terminal: false,
            hasFsProvider: false,
            hasTerminalProvider: false,
            allowReadOutsideWorkspace: false,
          ),
          rawAgentCapabilities: <String, Object?>{
            'agent': 'task_center_fast_agent',
          },
          authMethods: <Map<String, Object?>>[],
          agentInfo: <String, Object?>{
            'name': 'Task Center Fast Agent',
            'kind': 'local_minimal',
          },
        )
      : null;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      _permissionRequests.stream;

  @override
  Future<void> connect() async {
    _connected = true;
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureConnected();
    _sessionSequence += 1;
    final now = DateTime.now().toUtc();
    final session = AgentSession(
      id: 'fast-${now.microsecondsSinceEpoch}-$_sessionSequence',
      cwd: cwd.trim().isEmpty ? workspaceCwd : cwd.trim(),
      createdAt: now,
      title: 'Task Center Fast Agent',
      updatedAt: now,
      agentName: agentName,
    );
    _sessions[session.id] = _FastSession(session: session);
    return session;
  }

  @override
  Future<List<AgentEvent>> resumeSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureConnected();
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown fast agent session "$sessionId".');
    }
    return List<AgentEvent>.unmodifiable(session.events);
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() async {
    _ensureConnected();
    return groupAcpSessionsByProject(
      _sessions.values.map((entry) {
        final session = entry.session;
        return AcpSessionEntry(
          id: session.id,
          cwd: session.cwd,
          title: session.title ?? 'Task Center Fast Agent',
          updatedAt: session.updatedAt ?? session.createdAt,
          meta: const <String, Object?>{'agent': 'task_center_fast_agent'},
        );
      }),
    );
  }

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) async {
    _ensureConnected();
    return const AcpSessionSettings();
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) async {
    _ensureConnected();
    return false;
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) async {
    _ensureConnected();
    return const <AcpConfigOption>[];
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    throw StateError('Task Center fast agent does not support fork.');
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    _ensureConnected();
    _sessions.remove(sessionId);
  }

  @override
  Future<void> authenticate({required String methodId}) async {
    throw StateError('Task Center fast agent does not support auth.');
  }

  @override
  Future<void> logout() async {
    throw StateError('Task Center fast agent does not support logout.');
  }

  @override
  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) async {
    throw StateError('Task Center fast agent does not support extensions.');
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async* {
    _ensureConnected();
    _cancelled = false;
    final session = _sessions[sessionId];
    if (session == null) {
      throw StateError('Unknown fast agent session "$sessionId".');
    }
    final context = _FastPromptContext.parse(prompt);
    final workspaceId = context.workspaceId;
    final humanMessage = context.humanMessage;
    if (workspaceId.isEmpty || humanMessage.isEmpty) {
      yield* _recordAndYield(
        session,
        const AgentEvent(
          type: AgentEventType.agentTextDelta,
          text: '需要工作区和消息内容才能处理。',
        ),
      );
      yield* _recordAndYield(
        session,
        const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
      );
      return;
    }

    final tasksCall = await _callTool(
      session,
      'task_center_list_tasks',
      <String, Object?>{'workspace_id': workspaceId},
    );
    yield* _yieldEvents(tasksCall.events);
    if (_cancelled) return;

    final pendingQuestion = _firstPendingQuestion(tasksCall.result);
    if (pendingQuestion != null && _looksLikeHumanAnswer(humanMessage)) {
      final answerCall = await _callTool(
        session,
        'task_center_answer_human_question',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': pendingQuestion.taskId,
          'question_id': pendingQuestion.questionId,
          'answer': humanMessage,
          'actor': 'human',
        },
      );
      yield* _yieldEvents(answerCall.events);
      final admissionCall = await _callTool(
        session,
        'task_center_record_admission_decision',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': pendingQuestion.taskId,
          'decision': 'needs_human',
          'agent_name': agentName,
          'reason': '已记录人工补充，等待 fast agent 再次判断是否准入。',
          'content': '已记录人工补充，继续判断是否可以准入。',
        },
      );
      yield* _yieldEvents(admissionCall.events);
      yield* _streamText(session, '已记录你的补充，我会继续根据任务信息判断准入。');
      return;
    }

    final completedHumanTask = _completedHumanConfirmationTask(
      tasksCall.result,
      humanMessage,
    );
    if (completedHumanTask != null) {
      final worker = context.workAgentNames.isEmpty
          ? ''
          : context.workAgentNames.first;
      final taskId = _stringFromMap(completedHumanTask, 'id');
      if (worker.isEmpty) {
        final admissionCall = await _callTool(
          session,
          'task_center_record_admission_decision',
          <String, Object?>{
            'workspace_id': workspaceId,
            'task_id': taskId,
            'decision': 'needs_human',
            'agent_name': agentName,
            'reason': 'Human confirmation 已完成，但 workspace 没有配置 worker。',
            'content': '确认已收到，但需要先配置 worker agent。',
          },
        );
        yield* _yieldEvents(admissionCall.events);
        yield* _streamText(session, '确认已收到，但需要先配置 worker agent。');
        return;
      }

      final transferCall = await _callTool(
        session,
        'task_center_transfer_owner',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': taskId,
          'owner': <String, Object?>{
            'kind': 'work_agent',
            'agent_name': worker,
          },
          'readiness': 'ready',
          'route_reason': 'Human confirmation 已全部完成，可以交给 worker。',
          'actor': agentName,
        },
      );
      yield* _yieldEvents(transferCall.events);
      final startRunCall = await _callTool(
        session,
        'task_center_start_work_run',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': taskId,
          'agent_name': worker,
          'progress_summary': 'Human confirmation 完成，fast agent 交给 worker 执行。',
          'actor': agentName,
        },
      );
      yield* _yieldEvents(startRunCall.events);
      final admissionCall = await _callTool(
        session,
        'task_center_record_admission_decision',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': taskId,
          'decision': 'accepted',
          'agent_name': agentName,
          'reason': '人工确认已闭环，目标和执行边界足够清晰。',
          'content': '人工确认已完成，已交给 $worker 执行。',
        },
      );
      yield* _yieldEvents(admissionCall.events);
      yield* _streamText(session, '人工确认已完成，已交给 $worker 执行。');
      return;
    }

    final stalledCall = await _callTool(
      session,
      'task_center_list_stalled_work',
      <String, Object?>{'workspace_id': workspaceId},
    );
    yield* _yieldEvents(stalledCall.events);
    if (_cancelled) return;

    if (!_hasTaskSignal(humanMessage)) {
      final taskCreation = await _createClarificationTask(
        session: session,
        workspaceId: workspaceId,
        humanMessage: humanMessage,
      );
      yield* _yieldEvents(taskCreation.events);
      final admissionCall = await _callTool(
        session,
        'task_center_record_admission_decision',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': _stringFromMap(taskCreation.task, 'id'),
          'decision': 'needs_human',
          'agent_name': agentName,
          'reason': '输入还不足以形成可执行任务。',
          'content': '需要补充目标和验收条件后再准入。',
        },
      );
      yield* _yieldEvents(admissionCall.events);
      yield* _streamText(session, '我先把它放到人工确认里：请补充目标、范围和验收标准。');
      return;
    }

    if (_needsThinking(humanMessage)) {
      final taskCreation = await _createTask(
        session: session,
        workspaceId: workspaceId,
        humanMessage: humanMessage,
        readiness: 'needs_thinking',
        owner: <String, Object?>{
          'kind': 'thinking_agent',
          'agent_name': context.thinkingAgentName,
        },
        status: 'in_progress',
      );
      yield* _yieldEvents(taskCreation.events);
      final thinkingCall = await _callTool(
        session,
        'task_center_request_thinking_alignment',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': _stringFromMap(taskCreation.task, 'id'),
          'fast_agent_name': agentName,
          'thinking_agent_name': context.thinkingAgentName,
          'question': '请先梳理问题、风险和需要人工判断的清单。',
          'route_reason': '输入需要进一步分析后再分派执行。',
        },
      );
      yield* _yieldEvents(thinkingCall.events);
      yield* _streamText(session, '已准入，并先交给 thinking agent 梳理问题。');
      return;
    }

    final worker = context.workAgentNames.isEmpty
        ? ''
        : context.workAgentNames.first;
    if (worker.isEmpty) {
      final taskCreation = await _createClarificationTask(
        session: session,
        workspaceId: workspaceId,
        humanMessage: humanMessage,
        question: '这个 workspace 还没有配置 worker，请先配置主工作 agent。',
      );
      yield* _yieldEvents(taskCreation.events);
      final admissionCall = await _callTool(
        session,
        'task_center_record_admission_decision',
        <String, Object?>{
          'workspace_id': workspaceId,
          'task_id': _stringFromMap(taskCreation.task, 'id'),
          'decision': 'needs_human',
          'agent_name': agentName,
          'reason': '缺少可接手的 worker。',
          'content': '需要先配置 worker agent。',
        },
      );
      yield* _yieldEvents(admissionCall.events);
      yield* _streamText(session, '需要先配置 worker agent，我已经放到人工确认里。');
      return;
    }

    final taskCreation = await _createTask(
      session: session,
      workspaceId: workspaceId,
      humanMessage: humanMessage,
      readiness: 'ready',
      owner: <String, Object?>{'kind': 'work_agent', 'agent_name': worker},
      status: 'todo',
    );
    yield* _yieldEvents(taskCreation.events);
    final startRunCall = await _callTool(
      session,
      'task_center_start_work_run',
      <String, Object?>{
        'workspace_id': workspaceId,
        'task_id': _stringFromMap(taskCreation.task, 'id'),
        'agent_name': worker,
        'progress_summary': 'Fast agent 完成准入，交给 worker 执行。',
        'actor': agentName,
      },
    );
    yield* _yieldEvents(startRunCall.events);
    final admissionCall = await _callTool(
      session,
      'task_center_record_admission_decision',
      <String, Object?>{
        'workspace_id': workspaceId,
        'task_id': _stringFromMap(taskCreation.task, 'id'),
        'decision': 'accepted',
        'agent_name': agentName,
        'reason': '目标和验收方向足够清晰，已转交 worker。',
        'content': '已准入并交给 $worker 执行。',
      },
    );
    yield* _yieldEvents(admissionCall.events);
    yield* _streamText(session, '已准入，并交给 $worker 执行。');
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
  }) async {}

  @override
  Future<void> dispose() async {
    _connected = false;
    await _permissionRequests.close();
  }

  Future<_CreatedTask> _createClarificationTask({
    required _FastSession session,
    required String workspaceId,
    required String humanMessage,
    String question = '请补充这个任务的目标、范围和验收标准。',
  }) async {
    final task = await _createTask(
      session: session,
      workspaceId: workspaceId,
      humanMessage: humanMessage,
      readiness: 'waiting_human',
      owner: const <String, Object?>{'kind': 'human'},
      status: 'todo',
      acceptanceCriteria: const <String>[],
    );
    final questionCall = await _callTool(
      session,
      'task_center_request_human_confirmation',
      <String, Object?>{
        'workspace_id': workspaceId,
        'task_id': _stringFromMap(task.task, 'id'),
        'questions': <String>[question],
        'route_reason': '准入前需要人工补充信息。',
        'actor': agentName,
      },
    );
    return _CreatedTask(
      task: task.task,
      events: <AgentEvent>[...task.events, ...questionCall.events],
    );
  }

  Future<_CreatedTask> _createTask({
    required _FastSession session,
    required String workspaceId,
    required String humanMessage,
    required String readiness,
    required Map<String, Object?> owner,
    required String status,
    List<String> acceptanceCriteria = const <String>[
      '按用户描述完成可验证结果。',
      '在任务中心交付执行结果和必要说明。',
    ],
  }) async {
    final result =
        await _callTool(session, 'task_center_create_task', <String, Object?>{
          'workspace_id': workspaceId,
          'title': _titleFromMessage(humanMessage),
          'description': humanMessage,
          'details': '来自 workspace 群聊：$humanMessage',
          'objective': humanMessage,
          'acceptance_criteria': acceptanceCriteria,
          'current_owner': owner,
          'readiness': readiness,
          'route_reason': 'Fast agent 准入判断。',
          'status': status,
        });
    return _CreatedTask(
      task: _objectFromMap(result.result, 'task'),
      events: result.events,
    );
  }

  Future<_ToolResult> _callTool(
    _FastSession session,
    String toolName,
    Map<String, Object?> arguments,
  ) async {
    _toolSequence += 1;
    final id = 'fast-tool-$_toolSequence';
    final started = AgentEvent(
      type: AgentEventType.toolCall,
      text: toolName,
      metadata: <String, Object?>{
        'toolCallId': id,
        'title': toolName,
        'status': 'running',
        'kind': 'tool',
        'rawInput': arguments,
      },
    );
    session.events.add(started);
    final result = await api.call(toolName, arguments);
    final completed = AgentEvent(
      type: AgentEventType.toolCall,
      text: toolName,
      metadata: <String, Object?>{
        'toolCallId': id,
        'title': toolName,
        'status': 'completed',
        'kind': 'tool',
        'rawInput': arguments,
        'rawOutput': result,
      },
    );
    session.events.add(completed);
    return _ToolResult(
      result: result,
      events: <AgentEvent>[started, completed],
    );
  }

  Stream<AgentEvent> _yieldEvents(List<AgentEvent> events) async* {
    for (final event in events) {
      yield event;
    }
  }

  Stream<AgentEvent> _streamText(_FastSession session, String text) async* {
    final chunks = _textChunks(text);
    for (final chunk in chunks) {
      if (_cancelled) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
      yield* _recordAndYield(
        session,
        AgentEvent(type: AgentEventType.agentTextDelta, text: chunk),
      );
    }
    yield* _recordAndYield(
      session,
      const AgentEvent(type: AgentEventType.agentTextDone, text: ''),
    );
  }

  Stream<AgentEvent> _recordAndYield(
    _FastSession session,
    AgentEvent event,
  ) async* {
    session.events.add(event);
    yield event;
  }

  void _ensureConnected() {
    if (!_connected) {
      throw StateError('Task Center fast agent is not connected.');
    }
  }
}

class _FastSession {
  _FastSession({required this.session});

  final AgentSession session;
  final List<AgentEvent> events = <AgentEvent>[];
}

class _ToolResult {
  const _ToolResult({required this.result, required this.events});

  final Map<String, Object?> result;
  final List<AgentEvent> events;
}

class _CreatedTask {
  const _CreatedTask({required this.task, required this.events});

  final Map<String, Object?> task;
  final List<AgentEvent> events;
}

class _FastPromptContext {
  const _FastPromptContext({
    required this.workspaceId,
    required this.humanMessage,
    required this.thinkingAgentName,
    required this.workAgentNames,
  });

  final String workspaceId;
  final String humanMessage;
  final String thinkingAgentName;
  final List<String> workAgentNames;

  static _FastPromptContext parse(String prompt) {
    return _FastPromptContext(
      workspaceId: _lineValue(prompt, 'workspace_id'),
      humanMessage: _humanMessage(prompt),
      thinkingAgentName: _lineValue(prompt, 'thinking_agent'),
      workAgentNames: _csvLine(prompt, 'work_agents'),
    );
  }
}

class _PendingQuestion {
  const _PendingQuestion({required this.taskId, required this.questionId});

  final String taskId;
  final String questionId;
}

_PendingQuestion? _firstPendingQuestion(Map<String, Object?> listTasksResult) {
  final tasks = listTasksResult['tasks'];
  if (tasks is! List) return null;
  for (final rawTask in tasks) {
    if (rawTask is! Map) continue;
    final task = rawTask.map((key, value) => MapEntry(key.toString(), value));
    if (_stringFromMap(task, 'readiness') != 'waiting_human') continue;
    final questions = task['human_questions'];
    if (questions is! List) continue;
    for (final rawQuestion in questions) {
      if (rawQuestion is! Map) continue;
      final question = rawQuestion.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      if (question['resolved'] == true) continue;
      final taskId = _stringFromMap(task, 'id');
      final questionId = _stringFromMap(question, 'id');
      if (taskId.isNotEmpty && questionId.isNotEmpty) {
        return _PendingQuestion(taskId: taskId, questionId: questionId);
      }
    }
  }
  return null;
}

Map<String, Object?>? _completedHumanConfirmationTask(
  Map<String, Object?> listTasksResult,
  String message,
) {
  final taskId = _taskIdFromHumanConfirmationMessage(message);
  if (taskId.isEmpty) return null;
  final tasks = listTasksResult['tasks'];
  if (tasks is! List) return null;
  for (final rawTask in tasks) {
    if (rawTask is! Map) continue;
    final task = rawTask.map((key, value) => MapEntry(key.toString(), value));
    if (_stringFromMap(task, 'id') != taskId) continue;
    final questions = task['human_questions'];
    if (questions is! List || questions.isEmpty) return null;
    final hasOpenQuestion = questions.any((rawQuestion) {
      if (rawQuestion is! Map) return true;
      final question = rawQuestion.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      return question['resolved'] != true;
    });
    return hasOpenQuestion ? null : task;
  }
  return null;
}

String _taskIdFromHumanConfirmationMessage(String message) {
  if (!message.trimLeft().startsWith('Human confirmation answered')) {
    return '';
  }
  final inlineMatch = RegExp(
    r'(?:Task ID|task_id):?\s+([^\s]+)',
    caseSensitive: false,
  ).firstMatch(message);
  if (inlineMatch != null) return inlineMatch.group(1)?.trim() ?? '';
  for (final line in message.split('\n')) {
    final clean = line.trim();
    final lower = clean.toLowerCase();
    if (lower.startsWith('task id:')) {
      return clean.substring(clean.indexOf(':') + 1).trim();
    }
    if (lower.startsWith('task_id:')) {
      return clean.substring(clean.indexOf(':') + 1).trim();
    }
  }
  return '';
}

bool _looksLikeHumanAnswer(String message) {
  final text = message.trim();
  if (text.isEmpty) return false;
  const answerStarts = <String>[
    '确认',
    '可以',
    '补充',
    '目标',
    '范围',
    '验收',
    'answer:',
    '答复',
  ];
  return answerStarts.any(text.startsWith);
}

bool _hasTaskSignal(String message) {
  final text = message.trim();
  if (text.length < 8) return false;
  const verbs = <String>[
    '实现',
    '修复',
    '排查',
    '查询',
    '统计',
    '整理',
    '设计',
    '创建',
    '更新',
    '验证',
    '分析',
    '检查',
    'run',
    'test',
    'fix',
    'build',
    'count',
    'deliver',
    'done',
    'verify',
    'check',
    'analyze',
    'analyse',
    'design',
    'plan',
    'strategy',
  ];
  final lower = text.toLowerCase();
  return verbs.any((verb) => lower.contains(verb.toLowerCase()));
}

bool _needsThinking(String message) {
  final text = message.toLowerCase();
  const thinkingSignals = <String>[
    '复杂',
    '深入',
    '深度',
    '方案',
    '设计',
    '架构',
    '权衡',
    '分析',
    '梳理',
    'product-design',
    'analyze',
    'analyse',
    'analysis',
    'design',
    'plan',
    'strategy',
    'architecture',
    'deep',
  ];
  return thinkingSignals.any((signal) => text.contains(signal));
}

String _titleFromMessage(String message) {
  final compact = message
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll('\n', ' ')
      .trim();
  if (compact.isEmpty) return 'Untitled task';
  return compact.length <= 36 ? compact : '${compact.substring(0, 36)}...';
}

List<String> _textChunks(String text) {
  final result = <String>[];
  for (var index = 0; index < text.length; index += 8) {
    final end = index + 8 > text.length ? text.length : index + 8;
    result.add(text.substring(index, end));
  }
  return result;
}

String _lineValue(String prompt, String key) {
  final pattern = RegExp('^${RegExp.escape(key)}:\\s*(.*)\$', multiLine: true);
  final match = pattern.firstMatch(prompt);
  return match?.group(1)?.trim() ?? '';
}

List<String> _csvLine(String prompt, String key) {
  final value = _lineValue(prompt, key);
  if (value.isEmpty) return const <String>[];
  return value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList(growable: false);
}

String _humanMessage(String prompt) {
  const marker = 'human_message:';
  final start = prompt.indexOf(marker);
  if (start == -1) return '';
  final contentStart = start + marker.length;
  final end = prompt.indexOf('\n\n处理要求:', contentStart);
  final raw = end == -1
      ? prompt.substring(contentStart)
      : prompt.substring(contentStart, end);
  return raw.trim();
}

Map<String, Object?> _objectFromMap(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) return const <String, Object?>{};
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String _stringFromMap(Map<String, Object?> map, String key) {
  final value = map[key];
  return value is String ? value.trim() : '';
}

String debugFastAgentEventDump(List<AgentEvent> events) {
  return const JsonEncoder.withIndent('  ').convert(
    events
        .map(
          (event) => <String, Object?>{
            'type': event.type.name,
            'text': event.text,
            'metadata': event.metadata,
          },
        )
        .toList(),
  );
}
