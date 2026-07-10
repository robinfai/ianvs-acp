import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Default maximum retained output per managed terminal.
const int defaultTerminalOutputByteLimit = 1024 * 1024;

/// Handle for a managed terminal process.
class TerminalProcessHandle {
  /// Create a terminal process handle.
  TerminalProcessHandle({
    required this.terminalId,
    required this.process,
    required this.outputByteLimit,
  }) : _stdoutSub = process.stdout.listen((data) {}),
       _stderrSub = process.stderr.listen((data) {}) {
    _stdoutSub.onData(_appendOutput);
    _stderrSub.onData(_appendOutput);
  }

  /// Unique terminal identifier.
  final String terminalId;

  /// Underlying OS process.
  final Process process;

  /// Maximum number of encoded output bytes retained in memory.
  final int outputByteLimit;

  final StreamSubscription<List<int>> _stdoutSub;
  final StreamSubscription<List<int>> _stderrSub;
  final ListQueue<int> _outputBytes = ListQueue<int>();
  Future<void>? _releaseFuture;

  /// Whether older output was discarded to stay within [outputByteLimit].
  bool truncated = false;

  /// Return currently buffered output as a String.
  String currentOutput() =>
      utf8.decode(_outputBytes.toList(), allowMalformed: true);

  /// Wait for process to exit and return its code.
  Future<int> waitForExit() async => process.exitCode;

  /// Kill the process with SIGTERM.
  Future<void> kill() async {
    process.kill(ProcessSignal.sigterm);
  }

  /// Terminate the process and release stdout/stderr resources.
  Future<void> release() => _releaseFuture ??= _release();

  void _appendOutput(List<int> data) {
    if (data.length >= outputByteLimit) {
      if (_outputBytes.isNotEmpty || data.length > outputByteLimit) {
        truncated = true;
      }
      _outputBytes
        ..clear()
        ..addAll(data.skip(data.length - outputByteLimit));
    } else {
      _outputBytes.addAll(data);
    }
    while (_outputBytes.length > outputByteLimit) {
      _outputBytes.removeFirst();
      truncated = true;
    }
    while (_outputBytes.isNotEmpty && _isUtf8Continuation(_outputBytes.first)) {
      _outputBytes.removeFirst();
      truncated = true;
    }
  }

  bool _isUtf8Continuation(int byte) => byte & 0xc0 == 0x80;

  Future<void> _release() async {
    try {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 2));
      }
    } finally {
      await Future.wait<void>([_stdoutSub.cancel(), _stderrSub.cancel()]);
    }
  }
}

/// Provider interface for creating and managing terminal processes.
abstract class TerminalProvider {
  /// Create a new terminal process.
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args,
    String? cwd,
    Map<String, String>? env,
    int outputByteLimit = defaultTerminalOutputByteLimit,
  });

  /// Read the current buffered output for the terminal.
  Future<String> currentOutput(TerminalProcessHandle handle);

  /// Wait for the terminal process to exit, returning its code.
  Future<int> waitForExit(TerminalProcessHandle handle);

  /// Kill the terminal process.
  Future<void> kill(TerminalProcessHandle handle);

  /// Release resources for the terminal process.
  Future<void> release(TerminalProcessHandle handle);
}

/// Default implementation backed by dart:io Process.
class DefaultTerminalProvider implements TerminalProvider {
  /// Default maximum retained output per terminal.
  static const int defaultOutputByteLimit = defaultTerminalOutputByteLimit;

  final Map<String, TerminalProcessHandle> _handles = {};

  /// Number of terminal handles currently owned by this provider.
  int get activeHandleCount => _handles.length;

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const [],
    String? cwd,
    Map<String, String>? env,
    int outputByteLimit = defaultOutputByteLimit,
  }) async {
    if (outputByteLimit <= 0) {
      throw ArgumentError.value(
        outputByteLimit,
        'outputByteLimit',
        'must be greater than zero',
      );
    }
    // If no args are provided, treat the command as a shell one-liner.
    // This matches how many adapters (e.g., Claude Code) invoke terminal
    // commands via a single string.
    late final Process process;
    if (args.isEmpty) {
      if (Platform.isWindows) {
        process = await Process.start(
          'cmd.exe',
          ['/C', command],
          workingDirectory: cwd,
          environment: env,
          runInShell: false,
        );
      } else {
        // Prefer bash if available; fall back to sh otherwise.
        final shell = await _which('bash') ?? await _which('sh') ?? 'sh';
        final shellArgs = shell.endsWith('bash')
            ? ['-lc', command]
            : ['-c', command];
        process = await Process.start(
          shell,
          shellArgs,
          workingDirectory: cwd,
          environment: env,
          runInShell: false,
        );
      }
    } else {
      process = await Process.start(
        command,
        args,
        workingDirectory: cwd,
        environment: env,
        runInShell: false,
      );
    }
    final handle = TerminalProcessHandle(
      terminalId: '$sessionId:${DateTime.now().microsecondsSinceEpoch}',
      process: process,
      outputByteLimit: outputByteLimit,
    );
    _handles[handle.terminalId] = handle;
    return handle;
  }

  @override
  Future<String> currentOutput(TerminalProcessHandle handle) async =>
      handle.currentOutput();

  @override
  Future<int> waitForExit(TerminalProcessHandle handle) async =>
      handle.waitForExit();

  @override
  Future<void> kill(TerminalProcessHandle handle) async => handle.kill();

  @override
  Future<void> release(TerminalProcessHandle handle) async {
    try {
      await handle.release();
    } finally {
      if (identical(_handles[handle.terminalId], handle)) {
        _handles.remove(handle.terminalId);
      }
    }
  }

  Future<String?> _which(String bin) async {
    try {
      final result = await Process.run('which', [bin]);
      if (result.exitCode == 0) {
        final p = (result.stdout as String).trim();
        if (p.isNotEmpty) return p;
      }
    } on Exception catch (_) {
      // ignore
    }
    return null;
  }
}
