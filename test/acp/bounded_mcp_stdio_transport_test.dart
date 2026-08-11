import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/bounded_mcp_stdio_transport.dart';
import 'package:ianvs_acp/acp/transport_byte_budget.dart' as acp;
import 'package:mcp_dart/mcp_dart.dart' as mcp;

void main() {
  group(
    'POSIX process integration',
    () {
      test(
        'rejects an unterminated stdout line beyond the byte budget',
        () async {
          final fixture = await _ProcessFixture.create();
          addTearDown(fixture.dispose);
          final transport = fixture.transport(
            r'''
printf '%s' "$$" > "$PID_FILE"
i=0
while [ "$i" -lt 512 ]; do
  printf x
  i=$((i + 1))
done
sleep 10
''',
            budget: const acp.TransportByteBudget(
              maxBodyBytes: 1024,
              maxLineBytes: 64,
              maxSseEventBytes: 1024,
            ),
          );
          final error = Completer<Error>();
          final closed = Completer<void>();
          transport.onerror = (value) {
            if (!error.isCompleted) error.complete(value);
          };
          transport.onclose = () {
            if (!closed.isCompleted) closed.complete();
          };

          await transport.start();
          expect(
            await error.future.timeout(const Duration(seconds: 2)),
            isA<acp.TransportByteLimitExceeded>()
                .having(
                  (value) => value.resource,
                  'resource',
                  contains('stdout'),
                )
                .having((value) => value.limit, 'limit', 64),
          );
          await closed.future.timeout(const Duration(seconds: 2));
          await fixture.expectProcessStopped();
        },
      );

      test(
        'continuously drains stderr and terminates on cumulative flood',
        () async {
          final fixture = await _ProcessFixture.create();
          addTearDown(fixture.dispose);
          final transport = fixture.transport(
            r'''
printf '%s' "$$" > "$PID_FILE"
i=0
while [ "$i" -lt 512 ]; do
  printf x >&2
  i=$((i + 1))
done
sleep 10
''',
            budget: const acp.TransportByteBudget(
              maxBodyBytes: 64,
              maxLineBytes: 1024,
              maxSseEventBytes: 1024,
            ),
          );
          final error = Completer<Error>();
          final closed = Completer<void>();
          transport.onerror = (value) {
            if (!error.isCompleted) error.complete(value);
          };
          transport.onclose = () {
            if (!closed.isCompleted) closed.complete();
          };

          await transport.start();
          expect(
            await error.future.timeout(const Duration(seconds: 2)),
            isA<acp.TransportByteLimitExceeded>()
                .having(
                  (value) => value.resource,
                  'resource',
                  contains('stderr'),
                )
                .having((value) => value.limit, 'limit', 64),
          );
          await closed.future.timeout(const Duration(seconds: 2));
          await fixture.expectProcessStopped();
        },
      );

      test(
        'preserves newline-delimited JSON-RPC request and response',
        () async {
          final fixture = await _ProcessFixture.create();
          addTearDown(fixture.dispose);
          final transport = fixture.transport(r'''
printf '%s' "$$" > "$PID_FILE"
IFS= read -r request
printf '%s\n' '{"jsonrpc":"2.0","id":7,"result":{"ok":true}}'
sleep 10
''');
          final response = Completer<mcp.JsonRpcMessage>();
          transport.onmessage = (message) {
            if (!response.isCompleted) response.complete(message);
          };

          await transport.start();
          await transport.send(
            const mcp.JsonRpcRequest(id: 7, method: 'test/ping'),
          );

          final message = await response.future.timeout(
            const Duration(seconds: 2),
          );
          expect(message, isA<mcp.JsonRpcResponse>());
          final result = message as mcp.JsonRpcResponse;
          expect(result.id, 7);
          expect(result.result, <String, Object?>{'ok': true});

          await transport.close();
          await fixture.expectProcessStopped();
        },
      );

      test(
        'malformed stdout reports a payload-free error and terminates',
        () async {
          final fixture = await _ProcessFixture.create();
          addTearDown(fixture.dispose);
          final transport = fixture.transport(r'''
printf '%s' "$$" > "$PID_FILE"
printf '%s\n' 'not-json'
sleep 10
''');
          final error = Completer<Error>();
          final closed = Completer<void>();
          transport.onerror = (value) {
            if (!error.isCompleted) error.complete(value);
          };
          transport.onclose = () {
            if (!closed.isCompleted) closed.complete();
          };

          await transport.start();
          expect(
            await error.future.timeout(const Duration(seconds: 2)),
            isA<acp.TransportProtocolDecodeError>(),
          );
          await closed.future.timeout(const Duration(seconds: 2));
          await fixture.expectProcessStopped();
        },
      );

      test(
        'concurrent close is idempotent and kills a SIGTERM holdout',
        () async {
          final fixture = await _ProcessFixture.create();
          addTearDown(fixture.dispose);
          final transport = fixture.transport(r'''
printf '%s' "$$" > "$PID_FILE"
trap '' TERM
while :; do
  sleep 1
done
''', teardownTimeout: const Duration(milliseconds: 75));
          var closeCalls = 0;
          transport.onclose = () => closeCalls += 1;

          await transport.start();
          await fixture.waitForPid();
          await Future.wait<void>(<Future<void>>[
            transport.close(),
            transport.close(),
            transport.close(),
          ]).timeout(const Duration(seconds: 2));

          expect(closeCalls, 1);
          await fixture.expectProcessStopped();
        },
      );

      test('process exit closes the transport exactly once', () async {
        final fixture = await _ProcessFixture.create();
        addTearDown(fixture.dispose);
        final transport = fixture.transport(r'''
printf '%s' "$$" > "$PID_FILE"
exit 0
''');
        final closed = Completer<void>();
        var closeCalls = 0;
        transport.onclose = () {
          closeCalls += 1;
          if (!closed.isCompleted) closed.complete();
        };

        await transport.start();
        await closed.future.timeout(const Duration(seconds: 2));
        await transport.close();

        expect(closeCalls, 1);
        await fixture.expectProcessStopped();
      });

      test('close racing start terminates any spawned process', () async {
        final fixture = await _ProcessFixture.create();
        addTearDown(fixture.dispose);
        final transport = fixture.transport(r'''
printf '%s' "$$" > "$PID_FILE"
trap '' TERM
while :; do
  sleep 1
done
''', teardownTimeout: const Duration(milliseconds: 75));
        var closeCalls = 0;
        transport.onclose = () => closeCalls += 1;

        final starting = transport.start();
        final startOutcome = starting.then<Object?>(
          (_) => null,
          onError: (Object error) => error,
        );
        await transport.close().timeout(const Duration(seconds: 2));

        expect(await startOutcome, isA<StateError>());
        expect(closeCalls, 1);
        await fixture.expectProcessStoppedIfStarted();
      });
    },
    skip: Platform.isWindows
        ? 'requires POSIX process signals and tools'
        : false,
  );

  test('start failure still permits exactly-once idempotent close', () async {
    final missingExecutable = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}'
      'ianvs-mcp-stdio-missing-${DateTime.now().microsecondsSinceEpoch}',
    );
    final transport = BoundedMcpStdioTransport(
      parameters: BoundedMcpStdioServerParameters(
        command: missingExecutable.path,
      ),
    );
    var closeCalls = 0;
    transport.onclose = () => closeCalls += 1;

    await expectLater(transport.start(), throwsA(isA<ProcessException>()));
    await Future.wait<void>(<Future<void>>[
      transport.close(),
      transport.close(),
    ]);

    expect(closeCalls, 1);
  });
}

final class _ProcessFixture {
  _ProcessFixture(this.directory, this.pidFile);

  final Directory directory;
  final File pidFile;

  static Future<_ProcessFixture> create() async {
    final directory = await Directory.systemTemp.createTemp(
      'ianvs-bounded-mcp-stdio-',
    );
    return _ProcessFixture(directory, File('${directory.path}/child.pid'));
  }

  BoundedMcpStdioTransport transport(
    String script, {
    acp.TransportByteBudget budget = const acp.TransportByteBudget(),
    Duration teardownTimeout = const Duration(milliseconds: 250),
  }) {
    return BoundedMcpStdioTransport(
      parameters: BoundedMcpStdioServerParameters(
        command: '/bin/sh',
        args: <String>['-c', script],
        environment: <String, String>{'PID_FILE': pidFile.path},
      ),
      byteBudget: budget,
      teardownTimeout: teardownTimeout,
    );
  }

  Future<int> waitForPid() async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (await pidFile.exists()) {
        final value = int.tryParse((await pidFile.readAsString()).trim());
        if (value != null) return value;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('Child process did not publish its PID.');
  }

  Future<void> expectProcessStopped() async {
    final pid = await waitForPid();
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      final result = await Process.run('/bin/kill', <String>[
        '-0',
        pid.toString(),
      ]);
      if (result.exitCode != 0) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Child process $pid remained alive after transport close.');
  }

  Future<void> expectProcessStoppedIfStarted() async {
    if (!await pidFile.exists()) return;
    await expectProcessStopped();
  }

  Future<void> dispose() async {
    if (await pidFile.exists()) {
      final pid = int.tryParse((await pidFile.readAsString()).trim());
      if (pid != null) {
        await Process.run('/bin/kill', <String>['-KILL', pid.toString()]);
      }
    }
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}
