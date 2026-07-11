import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../rpc/line_channel.dart';
import 'byte_budget.dart';
import '../transport/transport.dart';

/// Stdio-based transport that spawns the agent process.
class StdioTransport implements AcpTransport {
  /// Create a stdio transport with logger.
  StdioTransport({
    required this.logger,
    this.command,
    this.args = const [],
    this.envOverrides = const {},
    this.cwd,
    this.onProtocolOut,
    this.onProtocolIn,
    this.maxLineBytes = defaultTransportByteLimit,
    int? maxStderrLineBytes,
  }) : maxStderrLineBytes = maxStderrLineBytes ?? maxLineBytes;

  /// Agent executable name/path.
  final String? command;

  /// Arguments passed to the agent.
  final List<String> args;

  /// Optional working directory for the agent process.
  final String? cwd;

  /// Environment variable overlay for the agent process.
  final Map<String, String> envOverrides;

  /// Logger for diagnostics.
  final Logger logger;

  /// Optional callback for outbound frames.
  final void Function(String line)? onProtocolOut;

  /// Optional callback for inbound frames.
  final void Function(String line)? onProtocolIn;

  /// Maximum raw UTF-8 bytes in one stdin/stdout protocol line.
  final int maxLineBytes;

  /// Maximum raw bytes retained for one stderr diagnostic line.
  final int maxStderrLineBytes;

  Process? _process;
  LineJsonChannel? _channel;
  late Future<int>? _exitCodeFuture;

  @override
  StreamChannel<String> get channel {
    if (_channel == null) {
      throw StateError('Transport not started');
    }
    return _channel!.channel;
  }

  @override
  Future<void> start() async {
    final baseEnv = Map<String, String>.from(Platform.environment);
    baseEnv.addAll(envOverrides);

    Future<Process> spawn(String cmd, List<String> a) async =>
        Process.start(cmd, a, workingDirectory: cwd, environment: baseEnv);

    if (command == null || command!.trim().isEmpty) {
      throw StateError(
        'AcpTransport requires an explicit agent command provided by the host.',
      );
    }
    final cmd = command!;
    final proc = await spawn(cmd, args);
    logger.fine('Spawned agent: $cmd ${args.join(' ')}');

    _process = proc;

    // Store exit code future for checking process state
    _exitCodeFuture = proc.exitCode;

    // Give the process a moment to start, checking if it crashes immediately
    await Future.delayed(const Duration(milliseconds: 100));

    // Check if process has already exited
    var hasExited = false;
    int? exitCode;
    try {
      exitCode = await _exitCodeFuture!.timeout(
        const Duration(milliseconds: 10),
      );
      hasExited = true;
    } on TimeoutException {
      // Process is still running, good
    }

    if (hasExited) {
      throw StateError('Agent process exited immediately with code $exitCode');
    }

    _channel = LineJsonChannel(
      proc,
      onStderr: (s) => logger.finer('[agent stderr] $s'),
      onInboundLine: onProtocolIn,
      onOutboundLine: onProtocolOut,
      maxLineBytes: maxLineBytes,
      maxStderrLineBytes: maxStderrLineBytes,
    );

    // Any process exit ends the protocol stream and all pending requests.
    unawaited(
      _exitCodeFuture!.then((code) {
        if (code != 0) {
          logger.warning('Agent process exited with code $code');
        }
        return _channel?.closeInbound();
      }),
    );
  }

  @override
  Future<void> stop() async {
    if (_channel != null) {
      await _channel!.dispose();
      _channel = null;
    }
    final process = _process;
    final exitCode = process == null ? null : _exitCodeFuture;
    _process = null;
    _exitCodeFuture = null;
    if (process == null) return;

    process.kill(ProcessSignal.sigterm);
    try {
      await exitCode?.timeout(const Duration(milliseconds: 500));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await exitCode?.timeout(const Duration(milliseconds: 500));
    }
  }
}
