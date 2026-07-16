import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
// logging is a direct dependency of the in-repository dart_acp package.
// ignore: depend_on_referenced_packages
import 'package:logging/logging.dart';

void main() {
  test('StdinTransport validates byte and queue budgets at runtime', () {
    for (final budget in <({String name, StdinTransport Function() create})>[
      (
        name: 'maxLineBytes',
        create: () => StdinTransport(
          logger: AcpConfig().logger,
          maxLineBytes: 0,
          inputStream: const Stream<List<int>>.empty(),
          outputSink: IOSink(_DiscardStreamConsumer()),
        ),
      ),
      (
        name: 'maxOutboundQueueItems',
        create: () => StdinTransport(
          logger: AcpConfig().logger,
          maxOutboundQueueItems: 0,
          inputStream: const Stream<List<int>>.empty(),
          outputSink: IOSink(_DiscardStreamConsumer()),
        ),
      ),
      (
        name: 'maxOutboundQueueBytes',
        create: () => StdinTransport(
          logger: AcpConfig().logger,
          maxOutboundQueueBytes: 0,
          inputStream: const Stream<List<int>>.empty(),
          outputSink: IOSink(_DiscardStreamConsumer()),
        ),
      ),
      (
        name: 'maxInboundQueueItems',
        create: () => StdinTransport(
          logger: AcpConfig().logger,
          maxInboundQueueItems: 0,
          inputStream: const Stream<List<int>>.empty(),
          outputSink: IOSink(_DiscardStreamConsumer()),
        ),
      ),
      (
        name: 'maxInboundQueueBytes',
        create: () => StdinTransport(
          logger: AcpConfig().logger,
          maxInboundQueueBytes: 0,
          inputStream: const Stream<List<int>>.empty(),
          outputSink: IOSink(_DiscardStreamConsumer()),
        ),
      ),
    ]) {
      expect(
        budget.create,
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            budget.name,
          ),
        ),
      );
    }
  });

  test('StdinTransport validates stopDrainTimeout at runtime', () {
    Object? create(Duration timeout) =>
        Function.apply(StdinTransport.new, const <Object?>[], <Symbol, Object?>{
          #logger: AcpConfig().logger,
          #stopDrainTimeout: timeout,
          #inputStream: const Stream<List<int>>.empty(),
          #outputSink: IOSink(_DiscardStreamConsumer()),
        });

    for (final timeout in <Duration>[
      Duration.zero,
      const Duration(microseconds: -1),
    ]) {
      expect(
        () => create(timeout),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'stopDrainTimeout',
          ),
        ),
      );
    }
  });

  test('StdinTransport logs omit inbound and outbound payloads', () async {
    const inboundSecret = 'stdin-inbound-secret';
    const outboundSecret = 'stdin-outbound-secret';
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final logger = Logger(
      'stdin.payload-free.${DateTime.now().microsecondsSinceEpoch}',
    );
    final messages = <String>[];
    final logSubscription = logger.onRecord.listen(
      (record) => messages.add(record.message),
    );
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: logger,
      inputStream: input.stream,
      outputSink: output,
    );

    try {
      await transport.start();
      final inbound = transport.channel.stream.first;
      input.add(utf8.encode('$inboundSecret\n'));
      transport.channel.sink.add(outboundSecret);
      expect(await inbound, inboundSecret);
      await output.flush();

      expect(messages.join('\n'), isNot(contains(inboundSecret)));
      expect(messages.join('\n'), isNot(contains(outboundSecret)));
    } finally {
      Logger.root.level = previousLevel;
      await logSubscription.cancel();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport bounds a paused inbound consumer', () async {
    final input = StreamController<List<int>>(sync: true);
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxInboundQueueItems: 1,
      maxInboundQueueBytes: 64,
      inputStream: input.stream,
      outputSink: output,
    );
    final lines = <String>[];
    final errors = <Object>[];
    final done = Completer<void>();

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        lines.add,
        onError: errors.add,
        onDone: done.complete,
      );
      subscription.pause();
      input.add(utf8.encode('one\ntwo\n'));
      await _waitFor(() => !input.hasListener);
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 1));

      expect(lines, isEmpty);
      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin input queue items',
            )
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
      );
      await subscription.cancel();
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport bounds paused inbound UTF-8 bytes', () async {
    final input = StreamController<List<int>>(sync: true);
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxInboundQueueItems: 8,
      maxInboundQueueBytes: 3,
      inputStream: input.stream,
      outputSink: output,
    );
    final errors = <Object>[];
    final done = Completer<void>();

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      subscription.pause();
      input.add(utf8.encode('é\né\n'));
      await _waitFor(() => !input.hasListener);
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 1));

      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin input queue bytes',
            )
            .having((error) => error.limit, 'limit', 3)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
      );
      await subscription.cancel();
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport bounds pending outbound writes', () async {
    final input = StreamController<List<int>>();
    final outputConsumer = _BlockingStreamConsumer();
    final output = IOSink(outputConsumer);
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxOutboundQueueItems: 1,
      maxOutboundQueueBytes: 64,
      inputStream: input.stream,
      outputSink: output,
    );
    final errors = <Object>[];

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );
      transport.channel.sink
        ..add('first')
        ..add('second');
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin output queue items',
            )
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
      );
      expect(outputConsumer.text, isEmpty);
      await subscription.cancel();
    } finally {
      outputConsumer.release();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport bounds pending outbound UTF-8 bytes', () async {
    final input = StreamController<List<int>>();
    final outputConsumer = _BlockingStreamConsumer();
    final output = IOSink(outputConsumer);
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxOutboundQueueItems: 8,
      maxOutboundQueueBytes: 3,
      inputStream: input.stream,
      outputSink: output,
    );
    final errors = <Object>[];

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );
      transport.channel.sink
        ..add('é')
        ..add('é');
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin output queue bytes',
            )
            .having((error) => error.limit, 'limit', 3)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
      );
      expect(outputConsumer.text, isEmpty);
      await subscription.cancel();
    } finally {
      outputConsumer.release();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport stop does not wait for a paused listener', () async {
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      inputStream: input.stream,
      outputSink: output,
    );
    StreamSubscription<String>? subscription;

    try {
      await transport.start();
      subscription = transport.channel.stream.listen((_) {});
      subscription.pause();

      await expectLater(
        transport.stop().timeout(const Duration(milliseconds: 200)),
        completes,
      );
    } finally {
      subscription?.resume();
      await subscription?.cancel();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport serializes restart behind an active flush', () async {
    final input = _RestartableInputStream();
    final outputConsumer = _BlockingStreamConsumer();
    final output = IOSink(outputConsumer);
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      inputStream: input,
      outputSink: output,
    );

    try {
      await transport.start();
      transport.channel.sink.add('old generation');
      await outputConsumer.started.future;

      var stopCompleted = false;
      final stop = transport.stop().then((_) => stopCompleted = true);
      var restartCompleted = false;
      final restart = transport.start().then((_) => restartCompleted = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(stopCompleted, isFalse);
      expect(restartCompleted, isFalse);
      expect(input.listenCount, 1);

      outputConsumer.release();
      await stop.timeout(const Duration(seconds: 1));
      await restart.timeout(const Duration(seconds: 1));
      expect(input.listenCount, 2);

      transport.channel.sink.add('new generation');
      await _waitFor(() => outputConsumer.text.contains('new generation\n'));
      expect(outputConsumer.text, 'old generation\nnew generation\n');
    } finally {
      outputConsumer.release();
      await transport.stop();
      await output.close();
    }
  });

  test(
    'StdinTransport bounds stop and restart behind a permanently blocked flush',
    () async {
      final input = _RestartableControlledInputStream();
      final outputConsumer = _BlockingStreamConsumer();
      final output = IOSink(outputConsumer);
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxOutboundQueueItems: 1,
        maxOutboundQueueBytes: 32,
        stopDrainTimeout: const Duration(milliseconds: 40),
        inputStream: input,
        outputSink: output,
      );
      StreamSubscription<String>? restartedSubscription;

      try {
        await transport.start();
        transport.channel.sink.add('old generation');
        await outputConsumer.started.future;

        await transport.stop().timeout(const Duration(milliseconds: 500));
        expect(() => transport.channel, throwsStateError);

        await transport.start().timeout(const Duration(seconds: 1));
        expect(input.listenCount, 2);
        final restartedLines = <String>[];
        final restartedErrors = <Object>[];
        restartedSubscription = transport.channel.stream.listen(
          restartedLines.add,
          onError: restartedErrors.add,
        );
        input.addLine('new inbound');
        await _waitFor(() => restartedLines.isNotEmpty);

        // The stopped generation must not retain its one-item queue budget.
        transport.channel.sink.add('new generation');
        outputConsumer.release();
        await _waitFor(() => outputConsumer.text.contains('new generation\n'));

        expect(restartedLines, <String>['new inbound']);
        expect(restartedErrors, isEmpty);
        expect(outputConsumer.text, 'old generation\nnew generation\n');
      } finally {
        outputConsumer.release();
        await restartedSubscription?.cancel();
        await transport.stop();
        await input.close();
        await output.close();
      }
    },
  );

  test(
    'StdinTransport ignores a late old-generation flush error after restart',
    () async {
      final zoneErrors = <Object>[];
      final bodyDone = Completer<void>();
      late StdinTransport transport;

      runZonedGuarded(() async {
        final input = _RestartableControlledInputStream();
        final outputConsumer = _BlockingStreamConsumer();
        final output = IOSink(outputConsumer);
        transport = StdinTransport(
          logger: AcpConfig().logger,
          stopDrainTimeout: const Duration(milliseconds: 40),
          inputStream: input,
          outputSink: output,
        );
        StreamSubscription<String>? restartedSubscription;
        try {
          await transport.start();
          transport.channel.sink.add('old generation');
          await outputConsumer.started.future;
          await transport.stop().timeout(const Duration(milliseconds: 500));
          await transport.start().timeout(const Duration(seconds: 1));

          final restartedLines = <String>[];
          final restartedErrors = <Object>[];
          restartedSubscription = transport.channel.stream.listen(
            restartedLines.add,
            onError: restartedErrors.add,
          );
          input.addLine('before late error');
          await _waitFor(() => restartedLines.isNotEmpty);

          outputConsumer.fail(StateError('late old flush failure'));
          await Future<void>.delayed(const Duration(milliseconds: 50));
          input.addLine('after late error');
          await _waitFor(() => restartedLines.length == 2);

          expect(restartedLines, <String>[
            'before late error',
            'after late error',
          ]);
          expect(restartedErrors, isEmpty);
          expect(transport.channel, isNotNull);
        } finally {
          outputConsumer.release();
          await restartedSubscription?.cancel();
          await transport.stop();
          await input.close();
          try {
            await output.close();
          } on Object {
            // The synthetic old-generation sink failure is expected.
          }
          if (!bodyDone.isCompleted) bodyDone.complete();
        }
      }, (error, _) => zoneErrors.add(error));

      await bodyDone.future.timeout(const Duration(seconds: 4));
      expect(zoneErrors, isEmpty);
      expect(() => transport.channel, throwsStateError);
    },
  );

  test(
    'StdinTransport bounds stop and restart when input cancel never completes',
    () async {
      final zoneErrors = <Object>[];
      final bodyDone = Completer<void>();
      late StdinTransport transport;

      runZonedGuarded(() async {
        final input = _SequencedInputStream(failSynchronously: false);
        final output = IOSink(_DiscardStreamConsumer());
        transport = StdinTransport(
          logger: AcpConfig().logger,
          stopDrainTimeout: const Duration(milliseconds: 40),
          inputStream: input,
          outputSink: output,
        );
        StreamSubscription<String>? restartedSubscription;
        try {
          await transport.start();
          final stop = transport.stop();
          await input.firstCancelStarted.future;
          final restart = transport.start();

          await stop.timeout(const Duration(milliseconds: 500));
          await restart.timeout(const Duration(milliseconds: 500));
          expect(input.listenCount, 2);

          final restartedLines = <String>[];
          final restartedErrors = <Object>[];
          restartedSubscription = transport.channel.stream.listen(
            restartedLines.add,
            onError: restartedErrors.add,
          );
          input.addLine('before late cancel');
          await _waitFor(() => restartedLines.isNotEmpty);

          input.releaseFirstCancel.completeError(
            StateError('late old cancel failure'),
            StackTrace.current,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
          input.addLine('after late cancel');
          await _waitFor(() => restartedLines.length == 2);

          expect(restartedLines, <String>[
            'before late cancel',
            'after late cancel',
          ]);
          expect(restartedErrors, isEmpty);
        } finally {
          if (!input.releaseFirstCancel.isCompleted) {
            input.releaseFirstCancel.complete();
          }
          await restartedSubscription?.cancel();
          await transport.stop().timeout(const Duration(milliseconds: 500));
          await output.close();
          if (!bodyDone.isCompleted) bodyDone.complete();
        }
      }, (error, _) => zoneErrors.add(error));

      await bodyDone.future.timeout(const Duration(seconds: 2));
      expect(zoneErrors, isEmpty);
      expect(() => transport.channel, throwsStateError);
    },
  );

  test(
    'StdinTransport drops an inbound frame when onProtocolIn stops transport',
    () async {
      final input = StreamController<List<int>>(sync: true);
      final output = IOSink(_DiscardStreamConsumer());
      final observed = <String>[];
      final received = <String>[];
      final errors = <Object>[];
      Future<void>? observerStop;
      late final StdinTransport transport;
      transport = StdinTransport(
        logger: AcpConfig().logger,
        inputStream: input.stream,
        outputSink: output,
        onProtocolIn: (line) {
          observed.add(line);
          observerStop = transport.stop();
        },
      );
      StreamSubscription<String>? subscription;

      try {
        await transport.start();
        subscription = transport.channel.stream.listen(
          received.add,
          onError: errors.add,
        );
        input.add(utf8.encode('stopped inbound\n'));
        await _waitFor(() => observerStop != null);
        await observerStop!.timeout(const Duration(seconds: 1));

        expect(observed, <String>['stopped inbound']);
        expect(received, isEmpty);
        expect(errors, isEmpty);
        expect(() => transport.channel, throwsStateError);
      } finally {
        await subscription?.cancel();
        await observerStop?.timeout(const Duration(seconds: 1));
        await transport.stop().timeout(const Duration(seconds: 1));
        await input.close();
        await output.close();
      }
    },
  );

  test(
    'StdinTransport drops an outbound frame when onProtocolOut stops transport',
    () async {
      final input = StreamController<List<int>>();
      final outputConsumer = _RecordingStreamConsumer();
      final output = IOSink(outputConsumer);
      final observed = <String>[];
      Future<void>? observerStop;
      late final StdinTransport transport;
      transport = StdinTransport(
        logger: AcpConfig().logger,
        inputStream: input.stream,
        outputSink: output,
        onProtocolOut: (line) {
          observed.add(line);
          observerStop = transport.stop();
        },
      );

      try {
        await transport.start();
        transport.channel.sink.add('stopped outbound');
        await _waitFor(() => observerStop != null);
        await observerStop!.timeout(const Duration(seconds: 1));

        expect(observed, <String>['stopped outbound']);
        expect(outputConsumer.text, isEmpty);
        expect(() => transport.channel, throwsStateError);
      } finally {
        await observerStop?.timeout(const Duration(seconds: 1));
        await transport.stop().timeout(const Duration(seconds: 1));
        await input.close();
        await output.close();
      }
    },
  );

  test('StdinTransport counts an observer-active inbound item', () async {
    final input = StreamController<List<int>>(sync: true);
    final output = IOSink(_DiscardStreamConsumer());
    final lines = <String>[];
    final errors = <Object>[];
    late final StdinTransport transport;
    transport = StdinTransport(
      logger: AcpConfig().logger,
      maxInboundQueueItems: 1,
      maxInboundQueueBytes: 64,
      inputStream: input.stream,
      outputSink: output,
      onProtocolIn: (line) {
        if (line == 'first') input.add(utf8.encode('second\n'));
      },
    );

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        lines.add,
        onError: errors.add,
      );
      input.add(utf8.encode('first\n'));
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, isEmpty);
      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin input queue items',
            )
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
      );
      await subscription.cancel();
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport counts observer-active inbound UTF-8 bytes', () async {
    final input = StreamController<List<int>>(sync: true);
    final output = IOSink(_DiscardStreamConsumer());
    final errors = <Object>[];
    var injected = false;
    late final StdinTransport transport;
    transport = StdinTransport(
      logger: AcpConfig().logger,
      maxInboundQueueItems: 8,
      maxInboundQueueBytes: 3,
      inputStream: input.stream,
      outputSink: output,
      onProtocolIn: (_) {
        if (injected) return;
        injected = true;
        input.add(utf8.encode('é\n'));
      },
    );

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );
      input.add(utf8.encode('é\n'));
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdin input queue bytes',
            )
            .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
      );
      await subscription.cancel();
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test(
    'StdinTransport clears active inbound bytes after exact budget',
    () async {
      final input = StreamController<List<int>>(sync: true);
      final output = IOSink(_DiscardStreamConsumer());
      final lines = <String>[];
      final errors = <Object>[];
      var injected = false;
      final transport = StdinTransport(
        logger: AcpConfig().logger,
        maxInboundQueueItems: 8,
        maxInboundQueueBytes: 4,
        inputStream: input.stream,
        outputSink: output,
        onProtocolIn: (_) {
          if (injected) return;
          injected = true;
          input.add(utf8.encode('é\n'));
        },
      );

      try {
        await transport.start();
        final subscription = transport.channel.stream.listen(
          lines.add,
          onError: errors.add,
        );
        input.add(utf8.encode('é\n'));
        await _waitFor(() => lines.length == 2);

        input.add(utf8.encode('éé\n'));
        await _waitFor(() => lines.length == 3 || errors.isNotEmpty);

        expect(lines, <String>['é', 'é', 'éé']);
        expect(errors, isEmpty);
        await subscription.cancel();
      } finally {
        await transport.stop();
        await input.close();
        await output.close();
      }
    },
  );

  test('StdinTransport retains a frame paused by its observer', () async {
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final lines = <String>[];
    final observed = <String>[];
    final observerPaused = Completer<void>();
    late StreamSubscription<String> subscription;
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      inputStream: input.stream,
      outputSink: output,
      onProtocolIn: (line) {
        observed.add(line);
        subscription.pause();
        if (!observerPaused.isCompleted) observerPaused.complete();
      },
    );

    try {
      await transport.start();
      subscription = transport.channel.stream.listen(lines.add);
      input.add(utf8.encode('retained\n'));
      await observerPaused.future;
      expect(lines, isEmpty);

      subscription.resume();
      await _waitFor(() => lines.isNotEmpty);
      expect(lines, <String>['retained']);
      expect(observed, <String>['retained']);
    } finally {
      subscription.resume();
      await subscription.cancel();
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport listener cancellation cancels input', () async {
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final observed = <String>[];
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      inputStream: input.stream,
      outputSink: output,
      onProtocolIn: observed.add,
    );

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen((_) {});
      await subscription.cancel();
      await _waitFor(() => !input.hasListener);

      input.add(utf8.encode('late\n'));
      await Future<void>.delayed(Duration.zero);
      expect(observed, isEmpty);
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
  });

  test('StdinTransport publishes the first terminal failure only', () async {
    final input = StreamController<List<int>>();
    final output = IOSink(_DiscardStreamConsumer());
    final errors = <Object>[];
    final done = Completer<void>();
    final transport = StdinTransport(
      logger: AcpConfig().logger,
      maxLineBytes: 1,
      inputStream: input.stream,
      outputSink: output,
    );

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
        onDone: done.complete,
      );
      subscription.pause();
      input.add(utf8.encode('xx\n'));
      await _waitFor(() => !input.hasListener);
      transport.channel.sink.add('yy');
      subscription.resume();
      await done.future.timeout(const Duration(seconds: 1));

      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<TransportByteLimitExceeded>().having(
          (error) => error.resource,
          'resource',
          'stdin input line',
        ),
      );
      await subscription.cancel();
    } finally {
      await transport.stop();
      await input.close();
      await output.close();
    }
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

  test('StdinTransport bounds synchronous failed-start cancellation', () async {
    final zoneErrors = <Object>[];
    final bodyDone = Completer<void>();
    late StdinTransport transport;

    runZonedGuarded(() async {
      final input = _SequencedInputStream();
      final output = IOSink(_DiscardStreamConsumer());
      transport = StdinTransport(
        logger: AcpConfig().logger,
        maxLineBytes: 4,
        stopDrainTimeout: const Duration(milliseconds: 40),
        inputStream: input,
        outputSink: output,
      );
      StreamSubscription<String>? restartedSubscription;
      try {
        await expectLater(
          transport.start().timeout(const Duration(milliseconds: 500)),
          throwsA(isA<TransportByteLimitExceeded>()),
        );
        expect(() => transport.channel, throwsStateError);

        await transport.start().timeout(const Duration(milliseconds: 500));
        expect(input.listenCount, 2);
        final restartedLines = <String>[];
        final restartedErrors = <Object>[];
        restartedSubscription = transport.channel.stream.listen(
          restartedLines.add,
          onError: restartedErrors.add,
        );
        input.addLine('one');
        await _waitFor(() => restartedLines.isNotEmpty);

        input.releaseFirstCancel.completeError(
          StateError('late failed-start cancel failure'),
          StackTrace.current,
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        input.addLine('two');
        await _waitFor(() => restartedLines.length == 2);

        expect(restartedLines, <String>['one', 'two']);
        expect(restartedErrors, isEmpty);
      } finally {
        if (!input.releaseFirstCancel.isCompleted) {
          input.releaseFirstCancel.complete();
        }
        await restartedSubscription?.cancel();
        await transport.stop().timeout(const Duration(milliseconds: 500));
        await output.close();
        if (!bodyDone.isCompleted) bodyDone.complete();
      }
    }, (error, _) => zoneErrors.add(error));

    await bodyDone.future.timeout(const Duration(seconds: 2));
    expect(zoneErrors, isEmpty);
    expect(() => transport.channel, throwsStateError);
  });

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

class _BlockingStreamConsumer implements StreamConsumer<List<int>> {
  final Completer<void> _release = Completer<void>();
  final Completer<void> started = Completer<void>();
  final List<int> _bytes = <int>[];

  String get text => utf8.decode(_bytes);

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  void fail(Object error) {
    if (!_release.isCompleted) {
      _release.completeError(error, StackTrace.current);
    }
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    if (!started.isCompleted) started.complete();
    await _release.future;
    await for (final chunk in stream) {
      _bytes.addAll(chunk);
    }
  }

  @override
  Future<void> close() async {}
}

class _RestartableInputStream extends Stream<List<int>> {
  var listenCount = 0;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount += 1;
    return _SynchronousSubscription<List<int>>();
  }
}

class _RestartableControlledInputStream extends Stream<List<int>> {
  final StreamController<List<int>> _controller =
      StreamController<List<int>>.broadcast(sync: true);
  var listenCount = 0;

  void addLine(String line) => _controller.add(utf8.encode('$line\n'));

  Future<void> close() => _controller.close();

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount += 1;
    return _controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
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
  _SequencedInputStream({this.failSynchronously = true});

  final bool failSynchronously;
  final firstCancelStarted = Completer<void>();
  final releaseFirstCancel = Completer<void>();
  var listenCount = 0;
  void Function(List<int>)? _onData;

  void addLine(String line) => _onData?.call(utf8.encode('$line\n'));

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCount += 1;
    _onData = onData;
    if (listenCount == 1) {
      final subscription = _DeferredCancelSubscription<List<int>>(
        firstCancelStarted,
        releaseFirstCancel,
      );
      if (failSynchronously) onData?.call(utf8.encode('12345\n'));
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
