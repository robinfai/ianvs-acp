import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:stream_channel/stream_channel.dart';

class WebSocketAcpTransport implements acp.AcpTransport {
  WebSocketAcpTransport({
    required this.endpoint,
    this.headers = const <String, String>{},
    this.onProtocolOut,
    this.onProtocolIn,
    this.connectTimeout = const Duration(seconds: 10),
  }) : assert(connectTimeout > Duration.zero);

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;
  final Duration connectTimeout;

  WebSocket? _socket;
  StreamChannelController<String>? _controller;
  StreamSubscription<Object?>? _socketSubscription;
  StreamSubscription<String>? _outboundSubscription;
  Completer<WebSocket>? _startCancellation;
  int _startSerial = 0;

  @override
  StreamChannel<String> get channel {
    final controller = _controller;
    if (controller == null) {
      throw StateError('Transport not started');
    }
    return controller.foreign;
  }

  @override
  Future<void> start() async {
    if (_controller != null) return;
    if (_startCancellation != null) {
      throw StateError('Transport connection is already in progress.');
    }
    final serial = ++_startSerial;
    final connection = WebSocket.connect(
      endpoint.toString(),
      headers: headers.isEmpty ? null : headers,
    );
    final cancellation = Completer<WebSocket>();
    _startCancellation = cancellation;
    WebSocket socket;
    try {
      socket = await Future.any<WebSocket>([
        connection,
        cancellation.future,
      ]).timeout(connectTimeout);
    } on Object {
      unawaited(
        connection.then<void>((lateSocket) async {
          await lateSocket.close(WebSocketStatus.normalClosure);
        }).catchError((Object _) {}),
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
    final controller = StreamChannelController<String>();
    _socket = socket;
    _controller = controller;

    _socketSubscription = socket.listen(
      (message) {
        if (message is! String || message.trim().isEmpty) return;
        _notifyProtocolIn(message);
        controller.local.sink.add(message);
      },
      onError: controller.local.sink.addError,
      onDone: () {
        unawaited(controller.local.sink.close());
      },
    );
    _outboundSubscription = controller.local.stream.listen(
      (line) {
        _notifyProtocolOut(line);
        socket.add(line);
      },
      onError: controller.local.sink.addError,
      onDone: () {
        unawaited(socket.close(WebSocketStatus.normalClosure));
      },
    );
  }

  void _notifyProtocolIn(String line) {
    try {
      onProtocolIn?.call(line);
    } catch (error, stackTrace) {
      _controller?.local.sink.addError(error, stackTrace);
    }
  }

  void _notifyProtocolOut(String line) {
    try {
      onProtocolOut?.call(line);
    } catch (error, stackTrace) {
      _controller?.local.sink.addError(error, stackTrace);
    }
  }

  @override
  Future<void> stop() async {
    _startSerial += 1;
    final startCancellation = _startCancellation;
    _startCancellation = null;
    if (startCancellation != null && !startCancellation.isCompleted) {
      startCancellation.completeError(
        StateError('Transport was stopped while connecting.'),
      );
    }
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
    await cleanUp(
      () async => _socket?.close(WebSocketStatus.normalClosure),
    );
    _socket = null;
    await cleanUp(() async => _controller?.local.sink.close());
    _controller = null;
    final cleanupError = firstError;
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, firstStackTrace!);
    }
  }
}
