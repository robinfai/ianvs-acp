import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import '../config.dart';
import 'inbound_gate.dart';

/// Alias for a JSON map used in requests/responses.
typedef Json = Map<String, dynamic>;

/// The first cause that made an ACP peer unavailable.
enum AcpPeerUnavailableReason {
  /// A fatal request or cleanup deadline expired.
  fatalTimeout,

  /// The underlying transport closed or failed.
  transportClosed,

  /// The peer was explicitly closed.
  explicitClose,

  /// The owning client was disposed.
  disposed,
}

/// Identifies prompt cleanup work owned by one generation.
final class AcpPromptCleanupIdentity {
  /// Creates an owner-scoped cleanup identity.
  const AcpPromptCleanupIdentity(this.ownerToken, this.generation);

  /// Identity token for the cleanup owner.
  final Object ownerToken;

  /// Generation of the cleanup owner.
  final int generation;
}

/// Immutable state published when an ACP peer becomes unavailable.
final class AcpPeerUnavailableState {
  /// Creates unavailable [reason] state with optional cleanup identity.
  const AcpPeerUnavailableState(this.reason, {this.cleanupIdentity});

  /// First reason that made the peer unavailable.
  final AcpPeerUnavailableReason reason;

  /// Fatal-timeout cleanup identity, when one exists.
  final AcpPromptCleanupIdentity? cleanupIdentity;
}

/// Receives the first unavailable state for an ACP peer.
typedef AcpPeerUnavailableListener =
    void Function(AcpPeerUnavailableState state);

/// Minimal identity required to bind a prompt request to its session owner.
abstract interface class JsonRpcPromptOwner {
  /// Session that owns the prompt request.
  String get sessionId;

  /// Monotonic generation of the prompt owner.
  int get generation;
}

/// Require an object-shaped JSON-RPC result without copying or traversing it.
Json requireJsonRpcObjectResult(Object? result, {required String resource}) {
  if (result is! Map) {
    throw FormatException('$resource must be a JSON object.');
  }
  if (result is Json) return result;
  return Map<String, dynamic>.from(result);
}

/// Thin wrapper around json_rpc_2.Peer with client handler hooks.
class JsonRpcPeer {
  /// Construct a peer bound to a [channel].
  JsonRpcPeer(
    StreamChannel<String> channel, {
    this.timeouts = const AcpTimeouts(),
    int maxPendingItems = 128,
    int maxPendingBytes = 32 * 1024 * 1024,
    int maxConcurrentHandlers = 16,
    int maxOrdinaryConcurrentHandlers = 14,
  }) : _gate = InboundGate(
         maxPendingItems: maxPendingItems,
         maxPendingBytes: maxPendingBytes,
         maxConcurrentHandlers: maxConcurrentHandlers,
         maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
       ) {
    timeouts.validate();
    _decodedSink = _JsonEncodingSink(
      channel.sink,
      prepare: _prepareCorrelationResponse,
      onCommitted: _finishCommittedCorrelations,
      onWriteRejected: _finishRejectedCorrelations,
    );
    _peer = rpc.Peer.withoutJson(
      StreamChannel<Object?>(_decodedIncoming.stream, _decodedSink),
    );
    _registerClientHandlers();
    unawaited(_listenToUnderlyingPeer());
    _inboundSubscription = channel.stream.listen(
      _handleInboundLine,
      onError: _handleInboundError,
      onDone: _handleInboundDone,
    );
  }

  /// Validated logical timeouts used by outbound requests.
  final AcpTimeouts timeouts;

  final InboundGate _gate;
  final StreamController<Object?> _decodedIncoming = StreamController<Object?>(
    sync: true,
  );
  final ListQueue<_DecodedDelivery> _decodedDeliveries =
      ListQueue<_DecodedDelivery>();
  final ListQueue<String> _deferredInboundLines = ListQueue<String>();
  final Map<String, _InboundCorrelation> _correlations =
      <String, _InboundCorrelation>{};
  final Set<AcpPeerUnavailableListener> _unavailableListeners =
      <AcpPeerUnavailableListener>{};
  final _OutboundRequestRegistry _outboundRequests = _OutboundRequestRegistry();

  /// Underlying JSON-RPC peer.
  late final rpc.Peer _peer;
  late final _JsonEncodingSink _decodedSink;
  late final StreamSubscription<String> _inboundSubscription;
  final StreamController<Object?> _sessionUpdates =
      StreamController<Object?>.broadcast(sync: true);
  _DispatchContext? _dispatchContext;
  _PendingTransportTermination? _pendingTransportTermination;
  AcpPeerUnavailableState? _unavailableState;
  Future<void>? _closeFuture;
  var _pendingTransportFinalizeScheduled = false;
  var _acceptingInbound = true;
  var _decodedIncomingClosed = false;
  var _sessionUpdatesClosed = false;
  var _dispatchingDecoded = false;
  var _dropDecodedDeliveries = false;
  var _terminalQueued = false;
  var _correlationWriteInProgress = false;
  var _correlationWriteEpoch = 0;
  var _drainingDeferredInbound = false;
  var _deferredInboundDrainScheduled = false;
  var _nextCorrelationId = 0;
  var _correlationPendingBytes = 0;

  @visibleForTesting
  int get correlationPendingItemsForTesting => _correlations.length;

  @visibleForTesting
  int get correlationPendingBytesForTesting => _correlationPendingBytes;

  @visibleForTesting
  int get inboundPendingItemsForTesting => _gate.pendingItems;

  @visibleForTesting
  Set<String> get correlationIdsForTesting =>
      Set<String>.unmodifiable(_correlations.keys);

  /// Whether the peer has not yet entered its unavailable state.
  bool get isAvailable => _closeFuture == null;

  Future<void> _listenToUnderlyingPeer() async {
    try {
      await _peer.listen();
    } on Object {
      try {
        await _becomeUnavailable(AcpPeerUnavailableReason.transportClosed);
      } on Object {
        // The public close owner retains the original cleanup failure.
      }
    }
  }

  /// Adds an unavailable listener, replaying existing state synchronously.
  void addUnavailableListener(AcpPeerUnavailableListener listener) {
    if (!_unavailableListeners.add(listener)) return;
    final state = _unavailableState;
    if (state != null) {
      try {
        listener(state);
      } on Object {
        // One listener cannot prevent replay to or cleanup by other owners.
      }
    }
  }

  /// Removes a previously added unavailable listener.
  void removeUnavailableListener(AcpPeerUnavailableListener listener) {
    _unavailableListeners.remove(listener);
  }

  /// Close the peer and clean up resources.
  Future<void> close() =>
      _becomeUnavailable(AcpPeerUnavailableReason.explicitClose);

  /// Dispose the peer and publish a disposed unavailable reason.
  Future<void> dispose() =>
      _becomeUnavailable(AcpPeerUnavailableReason.disposed);

  /// Close after a fatal timeout, optionally scoped to prompt cleanup.
  Future<void> closeForFatalTimeout({
    AcpPromptCleanupIdentity? cleanupIdentity,
  }) => _becomeUnavailable(
    AcpPeerUnavailableReason.fatalTimeout,
    cleanupIdentity: cleanupIdentity,
  );

  /// Close with a selected reason for unavailable lifecycle tests.
  @visibleForTesting
  Future<void> closeForTesting(AcpPeerUnavailableReason reason) =>
      _becomeUnavailable(reason);

  Future<void> _becomeUnavailable(
    AcpPeerUnavailableReason reason, {
    AcpPromptCleanupIdentity? cleanupIdentity,
  }) {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final closeOwner = Completer<void>.sync();
    final closeFuture = closeOwner.future;
    _closeFuture = closeFuture;
    _publishUnavailable(reason, closeOwner, cleanupIdentity: cleanupIdentity);
    return closeFuture;
  }

  void _publishUnavailable(
    AcpPeerUnavailableReason reason,
    Completer<void> closeOwner, {
    AcpPromptCleanupIdentity? cleanupIdentity,
  }) {
    final state = AcpPeerUnavailableState(
      reason,
      cleanupIdentity: cleanupIdentity,
    );
    _unavailableState = state;
    _decodedSink.disableWrites();
    final flushedRequests = _outboundRequests.completeConnectionClosed();
    _notifyUnavailableListeners(state);
    unawaited(_closeUnavailableResources(closeOwner));
    for (final operation in flushedRequests) {
      operation.publish();
    }
  }

  void _notifyUnavailableListeners(AcpPeerUnavailableState state) {
    for (final listener in _unavailableListeners.toList(growable: false)) {
      try {
        listener(state);
      } on Object {
        // Listener failures are isolated from peer shutdown and each other.
      }
    }
  }

  Future<void> _closeUnavailableResources(Completer<void> closeOwner) async {
    try {
      _acceptingInbound = false;
      _deferredInboundLines.clear();
      await _gate.close();
      _finishAllCorrelationsForPeerClose();
      await _closeUnderlyingPeerAfterGate();
      if (!closeOwner.isCompleted) closeOwner.complete();
    } on Object catch (error, stackTrace) {
      if (!closeOwner.isCompleted) {
        closeOwner.completeError(error, stackTrace);
      }
    }
  }

  Future<void> _closeUnderlyingPeerAfterGate() async {
    _dropDecodedDeliveries = true;
    final canceling = Future<void>.sync(_inboundSubscription.cancel);
    unawaited(canceling.catchError((Object _) {}));
    try {
      try {
        await _peer.close();
      } finally {
        try {
          await _closeDecodedIncoming();
        } finally {
          unawaited(_decodedSink.close());
        }
      }
    } finally {
      try {
        await canceling;
      } finally {
        await _closeSessionUpdates();
      }
    }
  }

  /// Stream of raw `session/update` notifications.
  Stream<Object?> get sessionUpdates => _sessionUpdates.stream;

  /// Injects a raw update for hostile-envelope route verification.
  @visibleForTesting
  void dispatchSessionUpdateForTesting(Object? envelope) {
    _dispatchSessionUpdate(envelope);
  }

  void _dispatchSessionUpdate(Object? envelope) {
    _sessionUpdates.add(envelope);
  }

  void _handleInboundLine(String line) {
    if (!_acceptingInbound) return;
    if (_correlationWriteInProgress) {
      _deferredInboundLines.addLast(line);
      return;
    }
    _processInboundLine(line);
  }

  void _processInboundLine(String line) {
    if (!_acceptingInbound) return;

    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _writeWireResponse(const <String, dynamic>{
        'jsonrpc': '2.0',
        'id': null,
        'error': <String, dynamic>{'code': -32700, 'message': 'Parse error.'},
      });
      return;
    } on Object catch (error, stackTrace) {
      _handleInboundError(error, stackTrace);
      return;
    }

    if (decoded is List && decoded.isEmpty) {
      _dispatchDecoded(_DecodedDelivery(decoded));
      return;
    }

    final elements = decoded is List ? decoded : <Object?>[decoded];
    final responses = <Object?>[];
    final requests = <Object?>[];
    for (final element in elements) {
      if (_isResponse(element)) {
        responses.add(element);
      } else {
        requests.add(element);
      }
    }

    if (responses.isNotEmpty) {
      _dispatchDecoded(
        _DecodedDelivery.response(
          decoded is List ? responses : responses.single,
        ),
      );
    }
    if (requests.isEmpty || !_acceptingInbound) return;

    _admitAndDispatchRequests(requests, wasBatch: decoded is List);
  }

  void _admitAndDispatchRequests(
    List<Object?> requests, {
    required bool wasBatch,
  }) {
    final gateElements = requests
        .map(
          (request) => InboundGateElement(
            method: _methodOf(request),
            byteLength: utf8.encode(jsonEncode(request)).length,
          ),
        )
        .toList(growable: false);
    final reservations = _gate.tryReserveBatch(gateElements);
    if (reservations == null) {
      _rejectForCapacity(requests, wasBatch: wasBatch);
      return;
    }
    final correlations = _reserveCorrelations(requests, reservations);
    if (correlations == null) {
      for (final reservation in reservations) {
        reservation.release();
      }
      _rejectForCapacity(requests, wasBatch: wasBatch);
      return;
    }
    final rewritten = _rewriteInboundCorrelationIds(
      requests,
      reservations,
      correlations,
    );
    try {
      _dispatchDecoded(
        _DecodedDelivery(
          wasBatch ? rewritten : rewritten.single,
          reservations: reservations,
        ),
      );
    } on Object {
      for (final correlation in correlations) {
        _finishCorrelation(correlation.internalId);
      }
      rethrow;
    }
  }

  List<_InboundCorrelation>? _reserveCorrelations(
    List<Object?> requests,
    List<InboundGateReservation> reservations,
  ) {
    final candidates = <_InboundCorrelation>[];
    var addedBytes = 0;
    for (var i = 0; i < requests.length; i += 1) {
      final request = requests[i];
      if (!_hasEchoableRequestId(request)) continue;
      final byteLength = utf8.encode(jsonEncode(request)).length;
      addedBytes += byteLength;
      candidates.add(
        _InboundCorrelation(
          internalId: '_acp_internal_${++_nextCorrelationId}',
          wireId: (request as Map)['id'],
          arrivalIdentity: Object(),
          canonicalByteLength: byteLength,
          reservation: reservations[i],
        ),
      );
    }
    if (_correlations.length + candidates.length > _gate.maxPendingItems ||
        _correlationPendingBytes + addedBytes > _gate.maxPendingBytes) {
      return null;
    }
    for (final entry in candidates) {
      _correlations[entry.internalId] = entry;
    }
    _correlationPendingBytes += addedBytes;
    return candidates;
  }

  List<Object?> _rewriteInboundCorrelationIds(
    List<Object?> requests,
    List<InboundGateReservation> reservations,
    List<_InboundCorrelation> correlations,
  ) {
    final byReservation =
        HashMap<InboundGateReservation, _InboundCorrelation>.identity();
    for (final correlation in correlations) {
      byReservation[correlation.reservation] = correlation;
    }
    return List<Object?>.generate(requests.length, (index) {
      final request = requests[index];
      final correlation = byReservation[reservations[index]];
      if (correlation == null) return request;
      return <Object?, Object?>{
        ...(request as Map),
        'id': correlation.internalId,
      };
    }, growable: false);
  }

  _PreparedCorrelationResponse _prepareCorrelationResponse(Object? event) {
    final ids = <String>[];
    Object? restore(Object? element) {
      if (element is! Map || !element.containsKey('id')) return element;
      final internalId = element['id'];
      if (internalId is! String) return element;
      final correlation = _correlations[internalId];
      if (correlation == null) return element;
      ids.add(internalId);
      return <Object?, Object?>{...element, 'id': correlation.wireId};
    }

    final wireValue = event is List
        ? event.map<Object?>(restore).toList(growable: false)
        : restore(event);
    if (ids.isNotEmpty) {
      _correlationWriteInProgress = true;
      _correlationWriteEpoch += 1;
    }
    return (wireValue: wireValue, internalIds: ids);
  }

  void _finishCommittedCorrelations(List<String> ids) {
    try {
      for (final id in ids) {
        _finishCorrelation(id);
      }
    } finally {
      _completeCorrelationWrite(ids);
    }
  }

  void _finishRejectedCorrelations(List<String> ids) {
    try {
      for (final id in ids) {
        _finishCorrelation(id);
      }
    } finally {
      _completeCorrelationWrite(ids);
    }
  }

  void _completeCorrelationWrite(List<String> ids) {
    if (ids.isEmpty) return;
    _correlationWriteInProgress = false;
    _drainDeferredInboundLines();
  }

  void _drainDeferredInboundLines() {
    if (!_acceptingInbound) {
      _deferredInboundLines.clear();
      return;
    }
    if (_drainingDeferredInbound) {
      _scheduleDeferredInboundDrain();
      return;
    }
    _drainingDeferredInbound = true;
    var enteredCorrelationWrite = false;
    try {
      if (_acceptingInbound &&
          !_correlationWriteInProgress &&
          _deferredInboundLines.isNotEmpty) {
        final writeEpochBefore = _correlationWriteEpoch;
        _processInboundLine(_deferredInboundLines.removeFirst());
        enteredCorrelationWrite = _correlationWriteEpoch != writeEpochBefore;
      }
    } finally {
      _drainingDeferredInbound = false;
    }
    if (enteredCorrelationWrite) return;
    if (_acceptingInbound &&
        !_correlationWriteInProgress &&
        _deferredInboundLines.isNotEmpty) {
      _scheduleDeferredInboundDrain();
    }
  }

  void _scheduleDeferredInboundDrain() {
    if (_deferredInboundDrainScheduled) return;
    _deferredInboundDrainScheduled = true;
    scheduleMicrotask(() {
      _deferredInboundDrainScheduled = false;
      _drainDeferredInboundLines();
    });
  }

  void _finishCorrelation(String internalId) {
    final entry = _correlations.remove(internalId);
    if (entry == null || entry.finished) return;
    entry.finished = true;
    _correlationPendingBytes -= entry.canonicalByteLength;
    if (!entry.responseCommitted.isCompleted) {
      entry.responseCommitted.complete();
    }
  }

  void _finishAllCorrelationsForPeerClose() {
    for (final id in _correlations.keys.toList(growable: false)) {
      _finishCorrelation(id);
    }
  }

  void _writeWireResponse(Object? response) {
    _decodedSink.addWireResponse(response);
  }

  void _dispatchDecoded(_DecodedDelivery delivery) {
    if (_dropDecodedDeliveries) {
      delivery.releaseUndelivered();
      return;
    }
    _decodedDeliveries.addLast(delivery);
    if (_dispatchingDecoded) return;
    _dispatchingDecoded = true;
    try {
      while (_decodedDeliveries.isNotEmpty) {
        final next = _decodedDeliveries.removeFirst();
        if (_dropDecodedDeliveries) {
          next.releaseUndelivered();
          continue;
        }
        if (_pendingTransportTermination != null && !next.isResponseOnly) {
          next.releaseUndelivered();
          for (final queued in _decodedDeliveries) {
            queued.releaseUndelivered();
          }
          _decodedDeliveries.clear();
          break;
        }
        if (!_acceptingInbound && next.reservations != null) {
          next.releaseUndelivered();
          continue;
        }
        _deliverDecoded(next);
      }
    } on Object {
      for (final queued in _decodedDeliveries) {
        queued.releaseUndelivered();
      }
      _decodedDeliveries.clear();
      rethrow;
    } finally {
      _dispatchingDecoded = false;
      _schedulePendingTransportFinalization();
    }
  }

  void _deliverDecoded(_DecodedDelivery delivery) {
    if (delivery.isTerminal) {
      if (_decodedIncomingClosed) return;
      final error = delivery.terminalError;
      if (error != null) {
        _decodedIncoming.addError(error, delivery.terminalStackTrace);
      }
      unawaited(_closeDecodedIncoming());
      return;
    }
    final reservations = delivery.reservations;
    if (reservations == null) {
      _decodedIncoming.add(delivery.message);
      return;
    }
    final previousContext = _dispatchContext;
    final context = _DispatchContext(reservations);
    _dispatchContext = context;
    var delivered = false;
    try {
      _decodedIncoming.add(delivery.message);
      delivered = true;
    } finally {
      if (delivered) {
        context.retainUnclaimed();
      } else {
        context.releaseUnused();
      }
      _dispatchContext = previousContext;
    }
  }

  static bool _isResponse(Object? element) =>
      element is Map &&
      (element.containsKey('result') || element.containsKey('error'));

  static String? _methodOf(Object? element) {
    if (element is! Map) return null;
    if (element['jsonrpc'] != '2.0') return null;
    final method = element['method'];
    if (method is! String) return null;
    if (element.containsKey('params')) {
      final params = element['params'];
      if (params is! List && params is! Map) return null;
    }
    final id = element['id'];
    if (id != null && id is! String && id is! num) return null;
    return method;
  }

  void _rejectForCapacity(List<Object?> requests, {required bool wasBatch}) {
    final errors = <Map<String, dynamic>>[];
    for (final request in requests) {
      if (!_hasEchoableRequestId(request)) continue;
      errors.add(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': (request as Map)['id'],
        'error': const <String, dynamic>{
          'code': -32000,
          'message': 'Inbound request capacity exceeded.',
        },
      });
    }
    if (errors.isEmpty) return;
    _writeWireResponse(wasBatch ? errors : errors.single);
  }

  static bool _hasEchoableRequestId(Object? value) {
    if (value is! Map || !value.containsKey('id')) return false;
    final id = value['id'];
    return id == null || id is String || id is num;
  }

  void _handleInboundError(Object error, StackTrace stackTrace) {
    if (_deferTransportTerminationDuringDispatch(
      error: error,
      stackTrace: stackTrace,
    )) {
      return;
    }
    final closing = _becomeUnavailable(
      AcpPeerUnavailableReason.transportClosed,
    );
    unawaited(closing.catchError((Object _) {}));
    _queueTerminal(error: error, stackTrace: stackTrace);
  }

  void _handleInboundDone() {
    if (_deferTransportTerminationDuringDispatch()) return;
    final closing = _becomeUnavailable(
      AcpPeerUnavailableReason.transportClosed,
    );
    unawaited(closing.catchError((Object _) {}));
    _queueTerminal();
  }

  bool _deferTransportTerminationDuringDispatch({
    Object? error,
    StackTrace? stackTrace,
  }) {
    if (_pendingTransportTermination != null) return true;
    if (!_dispatchingDecoded || _closeFuture != null) return false;
    final closeOwner = Completer<void>.sync();
    final closeFuture = closeOwner.future;
    _closeFuture = closeFuture;
    _pendingTransportTermination = _PendingTransportTermination(
      closeOwner: closeOwner,
      error: error,
      stackTrace: stackTrace,
    );
    final state = AcpPeerUnavailableState(
      AcpPeerUnavailableReason.transportClosed,
    );
    _unavailableState = state;
    _decodedSink.disableWrites();
    _stopRawAdmission();
    _notifyUnavailableListeners(state);
    _closeInboundGate();
    unawaited(
      closeFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return true;
  }

  void _schedulePendingTransportFinalization() {
    if (_pendingTransportTermination == null ||
        _pendingTransportFinalizeScheduled) {
      return;
    }
    _pendingTransportFinalizeScheduled = true;
    scheduleMicrotask(_finalizePendingTransportTermination);
  }

  void _finalizePendingTransportTermination() {
    _pendingTransportFinalizeScheduled = false;
    final pending = _pendingTransportTermination;
    if (pending == null) return;
    _pendingTransportTermination = null;
    final flushedRequests = _outboundRequests.completeConnectionClosed();
    unawaited(_closeUnavailableResources(pending.closeOwner));
    for (final operation in flushedRequests) {
      operation.publish();
    }
    _queueTerminal(error: pending.error, stackTrace: pending.stackTrace);
  }

  void _queueTerminal({Object? error, StackTrace? stackTrace}) {
    _stopAdmission();
    if (_terminalQueued || _decodedIncomingClosed) return;
    _terminalQueued = true;
    _dispatchDecoded(
      _DecodedDelivery.terminal(error: error, stackTrace: stackTrace),
    );
  }

  void _stopAdmission() {
    if (!_acceptingInbound) return;
    _stopRawAdmission();
    _closeInboundGate();
  }

  void _stopRawAdmission() {
    _acceptingInbound = false;
    _deferredInboundLines.clear();
  }

  void _closeInboundGate() => unawaited(_gate.close());

  Future<void> _closeDecodedIncoming() {
    if (_decodedIncomingClosed) return Future<void>.value();
    _decodedIncomingClosed = true;
    return _decodedIncoming.close();
  }

  Future<void> _closeSessionUpdates() {
    if (_sessionUpdatesClosed) return Future<void>.value();
    _sessionUpdatesClosed = true;
    return _sessionUpdates.close();
  }

  Future<T> _runInbound<T>(String method, FutureOr<T> Function() operation) {
    final context = _dispatchContext;
    final reservation = context?.take(method);
    if (reservation == null) {
      return Future<T>.error(
        StateError('Missing inbound reservation for $method.'),
      );
    }
    final running = reservation.run(operation);
    context!.track(running);
    return running;
  }

  T _runSessionUpdateSync<T>(T Function() operation) {
    final reservation = _dispatchContext?.take('session/update');
    if (reservation == null) {
      throw StateError('Missing inbound reservation for session/update.');
    }
    return reservation.runSync(operation);
  }

  void _registerClientHandlers() {
    _peer.registerMethod('session/update', (rpc.Parameters params) {
      return _runSessionUpdateSync(() {
        try {
          _dispatchSessionUpdate(params.value);
        } on Object {
          // Malformed envelopes and isolated routing failures are dropped.
        }
        return null;
      });
    });
    // The following methods are handled by higher-level wiring. We expose
    // registration points for them via onX setters.
    // Filesystem callbacks (Agent -> Client)
    _peer.registerMethod('fs/read_text_file', (rpc.Parameters params) {
      return _runInbound('fs/read_text_file', () {
        if (onReadTextFile == null) {
          throw rpc.RpcException.methodNotFound('fs/read_text_file');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onReadTextFile!(json);
      });
    });
    _peer.registerMethod('fs/write_text_file', (rpc.Parameters params) {
      return _runInbound('fs/write_text_file', () {
        if (onWriteTextFile == null) {
          throw rpc.RpcException.methodNotFound('fs/write_text_file');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onWriteTextFile!(json);
      });
    });
    // Permissioning (Agent -> Client)
    _peer.registerMethod('session/request_permission', (rpc.Parameters params) {
      return _runInbound('session/request_permission', () {
        if (onRequestPermission == null) {
          throw rpc.RpcException.methodNotFound('session/request_permission');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onRequestPermission!(json);
      });
    });
    // Terminal callbacks (Agent -> Client)
    _peer.registerMethod('terminal/create', (rpc.Parameters params) {
      return _runInbound('terminal/create', () {
        if (onTerminalCreate == null) {
          throw rpc.RpcException.methodNotFound('terminal/create');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onTerminalCreate!(json);
      });
    });
    _peer.registerMethod('terminal/output', (rpc.Parameters params) {
      return _runInbound('terminal/output', () {
        if (onTerminalOutput == null) {
          throw rpc.RpcException.methodNotFound('terminal/output');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onTerminalOutput!(json);
      });
    });
    _peer.registerMethod('terminal/wait_for_exit', (rpc.Parameters params) {
      return _runInbound('terminal/wait_for_exit', () {
        if (onTerminalWaitForExit == null) {
          throw rpc.RpcException.methodNotFound('terminal/wait_for_exit');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onTerminalWaitForExit!(json);
      });
    });
    _peer.registerMethod('terminal/kill', (rpc.Parameters params) {
      return _runInbound('terminal/kill', () {
        if (onTerminalKill == null) {
          throw rpc.RpcException.methodNotFound('terminal/kill');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onTerminalKill!(json);
      });
    });
    _peer.registerMethod('terminal/release', (rpc.Parameters params) {
      return _runInbound('terminal/release', () {
        if (onTerminalRelease == null) {
          throw rpc.RpcException.methodNotFound('terminal/release');
        }
        final json = Map<String, dynamic>.from(params.value as Map);
        return onTerminalRelease!(json);
      });
    });
    _peer.registerFallback((rpc.Parameters params) async {
      await _runInbound<void>(params.method, () async {
        await Future<void>.delayed(Duration.zero);
        throw rpc.RpcException.methodNotFound(params.method);
      });
    });
  }

  /// Client handlers (Agent -> Client callbacks)
  /// Handler invoked when agent requests `fs/read_text_file`.
  Future<dynamic> Function(Json)? onReadTextFile;

  /// Handler invoked when agent requests `fs/write_text_file`.
  Future<dynamic> Function(Json)? onWriteTextFile;

  /// Handler invoked when agent requests `session/request_permission`.
  Future<dynamic> Function(Json)? onRequestPermission;

  /// Handler invoked when agent requests `terminal/create`.
  Future<dynamic> Function(Json)? onTerminalCreate;

  /// Handler invoked when agent requests `terminal/output`.
  Future<dynamic> Function(Json)? onTerminalOutput;

  /// Handler invoked when agent requests `terminal/wait_for_exit`.
  Future<dynamic> Function(Json)? onTerminalWaitForExit;

  /// Handler invoked when agent requests `terminal/kill`.
  Future<dynamic> Function(Json)? onTerminalKill;

  /// Handler invoked when agent requests `terminal/release`.
  Future<dynamic> Function(Json)? onTerminalRelease;

  /// Send `initialize` and return the JSON payload.
  Future<Json> initialize(Json params) async => requireJsonRpcObjectResult(
    await _sendRequest('initialize', params),
    resource: 'JSON-RPC initialize result',
  );

  /// Send `session/new` and return the JSON payload.
  Future<Json> newSession(Json params) async => requireJsonRpcObjectResult(
    await _sendRequest('session/new', params),
    resource: 'JSON-RPC session/new result',
  );

  /// Send `session/load` for replay.
  Future<void> loadSession(Json params) async =>
      _sendRequest('session/load', params);

  /// Send `session/prompt` and return the terminal result payload.
  Future<Json> prompt(Json params) async {
    if (!isAvailable) throw const AcpConnectionClosedException();
    return requireJsonRpcObjectResult(
      await _peer.sendRequest('session/prompt', params),
      resource: 'JSON-RPC session/prompt result',
    );
  }

  /// Send an owner-bound prompt request without applying a prompt deadline.
  Future<Json> sendPromptRequest({
    required JsonRpcPromptOwner owner,
    required List<Map<String, dynamic>> content,
  }) async {
    final raw = await _sendRequest('session/prompt', <String, dynamic>{
      'sessionId': owner.sessionId,
      'prompt': content,
    }, promptOwner: owner);
    return requireJsonRpcObjectResult(
      raw,
      resource: 'JSON-RPC session/prompt result',
    );
  }

  /// Send `session/cancel` as a notification.
  Future<void> cancel(Json params) async =>
      _peer.sendNotification('session/cancel', params);

  /// (Extension) Send `session/set_mode` to change the session's mode.
  Future<void> setSessionMode(Json params) async =>
      _sendRequest('session/set_mode', params);

  /// Send an arbitrary JSON-RPC request by method name with params.
  Future<Json> sendRaw(String method, Json params) async {
    if (method == 'session/prompt') return prompt(params);
    return requireJsonRpcObjectResult(
      await _sendRequest(method, params),
      resource: 'JSON-RPC $method result',
    );
  }

  /// Send an arbitrary JSON-RPC notification by method name with params.
  Future<void> sendNotificationRaw(String method, Json params) async =>
      _peer.sendNotification(method, params);

  Future<Object?> _sendRequest(
    String method,
    Json params, {
    JsonRpcPromptOwner? promptOwner,
  }) {
    if (!isAvailable) {
      return Future<Object?>.error(const AcpConnectionClosedException());
    }
    if (method == 'session/prompt' && promptOwner == null) {
      return Future<Object?>.error(
        StateError('session/prompt requires an owner.'),
      );
    }

    final operation = _OutboundRequestOperation();
    _outboundRequests.add(operation);
    final settled = operation.result.future.whenComplete(() {
      operation.timer?.cancel();
      _outboundRequests.remove(operation);
    });
    final Duration? deadline = method == 'session/prompt'
        ? null
        : method == 'initialize'
        ? timeouts.initialize
        : timeouts.request;

    late final Future<Object?> raw;
    try {
      raw = _peer.sendRequest(method, params);
    } on Object catch (error, stackTrace) {
      operation.completeError(error, stackTrace);
      return settled;
    }
    unawaited(
      raw.then<void>(operation.completeValue, onError: operation.completeError),
    );

    if (deadline != null) {
      operation.timer = Timer(deadline, () {
        if (!operation.claimError(
          const AcpRequestTimeoutException(),
          StackTrace.current,
        )) {
          return;
        }
        try {
          final closing = closeForFatalTimeout();
          unawaited(
            closing.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
          );
        } on Object {
          // The request deadline remains the public first-wins terminal.
        } finally {
          operation.publish();
        }
      });
    }
    return settled;
  }
}

final class _OutboundRequestOperation {
  final Completer<Object?> result = Completer<Object?>();
  Timer? timer;
  Object? _value;
  Object? _error;
  StackTrace? _stackTrace;
  var _claimed = false;
  var _isError = false;
  var _published = false;

  bool get isCompleted => _claimed;

  void completeValue(Object? value) {
    if (claimValue(value)) publish();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (claimError(error, stackTrace)) publish();
  }

  bool claimValue(Object? value) {
    if (_claimed) return false;
    _claimed = true;
    _value = value;
    return true;
  }

  bool claimError(Object error, [StackTrace? stackTrace]) {
    if (_claimed) return false;
    _claimed = true;
    _isError = true;
    _error = error;
    _stackTrace = stackTrace;
    return true;
  }

  bool claimConnectionClosed() =>
      claimError(const AcpConnectionClosedException());

  void publish() {
    if (!_claimed || _published) return;
    _published = true;
    if (_isError) {
      result.completeError(_error!, _stackTrace);
    } else {
      result.complete(_value);
    }
  }
}

final class _OutboundRequestRegistry {
  final Set<_OutboundRequestOperation> _pending = <_OutboundRequestOperation>{};

  void add(_OutboundRequestOperation operation) => _pending.add(operation);

  void remove(_OutboundRequestOperation operation) =>
      _pending.remove(operation);

  List<_OutboundRequestOperation> completeConnectionClosed() {
    final claimed = <_OutboundRequestOperation>[];
    for (final operation in _pending.toList(growable: false)) {
      if (operation.claimConnectionClosed()) claimed.add(operation);
    }
    return claimed;
  }
}

final class _PendingTransportTermination {
  const _PendingTransportTermination({
    required this.closeOwner,
    this.error,
    this.stackTrace,
  });

  final Completer<void> closeOwner;
  final Object? error;
  final StackTrace? stackTrace;
}

class _DispatchContext {
  _DispatchContext(this.reservations)
    : _claimed = List<bool>.filled(reservations.length, false);

  final List<InboundGateReservation> reservations;
  final List<bool> _claimed;
  final List<Future<void>> _claimedSettled = <Future<void>>[];

  InboundGateReservation? take(String method) {
    for (var index = 0; index < reservations.length; index += 1) {
      if (_claimed[index]) continue;
      if (reservations[index].method == method) {
        _claimed[index] = true;
        return reservations[index];
      }
    }
    return null;
  }

  void track<T>(Future<T> running) {
    _claimedSettled.add(
      running.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void retainUnclaimed() {
    final barrier = Future.wait<void>(_claimedSettled, eagerError: false);
    for (var index = 0; index < reservations.length; index += 1) {
      if (_claimed[index]) continue;
      _claimed[index] = true;
      final retaining = reservations[index].run(() async {
        await barrier;
        await Future<void>.delayed(Duration.zero);
      });
      unawaited(retaining.catchError((Object _) {}));
    }
  }

  void releaseUnused() {
    for (var index = 0; index < reservations.length; index += 1) {
      if (!_claimed[index]) reservations[index].release();
    }
  }
}

class _DecodedDelivery {
  _DecodedDelivery(this.message, {this.reservations})
    : isTerminal = false,
      isResponseOnly = false,
      terminalError = null,
      terminalStackTrace = null;

  _DecodedDelivery.response(this.message)
    : reservations = null,
      isTerminal = false,
      isResponseOnly = true,
      terminalError = null,
      terminalStackTrace = null;

  _DecodedDelivery.terminal({Object? error, StackTrace? stackTrace})
    : message = null,
      reservations = null,
      isTerminal = true,
      isResponseOnly = false,
      terminalError = error,
      terminalStackTrace = stackTrace;

  final Object? message;
  final List<InboundGateReservation>? reservations;
  final bool isTerminal;
  final bool isResponseOnly;
  final Object? terminalError;
  final StackTrace? terminalStackTrace;

  void releaseUndelivered() {
    final held = reservations;
    if (held == null) return;
    for (final reservation in held) {
      reservation.release();
    }
  }
}

final class _InboundCorrelation {
  _InboundCorrelation({
    required this.internalId,
    required this.wireId,
    required this.arrivalIdentity,
    required this.canonicalByteLength,
    required this.reservation,
  });

  final String internalId;
  final Object? wireId;
  final Object arrivalIdentity;
  final int canonicalByteLength;
  final InboundGateReservation reservation;
  final Completer<void> responseCommitted = Completer<void>.sync();
  bool finished = false;
}

typedef _PreparedCorrelationResponse = ({
  Object? wireValue,
  List<String> internalIds,
});

final class _JsonEncodingSink implements StreamSink<Object?> {
  _JsonEncodingSink(
    this._sink, {
    required this.prepare,
    required this.onCommitted,
    required this.onWriteRejected,
  });

  final StreamSink<String> _sink;
  final _PreparedCorrelationResponse Function(Object? event) prepare;
  final void Function(List<String> ids) onCommitted;
  final void Function(List<String> ids) onWriteRejected;
  Future<void>? _closeFuture;
  bool _writesEnabled = true;

  void disableWrites() => _writesEnabled = false;

  @override
  Future<void> get done => _sink.done;

  @override
  void add(Object? event) {
    if (!_writesEnabled) return;
    final prepared = prepare(event);
    try {
      final encoded = jsonEncode(prepared.wireValue);
      _sink.add(encoded);
    } on Object {
      onWriteRejected(prepared.internalIds);
      rethrow;
    }
    onCommitted(prepared.internalIds);
  }

  void addWireResponse(Object? event) {
    if (!_writesEnabled) return;
    _sink.add(jsonEncode(event));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_writesEnabled) _sink.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    if (!_writesEnabled) return;
    await for (final event in stream) {
      if (!_writesEnabled) return;
      add(event);
    }
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _writesEnabled = false;
    final closing = Future<void>.sync(_sink.close);
    _closeFuture = closing;
    unawaited(closing.catchError((Object _) {}));
    return closing;
  }
}
