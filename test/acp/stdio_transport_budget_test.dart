import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';

void main() {
  test('StdioTransport forwards the configured line byte limit', () async {
    final transport = acp.StdioTransport(
      logger: Logger('stdio-budget-test'),
      command: '/bin/sh',
      args: const <String>['-c', "printf '12345\\n'; sleep 1"],
      maxLineBytes: 4,
    );
    final errors = <Object>[];

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );
      addTearDown(subscription.cancel);

      await _waitFor(() => errors.isNotEmpty);
      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>().having(
          (error) => error.limit,
          'limit',
          4,
        ),
      );
    } finally {
      await transport.stop();
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
