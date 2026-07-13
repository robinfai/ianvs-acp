import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/line_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
    'stdout invalid UTF-8 at direct EOF reports exactly one decode error',
    () async {
      final process = await Process.start('/bin/sh', <String>[
        '-c',
        "printf '\\377'",
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
  _BlockingStdinProcess() : _consumer = _BlockingStreamConsumer() {
    _stdin = IOSink(_consumer);
  }

  final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>();
  final Completer<int> _exitCode = Completer<int>();
  final _BlockingStreamConsumer _consumer;
  late final IOSink _stdin;

  Future<void> get writeStarted => _consumer.writeStarted;

  List<String> get lines => _consumer.lines;

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
  final Completer<void> _writeStarted = Completer<void>();
  final Completer<void> _release = Completer<void>();
  final List<String> lines = <String>[];

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
    final text = utf8.decode(bytes);
    lines.addAll(text.split('\n').where((line) => line.isNotEmpty));
  }

  @override
  Future<void> close() async {}
}
