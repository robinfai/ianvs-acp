import 'dart:async';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import '../rpc/line_channel.dart';
import 'byte_budget.dart';
import '../transport/transport.dart';

/// Starts a stdio child process.
typedef StdioProcessStarter =
    Future<Process> Function(
      String command,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

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
    int maxLineBytes = defaultTransportByteLimit,
    int? maxStderrLineBytes,
    int maxOutboundQueueItems = 128,
    int maxOutboundQueueBytes = 32 * 1024 * 1024,
    StdioProcessStarter? processStarter,
  }) : maxLineBytes = _positiveByteLimit(maxLineBytes, 'maxLineBytes'),
       maxStderrLineBytes = _positiveByteLimit(
         maxStderrLineBytes ?? maxLineBytes,
         'maxStderrLineBytes',
       ),
       maxOutboundQueueItems = _positiveByteLimit(
         maxOutboundQueueItems,
         'maxOutboundQueueItems',
       ),
       maxOutboundQueueBytes = _positiveByteLimit(
         maxOutboundQueueBytes,
         'maxOutboundQueueBytes',
       ),
       _processStarter = processStarter ?? _defaultProcessStarter;

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

  /// Maximum accepted stdin lines, including the active flush.
  final int maxOutboundQueueItems;

  /// Maximum accepted stdin UTF-8 bytes, including the active flush.
  final int maxOutboundQueueBytes;
  final StdioProcessStarter _processStarter;

  Process? _process;
  LineJsonChannel? _channel;
  late Future<int>? _exitCodeFuture;
  Future<void> _lifecycleTail = Future<void>.value();
  Future<void>? _coalescedStopFuture;

  @override
  StreamChannel<String> get channel {
    if (_channel == null) {
      throw StateError('Transport not started');
    }
    return _channel!.channel;
  }

  @override
  Future<void> start() {
    _coalescedStopFuture = null;
    return _serializeLifecycle(_start);
  }

  Future<void> _start() async {
    if (_process != null || _channel != null) {
      logger.warning('Stdio transport is already started');
      return;
    }
    final baseEnv = Map<String, String>.from(Platform.environment);
    baseEnv.addAll(envOverrides);

    if (command == null || command!.trim().isEmpty) {
      throw StateError(
        'AcpTransport requires an explicit agent command provided by the host.',
      );
    }
    final cmd = command!;
    late final Process proc;
    try {
      proc = await _processStarter(
        cmd,
        args,
        workingDirectory: cwd,
        environment: baseEnv,
      );
    } on Object {
      throw StateError('Agent process could not be started.');
    }
    logger.fine('Spawned agent process');
    final exitCodeFuture = proc.exitCode;

    // Give the process a moment to start, checking if it crashes immediately
    await Future.delayed(const Duration(milliseconds: 100));

    // Check if process has already exited
    var hasExited = false;
    try {
      await exitCodeFuture.timeout(const Duration(milliseconds: 10));
      hasExited = true;
    } on TimeoutException {
      // Process is still running, good
    }

    if (hasExited) {
      await _closeExitedProcess(proc);
      throw StateError('Agent process exited immediately.');
    }

    late final LineJsonChannel channel;
    try {
      channel = LineJsonChannel(
        proc,
        onStderr: (_) => logger.finer('Agent stderr line received'),
        onInboundLine: onProtocolIn,
        onOutboundLine: onProtocolOut,
        maxLineBytes: maxLineBytes,
        maxStderrLineBytes: maxStderrLineBytes,
        maxOutboundQueueItems: maxOutboundQueueItems,
        maxOutboundQueueBytes: maxOutboundQueueBytes,
      );
    } on Object {
      await _terminateAndReap(proc, exitCodeFuture);
      rethrow;
    }

    _process = proc;
    _exitCodeFuture = exitCodeFuture;
    _channel = channel;

    // stdout EOF owns protocol closure because exitCode may complete before
    // stdout has reported all buffered output.
    unawaited(
      exitCodeFuture.then((code) {
        if (code != 0) {
          logger.warning('Agent process exited with code $code');
        }
      }),
    );
  }

  @override
  Future<void> stop() {
    final existing = _coalescedStopFuture;
    if (existing != null) return existing;
    final future = _serializeLifecycle(_stop);
    _coalescedStopFuture = future;
    unawaited(
      future
          .whenComplete(() {
            if (identical(_coalescedStopFuture, future)) {
              _coalescedStopFuture = null;
            }
          })
          .catchError((Object _) {}),
    );
    return future;
  }

  Future<void> _stop() async {
    final channel = _channel;
    final process = _process;
    final exitCode = process == null ? null : _exitCodeFuture;
    _channel = null;
    _process = null;
    _exitCodeFuture = null;

    try {
      await channel?.dispose();
    } on Object {
      logger.fine('Agent channel shutdown failed');
    }
    if (process == null || exitCode == null) return;

    await _terminateAndReap(process, exitCode);
  }

  Future<void> _terminateAndReap(Process process, Future<int> exitCode) async {
    if (await _isExited(exitCode)) return;

    process.kill(ProcessSignal.sigterm);
    try {
      await exitCode.timeout(const Duration(milliseconds: 500));
      return;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    await exitCode;
  }

  Future<void> _closeExitedProcess(Process process) async {
    await Future.wait<void>(<Future<void>>[
      _ignoreCleanupAction(process.stdin.close),
      _ignoreCleanupAction(() => _cancelExitedOutput(process.stdout)),
      _ignoreCleanupAction(() => _cancelExitedOutput(process.stderr)),
    ]);
  }

  Future<bool> _isExited(Future<int> exitCode) async {
    try {
      await exitCode.timeout(Duration.zero);
      return true;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> _serializeLifecycle(Future<void> Function() operation) {
    final current = _lifecycleTail.then((_) => operation());
    _lifecycleTail = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return current;
  }
}

Future<Process> _defaultProcessStarter(
  String command,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) => Process.start(
  command,
  arguments,
  workingDirectory: workingDirectory,
  environment: environment,
);

Future<void> _ignoreCleanupAction(Future<void> Function() action) async {
  try {
    await action();
  } on Object {
    // The process is already reaped; cleanup must not expose stream payloads.
  }
}

Future<void> _cancelExitedOutput(Stream<List<int>> output) async {
  final subscription = output.listen(
    (_) {},
    onError: (Object _, StackTrace _) {
      // Closing an already-exited process must not surface diagnostic payloads.
    },
  );
  await subscription.cancel();
}

int _positiveByteLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}
