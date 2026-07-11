import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/line_channel.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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

  test('dispose is idempotent and waits for queued writes', () async {
    final process = await Process.start('/bin/cat', const <String>[]);
    final outboundLines = <String>[];
    final channel = LineJsonChannel(process, onOutboundLine: outboundLines.add);
    final subscription = channel.channel.stream.listen((_) {}, onError: (_) {});
    const expected = <String>['first', 'second', 'third'];

    try {
      channel.channel.sink
        ..add(expected[0])
        ..add(expected[1])
        ..add(expected[2]);
      await Future<void>.delayed(Duration.zero);

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
  });

  test(
    'dispose completes without an inbound listener and flushes queued writes',
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
        await Future<void>.delayed(Duration.zero);

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
