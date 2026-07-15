import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/streamable_http_acp_transport.dart';

void main() {
  test('HTTP POST response body is bounded before UTF-8 decoding', () async {
    const secret = 'acp-secret-payload-must-not-appear';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{
            'connectionId': 'connection-1',
            'value': secret,
          },
        }),
      );
      request.response
        ..headers.contentType = ContentType.json
        ..add(bytes);
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      byteBudget: const acp.TransportByteBudget(maxBodyBytes: 24),
    );
    await transport.start();
    final inbound = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      inbound.add,
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, Object?>{},
        }),
      );
      await _waitFor(() => errors.isNotEmpty);

      expect(inbound, isEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having((value) => value.limit, 'limit', 24)
            .having(
              (value) => value.observedAtLeast,
              'observedAtLeast',
              greaterThan(24),
            ),
      );
      expect(errors.single.toString(), isNot(contains(secret)));
    } finally {
      await subscription.cancel();
      await transport.stop();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'HTTP POST malformed JSON reports a payload-free protocol error',
    () async {
      const secret = 'acp-post-malformed-secret';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","id":1,"result":"$secret"');
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => errors.isNotEmpty);

        expect(inbound, isEmpty);
        expect(errors.single, isA<acp.TransportProtocolDecodeError>());
        expect(errors.single.toString(), isNot(contains(secret)));
      } finally {
        await subscription.cancel();
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('HTTP POST body timeout cancels the remote response read', () async {
    final responseStarted = Completer<void>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      request.response
        ..bufferOutput = false
        ..headers.contentType = ContentType.json
        ..write('{"jsonrpc":');
      openResponses.add(request.response);
      await request.response.flush();
      if (!responseStarted.isCompleted) responseStarted.complete();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      requestTimeout: const Duration(milliseconds: 50),
    );
    await transport.start();
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await responseStarted.future.timeout(const Duration(seconds: 1));
      await _waitFor(() => errors.isNotEmpty);

      expect(errors.single, isA<acp.TransportBodyReadTimeout>());
      expect(transport.activeBodyReadCount, 0);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // The client cancellation can already own/close the response sink.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('stop cancels a pending POST body without reporting an error', () async {
    final responseStarted = Completer<void>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      request.response
        ..bufferOutput = false
        ..headers.contentType = ContentType.json
        ..write('{"jsonrpc":');
      openResponses.add(request.response);
      await request.response.flush();
      if (!responseStarted.isCompleted) responseStarted.complete();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      requestTimeout: const Duration(seconds: 10),
    );
    await transport.start();
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await responseStarted.future.timeout(const Duration(seconds: 1));
      await _waitFor(() => transport.activeBodyReadCount == 1);

      await transport.stop().timeout(const Duration(seconds: 1));

      expect(transport.activeBodyReadCount, 0);
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // The stopped client may already own the response sink.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('DELETE body timeout does not delay stop', () async {
    final deleteStarted = Completer<void>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.drain<void>();
        request.response
          ..bufferOutput = false
          ..statusCode = HttpStatus.accepted
          ..write('pending');
        openResponses.add(request.response);
        await request.response.flush();
        if (!deleteStarted.isCompleted) deleteStarted.complete();
        return;
      }
      if (request.method == 'GET') {
        request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(': connected\n\n');
        openResponses.add(request.response);
        await request.response.flush();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-1',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final inbound = <Map<String, dynamic>>[];
    final subscription = transport.channel.stream.listen((line) {
      inbound.add(jsonDecode(line) as Map<String, dynamic>);
    });

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.any((message) => message['id'] == 1));

      await transport.stop().timeout(const Duration(seconds: 3));

      await deleteStarted.future.timeout(const Duration(seconds: 1));
      expect(transport.activeBodyReadCount, 0);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // The timed-out client read may already own the response sink.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'HTTP SSE malformed JSON reports a payload-free protocol error',
    () async {
      const secret = 'acp-sse-malformed-secret';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final openResponses = <HttpResponse>[];
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response.bufferOutput = false;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          openResponses.add(request.response);
          request.response.write(
            'data: {"jsonrpc":"2.0","method":"$secret"\n\n',
          );
          await request.response.flush();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, Object?>;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, Object?>{'connectionId': 'connection-1'},
            }),
          );
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        await _waitFor(
          () =>
              errors.any((error) => error is acp.TransportProtocolDecodeError),
        );

        final error = errors
            .whereType<acp.TransportProtocolDecodeError>()
            .single;
        expect(error.toString(), isNot(contains(secret)));
        expect(inbound, hasLength(1));
      } finally {
        await subscription.cancel();
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'HTTP SSE invalid UTF-8 reports a payload-free protocol error',
    () async {
      const secret = 'acp-sse-invalid-utf8-secret';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.add(<int>[
            ...utf8.encode('data: {"jsonrpc":"2.0","method":"$secret'),
            0xff,
            ...utf8.encode('"}\n\n'),
          ]);
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, Object?>;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, Object?>{'connectionId': 'connection-1'},
            }),
          );
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        await _waitFor(() => errors.isNotEmpty);

        expect(errors.single, isA<acp.TransportProtocolDecodeError>());
        expect(errors.single.toString(), isNot(contains(secret)));
        expect(inbound, hasLength(1));
      } finally {
        await subscription.cancel();
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('HTTP SSE error drain timeout clears its read', () async {
    final responseStarted = Completer<void>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response
          ..bufferOutput = false
          ..statusCode = HttpStatus.internalServerError
          ..write('pending');
        openResponses.add(request.response);
        await request.response.flush();
        if (!responseStarted.isCompleted) responseStarted.complete();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, Object?>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, Object?>{'connectionId': 'connection-1'},
          }),
        );
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      requestTimeout: const Duration(milliseconds: 50),
    );
    await transport.start();
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await responseStarted.future.timeout(const Duration(seconds: 1));
      await _waitFor(
        () => errors.any((error) => error is acp.TransportBodyReadTimeout),
      );

      expect(
        errors.whereType<acp.TransportBodyReadTimeout>().single.resource,
        contains('SSE error response body'),
      );
      expect(transport.activeBodyReadCount, 0);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // The timed-out client read may already own the response sink.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('stop suppresses queued SSE data and errors', () async {
    final sseResponse = Completer<HttpResponse>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response.bufferOutput = false;
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        openResponses.add(request.response);
        request.response.write(': connected\n\n');
        await request.response.flush();
        sseResponse.complete(request.response);
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, Object?>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, Object?>{'connectionId': 'connection-1'},
          }),
        );
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final inbound = <Map<String, Object?>>[];
    final errors = <Object>[];
    Future<void>? stopFuture;
    final subscription = transport.channel.stream.listen((line) {
      final message = jsonDecode(line) as Map<String, Object?>;
      inbound.add(message);
      if (message['method'] == 'test/first') {
        stopFuture ??= transport.stop();
      }
    }, onError: errors.add);

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.any((message) => message['id'] == 1));
      final response = await sseResponse.future.timeout(
        const Duration(seconds: 1),
      );
      response.write(
        'data: {"jsonrpc":"2.0","method":"test/first"}\n\n'
        'data: {"jsonrpc":"2.0","method":"test/after-stop"}\n\n',
      );
      await response.flush();
      await _waitFor(() => stopFuture != null);
      await stopFuture!.timeout(const Duration(seconds: 1));

      expect(
        inbound
            .where((message) => message['method'] != null)
            .map((message) => message['method']),
        ['test/first'],
      );
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // The stopped client may already own the response sink.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'HTTP SSE line and event limits do not deliver partial events',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final openResponses = <HttpResponse>[];
      final connectionStream = Completer<HttpResponse>();
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response.bufferOutput = false;
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          openResponses.add(request.response);
          connectionStream.complete(request.response);
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, Object?>;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, Object?>{'connectionId': 'connection-1'},
            }),
          );
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        byteBudget: const acp.TransportByteBudget(
          maxBodyBytes: 512,
          maxLineBytes: 32,
          maxSseEventBytes: 256,
        ),
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        final response = await connectionStream.future;
        response.write(
          'data: {"jsonrpc":"2.0",\n'
          'data: "method":"partial-event-must-not-arrive"}\n\n',
        );
        await response.flush();
        await _waitFor(() => errors.isNotEmpty);

        expect(inbound, hasLength(1));
        expect(
          errors.last,
          isA<acp.TransportByteLimitExceeded>().having(
            (value) => value.resource,
            'resource',
            contains('line'),
          ),
        );
      } finally {
        await subscription.cancel();
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'HTTP SSE preserves CRLF multiline comments and final EOF event',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
          request.response.write(
            ': comment\r\n'
            'event: message\r\n'
            'data: {"jsonrpc":"2.0",\r\n'
            'data: "method":"eof-notice"}\r\n',
          );
          await request.response.close();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, Object?>;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, Object?>{'connectionId': 'connection-1'},
            }),
          );
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        byteBudget: const acp.TransportByteBudget(
          maxBodyBytes: 512,
          maxLineBytes: 128,
          maxSseEventBytes: 256,
        ),
      );
      await transport.start();
      final inbound = <Map<String, Object?>>[];
      final subscription = transport.channel.stream.listen(
        (line) => inbound.add(jsonDecode(line) as Map<String, Object?>),
        onError: (_) {},
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(
          () => inbound.any((message) => message['method'] == 'eof-notice'),
        );
        expect(
          inbound.where((message) => message['method'] == 'eof-notice'),
          hasLength(1),
        );
      } finally {
        await subscription.cancel();
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('HTTP POST does not follow redirects', () async {
    final redirectTarget = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    var targetRequests = 0;
    final targetSubscription = redirectTarget.listen((request) async {
      targetRequests += 1;
      request.response
        ..headers.contentType = ContentType.json
        ..write('{}');
      await request.response.close();
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var originRequests = 0;
    final originSubscription = origin.listen((request) async {
      originRequests += 1;
      await request.drain<void>();
      request.response
        ..statusCode = HttpStatus.seeOther
        ..headers.set(
          HttpHeaders.locationHeader,
          'http://127.0.0.1:${redirectTarget.port}/redirected',
        );
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${origin.port}/acp'),
      requestTimeout: const Duration(seconds: 1),
      firstByteTimeout: const Duration(seconds: 1),
    );
    await transport.start();
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(() => errors.isNotEmpty);

      expect(originRequests, 1);
      expect(targetRequests, 0);
      expect(
        errors.single,
        isA<HttpException>().having(
          (error) => error.message,
          'message',
          contains('303'),
        ),
      );
    } finally {
      await subscription.cancel();
      await transport.stop();
      await originSubscription.cancel();
      await origin.close(force: true);
      await targetSubscription.cancel();
      await redirectTarget.close(force: true);
    }
  });

  test('HTTP SSE GET and teardown DELETE do not follow redirects', () async {
    final redirectTarget = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final targetMethods = <String>[];
    final targetSubscription = redirectTarget.listen((request) async {
      targetMethods.add(request.method);
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    });
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final originMethods = <String>[];
    final originSubscription = origin.listen((request) async {
      originMethods.add(request.method);
      if (request.method == 'POST') {
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else {
        request.response
          ..statusCode = HttpStatus.temporaryRedirect
          ..headers.set(
            HttpHeaders.locationHeader,
            'http://127.0.0.1:${redirectTarget.port}/redirected',
          );
      }
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${origin.port}/acp'),
      requestTimeout: const Duration(seconds: 1),
      firstByteTimeout: const Duration(seconds: 1),
    );
    await transport.start();
    final inbound = <Map<String, dynamic>>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      (line) => inbound.add(jsonDecode(line) as Map<String, dynamic>),
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(() => inbound.any((message) => message['id'] == 1));
      await _waitFor(() => originMethods.contains('GET'));
      await _waitFor(() => errors.isNotEmpty);

      expect(targetMethods, isEmpty);
      expect(errors.single, isA<HttpException>());

      await transport.stop();
      await _waitFor(() => originMethods.contains('DELETE'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(targetMethods, isEmpty);
    } finally {
      await subscription.cancel();
      await transport.stop();
      await originSubscription.cancel();
      await origin.close(force: true);
      await targetSubscription.cancel();
      await redirectTarget.close(force: true);
    }
  });

  test('session setup errors clear pending HTTP response routes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final sessionStreamOpened = Completer<String>();
    final connectionStream = Completer<HttpResponse>();
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      final sessionId = request.headers.value('Acp-Session-Id');
      if (sessionId == null && !connectionStream.isCompleted) {
        connectionStream.complete(request.response);
      } else if (sessionId != null && !sessionStreamOpened.isCompleted) {
        sessionStreamOpened.complete(sessionId);
      }
    }

    Future<void> sendSse(Map<String, dynamic> message) async {
      final response = await connectionStream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (message['method'] == 'session/new') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'error': <String, dynamic>{
              'code': -32000,
              'message': 'session setup failed',
            },
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    });

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'setup-id',
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any(
          (message) =>
              message['id'] == 'setup-id' && message.containsKey('error'),
        ),
      );

      await sendSse(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'setup-id',
        'result': <String, dynamic>{'sessionId': 'stale-session'},
      });

      await expectLater(
        sessionStreamOpened.future.timeout(const Duration(milliseconds: 150)),
        throwsA(isA<TimeoutException>()),
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('unexpected session SSE closure is reported', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final sessionStream = Completer<HttpResponse>();
    final promptAccepted = Completer<void>();
    var disposed = false;

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response.bufferOutput = false;
        request.response.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.response.write(': connected\n\n');
        await request.response.flush();
        openResponses.add(request.response);
        if (request.headers.value('Acp-Session-Id') == 'session-1' &&
            !sessionStream.isCompleted) {
          sessionStream.complete(request.response);
        }
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (message['method'] == 'session/new') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'sessionId': 'session-1'},
          }),
        );
      } else if (message['method'] == 'session/prompt') {
        request.response.statusCode = HttpStatus.accepted;
        if (!promptAccepted.isCompleted) promptAccepted.complete();
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 2),
      );
      final sessionResponse = await sessionStream.future.timeout(
        const Duration(seconds: 2),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'session/prompt',
          'params': <String, dynamic>{'sessionId': 'session-1'},
        }),
      );
      await promptAccepted.future.timeout(const Duration(seconds: 2));
      await sessionResponse.close();

      await _waitFor(() => transportErrors.isNotEmpty);
      expect(transportErrors.last, isA<StateError>());

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('session setup opens SSE stream for snake case session ids', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final sessionStreamOpened = Completer<String>();
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      final sessionId = request.headers.value('Acp-Session-Id');
      if (sessionId != null && !sessionStreamOpened.isCompleted) {
        sessionStreamOpened.complete(sessionId);
      }
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (message['method'] == 'session/new') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'session_id': 'snake-session'},
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    });

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'setup-id',
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 'setup-id'),
      );

      expect(
        await sessionStreamOpened.future.timeout(const Duration(seconds: 2)),
        'snake-session',
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('session setup HTTP failures clear pending response routes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final sessionStreamOpened = Completer<String>();
    final connectionStream = Completer<HttpResponse>();
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      final sessionId = request.headers.value('Acp-Session-Id');
      if (sessionId == null && !connectionStream.isCompleted) {
        connectionStream.complete(request.response);
      } else if (sessionId != null && !sessionStreamOpened.isCompleted) {
        sessionStreamOpened.complete(sessionId);
      }
    }

    Future<void> sendSse(Map<String, dynamic> message) async {
      final response = await connectionStream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (message['method'] == 'session/new') {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write('session setup exploded');
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'setup-id',
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(() => transportErrors.isNotEmpty);

      await sendSse(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'setup-id',
        'result': <String, dynamic>{'sessionId': 'stale-session'},
      });

      await expectLater(
        sessionStreamOpened.future.timeout(const Duration(milliseconds: 150)),
        throwsA(isA<TimeoutException>()),
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('invalid SSE JSON is reported without closing the stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final connectionStream = Completer<HttpResponse>();
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (request.headers.value('Acp-Session-Id') == null &&
          !connectionStream.isCompleted) {
        connectionStream.complete(request.response);
      }
    }

    Future<void> sendSseData(String data) async {
      final response = await connectionStream.future;
      response
        ..write('event: message\n')
        ..write('data: $data\n\n');
      await response.flush();
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      const malformedSecret = 'invalid-sse-history-secret';
      await sendSseData('{"secret":"$malformedSecret"');
      await _waitFor(() => transportErrors.isNotEmpty);

      await sendSseData(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'method': '_agent_ping',
          'params': <String, dynamic>{'ok': true},
        }),
      );
      await _waitFor(
        () => inboundMessages.any(
          (message) => message['method'] == '_agent_ping',
        ),
      );

      expect(transportErrors.single, isA<acp.TransportProtocolDecodeError>());
      expect(
        transportErrors.single.toString(),
        isNot(contains(malformedSecret)),
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('protocol callback failures do not block HTTP traffic', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final outboundLines = <String>[];
    final inboundLines = <String>[];
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-1',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      onProtocolOut: (line) {
        outboundLines.add(line);
        throw StateError('out callback failed');
      },
      onProtocolIn: (line) {
        inboundLines.add(line);
        throw StateError('in callback failed');
      },
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );

      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );
      await _waitFor(() => transportErrors.length >= 2);

      expect(outboundLines, hasLength(1));
      expect(inboundLines, hasLength(1));
      expect(
        transportErrors.whereType<StateError>().map((error) => error.message),
        containsAll(<String>['out callback failed', 'in callback failed']),
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('transport can restart after stop', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final initializeIds = <Object?>[];
    final initializeCookies = <String?>[];
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      initializeIds.add(message['id']);
      initializeCookies.add(request.headers.value(HttpHeaders.cookieHeader));
      if (message['id'] == 1) {
        request.response.cookies.add(Cookie('restart', 'must-clear'));
      }
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-${message['id']}')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-${message['id']}',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );

    Future<void> initialize(int id) async {
      final inboundMessages = <Map<String, dynamic>>[];
      final transportErrors = <Object>[];

      await transport.start();
      final channel = transport.channel;
      final inboundSubscription = channel.stream.listen((line) {
        inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
      }, onError: transportErrors.add);
      try {
        channel.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': 'initialize',
            'params': <String, dynamic>{},
          }),
        );

        await _waitFor(
          () => inboundMessages.any((message) => message['id'] == id),
        );

        expect(transportErrors, isEmpty);
      } finally {
        await inboundSubscription.cancel();
      }
    }

    try {
      await initialize(1);
      await transport.stop().timeout(const Duration(seconds: 5));
      await initialize(2);

      expect(initializeIds, [1, 2]);
      expect(initializeCookies, <String?>[null, null]);

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('stop tolerates inbound streams ending during teardown', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final openedSessionStreams = <String?>[];
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      final sessionId = request.headers.value('Acp-Session-Id');
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      openedSessionStreams.add(sessionId);
    }

    Future<void> closeOpenResponses() async {
      for (final response in List<HttpResponse>.of(openResponses)) {
        await response.close();
      }
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        unawaited(closeOpenResponses());
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      final method = message['method'];
      final Object? id = message['id'];
      request.response.headers.contentType = ContentType.json;
      if (method == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': id,
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (method == 'session/new') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{'sessionId': 'session-a'},
          }),
        );
      } else if (method == 'session/fork') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'result': <String, dynamic>{'sessionId': 'session-b'},
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 2),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'session/fork',
          'params': <String, dynamic>{'sessionId': 'session-a'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 3),
      );
      await _waitFor(
        () =>
            openedSessionStreams.contains(null) &&
            openedSessionStreams.contains('session-a') &&
            openedSessionStreams.contains('session-b'),
      );

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;

      expect(transportErrors, isEmpty);
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      await closeOpenResponses();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('closed session SSE streams reopen for later session traffic', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final firstSessionStream = Completer<HttpResponse>();
    final secondSessionStream = Completer<HttpResponse>();
    var sessionStreamCount = 0;
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);

      if (request.headers.value('Acp-Session-Id') == 'session-1') {
        sessionStreamCount += 1;
        if (sessionStreamCount == 1 && !firstSessionStream.isCompleted) {
          firstSessionStream.complete(request.response);
        } else if (sessionStreamCount == 2 &&
            !secondSessionStream.isCompleted) {
          secondSessionStream.complete(request.response);
        }
      }
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response.headers.contentType = ContentType.json;
      if (message['method'] == 'initialize') {
        request.response
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else if (message['method'] == 'session/new') {
        request.response.write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{'sessionId': 'session-1'},
          }),
        );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'new-session',
          'method': 'session/new',
          'params': <String, dynamic>{'cwd': '/workspace'},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 'new-session'),
      );
      final firstStream = await firstSessionStream.future.timeout(
        const Duration(seconds: 2),
      );
      await firstStream.close();
      await _waitFor(() => transportErrors.isNotEmpty);
      expect(transportErrors.single, isA<StateError>());

      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'prompt-1',
          'method': 'session/prompt',
          'params': <String, dynamic>{
            'sessionId': 'session-1',
            'prompt': <Map<String, dynamic>>[],
          },
        }),
      );

      await secondSessionStream.future.timeout(const Duration(seconds: 2));
      expect(sessionStreamCount, 2);

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        try {
          await response.close();
        } on Object {
          // Some streams are intentionally closed during the test.
        }
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('connection SSE startup failures are reported once', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    var disposed = false;

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-1',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );

      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );
      await _waitFor(() => transportErrors.isNotEmpty);

      expect(transportErrors.single, isA<HttpException>());

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('server request session ids are consumed for HTTP responses', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final outboundMessages = <Map<String, dynamic>>[];
    final outboundSessionHeaders = <String?>[];
    final connectionStream = Completer<HttpResponse>();
    var disposed = false;

    Future<void> openSse(HttpRequest request) async {
      request.response.bufferOutput = false;
      request.response.headers
        ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
        ..set(HttpHeaders.cacheControlHeader, 'no-cache');
      request.response.write(': connected\n\n');
      await request.response.flush();
      openResponses.add(request.response);
      if (request.headers.value('Acp-Session-Id') == null &&
          !connectionStream.isCompleted) {
        connectionStream.complete(request.response);
      }
    }

    Future<void> sendSse(Map<String, dynamic> message) async {
      final response = await connectionStream.future;
      response
        ..write('event: message\n')
        ..write('data: ${jsonEncode(message)}\n\n');
      await response.flush();
    }

    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        await openSse(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      outboundMessages.add(message);
      outboundSessionHeaders.add(request.headers.value('Acp-Session-Id'));
      if (message['method'] == 'initialize') {
        request.response
          ..headers.contentType = ContentType.json
          ..headers.set('Acp-Connection-Id', 'connection-1')
          ..write(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{
                'connectionId': 'connection-1',
                'protocolVersion': 1,
                'agentCapabilities': <String, dynamic>{},
                'authMethods': <Map<String, dynamic>>[],
              },
            }),
          );
      } else {
        request.response.statusCode = HttpStatus.accepted;
      }
      await request.response.close();
    });

    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
    );
    await transport.start();
    final channel = transport.channel;
    final inboundSubscription = channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    });

    try {
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      await sendSse(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'shared-request-id',
        'method': 'session/request_permission',
        'params': <String, dynamic>{
          'sessionId': 'session-a',
          'toolCall': <String, dynamic>{'toolCallId': 'tool-1'},
          'options': <String>['allow', 'deny'],
        },
      });
      await _waitFor(
        () => inboundMessages.any(
          (message) => message['id'] == 'shared-request-id',
        ),
      );
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'shared-request-id',
          'result': <String, dynamic>{'outcome': 'allow'},
        }),
      );
      await _waitFor(() => outboundMessages.length >= 2);

      await sendSse(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 'shared-request-id',
        'method': '_agent_ping',
        'params': <String, dynamic>{},
      });
      await _waitFor(
        () =>
            inboundMessages
                .where((message) => message['id'] == 'shared-request-id')
                .length ==
            2,
      );
      channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 'shared-request-id',
          'result': <String, dynamic>{'ok': true},
        }),
      );
      await _waitFor(() => outboundMessages.length >= 3);

      expect(outboundSessionHeaders[1], 'session-a');
      expect(outboundSessionHeaders[2], isNull);

      await transport.stop().timeout(const Duration(seconds: 5));
      disposed = true;
    } finally {
      await inboundSubscription.cancel();
      if (!disposed) {
        await transport.stop();
      }
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('HTTP response first-byte timeout is reported', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final transportErrors = <Object>[];
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      openResponses.add(request.response);
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      requestTimeout: const Duration(seconds: 1),
      firstByteTimeout: const Duration(milliseconds: 50),
      sseIdleTimeout: const Duration(seconds: 1),
    );
    await transport.start();
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: transportErrors.add,
    );

    try {
      transport.channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );

      await _waitFor(() => transportErrors.isNotEmpty);
      expect(transportErrors.single, isA<TimeoutException>());
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('SSE idle timeout is reported', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final openResponses = <HttpResponse>[];
    final inboundMessages = <Map<String, dynamic>>[];
    final transportErrors = <Object>[];
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response.bufferOutput = false;
        request.response.headers
          ..contentType = ContentType('text', 'event-stream', charset: 'utf-8')
          ..set(HttpHeaders.cacheControlHeader, 'no-cache');
        request.response.write(': connected\n\n');
        await request.response.flush();
        openResponses.add(request.response);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      request.response
        ..headers.contentType = ContentType.json
        ..headers.set('Acp-Connection-Id', 'connection-1')
        ..write(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{
              'connectionId': 'connection-1',
              'protocolVersion': 1,
              'agentCapabilities': <String, dynamic>{},
              'authMethods': <Map<String, dynamic>>[],
            },
          }),
        );
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      requestTimeout: const Duration(seconds: 1),
      firstByteTimeout: const Duration(seconds: 1),
      sseIdleTimeout: const Duration(milliseconds: 50),
    );
    await transport.start();
    final subscription = transport.channel.stream.listen((line) {
      inboundMessages.add(jsonDecode(line) as Map<String, dynamic>);
    }, onError: transportErrors.add);

    try {
      transport.channel.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, dynamic>{},
        }),
      );
      await _waitFor(
        () => inboundMessages.any((message) => message['id'] == 1),
      );

      await _waitFor(() => transportErrors.isNotEmpty);
      expect(transportErrors.single, isA<TimeoutException>());
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('cookie budget constructor arguments are validated at runtime', () {
    final endpoint = Uri.parse('http://127.0.0.1:1/acp');

    expect(
      () => StreamableHttpAcpTransport(endpoint: endpoint, maxCookieCount: 0),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxCookieCount',
        ),
      ),
    );
    expect(
      () => StreamableHttpAcpTransport(endpoint: endpoint, maxCookieBytes: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxCookieBytes',
        ),
      ),
    );
  });

  test('HTTP transport timeouts must be positive at runtime', () {
    final endpoint = Uri.parse('http://127.0.0.1:1/acp');
    final cases =
        <
          ({
            String name,
            Duration invalidValue,
            StreamableHttpAcpTransport Function(dynamic value) create,
          })
        >[
          (
            name: 'requestTimeout',
            invalidValue: Duration.zero,
            create: (value) => StreamableHttpAcpTransport(
              endpoint: endpoint,
              requestTimeout: value,
            ),
          ),
          (
            name: 'firstByteTimeout',
            invalidValue: Duration.zero,
            create: (value) => StreamableHttpAcpTransport(
              endpoint: endpoint,
              firstByteTimeout: value,
            ),
          ),
          (
            name: 'sseIdleTimeout',
            invalidValue: Duration.zero,
            create: (value) => StreamableHttpAcpTransport(
              endpoint: endpoint,
              sseIdleTimeout: value,
            ),
          ),
        ];

    for (final testCase in cases) {
      expect(
        () => testCase.create(testCase.invalidValue),
        throwsA(
          isA<ArgumentError>()
              .having((error) => error.name, 'name', testCase.name)
              .having(
                (error) => error.invalidValue,
                'invalidValue',
                testCase.invalidValue,
              ),
        ),
        reason: testCase.name,
      );
    }
  });

  test('HTTP transport validates its byte budget at runtime', () {
    final dynamic invalidBodyBytes = 0;

    expect(
      () => StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:1/acp'),
        byteBudget: acp.TransportByteBudget(maxBodyBytes: invalidBodyBytes),
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxBodyBytes')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
  });

  test(
    'configured Cookie bytes are rejected before creating a request',
    () async {
      const secret = 'configured-cookie-secret';
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        requestCount += 1;
        await request.drain<void>();
        await request.response.close();
      });
      final configuredHeader = 'configured=$secret';
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        headers: <String, String>{'cOoKiE': configuredHeader},
        maxCookieBytes: utf8.encode(configuredHeader).length - 1,
      );
      await transport.start();
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => errors.isNotEmpty);

        expect(requestCount, 0);
        expect(
          errors.single,
          isA<acp.TransportByteLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'ACP HTTP cookie header bytes',
              )
              .having(
                (error) => error.observedAtLeast,
                'observedAtLeast',
                utf8.encode(configuredHeader).length,
              ),
        );
        expect(errors.single.toString(), isNot(contains(secret)));
      } finally {
        await subscription.cancel();
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'multiple configured Cookie values count toward the cookie limit',
    () async {
      var requestCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        requestCount += 1;
        await request.drain<void>();
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        headers: const <String, String>{
          'Cookie': 'configured=one',
          'cOoKiE': 'second=two',
        },
        maxCookieCount: 1,
      );
      await transport.start();
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => errors.isNotEmpty);

        expect(requestCount, 0);
        expect(
          errors.single,
          isA<acp.TransportByteLimitExceeded>()
              .having((error) => error.resource, 'resource', 'ACP HTTP cookies')
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        );
      } finally {
        await subscription.cancel();
        await transport.stop();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'configured and jar Cookie values share exact combined budgets',
    () async {
      final openResponses = <HttpResponse>[];
      final requestCookies = <String?>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        requestCookies.add(request.headers.value(HttpHeaders.cookieHeader));
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            )
            ..write(': connected\n\n');
          openResponses.add(request.response);
          await request.response.flush();
          return;
        }
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        request.response.cookies.add(Cookie('remote', 'three'));
        await _writeInitializeResponse(request, message['id']);
      });
      const configured = 'configured=one; second=two';
      const combined = '$configured; remote=three';
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        headers: const <String, String>{
          'Cookie': 'configured=one',
          'cOoKiE': 'second=two',
        },
        maxCookieCount: 3,
        maxCookieBytes: utf8.encode(combined).length,
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        await _waitFor(() => requestCookies.length >= 2);

        expect(requestCookies[0], configured);
        expect(requestCookies[1], combined);
        expect(errors, isEmpty);
      } finally {
        await subscription.cancel();
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('expired cookies are pruned with Max-Age taking precedence', () async {
    var now = DateTime.utc(2030, 1, 1, 12);
    final openResponses = <HttpResponse>[];
    final getCookie = Completer<String?>();
    final postCookies = <String?>[];
    var followUpPostCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        if (!getCookie.isCompleted) {
          getCookie.complete(request.headers.value(HttpHeaders.cookieHeader));
        }
        request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(': connected\n\n');
        openResponses.add(request.response);
        await request.response.flush();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      if (message['method'] == 'initialize') {
        request.response
          ..cookies.add(
            Cookie('max', 'age')
              ..maxAge = 10
              ..expires = now.subtract(const Duration(days: 1)),
          )
          ..cookies.add(
            Cookie('expires', 'future')
              ..expires = now.add(const Duration(seconds: 5)),
          );
        await _writeInitializeResponse(request, message['id']);
        return;
      }
      postCookies.add(request.headers.value(HttpHeaders.cookieHeader));
      followUpPostCount += 1;
      if (followUpPostCount == 1) {
        request.response
          ..cookies.add(Cookie('fresh-a', 'one'))
          ..cookies.add(Cookie('fresh-b', 'two'));
      }
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      maxCookieCount: 2,
      clock: () => now,
    );
    await transport.start();
    final inbound = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      inbound.add,
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.isNotEmpty);
      expect(
        await getCookie.future.timeout(const Duration(seconds: 1)),
        'max=age; expires=future',
      );

      now = now.add(const Duration(seconds: 11));
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","method":"session/cancel",'
        '"params":{"sessionId":"s"}}',
      );
      await _waitFor(() => postCookies.isNotEmpty);
      expect(postCookies.first, isNull);

      transport.channel.sink.add(
        '{"jsonrpc":"2.0","method":"session/cancel",'
        '"params":{"sessionId":"s"}}',
      );
      await _waitFor(() => postCookies.length == 2);
      expect(postCookies.last, 'fresh-a=one; fresh-b=two');
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('extreme Max-Age values clamp without wrapping into the past', () async {
    var now = DateTime.utc(9999, 12, 31, 23, 59, 56);
    final openResponses = <HttpResponse>[];
    final getCookie = Completer<String?>();
    final postCookies = <String?>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        if (!getCookie.isCompleted) {
          getCookie.complete(request.headers.value(HttpHeaders.cookieHeader));
        }
        request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(': connected\n\n');
        openResponses.add(request.response);
        await request.response.flush();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      if (message['method'] == 'initialize') {
        request.response
          ..cookies.add(Cookie('exact', 'two')..maxAge = 2)
          ..cookies.add(Cookie('edge', 'three')..maxAge = 3)
          ..cookies.add(Cookie('clamped', 'four')..maxAge = 4)
          ..cookies.add(Cookie('huge', 'kept')..maxAge = 9223372036854775807);
        await _writeInitializeResponse(request, message['id']);
        return;
      }
      postCookies.add(request.headers.value(HttpHeaders.cookieHeader));
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      maxCookieCount: 4,
      clock: () => now,
    );
    await transport.start();
    final inbound = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      inbound.add,
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.isNotEmpty);
      expect(
        await getCookie.future.timeout(const Duration(seconds: 1)),
        'exact=two; edge=three; clamped=four; huge=kept',
      );

      now = now.add(const Duration(seconds: 2));
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","method":"session/cancel",'
        '"params":{"sessionId":"s"}}',
      );
      await _waitFor(() => postCookies.isNotEmpty);
      expect(postCookies.first, 'edge=three; clamped=four; huge=kept');

      now = now.add(const Duration(seconds: 1));
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","method":"session/cancel",'
        '"params":{"sessionId":"s"}}',
      );
      await _waitFor(() => postCookies.length == 2);
      expect(postCookies.last, 'clamped=four; huge=kept');
      expect(errors, isEmpty);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test(
    'malformed response cookies are payload-free across POST SSE and DELETE',
    () async {
      const secret = 'malformed-cookie-secret';
      final openResponses = <HttpResponse>[];
      var postCount = 0;
      var getCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          request.response
            ..statusCode = HttpStatus.accepted
            ..headers.add(HttpHeaders.setCookieHeader, 'delete-$secret');
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          getCount += 1;
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            );
          if (getCount == 1) {
            request.response.headers.add(
              HttpHeaders.setCookieHeader,
              'sse-$secret',
            );
            await request.response.close();
            return;
          }
          request.response.write(': connected\n\n');
          openResponses.add(request.response);
          await request.response.flush();
          return;
        }
        postCount += 1;
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        if (postCount == 1) {
          request.response.headers.add(
            HttpHeaders.setCookieHeader,
            'post-$secret',
          );
        }
        await _writeInitializeResponse(request, message['id']);
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => errors.isNotEmpty);

        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        await _waitFor(() => errors.length == 2);

        await transport.stop();
        await _waitFor(() => errors.length == 3);

        expect(
          errors,
          everyElement(
            isA<acp.TransportProtocolDecodeError>().having(
              (error) => error.resource,
              'resource',
              'ACP HTTP response cookies',
            ),
          ),
        );
        expect(
          errors.map((error) => error.toString()),
          everyElement(isNot(contains(secret))),
        );
      } finally {
        await subscription.cancel();
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'DELETE carries cookies and reports an atomic response overflow',
    () async {
      const secret = 'delete-cookie-secret';
      final openResponses = <HttpResponse>[];
      final postCookies = <String?>[];
      final deleteCookies = <String?>[];
      var postCount = 0;
      var deleteCount = 0;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          deleteCount += 1;
          deleteCookies.add(request.headers.value(HttpHeaders.cookieHeader));
          request.response.statusCode = HttpStatus.accepted;
          if (deleteCount == 1) {
            request.response.cookies.add(Cookie('overflow', secret));
          }
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            )
            ..write(': connected\n\n');
          openResponses.add(request.response);
          await request.response.flush();
          return;
        }
        postCount += 1;
        postCookies.add(request.headers.value(HttpHeaders.cookieHeader));
        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        if (postCount == 1) {
          request.response.cookies.add(Cookie('sticky', 'yes'));
        }
        await _writeInitializeResponse(request, message['id']);
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        maxCookieCount: 1,
      );

      Future<List<Object>> initialize(int id) async {
        await transport.start();
        final inbound = <String>[];
        final errors = <Object>[];
        final subscription = transport.channel.stream.listen(
          inbound.add,
          onError: errors.add,
        );
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":$id,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        if (id == 1) {
          await transport.stop();
          await subscription.cancel();
        } else {
          await subscription.cancel();
        }
        return errors;
      }

      try {
        final teardownErrors = await initialize(1);

        expect(deleteCookies, <String?>['sticky=yes']);
        expect(
          teardownErrors.single,
          isA<acp.TransportByteLimitExceeded>()
              .having((error) => error.resource, 'resource', 'ACP HTTP cookies')
              .having((error) => error.limit, 'limit', 1)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
        );
        expect(teardownErrors.single.toString(), isNot(contains(secret)));

        await initialize(2);
        expect(postCookies, <String?>[null, null]);
      } finally {
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'cookie jar accepts exact count and bytes then replaces and deletes',
    () async {
      final openResponses = <HttpResponse>[];
      final initialGetCookie = Completer<String?>();
      final finalPostCookie = Completer<String?>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        if (request.method == 'DELETE') {
          await request.response.close();
          return;
        }
        if (request.method == 'GET') {
          if (!initialGetCookie.isCompleted) {
            initialGetCookie.complete(
              request.headers.value(HttpHeaders.cookieHeader),
            );
          }
          request.response
            ..bufferOutput = false
            ..headers.contentType = ContentType(
              'text',
              'event-stream',
              charset: 'utf-8',
            )
            ..cookies.add(Cookie('r', 'x'))
            ..cookies.add(Cookie('d', '')..maxAge = 0)
            ..cookies.add(
              Cookie('e', '')
                ..expires = DateTime.now().subtract(const Duration(days: 1)),
            )
            ..cookies.add(Cookie('sse', 'two'))
            ..write(': connected\n\n');
          openResponses.add(request.response);
          await request.response.flush();
          return;
        }

        final body = await utf8.decoder.bind(request).join();
        final message = jsonDecode(body) as Map<String, dynamic>;
        if (message['method'] == 'initialize') {
          request.response
            ..cookies.add(Cookie('r', 'long'))
            ..cookies.add(Cookie('d', 'gone'))
            ..cookies.add(Cookie('e', 'gone'));
          await _writeInitializeResponse(request, message['id']);
          return;
        }
        if (!finalPostCookie.isCompleted) {
          finalPostCookie.complete(
            request.headers.value(HttpHeaders.cookieHeader),
          );
        }
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
      });
      final transport = StreamableHttpAcpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
        maxCookieCount: 3,
        maxCookieBytes: utf8.encode('r=long; d=gone; e=gone').length,
      );
      await transport.start();
      final inbound = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        inbound.add,
        onError: errors.add,
      );

      try {
        transport.channel.sink.add(
          '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
        );
        await _waitFor(() => inbound.isNotEmpty);
        expect(
          await initialGetCookie.future.timeout(const Duration(seconds: 1)),
          'r=long; d=gone; e=gone',
        );

        transport.channel.sink.add(
          '{"jsonrpc":"2.0","method":"session/cancel",'
          '"params":{"sessionId":"s"}}',
        );

        expect(
          await finalPostCookie.future.timeout(const Duration(seconds: 1)),
          'r=x; sse=two',
        );
        expect(errors, isEmpty);
      } finally {
        await subscription.cancel();
        await transport.stop();
        for (final response in openResponses) {
          await response.close();
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('cookie byte overflow is atomic across POST and SSE', () async {
    const secret = 'cookie-secret';
    final openResponses = <HttpResponse>[];
    final getCount = <int>[0];
    final retryPostCookie = Completer<String?>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        getCount[0] += 1;
        request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          );
        if (getCount[0] == 1) {
          request.response.cookies.add(Cookie('leaked', secret));
          await request.response.close();
          return;
        }
        request.response.write(': connected\n\n');
        openResponses.add(request.response);
        await request.response.flush();
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      if (message['method'] == 'initialize') {
        request.response.cookies.add(Cookie('safe', 'ok'));
        await _writeInitializeResponse(request, message['id']);
        return;
      }
      if (!retryPostCookie.isCompleted) {
        retryPostCookie.complete(
          request.headers.value(HttpHeaders.cookieHeader),
        );
      }
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
    });
    final nextHeader = 'safe=ok; leaked=$secret';
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      maxCookieBytes: utf8.encode(nextHeader).length - 1,
    );
    await transport.start();
    final inbound = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      inbound.add,
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.isNotEmpty);
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'ACP HTTP cookie header bytes',
            )
            .having(
              (error) => error.observedAtLeast,
              'observedAtLeast',
              utf8.encode(nextHeader).length,
            ),
      );
      expect(errors.single.toString(), isNot(contains(secret)));

      transport.channel.sink.add(
        '{"jsonrpc":"2.0","method":"session/cancel",'
        '"params":{"sessionId":"s"}}',
      );
      expect(
        await retryPostCookie.future.timeout(const Duration(seconds: 1)),
        'safe=ok',
      );
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('cookie count overflow rejects a POST response atomically', () async {
    const secret = 'count-secret';
    var postCount = 0;
    String? retryCookie;
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      if (request.method == 'DELETE') {
        await request.response.close();
        return;
      }
      if (request.method == 'GET') {
        request.response
          ..bufferOutput = false
          ..headers.contentType = ContentType(
            'text',
            'event-stream',
            charset: 'utf-8',
          )
          ..write(': connected\n\n');
        openResponses.add(request.response);
        await request.response.flush();
        return;
      }
      postCount += 1;
      final body = await utf8.decoder.bind(request).join();
      final message = jsonDecode(body) as Map<String, dynamic>;
      if (postCount == 1) {
        request.response
          ..cookies.add(Cookie('safe', 'ok'))
          ..cookies.add(Cookie('leaked', secret));
      } else {
        retryCookie = request.headers.value(HttpHeaders.cookieHeader);
      }
      await _writeInitializeResponse(request, message['id']);
    });
    final transport = StreamableHttpAcpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/acp'),
      maxCookieCount: 1,
    );
    await transport.start();
    final inbound = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      inbound.add,
      onError: errors.add,
    );

    try {
      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}',
      );
      await _waitFor(() => errors.isNotEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having((error) => error.resource, 'resource', 'ACP HTTP cookies')
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
      );
      expect(errors.single.toString(), isNot(contains(secret)));

      transport.channel.sink.add(
        '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}',
      );
      await _waitFor(() => inbound.isNotEmpty);
      expect(retryCookie, isNull);
    } finally {
      await subscription.cancel();
      await transport.stop();
      for (final response in openResponses) {
        await response.close();
      }
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}

Future<void> _writeInitializeResponse(HttpRequest request, Object? id) async {
  request.response
    ..headers.contentType = ContentType.json
    ..headers.set('Acp-Connection-Id', 'connection-1')
    ..write(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
        'result': <String, Object?>{'connectionId': 'connection-1'},
      }),
    );
  await request.response.close();
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}
