import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

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
  SessionScopedAgentClientPool(this._client) {
    _permissionRequestsSubscription = _client.permissionRequests.listen(
      _dispatchPermissionRequest,
      onError: _dispatchPermissionError,
      onDone: _closePermissionRequestStreams,
    );
    _permissionInvalidationsSubscription = _client.permissionInvalidations
        .listen(
          _dispatchPermissionInvalidation,
          onError: _dispatchPermissionInvalidationError,
          onDone: _closePermissionInvalidationStreams,
        );
  }

  static const int _retiredSessionLimit = 512;
  static const int _permissionOwnershipLimit = 512;
  static const int _centralCancellationLimit = 64;
  static const int _centralCancellationQueueLimit = 512;
  static const int _maxIdentityCodeUnits = 4096;
  static const int _knownSessionLimit = 512;

  final AcpAgentClient _client;
  final Map<String, _SessionScopedAgentClient> _sessionOwners =
      <String, _SessionScopedAgentClient>{};
  final Map<String, _SessionScopedAgentClient> _pendingSessionOwners =
      <String, _SessionScopedAgentClient>{};
  final Map<String, _SessionScopedAgentClient> _activePromptOwners =
      <String, _SessionScopedAgentClient>{};
  final Map<String, _SessionScopedAgentClient> _sessionOperationOwners =
      <String, _SessionScopedAgentClient>{};
  final Set<String> _terminalSessionOperations = <String>{};
  final LinkedHashMap<String, _SessionScopedAgentClient?>
  _retiredSessionOwners = LinkedHashMap<String, _SessionScopedAgentClient?>();
  final LinkedHashMap<String, _PermissionRequestBinding>
  _permissionRequestOwners = LinkedHashMap<String, _PermissionRequestBinding>();
  final Map<Object, _SessionScopedAgentClient> _pendingSetupOperations =
      <Object, _SessionScopedAgentClient>{};
  final Map<Object, String> _pendingSetupSourceSessions = <Object, String>{};
  final Map<_SessionScopedAgentClient, int> _queuedSetupOwners =
      <_SessionScopedAgentClient, int>{};
  final Map<String, Object> _pendingRestoreTokens = <String, Object>{};
  final Set<String> _centralCancellationIds = <String>{};
  final LinkedHashMap<String, _PermissionCancellationIdentity>
  _queuedCentralCancellations =
      LinkedHashMap<String, _PermissionCancellationIdentity>();
  final Map<String, _PermissionRequestBinding> _respondingPermissionBindings =
      <String, _PermissionRequestBinding>{};
  final LinkedHashMap<String, AcpPermissionRequest>
  _deferredPermissionRequests = LinkedHashMap<String, AcpPermissionRequest>();
  final Set<_SessionScopedAgentClient> _leases = <_SessionScopedAgentClient>{};
  final StreamController<AcpAgentLifecycleEvent> _lifecycleEvents =
      StreamController<AcpAgentLifecycleEvent>.broadcast(sync: true);
  int _leaseCount = 0;
  int _activeAgentOperations = 0;
  bool _closed = false;
  bool _logoutInProgress = false;
  final _BoundedIdentityBloomFilter _retiredSessionHistory =
      _BoundedIdentityBloomFilter();
  final _BoundedIdentityBloomFilter _knownSessionHistory =
      _BoundedIdentityBloomFilter();
  bool _permissionRequestsDone = false;
  bool _permissionInvalidationsDone = false;
  int _queuedSetupOperations = 0;
  Future<void> _setupTail = Future<void>.value();
  late final StreamSubscription<AcpPermissionRequest>
  _permissionRequestsSubscription;
  late final StreamSubscription<AcpPermissionInvalidation>
  _permissionInvalidationsSubscription;

  bool get isClosed => _closed;

  AcpAgentClient acquire() {
    if (_closed) throw StateError('ACP client pool is closed.');
    _leaseCount += 1;
    final lease = _SessionScopedAgentClient(this, _client);
    _leases.add(lease);
    if (_permissionRequestsDone) {
      unawaited(lease._permissionRequests.close());
    }
    if (_permissionInvalidationsDone) {
      unawaited(lease._permissionInvalidations.close());
    }
    return lease;
  }

  void _bind(
    _SessionScopedAgentClient lease,
    String sessionId, {
    bool allowTransfer = false,
    String? allowPreviousOperationSessionId,
  }) {
    _ensureAgentLifecycleAvailable();
    final pendingOwner = _pendingSessionOwners[sessionId];
    if (pendingOwner != null && !identical(pendingOwner, lease)) {
      throw StateError(
        'Session $sessionId is being restored by another lease.',
      );
    }
    final operationOwner = _sessionOperationOwners[sessionId];
    if (operationOwner != null && !identical(operationOwner, lease)) {
      throw StateError('Session $sessionId has an active operation.');
    }
    if (_respondingPermissionBindings.values.any(
      (binding) => binding.normalizedSessionId == sessionId,
    )) {
      throw StateError('Session $sessionId is resolving a permission request.');
    }
    _retiredSessionOwners.remove(sessionId);
    final currentOwner = _sessionOwners[sessionId];
    if (currentOwner != null && !identical(currentOwner, lease)) {
      if (!allowTransfer) {
        throw StateError('Session $sessionId is owned by another lease.');
      }
      if (_leaseHasActiveWork(currentOwner)) {
        throw StateError('Session $sessionId owner has an active operation.');
      }
      if (identical(_activePromptOwners[sessionId], currentOwner)) {
        throw StateError('Session $sessionId has an active prompt.');
      }
      final restoreToken = identical(_pendingSessionOwners[sessionId], lease)
          ? _pendingRestoreTokens[sessionId]
          : null;
      _cancelPermissionBindingsForSession(
        sessionId,
        preserveOwner: lease,
        preserveOperationToken: restoreToken,
      );
      currentOwner._sessionIds.remove(sessionId);
      currentOwner._knownSessionIds.remove(sessionId);
    }
    for (final previousSessionId in lease._sessionIds.toList(growable: false)) {
      if (identical(_sessionOwners[previousSessionId], lease)) {
        if (previousSessionId != sessionId &&
            identical(_activePromptOwners[previousSessionId], lease)) {
          throw StateError('Session $previousSessionId has an active prompt.');
        }
        if (previousSessionId != sessionId &&
            identical(_sessionOperationOwners[previousSessionId], lease) &&
            previousSessionId != allowPreviousOperationSessionId) {
          throw StateError(
            'Session $previousSessionId has an active operation.',
          );
        }
        _sessionOwners.remove(previousSessionId);
        if (previousSessionId != sessionId) {
          _cancelPermissionBindingsForSession(previousSessionId);
        }
      }
    }
    lease._sessionIds.clear();
    _sessionOwners[sessionId] = lease;
    lease._sessionIds.add(sessionId);
    lease._rememberSession(sessionId);
  }

  Object _reserveRestore(_SessionScopedAgentClient lease, String sessionId) {
    _ensureAgentLifecycleAvailable();
    if (_activePromptOwners.containsKey(sessionId)) {
      throw StateError('Session $sessionId has an active prompt.');
    }
    if (_respondingPermissionBindings.values.any(
      (binding) => binding.normalizedSessionId == sessionId,
    )) {
      throw StateError('Session $sessionId is resolving a permission request.');
    }
    // An idle owner may hand the session to a controller that needs to reload
    // an evicted local snapshot; _bind performs that transfer after success.
    final pendingOwner = _pendingSessionOwners[sessionId];
    if (pendingOwner != null) {
      throw StateError('Session $sessionId is already being restored.');
    }
    final currentOwner = _sessionOwners[sessionId];
    if (currentOwner != null &&
        !identical(currentOwner, lease) &&
        _leaseHasActiveWork(currentOwner)) {
      throw StateError('Session $sessionId owner has an active operation.');
    }
    final token = Object();
    _pendingSessionOwners[sessionId] = lease;
    _pendingRestoreTokens[sessionId] = token;
    return token;
  }

  void _releaseRestoreReservation(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    if (identical(_pendingSessionOwners[sessionId], lease)) {
      _pendingSessionOwners.remove(sessionId);
      _pendingRestoreTokens.remove(sessionId);
    }
  }

  void _unbind(
    _SessionScopedAgentClient lease,
    String sessionId, {
    bool retire = false,
  }) {
    lease._sessionIds.remove(sessionId);
    if (!identical(_sessionOwners[sessionId], lease)) return;
    _sessionOwners.remove(sessionId);
    _cancelPermissionBindingsForSession(sessionId);
    if (retire) _retireSession(sessionId, lease);
  }

  void _retireSession(String sessionId, _SessionScopedAgentClient lease) {
    _retiredSessionHistory.add(sessionId);
    for (final activeLease in _leases) {
      activeLease._knownSessionIds.remove(sessionId);
    }
    _retiredSessionOwners.remove(sessionId);
    _retiredSessionOwners[sessionId] = lease._disposed ? null : lease;
    while (_retiredSessionOwners.length > _retiredSessionLimit) {
      _retiredSessionOwners.remove(_retiredSessionOwners.keys.first);
    }
  }

  bool _owns(_SessionScopedAgentClient lease, String sessionId) {
    return identical(_sessionOwners[sessionId], lease);
  }

  void _claimSessionIfUnowned(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    if (!_owns(lease, sessionId) && _sessionOwners[sessionId] == null) {
      if (_retiredSessionOwners.containsKey(sessionId)) {
        throw StateError('Session $sessionId is retired.');
      }
      if (!lease._knownSessionIds.contains(sessionId)) {
        throw StateError('Session $sessionId is not known by this lease.');
      }
      _bind(lease, sessionId);
    }
    if (!_owns(lease, sessionId)) {
      throw StateError('Session $sessionId is not owned by this lease.');
    }
  }

  void _beginPrompt(_SessionScopedAgentClient lease, String sessionId) {
    _ensureAgentLifecycleAvailable();
    if (!_owns(lease, sessionId)) {
      throw StateError('Session $sessionId is not owned by this lease.');
    }
    if (_pendingSessionOwners.containsKey(sessionId)) {
      throw StateError('Session $sessionId is being restored.');
    }
    if (_sessionOperationOwners.values.any(
      (owner) => identical(owner, lease),
    )) {
      throw StateError('Session $sessionId has an active operation.');
    }
    if (_pendingSetupOperations.values.any(
      (owner) => identical(owner, lease),
    )) {
      throw StateError('This lease has a session setup in progress.');
    }
    if ((_queuedSetupOwners[lease] ?? 0) != 0) {
      throw StateError('This lease has a queued session setup.');
    }
    if (_leaseHasRespondingPermission(lease)) {
      throw StateError('This lease is resolving a permission request.');
    }
    if (_leaseHasOwnershipReservation(lease)) {
      throw StateError('This lease is handing off a session.');
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

  void _beginSessionOperation(
    _SessionScopedAgentClient lease,
    String sessionId, {
    bool allowActivePrompt = false,
    Object? setupToken,
  }) {
    _ensureAgentLifecycleAvailable();
    if (_sessionOperationOwners.entries.any(
      (entry) => entry.key == sessionId || identical(entry.value, lease),
    )) {
      throw StateError('Session $sessionId has an active operation.');
    }
    final leasePrompts = _activePromptOwners.entries.where(
      (entry) => identical(entry.value, lease),
    );
    if (leasePrompts.any(
      (entry) => !allowActivePrompt || entry.key != sessionId,
    )) {
      throw StateError('Session $sessionId has an active prompt.');
    }
    if (_pendingSetupOperations.entries.any(
      (entry) =>
          identical(entry.value, lease) && !identical(entry.key, setupToken),
    )) {
      throw StateError('This lease has a session setup in progress.');
    }
    if ((_queuedSetupOwners[lease] ?? 0) != 0 && setupToken == null) {
      throw StateError('This lease has a queued session setup.');
    }
    if (_leaseHasRespondingPermission(lease)) {
      throw StateError('This lease is resolving a permission request.');
    }
    if (_leaseHasOwnershipReservation(lease)) {
      throw StateError('This lease is handing off a session.');
    }
    _sessionOperationOwners[sessionId] = lease;
  }

  void _finishSessionOperation(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    if (identical(_sessionOperationOwners[sessionId], lease)) {
      _sessionOperationOwners.remove(sessionId);
    }
    if (lease._disposed && _owns(lease, sessionId)) {
      _unbind(lease, sessionId, retire: true);
    }
    unawaited(_closeIfUnused().catchError((Object _) {}));
  }

  void _beginTerminalSessionOperation(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    _beginSessionOperation(lease, sessionId);
    _terminalSessionOperations.add(sessionId);
    _cancelPermissionBindingsForSession(sessionId);
  }

  void _finishTerminalSessionOperation(
    _SessionScopedAgentClient lease,
    String sessionId,
  ) {
    _terminalSessionOperations.remove(sessionId);
    _finishSessionOperation(lease, sessionId);
  }

  Object _beginSetup(_SessionScopedAgentClient lease) {
    _ensureAgentLifecycleAvailable();
    if (_activePromptOwners.values.any((owner) => identical(owner, lease)) ||
        _sessionOperationOwners.values.any(
          (owner) => identical(owner, lease),
        ) ||
        _pendingSessionOwners.values.any((owner) => identical(owner, lease)) ||
        _permissionRequestOwners.values.any(
          (binding) => identical(binding.owner, lease),
        ) ||
        _leaseHasRespondingPermission(lease) ||
        _leaseHasOwnershipReservation(lease)) {
      throw StateError('This lease has an active session operation.');
    }
    final token = Object();
    _pendingSetupOperations[token] = lease;
    return token;
  }

  bool _leaseHasActiveWork(_SessionScopedAgentClient lease) {
    return _activePromptOwners.values.any((owner) => identical(owner, lease)) ||
        _sessionOperationOwners.values.any(
          (owner) => identical(owner, lease),
        ) ||
        _pendingSetupOperations.values.any(
          (owner) => identical(owner, lease),
        ) ||
        _pendingSessionOwners.values.any((owner) => identical(owner, lease)) ||
        (_queuedSetupOwners[lease] ?? 0) != 0 ||
        _leaseHasRespondingPermission(lease);
  }

  bool _leaseHasRespondingPermission(_SessionScopedAgentClient lease) {
    for (final binding in _respondingPermissionBindings.values) {
      if (identical(binding.owner, lease)) {
        return true;
      }
    }
    return false;
  }

  bool _leaseHasOwnershipReservation(_SessionScopedAgentClient lease) {
    for (final entry in _pendingSessionOwners.entries) {
      if (!identical(entry.value, lease) &&
          identical(_sessionOwners[entry.key], lease)) {
        return true;
      }
    }
    return false;
  }

  void _completeProvisionalOperation(Object token, String sessionId) {
    _pendingSetupOperations.remove(token);
    _pendingSetupSourceSessions.remove(token);
    for (final entry in _permissionRequestOwners.entries.toList(
      growable: false,
    )) {
      final binding = entry.value;
      if (!identical(binding.operationToken, token)) continue;
      if (binding.normalizedSessionId == sessionId) {
        _permissionRequestOwners[entry.key] = binding.promoted();
      } else {
        _retireProvisionalBindingSession(binding);
        _cancelPermissionBinding(entry.key, binding);
      }
    }
  }

  void _failProvisionalOperation(Object token) {
    _pendingSetupOperations.remove(token);
    _pendingSetupSourceSessions.remove(token);
    for (final entry in _permissionRequestOwners.entries.toList(
      growable: false,
    )) {
      if (identical(entry.value.operationToken, token)) {
        _retireProvisionalBindingSession(entry.value);
        _cancelPermissionBinding(entry.key, entry.value);
      }
    }
  }

  void _retireProvisionalBindingSession(_PermissionRequestBinding binding) {
    final sessionId = binding.normalizedSessionId;
    if (sessionId.isEmpty ||
        _sessionOwners.containsKey(sessionId) ||
        binding.owner._knownSessionIds.contains(sessionId)) {
      return;
    }
    _retireSession(sessionId, binding.owner);
  }

  void _markProvisionalSourceSession(Object token, String sessionId) {
    if (_pendingSetupOperations.containsKey(token)) {
      _pendingSetupSourceSessions[token] = sessionId;
    }
  }

  Future<T> _runSerializedSetup<T>(
    _SessionScopedAgentClient lease,
    Future<T> Function(Object token) operation,
  ) async {
    _ensureAgentLifecycleAvailable();
    _queuedSetupOperations += 1;
    _queuedSetupOwners.update(lease, (count) => count + 1, ifAbsent: () => 1);
    final previous = _setupTail;
    final release = Completer<void>();
    _setupTail = release.future;
    try {
      await previous.catchError((Object _) {});
      if (lease._disposed) throw StateError('ACP client lease is disposed.');
      return await _runAgentOperation(() async {
        final token = _beginSetup(lease);
        try {
          return await operation(token);
        } catch (_) {
          _failProvisionalOperation(token);
          rethrow;
        }
      });
    } finally {
      _queuedSetupOperations -= 1;
      final remainingForLease = (_queuedSetupOwners[lease] ?? 1) - 1;
      if (remainingForLease <= 0) {
        _queuedSetupOwners.remove(lease);
      } else {
        _queuedSetupOwners[lease] = remainingForLease;
      }
      if (!release.isCompleted) release.complete();
      await _closeIfUnused();
    }
  }

  void _dispatchPermissionRequest(AcpPermissionRequest request) {
    if (!_isBoundedIdentity(request.id) ||
        !_isBoundedIdentity(request.sessionId) ||
        request.lifecycleId.length > _maxIdentityCodeUnits) {
      _cancelPermissionRequest(request);
      return;
    }
    if (_respondingPermissionBindings.containsKey(request.id) ||
        _centralCancellationIds.contains(request.id) ||
        _queuedCentralCancellations.containsKey(request.id)) {
      if (_deferredPermissionRequests.length < _permissionOwnershipLimit ||
          _deferredPermissionRequests.containsKey(request.id)) {
        _deferredPermissionRequests[request.id] = request;
      }
      return;
    }
    if (_permissionRequestsDone) {
      _cancelPermissionRequest(request);
      return;
    }
    final sessionId = request.sessionId.trim();
    if (_terminalSessionOperations.contains(sessionId)) {
      _cancelUnownedPermission(request);
      return;
    }
    final liveOwner = _sessionOwners[sessionId];
    var owner = _pendingSessionOwners[sessionId] ?? liveOwner;
    Object? operationToken = _pendingRestoreTokens[sessionId];
    if (owner == null &&
        !_retiredSessionOwners.containsKey(sessionId) &&
        !_retiredSessionHistory.mightContain(sessionId) &&
        !_knownSessionHistory.mightContain(sessionId)) {
      final setupOperations = _pendingSetupOperations.entries
          .where((entry) {
            final candidate = entry.value;
            return _leases.contains(candidate) && !candidate._disposed;
          })
          .take(2)
          .toList(growable: false);
      if (setupOperations.length == 1) {
        owner = setupOperations.single.value;
        operationToken = setupOperations.single.key;
      }
    }
    if (sessionId.isEmpty ||
        owner == null ||
        !_leases.contains(owner) ||
        owner._disposed) {
      _cancelUnownedPermission(request);
      return;
    }

    if (operationToken == null) {
      final ownerSetupOperations = _pendingSetupOperations.entries
          .where((entry) => identical(entry.value, owner))
          .take(2)
          .toList(growable: false);
      if (ownerSetupOperations.length == 1) {
        final setupToken = ownerSetupOperations.single.key;
        if (_pendingSetupSourceSessions[setupToken] != sessionId) {
          if (identical(owner, liveOwner)) {
            _cancelUnownedPermission(request);
            return;
          }
          operationToken = setupToken;
        }
      }
    }

    final requestId = request.id;
    if (requestId.trim().isEmpty) {
      _cancelUnownedPermission(request);
      return;
    }
    final existing = _permissionRequestOwners[requestId];
    if (existing == null &&
        _permissionRequestOwners.length >= _permissionOwnershipLimit) {
      _cancelUnownedPermission(request);
      return;
    }
    if (existing != null) {
      _revokePermissionBindingLocally(
        requestId,
        existing,
        AcpPermissionInvalidationReason.promptCancelled,
      );
    }
    _permissionRequestOwners.remove(requestId);
    _permissionRequestOwners[requestId] = _PermissionRequestBinding(
      owner: owner,
      sessionId: request.sessionId,
      lifecycleId: request.lifecycleId,
      operationToken: operationToken,
    );
    if (!owner._permissionRequests.isClosed) {
      owner._permissionRequests.add(request);
    }
  }

  void _dispatchPermissionInvalidation(AcpPermissionInvalidation event) {
    final deferred = _deferredPermissionRequests[event.requestId];
    if (deferred != null &&
        deferred.sessionId == event.sessionId &&
        deferred.lifecycleId == event.lifecycleId) {
      _deferredPermissionRequests.remove(event.requestId);
    }
    final queuedCancellation = _queuedCentralCancellations[event.requestId];
    if (queuedCancellation != null && queuedCancellation.matches(event)) {
      _queuedCentralCancellations.remove(event.requestId);
      final deferred = _deferredPermissionRequests.remove(event.requestId);
      if (deferred != null) _dispatchPermissionRequest(deferred);
    }
    final binding = _permissionRequestOwners[event.requestId];
    if (binding != null && binding.matches(event)) {
      _permissionRequestOwners.remove(event.requestId);
      final owner = binding.owner;
      if (_leases.contains(owner) &&
          !owner._disposed &&
          !owner._permissionInvalidations.isClosed) {
        owner._permissionInvalidations.add(event);
      }
      _maybeClosePermissionRequestLeaseStreams();
      return;
    }
    _maybeClosePermissionRequestLeaseStreams();
  }

  void _dispatchPermissionError(Object error, StackTrace stackTrace) {
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._permissionRequests.isClosed) {
        lease._permissionRequests.addError(error, stackTrace);
      }
    }
  }

  void _dispatchPermissionInvalidationError(
    Object error,
    StackTrace stackTrace,
  ) {
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._permissionInvalidations.isClosed) {
        lease._permissionInvalidations.addError(error, stackTrace);
      }
    }
  }

  void _closePermissionRequestStreams() {
    _permissionRequestsDone = true;
    for (final entry in _permissionRequestOwners.entries.toList(
      growable: false,
    )) {
      if (identical(_respondingPermissionBindings[entry.key], entry.value)) {
        continue;
      }
      _cancelPermissionBinding(entry.key, entry.value);
    }
    _maybeClosePermissionRequestLeaseStreams();
  }

  void _maybeClosePermissionRequestLeaseStreams() {
    if (!_permissionRequestsDone ||
        _permissionRequestOwners.isNotEmpty ||
        _respondingPermissionBindings.isNotEmpty ||
        _centralCancellationIds.isNotEmpty ||
        _queuedCentralCancellations.isNotEmpty ||
        _deferredPermissionRequests.isNotEmpty) {
      return;
    }
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._permissionRequests.isClosed) {
        unawaited(lease._permissionRequests.close());
      }
    }
  }

  void _closePermissionInvalidationStreams() {
    _permissionInvalidationsDone = true;
    if (!_permissionRequestsDone) _closePermissionRequestStreams();
    for (final lease in _leases.toList(growable: false)) {
      if (!lease._permissionInvalidations.isClosed) {
        unawaited(lease._permissionInvalidations.close());
      }
    }
  }

  void _cancelUnownedPermission(AcpPermissionRequest request) {
    _cancelPermissionRequest(request);
  }

  void _cancelPermissionRequest(AcpPermissionRequest request) {
    _cancelPermissionId(
      request.id,
      identity: _PermissionCancellationIdentity(
        id: request.id,
        sessionId: request.sessionId,
        lifecycleId: request.lifecycleId,
      ),
    );
  }

  void _cancelPermissionId(
    String id, {
    _PermissionCancellationIdentity? identity,
  }) {
    if (!_isBoundedIdentity(id) ||
        _respondingPermissionBindings.containsKey(id) ||
        _centralCancellationIds.contains(id) ||
        _queuedCentralCancellations.containsKey(id)) {
      return;
    }
    final cancellation = identity ?? _PermissionCancellationIdentity(id: id);
    if (_centralCancellationIds.length >= _centralCancellationLimit) {
      if (_queuedCentralCancellations.length < _centralCancellationQueueLimit) {
        _queuedCentralCancellations[id] = cancellation;
      }
      return;
    }
    _startCentralPermissionCancellation(id);
  }

  void _startCentralPermissionCancellation(String id) {
    if (!_centralCancellationIds.add(id)) return;
    unawaited(
      _runAgentOperation(
        () => _client.respondToPermissionRequest(
          id: id,
          decision: AcpPermissionDecision.cancel,
        ),
      ).catchError((Object _) {}).whenComplete(() {
        _centralCancellationIds.remove(id);
        final deferred = _deferredPermissionRequests.remove(id);
        if (deferred != null) _dispatchPermissionRequest(deferred);
        _drainCentralPermissionCancellations();
        _maybeClosePermissionRequestLeaseStreams();
      }),
    );
  }

  void _drainCentralPermissionCancellations() {
    while (_centralCancellationIds.length < _centralCancellationLimit &&
        _queuedCentralCancellations.isNotEmpty) {
      final id = _queuedCentralCancellations.keys.first;
      _queuedCentralCancellations.remove(id);
      _startCentralPermissionCancellation(id);
    }
    _maybeClosePermissionRequestLeaseStreams();
  }

  Future<void> _respondToPermissionRequest(
    _SessionScopedAgentClient lease, {
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    final binding = _permissionRequestOwners[id];
    if (binding == null || !identical(binding.owner, lease)) {
      throw StateError('Permission request $id is not owned by this lease.');
    }
    if (_terminalSessionOperations.contains(binding.normalizedSessionId)) {
      throw StateError('Session ${binding.normalizedSessionId} is closing.');
    }
    final pendingOwner = _pendingSessionOwners[binding.normalizedSessionId];
    if (pendingOwner != null && !identical(pendingOwner, lease)) {
      throw StateError(
        'Session ${binding.normalizedSessionId} is being handed off.',
      );
    }
    if (_respondingPermissionBindings.containsKey(id)) {
      throw StateError('Permission request $id is already being resolved.');
    }
    _respondingPermissionBindings[id] = binding;
    var responseSucceeded = false;
    try {
      await _runAgentOperation(() async {
        await _client.respondToPermissionRequest(
          id: id,
          decision: decision,
          selectedOptionId: selectedOptionId,
        );
        responseSucceeded = true;
        if (identical(_permissionRequestOwners[id], binding)) {
          _permissionRequestOwners.remove(id);
        }
      });
    } finally {
      if (identical(_respondingPermissionBindings[id], binding)) {
        _respondingPermissionBindings.remove(id);
      }
      if (!responseSucceeded) {
        if (_permissionRequestsDone &&
            identical(_permissionRequestOwners[id], binding)) {
          _cancelPermissionBinding(id, binding);
        } else if (!identical(_permissionRequestOwners[id], binding)) {
          _cancelPermissionId(
            id,
            identity: _PermissionCancellationIdentity.fromBinding(id, binding),
          );
        }
      }
      final deferred = _deferredPermissionRequests.remove(id);
      if (deferred != null) _dispatchPermissionRequest(deferred);
      _maybeClosePermissionRequestLeaseStreams();
    }
  }

  void _cancelPermissionBindingsForSession(
    String sessionId, {
    _SessionScopedAgentClient? preserveOwner,
    Object? preserveOperationToken,
  }) {
    for (final entry in _permissionRequestOwners.entries.toList(
      growable: false,
    )) {
      final binding = entry.value;
      if (binding.normalizedSessionId != sessionId) continue;
      if (preserveOwner != null &&
          identical(binding.owner, preserveOwner) &&
          identical(binding.operationToken, preserveOperationToken)) {
        continue;
      }
      _cancelPermissionBinding(entry.key, binding);
    }
  }

  void _cancelPermissionBinding(
    String requestId,
    _PermissionRequestBinding binding,
  ) {
    if (!identical(_permissionRequestOwners[requestId], binding)) return;
    _permissionRequestOwners.remove(requestId);
    _revokePermissionBindingLocally(
      requestId,
      binding,
      AcpPermissionInvalidationReason.sessionClosed,
    );
    _cancelPermissionId(
      requestId,
      identity: _PermissionCancellationIdentity.fromBinding(requestId, binding),
    );
  }

  void _revokePermissionBindingLocally(
    String requestId,
    _PermissionRequestBinding binding,
    AcpPermissionInvalidationReason reason,
  ) {
    final owner = binding.owner;
    if (!_leases.contains(owner) ||
        owner._disposed ||
        owner._permissionInvalidations.isClosed) {
      return;
    }
    owner._permissionInvalidations.add(
      AcpPermissionInvalidation(
        requestId: requestId,
        lifecycleId: binding.lifecycleId,
        sessionId: binding.sessionId,
        reason: reason,
        invalidatedAt: DateTime.now(),
      ),
    );
  }

  bool _isBoundedIdentity(String value) {
    if (value.length > _maxIdentityCodeUnits) return false;
    return value.trim().isNotEmpty;
  }

  Future<T> _runAgentOperation<T>(Future<T> Function() operation) async {
    _ensureAgentLifecycleAvailable();
    _activeAgentOperations += 1;
    try {
      return await operation();
    } finally {
      _activeAgentOperations -= 1;
      await _closeIfUnused();
    }
  }

  void _ensureAgentLifecycleAvailable() {
    if (_closed) throw StateError('ACP client pool is closed.');
    if (_logoutInProgress) {
      throw StateError('ACP agent logout is in progress.');
    }
  }

  Future<void> _logout(_SessionScopedAgentClient lease) async {
    if (!_leases.contains(lease)) {
      throw StateError('ACP client lease is disposed.');
    }
    if (_logoutInProgress) {
      throw StateError('ACP agent logout is already in progress.');
    }
    if (_activePromptOwners.isNotEmpty ||
        _pendingSessionOwners.isNotEmpty ||
        _activeAgentOperations != 0 ||
        _queuedSetupOperations != 0) {
      throw StateError(
        'ACP agent logout is unavailable while a shared session is active.',
      );
    }
    _logoutInProgress = true;
    try {
      await _client.logout();
      _sessionOwners.clear();
      _pendingSessionOwners.clear();
      _activePromptOwners.clear();
      _sessionOperationOwners.clear();
      _terminalSessionOperations.clear();
      _retiredSessionOwners.clear();
      _permissionRequestOwners.clear();
      _pendingSetupOperations.clear();
      _pendingSetupSourceSessions.clear();
      _pendingRestoreTokens.clear();
      _centralCancellationIds.clear();
      _queuedCentralCancellations.clear();
      _respondingPermissionBindings.clear();
      _deferredPermissionRequests.clear();
      for (final activeLease in _leases) {
        activeLease._handlePoolLogout();
      }
      if (!_lifecycleEvents.isClosed) {
        _lifecycleEvents.add(AcpAgentLifecycleEvent.loggedOut);
      }
    } finally {
      _logoutInProgress = false;
      await _closeIfUnused();
    }
  }

  Future<void> _release(_SessionScopedAgentClient lease) async {
    if (_leaseCount <= 0) return;
    for (final sessionId in lease._sessionIds.toList(growable: false)) {
      if (identical(_sessionOperationOwners[sessionId], lease)) continue;
      _unbind(lease, sessionId, retire: true);
    }
    _pendingSessionOwners.removeWhere(
      (sessionId, owner) =>
          identical(owner, lease) &&
          !identical(_sessionOperationOwners[sessionId], lease),
    );
    _pendingRestoreTokens.removeWhere(
      (sessionId, _) => !_pendingSessionOwners.containsKey(sessionId),
    );
    _activePromptOwners.removeWhere((_, owner) => identical(owner, lease));
    final setupTokens = _pendingSetupOperations.entries
        .where((entry) => identical(entry.value, lease))
        .map((entry) => entry.key)
        .toList(growable: false);
    for (final token in setupTokens) {
      _failProvisionalOperation(token);
    }
    for (final entry in _permissionRequestOwners.entries.toList(
      growable: false,
    )) {
      if (identical(entry.value.owner, lease)) {
        _cancelPermissionBinding(entry.key, entry.value);
      }
    }
    for (final sessionId in _retiredSessionOwners.keys.toList(
      growable: false,
    )) {
      if (identical(_retiredSessionOwners[sessionId], lease)) {
        _retiredSessionOwners[sessionId] = null;
      }
    }
    _leases.remove(lease);
    _leaseCount -= 1;
    await _closeIfUnused();
  }

  Future<void> _closeIfUnused() async {
    if (_leaseCount != 0 ||
        _activeAgentOperations != 0 ||
        _queuedSetupOperations != 0 ||
        _sessionOperationOwners.isNotEmpty ||
        _closed ||
        _logoutInProgress) {
      return;
    }
    _closed = true;
    unawaited(
      _permissionRequestsSubscription.cancel().catchError((Object _) {}),
    );
    unawaited(
      _permissionInvalidationsSubscription.cancel().catchError((Object _) {}),
    );
    await _client.dispose();
    await _lifecycleEvents.close();
  }
}

final class _SessionScopedAgentClient
    implements
        AcpAgentClient,
        AcpAgentLifecycleEventSource,
        AcpLocalSessionViewOwnership {
  _SessionScopedAgentClient(this._pool, this._client);

  final SessionScopedAgentClientPool _pool;
  final AcpAgentClient _client;
  final Set<String> _sessionIds = <String>{};
  final LinkedHashSet<String> _knownSessionIds = LinkedHashSet<String>();
  final StreamController<AcpPermissionRequest> _permissionRequests =
      StreamController<AcpPermissionRequest>.broadcast(sync: true);
  final StreamController<AcpPermissionInvalidation> _permissionInvalidations =
      StreamController<AcpPermissionInvalidation>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<AcpAgentLifecycleEvent> get lifecycleEvents =>
      _pool._lifecycleEvents.stream;

  @override
  AcpAgentCapabilities? get capabilities => _client.capabilities;

  @override
  bool get supportsConcurrentPrompts => _client.supportsConcurrentPrompts;

  @override
  Stream<AcpPermissionRequest> get permissionRequests =>
      _permissionRequests.stream;

  @override
  Stream<AcpPermissionInvalidation> get permissionInvalidations =>
      _permissionInvalidations.stream;

  @override
  Stream<AcpAvailableCommandsUpdate> get availableCommandsUpdates => _client
      .availableCommandsUpdates
      .where((update) => _receivesSession(update.sessionId));

  @override
  Future<AcpAvailableCommandsUpdate?> sessionAvailableCommands(
    String sessionId,
  ) async {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    try {
      _pool._claimSessionIfUnowned(this, normalizedSessionId);
    } on StateError {
      return null;
    }
    return _runOwnedSessionOperation(
      normalizedSessionId,
      () => _client.sessionAvailableCommands(normalizedSessionId),
    );
  }

  @override
  Future<void> connect() {
    _ensureOpen();
    return _pool._runAgentOperation(_client.connect);
  }

  @override
  Future<AgentSession> createSession({
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureOpen();
    return _pool._runSerializedSetup(this, (token) async {
      final session = await _client.createSession(
        cwd: cwd,
        additionalDirectories: additionalDirectories,
      );
      _ensureOpen();
      _bind(session.id);
      _pool._completeProvisionalOperation(
        token,
        _normalizedSessionId(session.id),
      );
      return session;
    });
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
    _pool._beginSessionOperation(this, normalizedSessionId);
    try {
      return await _pool._runAgentOperation(() async {
        final token = _pool._reserveRestore(this, normalizedSessionId);
        try {
          final summary = await _client.restoreSession(
            sessionId: normalizedSessionId,
            cwd: cwd,
            additionalDirectories: additionalDirectories,
            replayHistory: replayHistory,
            onEvent: onEvent,
          );
          _ensureOpen();
          _bind(normalizedSessionId, allowTransfer: true);
          _pool._completeProvisionalOperation(token, normalizedSessionId);
          return summary;
        } catch (_) {
          _pool._failProvisionalOperation(token);
          if (!_pool._sessionOwners.containsKey(normalizedSessionId)) {
            _pool._retireSession(normalizedSessionId, this);
          }
          rethrow;
        } finally {
          _pool._releaseRestoreReservation(this, normalizedSessionId);
        }
      });
    } finally {
      _pool._finishSessionOperation(this, normalizedSessionId);
    }
  }

  @override
  Future<List<AcpProjectSessions>> listSessions() {
    _ensureOpen();
    return _pool._runAgentOperation(_client.listSessions);
  }

  @override
  Future<AcpSessionSettings> sessionSettings(String sessionId) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSessionId);
    return _runOwnedSessionOperation(
      normalizedSessionId,
      () => _client.sessionSettings(normalizedSessionId),
    );
  }

  @override
  Future<bool> setSessionMode({
    required String sessionId,
    required String modeId,
  }) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSessionId);
    return _runOwnedSessionOperation(
      normalizedSessionId,
      () => _client.setSessionMode(
        sessionId: normalizedSessionId,
        modeId: modeId,
      ),
    );
  }

  @override
  Future<List<AcpConfigOption>> setConfigOption({
    required String sessionId,
    required String configId,
    required Object value,
  }) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSessionId);
    return _runOwnedSessionOperation(
      normalizedSessionId,
      () => _client.setConfigOption(
        sessionId: normalizedSessionId,
        configId: configId,
        value: value,
      ),
    );
  }

  @override
  Future<AgentSession> forkSession({
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) async {
    _ensureOpen();
    final normalizedSourceSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSourceSessionId);
    return _pool._runSerializedSetup(this, (token) async {
      _pool._claimSessionIfUnowned(this, normalizedSourceSessionId);
      _pool._beginSessionOperation(
        this,
        normalizedSourceSessionId,
        setupToken: token,
      );
      _pool._markProvisionalSourceSession(token, normalizedSourceSessionId);
      try {
        final session = await _client.forkSession(
          sessionId: normalizedSourceSessionId,
          cwd: cwd,
          additionalDirectories: additionalDirectories,
        );
        _ensureOpen();
        _bind(
          session.id,
          allowPreviousOperationSessionId: normalizedSourceSessionId,
        );
        _pool._completeProvisionalOperation(
          token,
          _normalizedSessionId(session.id),
        );
        return session;
      } finally {
        _pool._finishSessionOperation(this, normalizedSourceSessionId);
      }
    });
  }

  @override
  Future<void> closeSession({required String sessionId}) async {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSessionId);
    _pool._beginTerminalSessionOperation(this, normalizedSessionId);
    try {
      await _pool._runAgentOperation(() async {
        try {
          await _client.closeSession(sessionId: normalizedSessionId);
        } finally {
          _pool._unbind(this, normalizedSessionId, retire: true);
        }
      });
    } finally {
      _pool._finishTerminalSessionOperation(this, normalizedSessionId);
    }
  }

  @override
  Future<void> deleteSession({required String sessionId}) async {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    _pool._claimSessionIfUnowned(this, normalizedSessionId);
    _pool._beginTerminalSessionOperation(this, normalizedSessionId);
    try {
      await _pool._runAgentOperation(() async {
        await _client.deleteSession(sessionId: normalizedSessionId);
        _pool._unbind(this, normalizedSessionId, retire: true);
      });
    } finally {
      _pool._finishTerminalSessionOperation(this, normalizedSessionId);
    }
  }

  @override
  Future<void> authenticate({required String methodId}) {
    _ensureOpen();
    return _pool._runAgentOperation(
      () => _client.authenticate(methodId: methodId),
    );
  }

  @override
  Future<void> logout() {
    _ensureOpen();
    return _pool._logout(this);
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
    try {
      _pool._claimSessionIfUnowned(this, normalizedSessionId);
    } on Object catch (error, stackTrace) {
      return Stream<AgentEvent>.error(error, stackTrace);
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
    return _runOwnedSessionOperation(
      normalizedSessionId,
      () => _client.cancelSession(sessionId: normalizedSessionId),
      allowActivePrompt: true,
    );
  }

  @override
  Future<void> respondToPermissionRequest({
    required String id,
    required AcpPermissionDecision decision,
    String? selectedOptionId,
  }) async {
    _ensureOpen();
    await _pool._respondToPermissionRequest(
      this,
      id: id,
      decision: decision,
      selectedOptionId: selectedOptionId,
    );
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
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
    if (!_permissionRequests.isClosed) unawaited(_permissionRequests.close());
    if (!_permissionInvalidations.isClosed) {
      unawaited(_permissionInvalidations.close());
    }
  }

  void _bind(
    String sessionId, {
    bool allowTransfer = false,
    String? allowPreviousOperationSessionId,
  }) {
    _pool._bind(
      this,
      _normalizedSessionId(sessionId),
      allowTransfer: allowTransfer,
      allowPreviousOperationSessionId: allowPreviousOperationSessionId,
    );
  }

  void _handlePoolLogout() {
    _sessionIds.clear();
    _knownSessionIds.clear();
  }

  void _rememberSession(String sessionId) {
    _pool._knownSessionHistory.add(sessionId);
    _knownSessionIds.remove(sessionId);
    _knownSessionIds.add(sessionId);
    while (_knownSessionIds.length >
        SessionScopedAgentClientPool._knownSessionLimit) {
      _knownSessionIds.remove(_knownSessionIds.first);
    }
  }

  @override
  void retainLocalSessionView(String sessionId) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    final owner = _pool._sessionOwners[normalizedSessionId];
    if (owner != null && !identical(owner, this)) {
      throw StateError(
        'Session $normalizedSessionId is owned by another lease.',
      );
    }
    if (_pool._retiredSessionOwners.containsKey(normalizedSessionId)) {
      throw StateError('Session $normalizedSessionId is retired.');
    }
    if (owner == null &&
        !_knownSessionIds.contains(normalizedSessionId) &&
        _pool._retiredSessionHistory.mightContain(normalizedSessionId)) {
      throw StateError('Session $normalizedSessionId is retired.');
    }
    _rememberSession(normalizedSessionId);
  }

  @override
  void releaseLocalSessionView(String sessionId) {
    final normalizedSessionId = _normalizedSessionId(sessionId);
    if (!_pool._owns(this, normalizedSessionId)) {
      _knownSessionIds.remove(normalizedSessionId);
    }
  }

  @override
  void abandonLocalSessionView(String sessionId) {
    _ensureOpen();
    final normalizedSessionId = _normalizedSessionId(sessionId);
    if (_pool._owns(this, normalizedSessionId)) {
      _pool._unbind(this, normalizedSessionId, retire: true);
    } else {
      _knownSessionIds.remove(normalizedSessionId);
    }
  }

  Future<T> _runOwnedSessionOperation<T>(
    String sessionId,
    Future<T> Function() operation, {
    bool allowActivePrompt = false,
  }) async {
    _pool._beginSessionOperation(
      this,
      sessionId,
      allowActivePrompt: allowActivePrompt,
    );
    try {
      if (!_pool._owns(this, sessionId)) {
        throw StateError('Session $sessionId is not owned by this lease.');
      }
      return await _pool._runAgentOperation(operation);
    } finally {
      _pool._finishSessionOperation(this, sessionId);
    }
  }

  bool _receivesSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    final pendingOwner = _pool._pendingSessionOwners[normalizedSessionId];
    if (pendingOwner != null) return identical(pendingOwner, this);
    return _pool._owns(this, normalizedSessionId);
  }

  String _normalizedSessionId(String sessionId) {
    if (sessionId.length > SessionScopedAgentClientPool._maxIdentityCodeUnits) {
      throw ArgumentError.value(sessionId, 'sessionId');
    }
    final normalized = sessionId.trim();
    if (normalized.isEmpty) throw ArgumentError.value(sessionId, 'sessionId');
    return normalized;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('ACP client lease is disposed.');
  }
}

final class _PermissionRequestBinding {
  const _PermissionRequestBinding({
    required this.owner,
    required this.sessionId,
    required this.lifecycleId,
    required this.operationToken,
  });

  final _SessionScopedAgentClient owner;
  final String sessionId;
  final String lifecycleId;
  final Object? operationToken;

  String get normalizedSessionId => sessionId.trim();

  _PermissionRequestBinding promoted() {
    return _PermissionRequestBinding(
      owner: owner,
      sessionId: sessionId,
      lifecycleId: lifecycleId,
      operationToken: null,
    );
  }

  bool matches(AcpPermissionInvalidation event) {
    return event.sessionId == sessionId && event.lifecycleId == lifecycleId;
  }
}

final class _PermissionCancellationIdentity {
  const _PermissionCancellationIdentity({
    required this.id,
    this.sessionId,
    this.lifecycleId,
  });

  factory _PermissionCancellationIdentity.fromBinding(
    String id,
    _PermissionRequestBinding binding,
  ) {
    return _PermissionCancellationIdentity(
      id: id,
      sessionId: binding.sessionId,
      lifecycleId: binding.lifecycleId,
    );
  }

  final String id;
  final String? sessionId;
  final String? lifecycleId;

  bool matches(AcpPermissionInvalidation event) {
    return id == event.requestId &&
        sessionId == event.sessionId &&
        lifecycleId == event.lifecycleId;
  }
}

/// Fixed-memory conservative provenance for identities evicted from exact LRU
/// maps. Entries are never forgotten within one underlying Agent generation,
/// so a late session event cannot become a false negative after an LRU trim.
final class _BoundedIdentityBloomFilter {
  static const int _wordCount = 1 << 15;
  static const int _bitMask = (_wordCount * 32) - 1;
  static const List<int> _seeds = <int>[
    0x811c9dc5,
    0x9e3779b9,
    0x85ebca6b,
    0xc2b2ae35,
  ];

  final Uint32List _words = Uint32List(_wordCount);

  void add(String value) {
    for (final seed in _seeds) {
      final bit = _hash(value, seed) & _bitMask;
      _words[bit >> 5] |= 1 << (bit & 31);
    }
  }

  bool mightContain(String value) {
    for (final seed in _seeds) {
      final bit = _hash(value, seed) & _bitMask;
      if ((_words[bit >> 5] & (1 << (bit & 31))) == 0) return false;
    }
    return true;
  }

  int _hash(String value, int seed) {
    var hash = seed;
    for (var index = 0; index < value.length; index += 1) {
      hash = ((hash ^ value.codeUnitAt(index)) * 0x01000193) & 0xffffffff;
    }
    hash ^= hash >> 16;
    return hash & 0xffffffff;
  }
}
