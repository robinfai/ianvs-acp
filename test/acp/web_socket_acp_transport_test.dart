import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/web_socket_acp_transport.dart';

void main() {
  test('protocol callback failures do not block websocket traffic', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSocket = Completer<WebSocket>();
    final outboundMessages = <String>[];
    var disposed = false;

    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      if (!serverSocket.isCompleted) {
        serverSocket.complete(socket);
      }
      socket.listen((message) {
        if (message is String) {
          outboundMessages.add(message);
        }
      });
    });

    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      onProtocolIn: (_) => throw StateError('in capture failed'),
      onProtocolOut: (_) => throw StateError('out capture failed'),
    );
    final inboundMessages = <String>[];
    final transportErrors = <Object>[];

    try {
      await transport.start();
      final channel = transport.channel;
      final inboundSubscription = channel.stream.listen(
        inboundMessages.add,
        onError: transportErrors.add,
      );
      final socket = await serverSocket.future;

      socket.add('{"jsonrpc":"2.0","method":"inbound"}');
      channel.sink.add('{"jsonrpc":"2.0","method":"outbound"}');

      await _waitFor(
        () =>
            inboundMessages.isNotEmpty &&
            outboundMessages.isNotEmpty &&
            transportErrors.length >= 2,
      );

      expect(inboundMessages.single, contains('inbound'));
      expect(outboundMessages.single, contains('outbound'));
      expect(transportErrors.whereType<StateError>(), hasLength(2));

      await inboundSubscription.cancel();
      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      if (!disposed) {
        await transport.stop();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}
