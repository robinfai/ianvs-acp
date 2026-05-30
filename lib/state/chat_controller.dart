import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_permission_request.dart';
import '../acp/acp_session_catalog.dart';
import '../acp/acp_session_settings.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
import '../acp/prompt_attachment.dart';
import 'connection_state.dart';

enum ChatMessageRole { user, assistant, tool, error, status }

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
    this.agentName = 'Codex',
    this.permissionHistoryLimit = defaultPermissionHistoryLimit,
    List<AcpPermissionTrustRule> permissionTrustRules =
        const <AcpPermissionTrustRule>[],
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
  final String agentName;
  final int permissionHistoryLimit;
  final List<AcpPermissionTrustRule> permissionTrustRules;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? currentSession;
  final List<AgentSession> sessions = <AgentSession>[];
  final List<ChatMessage> messages = <ChatMessage>[];
  List<Map<String, Object?>> availableCommands = const <Map<String, Object?>>[];
  AcpAgentCapabilities? capabilities;
  AcpSessionSettings sessionSettings = const AcpSessionSettings();
  AcpPermissionRequest? pendingPermissionRequest;
  final List<AcpPermissionAuditEntry> _permissionHistory =
      <AcpPermissionAuditEntry>[];
  String? lastError;
  bool isStreaming = false;
  bool sessionSettingsLoading = false;
  bool isSessionOperationRunning = false;
  bool _isDisposed = false;

  bool get supportsSessionClose => capabilities?.session.close == true;

  bool get supportsSessionFork => capabilities?.session.fork == true;

  bool get supportsAuthLogout => capabilities?.auth.logout == true;

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
  Duration? lastLatency;
  int _sessionSettingsLoadSerial = 0;
  int? _activeSessionSettingsLoadId;

  Future<void> connect() async {
    if (isSessionOperationRunning) return;
    await _runSessionOperation(() async {
      await _connectWithStatus(ConnectionStatus.connecting);
    });
  }

  Future<void> newSession() async {
    if (isStreaming || isSessionOperationRunning) return;
    await _runSessionOperation(() async {
      try {
        if (status == ConnectionStatus.disconnected ||
            status == ConnectionStatus.error) {
          await _connectWithStatus(ConnectionStatus.connecting);
          if (status == ConnectionStatus.error) return;
        }
        final session = (await client.createSession(
          cwd: cwd,
        )).copyWith(agentName: agentName);
        currentSession = session;
        _upsertSession(session);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        for (final event in session.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        await _loadSessionSettings(session.id, notify: false);
        status = ConnectionStatus.sessionReady;
        _notifyListeners();
      } catch (error) {
        _setError(error);
      }
    });
  }

  Future<void> resumeSession(
    String sessionId, {
    String? cwd,
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

    await _runSessionOperation(() async {
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
        final session = AgentSession(
          id: trimmedSessionId,
          cwd: workspaceCwd,
          createdAt: DateTime.now(),
          title: title,
          updatedAt: updatedAt,
          agentName: agentName,
        );
        currentSession = session;
        _upsertSession(session);
        _notifyListeners();

        final replay = await client.resumeSession(
          sessionId: trimmedSessionId,
          cwd: workspaceCwd,
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
    }

    final session = currentSession;
    if (session == null) return;

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
    _notifyListeners();

    await _promptSubscription?.cancel();
    _promptSubscription = client
        .sendPrompt(
          sessionId: session.id,
          prompt: prompt,
          attachments: attachments,
        )
        .listen(
          _handleAgentEvent,
          onError: (Object error, StackTrace stackTrace) {
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
      await _cancelPendingPermissionRequest();
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
      if (!didSet) {
        throw StateError('ACP agent rejected session mode "$trimmedModeId".');
      }
      sessionSettings = sessionSettings.withCurrentMode(trimmedModeId);
      lastError = null;
      _notifyListeners();
    } catch (error) {
      _setActionError(error);
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
      sessionSettings = sessionSettings.copyWith(
        configOptions: options.isEmpty
            ? _configOptionsWithOverride(trimmedConfigId, value)
            : options,
      );
      lastError = null;
      _notifyListeners();
    } catch (error) {
      _setActionError(error);
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
        );
        final forkedTitle = forked.title?.trim().isNotEmpty == true
            ? forked.title
            : 'Fork of ${session.displayTitle}';
        final updatedSession = forked.copyWith(
          title: forkedTitle,
          agentName: agentName,
        );
        currentSession = updatedSession;
        _upsertSession(updatedSession);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        for (final event in updatedSession.initialEvents) {
          _handleAgentEvent(event, notify: false);
        }
        await _loadSessionSettings(updatedSession.id, notify: false);
        status = ConnectionStatus.sessionReady;
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
        currentSession = null;
        sessions.removeWhere((item) => item.id == session.id);
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionSettingsLoading = false;
        await _cancelPendingPermissionRequest();
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
        currentSession = null;
        sessions.clear();
        messages.clear();
        availableCommands = const <Map<String, Object?>>[];
        lastLatency = null;
        lastError = null;
        sessionSettings = const AcpSessionSettings();
        sessionSettingsLoading = false;
        await _cancelPendingPermissionRequest();
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
    pendingPermissionRequest = null;
    _recordPermissionDecision(request.id, decision);
    _notifyListeners();
    await _sendPermissionDecision(id: request.id, decision: decision);
  }

  Future<void> _connectWithStatus(ConnectionStatus connectingStatus) async {
    status = connectingStatus;
    lastError = null;
    _notifyListeners();
    try {
      await client.connect();
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
        messages.add(
          ChatMessage(
            role: ChatMessageRole.tool,
            text: event.text,
            metadata: event.metadata,
          ),
        );
      case AgentEventType.error:
        final message = _messageForAgentError(event);
        lastError = message;
        messages.add(ChatMessage(role: ChatMessageRole.error, text: message));
        status = ConnectionStatus.error;
      case AgentEventType.status:
        _appendStatus(event);
    }
    if (notify) {
      _notifyListeners();
    }
  }

  void _handlePermissionRequest(AcpPermissionRequest request) {
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
        ),
      );
    }
    pendingPermissionRequest = request;
    _recordPermissionRequest(request);
    final trustedDecision = _trustedDecisionFor(request);
    if (trustedDecision != null) {
      pendingPermissionRequest = null;
      _recordPermissionDecision(
        request.id,
        trustedDecision,
        source: AcpPermissionDecisionSource.trustRule,
      );
      unawaited(
        _sendPermissionDecision(id: request.id, decision: trustedDecision),
      );
    }
    _notifyListeners();
  }

  void _handlePermissionRequestsDone() {
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

  Future<void> _sendPermissionDecision({
    required String id,
    required AcpPermissionDecision decision,
  }) async {
    try {
      await client.respondToPermissionRequest(id: id, decision: decision);
    } catch (error) {
      _setActionError(error);
    }
  }

  Future<void> _cancelPendingPermissionRequest() async {
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
  }) {
    final index = _permissionHistory.indexWhere(
      (entry) => entry.request.id == requestId,
    );
    if (index == -1) return;
    _permissionHistory[index] = _permissionHistory[index].copyWith(
      status: _permissionAuditStatus(decision),
      resolvedAt: DateTime.now(),
      decisionSource: source,
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
        sessionSettings = sessionSettings.copyWith(configOptions: options);
      }
      return;
    }
    if (kind == 'session_info_update') {
      _applySessionInfoUpdate(event.metadata);
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

  void _applySessionInfoUpdate(Map<String, Object?> metadata) {
    final session = currentSession;
    if (session == null) return;
    final sessionId = metadata['sessionId'];
    if (sessionId is String &&
        sessionId.isNotEmpty &&
        sessionId != session.id) {
      return;
    }

    final title = metadata['title'] is String
        ? metadata['title'] as String
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
    if (status != ConnectionStatus.error) {
      status = currentSession == null
          ? ConnectionStatus.connected
          : ConnectionStatus.sessionReady;
    }
    final startedAt = _lastPromptStartedAt;
    if (startedAt != null) {
      lastLatency = DateTime.now().difference(startedAt);
    }
    _notifyListeners();
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
        sessionSettings = settings;
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
        currentSession?.id == sessionId;
  }

  @override
  void dispose() {
    _isDisposed = true;
    unawaited(_promptSubscription?.cancel());
    unawaited(_permissionSubscription.cancel());
    unawaited(client.dispose());
    super.dispose();
  }

  void _notifyListeners() {
    if (_isDisposed) return;
    notifyListeners();
  }
}
