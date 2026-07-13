import 'dart:async';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
// logging is a direct dependency of the in-repository dart_acp package.
// ignore: depend_on_referenced_packages
import 'package:logging/logging.dart';

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
    expect(
      () => acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/false',
        maxOutboundQueueItems: 0,
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxOutboundQueueItems')
            .having((error) => error.invalidValue, 'invalidValue', 0),
      ),
    );
    expect(
      () => acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/false',
        maxOutboundQueueBytes: -1,
      ),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'maxOutboundQueueBytes')
            .having((error) => error.invalidValue, 'invalidValue', -1),
      ),
    );
  });

  test(
    'StdioTransport spawn failure omits command and argument payloads',
    () async {
      const commandSecret = '/definitely-missing/agent-command-secret';
      const argumentSecret = 'agent-argument-secret';
      final transport = acp.StdioTransport(
        logger: Logger('stdio.spawn-failure'),
        command: commandSecret,
        args: const <String>[argumentSecret],
      );

      Object? failure;
      try {
        await transport.start();
      } on Object catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure.toString(), isNot(contains(commandSecret)));
      expect(failure.toString(), isNot(contains(argumentSecret)));
      await transport.stop();
    },
  );

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

  test('StdioTransport forwards outbound queue budgets', () async {
    final transport = acp.StdioTransport(
      logger: acp.AcpConfig().logger,
      command: '/bin/cat',
      maxOutboundQueueItems: 1,
      maxOutboundQueueBytes: 64,
    );
    final errors = <Object>[];

    try {
      await transport.start();
      final subscription = transport.channel.stream.listen(
        (_) {},
        onError: errors.add,
      );
      addTearDown(subscription.cancel);

      transport.channel.sink
        ..add('first')
        ..add('second');
      await _waitFor(() => errors.isNotEmpty);

      expect(
        errors.single,
        isA<acp.TransportByteLimitExceeded>()
            .having(
              (error) => error.resource,
              'resource',
              'stdio stdin queue items',
            )
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observedAtLeast, 'observedAtLeast', 2),
      );
    } finally {
      await transport.stop();
    }
  });

  test(
    'StdioTransport reports direct-EOF invalid UTF-8 exactly once',
    () async {
      final transport = acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/sh',
        args: const <String>[
          '-c',
          "sleep 0.2; (sleep 0.2; printf '\\377') & exit 0",
        ],
      );
      final lines = <String>[];
      final errors = <Object>[];
      final done = Completer<void>();

      try {
        await transport.start();
        final subscription = transport.channel.stream.listen(
          lines.add,
          onError: errors.add,
          onDone: done.complete,
        );
        addTearDown(subscription.cancel);
        await done.future.timeout(const Duration(seconds: 3));

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
        await transport.stop();
      }
    },
  );

  test('StdioTransport preserves a valid final line without newline', () async {
    final transport = acp.StdioTransport(
      logger: acp.AcpConfig().logger,
      command: '/bin/sh',
      args: const <String>[
        '-c',
        "sleep 0.2; (sleep 0.2; printf 'last') & exit 0",
      ],
    );

    try {
      await transport.start();
      final lines = await transport.channel.stream.toList().timeout(
        const Duration(seconds: 3),
      );

      expect(lines, hasLength(1));
      expect(lines.single, 'last');
    } finally {
      await transport.stop();
    }
  });

  test(
    'StdioTransport stop completes without a listener after stdin fails',
    () async {
      final outboundAttempted = Completer<void>();
      final transport = acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/sh',
        args: const <String>['-c', 'exec 0<&-; sleep 5'],
        onProtocolOut: (_) {
          if (!outboundAttempted.isCompleted) outboundAttempted.complete();
        },
      );

      try {
        await transport.start();
        transport.channel.sink.add('secret outbound payload');
        await outboundAttempted.future.timeout(const Duration(seconds: 1));

        await transport.stop().timeout(const Duration(seconds: 1));
      } finally {
        await transport.stop().timeout(const Duration(seconds: 2));
      }
    },
  );

  test(
    'StdioTransport stop completes with paused inbound and flushes queued writes',
    () async {
      final outboundLines = <String>[];
      final inboundLines = <String>[];
      final transport = acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: '/bin/cat',
        onProtocolOut: outboundLines.add,
        onProtocolIn: inboundLines.add,
      );
      StreamSubscription<String>? subscription;
      Future<void>? stopFuture;
      const expected = <String>['first', 'second'];

      try {
        await transport.start();
        subscription = transport.channel.stream.listen((_) {}, onError: (_) {})
          ..pause();
        transport.channel.sink
          ..add(expected[0])
          ..add(expected[1]);
        await _waitFor(() => inboundLines.length == expected.length);

        stopFuture = transport.stop();
        await stopFuture.timeout(const Duration(seconds: 1));

        expect(outboundLines, expected);
        expect(inboundLines, expected);
      } finally {
        await subscription?.cancel();
        await (stopFuture ?? transport.stop()).timeout(
          const Duration(seconds: 2),
        );
      }
    },
  );

  test(
    'StdioTransport bounds stalled flush then kills and reaps a TERM-ignoring child',
    () async {
      final fixture = await _DartChildFixture.create();
      final outboundStarted = Completer<void>();
      final transport = acp.StdioTransport(
        logger: Logger('stdio.stalled-flush'),
        command: fixture.dartExecutable,
        args: <String>[
          fixture.script.path,
          'ignoreTerm',
          fixture.events.path,
          'diagnostic-secret',
        ],
        onProtocolOut: (_) {
          if (!outboundStarted.isCompleted) outboundStarted.complete();
        },
      );
      Future<void>? stopFuture;

      try {
        await transport.start();
        await fixture.waitForStarts(1);
        transport.channel.sink.add('x' * (1024 * 1024));
        await outboundStarted.future.timeout(const Duration(seconds: 1));

        stopFuture = transport.stop();
        await stopFuture.timeout(const Duration(seconds: 3));

        final events = await fixture.readEvents();
        final pid = fixture.startedPids(events).single;
        expect(events, contains('term:$pid'));
        expect(Process.killPid(pid, ProcessSignal.sigkill), isFalse);
      } finally {
        await fixture.killChildren();
        await (stopFuture ?? transport.stop()).timeout(
          const Duration(seconds: 2),
        );
        await fixture.dispose();
      }
    },
  );

  test('StdioTransport concurrent stop calls share one Future', () async {
    final fixture = await _DartChildFixture.create();
    final transport = fixture.transport(mode: 'termExit');
    Future<void>? firstStop;
    Future<void>? secondStop;

    try {
      await transport.start();
      await fixture.waitForStarts(1);

      firstStop = transport.stop();
      secondStop = transport.stop();

      expect(identical(firstStop, secondStop), isTrue);
      await firstStop.timeout(const Duration(seconds: 2));
    } finally {
      await fixture.killChildren();
      await Future.wait<void>(<Future<void>>[
        ?firstStop,
        ?secondStop,
      ]).timeout(const Duration(seconds: 2));
      await transport.stop().timeout(const Duration(seconds: 2));
      await fixture.dispose();
    }
  });

  test('StdioTransport concurrent start calls spawn only one child', () async {
    final fixture = await _DartChildFixture.create();
    final transport = fixture.transport(mode: 'termExit');

    try {
      final firstStart = transport.start();
      final secondStart = transport.start();
      await Future.wait<void>(<Future<void>>[
        firstStart,
        secondStart,
      ]).timeout(const Duration(seconds: 2));
      await fixture.waitForStarts(1);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(fixture.startedPids(await fixture.readEvents()), hasLength(1));
    } finally {
      await transport.stop().timeout(const Duration(seconds: 2));
      await fixture.killChildren();
      await fixture.dispose();
    }
  });

  test(
    'StdioTransport clears an immediate failed start so it can retry',
    () async {
      final fixture = await _DartChildFixture.create();
      final executable = await fixture.compileChild();
      final transport = fixture.transport(
        mode: 'failOnce',
        command: executable,
      );

      try {
        await expectLater(transport.start(), throwsA(isA<StateError>()));
        expect(() => transport.channel, throwsStateError);

        await transport.start().timeout(const Duration(seconds: 2));
        await fixture.waitForStarts(2);
        expect(() => transport.channel, returnsNormally);
      } finally {
        await transport.stop().timeout(const Duration(seconds: 2));
        await fixture.killChildren();
        await fixture.dispose();
      }
    },
  );

  test(
    'StdioTransport deterministically closes streams for repeated immediate exits',
    () async {
      final processes = <_ObservableProcess>[];
      final transport = acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: 'fake-agent',
        processStarter: (_, _, {workingDirectory, environment}) async {
          final process = _ObservableProcess.immediateExit(
            stdoutBytes: 'stdout-secret'.codeUnits,
            stderrBytes: 'stderr-secret'.codeUnits,
            closeOutputStreamsOnListen: false,
          );
          processes.add(process);
          return process;
        },
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        Object? failure;
        try {
          await transport.start().timeout(const Duration(seconds: 1));
        } on Object catch (error) {
          failure = error;
        }
        expect(failure, isA<StateError>());
        expect(failure.toString(), isNot(contains('stdout-secret')));
        expect(failure.toString(), isNot(contains('stderr-secret')));
        expect(() => transport.channel, throwsStateError);
      }

      expect(processes, hasLength(2));
      for (final process in processes) {
        expect(process.stdinCloseCount, 1);
        expect(process.stdoutListenCount, 1);
        expect(process.stderrListenCount, 1);
        expect(process.stdoutCancelCount, 1);
        expect(process.stderrCancelCount, 1);
        expect(process.killSignals, isEmpty);
        await process.disposeStreams();
      }
      await transport.stop();
    },
  );

  test(
    'StdioTransport stop queued during start reaps the spawned child',
    () async {
      final starterInvoked = Completer<void>();
      final processReady = Completer<Process>();
      final process = _ObservableProcess.live();
      final transport = acp.StdioTransport(
        logger: acp.AcpConfig().logger,
        command: 'fake-agent',
        processStarter: (_, _, {workingDirectory, environment}) {
          starterInvoked.complete();
          return processReady.future;
        },
      );

      final startFuture = transport.start();
      await starterInvoked.future.timeout(const Duration(seconds: 1));
      final stopFuture = transport.stop();
      processReady.complete(process);

      await Future.wait<void>(<Future<void>>[
        startFuture,
        stopFuture,
      ]).timeout(const Duration(seconds: 2));

      expect(process.killSignals, <ProcessSignal>[ProcessSignal.sigterm]);
      expect(process.hasExited, isTrue);
      expect(() => transport.channel, throwsStateError);
      await transport.stop();
    },
  );

  test(
    'StdioTransport serializes restart until the old child is reaped',
    () async {
      final fixture = await _DartChildFixture.create();
      final transport = fixture.transport(mode: 'termExit');

      try {
        await transport.start();
        await fixture.waitForStarts(1);
        final firstPid = fixture.startedPids(await fixture.readEvents()).single;

        final stopFuture = transport.stop();
        final restartFuture = transport.start();
        await Future.wait<void>(<Future<void>>[
          stopFuture,
          restartFuture,
        ]).timeout(const Duration(seconds: 3));
        await fixture.waitForStarts(2);

        final events = await fixture.readEvents();
        final pids = fixture.startedPids(events);
        final secondPid = pids.last;
        expect(secondPid, isNot(firstPid));
        expect(
          events.indexOf('exit:$firstPid'),
          lessThan(events.indexOf('start:$secondPid')),
        );
        expect(() => transport.channel, returnsNormally);
      } finally {
        await transport.stop().timeout(const Duration(seconds: 2));
        await fixture.killChildren();
        await fixture.dispose();
      }
    },
  );

  test('StdioTransport does not signal a child that already exited', () async {
    final fixture = await _DartChildFixture.create();
    final transport = fixture.transport(mode: 'naturalExit');

    try {
      await transport.start();
      await transport.channel.stream.drain<void>().timeout(
        const Duration(seconds: 2),
      );
      await transport.stop().timeout(const Duration(seconds: 1));

      final events = await fixture.readEvents();
      final pid = fixture.startedPids(events).single;
      expect(events, contains('exit:$pid'));
      expect(events, isNot(contains('term:$pid')));
    } finally {
      await transport.stop().timeout(const Duration(seconds: 2));
      await fixture.killChildren();
      await fixture.dispose();
    }
  });

  test(
    'StdioTransport logs omit command arguments and stderr payloads',
    () async {
      const secret = 'command-and-stderr-secret';
      final fixture = await _DartChildFixture.create();
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final logger = Logger(
        'stdio.payload-free.${DateTime.now().microsecondsSinceEpoch}',
      );
      final messages = <String>[];
      final logSubscription = logger.onRecord.listen(
        (record) => messages.add(record.message),
      );
      final transport = fixture.transport(
        mode: 'naturalExit',
        logger: logger,
        diagnostic: secret,
      );

      try {
        await transport.start();
        await transport.channel.stream.drain<void>().timeout(
          const Duration(seconds: 2),
        );
        await transport.stop().timeout(const Duration(seconds: 1));

        expect(messages.join('\n'), isNot(contains(secret)));
      } finally {
        Logger.root.level = previousLevel;
        await logSubscription.cancel();
        await transport.stop().timeout(const Duration(seconds: 2));
        await fixture.killChildren();
        await fixture.dispose();
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

class _DartChildFixture {
  _DartChildFixture._(
    this.directory,
    this.script,
    this.events,
    this.dartExecutable,
  );

  final Directory directory;
  final File script;
  final File events;
  final String dartExecutable;

  static Future<_DartChildFixture> create() async {
    final dartLookup = await Process.run('/usr/bin/which', <String>['dart']);
    if (dartLookup.exitCode != 0) {
      throw StateError(
        'Dart executable is unavailable for child-process tests.',
      );
    }
    final dartExecutable = (dartLookup.stdout as String).trim();
    final directory = await Directory.systemTemp.createTemp(
      'stdio-transport-shutdown-',
    );
    final script = File('${directory.path}/child.dart');
    final events = File('${directory.path}/events.log');
    await script.writeAsString(r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args[0];
  final eventsPath = args[1];
  final diagnostic = args[2];
  void record(String event) {
    File(eventsPath).writeAsStringSync('$event\n', mode: FileMode.append);
  }

  final priorStarts = File(eventsPath).existsSync()
      ? File(eventsPath)
          .readAsLinesSync()
          .where((line) => line.startsWith('start:'))
          .length
      : 0;
  final processId = pid;
  record('start:$processId');
  stderr.writeln(diagnostic);
  stdout.writeln(processId);

  if (mode == 'warmup') {
    record('exit:$processId');
    return;
  }

  if (mode == 'failOnce' && priorStarts == 0) {
    record('exit:$processId');
    return;
  }

  if (mode == 'naturalExit') {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    record('exit:$processId');
    return;
  }

  final keepAlive = Timer.periodic(const Duration(seconds: 1), (_) {});
  final signalSubscription = ProcessSignal.sigterm.watch().listen((_) async {
    record('term:$processId');
    if (mode == 'termExit' || mode == 'failOnce') {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      record('exit:$processId');
      exit(0);
    }
  });
  await Completer<void>().future;
  keepAlive.cancel();
  await signalSubscription.cancel();
}
''');
    return _DartChildFixture._(directory, script, events, dartExecutable);
  }

  acp.StdioTransport transport({
    required String mode,
    Logger? logger,
    String diagnostic = 'diagnostic',
    String? command,
  }) => acp.StdioTransport(
    logger: logger ?? Logger('stdio.fixture'),
    command: command ?? dartExecutable,
    args: <String>[
      if (command == null) script.path,
      mode,
      events.path,
      diagnostic,
    ],
  );

  Future<String> compileChild() async {
    final executable = '${directory.path}/child';
    final result = await Process.run(dartExecutable, <String>[
      'compile',
      'exe',
      script.path,
      '-o',
      executable,
    ]);
    if (result.exitCode != 0) {
      throw StateError('Dart child fixture compilation failed.');
    }
    final warmup = await Process.run(executable, <String>[
      'warmup',
      events.path,
      'warmup',
    ]);
    if (warmup.exitCode != 0) {
      throw StateError('Dart child fixture warmup failed.');
    }
    if (await events.exists()) await events.delete();
    return executable;
  }

  Future<List<String>> readEvents() async {
    if (!await events.exists()) return <String>[];
    return (await events.readAsLines())
        .where((line) => line.isNotEmpty)
        .toList();
  }

  List<int> startedPids(List<String> entries) => entries
      .where((entry) => entry.startsWith('start:'))
      .map((entry) => int.parse(entry.substring('start:'.length)))
      .toList();

  Future<void> waitForStarts(int count) => _waitFor(() {
    if (!events.existsSync()) return false;
    return events
            .readAsLinesSync()
            .where((line) => line.startsWith('start:'))
            .length >=
        count;
  });

  Future<void> killChildren() async {
    final entries = await readEvents();
    for (final pid in startedPids(entries)) {
      Process.killPid(pid, ProcessSignal.sigkill);
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _ObservableProcess implements Process {
  _ObservableProcess._({
    required bool exited,
    required bool closeOutputStreamsOnListen,
    this._stdoutBytes = const <int>[],
    this._stderrBytes = const <int>[],
  }) : _stdinConsumer = _CountingStreamConsumer() {
    _stdin = IOSink(_stdinConsumer);
    _stdoutController = StreamController<List<int>>(
      sync: true,
      onListen: () {
        stdoutListenCount++;
        if (exited) {
          if (_stdoutBytes.isNotEmpty) _stdoutController.add(_stdoutBytes);
          if (closeOutputStreamsOnListen) _stdoutController.close();
        }
      },
      onCancel: () {
        stdoutCancelCount++;
      },
    );
    _stderrController = StreamController<List<int>>(
      sync: true,
      onListen: () {
        stderrListenCount++;
        if (exited) {
          if (_stderrBytes.isNotEmpty) _stderrController.add(_stderrBytes);
          if (closeOutputStreamsOnListen) _stderrController.close();
        }
      },
      onCancel: () {
        stderrCancelCount++;
      },
    );
    if (exited) _exitCode.complete(17);
  }

  factory _ObservableProcess.immediateExit({
    List<int> stdoutBytes = const <int>[],
    List<int> stderrBytes = const <int>[],
    bool closeOutputStreamsOnListen = true,
  }) => _ObservableProcess._(
    exited: true,
    closeOutputStreamsOnListen: closeOutputStreamsOnListen,
    stdoutBytes: stdoutBytes,
    stderrBytes: stderrBytes,
  );

  factory _ObservableProcess.live() =>
      _ObservableProcess._(exited: false, closeOutputStreamsOnListen: false);

  final List<int> _stdoutBytes;
  final List<int> _stderrBytes;
  final Completer<int> _exitCode = Completer<int>();
  final _CountingStreamConsumer _stdinConsumer;
  late final IOSink _stdin;
  late final StreamController<List<int>> _stdoutController;
  late final StreamController<List<int>> _stderrController;
  final List<ProcessSignal> killSignals = <ProcessSignal>[];
  var stdoutListenCount = 0;
  var stderrListenCount = 0;
  var stdoutCancelCount = 0;
  var stderrCancelCount = 0;

  int get stdinCloseCount => _stdinConsumer.closeCount;

  bool get hasExited => _exitCode.isCompleted;

  Future<void> disposeStreams() async {
    if (!_stdoutController.isClosed) await _stdoutController.close();
    if (!_stderrController.isClosed) await _stderrController.close();
  }

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    if (!_exitCode.isCompleted) _exitCode.complete(-signal.signalNumber);
    if (!_stdoutController.isClosed) _stdoutController.close();
    if (!_stderrController.isClosed) _stderrController.close();
    return true;
  }
}

class _CountingStreamConsumer implements StreamConsumer<List<int>> {
  var closeCount = 0;

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {
    closeCount++;
  }
}
