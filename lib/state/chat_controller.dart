import 'dart:async';

import 'package:flutter/foundation.dart';

import '../acp/acp_agent_capabilities.dart';
import '../acp/acp_agent_client.dart';
import '../acp/acp_session_catalog.dart';
import '../acp/agent_event.dart';
import '../acp/agent_session.dart';
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
  ChatController({required this.client, required this.cwd});

  final AcpAgentClient client;
  final String cwd;

  ConnectionStatus status = ConnectionStatus.disconnected;
  AgentSession? currentSession;
  final List<AgentSession> sessions = <AgentSession>[];
  final List<ChatMessage> messages = <ChatMessage>[];
  AcpAgentCapabilities? capabilities;
  String? lastError;
  bool isStreaming = false;

  StreamSubscription<AgentEvent>? _promptSubscription;
  DateTime? _lastPromptStartedAt;
  Duration? lastLatency;

  Future<void> connect() async {
    await _connectWithStatus(ConnectionStatus.connecting);
  }

  Future<void> newSession() async {
    try {
      if (status == ConnectionStatus.disconnected ||
          status == ConnectionStatus.error) {
        await connect();
        if (status == ConnectionStatus.error) return;
      }
      final session = await client.createSession(cwd: cwd);
      currentSession = session;
      sessions
        ..clear()
        ..add(session);
      messages.clear();
      lastLatency = null;
      lastError = null;
      status = ConnectionStatus.sessionReady;
      notifyListeners();
    } catch (error) {
      _setError(error);
    }
  }

  Future<void> resumeSession(String sessionId, {String? cwd}) async {
    final trimmedSessionId = sessionId.trim();
    if (trimmedSessionId.isEmpty || isStreaming) return;
    final workspaceCwd = cwd == null || cwd.trim().isEmpty
        ? this.cwd
        : cwd.trim();

    try {
      await _promptSubscription?.cancel();
      _promptSubscription = null;
      if (status == ConnectionStatus.disconnected ||
          status == ConnectionStatus.error) {
        await connect();
        if (status == ConnectionStatus.error) return;
      }

      status = ConnectionStatus.reconnecting;
      isStreaming = false;
      lastError = null;
      messages.clear();
      lastLatency = null;
      final session = AgentSession(
        id: trimmedSessionId,
        cwd: workspaceCwd,
        createdAt: DateTime.now(),
      );
      currentSession = session;
      sessions
        ..clear()
        ..add(session);
      notifyListeners();

      final replay = await client.resumeSession(
        sessionId: trimmedSessionId,
        cwd: workspaceCwd,
      );
      for (final event in replay) {
        _handleAgentEvent(event, notify: false);
      }
      if (status != ConnectionStatus.error) {
        status = ConnectionStatus.sessionReady;
      }
      notifyListeners();
    } catch (error) {
      _setError(error);
    }
  }

  Future<List<AcpProjectSessions>> listSessions() async {
    if (status == ConnectionStatus.disconnected ||
        status == ConnectionStatus.error) {
      await connect();
      if (status == ConnectionStatus.error) {
        throw StateError(lastError ?? 'ACP agent connection failed.');
      }
    }
    return client.listSessions();
  }

  Future<void> sendPrompt(String text) async {
    final prompt = text.trim();
    if (prompt.isEmpty || isStreaming) return;

    if (currentSession == null) {
      await newSession();
    }

    final session = currentSession;
    if (session == null) return;

    messages.add(ChatMessage(role: ChatMessageRole.user, text: prompt));
    isStreaming = true;
    status = ConnectionStatus.streaming;
    lastError = null;
    _lastPromptStartedAt = DateTime.now();
    notifyListeners();

    await _promptSubscription?.cancel();
    _promptSubscription = client
        .sendPrompt(sessionId: session.id, prompt: prompt)
        .listen(
          _handleAgentEvent,
          onError: (Object error, StackTrace stackTrace) {
            _handleAgentEvent(
              AgentEvent(type: AgentEventType.error, text: error.toString()),
            );
            _finishStreaming();
          },
          onDone: _finishStreaming,
        );
  }

  Future<void> stop() async {
    if (!isStreaming) return;
    await client.cancel();
    await _promptSubscription?.cancel();
    _promptSubscription = null;
    _finishStreaming();
  }

  Future<void> reconnect() async {
    await _promptSubscription?.cancel();
    _promptSubscription = null;
    isStreaming = false;
    currentSession = null;
    sessions.clear();
    await _connectWithStatus(ConnectionStatus.reconnecting);
  }

  Future<void> _connectWithStatus(ConnectionStatus connectingStatus) async {
    status = connectingStatus;
    lastError = null;
    notifyListeners();
    try {
      await client.connect();
      capabilities = client.capabilities;
      status = ConnectionStatus.connected;
      notifyListeners();
    } catch (error) {
      _setError(error);
    }
  }

  void _handleAgentEvent(AgentEvent event, {bool notify = true}) {
    switch (event.type) {
      case AgentEventType.userMessage:
        _appendText(ChatMessageRole.user, event.text);
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
        lastError = event.text;
        messages.add(
          ChatMessage(role: ChatMessageRole.error, text: event.text),
        );
        status = ConnectionStatus.error;
      case AgentEventType.status:
        _appendStatus(event);
    }
    if (notify) {
      notifyListeners();
    }
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
    notifyListeners();
  }

  void _setError(Object error) {
    lastError = error.toString();
    status = ConnectionStatus.error;
    isStreaming = false;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_promptSubscription?.cancel());
    unawaited(client.dispose());
    super.dispose();
  }
}
