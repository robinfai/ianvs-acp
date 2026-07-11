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
