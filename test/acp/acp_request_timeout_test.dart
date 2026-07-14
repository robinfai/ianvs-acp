import 'dart:async';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:stream_channel/stream_channel.dart';

final class _StartCountingTransport implements acp.AcpTransport {
  final StreamController<String> _input = StreamController<String>(sync: true);
  final StreamController<String> _output = StreamController<String>(sync: true);
  var startCount = 0;
  var stopCount = 0;

  @override
  StreamChannel<String> get channel =>
      StreamChannel<String>(_input.stream, _output.sink);

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  Future<void> dispose() async {
    final inputDone = _input.hasListener ? null : _input.stream.drain<void>();
    final outputDone = _output.hasListener
        ? null
        : _output.stream.drain<void>();
    await _input.close();
    await _output.close();
    await inputDone;
    await outputDone;
  }
}

final class _SecondValidationFailsTimeouts extends acp.AcpTimeouts {
  var validationCount = 0;

  @override
  void validate() {
    validationCount += 1;
    if (validationCount == 2) {
      throw ArgumentError('second validation');
    }
  }
}

final class _SecretToken {
  @override
  String toString() => 'TOKEN-CANARY';
}

void main() {
  test('ACP timeout defaults and validation are exact', () {
    const defaults = acp.AcpTimeouts();
    expect(defaults.initialize, const Duration(seconds: 15));
    expect(defaults.request, const Duration(seconds: 60));
    expect(defaults.prompt, const Duration(minutes: 30));
    expect(defaults.permission, const Duration(minutes: 5));
    expect(defaults.promptCancelGrace, const Duration(seconds: 2));

    final invalid = <acp.AcpTimeouts>[
      const acp.AcpTimeouts(initialize: Duration.zero),
      const acp.AcpTimeouts(initialize: Duration(microseconds: -1)),
      const acp.AcpTimeouts(request: Duration.zero),
      const acp.AcpTimeouts(request: Duration(microseconds: -1)),
      const acp.AcpTimeouts(prompt: Duration.zero),
      const acp.AcpTimeouts(prompt: Duration(microseconds: -1)),
      const acp.AcpTimeouts(permission: Duration.zero),
      const acp.AcpTimeouts(permission: Duration(microseconds: -1)),
      const acp.AcpTimeouts(promptCancelGrace: Duration.zero),
      const acp.AcpTimeouts(promptCancelGrace: Duration(microseconds: -1)),
    ];
    for (final timeouts in invalid) {
      expect(() => acp.AcpConfig(timeouts: timeouts), throwsArgumentError);
    }
  });

  test('invalid timeouts fail before transport construction', () async {
    final transport = _StartCountingTransport();
    final timeouts = _SecondValidationFailsTimeouts();
    final config = acp.AcpConfig(timeouts: timeouts);
    try {
      await expectLater(
        acp.AcpClient.start(config: config, transport: transport),
        throwsArgumentError,
      );
      expect(timeouts.validationCount, 2);
      expect(transport.startCount, 0);
      expect(transport.stopCount, 0);
      expect(
        () => DartAcpAgentClient(
          timeouts: const acp.AcpTimeouts(request: Duration.zero),
        ),
        throwsArgumentError,
      );
    } finally {
      await transport.dispose();
    }
  });

  test('timeout exceptions and cancellation tokens do not leak context', () {
    expect(
      const acp.AcpRequestTimeoutException().toString(),
      'ACP request timed out.',
    );
    expect(
      const acp.AcpPromptTimeoutException().toString(),
      'ACP prompt timed out.',
    );
    expect(
      const acp.AcpConnectionClosedException().toString(),
      'ACP connection closed.',
    );
    expect(
      const acp.PermissionRequestTimeoutException().toString(),
      'Permission request timed out.',
    );

    final token = _SecretToken();
    final options = acp.PermissionOptions(
      title: 'safe',
      rationale: 'safe',
      options: const <String>['allow'],
      sessionId: 'safe-session',
      toolName: 'safe-tool',
      cancellationToken: token,
      metadata: const <String, Object?>{'safe': true},
    );
    expect(options.cancellationToken, same(token));
    expect(options.metadata.values, isNot(contains(same(token))));
    expect(jsonEncode(options.metadata), isNot(contains('TOKEN-CANARY')));
    expect(options.toString(), isNot(contains('TOKEN-CANARY')));
  });
}
