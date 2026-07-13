import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exports safe terminal handle defaults', () {
    expect(defaultMaxTerminalHandles, 32);
    expect(defaultMaxTerminalHandlesPerSession, 8);

    final provider = DefaultTerminalProvider();
    expect(provider.maxActiveHandles, defaultMaxTerminalHandles);
    expect(
      provider.maxActiveHandlesPerSession,
      defaultMaxTerminalHandlesPerSession,
    );
  });

  test('terminal handle limits require positive ordered values', () {
    expect(
      () => DefaultTerminalProvider(maxActiveHandles: 0),
      throwsArgumentError,
    );
    expect(
      () => DefaultTerminalProvider(maxActiveHandlesPerSession: 0),
      throwsArgumentError,
    );
    expect(
      () => DefaultTerminalProvider(
        maxActiveHandles: 1,
        maxActiveHandlesPerSession: 2,
      ),
      throwsArgumentError,
    );
    expect(
      () => validateTerminalHandleLimits(
        maxTerminalHandles: -1,
        maxTerminalHandlesPerSession: 1,
      ),
      throwsArgumentError,
    );
  });

  test('terminal handle limit exception text is payload-free', () {
    const exception = TerminalHandleLimitException(
      reason: TerminalHandleLimitReason.session,
      limit: 8,
    );

    expect(exception.reason, TerminalHandleLimitReason.session);
    expect(exception.limit, 8);
    expect(exception.toString(), 'Terminal handle limit exceeded.');
    expect(exception.toString(), isNot(contains('session')));
    expect(exception.toString(), isNot(contains('8')));
  });

  test(
    'provider bounds active handles globally and per session then reuses release',
    () async {
      final provider = DefaultTerminalProvider(
        maxActiveHandles: 2,
        maxActiveHandlesPerSession: 1,
      );
      final handles = <TerminalProcessHandle>[];
      addTearDown(() async {
        for (final handle in handles) {
          await provider.release(handle);
        }
      });

      handles.add(await _createSleepingTerminal(provider, 'session-a'));
      await expectLater(
        _releaseIfUnexpectedlyCreated(
          provider,
          _createSleepingTerminal(provider, 'session-a'),
        ),
        throwsA(
          isA<TerminalHandleLimitException>()
              .having(
                (error) => error.reason,
                'reason',
                TerminalHandleLimitReason.session,
              )
              .having((error) => error.limit, 'limit', 1),
        ),
      );

      handles.add(await _createSleepingTerminal(provider, 'session-b'));
      expect(provider.activeHandleCount, 2);
      await expectLater(
        _releaseIfUnexpectedlyCreated(
          provider,
          _createSleepingTerminal(provider, 'session-c'),
        ),
        throwsA(
          isA<TerminalHandleLimitException>()
              .having(
                (error) => error.reason,
                'reason',
                TerminalHandleLimitReason.global,
              )
              .having((error) => error.limit, 'limit', 2),
        ),
      );

      await provider.release(handles.removeAt(0));
      handles.add(await _createSleepingTerminal(provider, 'session-c'));
      expect(provider.activeHandleCount, 2);
    },
  );

  test('provider reserves pending Process.start calls synchronously', () async {
    final provider = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final first = _createSleepingTerminal(provider, 'session-a');
    addTearDown(() async {
      final handle = await first;
      await provider.release(handle);
    });

    await expectLater(
      _releaseIfUnexpectedlyCreated(
        provider,
        _createSleepingTerminal(provider, 'session-b'),
      ),
      throwsA(
        isA<TerminalHandleLimitException>().having(
          (error) => error.reason,
          'reason',
          TerminalHandleLimitReason.global,
        ),
      ),
    );

    await first;
    expect(provider.activeHandleCount, 1);
  });

  test('provider rolls back a failed Process.start reservation', () async {
    final provider = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );

    await expectLater(
      _releaseIfUnexpectedlyCreated(
        provider,
        provider.create(
          sessionId: 'session-a',
          command: '/definitely/missing/ianvs-terminal',
          args: const ['unused'],
        ),
      ),
      throwsA(isA<ProcessException>()),
    );

    final handle = await _createSleepingTerminal(provider, 'session-a');
    addTearDown(() => provider.release(handle));
    expect(provider.activeHandleCount, 1);
  });

  test('natural exit retains capacity until idempotent release', () async {
    final provider = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final handle = await provider.create(
      sessionId: 'session-a',
      command: '/bin/sh',
      args: const ['-c', 'exit 0'],
    );
    await handle.waitForExit().timeout(const Duration(seconds: 2));
    expect(provider.activeHandleCount, 1);

    await expectLater(
      _releaseIfUnexpectedlyCreated(
        provider,
        _createSleepingTerminal(provider, 'session-b'),
      ),
      throwsA(isA<TerminalHandleLimitException>()),
    );

    final firstRelease = provider.release(handle);
    final secondRelease = provider.release(handle);
    await Future.wait<void>([firstRelease, secondRelease]);
    await provider.release(handle);
    expect(provider.activeHandleCount, 0);

    final replacement = await _createSleepingTerminal(provider, 'session-b');
    addTearDown(() => provider.release(replacement));
    expect(provider.activeHandleCount, 1);
  });

  test('provider release ignores a foreign handle with the same id', () async {
    final providerA = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final providerB = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final handleA = await _createSleepingTerminal(providerA, 'session');
    addTearDown(() => providerA.release(handleA));
    final handleB = await _createSleepingTerminal(providerB, 'session');
    addTearDown(() => providerB.release(handleB));
    expect(handleA.terminalId, handleB.terminalId);

    await providerA.release(handleB);

    expect(providerA.activeHandleCount, 1);
    expect(providerB.activeHandleCount, 1);
    await expectLater(
      handleB.process.exitCode.timeout(const Duration(milliseconds: 100)),
      throwsA(isA<TimeoutException>()),
    );

    await providerA.release(handleA);
    await providerB.release(handleB);
    expect(providerA.activeHandleCount, 0);
    expect(providerB.activeHandleCount, 0);
  });

  test('concurrent owned release waits for the same cleanup', () async {
    final provider = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final handle = await provider.create(
      sessionId: 'session-a',
      command: '/bin/sh',
      args: const ['-c', "trap '' TERM; printf ready; read ignored"],
    );
    addTearDown(() => provider.release(handle));
    await _waitUntil(() => handle.currentOutput() == 'ready');

    final firstRelease = provider.release(handle);
    addTearDown(() => firstRelease);
    final secondRelease = provider.release(handle);

    await secondRelease;
    expect(
      await handle.process.exitCode.timeout(const Duration(milliseconds: 100)),
      isNotNull,
    );
    expect(provider.activeHandleCount, 0);

    final replacement = await _createSleepingTerminal(provider, 'session-b');
    addTearDown(() => provider.release(replacement));
  });

  test('terminal identifiers remain unique across released handles', () async {
    final provider = DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 1,
    );
    final terminalIds = <String>[];

    for (var index = 0; index < 20; index += 1) {
      final handle = await provider.create(
        sessionId: 'session-a',
        command: '/bin/sh',
        args: const ['-c', 'exit 0'],
      );
      terminalIds.add(handle.terminalId);
      await handle.waitForExit().timeout(const Duration(seconds: 2));
      await provider.release(handle);
    }

    expect(terminalIds.toSet(), hasLength(terminalIds.length));
  });

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

Future<TerminalProcessHandle> _createSleepingTerminal(
  DefaultTerminalProvider provider,
  String sessionId,
) => provider.create(
  sessionId: sessionId,
  command: '/bin/sh',
  args: const ['-c', 'sleep 30'],
);

Future<TerminalProcessHandle> _releaseIfUnexpectedlyCreated(
  DefaultTerminalProvider provider,
  Future<TerminalProcessHandle> create,
) async {
  final handle = await create;
  await provider.release(handle);
  return handle;
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
