import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:stream_channel/stream_channel.dart';

import 'acp_endpoint_validator.dart';

typedef WebSocketFrameWriter =
    Future<void> Function(WebSocket socket, String frame);

class WebSocketAcpTransport implements acp.AcpTransport {
  WebSocketAcpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.onProtocolOut,
    this.onProtocolIn,
    Duration connectTimeout = const Duration(seconds: 10),
    int maxFrameBytes = acp.defaultTransportByteLimit,
    int maxInboundQueueItems = 128,
    int maxInboundQueueBytes = 32 * 1024 * 1024,
    int maxOutboundQueueItems = 128,
    int maxOutboundQueueBytes = 32 * 1024 * 1024,
    WebSocketFrameWriter? frameWriter,
  }) : connectTimeout = _positiveDuration(connectTimeout, 'connectTimeout'),
       maxFrameBytes = _positiveLimit(maxFrameBytes, 'maxFrameBytes'),
       maxInboundQueueItems = _positiveLimit(
         maxInboundQueueItems,
         'maxInboundQueueItems',
       ),
       maxInboundQueueBytes = _positiveLimit(
         maxInboundQueueBytes,
         'maxInboundQueueBytes',
       ),
       maxOutboundQueueItems = _positiveLimit(
         maxOutboundQueueItems,
         'maxOutboundQueueItems',
       ),
       maxOutboundQueueBytes = _positiveLimit(
         maxOutboundQueueBytes,
         'maxOutboundQueueBytes',
       ),
       _frameWriter = frameWriter ?? _writeFrame {
    validateAcpEndpoint(endpoint, allowedSchemes: const <String>{'ws', 'wss'});
  }

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;
  final Duration connectTimeout;
  final int maxFrameBytes;
  final int maxInboundQueueItems;
  final int maxInboundQueueBytes;
  final int maxOutboundQueueItems;
  final int maxOutboundQueueBytes;
  final WebSocketFrameWriter _frameWriter;

  final List<_QueuedFrame> _inboundQueue = <_QueuedFrame>[];
  final List<_QueuedFrame> _outboundQueue = <_QueuedFrame>[];

  WebSocket? _socket;
  StreamChannel<String>? _channel;
  StreamController<String>? _inboundController;
  StreamController<String>? _outboundController;
  StreamSubscription<Object?>? _socketSubscription;
  StreamSubscription<String>? _outboundSubscription;
  Completer<WebSocket>? _startCancellation;
  Completer<void>? _drainCancellation;
  _NoRedirectHttpClient? _handshakeClient;
  Future<void>? _outboundDrainFuture;
  Future<void>? _activeWrite;
  Future<void>? _stopFuture;
  int _startSerial = 0;
  int _inboundQueueBytes = 0;
  int _outboundQueueBytes = 0;
  bool _inboundListening = false;
  bool _inboundPaused = false;
  bool _outboundDraining = false;
  bool _stopping = false;
  bool _failed = false;
  bool _capacityCloseScheduled = false;

  @override
  StreamChannel<String> get channel {
    final channel = _channel;
    if (channel == null) throw StateError('Transport not started');
    return channel;
  }

  @override
  Future<void> start() async {
    for (;;) {
      final stopping = _stopFuture;
      if (stopping == null) break;
      await stopping;
    }
    if (_channel != null) return;
    if (_startCancellation != null) {
      throw StateError('Transport connection is already in progress.');
    }
    _resetQueues();
    _stopping = false;
    _failed = false;
    final serial = ++_startSerial;
    final handshakeClient = _NoRedirectHttpClient();
    _handshakeClient = handshakeClient;
    final connection =
        WebSocket.connect(
          endpoint.toString(),
          headers: headers.isEmpty ? null : headers,
          customClient: handshakeClient,
        ).whenComplete(() {
          if (identical(_handshakeClient, handshakeClient)) {
            _handshakeClient = null;
          }
          handshakeClient.close(force: true);
        });
    final cancellation = Completer<WebSocket>();
    _startCancellation = cancellation;
    WebSocket socket;
    try {
      socket = await Future.any<WebSocket>([
        connection,
        cancellation.future,
      ]).timeout(connectTimeout);
    } on Object {
      handshakeClient.close(force: true);
      unawaited(
        connection
            .then<void>((lateSocket) async {
              await lateSocket.close(WebSocketStatus.normalClosure);
            })
            .catchError((Object _) {}),
      );
      rethrow;
    } finally {
      if (identical(_startCancellation, cancellation)) {
        _startCancellation = null;
      }
    }
    if (serial != _startSerial) {
      await socket.close(WebSocketStatus.normalClosure);
      throw StateError('Transport was stopped while connecting.');
    }

    final inboundController = StreamController<String>(
      sync: true,
      onListen: _handleInboundListen,
      onPause: _handleInboundPause,
      onResume: _handleInboundResume,
      onCancel: _handleInboundCancel,
    );
    final outboundController = StreamController<String>(sync: true);
    _socket = socket;
    _inboundController = inboundController;
    _outboundController = outboundController;
    _channel = StreamChannel<String>(
      inboundController.stream,
      outboundController.sink,
    );
    _drainCancellation = Completer<void>();

    _socketSubscription = socket.listen(
      _handleSocketMessage,
      onError: (Object error, StackTrace stackTrace) {
        if (!_stopping) inboundController.addError(error, stackTrace);
      },
      onDone: _handleSocketDone,
    );
    _outboundSubscription = outboundController.stream.listen(
      _enqueueOutbound,
      onError: (Object error, StackTrace stackTrace) {
        if (!_stopping) inboundController.addError(error, stackTrace);
      },
      onDone: () {
        unawaited(_closeAfterOutboundDrain(socket));
      },
    );
  }

  void _handleSocketMessage(Object? message) {
    if (_stopping || _failed) return;
    if (message is String) {
      final bytes = utf8.encode(message).length;
      if (bytes > maxFrameBytes) {
        _failCapacity(
          resource: 'WebSocket text frame',
          limit: maxFrameBytes,
          observed: bytes,
        );
        return;
      }
      if (message.trim().isEmpty) return;
      _enqueueInbound(_QueuedFrame(message, bytes));
      return;
    }
    if (message is List<int> && message.length > maxFrameBytes) {
      _failCapacity(
        resource: 'WebSocket binary frame',
        limit: maxFrameBytes,
        observed: message.length,
      );
    }
    // Small binary frames remain intentionally ignored.
  }

  void _enqueueInbound(_QueuedFrame frame) {
    final observedItems = _inboundQueue.length + 1;
    final observedBytes = _inboundQueueBytes + frame.bytes;
    if (observedItems > maxInboundQueueItems) {
      _failCapacity(
        resource: 'WebSocket inbound queue items',
        limit: maxInboundQueueItems,
        observed: observedItems,
      );
      return;
    }
    if (observedBytes > maxInboundQueueBytes) {
      _failCapacity(
        resource: 'WebSocket inbound queue bytes',
        limit: maxInboundQueueBytes,
        observed: observedBytes,
      );
      return;
    }
    _inboundQueue.add(frame);
    _inboundQueueBytes = observedBytes;
    _drainInbound();
  }

  void _handleInboundListen() {
    _inboundListening = true;
    _inboundPaused = false;
    _drainInbound();
  }

  void _handleInboundPause() => _inboundPaused = true;

  void _handleInboundResume() {
    _inboundPaused = false;
    _drainInbound();
  }

  void _handleInboundCancel() {
    _inboundListening = false;
    _inboundPaused = true;
  }

  void _drainInbound() {
    final controller = _inboundController;
    if (controller == null ||
        !_inboundListening ||
        _inboundPaused ||
        _stopping ||
        _failed) {
      return;
    }
    while (_inboundQueue.isNotEmpty && !_inboundPaused && !_failed) {
      final frame = _inboundQueue.removeAt(0);
      _inboundQueueBytes -= frame.bytes;
      _notifyProtocolIn(frame.text);
      controller.add(frame.text);
    }
  }

  void _enqueueOutbound(String line) {
    if (_stopping || _failed) return;
    final bytes = utf8.encode(line).length;
    if (bytes > maxFrameBytes) {
      _failCapacity(
        resource: 'WebSocket outbound frame',
        limit: maxFrameBytes,
        observed: bytes,
      );
      return;
    }
    final observedItems = _outboundQueue.length + 1;
    final observedBytes = _outboundQueueBytes + bytes;
    if (observedItems > maxOutboundQueueItems) {
      _failCapacity(
        resource: 'WebSocket outbound queue items',
        limit: maxOutboundQueueItems,
        observed: observedItems,
      );
      return;
    }
    if (observedBytes > maxOutboundQueueBytes) {
      _failCapacity(
        resource: 'WebSocket outbound queue bytes',
        limit: maxOutboundQueueBytes,
        observed: observedBytes,
      );
      return;
    }
    _outboundQueue.add(_QueuedFrame(line, bytes));
    _outboundQueueBytes = observedBytes;
    _startOutboundDrain();
  }

  void _startOutboundDrain() {
    if (_outboundDraining || _outboundQueue.isEmpty) return;
    _outboundDraining = true;
    final future = _drainOutbound();
    _outboundDrainFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_outboundDrainFuture, future)) {
          _outboundDrainFuture = null;
        }
        _outboundDraining = false;
        if (!_stopping && !_failed && _outboundQueue.isNotEmpty) {
          _startOutboundDrain();
        }
      }),
    );
  }

  Future<void> _drainOutbound() async {
    final socket = _socket;
    final cancellation = _drainCancellation;
    if (socket == null || cancellation == null) return;
    while (_outboundQueue.isNotEmpty && !_stopping && !_failed) {
      final frame = _outboundQueue.first;
      _notifyProtocolOut(frame.text);
      final write = _frameWriter(socket, frame.text);
      _activeWrite = write;
      try {
        await Future.any<void>(<Future<void>>[write, cancellation.future]);
      } on Object catch (error, stackTrace) {
        if (!_stopping && !_failed) {
          _inboundController?.addError(error, stackTrace);
          _failed = true;
          _clearQueues();
        }
        return;
      }
      if (_stopping || _failed || cancellation.isCompleted) {
        unawaited(
          write
              .whenComplete(() {
                if (identical(_activeWrite, write)) _activeWrite = null;
              })
              .catchError((Object _) {}),
        );
        return;
      }
      if (identical(_activeWrite, write)) _activeWrite = null;
      if (_outboundQueue.isNotEmpty && identical(_outboundQueue.first, frame)) {
        _outboundQueue.removeAt(0);
        _outboundQueueBytes -= frame.bytes;
      }
    }
  }

  Future<void> _closeAfterOutboundDrain(WebSocket socket) async {
    try {
      await _outboundDrainFuture;
    } on Object {
      // The channel error path reports write failures.
    }
    if (!_stopping) await socket.close(WebSocketStatus.normalClosure);
  }

  void _failCapacity({
    required String resource,
    required int limit,
    required int observed,
  }) {
    if (_failed || _stopping) return;
    _failed = true;
    final error = acp.TransportByteLimitExceeded(
      resource: resource,
      limit: limit,
      observedAtLeast: observed,
    );
    _clearQueues();
    final cancellation = _drainCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    _inboundController?.addError(error, StackTrace.current);
    _scheduleCapacityClose();
  }

  void _scheduleCapacityClose() {
    if (_capacityCloseScheduled) return;
    final socket = _socket;
    if (socket == null) return;
    _capacityCloseScheduled = true;
    unawaited(() async {
      try {
        await socket.close(
          WebSocketStatus.messageTooBig,
          'transport capacity exceeded',
        );
        return;
      } on StateError {
        // addStream temporarily binds the sink. Retry once that write settles.
      } on Object {
        return;
      }
      final write = _activeWrite;
      if (write != null) {
        try {
          await write;
        } on Object {
          // Closing still owns final cleanup after a failed write.
        }
      }
      try {
        await socket.close(
          WebSocketStatus.messageTooBig,
          'transport capacity exceeded',
        );
      } on Object {
        // stop() forcefully completes local cleanup if the peer is gone.
      }
    }());
  }

  void _handleSocketDone() {
    _failed = true;
    _clearQueues();
    final cancellation = _drainCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
    unawaited(_outboundController?.close());
    unawaited(_inboundController?.close());
  }

  void _notifyProtocolIn(String line) {
    try {
      onProtocolIn?.call(line);
    } catch (error, stackTrace) {
      _inboundController?.addError(error, stackTrace);
    }
  }

  void _notifyProtocolOut(String line) {
    try {
      onProtocolOut?.call(line);
    } catch (error, stackTrace) {
      _inboundController?.addError(error, stackTrace);
    }
  }

  @override
  Future<void> stop() {
    final existing = _stopFuture;
    if (existing != null) return existing;
    final future = _stop();
    _stopFuture = future;
    unawaited(
      future
          .whenComplete(() {
            if (identical(_stopFuture, future)) _stopFuture = null;
          })
          .catchError((Object _) {}),
    );
    return future;
  }

  Future<void> _stop() async {
    _startSerial += 1;
    _stopping = true;
    final startCancellation = _startCancellation;
    _startCancellation = null;
    _handshakeClient?.close(force: true);
    _handshakeClient = null;
    if (startCancellation != null && !startCancellation.isCompleted) {
      startCancellation.completeError(
        StateError('Transport was stopped while connecting.'),
      );
    }
    final drainCancellation = _drainCancellation;
    if (drainCancellation != null && !drainCancellation.isCompleted) {
      drainCancellation.complete();
    }
    _clearQueues();

    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> cleanUp(Future<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await cleanUp(() async => _outboundSubscription?.cancel());
    _outboundSubscription = null;
    await cleanUp(() async => _socketSubscription?.cancel());
    _socketSubscription = null;
    await cleanUp(() async => _socket?.close(WebSocketStatus.normalClosure));
    _socket = null;
    await cleanUp(() async => _outboundDrainFuture);
    _outboundDrainFuture = null;
    await cleanUp(() async => _outboundController?.close());
    _outboundController = null;
    await cleanUp(() async {
      final controller = _inboundController;
      if (controller != null) unawaited(controller.close());
    });
    _inboundController = null;
    _channel = null;
    _drainCancellation = null;
    _activeWrite = null;
    _inboundListening = false;
    _inboundPaused = false;
    _failed = false;
    _capacityCloseScheduled = false;
    final cleanupError = firstError;
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, firstStackTrace!);
    }
  }

  void _resetQueues() {
    _clearQueues();
    _inboundListening = false;
    _inboundPaused = false;
    _outboundDraining = false;
    _capacityCloseScheduled = false;
  }

  void _clearQueues() {
    _inboundQueue.clear();
    _outboundQueue.clear();
    _inboundQueueBytes = 0;
    _outboundQueueBytes = 0;
  }

  static Future<void> _writeFrame(WebSocket socket, String frame) {
    return socket.addStream(Stream<Object?>.value(frame));
  }
}

Duration _positiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

int _positiveLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

class _QueuedFrame {
  const _QueuedFrame(this.text, this.bytes);

  final String text;
  final int bytes;
}

class _NoRedirectHttpClient implements HttpClient {
  _NoRedirectHttpClient() : _delegate = HttpClient();

  final HttpClient _delegate;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final request = await _delegate.openUrl(method, url);
    request.followRedirects = false;
    return request;
  }

  @override
  void close({bool force = false}) => _delegate.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'WebSocket handshake attempted an unsupported HttpClient operation.',
    );
  }
}
