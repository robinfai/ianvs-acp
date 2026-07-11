import 'dart:async';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('StdioTransport rejects non-positive budgets at construction', () {
    expect(
      () => acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/false',
        maxLineBytes: 0,
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxLineBytes')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
    expect(
      () => acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/false',
        maxStderrLineBytes: -1,
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxStderrLineBytes')
            .having((error) => error.invalidValue, 'invalidValue', -1),
      ),
    );
  });

  test('StdioTransport forwards the configured line byte limit', () async {
    final transport = acp.StdioTransport(
      logger: acp.AcpConfig().logger,
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
