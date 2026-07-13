import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
import 'package:meta/meta.dart';
import 'package:stream_channel/stream_channel.dart';

import 'inbound_gate.dart';

/// Alias for a JSON map used in requests/responses.
typedef Json = Map<String, dynamic>;

/// Require an object-shaped JSON-RPC result without copying or traversing it.
Json requireJsonRpcObjectResult(Object? result, {required String resource}) {
  if (result is Json) return result;
  throw FormatException('$resource must be a JSON object.');
}

/// Thin wrapper around json_rpc_2.Peer with client handler hooks.
class JsonRpcPeer {
  /// Construct a peer bound to a [channel].
  JsonRpcPeer(
    StreamChannel<String> channel, {
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
    _decodedSink = _JsonEncodingSink(channel.sink);
    _peer = rpc.Peer.withoutJson(
      StreamChannel<Object?>(_decodedIncoming.stream, _decodedSink),
    );
    _registerClientHandlers();
    // Start listening for messages; fire-and-forget intentionally.
    unawaited(() async {
      try {
        await _peer.listen();
      } on Object {
        // Pending requests receive the channel failure directly. The peer's
        // listener future must not report the same transport error again as
        // an unhandled asynchronous exception.
      }
    }());
    _inboundSubscription = channel.stream.listen(
      _handleInboundLine,
      onError: _handleInboundError,
      onDone: _handleInboundDone,
    );
  }

  final InboundGate _gate;
  final StreamController<Object?> _decodedIncoming = StreamController<Object?>(
    sync: true,
  );
  final ListQueue<_DecodedDelivery> _decodedDeliveries =
      ListQueue<_DecodedDelivery>();

  /// Underlying JSON-RPC peer.
  late final rpc.Peer _peer;
  late final _JsonEncodingSink _decodedSink;
  late final StreamSubscription<String> _inboundSubscription;
  final StreamController<Object?> _sessionUpdates =
      StreamController<Object?>.broadcast(sync: true);
  _DispatchContext? _dispatchContext;
  Future<void>? _closeFuture;
  var _acceptingInbound = true;
  var _decodedIncomingClosed = false;
  var _sessionUpdatesClosed = false;
  var _dispatchingDecoded = false;
  var _dropDecodedDeliveries = false;
  var _terminalQueued = false;

  /// Close the peer and clean up resources.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _dropDecodedDeliveries = true;
    _stopAdmission();
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

    Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      _decodedSink.add(const <String, dynamic>{
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
        _DecodedDelivery(decoded is List ? responses : responses.single),
      );
    }
    if (requests.isEmpty || !_acceptingInbound) return;

    final gateElements = requests
        .map(
          (element) => InboundGateElement(
            method: _methodOf(element),
            byteLength: utf8.encode(jsonEncode(element)).length,
          ),
        )
        .toList(growable: false);
    final reservations = _gate.tryReserveBatch(gateElements);
    if (reservations == null) {
      _rejectForCapacity(requests, wasBatch: decoded is List);
      return;
    }

    _dispatchDecoded(
      _DecodedDelivery(
        decoded is List ? requests : requests.single,
        reservations: reservations,
      ),
    );
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
      if (!_hasLegalRequestId(request)) continue;
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
    _decodedSink.add(wasBatch ? errors : errors.single);
  }

  static bool _hasLegalRequestId(Object? value) {
    if (value is! Map || !value.containsKey('id')) return false;
    if (value['jsonrpc'] != '2.0' || value['method'] is! String) return false;
    if (value.containsKey('params')) {
      final params = value['params'];
      if (params is! List && params is! Map) return false;
    }
    final id = value['id'];
    return id == null || id is String || id is num;
  }

  void _handleInboundError(Object error, StackTrace stackTrace) {
    _queueTerminal(error: error, stackTrace: stackTrace);
  }

  void _handleInboundDone() {
    _queueTerminal();
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
    _acceptingInbound = false;
    unawaited(_gate.close());
  }

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
    await _peer.sendRequest('initialize', params),
    resource: 'JSON-RPC initialize result',
  );

  /// Send `session/new` and return the JSON payload.
  Future<Json> newSession(Json params) async =>
      Map<String, dynamic>.from(await _peer.sendRequest('session/new', params));

  /// Send `session/load` for replay.
  Future<void> loadSession(Json params) async =>
      _peer.sendRequest('session/load', params);

  /// Send `session/prompt` and return the terminal result payload.
  Future<Json> prompt(Json params) async => Map<String, dynamic>.from(
    await _peer.sendRequest('session/prompt', params),
  );

  /// Send `session/cancel` as a notification.
  Future<void> cancel(Json params) async =>
      _peer.sendNotification('session/cancel', params);

  /// (Extension) Send `session/set_mode` to change the session's mode.
  Future<void> setSessionMode(Json params) async =>
      _peer.sendRequest('session/set_mode', params);

  /// Send an arbitrary JSON-RPC request by method name with params.
  Future<Json> sendRaw(String method, Json params) async =>
      requireJsonRpcObjectResult(
        await _peer.sendRequest(method, params),
        resource: 'JSON-RPC $method result',
      );

  /// Send an arbitrary JSON-RPC notification by method name with params.
  Future<void> sendNotificationRaw(String method, Json params) async =>
      _peer.sendNotification(method, params);
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
      terminalError = null,
      terminalStackTrace = null;

  _DecodedDelivery.terminal({Object? error, StackTrace? stackTrace})
    : message = null,
      reservations = null,
      isTerminal = true,
      terminalError = error,
      terminalStackTrace = stackTrace;

  final Object? message;
  final List<InboundGateReservation>? reservations;
  final bool isTerminal;
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

class _JsonEncodingSink implements StreamSink<Object?> {
  _JsonEncodingSink(this._sink);

  final StreamSink<String> _sink;
  Future<void>? _closeFuture;
  var _closed = false;

  @override
  Future<void> get done => _sink.done;

  @override
  void add(Object? event) {
    if (_closed) return;
    _sink.add(jsonEncode(event));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _sink.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<Object?> stream) {
    if (_closed) return Future<void>.value();
    return _sink.addStream(stream.map(jsonEncode));
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    final closing = Future<void>.sync(_sink.close);
    _closeFuture = closing;
    // json_rpc_2 closes its sink without awaiting the returned future. Attach
    // a handler immediately while preserving [closing] for explicit awaiters.
    unawaited(closing.catchError((Object _) {}));
    return closing;
  }
}
