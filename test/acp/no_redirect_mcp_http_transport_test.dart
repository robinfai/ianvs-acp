import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/no_redirect_mcp_http_transport.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  test(
    'bounded UTF-8 bodies count raw bytes without retaining overflow',
    () async {
      const secret = 'raw-byte-secret';
      final chunks = <List<int>>[utf8.encode('é'), utf8.encode('é$secret')];

      await expectLater(
        acp.readBoundedUtf8Body(
          Stream<List<int>>.fromIterable(chunks),
          limit: 3,
          resource: 'test body',
        ),
        throwsA(
          isA<acp.TransportByteLimitExceeded>()
              .having((value) => value.limit, 'limit', 3)
              .having(
                (value) => value.observedAtLeast,
                'observedAtLeast',
                greaterThan(3),
              )
              .having(
                (value) => value.toString(),
                'payload-free error',
                isNot(contains(secret)),
              ),
        ),
      );
    },
  );

  test('SSE does not apply one-shot body limits across valid events', () async {
    final events = await acp
        .decodeBoundedSse(
          Stream<List<int>>.value(utf8.encode('data: one\n\ndata: two\n\n')),
          budget: const acp.TransportByteBudget(
            maxBodyBytes: 1,
            maxLineBytes: 32,
            maxSseEventBytes: 32,
          ),
          resource: 'test SSE',
        )
        .toList();

    expect(events.map((event) => event.data), ['one', 'two']);
  });

  test('SSE accepts CR-only multiline events', () async {
    final events = await acp
        .decodeBoundedSse(
          Stream<List<int>>.fromIterable(<List<int>>[
            utf8.encode('data: one\rdata: two\r'),
            utf8.encode('\rdata: three\r'),
            utf8.encode('\r'),
          ]),
          budget: const acp.TransportByteBudget(
            maxBodyBytes: 1,
            maxLineBytes: 32,
            maxSseEventBytes: 64,
          ),
          resource: 'test SSE',
        )
        .toList();

    expect(events.map((event) => event.data), ['one\ntwo', 'three']);
  });

  test('MCP JSON response counts raw bytes and redacts limit errors', () async {
    const secret = 'mcp-secret-payload-must-not-appear';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      final bytes = utf8.encode(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{'value': secret},
        }),
      );
      request.response
        ..headers.contentType = ContentType.json
        ..contentLength = bytes.length
        ..add(bytes);
      await request.response.close();
    });
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      byteBudget: const acp.TransportByteBudget(maxBodyBytes: 24),
    );
    final errorCompleter = Completer<Error>();
    transport.onerror = (error) {
      if (!errorCompleter.isCompleted) errorCompleter.complete(error);
    };

    try {
      await transport.start();
      await transport.send(
        const mcp.JsonRpcNotification(method: 'test/oversized-json'),
      );
      final error = await errorCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      expect(
        error,
        isA<acp.TransportByteLimitExceeded>()
            .having((value) => value.resource, 'resource', contains('body'))
            .having((value) => value.limit, 'limit', 24)
            .having(
              (value) => value.observedAtLeast,
              'observedAtLeast',
              greaterThan(24),
            ),
      );
      expect(error.toString(), isNot(contains(secret)));
    } finally {
      await transport.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('MCP accepted and failed response drains are bounded', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var requestCount = 0;
    final serverSubscription = server.listen((request) async {
      requestCount += 1;
      await request.drain<void>();
      request.response
        ..statusCode = requestCount == 1
            ? HttpStatus.accepted
            : HttpStatus.badRequest
        ..write(List<String>.filled(64, 'x').join());
      await request.response.close();
    });
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      byteBudget: const acp.TransportByteBudget(maxBodyBytes: 16),
    );

    try {
      await transport.start();
      for (final method in const ['test/accepted', 'test/failed']) {
        await expectLater(
          transport.send(mcp.JsonRpcNotification(method: method)),
          throwsA(isA<acp.TransportByteLimitExceeded>()),
        );
      }
    } finally {
      await transport.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });

  test('MCP SSE event limit rejects without a partial message', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      request.response.headers.contentType = ContentType(
        'text',
        'event-stream',
        charset: 'utf-8',
      );
      request.response.write(
        'data: {"jsonrpc":"2.0",\n'
        'data: "method":"never-deliver-this-event"}\n\n',
      );
      await request.response.close();
    });
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      byteBudget: const acp.TransportByteBudget(
        maxBodyBytes: 256,
        maxLineBytes: 128,
        maxSseEventBytes: 32,
      ),
    );
    final messages = <mcp.JsonRpcMessage>[];
    final errorCompleter = Completer<Error>();
    transport.onmessage = messages.add;
    transport.onerror = (error) {
      if (!errorCompleter.isCompleted) errorCompleter.complete(error);
    };

    try {
      await transport.start();
      await transport.send(
        const mcp.JsonRpcNotification(method: 'test/oversized-sse'),
      );
      final error = await errorCompleter.future.timeout(
        const Duration(seconds: 2),
      );

      expect(
        error,
        isA<acp.TransportByteLimitExceeded>().having(
          (value) => value.resource,
          'resource',
          contains('event'),
        ),
      );
      expect(messages, isEmpty);
    } finally {
      await transport.close();
      await serverSubscription.cancel();
      await server.close(force: true);
    }
  });
}
