import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/web_socket_acp_transport.dart';

void main() {
  test('websocket handshake does not follow redirects', () async {
    final redirectTarget = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    var targetRequests = 0;
    final targetSockets = <WebSocket>[];
    final targetSubscription = redirectTarget.listen((request) async {
      targetRequests += 1;
      final socket = await WebSocketTransformer.upgrade(request);
      targetSockets.add(socket);
      socket.listen((_) {});
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var originRequests = 0;
    final originSubscription = origin.listen((request) async {
      originRequests += 1;
      request.response
        ..statusCode = HttpStatus.temporaryRedirect
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${redirectTarget.port}/redirected',
        );
      await request.response.close();
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${origin.port}/acp'),
      connectTimeout: const Duration(seconds: 1),
    );

    try {
      await expectLater(transport.start(), throwsA(isA<WebSocketException>()));
      expect(originRequests, 1);
      expect(targetRequests, 0);
    } finally {
      await transport.stop();
      for (final socket in targetSockets) {
        await socket.close();
      }
      await originSubscription.cancel();
      await origin.close(force: true);
      await targetSubscription.cancel();
      await redirectTarget.close(force: true);
    }
  });

  test('websocket connection attempts time out', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    final serverSubscription = server.listen((_) {
      if (!requestStarted.isCompleted) requestStarted.complete();
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      connectTimeout: const Duration(milliseconds: 20),
    );

    try {
      final starting = transport.start();
      await requestStarted.future;

      await expectLater(starting, throwsA(isA<TimeoutException>()));
      expect(() => transport.channel, throwsStateError);
    } finally {
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('stop cancels a pending websocket handshake', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    final serverSubscription = server.listen((_) {
      if (!requestStarted.isCompleted) requestStarted.complete();
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      connectTimeout: const Duration(seconds: 5),
    );

    try {
      final starting = transport.start();
      await requestStarted.future;
      final startFailure = expectLater(starting, throwsStateError);

      await transport.stop();
      await startFailure.timeout(const Duration(seconds: 1));
      expect(() => transport.channel, throwsStateError);
    } finally {
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('a websocket that connects after timeout is closed', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requestStarted = Completer<void>();
    final releaseHandshake = Completer<void>();
    final serverSocket = Completer<WebSocket>();
    final socketClosed = Completer<void>();
    final serverSubscription = server.listen((request) async {
      if (!requestStarted.isCompleted) requestStarted.complete();
      await releaseHandshake.future;
      final socket = await WebSocketTransformer.upgrade(request);
      serverSocket.complete(socket);
      socket.listen(
        (_) {},
        onDone: () {
          if (!socketClosed.isCompleted) socketClosed.complete();
        },
      );
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      connectTimeout: const Duration(milliseconds: 20),
    );

    try {
      final starting = transport.start();
      await requestStarted.future;
      await expectLater(starting, throwsA(isA<TimeoutException>()));

      releaseHandshake.complete();
      await serverSocket.future.timeout(const Duration(seconds: 1));
      await socketClosed.future.timeout(const Duration(seconds: 1));
    } finally {
      if (!releaseHandshake.isCompleted) releaseHandshake.complete();
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

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

  test('oversized UTF-8 text frame closes with 1009 without payload', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSocket = Completer<WebSocket>();
    final peerClosed = Completer<int?>();
    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      serverSocket.complete(socket);
      socket.listen(
        (_) {},
        onDone: () => peerClosed.complete(socket.closeCode),
      );
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      maxFrameBytes: 4,
    );
    final messages = <String>[];
    final errors = <Object>[];

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        messages.add,
        onError: errors.add,
      );
      final socket = await serverSocket.future;
      socket.add('éésecret');

      expect(
        await peerClosed.future.timeout(const Duration(seconds: 2)),
        WebSocketStatus.messageTooBig,
      );
      await _waitFor(() => errors.isNotEmpty);
      expect(messages, isEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>().having(
          (error) => error.limit,
          'limit',
          4,
        ),
      );
      expect(errors.single.toString(), isNot(contains('secret')));
      await subscription.cancel();
    } finally {
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'small binary is ignored but oversized binary closes with 1009',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSocket = Completer<WebSocket>();
      final peerClosed = Completer<int?>();
      final serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        serverSocket.complete(socket);
        socket.listen(
          (_) {},
          onDone: () => peerClosed.complete(socket.closeCode),
        );
      });
      final transport = WebSocketAcpTransport(
        endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
        maxFrameBytes: 3,
      );
      final messages = <String>[];
      final errors = <Object>[];

      try {
        await transport.start();
        final subscription = transport.channel.stream.listen(
          messages.add,
          onError: errors.add,
        );
        final socket = await serverSocket.future;
        socket
          ..add(<int>[1, 2])
          ..add('ok');
        await _waitFor(() => messages.contains('ok'));
        expect(errors, isEmpty);

        socket.add(<int>[1, 2, 3, 4]);
        expect(
          await peerClosed.future.timeout(const Duration(seconds: 2)),
          WebSocketStatus.messageTooBig,
        );
        await _waitFor(() => errors.isNotEmpty);
        expect(errors.single, isA<acp.TransportByteLimitExceeded>());
        await subscription.cancel();
      } finally {
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('paused inbound consumer is bounded by item count', () async {
    await _expectInboundQueueLimit(
      maxItems: 1,
      maxBytes: 64,
      frames: const <String>['one', 'two'],
    );
  });

  test('paused inbound consumer is bounded by UTF-8 bytes', () async {
    await _expectInboundQueueLimit(
      maxItems: 8,
      maxBytes: 3,
      frames: const <String>['é', 'é'],
    );
  });

  test('outbound queue counts a pending write against item limit', () async {
    await _expectOutboundQueueLimit(maxItems: 1, maxBytes: 64);
  });

  test('outbound queue counts a pending write against byte limit', () async {
    await _expectOutboundQueueLimit(maxItems: 8, maxBytes: 3);
  });

  test(
    'stop cancels a pending outbound drain and drops queued frames',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSocket = Completer<WebSocket>();
      final releaseWrite = Completer<void>();
      final writesStarted = <String>[];
      final serverSubscription = server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        serverSocket.complete(socket);
        socket.listen((_) {});
      });
      final transport = WebSocketAcpTransport(
        endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
        frameWriter: (_, frame) async {
          writesStarted.add(frame);
          await releaseWrite.future;
        },
      );

      try {
        await transport.start();
        await serverSocket.future;
        transport.channel.sink
          ..add('first')
          ..add('second');
        await _waitFor(() => writesStarted.isNotEmpty);

        await transport.stop().timeout(const Duration(seconds: 1));
        expect(writesStarted, <String>['first']);
      } finally {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
        await transport.stop().timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('second transport.stop timed out'),
        );
        await serverSubscription.cancel().timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('server subscription timed out'),
        );
        await server
            .close(force: true)
            .timeout(
              const Duration(seconds: 2),
              onTimeout: () => throw StateError('server close timed out'),
            );
      }
    },
  );

  test('peer close cancels outbound drain and closes the sink', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSocket = Completer<WebSocket>();
    final releaseWrite = Completer<void>();
    final writesStarted = <String>[];
    final serverSubscription = server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      serverSocket.complete(socket);
      socket.listen((_) {});
    });
    final transport = WebSocketAcpTransport(
      endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
      frameWriter: (_, frame) async {
        writesStarted.add(frame);
        await releaseWrite.future;
      },
    );
    final inboundDone = Completer<void>();

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onDone: inboundDone.complete,
      );
      final socket = await serverSocket.future;
      transport.channel.sink
        ..add('first')
        ..add('second');
      await _waitFor(() => writesStarted.isNotEmpty);

      await socket.close(WebSocketStatus.normalClosure);
      await inboundDone.future.timeout(const Duration(seconds: 2));
      expect(() => transport.channel.sink.add('third'), throwsStateError);
      expect(writesStarted, <String>['first']);
      await subscription.cancel();
    } finally {
      if (!releaseWrite.isCompleted) releaseWrite.complete();
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _expectInboundQueueLimit({
  required int maxItems,
  required int maxBytes,
  required List<String> frames,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverSocket = Completer<WebSocket>();
  final peerClosed = Completer<int?>();
  final serverSubscription = server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    serverSocket.complete(socket);
    socket.listen((_) {}, onDone: () => peerClosed.complete(socket.closeCode));
  });
  final transport = WebSocketAcpTransport(
    endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
    maxInboundQueueItems: maxItems,
    maxInboundQueueBytes: maxBytes,
  );
  final messages = <String>[];
  final errors = <Object>[];

  try {
    await transport.start();
    final subscription = transport.channel.stream.listen(
      messages.add,
      onError: errors.add,
    );
    subscription.pause();
    final socket = await serverSocket.future;
    for (final frame in frames) {
      socket.add(frame);
    }

    expect(
      await peerClosed.future.timeout(const Duration(seconds: 2)),
      WebSocketStatus.messageTooBig,
    );
    subscription.resume();
    await _waitFor(() => errors.isNotEmpty);
    expect(messages, isEmpty);
    expect(errors.single, isA<acp.TransportByteLimitExceeded>());
    await subscription.cancel();
  } finally {
    await transport.stop();
    await serverSubscription.cancel();
    await server.close(force: true);
  }
}

Future<void> _expectOutboundQueueLimit({
  required int maxItems,
  required int maxBytes,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final serverSocket = Completer<WebSocket>();
  final peerClosed = Completer<int?>();
  final releaseWrite = Completer<void>();
  final writesStarted = <String>[];
  var allowSocketWrite = true;
  final serverSubscription = server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    serverSocket.complete(socket);
    socket.listen((_) {}, onDone: () => peerClosed.complete(socket.closeCode));
  });
  final transport = WebSocketAcpTransport(
    endpoint: Uri.parse('ws://127.0.0.1:${server.port}/acp'),
    maxOutboundQueueItems: maxItems,
    maxOutboundQueueBytes: maxBytes,
    frameWriter: (socket, frame) async {
      writesStarted.add(frame);
      await releaseWrite.future;
      if (allowSocketWrite && socket.readyState == WebSocket.open) {
        await socket.addStream(Stream<Object?>.value(frame));
      }
    },
  );
  final errors = <Object>[];

  try {
    await transport.start();
    await serverSocket.future;
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );
    transport.channel.sink
      ..add('ab')
      ..add('cd');

    await _waitFor(() => writesStarted.isNotEmpty);
    expect(
      await peerClosed.future.timeout(const Duration(seconds: 2)),
      WebSocketStatus.messageTooBig,
    );
    await _waitFor(() => errors.isNotEmpty);
    expect(writesStarted, <String>['ab']);
    expect(errors.single, isA<acp.TransportByteLimitExceeded>());
    await subscription.cancel();
  } finally {
    allowSocketWrite = false;
    if (!releaseWrite.isCompleted) releaseWrite.complete();
    await Future<void>.delayed(Duration.zero);
    await transport.stop();
    await serverSubscription.cancel();
    await server.close(force: true);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}
