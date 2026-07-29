import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class MemoryDaemonReady {
  const MemoryDaemonReady({required this.port});

  final int port;

  String get baseUrl => 'http://127.0.0.1:$port';

  factory MemoryDaemonReady.fromStdoutLine(String line) {
    final decoded = jsonDecode(line);
    if (decoded is! Map || decoded['type'] != 'ready') {
      throw const FormatException('Expected memory daemon ready JSON.');
    }
    final port = decoded['port'];
    if (port is! int || port <= 0) {
      throw const FormatException('Memory daemon ready JSON missing port.');
    }
    return MemoryDaemonReady(port: port);
  }
}

class MemoryDaemonLaunch {
  const MemoryDaemonLaunch({
    required this.executable,
    required this.dataDir,
    required this.token,
    this.extraEnv = const <String, String>{},
  });

  final String executable;
  final String dataDir;
  final String token;
  final Map<String, String> extraEnv;

  List<String> get args => <String>[
    '--mode',
    'daemon',
    '--host',
    '127.0.0.1',
    '--port',
    '0',
    '--data-dir',
    dataDir,
  ];

  Map<String, String> get env => <String, String>{
    ...extraEnv,
    'MEMORY_DAEMON_TOKEN': token,
  };

  static String generateToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  static String defaultDataDir({Map<String, String>? environment}) {
    final env = environment ?? Platform.environment;
    final xdgDataHome = env['XDG_DATA_HOME']?.trim();
    if (xdgDataHome != null && xdgDataHome.isNotEmpty) {
      return '$xdgDataHome/ianvs-acp/memory';
    }
    final home = env['HOME']?.trim();
    if (home != null && home.isNotEmpty) {
      return '$home/.local/share/ianvs-acp/memory';
    }
    return '${Directory.current.path}/.ianvs-acp/memory';
  }

  static String resolveExecutable({
    String? currentDirectory,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final override = env['IANVS_MEMORY_CORE_EXE']?.trim();
    if (override != null && override.isNotEmpty) return override;

    final cwd = currentDirectory ?? Directory.current.path;
    final appExecutableDir = File(Platform.resolvedExecutable).parent.path;
    final appContentsDir = Directory(appExecutableDir).parent.path;
    final candidates = <String>[
      '$cwd/memory-core/target/release/memory-core',
      '$cwd/memory-core/target/debug/memory-core',
      '$appExecutableDir/memory-core',
      '$appContentsDir/Resources/memory-core',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return 'memory-core';
  }
}

class MemoryDaemonEndpoint {
  const MemoryDaemonEndpoint({required this.baseUrl, required this.token});

  final Uri baseUrl;
  final String token;
}

typedef MemoryDaemonProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> args, {
      required Map<String, String> processEnvironment,
    });

Future<Process> _startMemoryDaemonProcess(
  String executable,
  List<String> args, {
  required Map<String, String> processEnvironment,
}) {
  return Process.start(executable, args, environment: processEnvironment);
}

class MemoryDaemonManager {
  MemoryDaemonManager({
    required this.launch,
    MemoryDaemonProcessStarter? startProcess,
    this.startTimeout = const Duration(seconds: 90),
  }) : _startProcess = startProcess ?? _startMemoryDaemonProcess;

  final MemoryDaemonLaunch launch;
  final Duration startTimeout;
  final MemoryDaemonProcessStarter _startProcess;

  Process? _process;
  MemoryDaemonEndpoint? _endpoint;
  Future<MemoryDaemonEndpoint>? _starting;
  bool _exited = false;

  Future<MemoryDaemonEndpoint> ensureStarted() {
    final endpoint = _endpoint;
    if (endpoint != null && !_exited) return Future.value(endpoint);
    return _starting ??= _start();
  }

  Future<MemoryDaemonEndpoint> _start() async {
    await dispose();
    _exited = false;
    final process = await _startProcess(
      launch.executable,
      launch.args,
      processEnvironment: launch.env,
    );
    _process = process;
    unawaited(process.stderr.drain<void>());
    unawaited(
      process.exitCode.then((_) {
        if (!identical(_process, process)) return;
        _process = null;
        _endpoint = null;
        _exited = true;
      }),
    );

    try {
      final line = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(startTimeout);
      final ready = MemoryDaemonReady.fromStdoutLine(line);
      final endpoint = MemoryDaemonEndpoint(
        baseUrl: Uri.parse(ready.baseUrl),
        token: launch.token,
      );
      _endpoint = endpoint;
      return endpoint;
    } catch (error) {
      process.kill();
      _process = null;
      _endpoint = null;
      _exited = true;
      rethrow;
    } finally {
      _starting = null;
    }
  }

  Future<void> dispose() async {
    final process = _process;
    _process = null;
    _endpoint = null;
    _exited = true;
    if (process == null) return;
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } catch (_) {
      // Best effort: the app owns this child process and asks it to stop.
    }
  }
}
