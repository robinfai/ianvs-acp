import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

import '../transport/byte_budget.dart';
import '../transport/raw_line_decoder.dart';

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
    int maxOutboundQueueItems = 128,
    int maxOutboundQueueBytes = 32 * 1024 * 1024,
  }) : assert(maxLineBytes > 0),
       assert(maxStderrLineBytes == null || maxStderrLineBytes > 0),
       _onStderr = onStderr,
       maxStderrLineBytes = maxStderrLineBytes ?? maxLineBytes,
       maxOutboundQueueItems = _positiveQueueLimit(
         maxOutboundQueueItems,
         'maxOutboundQueueItems',
       ),
       maxOutboundQueueBytes = _positiveQueueLimit(
         maxOutboundQueueBytes,
         'maxOutboundQueueBytes',
       ) {
    _stdoutDecoder = RawTransportLineDecoder(
      limit: maxLineBytes,
      resource: 'stdio stdout line',
      onLine: _handleStdoutLine,
      onOverflow: _handleStdoutOverflow,
    );
    _stderrDecoder = RawTransportLineDecoder(
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
  final int maxOutboundQueueItems;
  final int maxOutboundQueueBytes;
  final StreamChannelController<String> _controller =
      StreamChannelController<String>(sync: true);
  final void Function(String)? _onStderr;
  final ListQueue<_OutboundFrame> _outboundQueue = ListQueue<_OutboundFrame>();
  final Completer<void> _outboundDrainCancellation = Completer<void>();
  late final RawTransportLineDecoder _stdoutDecoder;
  late final RawTransportLineDecoder _stderrDecoder;
  late final StreamSubscription<List<int>> _stdoutSub;
  late final StreamSubscription<List<int>> _stderrSub;
  late final StreamSubscription<String> _outboundSub;
  Future<void>? _closeInboundFuture;
  Future<void>? _disposeFuture;
  Future<void>? _outboundBatchBarrier;
  Future<void>? _outboundDrainFuture;
  Future<void>? _activeWrite;
  var _outboundQueueBytes = 0;
  var _outboundDraining = false;
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
      _failOutbound(
        TransportByteLimitExceeded(
          resource: 'stdio stdin line',
          limit: maxLineBytes,
          observedAtLeast: bytes.length,
        ),
        StackTrace.current,
      );
      return;
    }
    final observedItems = _outboundQueue.length + 1;
    final observedBytes = _outboundQueueBytes + bytes.length;
    if (observedItems > maxOutboundQueueItems) {
      _failOutbound(
        TransportByteLimitExceeded(
          resource: 'stdio stdin queue items',
          limit: maxOutboundQueueItems,
          observedAtLeast: observedItems,
        ),
        StackTrace.current,
      );
      return;
    }
    if (observedBytes > maxOutboundQueueBytes) {
      _failOutbound(
        TransportByteLimitExceeded(
          resource: 'stdio stdin queue bytes',
          limit: maxOutboundQueueBytes,
          observedAtLeast: observedBytes,
        ),
        StackTrace.current,
      );
      return;
    }
    _outboundQueue.addLast(_OutboundFrame(line, bytes));
    _outboundQueueBytes = observedBytes;
    _startOutboundDrain();
  }

  void _startOutboundDrain() {
    if (_outboundDraining || _outboundQueue.isEmpty || _outboundFailed) return;
    _outboundDraining = true;
    final future = _drainOutbound();
    _outboundDrainFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_outboundDrainFuture, future)) {
          _outboundDrainFuture = null;
        }
        _outboundDraining = false;
        if (!_outboundFailed && _outboundQueue.isNotEmpty) {
          _startOutboundDrain();
        }
      }),
    );
  }

  Future<void> _drainOutbound() async {
    await _getOutboundBatchBarrier();
    while (_outboundQueue.isNotEmpty && !_outboundFailed) {
      final frame = _outboundQueue.first;
      try {
        onOutboundLine?.call(frame.line);
      } on Object catch (error, stackTrace) {
        _reportInboundError(error, stackTrace);
      }

      Future<void> write;
      try {
        process.stdin.add(<int>[...frame.bytes, 0x0a]);
        write = process.stdin.flush();
      } on Object catch (_, stackTrace) {
        _failOutbound(
          TransportWriteError(resource: 'stdio stdin write'),
          stackTrace,
        );
        return;
      }
      _activeWrite = write;
      try {
        await Future.any<void>(<Future<void>>[
          write,
          _outboundDrainCancellation.future,
        ]);
      } on Object catch (_, stackTrace) {
        if (!_outboundFailed) {
          _failOutbound(
            TransportWriteError(resource: 'stdio stdin write'),
            stackTrace,
          );
        }
        return;
      }
      if (_outboundFailed || _outboundDrainCancellation.isCompleted) {
        unawaited(
          write
              .whenComplete(() {
                if (identical(_activeWrite, write)) _activeWrite = null;
              })
              .catchError((Object _) {}),
        );
        return;
      }
      if (identical(_activeWrite, write)) _activeWrite = null;
      if (_outboundQueue.isNotEmpty && identical(_outboundQueue.first, frame)) {
        _outboundQueue.removeFirst();
        _outboundQueueBytes -= frame.bytes.length;
      }
    }
  }

  void _failOutbound(Object error, StackTrace stackTrace) {
    if (_outboundFailed) return;
    _outboundFailed = true;
    _outboundQueue.clear();
    _outboundQueueBytes = 0;
    if (!_outboundDrainCancellation.isCompleted) {
      _outboundDrainCancellation.complete();
    }
    unawaited(_outboundSub.cancel());
    unawaited(closeInbound(error, stackTrace).catchError((Object _) {}));
  }

  void _reportInboundError(Object error, StackTrace stackTrace) {
    try {
      _controller.local.sink.addError(error, stackTrace);
    } on Object {
      // A callback failure must not disrupt protocol writes during shutdown.
    }
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
    await Future<void>.delayed(Duration.zero);
    unawaited(closeInbound().catchError((Object _) {}));
    await _outboundSub.cancel();
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    final outboundDrain = _outboundDrainFuture;
    try {
      await outboundDrain;
      if (!_outboundFailed) await process.stdin.flush();
    } on Object {
      // The process may already have exited.
    }
  }
}

class _OutboundFrame {
  const _OutboundFrame(this.line, this.bytes);

  final String line;
  final List<int> bytes;
}

int _positiveQueueLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}
