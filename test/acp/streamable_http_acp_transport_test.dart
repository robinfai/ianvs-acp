import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/streamable_http_acp_transport.dart';

void main() {
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

      await sendSseData('not json');
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

      expect(transportErrors.single, isA<FormatException>());

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
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}
