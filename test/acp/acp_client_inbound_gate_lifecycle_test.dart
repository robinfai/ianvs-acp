import 'dart:async';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test('invalid inbound gate limits fail before transport start', () async {
    final transport = _LifecycleTransport();

    await expectLater(
      AcpClient.start(
        config: AcpConfig(),
        transport: transport,
        maxPendingItems: 0,
      ),
      throwsArgumentError,
    );

    expect(transport.startCount, 0);
    expect(transport.stopCount, 0);
    unawaited(transport.closeInput());
  });

  test('dispose stops transport once when peer close throws Error', () async {
    final transport = _LifecycleTransport(cancelError: _CloseError());
    final client = await AcpClient.start(
      config: AcpConfig(),
      transport: transport,
    );

    await client.dispose();
    await client.dispose();

    expect(transport.stopCount, 1);
    await transport.closeInput();
  });

  test('custom inbound gate limits are passed to the peer', () async {
    final transport = _LifecycleTransport();
    final client = await AcpClient.start(
      config: AcpConfig(),
      transport: transport,
      maxPendingItems: 1,
      maxPendingBytes: 1024,
      maxConcurrentHandlers: 3,
      maxOrdinaryConcurrentHandlers: 1,
    );

    try {
      transport.addInbound(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'unknown/first',
        }),
      );
      transport.addInbound(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'unknown/second',
        }),
      );
      await pumpEventQueue();

      expect(
        transport.outboundLines.map(jsonDecode),
        contains(
          isA<Map<String, dynamic>>()
              .having((response) => response['id'], 'id', 2)
              .having(
                (response) => response['error'],
                'capacity error',
                <String, dynamic>{
                  'code': -32000,
                  'message': 'Inbound request capacity exceeded.',
                },
              ),
        ),
      );
    } finally {
      await client.dispose();
      await transport.closeInput();
    }
    expect(transport.stopCount, 1);
  });
}

class _LifecycleTransport implements AcpTransport {
  _LifecycleTransport({Object? cancelError})
    : _sink = _CloseTrackingSink(),
      _channel = StreamController<String>(
        sync: true,
        onCancel: cancelError == null
            ? null
            : () => Future<void>.error(cancelError),
      );

  final StreamController<String> _channel;
  final _CloseTrackingSink _sink;
  var startCount = 0;
  var stopCount = 0;
  List<String> get outboundLines => _sink.events;

  @override
  StreamChannel<String> get channel =>
      StreamChannel<String>(_channel.stream, _sink);

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  void addInbound(String line) => _channel.add(line);

  Future<void> closeInput() => _channel.close();
}

class _CloseTrackingSink implements StreamSink<String> {
  final Completer<void> _done = Completer<void>();
  final List<String> events = <String>[];

  @override
  Future<void> get done => _done.future;

  @override
  void add(String event) => events.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<String> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override
  Future<void> close() {
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }
}

class _CloseError extends Error {}
