import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:stream_channel/stream_channel.dart';

void main() {
  test('invalid terminal handle limits fail before transport start', () async {
    Future<void> expectRejected({
      required int maxTerminalHandles,
      required int maxTerminalHandlesPerSession,
    }) async {
      final transport = _TrackingLifecycleTransport();

      await expectLater(
        AcpClient.start(
          config: AcpConfig(),
          transport: transport,
          maxTerminalHandles: maxTerminalHandles,
          maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
        ),
        throwsArgumentError,
      );

      expect(transport.startCount, 0);
      expect(transport.stopCount, 0);
      unawaited(transport.closeInput());
    }

    await expectRejected(
      maxTerminalHandles: 0,
      maxTerminalHandlesPerSession: 1,
    );
    await expectRejected(
      maxTerminalHandles: 1,
      maxTerminalHandlesPerSession: 0,
    );
    await expectRejected(
      maxTerminalHandles: 1,
      maxTerminalHandlesPerSession: 2,
    );
  });

  test(
    'AcpClient terminal handle limits reach the live session manager',
    () async {
      final transport = _TrackingLifecycleTransport();
      final provider = _RecordingTerminalProvider(
        currentOutputValue: 'aé中-secret-must-be-truncated',
      );
      final responses = <String, Completer<Map<String, dynamic>>>{};
      final server = transport.outbound.listen((line) {
        final message = jsonDecode(line) as Map<String, dynamic>;
        if (message['method'] == 'session/resume') {
          transport.addInbound(
            jsonEncode(<String, dynamic>{
              'jsonrpc': '2.0',
              'id': message['id'],
              'result': <String, dynamic>{'sessionId': 'session-limit'},
            }),
          );
          return;
        }
        final id = message['id']?.toString();
        if (id != null) responses[id]?.complete(message);
      });
      final client = await AcpClient.start(
        config: AcpConfig(
          terminalProvider: provider,
          permissionProvider: DefaultPermissionProvider(
            onRequest: (_) async => const PermissionDecision.allow(),
          ),
        ),
        transport: transport,
        maxTerminalHandles: 1,
        maxTerminalHandlesPerSession: 1,
      );
      final terminalEvents = <TerminalEvent>[];
      final terminalEventsSubscription = client.terminalEvents.listen(
        terminalEvents.add,
      );

      Future<Map<String, dynamic>> terminalRequest({
        required String id,
        required String method,
        required Map<String, dynamic> params,
      }) async {
        final response = Completer<Map<String, dynamic>>();
        responses[id] = response;
        transport.addInbound(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': id,
            'method': method,
            'params': params,
          }),
        );
        return response.future.timeout(const Duration(seconds: 5));
      }

      try {
        await client.resumeSession(
          sessionId: 'session-limit',
          workspaceRoot: '/workspace',
        );
        final first = await terminalRequest(
          id: 'terminal-limit-first',
          method: 'terminal/create',
          params: <String, dynamic>{
            'sessionId': 'session-limit',
            'command': 'first-command',
            'args': <String>[],
            'outputByteLimit': 4,
            'env': <Map<String, String>>[
              <String, String>{
                'name': 'TERMINAL_LIMIT_CANARY',
                'value': 'terminal-limit-secret',
              },
            ],
          },
        );
        final terminalId =
            (first['result'] as Map<String, dynamic>)['terminalId'];
        final publicOutput = await client.terminalOutput(terminalId as String);
        final output = await terminalRequest(
          id: 'terminal-output',
          method: 'terminal/output',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        final waited = await terminalRequest(
          id: 'terminal-wait',
          method: 'terminal/wait_for_exit',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        final second = await terminalRequest(
          id: 'terminal-limit-second',
          method: 'terminal/create',
          params: <String, dynamic>{
            'sessionId': 'session-limit',
            'command': 'second-command-canary',
            'args': <String>[],
          },
        );

        expect(first, contains('result'));
        expect(publicOutput, 'aé');
        expect(publicOutput, isNot(contains('secret-must-be-truncated')));
        expect(output['result'], <String, dynamic>{
          'output': 'aé',
          'truncated': true,
          'exitStatus': null,
        });
        expect(waited['result'], <String, dynamic>{'exitCode': 0});
        final outputEvent = terminalEvents
            .whereType<TerminalOutputEvent>()
            .single;
        expect(outputEvent.output, 'aé');
        expect(outputEvent.truncated, isTrue);
        expect(second['error'], <String, dynamic>{
          'code': -32001,
          'message': 'Terminal handle limit exceeded.',
        });
        expect(second.toString(), isNot(contains('terminal-limit-secret')));
        expect(second.toString(), isNot(contains('second-command-canary')));
        expect(provider.createCalls, 1);
        expect(
          provider.createdHandles.single.outputByteLimit,
          defaultTerminalOutputByteLimit,
        );
      } finally {
        await terminalEventsSubscription.cancel();
        await client.dispose();
        await server.cancel();
        await transport.closeInput();
      }

      expect(transport.stopCount, 1);
      expect(provider.releaseAttempts, 1);
      expect(provider.createdHandles, hasLength(1));
      expect(
        provider.releasedHandles.single,
        same(provider.createdHandles.single),
      );
    },
  );

  test('terminal/output drops output released during provider read', () async {
    final provider = _ControlledTerminalProvider();
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final outputResult = Completer<String>();
      provider.nextCurrentOutput = outputResult;

      final output = harness.terminalRequest(
        method: 'terminal/output',
        params: <String, dynamic>{'terminalId': terminalId},
      );
      await provider.currentOutputStarted.future.timeout(
        const Duration(seconds: 2),
      );
      await harness.client.terminalRelease(terminalId);
      outputResult.complete('late-output-canary');

      expect(
        (await output.timeout(const Duration(seconds: 2)))['result'],
        <String, dynamic>{'output': '', 'truncated': false, 'exitStatus': null},
      );
      expect(harness.events.whereType<TerminalOutputEvent>(), isEmpty);
    } finally {
      await harness.dispose();
    }
  });

  test('terminal/wait drops exit released during provider wait', () async {
    final provider = _ControlledTerminalProvider(
      currentOutputValue: 'late-wait-output-canary',
    );
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final waitResult = Completer<int>();
      provider.nextWaitForExit = waitResult;

      final waiting = harness.terminalRequest(
        method: 'terminal/wait_for_exit',
        params: <String, dynamic>{'terminalId': terminalId},
      );
      await provider.waitForExitStarted.future.timeout(
        const Duration(seconds: 2),
      );
      await harness.client.terminalRelease(terminalId);
      waitResult.complete(37);

      expect(
        (await waiting.timeout(const Duration(seconds: 2)))['result'],
        <String, dynamic>{'exitCode': 0},
      );
      expect(provider.currentOutputCalls, 0);
      expect(harness.events.whereType<TerminalExited>(), isEmpty);
    } finally {
      await harness.dispose();
    }
  });

  test('terminalOutput drops output released during provider read', () async {
    final provider = _ControlledTerminalProvider();
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final outputResult = Completer<String>();
      provider.nextCurrentOutput = outputResult;

      final output = harness.client.terminalOutput(terminalId);
      await provider.currentOutputStarted.future.timeout(
        const Duration(seconds: 2),
      );
      await harness.client.terminalRelease(terminalId);
      outputResult.complete('late-public-output-canary');

      expect(await output.timeout(const Duration(seconds: 2)), '');
    } finally {
      await harness.dispose();
    }
  });

  test(
    'terminalWaitForExit drops exit released during provider wait',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final waitResult = Completer<int>();
        provider.nextWaitForExit = waitResult;

        final waiting = harness.client.terminalWaitForExit(terminalId);
        await provider.waitForExitStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await harness.client.terminalRelease(terminalId);
        waitResult.complete(41);

        expect(await waiting.timeout(const Duration(seconds: 2)), isNull);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('session close invalidates a pending terminal output read', () async {
    final provider = _ControlledTerminalProvider();
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final outputResult = Completer<String>();
      provider.nextCurrentOutput = outputResult;

      final output = harness.terminalRequest(
        method: 'terminal/output',
        params: <String, dynamic>{'terminalId': terminalId},
      );
      await provider.currentOutputStarted.future.timeout(
        const Duration(seconds: 2),
      );
      await harness.client.closeSession(
        sessionId: _TerminalRaceHarness.sessionId,
      );
      outputResult.complete('late-close-output-canary');

      expect(
        (await output.timeout(const Duration(seconds: 2)))['result'],
        <String, dynamic>{'output': '', 'truncated': false, 'exitStatus': null},
      );
      expect(harness.events.whereType<TerminalOutputEvent>(), isEmpty);
    } finally {
      await harness.dispose();
    }
  });

  test(
    'terminal/output drops a provider error after terminal release',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final outputResult = Completer<String>();
        provider.nextCurrentOutput = outputResult;

        final output = harness.terminalRequest(
          method: 'terminal/output',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        await provider.currentOutputStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await harness.client.terminalRelease(terminalId);
        outputResult.completeError(
          StateError('late-output-error-canary'),
          StackTrace.fromString('late-output-error-stack-canary'),
        );

        expect(
          (await output.timeout(const Duration(seconds: 2)))['result'],
          <String, dynamic>{
            'output': '',
            'truncated': false,
            'exitStatus': null,
          },
        );
        expect(harness.events.whereType<TerminalOutputEvent>(), isEmpty);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'terminal/wait drops a provider wait error after terminal release',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final waitResult = Completer<int>();
        provider.nextWaitForExit = waitResult;

        final waiting = harness.terminalRequest(
          method: 'terminal/wait_for_exit',
          params: <String, dynamic>{'terminalId': terminalId},
        );
        await provider.waitForExitStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await harness.client.terminalRelease(terminalId);
        waitResult.completeError(
          StateError('late-wait-error-canary'),
          StackTrace.fromString('late-wait-error-stack-canary'),
        );

        expect(
          (await waiting.timeout(const Duration(seconds: 2)))['result'],
          <String, dynamic>{'exitCode': 0},
        );
        expect(provider.currentOutputCalls, 0);
        expect(harness.events.whereType<TerminalExited>(), isEmpty);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('terminal/wait does not read terminal output after exit', () async {
    final provider = _ControlledTerminalProvider();
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final waitResult = Completer<int>();
      provider.nextWaitForExit = waitResult;

      final waiting = harness.terminalRequest(
        method: 'terminal/wait_for_exit',
        params: <String, dynamic>{'terminalId': terminalId},
      );
      await provider.waitForExitStarted.future.timeout(
        const Duration(seconds: 2),
      );
      waitResult.complete(53);

      expect(
        (await waiting.timeout(const Duration(seconds: 2)))['result'],
        <String, dynamic>{'exitCode': 53},
      );
      expect(provider.currentOutputCalls, 0);
      expect(harness.events.whereType<TerminalExited>(), hasLength(1));
    } finally {
      await harness.dispose();
    }
  });

  test(
    'terminalOutput drops a provider error after terminal release',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final outputResult = Completer<String>();
        provider.nextCurrentOutput = outputResult;

        final output = harness.client.terminalOutput(terminalId);
        await provider.currentOutputStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await harness.client.terminalRelease(terminalId);
        outputResult.completeError(
          StateError('late-public-output-error-canary'),
          StackTrace.fromString('late-public-output-error-stack-canary'),
        );

        expect(await output.timeout(const Duration(seconds: 2)), '');
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'terminalWaitForExit drops a provider error after terminal release',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final waitResult = Completer<int>();
        provider.nextWaitForExit = waitResult;

        final waiting = harness.client.terminalWaitForExit(terminalId);
        await provider.waitForExitStarted.future.timeout(
          const Duration(seconds: 2),
        );
        await harness.client.terminalRelease(terminalId);
        waitResult.completeError(
          StateError('late-public-wait-error-canary'),
          StackTrace.fromString('late-public-wait-error-stack-canary'),
        );

        expect(await waiting.timeout(const Duration(seconds: 2)), isNull);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('terminalOutput preserves a current provider error and stack', () async {
    final provider = _ControlledTerminalProvider();
    final harness = await _TerminalRaceHarness.start(provider);
    try {
      final terminalId = await harness.createTerminal();
      final outputResult = Completer<String>();
      final providerError = StateError('current-output-error-canary');
      final providerStack = StackTrace.fromString(
        'current-output-error-stack-canary',
      );
      provider.nextCurrentOutput = outputResult;

      final output = harness.client.terminalOutput(terminalId);
      await provider.currentOutputStarted.future.timeout(
        const Duration(seconds: 2),
      );
      outputResult.completeError(providerError, providerStack);

      Object? caughtError;
      StackTrace? caughtStack;
      try {
        await output.timeout(const Duration(seconds: 2));
      } on Object catch (error, stackTrace) {
        caughtError = error;
        caughtStack = stackTrace;
      }
      expect(caughtError, same(providerError));
      expect(
        caughtStack.toString(),
        contains('current-output-error-stack-canary'),
      );
    } finally {
      await harness.dispose();
    }
  });

  test(
    'terminalWaitForExit preserves a current provider error and stack',
    () async {
      final provider = _ControlledTerminalProvider();
      final harness = await _TerminalRaceHarness.start(provider);
      try {
        final terminalId = await harness.createTerminal();
        final waitResult = Completer<int>();
        final providerError = StateError('current-wait-error-canary');
        final providerStack = StackTrace.fromString(
          'current-wait-error-stack-canary',
        );
        provider.nextWaitForExit = waitResult;

        final waiting = harness.client.terminalWaitForExit(terminalId);
        await provider.waitForExitStarted.future.timeout(
          const Duration(seconds: 2),
        );
        waitResult.completeError(providerError, providerStack);

        Object? caughtError;
        StackTrace? caughtStack;
        try {
          await waiting.timeout(const Duration(seconds: 2));
        } on Object catch (error, stackTrace) {
          caughtError = error;
          caughtStack = stackTrace;
        }
        expect(caughtError, same(providerError));
        expect(
          caughtStack.toString(),
          contains('current-wait-error-stack-canary'),
        );
      } finally {
        await harness.dispose();
      }
    },
  );
}

class _TerminalRaceHarness {
  _TerminalRaceHarness._({
    required this.client,
    required this.transport,
    required this.server,
    required this.eventSubscription,
    required this.events,
    required this.responses,
  });

  static const String sessionId = 'terminal-race-session';

  final AcpClient client;
  final _TrackingLifecycleTransport transport;
  final StreamSubscription<String> server;
  final StreamSubscription<TerminalEvent> eventSubscription;
  final List<TerminalEvent> events;
  final Map<String, Completer<Map<String, dynamic>>> responses;
  var _nextRequestId = 0;

  static Future<_TerminalRaceHarness> start(
    _ControlledTerminalProvider provider,
  ) async {
    final transport = _TrackingLifecycleTransport();
    final responses = <String, Completer<Map<String, dynamic>>>{};
    late final StreamSubscription<String> server;
    server = transport.outbound.listen((line) {
      final message = jsonDecode(line) as Map<String, dynamic>;
      final method = message['method'];
      if (method == 'session/resume' || method == 'session/close') {
        transport.addInbound(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': method == 'session/resume'
                ? <String, dynamic>{'sessionId': sessionId}
                : <String, dynamic>{},
          }),
        );
        return;
      }
      final id = message['id']?.toString();
      if (id != null) responses[id]?.complete(message);
    });
    final client = await AcpClient.start(
      config: AcpConfig(
        terminalProvider: provider,
        permissionProvider: DefaultPermissionProvider(
          onRequest: (_) async => const PermissionDecision.allow(),
        ),
      ),
      transport: transport,
      maxTerminalHandles: 4,
      maxTerminalHandlesPerSession: 4,
    );
    final events = <TerminalEvent>[];
    final eventSubscription = client.terminalEvents.listen(events.add);
    await client.resumeSession(
      sessionId: sessionId,
      workspaceRoot: '/workspace',
    );
    return _TerminalRaceHarness._(
      client: client,
      transport: transport,
      server: server,
      eventSubscription: eventSubscription,
      events: events,
      responses: responses,
    );
  }

  Future<Map<String, dynamic>> terminalRequest({
    required String method,
    required Map<String, dynamic> params,
  }) {
    final id = 'terminal-race-${++_nextRequestId}';
    final response = Completer<Map<String, dynamic>>();
    responses[id] = response;
    transport.addInbound(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    return response.future;
  }

  Future<String> createTerminal() async {
    final response = await terminalRequest(
      method: 'terminal/create',
      params: <String, dynamic>{
        'sessionId': sessionId,
        'command': 'terminal-race-command',
        'args': <String>[],
      },
    ).timeout(const Duration(seconds: 2));
    return (response['result'] as Map<String, dynamic>)['terminalId'] as String;
  }

  Future<void> dispose() async {
    await eventSubscription.cancel();
    await client.dispose();
    await server.cancel();
    await transport.closeInput();
  }
}

class _TrackingLifecycleTransport implements AcpTransport {
  final StreamChannelController<String> _controller =
      StreamChannelController<String>();
  var startCount = 0;
  var stopCount = 0;

  Stream<String> get outbound => _controller.local.stream;

  @override
  StreamChannel<String> get channel => _controller.foreign;

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  void addInbound(String line) => _controller.local.sink.add(line);

  Future<void> closeInput() => _controller.local.sink.close();
}

class _RecordingTerminalProvider implements TerminalProvider {
  _RecordingTerminalProvider({this.currentOutputValue = ''});

  final String currentOutputValue;
  var createCalls = 0;
  var releaseAttempts = 0;
  final List<TerminalProcessHandle> createdHandles = <TerminalProcessHandle>[];
  final List<TerminalProcessHandle> releasedHandles = <TerminalProcessHandle>[];

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int? outputByteLimit,
  }) async {
    createCalls += 1;
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    final handle = TerminalProcessHandle(
      terminalId: 'terminal-$createCalls',
      process: process,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  Future<String> currentOutput(TerminalProcessHandle handle) async =>
      currentOutputValue;

  @override
  Future<void> kill(TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(TerminalProcessHandle handle) async {
    releaseAttempts += 1;
    releasedHandles.add(handle);
    await handle.release();
  }

  @override
  Future<int> waitForExit(TerminalProcessHandle handle) async => 0;
}

class _ControlledTerminalProvider implements TerminalProvider {
  _ControlledTerminalProvider({this.currentOutputValue = ''});

  final String currentOutputValue;
  Completer<String>? nextCurrentOutput;
  Completer<int>? nextWaitForExit;
  Completer<void> currentOutputStarted = Completer<void>();
  Completer<void> waitForExitStarted = Completer<void>();
  final List<TerminalProcessHandle> createdHandles = <TerminalProcessHandle>[];
  int currentOutputCalls = 0;
  int _nextTerminalId = 0;

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int? outputByteLimit,
  }) async {
    final process = await Process.start('/bin/sh', const <String>[
      '-c',
      'sleep 30',
    ]);
    final handle = TerminalProcessHandle(
      terminalId: 'controlled-terminal-${++_nextTerminalId}',
      process: process,
    );
    createdHandles.add(handle);
    return handle;
  }

  @override
  Future<String> currentOutput(TerminalProcessHandle handle) {
    currentOutputCalls += 1;
    if (!currentOutputStarted.isCompleted) currentOutputStarted.complete();
    final controlled = nextCurrentOutput;
    return controlled?.future ?? Future<String>.value(currentOutputValue);
  }

  @override
  Future<void> kill(TerminalProcessHandle handle) => handle.kill();

  @override
  Future<void> release(TerminalProcessHandle handle) => handle.release();

  @override
  Future<int> waitForExit(TerminalProcessHandle handle) {
    if (!waitForExitStarted.isCompleted) waitForExitStarted.complete();
    final controlled = nextWaitForExit;
    return controlled?.future ?? Future<int>.value(0);
  }
}
