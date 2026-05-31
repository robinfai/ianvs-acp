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
  });

  final Uri endpoint;
  final Map<String, String> headers;
  final void Function(String line)? onProtocolOut;
  final void Function(String line)? onProtocolIn;

  WebSocket? _socket;
  StreamChannelController<String>? _controller;
  StreamSubscription<Object?>? _socketSubscription;
  StreamSubscription<String>? _outboundSubscription;

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
    final socket = await WebSocket.connect(
      endpoint.toString(),
      headers: headers.isEmpty ? null : headers,
    );
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
    await _outboundSubscription?.cancel();
    _outboundSubscription = null;
    await _socketSubscription?.cancel();
    _socketSubscription = null;
    await _socket?.close(WebSocketStatus.normalClosure);
    _socket = null;
    await _controller?.local.sink.close();
    _controller = null;
  }
}
