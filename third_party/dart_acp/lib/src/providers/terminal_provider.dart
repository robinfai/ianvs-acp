import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Handle for a managed terminal process.
class TerminalProcessHandle {
  /// Create a terminal process handle.
  TerminalProcessHandle({required this.terminalId, required this.process})
    : _stdoutSub = process.stdout.listen((data) {}),
      _stderrSub = process.stderr.listen((data) {}) {
    // Rewire subscriptions to buffer output as text
    _stdoutSub.onData((data) => _buffer.write(utf8.decode(data)));
    _stderrSub.onData((data) => _buffer.write(utf8.decode(data)));
  }

  /// Unique terminal identifier.
  final String terminalId;

  /// Underlying OS process.
  final Process process;
  final StreamSubscription<List<int>> _stdoutSub;
  final StreamSubscription<List<int>> _stderrSub;
  final StringBuffer _buffer = StringBuffer();
  bool _released = false;

  /// Return currently buffered output as a String.
  String currentOutput() => _buffer.toString();

  /// Wait for process to exit and return its code.
  Future<int> waitForExit() async => process.exitCode;

  /// Kill the process with SIGTERM.
  Future<void> kill() async {
    process.kill(ProcessSignal.sigterm);
  }

  /// Release resources and cancel stdout/stderr subscriptions.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
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
  final Map<String, TerminalProcessHandle> _handles = {};

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const [],
    String? cwd,
    Map<String, String>? env,
  }) async {
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
    await handle.release();
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
