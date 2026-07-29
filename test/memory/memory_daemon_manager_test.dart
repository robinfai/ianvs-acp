import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/memory/memory_daemon_manager.dart';

void main() {
  test('parses ready JSON line', () {
    final ready = MemoryDaemonReady.fromStdoutLine(
      '{"type":"ready","port":43129}',
    );
    expect(ready.port, 43129);
    expect(ready.baseUrl, 'http://127.0.0.1:43129');
  });

  test('builds daemon env with token but args omit token', () {
    const launch = MemoryDaemonLaunch(
      executable: '/tmp/memory-core',
      dataDir: '/tmp/data',
      token: 'secret-token',
    );
    expect(launch.env['MEMORY_DAEMON_TOKEN'], 'secret-token');
    expect(launch.args.join(' '), isNot(contains('secret-token')));
    expect(launch.args, contains('--port'));
    expect(launch.args, contains('0'));
  });

  test(
    'manager starts daemon on a dynamic port and stops owned process',
    () async {
      final fakeProcess = _FakeProcess();
      String? executable;
      List<String>? args;
      Map<String, String>? environment;
      final manager = MemoryDaemonManager(
        launch: const MemoryDaemonLaunch(
          executable: '/tmp/memory-core',
          dataDir: '/tmp/data',
          token: 'secret-token',
        ),
        startProcess:
            (
              processExecutable,
              processArgs, {
              required processEnvironment,
            }) async {
              executable = processExecutable;
              args = processArgs;
              environment = processEnvironment;
              Future.microtask(
                () => fakeProcess.addStdout('{"type":"ready","port":43129}'),
              );
              return fakeProcess;
            },
      );

      final endpoint = await manager.ensureStarted();

      expect(executable, '/tmp/memory-core');
      expect(args, containsAllInOrder(['--port', '0']));
      expect(environment?['MEMORY_DAEMON_TOKEN'], 'secret-token');
      expect(endpoint.baseUrl.toString(), 'http://127.0.0.1:43129');
      expect(endpoint.token, 'secret-token');

      await manager.dispose();

      expect(fakeProcess.killed, isTrue);
    },
  );
}

class _FakeProcess implements Process {
  _FakeProcess()
    : stdin = IOSink(StreamController<List<int>>().sink),
      _stdout = StreamController<List<int>>(),
      _stderr = StreamController<List<int>>();

  final StreamController<List<int>> _stdout;
  final StreamController<List<int>> _stderr;
  final Completer<int> _exitCode = Completer<int>();
  bool killed = false;

  void addStdout(String line) {
    _stdout.add(utf8.encode('$line\n'));
  }

  @override
  final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  int get pid => 43129;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    unawaited(_stdout.close());
    unawaited(_stderr.close());
    return true;
  }
}
