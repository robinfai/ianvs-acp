import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:stream_channel/stream_channel.dart';

/// Wraps a process's stdio as a line-delimited JSON StreamChannel.
class LineJsonChannel {
  /// Create a line-delimited channel around [process].
  LineJsonChannel(
    this.process, {
    void Function(String)? onStderr,
    this.onInboundLine,
    this.onOutboundLine,
  }) {
    _stdoutSub = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            if (line.trim().isEmpty) return;
            onInboundLine?.call(line);
            _controller.local.sink.add(line);
          },
          onError: (Object error, StackTrace stackTrace) {
            unawaited(closeInbound(error, stackTrace));
          },
          onDone: () {
            unawaited(closeInbound());
          },
        );
    // Always drain stderr to prevent subprocess blocking, even if no callback
    _stderrSub = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            // Always consume the data to prevent blocking
            onStderr?.call(line);
          },
          onError: (e) {
            // Stderr is diagnostic-only; stdout owns the protocol lifetime.
          },
        );

    _outboundSub = _controller.local.stream.listen(
      (out) {
        // Each outgoing payload is one JSON-RPC message; append newline
        onOutboundLine?.call(out);
        try {
          process.stdin.add(utf8.encode(out));
          process.stdin.add([0x0A]);
          // Flush to ensure immediate delivery
          unawaited(
            process.stdin.flush().catchError((Object error) {
              unawaited(closeInbound(error, StackTrace.current));
            }),
          );
        } on Object catch (error, stackTrace) {
          unawaited(closeInbound(error, stackTrace));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        unawaited(closeInbound(error, stackTrace));
      },
    );
  }

  /// Underlying process.
  final Process process;
  final StreamChannelController<String> _controller = StreamChannelController();
  late final StreamSubscription _stdoutSub;
  late final StreamSubscription _stderrSub;
  late final StreamSubscription<String> _outboundSub;
  Future<void>? _closeInboundFuture;

  /// Callback invoked for raw inbound lines.
  final void Function(String line)? onInboundLine;

  /// Callback invoked for raw outbound lines.
  final void Function(String line)? onOutboundLine;

  /// Exposed stream channel used by the JSON-RPC peer.
  StreamChannel<String> get channel => _controller.foreign;

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
  Future<void> dispose() async {
    await closeInbound();
    await _outboundSub.cancel();
    await _stdoutSub.cancel();
    await _stderrSub.cancel();
    try {
      await process.stdin.flush();
    } on Object {
      // The process may already have exited.
    }
  }
}
