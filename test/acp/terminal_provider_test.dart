import 'dart:async';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bounds terminal output and release terminates the process', () async {
    final provider = DefaultTerminalProvider();
    final handle = await provider.create(
      sessionId: 'session-1',
      command: '/bin/sh',
      args: const ['-c', "printf '1234567890'; sleep 30"],
      outputByteLimit: 5,
    );
    addTearDown(() => provider.release(handle));

    await _waitUntil(() => handle.currentOutput().isNotEmpty);
    expect(handle.currentOutput(), '67890');
    expect(handle.truncated, isTrue);

    await provider.release(handle);

    expect(
      await handle.process.exitCode.timeout(const Duration(seconds: 2)),
      isNotNull,
    );
    expect(provider.activeHandleCount, 0);
  });

  test('terminal output truncation preserves UTF-8 boundaries', () async {
    final provider = DefaultTerminalProvider();
    final handle = await provider.create(
      sessionId: 'session-1',
      command: '/bin/sh',
      args: const ['-c', "printf 'aé中'"],
      outputByteLimit: 4,
    );
    addTearDown(() => provider.release(handle));

    await handle.waitForExit().timeout(const Duration(seconds: 2));
    await _waitUntil(() => handle.currentOutput().isNotEmpty);

    expect(handle.currentOutput(), '中');
    expect(handle.truncated, isTrue);
  });
}

Future<void> _waitUntil(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
