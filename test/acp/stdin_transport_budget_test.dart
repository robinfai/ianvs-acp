import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('StdinTransport validates maxLineBytes at runtime', () {
    expect(
      () => StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 0,
        inputStream: const Stream<List<int>>.empty(),
        outputSink: IOSink(_DiscardStreamConsumer()),
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxLineBytes',
        ),
      ),
    );
  });

  test(
    'StdinTransport accepts exact UTF-8 line budget across chunks',
    () async {
      final input = StreamController<List<int>>();
      final output = IOSink(_DiscardStreamConsumer());
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 4,
        inputStream: input.stream,
        outputSink: output,
      );
      await transport.start();
      final lines = <String>[];
      final errors = <Object>[];
      final subscription = transport.channel.stream.listen(
        lines.add,
        onError: errors.add,
      );

      try {
        input
          ..add(const <int>[0xc3])
          ..add(const <int>[0xa9, 0xc3])
          ..add(const <int>[0xa9, 0x0d])
          ..add(const <int>[0x0a]);
        await _waitFor(() => lines.isNotEmpty);

        expect(lines, <String>['éé']);
        expect(errors, isEmpty);
      } finally {
        await subscription.cancel();
        await transport.stop();
        await input.close();
        await output.close();
      }
    },
  );

  test(
    'StdinTransport decodes UTF-8 across a 64 KiB segment boundary',
    () async {
      const segmentBytes = 64 * 1024;
      final bytes = List<int>.filled(segmentBytes - 1, 0x61, growable: true)
        ..addAll(const <int>[0xc3, 0xa9, 0x0a]);
      final output = IOSink(_DiscardStreamConsumer());
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: segmentBytes + 1,
        inputStream: Stream<List<int>>.fromIterable(<List<int>>[
          bytes.sublist(0, segmentBytes),
          bytes.sublist(segmentBytes),
        ]),
        outputSink: output,
      );
      await transport.start();

      try {
        final lines = await transport.channel.stream.toList();
        expect(lines, hasLength(1));
        expect(lines.single.length, segmentBytes);
        expect(lines.single.endsWith('é'), isTrue);
      } finally {
        await transport.stop();
        await output.close();
      }
    },
  );

  test('StdinTransport cancels input at maxLineBytes plus one', () async {
    const secret = 'secret-payload';
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxLineBytes: 4,
      inputStream: input.stream,
      outputSink: output,
    );
    await transport.start();
    final lines = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );

    try {
      input.add(utf8.encode('safe\n12345$secret\nlater\n'));
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, <String>['safe']);
      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 5),
      );
      expect(errors.single.toString(), isNot(contains(secret)));
      await _waitFor(() => !input.hasListener);
      expect(lines, <String>['safe']);
    } finally {
      await subscription.cancel();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport reports invalid UTF-8 without later delivery', () async {
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxLineBytes: 8,
      inputStream: input.stream,
      outputSink: output,
    );
    await transport.start();
    final lines = <String>[];
    final errors = <Object>[];
    final subscription = transport.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );

    try {
      input.add(const <int>[0xff, 0x0a, 0x6f, 0x6b, 0x0a]);
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, isEmpty);
      expect(errors.single, isA<TransportProtocolDecodeError>());
      await _waitFor(() => !input.hasListener);
    } finally {
      await subscription.cancel();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test(
    'StdinTransport maps unfinished UTF-8 at EOF to one protocol error',
    () async {
      final output = IOSink(_DiscardStreamConsumer());
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 1,
        inputStream: Stream<List<int>>.value(const <int>[0xc3]),
        outputSink: output,
      );
      await transport.start();
      final lines = <String>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final subscription = transport.channel.stream.listen(
        lines.add,
        onError: errors.add,
        onDone: done.complete,
      );

      try {
        await done.future.timeout(const Duration(seconds: 1));

        expect(lines, isEmpty);
        expect(errors, hasLength(1));
        expect(errors.single, isA<TransportProtocolDecodeError>());
      } finally {
        await subscription.cancel();
        await transport.stop();
        await output.close();
      }
    },
  );

  test('StdinTransport delivers an unterminated final line at EOF', () async {
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxLineBytes: 4,
      inputStream: Stream<List<int>>.value(utf8.encode('last')),
      outputSink: output,
    );
    await transport.start();

    await expectLater(
      transport.channel.stream,
      emitsInOrder(<Object>['last', emitsDone]),
    );
    await transport.stop();
    await transport.stop();
    await output.close();
  });

  for (final failure in <({String name, List<int> bytes})>[
    (name: 'overflow', bytes: utf8.encode('12345secret-payload\n')),
    (name: 'invalid UTF-8', bytes: const <int>[0xff, 0x0a]),
  ]) {
    test(
      'StdinTransport rejects synchronous ${failure.name} during start',
      () async {
        final input = _SynchronousInputStream(<List<int>>[
          failure.bytes,
          utf8.encode('late\n'),
        ]);
        final protocolLines = <String>[];
        final output = IOSink(_DiscardStreamConsumer());
        final transport = StdinTransport(
          logger: AcpConfig().logger,
          maxLineBytes: 4,
          inputStream: input,
          outputSink: output,
          onProtocolIn: protocolLines.add,
        );

        try {
          final start = transport.start();
          if (failure.name == 'overflow') {
            await expectLater(
              start,
              throwsA(
                isA<TransportByteLimitExceeded>()
                    .having((error) => error.limit, 'limit', 4)
                    .having(
                      (error) => error.observedAtLeast,
                      'observedAtLeast',
                      5,
                    )
                    .having(
                      (error) => error.toString(),
                      'payload-free text',
                      isNot(contains('secret-payload')),
                    ),
              ),
            );
          } else {
            await expectLater(
              start,
              throwsA(isA<TransportProtocolDecodeError>()),
            );
          }

          expect(input.wasCancelled, isTrue);
          expect(input.hasListener, isFalse);
          expect(protocolLines, isEmpty);
          expect(() => transport.channel, throwsStateError);
          await transport.stop();
          await transport.stop();
        } finally {
          await transport.stop();
          await output.close();
        }
      },
    );
  }

  test(
    'StdinTransport serializes a second start behind failed cleanup',
    () async {
      final input = _SequencedInputStream();
      final output = IOSink(_DiscardStreamConsumer());
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 4,
        inputStream: input,
        outputSink: output,
      );

      try {
        final firstStart = transport.start();
        await input.firstCancelStarted.future;
        var secondCompleted = false;
        final secondStart = transport.start().then((_) {
          secondCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(secondCompleted, isFalse);
        expect(input.listenCount, 1);

        input.releaseFirstCancel.complete();
        await expectLater(
          firstStart,
          throwsA(isA<TransportByteLimitExceeded>()),
        );
        await secondStart;

        expect(input.listenCount, 2);
        expect(() => transport.channel, returnsNormally);
      } finally {
        if (!input.releaseFirstCancel.isCompleted) {
          input.releaseFirstCancel.complete();
        }
        await transport.stop();
        await output.close();
      }
    },
  );

  test(
    'StdinTransport serializes stop behind a pending failed start',
    () async {
      final input = _SequencedInputStream();
      final output = IOSink(_DiscardStreamConsumer());
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 4,
        inputStream: input,
        outputSink: output,
      );

      try {
        final start = transport.start();
        await input.firstCancelStarted.future;
        var stopCompleted = false;
        final stop = transport.stop().then((_) {
          stopCompleted = true;
        });
        await Future<void>.delayed(Duration.zero);

        expect(stopCompleted, isFalse);
        input.releaseFirstCancel.complete();
        await expectLater(start, throwsA(isA<TransportByteLimitExceeded>()));
        await stop;

        expect(() => transport.channel, throwsStateError);
        await transport.stop();
      } finally {
        if (!input.releaseFirstCancel.isCompleted) {
          input.releaseFirstCancel.complete();
        }
        await transport.stop();
        await output.close();
      }
    },
  );

  test('StdinTransport closes async input when cancellation throws', () async {
    const cancelSecret = 'cancel-secret-must-not-leak';
    final input = _ControllableInputStream(StateError(cancelSecret));
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxLineBytes: 4,
      inputStream: input,
      outputSink: output,
    );
    await transport.start();
    final errors = <Object>[];
    final done = Completer<void>();
    final subscription = transport.channel.stream.listen(
      (_) {},
      onError: errors.add,
      onDone: done.complete,
    );

    try {
      input.add(utf8.encode('12345\n'));
      await done.future.timeout(const Duration(seconds: 1));

      expect(input.subscription.cancelCalled, isTrue);
      expect(errors, hasLength(1));
      expect(errors.single, isA<TransportByteLimitExceeded>());
      expect(errors.single.toString(), isNot(contains(cancelSecret)));
    } finally {
      await subscription.cancel();
      await transport.stop();
      await output.close();
    }
  });

  test('StdinTransport cleans a generation when input listen throws', () async {
    final input = _RetainingListenThrowingInputStream();
    final protocolLines = <String>[];
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      inputStream: input,
      outputSink: output,
      onProtocolIn: protocolLines.add,
    );

    try {
      await expectLater(
        transport.start(),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'input listen failed',
          ),
        ),
      );

      input.addAfterThrow(utf8.encode('late\n'));
      await Future<void>.delayed(Duration.zero);

      expect(protocolLines, isEmpty);
      expect(() => transport.channel, throwsStateError);
      await transport.stop();
      await transport.stop();
    } finally {
      await transport.stop();
      await output.close();
    }
  });

  test(
    'StdinTransport isolates protocol observer failures from traffic',
    () async {
      final input = StreamController<List<int>>();
      final outputConsumer = _RecordingStreamConsumer();
      final output = IOSink(outputConsumer);
      final inboundLines = <String>[];
      final transportErrors = <Object>[];
      final protocolInLines = <String>[];
      final protocolOutLines = <String>[];
      final zoneErrors = <Object>[];
      final bodyDone = Completer<void>();
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        inputStream: input.stream,
        outputSink: output,
        onProtocolIn: (line) {
          protocolInLines.add(line);
          throw StateError('in observer failed');
        },
        onProtocolOut: (line) {
          protocolOutLines.add(line);
          throw StateError('out observer failed');
        },
      );

      runZonedGuarded(
        () async {
          StreamSubscription<String>? subscription;
          try {
            await transport.start();
            subscription = transport.channel.stream.listen(
              inboundLines.add,
              onError: transportErrors.add,
            );

            input.add(utf8.encode('valid inbound\n'));
            transport.channel.sink.add('valid outbound');
            await _waitFor(
              () =>
                  inboundLines.isNotEmpty &&
                  outputConsumer.text.contains('valid outbound\n') &&
                  transportErrors.length >= 2,
            );
          } finally {
            await subscription?.cancel();
            await transport.stop();
            await input.close();
            await output.close();
            if (!bodyDone.isCompleted) bodyDone.complete();
          }
        },
        (error, _) {
          zoneErrors.add(error);
        },
      );

      await bodyDone.future.timeout(const Duration(seconds: 2));

      expect(zoneErrors, isEmpty);
      expect(inboundLines, <String>['valid inbound']);
      expect(outputConsumer.text, contains('valid outbound\n'));
      expect(protocolInLines, <String>['valid inbound']);
      expect(protocolOutLines, <String>['valid outbound']);
      expect(
        transportErrors.whereType<StateError>().map((error) => error.message),
        containsAll(<String>['in observer failed', 'out observer failed']),
      );
      expect(() => transport.channel, throwsStateError);
    },
  );
}

class _DiscardStreamConsumer implements StreamConsumer<List<int>> {
  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}
}

class _RecordingStreamConsumer implements StreamConsumer<List<int>> {
  final List<int> _bytes = <int>[];

  String get text => utf8.decode(_bytes);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      _bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

class _RetainingListenThrowingInputStream extends Stream<List<int>> {
  void Function(List<int>)? _onData;

  void addAfterThrow(List<int> bytes) => _onData?.call(bytes);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    throw StateError('input listen failed');
  }
}

class _SynchronousInputStream extends Stream<List<int>> {
  _SynchronousInputStream(this.chunks);

  final List<List<int>> chunks;
  _SynchronousSubscription<List<int>>? _subscription;

  bool get hasListener => _subscription?.isActive ?? false;
  bool get wasCancelled => _subscription?.wasCancelled ?? false;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final subscription = _SynchronousSubscription<List<int>>();
    _subscription = subscription;
    for (final chunk in chunks) {
      if (!subscription.isActive) break;
      onData?.call(chunk);
    }
    return subscription;
  }
}

class _SynchronousSubscription<T> implements StreamSubscription<T> {
  var isActive = true;
  var wasCancelled = false;
  var _paused = false;

  @override
  Future<void> cancel() async {
    wasCancelled = true;
    isActive = false;
  }

  @override
  bool get isPaused => _paused;

  @override
  void onData(void Function(T data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {
    _paused = true;
  }

  @override
  void resume() {
    _paused = false;
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}

class _SequencedInputStream extends Stream<List<int>> {
  final firstCancelStarted = Completer<void>();
  final releaseFirstCancel = Completer<void>();
  var listenCount = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount += 1;
    if (listenCount == 1) {
      final subscription = _DeferredCancelSubscription<List<int>>(
        firstCancelStarted,
        releaseFirstCancel,
      );
      onData?.call(utf8.encode('12345\n'));
      return subscription;
    }
    return _SynchronousSubscription<List<int>>();
  }
}

class _DeferredCancelSubscription<T> extends _SynchronousSubscription<T> {
  _DeferredCancelSubscription(this.cancelStarted, this.releaseCancel);

  final Completer<void> cancelStarted;
  final Completer<void> releaseCancel;

  @override
  Future<void> cancel() async {
    wasCancelled = true;
    isActive = false;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await releaseCancel.future;
  }
}

class _ControllableInputStream extends Stream<List<int>> {
  _ControllableInputStream(Object cancelError)
    : subscription = _ThrowingCancelSubscription<List<int>>(cancelError);

  final _ThrowingCancelSubscription<List<int>> subscription;
  void Function(List<int>)? _onData;

  void add(List<int> bytes) => _onData?.call(bytes);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    return subscription;
  }
}

class _ThrowingCancelSubscription<T> extends _SynchronousSubscription<T> {
  _ThrowingCancelSubscription(this.cancelError);

  final Object cancelError;
  var cancelCalled = false;

  @override
  Future<void> cancel() {
    cancelCalled = true;
    wasCancelled = true;
    isActive = false;
    return Future<void>.error(cancelError, StackTrace.current);
  }
}

Future<void> _waitFor(bool Function() predicate) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Timed out waiting for condition.');
}
