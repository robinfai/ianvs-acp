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

  test('bounded body timeout cancels its source before completing', () async {
    final canceled = Completer<void>();
    late final StreamController<List<int>> controller;
    controller = StreamController<List<int>>(
      onListen: () => controller.add(utf8.encode('partial')),
      onCancel: () {
        if (!canceled.isCompleted) canceled.complete();
      },
    );
    final operation = acp.startBoundedUtf8BodyRead(
      controller.stream,
      limit: 64,
      timeout: const Duration(milliseconds: 25),
      resource: 'timeout-secret-must-not-appear',
    );

    await expectLater(
      operation.future,
      throwsA(
        isA<acp.TransportBodyReadTimeout>()
            .having(
              (error) => error.resource,
              'resource',
              'timeout-secret-must-not-appear',
            )
            .having(
              (error) => error.timeout,
              'timeout',
              const Duration(milliseconds: 25),
            ),
      ),
    );
    await canceled.future.timeout(const Duration(seconds: 1));
    await controller.close();
  });

  test(
    'bounded body invalid UTF-8 reports a payload-free protocol error',
    () async {
      const resource = 'invalid-utf8-response-body';

      await expectLater(
        acp.readBoundedUtf8Body(
          Stream<List<int>>.value(const <int>[0xff, 0xfe]),
          limit: 8,
          resource: resource,
        ),
        throwsA(
          isA<acp.TransportProtocolDecodeError>().having(
            (error) => error.resource,
            'resource',
            resource,
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

  test(
    'MCP POST malformed JSON reports a payload-free protocol error',
    () async {
      const secret = 'mcp-post-malformed-secret';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        await request.drain<void>();
        request.response
          ..headers.contentType = ContentType.json
          ..write('{"jsonrpc":"2.0","id":1,"result":"$secret"');
        await request.response.close();
      });
      final transport = NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      );
      final errorCompleter = Completer<Error>();
      transport.onerror = (error) {
        if (!errorCompleter.isCompleted) errorCompleter.complete(error);
      };

      try {
        await transport.start();
        await transport.send(
          const mcp.JsonRpcNotification(method: 'test/malformed-post'),
        );
        final error = await errorCompleter.future.timeout(
          const Duration(seconds: 2),
        );

        expect(error, isA<acp.TransportProtocolDecodeError>());
        expect(error.toString(), isNot(contains(secret)));
      } finally {
        await transport.close();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('MCP JSON body timeout cancels the remote response read', () async {
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
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      requestTimeout: const Duration(milliseconds: 50),
    );
    final errors = <Error>[];
    transport.onerror = errors.add;

    try {
      await transport.start();
      await transport.send(
        const mcp.JsonRpcNotification(method: 'test/hanging-json'),
      );
      await responseStarted.future.timeout(const Duration(seconds: 1));
      await _waitFor(
        () => errors.any((error) => error is acp.TransportBodyReadTimeout),
      );

      expect(
        errors.whereType<acp.TransportBodyReadTimeout>().single.resource,
        contains('JSON response body'),
      );
      expect(transport.activeBodyReadCount, 0);
    } finally {
      await transport.close();
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

  test(
    'MCP SSE malformed JSON reports a payload-free protocol error',
    () async {
      const secret = 'mcp-sse-malformed-secret';
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final serverSubscription = server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
          charset: 'utf-8',
        );
        request.response.write('data: {"jsonrpc":"2.0","method":"$secret"\n\n');
        await request.response.close();
      });
      final transport = NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      );
      final errorCompleter = Completer<Error>();
      transport.onerror = (error) {
        if (!errorCompleter.isCompleted) errorCompleter.complete(error);
      };

      try {
        await transport.start();
        await transport.send(
          const mcp.JsonRpcNotification(method: 'test/malformed-sse'),
        );
        final error = await errorCompleter.future.timeout(
          const Duration(seconds: 2),
        );

        expect(error, isA<acp.TransportProtocolDecodeError>());
        expect(error.toString(), isNot(contains(secret)));
      } finally {
        await transport.close();
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

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

  for (final testCase in <({String name, int status, String? contentType})>[
    (name: 'accepted', status: HttpStatus.accepted, contentType: null),
    (name: 'error', status: HttpStatus.badRequest, contentType: null),
    (name: 'unsupported', status: HttpStatus.ok, contentType: 'text/plain'),
  ]) {
    test(
      'MCP ${testCase.name} response body timeout clears its read',
      () async {
        final responseStarted = Completer<void>();
        final openResponses = <HttpResponse>[];
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final serverSubscription = server.listen((request) async {
          await request.drain<void>();
          request.response
            ..bufferOutput = false
            ..statusCode = testCase.status;
          if (testCase.contentType != null) {
            request.response.headers.set(
              HttpHeaders.contentTypeHeader,
              testCase.contentType!,
            );
          }
          request.response.write('pending');
          openResponses.add(request.response);
          await request.response.flush();
          if (!responseStarted.isCompleted) responseStarted.complete();
        });
        final transport = NoRedirectMcpHttpTransport(
          endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
          requestTimeout: const Duration(milliseconds: 50),
        );
        final errors = <Error>[];
        transport.onerror = errors.add;

        try {
          await transport.start();
          final send = transport.send(
            mcp.JsonRpcNotification(method: 'test/${testCase.name}'),
          );
          await responseStarted.future.timeout(const Duration(seconds: 1));
          if (testCase.name == 'unsupported') {
            await expectLater(send, throwsA(isA<mcp.McpError>()));
            await _waitFor(
              () =>
                  errors.any((error) => error is acp.TransportBodyReadTimeout),
            );
          } else {
            await expectLater(
              send,
              throwsA(isA<acp.TransportBodyReadTimeout>()),
            );
          }

          expect(transport.activeBodyReadCount, 0);
        } finally {
          await transport.close();
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
      },
    );
  }

  test(
    'MCP close cancels a pending JSON body without reporting an error',
    () async {
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
      final transport = NoRedirectMcpHttpTransport(
        endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
        requestTimeout: const Duration(seconds: 10),
      );
      final errors = <Error>[];
      transport.onerror = errors.add;

      try {
        await transport.start();
        await transport.send(
          const mcp.JsonRpcNotification(method: 'test/close-pending'),
        );
        await responseStarted.future.timeout(const Duration(seconds: 1));
        expect(transport.activeBodyReadCount, 1);

        await transport.close().timeout(const Duration(seconds: 1));

        expect(transport.activeBodyReadCount, 0);
        expect(errors, isEmpty);
      } finally {
        await transport.close();
        for (final response in openResponses) {
          try {
            await response.close();
          } on Object {
            // The closed client may already own the response sink.
          }
        }
        await serverSubscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('MCP DELETE body timeout does not delay close', () async {
    final deleteStarted = Completer<void>();
    final openResponses = <HttpResponse>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final serverSubscription = server.listen((request) async {
      await request.drain<void>();
      if (request.method == 'DELETE') {
        request.response
          ..bufferOutput = false
          ..statusCode = HttpStatus.accepted
          ..write('pending');
        openResponses.add(request.response);
        await request.response.flush();
        if (!deleteStarted.isCompleted) deleteStarted.complete();
        return;
      }
      request.response
        ..statusCode = HttpStatus.accepted
        ..headers.set('Mcp-Session-Id', 'session-1');
      await request.response.close();
    });
    final transport = NoRedirectMcpHttpTransport(
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
      teardownTimeout: const Duration(milliseconds: 75),
    );

    try {
      await transport.start();
      await transport.send(
        const mcp.JsonRpcNotification(method: 'test/create-session'),
      );

      await transport.close().timeout(const Duration(seconds: 1));

      await deleteStarted.future.timeout(const Duration(seconds: 1));
      expect(transport.activeBodyReadCount, 0);
    } finally {
      await transport.close();
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

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met before timeout.', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
