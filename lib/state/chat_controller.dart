import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_permission_request.dart';
import '../acp/acp_permission_reviewer.dart';
import '../acp/acp_session_catalog.dart';
import '../acp/acp_session_settings.dart';
import '../acp/acp_session_usage.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import '../acp/prompt_attachment.dart';
import '../memory/acp_memory_middleware.dart';
import 'connection_state.dart';

enum ChatMessageRole { user, assistant, tool, error, status }

const List<String> _toolCallIdMetadataKeys = [
  'toolCallId',
  'tool_call_id',
  'id',
  'callId',
  'call_id',
];

class ChatMessage {
  ChatMessage({
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.metadata = const <String, Object?>{},
  }) : timestamp = timestamp ?? DateTime.now();

  final ChatMessageRole role;
  String text;
  final DateTime timestamp;
  final Map<String, Object?> metadata;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required this.client,
    required this.cwd,
    this.additionalDirectories = const <String>[],
    this.agentName = 'Codex',
    this.permissionHistoryLimit = defaultPermissionHistoryLimit,
    List<AcpPermissionTrustRule> permissionTrustRules =
        const <AcpPermissionTrustRule>[],
    this.memoryMiddleware,
    this.permissionReviewer,
  }) : assert(permissionHistoryLimit > 0),
       permissionTrustRules = List.unmodifiable(permissionTrustRules) {
    _permissionSubscription = client.permissionRequests.listen(
      _handlePermissionRequest,
      onError: (Object error, StackTrace stackTrace) => _setActionError(error),
      onDone: _handlePermissionRequestsDone,
    );
  }

  static const int defaultPermissionHistoryLimit = 500;

  final AcpAgentClient client;
  final String cwd;
  final List<String> additionalDirectories;
  final String agentName;
  final int permissionHistoryLimit;
  final List<AcpPermissionTrustRule> permissionTrustRules;
  final AcpMemoryMiddleware? memoryMiddleware;
  final AcpPermissionReviewer? permissionReviewer;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? currentSession;
  final List<AgentSession> sessions = <AgentSession>[];
  final List<ChatMessage> messages = <ChatMessage>[];
  List<Map<String, Object?>> availableCommands = const <Map<String, Object?>>[];
  AcpAgentCapabilities? capabilities;
  AcpSessionSettings sessionSettings = const AcpSessionSettings();
  AcpSessionUsage? sessionUsage;
  AcpPermissionRequest? pendingPermissionRequest;
  AcpToolCallExecutionPolicy toolCallExecutionPolicy =
      AcpToolCallExecutionPolicy.autoReview;
  final List<AcpPermissionAuditEntry> _permissionHistory =
      <AcpPermissionAuditEntry>[];
  final Set<String> _resolvingPermissionRequestIds = <String>{};
  final Set<String> _reviewingPermissionRequestIds = <String>{};
  final Set<String> _retiredSessionIds = <String>{};
  String? lastError;
  bool isStreaming = false;
  bool sessionSettingsLoading = false;
  bool isSessionOperationRunning = false;
  bool _isDisposed = false;

  bool get supportsSessionClose => capabilities?.session.close == true;

  bool get supportsSessionFork => capabilities?.session.fork == true;

  bool get supportsSessionList => capabilities?.session.list == true;

  bool get supportsSessionResume {
    return capabilities?.loadSession == true ||
        capabilities?.session.resume == true;
  }

  bool get supportsAuthLogout => capabilities?.auth.logout == true;

  bool get hasPermissionReviewer => permissionReviewer != null;

  String? get currentModelValue => sessionSettings.modelOption?.currentValue;

  String? get currentReasoningEffortValue {
    return sessionSettings.reasoningEffortOption?.currentValue;
  }

  List<Map<String, Object?>> get authMethods {
    return capabilities?.authMethods
            .where((method) => _stringFromMap(method, 'id').isNotEmpty)
            .toList(growable: false) ??
        const <Map<String, Object?>>[];
  }

  bool get canAuthenticate {
    return authMethods.isNotEmpty && !isStreaming && !isSessionOperationRunning;
  }

  bool get canForkCurrentSession {
    return currentSession != null &&
        supportsSessionFork &&
        !isStreaming &&
        !isSessionOperationRunning;
  }

  bool get canCloseCurrentSession {
    return currentSession != null &&
        supportsSessionClose &&
        !isStreaming &&
        !isSessionOperationRunning;
  }

  bool get canListSessions {
    return !isStreaming &&
        !isSessionOperationRunning &&
        (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error ||
            supportsSessionList);
  }

  bool get canResumeSessions {
    return !isStreaming &&
        !isSessionOperationRunning &&
        (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error ||
            (supportsSessionList && supportsSessionResume));
  }

  bool get canLogout {
    return supportsAuthLogout && !isStreaming && !isSessionOperationRunning;
  }

  bool get canSendExtensionRequest {
    return capabilities != null && !isStreaming && !isSessionOperationRunning;
  }

  List<AcpPermissionAuditEntry> get permissionHistory {
    return List.unmodifiable(_permissionHistory);
  }

  StreamSubscription<AgentEvent>? _promptSubscription;
  late final StreamSubscription<AcpPermissionRequest> _permissionSubscription;
  DateTime? _lastPromptStartedAt;
  String? _pendingMemoryUserPrompt;
  StringBuffer? _pendingMemoryAssistantAnswer;
  String? _pendingMemorySessionId;
  String? _pendingMemoryCwd;
  bool _pendingMemoryHadError = false;
  Duration? lastLatency;
  int _sessionSettingsLoadSerial = 0;
  int? _activeSessionSettingsLoadId;

  Future<void> connect() async {
    if (isSessionOperationRunning) return;
    await _runSessionOperation(() async {
      await _connectWithStatus(ConnectionStatus.connecting);
    });
  }

  Future<void> newSession({String? cwd}) async {
    if (isStreaming || isSessionOperationRunning) return;
    final workspaceCwd = cwd == null || cwd.trim().isEmpty
        ? this.cwd
        : cwd.trim();
    await _runSessionOperation(() async {
      try {
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }
        final session = (await client.createSession(
          cwd: workspaceCwd,
          additionalDirectories: additionalDirectories,
        )).copyWith(agentName: agentName);
        _retiredSessionIds.remove(session.id);
        currentSession = session;
        _upsertSession(session);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        for (final event in session.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        await _loadSessionSettings(session.id, notify: false);
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        _setError(error);
      }
    });
  }

  Future<void> resumeSession(
    String sessionId, {
    String? cwd,
    List<String>? additionalDirectories,
    String? title,
    DateTime? updatedAt,
  }) async {
    final trimmedSessionId = sessionId.trim();
    if (trimmedSessionId.isEmpty || isStreaming || isSessionOperationRunning) {
      return;
    }
    final workspaceCwd = cwd == null || cwd.trim().isEmpty
        ? this.cwd
        : cwd.trim();
    final workspaceAdditionalDirectories =
        additionalDirectories == null || additionalDirectories.isEmpty
        ? this.additionalDirectories
        : additionalDirectories;

    await _runSessionOperation(() async {
      final previousSession = currentSession;
      final previousSessions = List<AgentSession>.from(sessions);
      final previousMessages = List<ChatMessage>.from(messages);
      final previousAvailableCommands = availableCommands;
      final previousLastLatency = lastLatency;
      final previousSessionSettings = sessionSettings;
      final previousSessionUsage = sessionUsage;
      final previousSessionSettingsLoading = sessionSettingsLoading;
      final previousSettingsLoadId = _activeSessionSettingsLoadId;
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }

        status = ConnectionStatus.reconnecting;
        isStreaming = false;
        lastError = null;
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        final session = AgentSession(
          id: trimmedSessionId,
          cwd: workspaceCwd,
          createdAt: DateTime.now(),
          additionalDirectories: workspaceAdditionalDirectories,
          title: title,
          updatedAt: updatedAt,
          agentName: agentName,
        );
        _retiredSessionIds.remove(session.id);
        currentSession = session;
        _upsertSession(session);
        _notifyListeners();

        final replay = await client.resumeSession(
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
          additionalDirectories: workspaceAdditionalDirectories,
        );
        for (final event in replay) {
          _handleAgentEvent(event, notify: false);
        }
        await _loadSessionSettings(trimmedSessionId, notify: false);
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        currentSession = previousSession;
        sessions
          ..clear()
          ..addAll(previousSessions);
        messages
          ..clear()
          ..addAll(previousMessages);
        availableCommands = previousAvailableCommands;
        lastLatency = previousLastLatency;
        sessionSettings = previousSessionSettings;
        sessionUsage = previousSessionUsage;
        sessionSettingsLoading = previousSessionSettingsLoading;
        _activeSessionSettingsLoadId = previousSettingsLoadId;
        _setError(error);
      }
    });
  }

  Future<List<AcpProjectSessions>> listSessions() async {
    if (isSessionOperationRunning) {
      throw StateError('Another session operation is already in progress.');
    }
    return _runSessionOperationWithResult(() async {
      if (status == ConnectionStatus.disconnected ||
          status == ConnectionStatus.error) {
        await _connectWithStatus(ConnectionStatus.connecting);
        if (status == ConnectionStatus.error) {
          throw StateError(lastError ?? 'ACP agent connection failed.');
        }
      }
      return client.listSessions();
    });
  }

  Future<List<AcpProjectSessions>> listResumableSessions() async {
    final projects = await listSessions();
    if (!supportsSessionResume) {
      throw StateError(
        'ACP agent does not support session/load or session/resume.',
      );
    }
    return projects;
  }

  Future<void> sendPrompt(
    String text, {
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) async {
    final prompt = text.trim();
    if ((prompt.isEmpty && attachments.isEmpty) ||
        isStreaming ||
        isSessionOperationRunning) {
      return;
    }

    if (currentSession == null) {
      await newSession();
      if (status == ConnectionStatus.error) return;
    }

    final session = currentSession;
    if (session == null) return;

    final prepared = await memoryMiddleware?.preparePrompt(
      prompt,
      sessionId: session.id,
      cwd: session.cwd,
    );
    final agentPrompt = prepared?.prompt ?? prompt;
    final memoryContext = prepared?.memoryContext;

    final contentBlocks = attachments
        .map((attachment) => attachment.toResourceLink())
        .toList();
    messages.add(
      ChatMessage(
        role: ChatMessageRole.user,
        text: prompt,
        metadata: contentBlocks.isEmpty
            ? const <String, Object?>{}
            : <String, Object?>{'contentBlocks': contentBlocks},
      ),
    );
    isStreaming = true;
    status = ConnectionStatus.streaming;
    lastError = null;
    _lastPromptStartedAt = DateTime.now();
    _pendingMemoryUserPrompt = prompt;
    _pendingMemoryAssistantAnswer = StringBuffer();
    _pendingMemorySessionId = session.id;
    _pendingMemoryCwd = session.cwd;
    _pendingMemoryHadError = false;
    _notifyListeners();

    try {
      await _promptSubscription?.cancel();
      _promptSubscription = client
          .sendPrompt(
            sessionId: session.id,
            prompt: agentPrompt,
            memoryContext: memoryContext,
            attachments: attachments,
          )
          .listen(
            (event) {
              _recordMemoryExtractionEvent(event);
              _handleAgentEvent(event);
            },
            onError: (Object error, StackTrace stackTrace) {
              _pendingMemoryHadError = true;
              _handleAgentEvent(
                AgentEvent(
                  type: AgentEventType.error,
                  text: _messageForError(error),
                ),
              );
              _finishStreaming();
            },
            onDone: _finishStreaming,
          );
    } catch (error) {
      _handleAgentEvent(
        AgentEvent(type: AgentEventType.error, text: _messageForError(error)),
      );
      _pendingMemoryHadError = true;
      _finishStreaming();
    }
  }

  Future<void> stop() async {
    if (!isStreaming) return;
    Object? cancelError;
    try {
      await _cancelPendingPermissionRequest();
      await client.cancel();
    } catch (error) {
      cancelError = error;
    } finally {
      await _promptSubscription?.cancel();
      _promptSubscription = null;
      _clearPendingMemoryExtraction();
      _finishStreaming();
    }
    if (cancelError != null) {
      _setActionError(cancelError);
    }
  }

  Future<void> reconnect() async {
    if (isSessionOperationRunning) return;
    await _runSessionOperation(() async {
      await _promptSubscription?.cancel();
      _promptSubscription = null;
      isStreaming = false;
      await _cancelPendingPermissionRequest(reportErrors: false);
      currentSession = null;
      sessions.clear();
      availableCommands = const <Map<String, Object?>>[];
      sessionSettings = const AcpSessionSettings();
      sessionSettingsLoading = false;
      await _connectWithStatus(ConnectionStatus.reconnecting);
    });
  }

  Future<void> refreshSessionSettings() async {
    final sessionId = currentSession?.id;
    if (isStreaming || isSessionOperationRunning) return;
    if (sessionId == null) return;
    await _loadSessionSettings(sessionId);
  }

  Future<void> setSessionMode(String modeId) async {
    final sessionId = currentSession?.id;
    final trimmedModeId = modeId.trim();
    if (sessionId == null ||
        trimmedModeId.isEmpty ||
        !sessionSettings.shouldUseLegacyModes ||
        isStreaming ||
        isSessionOperationRunning) {
      return;
    }

    try {
      final didSet = await client.setSessionMode(
        sessionId: sessionId,
        modeId: trimmedModeId,
      );
      if (!_isActiveSession(sessionId)) return;
      if (!didSet) {
        throw StateError('ACP agent rejected session mode "$trimmedModeId".');
      }
      sessionSettings = sessionSettings.withCurrentMode(trimmedModeId);
      lastError = null;
      _notifyListeners();
    } catch (error) {
      if (_isActiveSession(sessionId)) {
        _setActionError(error);
      }
    }
  }

  Future<void> setConfigOption(String configId, Object value) async {
    final sessionId = currentSession?.id;
    final trimmedConfigId = configId.trim();
    if (sessionId == null ||
        trimmedConfigId.isEmpty ||
        isStreaming ||
        isSessionOperationRunning) {
      return;
    }

    try {
      final options = await client.setConfigOption(
        sessionId: sessionId,
        configId: trimmedConfigId,
        value: value,
      );
      if (!_isActiveSession(sessionId)) return;
      final updatedOptions = options.isEmpty
          ? _configOptionsWithOverride(trimmedConfigId, value)
          : options;
      sessionSettings = sessionSettings.withPreferredConfigOptions(
        updatedOptions,
      );
      lastError = null;
      _notifyListeners();
    } catch (error) {
      if (_isActiveSession(sessionId)) {
        _setActionError(error);
      }
    }
  }

  Future<void> setSessionModel(String modelValue) async {
    final option = sessionSettings.modelOption;
    if (option == null) {
      _setActionError(StateError('No model option exposed by this session.'));
      return;
    }
    await setConfigOption(option.id, modelValue);
  }

  Future<void> setSessionReasoningEffort(String effortValue) async {
    final option = sessionSettings.reasoningEffortOption;
    if (option == null) {
      _setActionError(
        StateError('No reasoning effort option exposed by this session.'),
      );
      return;
    }
    await setConfigOption(option.id, effortValue);
  }

  void setToolCallExecutionPolicy(AcpToolCallExecutionPolicy policy) {
    if (toolCallExecutionPolicy == policy) return;
    toolCallExecutionPolicy = policy;
    final request = pendingPermissionRequest;
    if (request != null) {
      _resolvePendingPermissionForPolicy(request);
    }
    _notifyListeners();
  }

  Future<void> forkCurrentSession() async {
    final session = currentSession;
    if (session == null || !supportsSessionFork) return;
    if (isStreaming || isSessionOperationRunning) return;

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        final forked = await client.forkSession(
          sessionId: session.id,
          cwd: session.cwd,
          additionalDirectories: session.additionalDirectories,
        );
        final forkedTitle = forked.title?.trim().isNotEmpty == true
            ? forked.title
            : 'Fork of ${session.displayTitle}';
        final updatedSession = forked.copyWith(
          title: forkedTitle,
          agentName: agentName,
        );
        _retiredSessionIds.remove(updatedSession.id);
        currentSession = updatedSession;
        _upsertSession(updatedSession);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        for (final event in updatedSession.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        await _loadSessionSettings(updatedSession.id, notify: false);
        if (status != ConnectionStatus.error) {
          status = ConnectionStatus.sessionReady;
        }
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<void> closeCurrentSession() async {
    final session = currentSession;
    if (session == null || !supportsSessionClose) return;
    if (isStreaming || isSessionOperationRunning) return;

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        await client.closeSession(sessionId: session.id);
        _retiredSessionIds.add(session.id);
        currentSession = null;
        sessions.removeWhere((item) => item.id == session.id);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        await _cancelPendingPermissionRequest(reportErrors: false);
        status = ConnectionStatus.connected;
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<void> logout() async {
    if (!supportsAuthLogout) return;
    if (isStreaming || isSessionOperationRunning) return;

    await _runSessionOperation(() async {
      try {
        await _promptSubscription?.cancel();
        _promptSubscription = null;
        await client.logout();
        if (currentSession case final session?) {
          _retiredSessionIds.add(session.id);
        }
        _retiredSessionIds.addAll(sessions.map((session) => session.id));
        currentSession = null;
        sessions.clear();
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionUsage = null;
        sessionSettingsLoading = false;
        await _cancelPendingPermissionRequest(reportErrors: false);
        status = ConnectionStatus.connected;
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<void> authenticate(String methodId) async {
    final trimmedMethodId = methodId.trim();
    if (trimmedMethodId.isEmpty || !canAuthenticate) return;

    await _runSessionOperation(() async {
      try {
        await client.authenticate(methodId: trimmedMethodId);
        lastError = null;
        _notifyListeners();
      } catch (error) {
        _setActionError(error);
      }
    });
  }

  Future<Map<String, Object?>> sendExtensionRequest({
    required String method,
    required Map<String, Object?> params,
  }) async {
    final trimmedMethod = method.trim();
    if (trimmedMethod.isEmpty) {
      throw StateError('Extension method is required.');
    }
    if (!trimmedMethod.startsWith('_')) {
      throw StateError('Extension method must start with underscore (_).');
    }
    if (!canSendExtensionRequest) {
      throw StateError('Connect to an ACP agent before sending extensions.');
    }

    try {
      final result = await client.sendExtensionRequest(
        method: trimmedMethod,
        params: params,
      );
      lastError = null;
      _notifyListeners();
      return result;
    } catch (error) {
      _setActionError(error);
      rethrow;
    }
  }

  Future<void> resolvePermissionRequest(AcpPermissionDecision decision) async {
    final request = pendingPermissionRequest;
    if (request == null) return;
    await _resolvePermissionRequest(
      request,
      decision,
      source: AcpPermissionDecisionSource.manual,
    );
  }

  Future<void> _connectWithStatus(ConnectionStatus connectingStatus) async {
    status = connectingStatus;
    capabilities = null;
    lastError = null;
    _notifyListeners();
    try {
      await client.connect();
      _retiredSessionIds.clear();
      capabilities = client.capabilities;
      status = ConnectionStatus.connected;
      _notifyListeners();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> _runSessionOperation(Future<void> Function() action) async {
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      await action();
    } finally {
      isSessionOperationRunning = false;
      _notifyListeners();
    }
  }

  Future<T> _runSessionOperationWithResult<T>(
    Future<T> Function() action,
  ) async {
    isSessionOperationRunning = true;
    _notifyListeners();
    try {
      return await action();
    } finally {
      isSessionOperationRunning = false;
      _notifyListeners();
    }
  }

  void _handleAgentEvent(AgentEvent event, {bool notify = true}) {
    switch (event.type) {
      case AgentEventType.userMessage:
        messages.add(
          ChatMessage(
            role: ChatMessageRole.user,
            text: event.text,
            metadata: event.metadata,
          ),
        );
      case AgentEventType.agentTextDelta:
        _appendText(
          ChatMessageRole.assistant,
          event.text,
          metadata: event.metadata,
        );
      case AgentEventType.agentTextDone:
        _appendTurnStatus(event);
        _finishStreaming();
      case AgentEventType.toolCall:
        _appendToolCall(event);
      case AgentEventType.error:
        _pendingMemoryHadError = true;
        final message = _messageForAgentError(event);
        lastError = message;
        messages.add(ChatMessage(role: ChatMessageRole.error, text: message));
        status = ConnectionStatus.error;
        _finishStreaming();
      case AgentEventType.status:
        _appendStatus(event);
    }
    if (notify) {
      _notifyListeners();
    }
  }

  void _recordMemoryExtractionEvent(AgentEvent event) {
    if (event.type == AgentEventType.agentTextDelta ||
        event.type == AgentEventType.agentTextDone) {
      _pendingMemoryAssistantAnswer?.write(event.text);
    }
  }

  void _appendToolCall(AgentEvent event) {
    final toolCallId = _toolCallIdFromMetadata(event.metadata);
    if (toolCallId.isEmpty) {
      messages.add(
        ChatMessage(
          role: ChatMessageRole.tool,
          text: event.text,
          metadata: event.metadata,
        ),
      );
      return;
    }

    for (var index = messages.length - 1; index >= 0; index -= 1) {
      final message = messages[index];
      if (message.role == ChatMessageRole.user) break;
      if (message.role != ChatMessageRole.tool) continue;
      if (_toolCallIdFromMetadata(message.metadata) != toolCallId) {
        continue;
      }

      messages[index] = ChatMessage(
        role: ChatMessageRole.tool,
        text: event.text.trim().isEmpty ? message.text : event.text,
        timestamp: message.timestamp,
        metadata: _mergeMetadata(message.metadata, event.metadata),
      );
      return;
    }

    messages.add(
      ChatMessage(
        role: ChatMessageRole.tool,
        text: event.text,
        metadata: event.metadata,
      ),
    );
  }

  Map<String, Object?> _mergeMetadata(
    Map<String, Object?> existing,
    Map<String, Object?> update,
  ) {
    final merged = Map<String, Object?>.from(existing);
    for (final entry in update.entries) {
      if (entry.value == null) continue;
      merged[entry.key] = entry.value;
    }
    return Map.unmodifiable(merged);
  }

  void _handlePermissionRequest(AcpPermissionRequest request) {
    if (_hasDeliveredPermissionDecision(request.id)) return;

    if (!_isPermissionRequestForActiveSession(request)) {
      _recordPermissionRequest(request);
      _recordPermissionDecision(
        request.id,
        AcpPermissionDecision.cancel,
        source: AcpPermissionDecisionSource.system,
      );
      unawaited(
        _sendPermissionDecision(
          id: request.id,
          decision: AcpPermissionDecision.cancel,
          reportErrors: false,
        ),
      );
      _notifyListeners();
      return;
    }

    final previous = pendingPermissionRequest;
    if (previous != null && previous.id != request.id) {
      _recordPermissionDecision(
        previous.id,
        AcpPermissionDecision.cancel,
        source: AcpPermissionDecisionSource.system,
      );
      unawaited(
        _sendPermissionDecision(
          id: previous.id,
          decision: AcpPermissionDecision.cancel,
          reportErrors: false,
        ),
      );
    }
    pendingPermissionRequest = request;
    _recordPermissionRequest(request);
    _resolvePendingPermissionForPolicy(request);
    _notifyListeners();
  }

  bool _hasDeliveredPermissionDecision(String requestId) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.id == requestId,
    );
    if (index == -1) return false;

    final entry = _permissionHistory[index];
    if (entry.status == AcpPermissionAuditStatus.pending) return false;
    return switch (entry.decisionSource) {
      AcpPermissionDecisionSource.manual ||
      AcpPermissionDecisionSource.trustRule ||
      AcpPermissionDecisionSource.reviewAgent ||
      AcpPermissionDecisionSource.policy => true,
      AcpPermissionDecisionSource.system || null => false,
    };
  }

  bool _isPermissionRequestForActiveSession(AcpPermissionRequest request) {
    final requestSessionId = request.sessionId.trim();
    if (requestSessionId.isEmpty) return true;
    if (_retiredSessionIds.contains(requestSessionId)) return false;
    final session = currentSession;
    if (session == null) return true;
    return requestSessionId == session.id;
  }

  void _handlePermissionRequestsDone() {
    if (_isDisposed) return;
    final request = pendingPermissionRequest;
    if (request == null) return;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request.id,
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    _notifyListeners();
  }

  AcpPermissionDecision? _trustedDecisionFor(AcpPermissionRequest request) {
    for (final rule in permissionTrustRules) {
      if (rule.matches(request)) return rule.decision;
    }
    return null;
  }

  void _resolvePendingPermissionForPolicy(AcpPermissionRequest request) {
    switch (toolCallExecutionPolicy) {
      case AcpToolCallExecutionPolicy.defaultPermissions:
        return;
      case AcpToolCallExecutionPolicy.autoReview:
        final trustedDecision = _trustedDecisionFor(request);
        if (trustedDecision != null) {
          unawaited(
            _resolvePermissionRequest(
              request,
              trustedDecision,
              source: AcpPermissionDecisionSource.trustRule,
            ),
          );
          return;
        }
        _startPermissionReview(request);
        return;
      case AcpToolCallExecutionPolicy.fullAccess:
        unawaited(
          _resolvePermissionRequest(
            request,
            AcpPermissionDecision.allow,
            source: AcpPermissionDecisionSource.policy,
          ),
        );
        return;
    }
  }

  Future<void> _resolvePermissionRequest(
    AcpPermissionRequest request,
    AcpPermissionDecision decision, {
    required AcpPermissionDecisionSource source,
    AcpPermissionReviewResult? reviewResult,
  }) async {
    if (_isDisposed) return;
    if (_hasDeliveredPermissionDecision(request.id)) return;
    if (!_resolvingPermissionRequestIds.add(request.id)) return;
    try {
      final didSend = await _sendPermissionDecision(
        id: request.id,
        decision: decision,
      );
      if (_isDisposed || !didSend) return;
      if (pendingPermissionRequest?.id == request.id) {
        pendingPermissionRequest = null;
      }
      _recordPermissionDecision(
        request.id,
        decision,
        source: source,
        reviewResult: reviewResult,
      );
      _notifyListeners();
    } finally {
      _resolvingPermissionRequestIds.remove(request.id);
    }
  }

  void _startPermissionReview(AcpPermissionRequest request) {
    if (_isDisposed) return;
    final reviewer = permissionReviewer;
    if (reviewer == null) return;
    if (!_reviewingPermissionRequestIds.add(request.id)) return;
    unawaited(() async {
      try {
        final reviewSession = currentSession;
        final reviewWorkspaceRoot = reviewSession?.cwd.trim().isNotEmpty == true
            ? reviewSession!.cwd
            : cwd;
        final reviewAdditionalDirectories =
            reviewSession?.additionalDirectories.isNotEmpty == true
            ? reviewSession!.additionalDirectories
            : additionalDirectories;
        final result = await reviewer.review(
          request,
          workspaceRoot: reviewWorkspaceRoot,
          additionalDirectories: reviewAdditionalDirectories,
          model: currentModelValue,
        );
        if (_isDisposed) return;
        if (result == null) return;
        _recordPermissionReview(request.id, result);
        final decision = result.decision;
        if (decision == null) {
          _notifyListeners();
          return;
        }
        if (pendingPermissionRequest?.id != request.id) return;
        if (_hasDeliveredPermissionDecision(request.id)) return;
        await _resolvePermissionRequest(
          request,
          decision,
          source: AcpPermissionDecisionSource.reviewAgent,
          reviewResult: result,
        );
      } catch (error) {
        if (!_isDisposed && pendingPermissionRequest?.id == request.id) {
          _setActionError(error);
        }
      } finally {
        _reviewingPermissionRequestIds.remove(request.id);
      }
    }());
  }

  Future<bool> _sendPermissionDecision({
    required String id,
    required AcpPermissionDecision decision,
    bool reportErrors = true,
  }) async {
    try {
      await client.respondToPermissionRequest(id: id, decision: decision);
      return true;
    } catch (error) {
      if (reportErrors) {
        _setActionError(error);
      }
      return false;
    }
  }

  Future<void> _cancelPendingPermissionRequest({
    bool reportErrors = true,
  }) async {
    final request = pendingPermissionRequest;
    if (request == null) return;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request.id,
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    await _sendPermissionDecision(
      id: request.id,
      decision: AcpPermissionDecision.cancel,
      reportErrors: reportErrors,
    );
  }

  void _cancelPendingPermissionRequestAfterPromptEnd() {
    final request = pendingPermissionRequest;
    if (request == null) return;
    pendingPermissionRequest = null;
    _recordPermissionDecision(
      request.id,
      AcpPermissionDecision.cancel,
      source: AcpPermissionDecisionSource.system,
    );
    unawaited(
      _sendPermissionDecision(
        id: request.id,
        decision: AcpPermissionDecision.cancel,
        reportErrors: false,
      ),
    );
  }

  void _recordPermissionRequest(AcpPermissionRequest request) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.id == request.id,
    );
    final entry = AcpPermissionAuditEntry(
      request: request,
      status: AcpPermissionAuditStatus.pending,
      recordedAt: request.requestedAt,
    );
    if (index == -1) {
      _permissionHistory.insert(0, entry);
      _trimPermissionHistory();
    } else {
      _permissionHistory[index] = entry;
    }
  }

  void _trimPermissionHistory() {
    if (_permissionHistory.length <= permissionHistoryLimit) return;
    _permissionHistory.removeRange(
      permissionHistoryLimit,
      _permissionHistory.length,
    );
  }

  void _recordPermissionDecision(
    String requestId,
    AcpPermissionDecision decision, {
    AcpPermissionDecisionSource source = AcpPermissionDecisionSource.manual,
    AcpPermissionReviewResult? reviewResult,
  }) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.id == requestId,
    );
    if (index == -1) return;
    _permissionHistory[index] = _permissionHistory[index].copyWith(
      status: _permissionAuditStatus(decision),
      resolvedAt: DateTime.now(),
      decisionSource: source,
      reviewResult: reviewResult,
    );
  }

  void _recordPermissionReview(
    String requestId,
    AcpPermissionReviewResult reviewResult,
  ) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.id == requestId,
    );
    if (index == -1) return;
    _permissionHistory[index] = _permissionHistory[index].copyWith(
      reviewResult: reviewResult,
    );
  }

  AcpPermissionAuditStatus _permissionAuditStatus(
    AcpPermissionDecision decision,
  ) {
    return switch (decision) {
      AcpPermissionDecision.allow => AcpPermissionAuditStatus.allowed,
      AcpPermissionDecision.deny => AcpPermissionAuditStatus.denied,
      AcpPermissionDecision.cancel => AcpPermissionAuditStatus.cancelled,
    };
  }

  void _appendText(
    ChatMessageRole role,
    String text, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    if (metadata.isEmpty && lastMessage != null && lastMessage.role == role) {
      lastMessage.text += text;
    } else {
      messages.add(ChatMessage(role: role, text: text, metadata: metadata));
    }
  }

  void _appendStatus(AgentEvent event) {
    final kind = event.metadata['kind'];
    if (kind == 'mode') {
      final mode = event.metadata['mode'];
      if (mode is String && mode.isNotEmpty) {
        sessionSettings = sessionSettings.withCurrentMode(mode);
      }
    }
    if (kind == 'config_option_update') {
      final options = event.metadata['configOptions'];
      if (options is List<AcpConfigOption>) {
        sessionSettings = sessionSettings.withPreferredConfigOptions(options);
      }
      return;
    }
    if (kind == 'session_info_update') {
      _applySessionInfoUpdate(event.metadata);
      return;
    }
    if (kind == 'usage_update') {
      _applyUsageUpdate(event.metadata);
      return;
    }
    if (kind == 'terminal') {
      _upsertTerminalStatusMessage(event);
      return;
    }
    if (kind == 'plan' || kind == 'commands') {
      if (kind == 'commands') {
        availableCommands = _commandsFromMetadata(event.metadata['commands']);
      }
      _replaceStatusMessage(event);
      return;
    }
    final lastMessage = messages.isNotEmpty ? messages.last : null;
    if (kind == 'thought' &&
        lastMessage != null &&
        lastMessage.role == ChatMessageRole.status &&
        lastMessage.metadata['kind'] == 'thought') {
      lastMessage.text += event.text;
      return;
    }
    messages.add(
      ChatMessage(
        role: ChatMessageRole.status,
        text: event.text,
        metadata: event.metadata,
      ),
    );
  }

  void _upsertTerminalStatusMessage(AgentEvent event) {
    final terminalId = event.metadata['terminalId'];
    if (terminalId is! String || terminalId.trim().isEmpty) {
      messages.add(
        ChatMessage(
          role: ChatMessageRole.status,
          text: event.text,
          metadata: event.metadata,
        ),
      );
      return;
    }

    final index = messages.indexWhere((item) {
      return item.role == ChatMessageRole.status &&
          item.metadata['kind'] == 'terminal' &&
          item.metadata['terminalId'] == terminalId;
    });
    if (index == -1) {
      messages.add(
        ChatMessage(
          role: ChatMessageRole.status,
          text: event.text,
          metadata: event.metadata,
        ),
      );
      return;
    }

    final previous = messages[index];
    final metadata = <String, Object?>{...previous.metadata, ...event.metadata};
    if (event.metadata['status'] == 'released' &&
        (previous.metadata['status'] == 'completed' ||
            previous.metadata['status'] == 'failed')) {
      metadata['status'] = previous.metadata['status'];
    }
    messages[index] = ChatMessage(
      role: ChatMessageRole.status,
      text: _terminalStatusText(event.text, previous.text),
      metadata: metadata,
    );
  }

  String _terminalStatusText(String incoming, String fallback) {
    final text = incoming.trim();
    if (text.isEmpty ||
        text == 'Terminal output.' ||
        text == 'Terminal exited.' ||
        text == 'Terminal released.') {
      return fallback;
    }
    return text;
  }

  void _replaceStatusMessage(AgentEvent event) {
    final kind = event.metadata['kind'];
    final message = ChatMessage(
      role: ChatMessageRole.status,
      text: event.text,
      metadata: event.metadata,
    );
    final index = messages.indexWhere((item) {
      return item.role == ChatMessageRole.status &&
          item.metadata['kind'] == kind;
    });
    if (index == -1) {
      messages.add(message);
    } else {
      messages[index] = message;
    }
  }

  List<Map<String, Object?>> _commandsFromMetadata(Object? raw) {
    if (raw is! List) return const <Map<String, Object?>>[];
    return raw
        .whereType<Map>()
        .map(
          (item) => item.map((key, value) => MapEntry(key.toString(), value)),
        )
        .toList(growable: false);
  }

  String _stringFromMap(Map<String, Object?> map, String key) {
    final value = map[key];
    return value is String ? value.trim() : '';
  }

  String _toolCallIdFromMetadata(Map<String, Object?> metadata) {
    for (final key in _toolCallIdMetadataKeys) {
      final value = _stringFromMap(metadata, key);
      if (value.isNotEmpty) return value;
    }
    final nested = metadata['toolCall'];
    if (nested is Map) {
      final nestedMetadata = nested.map(
        (key, value) => MapEntry(key.toString(), value),
      );
      for (final key in _toolCallIdMetadataKeys) {
        final value = _stringFromMap(nestedMetadata, key);
        if (value.isNotEmpty) return value;
      }
    }
    return '';
  }

  void _applyUsageUpdate(Map<String, Object?> metadata) {
    final used = _intFromObject(metadata['used']);
    final size = _intFromObject(metadata['size']);
    if (used == null || size == null || used < 0 || size <= 0) return;
    sessionUsage = AcpSessionUsage(
      used: used,
      size: size,
      cost: _usageCostFromObject(metadata['cost']),
    );
  }

  AcpSessionUsageCost? _usageCostFromObject(Object? raw) {
    if (raw is! Map) return null;
    final mapped = raw.map((key, value) => MapEntry(key.toString(), value));
    final amount = _numFromObject(mapped['amount']);
    final currency = mapped['currency']?.toString().trim() ?? '';
    if (amount == null || currency.isEmpty) return null;
    return AcpSessionUsageCost(amount: amount, currency: currency);
  }

  int? _intFromObject(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim());
    return null;
  }

  num? _numFromObject(Object? raw) {
    if (raw is num) return raw;
    if (raw is String) return num.tryParse(raw.trim());
    return null;
  }

  void _applySessionInfoUpdate(Map<String, Object?> metadata) {
    final session = currentSession;
    if (session == null) return;
    final sessionId = metadata['sessionId'];
    if (sessionId is String &&
        sessionId.isNotEmpty &&
        sessionId != session.id) {
      return;
    }

    final rawTitle = metadata['title'];
    final title = rawTitle is String && rawTitle.trim().isNotEmpty
        ? rawTitle.trim()
        : null;
    final updatedAtRaw = metadata['updatedAt'];
    final updatedAt = updatedAtRaw is String
        ? DateTime.tryParse(updatedAtRaw)?.toLocal()
        : null;
    final updatedSession = session.copyWith(title: title, updatedAt: updatedAt);
    currentSession = updatedSession;
    _upsertSession(updatedSession);
  }

  void _upsertSession(AgentSession session) {
    final index = sessions.indexWhere((item) => item.id == session.id);
    if (index != -1) {
      sessions[index] = session;
      return;
    }
    sessions.insert(0, session);
  }

  List<AcpConfigOption> _configOptionsWithOverride(
    String configId,
    Object value,
  ) {
    var didUpdate = false;
    final options = sessionSettings.configOptions.map((option) {
      if (option.id != configId) return option;
      didUpdate = true;
      return option.copyWith(currentValue: value);
    }).toList();
    return didUpdate ? options : sessionSettings.configOptions;
  }

  void _appendTurnStatus(AgentEvent event) {
    final stopReason = event.metadata['stopReason'];
    if (stopReason is! String || stopReason.isEmpty) return;
    messages.add(
      ChatMessage(
        role: ChatMessageRole.status,
        text: _stopReasonLabel(stopReason),
        metadata: <String, Object?>{'kind': 'turn', 'stopReason': stopReason},
      ),
    );
  }

  String _stopReasonLabel(String stopReason) {
    return switch (stopReason) {
      'endTurn' => 'Turn ended normally.',
      'maxTokens' => 'Turn stopped after reaching the token limit.',
      'maxTurnRequests' => 'Turn stopped after too many model requests.',
      'cancelled' => 'Turn cancelled.',
      'refusal' => 'Agent refused to continue.',
      _ => 'Turn ended: $stopReason',
    };
  }

  void _finishStreaming() {
    if (!isStreaming) return;
    isStreaming = false;
    _cancelPendingPermissionRequestAfterPromptEnd();
    if (status != ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    final startedAt = _lastPromptStartedAt;
    if (startedAt != null) {
      lastLatency = DateTime.now().difference(startedAt);
    }
    final extractionContext = _takePendingMemoryExtraction();
    if (extractionContext != null) {
      unawaited(memoryMiddleware?.extractTurn(extractionContext));
    }
    _notifyListeners();
  }

  MemoryTurnContext? _takePendingMemoryExtraction() {
    final userPrompt = _pendingMemoryUserPrompt;
    final assistantAnswer = _pendingMemoryAssistantAnswer?.toString();
    final sessionId = _pendingMemorySessionId;
    final cwd = _pendingMemoryCwd;
    final hadError = _pendingMemoryHadError;
    _clearPendingMemoryExtraction();
    if (hadError ||
        userPrompt == null ||
        assistantAnswer == null ||
        assistantAnswer.trim().isEmpty) {
      return null;
    }
    return MemoryTurnContext(
      userPrompt: userPrompt,
      assistantAnswer: assistantAnswer,
      sessionId: sessionId,
      cwd: cwd,
    );
  }

  void _clearPendingMemoryExtraction() {
    _pendingMemoryUserPrompt = null;
    _pendingMemoryAssistantAnswer = null;
    _pendingMemorySessionId = null;
    _pendingMemoryCwd = null;
    _pendingMemoryHadError = false;
  }

  void _setError(Object error) {
    lastError = _messageForError(error);
    status = ConnectionStatus.error;
    isStreaming = false;
    _notifyListeners();
  }

  void _setActionError(Object error) {
    lastError = _messageForError(error);
    if (status == ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    _notifyListeners();
  }

  String _messageForAgentError(AgentEvent event) {
    if (_containsAuthRequired(event.text) ||
        _containsAuthRequired(event.metadata)) {
      return _authRequiredMessage();
    }
    return event.text;
  }

  String _messageForError(Object error) {
    if (_containsAuthRequired(error.toString()) ||
        _containsAuthRequired(_dynamicField(error, 'message')) ||
        _containsAuthRequired(_dynamicField(error, 'code')) ||
        _containsAuthRequired(_dynamicField(error, 'data'))) {
      return _authRequiredMessage();
    }
    return error.toString();
  }

  String _authRequiredMessage() {
    if (authMethods.isNotEmpty) {
      return 'Authentication required. Open the Agents menu and choose Authenticate, then try again.';
    }
    return 'Authentication required, but this agent did not advertise an authentication method.';
  }

  bool _containsAuthRequired(Object? value) {
    if (value == null) return false;
    if (value is String) return value.toLowerCase().contains('auth_required');
    if (value is Map) {
      return value.entries.any((entry) {
        return _containsAuthRequired(entry.key.toString()) ||
            _containsAuthRequired(entry.value);
      });
    }
    if (value is Iterable) return value.any(_containsAuthRequired);
    return false;
  }

  Object? _dynamicField(Object object, String fieldName) {
    try {
      final dynamic value = object;
      return switch (fieldName) {
        'code' => value.code,
        'data' => value.data,
        'message' => value.message,
        _ => null,
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> _loadSessionSettings(
    String sessionId, {
    bool notify = true,
  }) async {
    final loadId = ++_sessionSettingsLoadSerial;
    _activeSessionSettingsLoadId = loadId;
    sessionSettingsLoading = true;
    if (notify) _notifyListeners();

    try {
      final settings = await client.sessionSettings(sessionId);
      if (_isCurrentSessionSettingsLoad(loadId, sessionId)) {
        sessionSettings = settings.withConfigOptionsPreference;
      }
    } catch (_) {
      if (_isCurrentSessionSettingsLoad(loadId, sessionId)) {
        sessionSettings = const AcpSessionSettings();
      }
    } finally {
      if (_activeSessionSettingsLoadId == loadId) {
        _activeSessionSettingsLoadId = null;
        sessionSettingsLoading = false;
        if (notify) _notifyListeners();
      }
    }
  }

  bool _isCurrentSessionSettingsLoad(int loadId, String sessionId) {
    return !_isDisposed &&
        _activeSessionSettingsLoadId == loadId &&
        _isActiveSession(sessionId);
  }

  bool _isActiveSession(String sessionId) {
    return !_isDisposed && currentSession?.id == sessionId;
  }

  @override
  void dispose() {
    _isDisposed = true;
    _disposeLater(() => _promptSubscription?.cancel());
    _disposeLater(_permissionSubscription.cancel);
    _disposeLater(client.dispose);
    _disposeLater(() => permissionReviewer?.dispose());
    memoryMiddleware?.dispose();
    _resolvingPermissionRequestIds.clear();
    _reviewingPermissionRequestIds.clear();
    super.dispose();
  }

  void _disposeLater(Future<void>? Function() action) {
    try {
      final cleanup = action();
      if (cleanup == null) return;
      unawaited(cleanup.catchError((_) {}));
    } on Object {
      // Dispose must stay best-effort; teardown errors have no live UI target.
    }
  }

  void _notifyListeners() {
    if (_isDisposed) return;
    notifyListeners();
  }
}
