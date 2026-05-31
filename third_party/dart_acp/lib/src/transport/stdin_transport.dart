import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import 'transport.dart';

/// Transport that uses stdin/stdout for communication without spawning a process.
/// This allows the ACP client to communicate with an agent via standard I/O streams.
class StdinTransport implements AcpTransport {
  /// Create a stdin transport with optional callbacks for protocol monitoring.
  ///
  /// For testing, you can provide custom input/output streams instead of using
  /// the global stdin/stdout.
  StdinTransport({
    required this.logger,
    this.onProtocolOut,
    this.onProtocolIn,
    Stream<List<int>>? inputStream,
    IOSink? outputSink,
  }) : _inputStream = inputStream ?? stdin,
       _outputSink = outputSink ?? stdout;

  /// Logger for diagnostics.
  final Logger logger;

  /// Optional callback for outbound frames.
  final void Function(String line)? onProtocolOut;

  /// Optional callback for inbound frames.
  final void Function(String line)? onProtocolIn;

  final Stream<List<int>> _inputStream;
  final IOSink _outputSink;

  StreamController<String>? _inboundController;
  StreamController<String>? _outboundController;
  StreamSubscription? _stdinSubscription;
  StreamChannel<String>? _channel;

  @override
  StreamChannel<String> get channel {
    if (_channel == null) {
      throw StateError('Transport not started');
    }
    return _channel!;
  }

  @override
  Future<void> start() async {
    if (_channel != null) {
      logger.warning('Transport already started');
      return;
    }

    _inboundController = StreamController<String>.broadcast();
    _outboundController = StreamController<String>.broadcast();

    // Read from input stream and forward to inbound controller
    // Only subscribe if we haven't already
    _stdinSubscription ??= _inputStream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            logger.finer('Received from input: $line');
            onProtocolIn?.call(line);
            _inboundController?.add(line);
          },
          onError: (error) {
            logger.severe('Input error: $error');
            _inboundController?.addError(error);
          },
          onDone: () {
            logger.fine('Input closed');
            unawaited(_inboundController?.close());
          },
        );

    // Forward outbound messages to output sink
    _outboundController!.stream.listen(
      (line) {
        logger.finer('Sending to output: $line');
        onProtocolOut?.call(line);
        _outputSink.writeln(line);
      },
      onError: (error) {
        logger.severe('Outbound error: $error');
      },
    );

    _channel = StreamChannel<String>(
      _inboundController!.stream,
      _outboundController!.sink,
    );

    logger.fine('StdinTransport started');
  }

  @override
  Future<void> stop() async {
    await _stdinSubscription?.cancel();
    _stdinSubscription = null;

    await _inboundController?.close();
    _inboundController = null;

    await _outboundController?.close();
    _outboundController = null;

    _channel = null;
    logger.fine('StdinTransport stopped');
  }
}
