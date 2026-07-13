import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/line_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('line byte budgets must be positive at runtime', () {
    final process = _BlockingStdinProcess();

    expect(
      () => LineJsonChannel(process, maxLineBytes: 0),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxLineBytes')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
    expect(
      () => LineJsonChannel(process, maxStderrLineBytes: 0),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxStderrLineBytes')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
  });

  test('outbound queue budgets must be positive', () {
    final process = _BlockingStdinProcess();

    expect(
      () => LineJsonChannel(process, maxOutboundQueueItems: 0),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxOutboundQueueItems')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
    expect(
      () => LineJsonChannel(process, maxOutboundQueueBytes: -1),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxOutboundQueueBytes')
            .having((error) => error.invalidValue, 'invalidValue', -1),
      ),
    );
    expect(
      () => LineJsonChannel(process, disposeDrainTimeout: Duration.zero),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'disposeDrainTimeout')
            .having(
              (error) => error.invalidValue,
              'invalidValue',
              Duration.zero,
            ),
      ),
    );
  });

  test('stdout counts raw UTF-8 bytes across chunks before decoding', () async {
    final process = await Process.start('/bin/sh', <String>[
      '-c',
      "printf '\\303\\251'; sleep 0.05; printf 'x\\n'; sleep 1",
    ]);
    final channel = LineJsonChannel(process, maxLineBytes: 2);
    final errors = <Object>[];
    final lines = <String>[];
    final subscription = channel.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );

    try {
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, isEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.resource, 'resource', contains('stdout')),
      );
    } finally {
      await subscription.cancel();
      await channel.dispose();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  });

  test('stdout preserves CRLF and dispatches a final EOF line', () async {
    final process = await Process.start('/bin/sh', <String>[
      '-c',
      "printf '\\303\\251\\r\\nlast'",
    ]);
    final channel = LineJsonChannel(process, maxLineBytes: 4);
    final lines = await channel.channel.stream.toList();

    expect(lines, <String>['é', 'last']);
    await channel.dispose();
    await process.exitCode;
  });

  test('stdout decodes UTF-8 across a 64 KiB segment boundary', () async {
    const segmentBytes = 64 * 1024;
    final process = _BlockingStdinProcess();
    final channel = LineJsonChannel(process, maxLineBytes: segmentBytes + 1);
    final lines = <String>[];
    final errors = <Object>[];
    final subscription = channel.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );
    final bytes = List<int>.filled(segmentBytes - 1, 0x61, growable: true)
      ..addAll(const <int>[0xc3, 0xa9, 0x0a]);

    try {
      process
        ..addStdout(bytes.sublist(0, segmentBytes))
        ..addStdout(bytes.sublist(segmentBytes));
      await _waitFor(() => lines.isNotEmpty);

      expect(errors, isEmpty);
      expect(lines.single.length, segmentBytes);
      expect(lines.single.endsWith('é'), isTrue);
    } finally {
      await subscription.cancel();
      await channel.dispose();
      process.releaseWrites();
    }
  });

  test('stdout reports invalid UTF-8 as a protocol decode error', () async {
    final process = await Process.start('/bin/sh', <String>[
      '-c',
      "printf '\\377\\n'; sleep 1",
    ]);
    final channel = LineJsonChannel(process);
    final lines = <String>[];
    final errors = <Object>[];
    final subscription = channel.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );

    try {
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, isEmpty);
      expect(
        errors.single,
        isA<acp.TransportProtocolDecodeError>().having(
          (error) => error.resource,
          'resource',
          'stdio stdout line',
        ),
      );
    } finally {
      await subscription.cancel();
      await channel.dispose();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  });

  test(
    'stdout unfinished UTF-8 at direct EOF reports exactly one decode error',
    () async {
      final process = await Process.start('/bin/sh', <String>[
        '-c',
        "printf '\\303'",
      ]);
      final channel = LineJsonChannel(process);
      final lines = <String>[];
      final errors = <Object>[];
      final done = Completer<void>();
      final subscription = channel.channel.stream.listen(
        lines.add,
        onError: errors.add,
        onDone: done.complete,
      );

      try {
        await done.future.timeout(const Duration(seconds: 2));

        expect(lines, isEmpty);
        expect(errors, hasLength(1));
        expect(
          errors.single,
          isA<acp.TransportProtocolDecodeError>().having(
            (error) => error.resource,
            'resource',
            'stdio stdout line',
          ),
        );
      } finally {
        await subscription.cancel();
        await channel.dispose();
        await process.exitCode;
      }
    },
  );

  test(
    'stderr truncates one oversized line and resumes after newline',
    () async {
      final process = await Process.start('/bin/sh', <String>[
        '-c',
        "printf 'abcdef' >&2; sleep 0.05; printf '\\nok\\n' >&2",
      ]);
      final diagnostics = <String>[];
      final channel = LineJsonChannel(
        process,
        maxStderrLineBytes: 3,
        onStderr: diagnostics.add,
      );
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: (_) {},
      );

      await process.exitCode;
      await _waitFor(() => diagnostics.length >= 2);

      expect(diagnostics, <String>['truncated', 'ok']);
      await subscription.cancel();
      await channel.dispose();
    },
  );

  test('stderr replaces invalid UTF-8 and resumes after newline', () async {
    final process = await Process.start('/bin/sh', <String>[
      '-c',
      "printf '\\377\\nok\\n' >&2",
    ]);
    final diagnostics = <String>[];
    final channel = LineJsonChannel(process, onStderr: diagnostics.add);
    final subscription = channel.channel.stream.listen((_) {}, onError: (_) {});

    await process.exitCode;
    await _waitFor(() => diagnostics.length == 2);

    expect(diagnostics, <String>['truncated', 'ok']);
    await subscription.cancel();
    await channel.dispose();
  });

  test('outbound rejects oversized UTF-8 before writing stdin', () async {
    final process = await Process.start('/bin/cat', const <String>[]);
    final channel = LineJsonChannel(process, maxLineBytes: 4);
    final lines = <String>[];
    final errors = <Object>[];
    final subscription = channel.channel.stream.listen(
      lines.add,
      onError: errors.add,
    );

    try {
      channel.channel.sink.add('ééx');
      await _waitFor(() => errors.isNotEmpty);

      expect(lines, isEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.resource, 'resource', contains('stdin')),
      );
    } finally {
      await subscription.cancel();
      await channel.dispose();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  });

  test(
    'outbound drops queued and later lines after an oversized line',
    () async {
      final process = await Process.start('/bin/cat', const <String>[]);
      final outboundLines = <String>[];
      final channel = LineJsonChannel(
        process,
        maxLineBytes: 4,
        onOutboundLine: outboundLines.add,
      );
      final errors = <Object>[];
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );

      try {
        channel.channel.sink
          ..add('ok')
          ..add('12345')
          ..add('no');
        await _waitFor(() => errors.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(outboundLines, isEmpty);
        expect(errors.single, isA<acp.TransportByteLimitExceeded>());
      } finally {
        await subscription.cancel();
        await channel.dispose();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    },
  );

  test('outbound item budget accepts the exact active boundary', () async {
    final process = _BlockingStdinProcess();
    final outboundLines = <String>[];
    final channel = LineJsonChannel(
      process,
      maxOutboundQueueItems: 2,
      onOutboundLine: outboundLines.add,
    );
    final subscription = channel.channel.stream.listen((_) {}, onError: (_) {});

    try {
      channel.channel.sink.add('first');
      await process.writeStarted.timeout(const Duration(seconds: 1));
      channel.channel.sink.add('second');

      process.releaseWrites();
      await channel.dispose().timeout(const Duration(seconds: 1));

      expect(outboundLines, <String>['first', 'second']);
      expect(process.lines, <String>['first', 'second']);
    } finally {
      process.releaseWrites();
      await subscription.cancel();
      await channel.dispose();
    }
  });

  test(
    'outbound item overflow counts active write and drops queued payloads',
    () async {
      const activePayload = 'active-secret';
      const queuedPayload = 'queued-secret';
      const overflowPayload = 'overflow-secret';
      final process = _BlockingStdinProcess();
      final outboundLines = <String>[];
      final errors = <Object>[];
      final channel = LineJsonChannel(
        process,
        maxOutboundQueueItems: 2,
        onOutboundLine: outboundLines.add,
      );
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );

      try {
        channel.channel.sink.add(activePayload);
        await process.writeStarted.timeout(const Duration(seconds: 1));
        channel.channel.sink
          ..add(queuedPayload)
          ..add(overflowPayload);
        await _waitFor(() => errors.isNotEmpty);

        expect(outboundLines, <String>[activePayload]);
        expect(
          errors.single,
          isA<acp.TransportByteLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'stdio stdin queue items',
              )
              .having((error) => error.limit, 'limit', 2)
              .having((error) => error.observedAtLeast, 'observedAtLeast', 3),
        );
        expect(errors.single.toString(), isNot(contains(queuedPayload)));
        expect(errors.single.toString(), isNot(contains(overflowPayload)));

        await channel.dispose().timeout(const Duration(milliseconds: 200));
        expect(process.lines, isEmpty);
        process.releaseWrites();
        await _waitFor(() => process.lines.isNotEmpty);
        expect(process.lines, <String>[activePayload]);
      } finally {
        process.releaseWrites();
        await subscription.cancel();
        await channel.dispose();
      }
    },
  );

  test('outbound byte budget accepts exact UTF-8 boundary', () async {
    final process = _BlockingStdinProcess();
    final channel = LineJsonChannel(process, maxOutboundQueueBytes: 4);
    final subscription = channel.channel.stream.listen((_) {}, onError: (_) {});

    try {
      channel.channel.sink.add('é');
      await process.writeStarted.timeout(const Duration(seconds: 1));
      channel.channel.sink.add('é');

      process.releaseWrites();
      await channel.dispose().timeout(const Duration(seconds: 1));

      expect(process.lines, <String>['é', 'é']);
    } finally {
      process.releaseWrites();
      await subscription.cancel();
      await channel.dispose();
    }
  });

  test('outbound byte overflow counts active UTF-8 bytes', () async {
    final process = _BlockingStdinProcess();
    final errors = <Object>[];
    final channel = LineJsonChannel(process, maxOutboundQueueBytes: 4);
    final subscription = channel.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      channel.channel.sink.add('é');
      await process.writeStarted.timeout(const Duration(seconds: 1));
      channel.channel.sink
        ..add('é')
        ..add('x');
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdio stdin queue bytes',
            )
            .having((error) => error.limit, 'limit', 4)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 5),
      );
      await channel.dispose().timeout(const Duration(milliseconds: 200));
      expect(process.lines, isEmpty);
      process.releaseWrites();
      await _waitFor(() => process.lines.isNotEmpty);
      expect(process.lines, <String>['é']);
    } finally {
      process.releaseWrites();
      await subscription.cancel();
      await channel.dispose();
    }
  });

  test(
    'synchronous outbound burst cannot hide in the channel controller',
    () async {
      final process = _BlockingStdinProcess();
      final outboundLines = <String>[];
      final errors = <Object>[];
      final channel = LineJsonChannel(
        process,
        maxOutboundQueueItems: 3,
        onOutboundLine: outboundLines.add,
      );
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );

      try {
        channel.channel.sink
          ..add('one')
          ..add('two')
          ..add('three')
          ..add('four')
          ..add('five');
        await _waitFor(() => errors.isNotEmpty);

        expect(outboundLines, isEmpty);
        expect(process.lines, isEmpty);
        expect(
          errors.single,
          isA<acp.TransportByteLimitExceeded>()
              .having(
                (error) => error.resource,
                'resource',
                'stdio stdin queue items',
              )
              .having((error) => error.observedAtLeast, 'observedAtLeast', 4),
        );
      } finally {
        process.releaseWrites();
        await subscription.cancel();
        await channel.dispose();
      }
    },
  );

  test('outbound writes preserve strict message order', () async {
    final process = await Process.start('/bin/cat', const <String>[]);
    final channel = LineJsonChannel(process);
    final linesFuture = channel.channel.stream.take(3).toList();

    try {
      channel.channel.sink
        ..add('first')
        ..add('second')
        ..add('third');

      expect(await linesFuture.timeout(const Duration(seconds: 2)), <String>[
        'first',
        'second',
        'third',
      ]);
    } finally {
      await channel.dispose();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  });

  test(
    'immediate dispose is idempotent and waits for accepted writes',
    () async {
      final process = await Process.start('/bin/cat', const <String>[]);
      final outboundLines = <String>[];
      final channel = LineJsonChannel(
        process,
        onOutboundLine: outboundLines.add,
      );
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: (_) {},
      );
      const expected = <String>['first', 'second', 'third'];

      try {
        channel.channel.sink
          ..add(expected[0])
          ..add(expected[1])
          ..add(expected[2]);

        final firstDispose = channel.dispose();
        final secondDispose = channel.dispose();
        expect(identical(firstDispose, secondDispose), isTrue);
        await firstDispose;

        expect(outboundLines, expected);
      } finally {
        await subscription.cancel();
        await channel.dispose();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    },
  );

  test(
    'immediate dispose without an inbound listener flushes accepted writes',
    () async {
      final process = await Process.start('/bin/cat', const <String>[]);
      final outboundLines = <String>[];
      final channel = LineJsonChannel(
        process,
        onOutboundLine: outboundLines.add,
      );
      const expected = <String>['first', 'second'];

      try {
        channel.channel.sink
          ..add(expected[0])
          ..add(expected[1]);

        await channel.dispose().timeout(const Duration(seconds: 1));

        expect(outboundLines, expected);
      } finally {
        final inboundDone = Completer<void>();
        final subscription = channel.channel.stream.listen(
          (_) {},
          onError: (_) {},
          onDone: inboundDone.complete,
        );
        await inboundDone.future.timeout(const Duration(seconds: 2));
        await subscription.cancel();
        await channel.dispose();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    },
  );

  test(
    'dispose completes without an inbound listener after stdin flush fails',
    () async {
      const payload = 'secret outbound payload';
      final process = _FailingStdinProcess('write failed for $payload');
      final channel = LineJsonChannel(process);

      channel.channel.sink.add(payload);
      await process.writeFailed.timeout(const Duration(seconds: 1));

      await channel.dispose().timeout(const Duration(milliseconds: 200));
    },
  );

  test('dispose bounds a stdin flush that never completes', () async {
    final process = _BlockingStdinProcess();
    final channel = LineJsonChannel(process);
    final subscription = channel.channel.stream.listen((_) {}, onError: (_) {});

    try {
      channel.channel.sink.add('accepted-before-dispose');
      await process.writeStarted.timeout(const Duration(seconds: 1));

      final stopwatch = Stopwatch()..start();
      await channel.dispose().timeout(const Duration(seconds: 1));
      stopwatch.stop();

      expect(
        stopwatch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 400)),
      );
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
      expect(process.lines, isEmpty);
    } finally {
      process.releaseWrites();
      await subscription.cancel();
      await channel.dispose();
    }
  });

  test(
    'dispose caches its Future before synchronous inbound onDone reentry',
    () async {
      final process = _BlockingStdinProcess();
      final channel = LineJsonChannel(process);
      final inboundDone = Completer<void>();
      Future<void>? reentrantDispose;
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: (_) {},
        onDone: () {
          reentrantDispose = channel.dispose();
          inboundDone.complete();
        },
      );

      try {
        channel.channel.sink.add('active');
        await process.writeStarted.timeout(const Duration(seconds: 1));

        final firstDispose = channel.dispose();
        await inboundDone.future.timeout(const Duration(seconds: 1));

        expect(identical(firstDispose, reentrantDispose), isTrue);
        await firstDispose.timeout(const Duration(seconds: 1));
        process.releaseWrites();
        await _waitFor(() => process.stdinCloseCallCount == 1);
        expect(process.stdinCloseCallCount, 1);
      } finally {
        process.releaseWrites();
        await subscription.cancel();
        await channel.dispose();
      }
    },
  );

  test(
    'dispose handles a late stdin flush error after bounded abort',
    () async {
      final uncaught = <Object>[];

      await runZonedGuarded(() async {
        final process = _BlockingStdinProcess(
          lateFailure: StateError('late secret flush failure'),
        );
        final channel = LineJsonChannel(process);
        final subscription = channel.channel.stream.listen(
          (_) {},
          onError: (_) {},
        );

        try {
          channel.channel.sink.add('secret payload');
          await process.writeStarted.timeout(const Duration(seconds: 1));
          await channel.dispose().timeout(const Duration(seconds: 1));
          process.releaseWrites();
          await Future<void>.delayed(const Duration(milliseconds: 50));
        } finally {
          process.releaseWrites();
          await subscription.cancel();
          await channel.dispose();
        }
      }, (error, _) => uncaught.add(error));

      expect(uncaught, isEmpty);
    },
  );

  test(
    'dispose keeps stdout draining while accepted stdin is backpressured',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'line-channel-cross-backpressure-',
      );
      final script = File('${directory.path}/child.dart');
      final observed = File('${directory.path}/observed.log');
      final dartLookup = await Process.run('/usr/bin/which', <String>['dart']);
      if (dartLookup.exitCode != 0) {
        throw StateError('Dart executable is unavailable for child test.');
      }
      await script.writeAsString(r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final observed = File(args[0]);
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final marker = line.startsWith('first:') ? 'first' : 'second';
    observed.writeAsStringSync('$marker\n', mode: FileMode.append);
    stdout.add(List<int>.filled(1024 * 1024, 0x78));
    stdout.add(const <int>[0x0a]);
    await stdout.flush();
  }
}
''');
      final process = await Process.start(
        (dartLookup.stdout as String).trim(),
        <String>[script.path, observed.path],
      );
      final channel = LineJsonChannel(
        process,
        maxLineBytes: 3 * 1024 * 1024,
        disposeDrainTimeout: const Duration(seconds: 3),
      );
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: (_) {},
      );

      try {
        channel.channel.sink
          ..add('first:${'a' * (128 * 1024)}')
          ..add('second:${'b' * (2 * 1024 * 1024)}');

        await channel.dispose().timeout(const Duration(seconds: 5));
        await _waitFor(() {
          if (!observed.existsSync()) return false;
          return observed.readAsLinesSync().length == 2;
        });

        expect(await observed.readAsLines(), <String>['first', 'second']);
      } finally {
        await subscription.cancel();
        await channel.dispose();
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 2));
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'dispose timeout permits only the active write to finish late',
    () async {
      final process = _BlockingStdinProcess();
      final channel = LineJsonChannel(process, maxOutboundQueueItems: 3);
      final subscription = channel.channel.stream.listen(
        (_) {},
        onError: (_) {},
      );

      try {
        channel.channel.sink.add('active');
        await process.writeStarted.timeout(const Duration(seconds: 1));
        channel.channel.sink.add('queued');

        final disposeFuture = channel.dispose();
        channel.channel.sink.add('post-dispose');
        await disposeFuture.timeout(const Duration(seconds: 1));

        process.releaseWrites();
        await _waitFor(() => process.lines.isNotEmpty);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(process.lines, <String>['active']);
      } finally {
        process.releaseWrites();
        await subscription.cancel();
        await channel.dispose();
      }
    },
  );

  test('stdin flush failure reports a payload-free transport error', () async {
    const payload = 'secret outbound payload';
    final process = _FailingStdinProcess('write failed for $payload');
    final channel = LineJsonChannel(process);
    final errors = <Object>[];
    final subscription = channel.channel.stream.listen(
      (_) {},
      onError: errors.add,
    );

    try {
      channel.channel.sink.add(payload);
      await _waitFor(() => errors.isNotEmpty);

      expect(errors, hasLength(1));
      expect(
        errors.single,
        isA<acp.TransportWriteError>().having(
          (error) => error.resource,
          'resource',
          'stdio stdin write',
        ),
      );
      expect(errors.single.toString(), isNot(contains(payload)));
    } finally {
      await subscription.cancel();
      await channel.dispose();
    }
  });
}

Future<void> _waitFor(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition not met before timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FailingStdinProcess implements Process {
  _FailingStdinProcess(String failureMessage)
    : _consumer = _FailingStreamConsumer(failureMessage) {
    _stdin = IOSink(_consumer);
  }

  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final _FailingStreamConsumer _consumer;
  late final IOSink _stdin;

  Future<void> get writeFailed => _consumer.writeFailed;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCode.isCompleted) _exitCode.complete(-signal.signalNumber);
    return true;
  }
}

class _FailingStreamConsumer implements StreamConsumer<List<int>> {
  _FailingStreamConsumer(this.failureMessage);

  final String failureMessage;
  final Completer<void> _writeFailed = Completer<void>();

  Future<void> get writeFailed => _writeFailed.future;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
    if (!_writeFailed.isCompleted) _writeFailed.complete();
    throw StateError(failureMessage);
  }

  @override
  Future<void> close() async {}
}

class _BlockingStdinProcess implements Process {
  _BlockingStdinProcess({Object? lateFailure})
    : _consumer = _BlockingStreamConsumer(lateFailure) {
    _stdin = IOSink(_consumer);
  }

  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final _BlockingStreamConsumer _consumer;
  late final IOSink _stdin;

  Future<void> get writeStarted => _consumer.writeStarted;

  List<String> get lines => _consumer.lines;

  int get stdinCloseCallCount => _consumer.closeCount;

  void addStdout(List<int> bytes) => _stdoutController.add(bytes);

  void releaseWrites() => _consumer.release();

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 1;

  @override
  Stream<List<int>> get stderr => const Stream<List<int>>.empty();

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCode.isCompleted) _exitCode.complete(-signal.signalNumber);
    return true;
  }
}

class _BlockingStreamConsumer implements StreamConsumer<List<int>> {
  _BlockingStreamConsumer(this.lateFailure);

  final Object? lateFailure;
  final Completer<void> _writeStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  final List<String> lines = <String>[];
  var closeCount = 0;

  Future<void> get writeStarted => _writeStarted.future;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    final bytes = <int>[];
    await for (final chunk in stream) {
      bytes.addAll(chunk);
      if (!_writeStarted.isCompleted) _writeStarted.complete();
    }
    await _release.future;
    if (lateFailure case final failure?) throw failure;
    final text = utf8.decode(bytes);
    lines.addAll(text.split('\n').where((line) => line.isNotEmpty));
  }

  @override
  Future<void> close() async {
    closeCount++;
  }
}
