import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

import '../transport/byte_budget.dart';

/// Wraps a process's stdio as a bounded line-delimited JSON StreamChannel.
class LineJsonChannel {
  /// Create a line-delimited channel around [process].
  LineJsonChannel(
    this.process, {
    void Function(String)? onStderr,
    this.onInboundLine,
    this.onOutboundLine,
    this.maxLineBytes = defaultTransportByteLimit,
    int? maxStderrLineBytes,
  }) : assert(maxLineBytes > 0),
       assert(maxStderrLineBytes == null || maxStderrLineBytes > 0),
       _onStderr = onStderr,
       maxStderrLineBytes = maxStderrLineBytes ?? maxLineBytes {
    _stdoutDecoder = _RawLineDecoder(
      limit: maxLineBytes,
      resource: 'stdio stdout line',
      onLine: _handleStdoutLine,
      onOverflow: _handleStdoutOverflow,
    );
    _stderrDecoder = _RawLineDecoder(
      limit: this.maxStderrLineBytes,
      resource: 'stdio stderr line',
      discardOversizedLines: true,
      onLine: _handleStderrLine,
      onOverflow: (_) => _emitStderrTruncated(),
    );
    _stdoutSub = process.stdout.listen(
      _stdoutDecoder.add,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(_failStdout(error, stackTrace));
      },
      onDone: () {
        _stdoutDecoder.close();
        if (!_stdoutFailed) unawaited(closeInbound());
      },
    );
    // Always drain stderr to prevent subprocess blocking, even if no callback.
    _stderrSub = process.stderr.listen(
      _stderrDecoder.add,
      onError: (_) {
        // Stderr is diagnostic-only; stdout owns the protocol lifetime.
      },
      onDone: _stderrDecoder.close,
    );
    _outboundSub = _controller.local.stream.listen(
      _enqueueOutbound,
      onError: (Object error, StackTrace stackTrace) {
        unawaited(closeInbound(error, stackTrace));
      },
    );
  }

  /// Underlying process.
  final Process process;
  final int maxLineBytes;
  final int maxStderrLineBytes;
  final StreamChannelController<String> _controller = StreamChannelController();
  final void Function(String)? _onStderr;
  late final _RawLineDecoder _stdoutDecoder;
  late final _RawLineDecoder _stderrDecoder;
  late final StreamSubscription<List<int>> _stdoutSub;
  late final StreamSubscription<List<int>> _stderrSub;
  late final StreamSubscription<String> _outboundSub;
  Future<void>? _closeInboundFuture;
  Future<void>? _disposeFuture;
  Future<void>? _outboundBatchBarrier;
  Future<void> _outboundWrites = Future<void>.value();
  var _stdoutFailed = false;
  var _outboundFailed = false;

  /// Callback invoked for raw inbound lines.
  final void Function(String line)? onInboundLine;

  /// Callback invoked for raw outbound lines.
  final void Function(String line)? onOutboundLine;

  /// Exposed stream channel used by the JSON-RPC peer.
  StreamChannel<String> get channel => _controller.foreign;

  void _handleStdoutLine(List<int> bytes) {
    if (_stdoutFailed) return;
    final line = _decodeLine(bytes, resource: 'stdio stdout line');
    if (line == null) return;
    if (line.trim().isEmpty) return;
    try {
      onInboundLine?.call(line);
    } on Object catch (error, stackTrace) {
      _controller.local.sink.addError(error, stackTrace);
    }
    _controller.local.sink.add(line);
  }

  void _handleStdoutOverflow(TransportByteLimitExceeded error) {
    unawaited(_failStdout(error, StackTrace.current));
  }

  Future<void> _failStdout(Object error, StackTrace stackTrace) async {
    if (_stdoutFailed) return;
    _stdoutFailed = true;
    await _stdoutSub.cancel();
    await closeInbound(error, stackTrace);
  }

  void _handleStderrLine(List<int> bytes) {
    final line = _decodeLine(bytes, resource: 'stdio stderr line');
    if (line == null) {
      _emitStderrTruncated();
      return;
    }
    _onStderr?.call(line);
  }

  String? _decodeLine(List<int> bytes, {required String resource}) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      if (resource.contains('stderr')) return null;
      unawaited(
        _failStdout(
          TransportProtocolDecodeError(resource: resource),
          StackTrace.current,
        ),
      );
      return null;
    }
  }

  void _emitStderrTruncated() {
    _onStderr?.call('truncated');
  }

  void _enqueueOutbound(String line) {
    if (_outboundFailed) return;
    final bytes = utf8.encode(line);
    if (bytes.length > maxLineBytes) {
      _outboundFailed = true;
      unawaited(_outboundSub.cancel());
      unawaited(
        closeInbound(
          TransportByteLimitExceeded(
            resource: 'stdio stdin line',
            limit: maxLineBytes,
            observedAtLeast: bytes.length,
          ),
          StackTrace.current,
        ),
      );
      return;
    }
    final batchBarrier = _getOutboundBatchBarrier();
    _outboundWrites = _outboundWrites
        .then((_) async {
          await batchBarrier;
          if (_outboundFailed) return;
          try {
            onOutboundLine?.call(line);
          } on Object catch (error, stackTrace) {
            _controller.local.sink.addError(error, stackTrace);
          }
          process.stdin.add(<int>[...bytes, 0x0a]);
          await process.stdin.flush();
        })
        .catchError((Object error, StackTrace stackTrace) async {
          await closeInbound(error, stackTrace);
        });
  }

  Future<void> _getOutboundBatchBarrier() {
    final existing = _outboundBatchBarrier;
    if (existing != null) return existing;
    final barrier = Future<void>.delayed(Duration.zero);
    _outboundBatchBarrier = barrier;
    unawaited(
      barrier.whenComplete(() {
        if (identical(_outboundBatchBarrier, barrier)) {
          _outboundBatchBarrier = null;
        }
      }),
    );
    return barrier;
  }

  /// Close the protocol input seen by the JSON-RPC peer.
  Future<void> closeInbound([Object? error, StackTrace? stackTrace]) {
    final existing = _closeInboundFuture;
    if (existing != null) return existing;
    final completer = Completer<void>();
    _closeInboundFuture = completer.future;
    try {
      if (error != null) {
        _controller.local.sink.addError(error, stackTrace);
      }
      unawaited(
        _controller.local.sink.close().then(
          (_) => completer.complete(),
          onError: completer.completeError,
        ),
      );
    } on Object catch (closeError, closeStackTrace) {
      completer.completeError(closeError, closeStackTrace);
    }
    return completer.future;
  }

  /// Dispose resources and flush stdin.
  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    final future = _dispose();
    _disposeFuture = future;
    return future;
  }

  Future<void> _dispose() async {
    _stdoutFailed = true;
    unawaited(closeInbound().catchError((Object _) {}));
    await _outboundSub.cancel();
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    try {
      await _outboundWrites;
      await process.stdin.flush();
    } on Object {
      // The process may already have exited.
    }
  }
}

class _RawLineDecoder {
  _RawLineDecoder({
    required this.limit,
    required this.resource,
    required this.onLine,
    required this.onOverflow,
    this.discardOversizedLines = false,
  });

  final int limit;
  final String resource;
  final void Function(List<int> bytes) onLine;
  final void Function(TransportByteLimitExceeded error) onOverflow;
  final bool discardOversizedLines;
  final List<int> _bytes = <int>[];
  var _pendingCarriageReturn = false;
  var _discarding = false;
  var _closed = false;

  void add(List<int> chunk) {
    if (_closed) return;
    for (final byte in chunk) {
      _addByte(byte);
      if (_closed) return;
    }
  }

  void _addByte(int byte) {
    if (_pendingCarriageReturn) {
      _pendingCarriageReturn = false;
      _finishLine();
      if (byte == 0x0a) return;
    }
    if (byte == 0x0d) {
      _pendingCarriageReturn = true;
      return;
    }
    if (byte == 0x0a) {
      _finishLine();
      return;
    }
    if (_discarding) return;
    _bytes.add(byte);
    if (_bytes.length <= limit) return;
    final error = TransportByteLimitExceeded(
      resource: resource,
      limit: limit,
      observedAtLeast: _bytes.length,
    );
    _bytes.clear();
    onOverflow(error);
    if (discardOversizedLines) {
      _discarding = true;
    } else {
      _closed = true;
    }
  }

  void _finishLine() {
    if (_discarding) {
      _discarding = false;
      _bytes.clear();
      return;
    }
    final line = List<int>.of(_bytes, growable: false);
    _bytes.clear();
    onLine(line);
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_discarding) return;
    if (_pendingCarriageReturn || _bytes.isNotEmpty) _finishLine();
  }
}
