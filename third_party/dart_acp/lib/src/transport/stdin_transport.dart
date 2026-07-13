import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import 'byte_budget.dart';
import 'raw_line_decoder.dart';
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
    int maxLineBytes = defaultTransportByteLimit,
  }) : maxLineBytes = _positiveLineLimit(maxLineBytes),
       _inputStream = inputStream ?? stdin,
       _outputSink = outputSink ?? stdout;

  /// Logger for diagnostics.
  final Logger logger;

  /// Optional callback for outbound frames.
  final void Function(String line)? onProtocolOut;

  /// Optional callback for inbound frames.
  final void Function(String line)? onProtocolIn;

  final Stream<List<int>> _inputStream;
  final IOSink _outputSink;

  /// Maximum raw UTF-8 bytes accepted in one inbound protocol line.
  final int maxLineBytes;

  StreamController<String>? _inboundController;
  StreamController<String>? _outboundController;
  StreamSubscription? _stdinSubscription;
  StreamChannel<String>? _channel;
  RawTransportLineDecoder? _inputDecoder;
  var _inputFailed = false;
  var _inputSubscriptionReady = false;
  _InputFailure? _inputFailure;
  Future<void> _lifecycleTail = Future<void>.value();
  var _generationCounter = 0;
  int? _activeGeneration;

  @override
  StreamChannel<String> get channel {
    if (_channel == null) {
      throw StateError('Transport not started');
    }
    return _channel!;
  }

  @override
  Future<void> start() => _serializeLifecycle(_start);

  Future<void> _start() async {
    if (_channel != null) {
      logger.warning('Transport already started');
      return;
    }

    final generation = ++_generationCounter;
    _activeGeneration = generation;
    final inboundController = StreamController<String>.broadcast();
    final outboundController = StreamController<String>.broadcast();
    _inboundController = inboundController;
    _outboundController = outboundController;

    _inputFailed = false;
    _inputSubscriptionReady = false;
    _inputFailure = null;
    late final RawTransportLineDecoder inputDecoder;
    inputDecoder = RawTransportLineDecoder(
      limit: maxLineBytes,
      resource: 'stdin input line',
      onLine: (bytes) => _handleInputLine(generation, bytes),
      onOverflow: (error) {
        _failInput(generation, error, StackTrace.current);
      },
    );
    _inputDecoder = inputDecoder;

    // Read from input stream and forward to inbound controller
    late final StreamSubscription<List<int>> inputSubscription;
    try {
      inputSubscription = _inputStream.listen(
        inputDecoder.add,
        onError: (Object error, StackTrace stackTrace) {
          _failInput(generation, error, stackTrace);
        },
        onDone: () {
          if (_activeGeneration != generation || _inputFailed) return;
          inputDecoder.close();
          logger.fine('Input closed');
          unawaited(inboundController.close());
        },
      );
    } on Object catch (error, stackTrace) {
      await _resetFailedStart(
        generation: generation,
        inboundController: inboundController,
        outboundController: outboundController,
        inputDecoder: inputDecoder,
      );
      Error.throwWithStackTrace(error, stackTrace);
    }
    _stdinSubscription = inputSubscription;
    _inputSubscriptionReady = true;
    final synchronousFailure = _inputFailure;
    if (synchronousFailure != null) {
      try {
        await inputSubscription.cancel();
      } on Object {
        // Preserve the original protocol failure raised during listen.
      }
      if (identical(_stdinSubscription, inputSubscription)) {
        _stdinSubscription = null;
      }
      await _resetFailedStart(
        generation: generation,
        inboundController: inboundController,
        outboundController: outboundController,
        inputDecoder: inputDecoder,
      );
      Error.throwWithStackTrace(
        synchronousFailure.error,
        synchronousFailure.stackTrace,
      );
    }

    // Forward outbound messages to output sink
    outboundController.stream.listen(
      (line) {
        logger.finer('Sending to output: $line');
        try {
          onProtocolOut?.call(line);
        } on Object catch (error, stackTrace) {
          _reportProtocolObserverFailure(
            generation: generation,
            inboundController: inboundController,
            direction: 'Outbound',
            error: error,
            stackTrace: stackTrace,
          );
        }
        _outputSink.writeln(line);
      },
      onError: (error) {
        logger.severe('Outbound error: $error');
      },
    );

    _channel = StreamChannel<String>(
      inboundController.stream,
      outboundController.sink,
    );

    logger.fine('StdinTransport started');
  }

  void _handleInputLine(int generation, List<int> bytes) {
    if (_activeGeneration != generation || _inputFailed) return;
    final String line;
    try {
      line = utf8.decode(bytes);
    } on FormatException {
      _failInput(
        generation,
        TransportProtocolDecodeError(resource: 'stdin input line'),
        StackTrace.current,
      );
      return;
    }
    logger.finer('Received from input: $line');
    final inboundController = _inboundController;
    try {
      onProtocolIn?.call(line);
    } on Object catch (error, stackTrace) {
      if (inboundController != null) {
        _reportProtocolObserverFailure(
          generation: generation,
          inboundController: inboundController,
          direction: 'Inbound',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (_activeGeneration == generation) {
      inboundController?.add(line);
    }
  }

  void _reportProtocolObserverFailure({
    required int generation,
    required StreamController<String> inboundController,
    required String direction,
    required Object error,
    required StackTrace stackTrace,
  }) {
    logger.warning('$direction protocol observer failed');
    if (_activeGeneration != generation ||
        !identical(_inboundController, inboundController) ||
        inboundController.isClosed) {
      return;
    }
    try {
      inboundController.addError(error, stackTrace);
    } on Object {
      // Observer diagnostics must not interrupt protocol traffic during close.
    }
  }

  void _failInput(int generation, Object error, StackTrace stackTrace) {
    if (_activeGeneration != generation || _inputFailed) return;
    _inputFailed = true;
    final failure = _InputFailure(error, stackTrace);
    _inputFailure = failure;
    _inputDecoder?.cancel();
    logger.severe('Input failed: $error');
    if (!_inputSubscriptionReady) return;
    _reportInputFailure(generation, failure);
  }

  void _reportInputFailure(int generation, _InputFailure failure) {
    final controller = _inboundController;
    if (controller != null && !controller.isClosed) {
      controller.addError(failure.error, failure.stackTrace);
    }
    final subscription = _stdinSubscription;
    unawaited(
      _cancelFailedInput(
        generation: generation,
        controller: controller,
        subscription: subscription,
      ),
    );
  }

  Future<void> _cancelFailedInput({
    required int generation,
    required StreamController<String>? controller,
    required StreamSubscription? subscription,
  }) async {
    try {
      await subscription?.cancel();
    } on Object {
      // Preserve the already-published payload-free input failure.
    } finally {
      if (controller != null && !controller.isClosed) {
        try {
          await controller.close();
        } on Object {
          // Input shutdown is best effort after the protocol has failed.
        }
      }
      if (_activeGeneration == generation) {
        if (identical(_stdinSubscription, subscription)) {
          _stdinSubscription = null;
        }
        _inputSubscriptionReady = false;
      }
    }
  }

  Future<void> _resetFailedStart({
    required int generation,
    required StreamController<String> inboundController,
    required StreamController<String> outboundController,
    required RawTransportLineDecoder inputDecoder,
  }) async {
    inputDecoder.cancel();
    if (!inboundController.isClosed) {
      try {
        await inboundController.close();
      } on Object {
        // Preserve the synchronous input failure from start.
      }
    }
    if (!outboundController.isClosed) {
      try {
        await outboundController.close();
      } on Object {
        // Preserve the synchronous input failure from start.
      }
    }
    if (_activeGeneration == generation) {
      _activeGeneration = null;
      _inputSubscriptionReady = false;
      _inputDecoder = null;
      _inputFailure = null;
      if (identical(_inboundController, inboundController)) {
        _inboundController = null;
      }
      if (identical(_outboundController, outboundController)) {
        _outboundController = null;
      }
      _channel = null;
    }
  }

  @override
  Future<void> stop() => _serializeLifecycle(_stop);

  Future<void> _stop() async {
    final subscription = _stdinSubscription;
    final inputDecoder = _inputDecoder;
    final inboundController = _inboundController;
    final outboundController = _outboundController;

    _activeGeneration = null;
    _stdinSubscription = null;
    _inputSubscriptionReady = false;
    _inputDecoder = null;
    _inputFailure = null;
    _inboundController = null;
    _outboundController = null;
    _channel = null;

    inputDecoder?.cancel();
    try {
      await subscription?.cancel();
    } on Object {
      // Local stop must complete even if a custom stream cannot cancel.
    }
    if (inboundController != null && !inboundController.isClosed) {
      try {
        await inboundController.close();
      } on Object {
        // Continue releasing the remaining resources.
      }
    }
    if (outboundController != null && !outboundController.isClosed) {
      try {
        await outboundController.close();
      } on Object {
        // Continue releasing the remaining resources.
      }
    }
    logger.fine('StdinTransport stopped');
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

class _InputFailure {
  const _InputFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

int _positiveLineLimit(int value) {
  if (value <= 0) {
    throw ArgumentError.value(
      value,
      'maxLineBytes',
      'must be greater than zero',
    );
  }
  return value;
}
