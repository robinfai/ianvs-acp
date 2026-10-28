import 'dart:async';
import 'package:ianvs_agent_core/ianvs_agent_core.dart';
import 'ianvs_acp_runtime.dart';

/// A single already-created ACP session. The host owns the runtime and its launch
/// policy. Native events alone decide operation completion and permission validity.
class AcpRuntimeChatSession extends ChatSession {
  AcpRuntimeChatSession({
    required this.runtime,
    required this.sessionId,
    required this.agentName,
    this.cwd = '',
  }) {
    _content = ChatContentProjection(
      identity: ChatContentIdentity(runtime, sessionId),
    );
    _subscription = runtime.events.listen(
      _onEvent,
      onError: (Object error) => _fail(error),
      onDone: () {
        if (!_disposed) _fail(StateError('Runtime event stream closed'));
      },
    );
  }
  final IanvsRustRuntime runtime;
  final String sessionId, agentName, cwd;
  late final ChatContentProjection _content;
  late final StreamSubscription<IanvsRuntimeEvent> _subscription;
  final _pending = <String, Completer<void>>{};
  String? _promptId, _restoreId, _error;
  ChatPermissionRequest? _permission;
  int _next = 0, _turn = 0;
  bool _disposed = false;
  Map<String, Object?>? lastResultMeta;

  @override
  ChatSessionState get state => ChatSessionState(
    identity: _content.identity,
    agentName: agentName,
    messages: _content.messages,
    messagesRevision: _content.revision,
    isSending: _promptId != null,
    isLoading: _restoreId != null,
    enabled: !_disposed && _error == null,
    permission: _permission,
    error: _error,
    capabilities: const ChatCapabilities(tools: true, permissions: true),
  );

  String _id() => '$sessionId:${identityHashCode(this)}:${_next++}';
  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) {
    if (_disposed ||
        _error != null ||
        _promptId != null ||
        _restoreId != null) {
      return Future.error(StateError('Session is unavailable or busy'));
    }
    if (attachments.isNotEmpty) {
      return Future.error(
        UnsupportedError('Use runtime prompt attachment encoding explicitly'),
      );
    }
    final id = _id();
    _promptId = id;
    final result = _pending[id] = Completer<void>();
    _turn++;
    try {
      runtime.prompt(requestId: id, sessionId: sessionId, text: text);
    } catch (error) {
      _fail(error);
    }
    notifySessionChanged();
    return result.future;
  }

  @override
  Future<void> stop() async {
    final prompt = _promptId;
    if (prompt == null) return;
    final completion = _pending[prompt]?.future;
    runtime.cancel(requestId: _id(), sessionId: sessionId);
    if (completion != null) await completion;
  }

  Future<void> restore() {
    if (_disposed || _promptId != null || _restoreId != null) {
      return Future.error(StateError('Session is busy'));
    }
    final id = _id();
    _restoreId = id;
    _content.beginRestore(id);
    final result = _pending[id] = Completer<void>();
    try {
      runtime.restoreSession(requestId: id, sessionId: sessionId, cwd: cwd);
    } catch (error) {
      _fail(error);
    }
    notifySessionChanged();
    return result.future;
  }

  @override
  Future<void> selectPermissionOption(String optionId) async {
    final request = _permission;
    if (request == null ||
        !request.choices.any((c) => c.optionId == optionId)) {
      throw StateError('Permission is stale or option was not offered');
    }
    runtime.respondPermission(
      requestId: request.id,
      decision: {'decision': 'selected', 'optionId': optionId},
    );
    _permission = null;
    notifySessionChanged();
  }

  @override
  Future<void> resolvePermission(ChatPermissionDecision decision) async {
    if (decision != ChatPermissionDecision.cancel) {
      throw UnsupportedError('Select an explicit offered option');
    }
    final request = _permission;
    if (request == null) return;
    runtime.respondPermission(
      requestId: request.id,
      decision: {'decision': 'cancelled'},
    );
    _permission = null;
    notifySessionChanged();
  }

  void _onEvent(IanvsRuntimeEvent event) {
    if (_disposed) return;
    try {
      final data = event.data;
      if (event.type == IanvsRuntimeEventType.runtimeError) {
        final id = data['requestId'];
        if (id == null || _pending.containsKey(id)) {
          _fail(StateError('${data['code']}: ${data['message']}'));
        }
        return;
      }
      if (event.type == IanvsRuntimeEventType.statusChanged &&
          [
            'failed',
            'disposed',
            'stopped',
            'recovering',
          ].contains(data['status'])) {
        _fail(StateError('Connection ${data['status']}'));
        return;
      }
      if (event.type == IanvsRuntimeEventType.renderSnapshotChunk) {
        if (data['sessionId'] != sessionId || data['requestId'] != _restoreId) {
          return;
        }
        for (final item in data['updates'] as List) {
          _render(Map<String, Object?>.from(item as Map), replay: true);
        }
      } else if (event.type == IanvsRuntimeEventType.renderUpdate) {
        _render(Map<String, Object?>.from(data['update'] as Map));
      } else if (event.type == IanvsRuntimeEventType.sessionUpdate) {
        final update = Map<String, Object?>.from(data['update'] as Map);
        if (update['sessionId'] != sessionId) return;
        if (update['kind'] == 'session_restored' &&
            update['requestId'] == _restoreId &&
            _restoreId != null) {
          final id = _restoreId!;
          _content.commitRestore(id);
          _restoreId = null;
          _pending.remove(id)?.complete();
        } else if (update['kind'] == 'permission_invalidated') {
          _permission = null;
        }
      } else if (event.type == IanvsRuntimeEventType.permissionRequest) {
        final req = Map<String, Object?>.from(data['request'] as Map);
        if (req['sessionId'] != sessionId) return;
        final choices = [
          for (final raw in req['options'] as List)
            ChatPermissionChoice(
              optionId: raw['optionId'] as String,
              name: raw['label'] as String,
              kind: raw['kind'] as String?,
            ),
        ];
        _permission = ChatPermissionRequest(
          id: req['requestId'] as String,
          title: req['title'] as String,
          rationale: '',
          sessionId: sessionId,
          toolName: req['toolCallId'] as String,
          options: choices.map((c) => c.name).toList(),
          requestedAt: DateTime.now(),
          choices: choices,
          metadata: req,
        );
      }
      notifySessionChanged();
    } catch (error) {
      _fail(error);
    }
  }

  void _render(Map<String, Object?> update, {bool replay = false}) {
    if (update['sessionId'] != sessionId) return;
    final metadata = Map<String, Object?>.from(
      update['metadata'] as Map? ?? {},
    );
    if (update['kind'] == 'turn_completed') {
      if (replay) {
        _content.apply(
          ChatContentUpdate(
            identity: _content.identity,
            turnId: _turn,
            kind: ChatContentKind.turnCompleted,
          ),
          restoreId: _restoreId,
        );
        return;
      }
      if (metadata['requestId'] != _promptId || _promptId == null) return;
      lastResultMeta = metadata['resultMeta'] == null
          ? null
          : Map<String, Object?>.from(metadata['resultMeta'] as Map);
      _content.apply(
        ChatContentUpdate(
          identity: _content.identity,
          turnId: _turn,
          kind: ChatContentKind.turnCompleted,
        ),
      );
      final id = _promptId!;
      _promptId = null;
      _permission = null;
      _pending.remove(id)?.complete();
      return;
    }
    if (replay && update['kind'] == 'user_message') _turn++;
    final kind = switch (update['kind']) {
      'user_message' => ChatContentKind.user,
      'assistant_text' => ChatContentKind.textDelta,
      'thought' => ChatContentKind.thoughtDelta,
      'tool_call' => ChatContentKind.tool,
      'plan' => ChatContentKind.plan,
      _ => null,
    };
    if (kind == null) return;
    _content.apply(
      ChatContentUpdate(
        identity: _content.identity,
        turnId: _turn,
        kind: kind,
        text: update['text'] as String? ?? '',
        toolCallId: metadata['toolCallId'] as String?,
        metadata: metadata,
      ),
      restoreId: replay ? _restoreId : null,
    );
  }

  void _fail(Object error) {
    _error = error.toString();
    final restore = _restoreId;
    if (restore != null) _content.discardRestore(restore);
    _promptId = _restoreId = null;
    _permission = null;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
    notifySessionChanged();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _fail(StateError('Session view disposed'));
    unawaited(_subscription.cancel());
    super.dispose();
  }
}
