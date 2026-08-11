import 'acp_agent_capabilities.dart';
import 'acp_agent_client.dart';
import 'acp_available_commands.dart';
import 'acp_permission_request.dart';
import 'acp_session_catalog.dart';
import 'acp_session_settings.dart';
import 'agent_event.dart';
import 'agent_session.dart';
import 'prompt_attachment.dart';

/// Shares one authoritative ACP connection across isolated conversation
/// controllers. Each lease receives permission events only for sessions that
/// it created, restored, or reclaimed from a local idle snapshot and releases
/// the underlying client when the final lease is disposed.
final class SessionScopedAgentClientPool {
  SessionScopedAgentClientPool(this._client);

  final AcpAgentClient _client;
  final Map<String, _SessionScopedAgentClient> _sessionOwners =
      <String, _SessionScopedAgentClient>{};
  final Map<String, _SessionScopedAgentClient> _pendingSessionOwners =
      <String, _SessionScopedAgentClient>{};
  final Map<String, _SessionScopedAgentClient> _activePromptOwners =
      <String, _SessionScopedAgentClient>{};
  int _leaseCount = 0;
  bool _closed = false;

  AcpAgentClient acquire() {
    if (_closed) throw StateError('ACP client pool is closed.');
    _leaseCount += 1;
    return _SessionScopedAgentClient(this, _client);
  }

  void _bind(_SessionScopedAgentClient lease, String sessionId) {
    final currentOwner = _sessionOwners[sessionId];
    if (currentOwner != null && !identical(currentOwner, lease)) {
      if (identical(_activePromptOwners[sessionId], currentOwner)) {
        throw StateError('Session $sessionId has an active prompt.');
      }
      currentOwner._sessionIds.remove(sessionId);
    }
    for (final previousSessionId in lease._sessionIds.toList(growable: false)) {
      if (identical(_sessionOwners[previousSessionId], lease)) {
        _sessionOwners.remove(previousSessionId);
      }
    }
    lease._sessionIds.clear();
    _sessionOwners[sessionId] = lease;
    lease._sessionIds.add(sessionId);
  }

  void _reserveRestore(_SessionScopedAgentClient lease, String sessionId) {
    if (_activePromptOwners.containsKey(sessionId)) {
      throw StateError('Session $sessionId has an active prompt.');
    }
    // An idle owner may hand the session to a controller that needs to reload
    // an evicted local snapshot; _bind performs that transfer after success.
    final pendingOwner = _pendingSessionOwners[sessionId];
    if (pendingOwner != null) {
      throw StateError('Session $sessionId is already being restored.');
    }
    _pendingSessionOwners[sessionId] = lease;
  }

  void _releaseRestoreReservation(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    if (identical(_pendingSessionOwners[sessionId], lease)) {
      _pendingSessionOwners.remove(sessionId);
    }
  }

  void _unbind(_SessionScopedAgentClient lease, String sessionId) {
    lease._sessionIds.remove(sessionId);
    if (identical(_sessionOwners[sessionId], lease)) {
      _sessionOwners.remove(sessionId);
    }
  }

  bool _owns(_SessionScopedAgentClient lease, String sessionId) {
    return identical(_sessionOwners[sessionId], lease);
  }

  void _beginPrompt(_SessionScopedAgentClient lease, String sessionId) {
    if (!_owns(lease, sessionId)) {
      throw StateError('Session $sessionId is not owned by this lease.');
    }
    if (_pendingSessionOwners.containsKey(sessionId)) {
      throw StateError('Session $sessionId is being restored.');
    }
    if (_activePromptOwners.containsKey(sessionId)) {
      throw StateError('Session $sessionId already has an active prompt.');
    }
    _activePromptOwners[sessionId] = lease;
  }

  void _finishPrompt(_SessionScopedAgentClient lease, String sessionId) {
    if (identical(_activePromptOwners[sessionId], lease)) {
      _activePromptOwners.remove(sessionId);
    }
  }

  Future<void> _release(_SessionScopedAgentClient lease) async {
    if (_leaseCount <= 0) return;
    for (final sessionId in lease._sessionIds.toList(growable: false)) {
      _unbind(lease, sessionId);
    }
    _pendingSessionOwners.removeWhere((_, owner) => identical(owner, lease));
    _activePromptOwners.removeWhere((_, owner) => identical(owner, lease));
    _leaseCount -= 1;
    if (_leaseCount != 0 || _closed) return;
    _closed = true;
    await _client.dispose();
  }
}

final class _SessionScopedAgentClient implements AcpAgentClient {
  _SessionScopedAgentClient(this._pool, this._client);

  final SessionScopedAgentClientPool _pool;
  final AcpAgentClient _client;
  final Set<String> _sessionIds = <String>{};
  final Set<String> _permissionRequestIds = <String>{};
  bool _disposed = false;

  @override
  AcpAgentCapabilities? get capabilities => _client.capabilities;

  @override
  bool get supportsConcurrentPrompts => _client.supportsConcurrentPrompts;

  @override
  Stream<AcpPermissionRequest> get permissionRequests => _client
      .permissionRequests
      .where((request) => _receivesSession(request.sessionId))
      .map((request) {
        _permissionRequestIds.add(request.id);
        return request;
      });

  @override
  Stream<AcpPermissionInvalidation> get permissionInvalidations => _client
      .permissionInvalidations
      .where((event) => _receivesSession(event.sessionId))
      .map((event) {
        _permissionRequestIds.remove(event.requestId);
        return event;
      });

  @override
  Stream<AcpAvailableCommandsUpdate> get availableCommandsUpdates => _client
      .availableCommandsUpdates
      .where((update) => _receivesSession(update.sessionId));

  @override
  Future<AcpAvailableCommandsUpdate?> sessionAvailableCommands(
    String sessionId,
  ) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    if (!_receivesSession(normalizedSessionId)) {
      return Future<AcpAvailableCommandsUpdate?>.value();
    }
    return _client.sessionAvailableCommands(normalizedSessionId);
  }

  @override
  Future<void> connect() {
    _ensureOpen();
    return _client.connect();
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureOpen();
    final session = await _client.createSession(
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
    _ensureOpen();
    _bind(session.id);
    return session;
  }

  @override
  Future<AcpSessionRestoreSummary> restoreSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
    bool replayHistory = true,
    required AcpSessionRestoreEventObserver onEvent,
  }) async {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._reserveRestore(this, normalizedSessionId);
    try {
      final summary = await _client.restoreSession(
        sessionId: normalizedSessionId,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
        replayHistory: replayHistory,
        onEvent: onEvent,
      );
      _ensureOpen();
      _bind(normalizedSessionId);
      return summary;
    } finally {
      _pool._releaseRestoreReservation(this, normalizedSessionId);
    }
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() {
    _ensureOpen();
    return _client.listSessions();
  }

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) {
    _ensureOpen();
    return _client.sessionSettings(sessionId);
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) {
    _ensureOpen();
    return _client.setSessionMode(sessionId: sessionId, modeId: modeId);
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) {
    _ensureOpen();
    return _client.setConfigOption(
      sessionId: sessionId,
      configId: configId,
      value: value,
    );
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureOpen();
    final session = await _client.forkSession(
      sessionId: sessionId,
      cwd: cwd,
      additionalDirectories: additionalDirectories,
    );
    _ensureOpen();
    _bind(session.id);
    return session;
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    _ensureOpen();
    await _client.closeSession(sessionId: sessionId);
    _pool._unbind(this, sessionId.trim());
  }

  @override
  Future<void> deleteSession({required String sessionId}) async {
    _ensureOpen();
    await _client.deleteSession(sessionId: sessionId);
    _pool._unbind(this, sessionId.trim());
  }

  @override
  Future<void> authenticate({required String methodId}) {
    _ensureOpen();
    return _client.authenticate(methodId: methodId);
  }

  @override
  Future<void> logout() {
    _ensureOpen();
    return _client.logout();
  }

  @override
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
    List<PromptAttachment> attachments = const <PromptAttachment>[],
  }) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    // ChatController can reactivate an idle session from its local view
    // snapshot without calling restoreSession again. Reclaim that unowned
    // session at the first operation that can emit session-scoped events.
    // A session owned by another lease is still protected because it may have
    // a prompt running in another conversation view.
    if (!_pool._owns(this, normalizedSessionId) &&
        _pool._sessionOwners[normalizedSessionId] == null) {
      _bind(normalizedSessionId);
    }
    if (!_pool._owns(this, normalizedSessionId)) {
      return Stream<AgentEvent>.error(
        StateError('Session $normalizedSessionId is not owned by this lease.'),
      );
    }
    try {
      _pool._beginPrompt(this, normalizedSessionId);
      final events = _client.sendPrompt(
        sessionId: normalizedSessionId,
        prompt: prompt,
        attachments: attachments,
      );
      return (() async* {
        try {
          yield* events;
        } finally {
          _pool._finishPrompt(this, normalizedSessionId);
        }
      })();
    } on Object catch (error, stackTrace) {
      _pool._finishPrompt(this, normalizedSessionId);
      return Stream<AgentEvent>.error(error, stackTrace);
    }
  }

  @override
  Future<void> cancel() async {
    _ensureOpen();
    if (_sessionIds.length != 1) {
      throw StateError('Session-specific cancellation requires a session id.');
    }
    await cancelSession(sessionId: _sessionIds.single);
  }

  @override
  Future<void> cancelSession({required String sessionId}) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    if (!_pool._owns(this, normalizedSessionId)) {
      return Future<void>.error(
        StateError('Session $normalizedSessionId is not owned by this lease.'),
      );
    }
    return _client.cancelSession(sessionId: normalizedSessionId);
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    _ensureOpen();
    if (!_permissionRequestIds.contains(id)) {
      throw StateError('Permission request $id is not owned by this lease.');
    }
    await _client.respondToPermissionRequest(
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
    _permissionRequestIds.remove(id);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _permissionRequestIds.clear();
    final activeSessionIds = _pool._activePromptOwners.entries
        .where((entry) => identical(entry.value, this))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final sessionId in activeSessionIds) {
      try {
        await _client.cancelSession(sessionId: sessionId);
      } on Object {
        // Releasing the lease and the final underlying client must continue.
      }
    }
    await _pool._release(this);
  }

  void _bind(String sessionId) {
    _pool._bind(this, _normalizedSessionId(sessionId));
  }

  bool _receivesSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    final pendingOwner = _pool._pendingSessionOwners[normalizedSessionId];
    if (pendingOwner != null) return identical(pendingOwner, this);
    return _pool._owns(this, normalizedSessionId);
  }

  String _normalizedSessionId(String sessionId) {
    final normalized = sessionId.trim();
    if (normalized.isEmpty) throw ArgumentError.value(sessionId, 'sessionId');
    return normalized;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('ACP client lease is disposed.');
  }
}
