import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mcp_dart/mcp_dart.dart' as mcp;

import 'transport_byte_budget.dart' as acp;

/// Process configuration for [BoundedMcpStdioTransport].
final class BoundedMcpStdioServerParameters {
  const BoundedMcpStdioServerParameters({
    required this.command,
    this.args = const <String>[],
    this.environment,
    this.workingDirectory,
  });

  final String command;
  final List<String> args;
  final Map<String, String>? environment;
  final String? workingDirectory;
}

/// MCP stdio transport with strict stdout and stderr byte budgets.
///
/// stdout is decoded one newline-delimited message at a time. The pending line
/// never grows beyond [acp.TransportByteBudget.maxLineBytes]. stderr is always
/// drained and the total bytes produced by one child process are limited by
/// [acp.TransportByteBudget.maxBodyBytes]. A protocol or budget failure closes
/// the transport and terminates the child process.
final class BoundedMcpStdioTransport implements mcp.Transport {
  BoundedMcpStdioTransport({
    required this.parameters,
    this.byteBudget = const acp.TransportByteBudget(),
    Duration teardownTimeout = const Duration(seconds: 2),
  }) : teardownTimeout = _positiveDuration(teardownTimeout, 'teardownTimeout') {
    byteBudget.validate();
  }

  final BoundedMcpStdioServerParameters parameters;
  final acp.TransportByteBudget byteBudget;
  final Duration teardownTimeout;

  final BytesBuilder _stdoutLine = BytesBuilder(copy: false);
  var _stdoutLineBytes = 0;
  var _stderrBytes = 0;

  Process? _process;
  StreamSubscription<List<int>>? _stdoutSubscription;
  StreamSubscription<List<int>>? _stderrSubscription;
  Future<void>? _startFuture;
  Future<void>? _closeFuture;
  var _started = false;
  var _closing = false;
  var _closed = false;
  var _failed = false;
  var _closeNotified = false;

  @override
  void Function()? onclose;

  @override
  void Function(Error error)? onerror;

  @override
  void Function(mcp.JsonRpcMessage message)? onmessage;

  @override
  String? get sessionId => null;

  @override
  Future<void> start() {
    if (_closed || _closing) {
      return Future<void>.error(StateError('MCP stdio transport is closed.'));
    }
    if (_started || _startFuture != null) {
      return Future<void>.error(
        StateError('MCP stdio transport is already started.'),
      );
    }
    late final Future<void> starting;
    starting = _performStart().whenComplete(() {
      if (identical(_startFuture, starting)) _startFuture = null;
    });
    _startFuture = starting;
    return starting;
  }

  Future<void> _performStart() async {
    final process = await Process.start(
      parameters.command,
      parameters.args,
      workingDirectory: parameters.workingDirectory,
      environment: parameters.environment,
      runInShell: false,
      mode: ProcessStartMode.normal,
    );
    _process = process;
    _stdoutSubscription = process.stdout.listen(
      _onStdoutData,
      onError: _onStreamError,
      onDone: _onStdoutDone,
      cancelOnError: false,
    );
    _stderrSubscription = process.stderr.listen(
      _onStderrData,
      onError: _onStreamError,
      cancelOnError: false,
    );
    unawaited(_watchProcess(process));

    if (_closing || _closed) {
      await _stopProcess(process);
      throw StateError('MCP stdio transport closed while starting.');
    }
    _started = true;
  }

  Future<void> _watchProcess(Process process) async {
    final exitCode = await process.exitCode;
    if (!identical(_process, process) || _closing || _closed) return;
    if (exitCode != 0) {
      _reportError(StateError('MCP stdio process exited with code $exitCode.'));
    }
    unawaited(close());
  }

  void _onStdoutData(List<int> chunk) {
    if (_closing || _closed || _failed) return;
    var segmentStart = 0;
    for (var index = 0; index < chunk.length; index += 1) {
      if (chunk[index] != 0x0a) continue;
      if (!_appendStdoutSegment(chunk, segmentStart, index)) return;
      if (!_deliverStdoutLine()) return;
      segmentStart = index + 1;
    }
    _appendStdoutSegment(chunk, segmentStart, chunk.length);
  }

  bool _appendStdoutSegment(List<int> chunk, int start, int end) {
    final length = end - start;
    if (length <= 0) return true;
    final observed = _stdoutLineBytes + length;
    if (observed > byteBudget.maxLineBytes) {
      _fail(
        acp.TransportByteLimitExceeded(
          resource: 'MCP stdio stdout line',
          limit: byteBudget.maxLineBytes,
          observedAtLeast: observed,
        ),
      );
      return false;
    }
    if (chunk is Uint8List) {
      _stdoutLine.add(Uint8List.sublistView(chunk, start, end));
    } else {
      _stdoutLine.add(chunk.sublist(start, end));
    }
    _stdoutLineBytes = observed;
    return true;
  }

  bool _deliverStdoutLine() {
    var bytes = _stdoutLine.takeBytes();
    _stdoutLineBytes = 0;
    if (bytes.isNotEmpty && bytes.last == 0x0d) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
    try {
      final source = utf8.decode(bytes);
      final decoded = acp.decodeTransportJson(
        source,
        resource: 'MCP stdio stdout JSON',
      );
      if (decoded is! Map) {
        throw acp.TransportProtocolDecodeError(
          resource: 'MCP stdio stdout JSON-RPC',
        );
      }
      final json = decoded.map((key, value) => MapEntry(key.toString(), value));
      final message = mcp.JsonRpcMessage.fromJson(json);
      if (_closing || _closed || _failed) return false;
      try {
        onmessage?.call(message);
      } on Object catch (error) {
        _reportError(_asError(error, 'MCP stdio message handler failed.'));
      }
      return true;
    } on Object {
      _fail(
        acp.TransportProtocolDecodeError(resource: 'MCP stdio stdout JSON-RPC'),
      );
      return false;
    }
  }

  void _onStderrData(List<int> chunk) {
    if (_closing || _closed || _failed) return;
    _stderrBytes += chunk.length;
    if (_stderrBytes <= byteBudget.maxBodyBytes) return;
    _fail(
      acp.TransportByteLimitExceeded(
        resource: 'MCP stdio stderr',
        limit: byteBudget.maxBodyBytes,
        observedAtLeast: _stderrBytes,
      ),
    );
  }

  void _onStdoutDone() {
    if (_closing || _closed || _failed || _stdoutLineBytes == 0) return;
    _fail(
      acp.TransportProtocolDecodeError(
        resource: 'MCP stdio truncated stdout JSON-RPC',
      ),
    );
  }

  void _onStreamError(Object error, StackTrace stackTrace) {
    if (_closing || _closed || _failed) return;
    _fail(_asError(error, 'MCP stdio stream failed.'));
  }

  void _fail(Error error) {
    if (_closing || _closed || _failed) return;
    _failed = true;
    _reportError(error);
    unawaited(close());
  }

  void _reportError(Error error) {
    try {
      onerror?.call(error);
    } on Object {
      // A consumer callback cannot prevent transport teardown.
    }
  }

  @override
  Future<void> send(mcp.JsonRpcMessage message, {int? relatedRequestId}) async {
    final process = _process;
    if (!_started || _closing || _closed || process == null) {
      throw StateError('MCP stdio transport is not running.');
    }
    try {
      final encoded = utf8.encode('${jsonEncode(message.toJson())}\n');
      if (encoded.length > byteBudget.maxBodyBytes) {
        throw acp.TransportByteLimitExceeded(
          resource: 'MCP stdio stdin message',
          limit: byteBudget.maxBodyBytes,
          observedAtLeast: encoded.length,
        );
      }
      process.stdin.add(encoded);
      await process.stdin.flush();
    } on Object catch (error) {
      final reported = error is Error
          ? error
          : acp.TransportWriteError(resource: 'MCP stdio stdin');
      _fail(reported);
      throw reported;
    }
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closing = true;
    late final Future<void> closing;
    closing = _performClose().whenComplete(() {
      _closed = true;
      _closing = false;
      _started = false;
      if (!_closeNotified) {
        _closeNotified = true;
        try {
          onclose?.call();
        } on Object {
          // Local cleanup is complete even if a consumer callback fails.
        }
      }
    });
    _closeFuture = closing;
    return closing;
  }

  Future<void> _performClose() async {
    final starting = _startFuture;
    if (starting != null) {
      try {
        await starting;
      } on Object {
        // A close racing start owns cleanup of any spawned process.
      }
    }

    final process = _process;
    if (process != null) await _stopProcess(process);

    final stdout = _stdoutSubscription;
    final stderr = _stderrSubscription;
    _stdoutSubscription = null;
    _stderrSubscription = null;
    await Future.wait<void>(<Future<void>>[
      if (stdout != null) stdout.cancel().catchError((Object _) {}),
      if (stderr != null) stderr.cancel().catchError((Object _) {}),
    ]);
    _process = null;
    _stdoutLine.clear();
    _stdoutLineBytes = 0;
  }

  Future<void> _stopProcess(Process process) async {
    // Keep stdout and stderr subscriptions active while termination is in
    // flight. Closing stdin is best effort and must never delay SIGTERM: a
    // child that stopped reading its pipe could otherwise block teardown.
    unawaited(process.stdin.close().catchError((Object _) {}));
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(teardownTimeout);
      return;
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
    }
    try {
      await process.exitCode.timeout(teardownTimeout);
    } on TimeoutException {
      _reportError(
        StateError('MCP stdio process did not terminate after SIGKILL.'),
      );
    }
  }
}

Duration _positiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

Error _asError(Object error, String fallback) {
  return error is Error ? error : StateError(fallback);
}
