import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

import 'byte_budget.dart';
import 'raw_line_decoder.dart';
import 'transport.dart';

/// Transport that uses stdin/stdout for communication without spawning a process.
/// This allows the ACP client to communicate with an agent via standard I/O streams.
/// The inbound side of [channel] supports one listener.
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
    int maxOutboundQueueItems = 128,
    int maxOutboundQueueBytes = 32 * 1024 * 1024,
    int maxInboundQueueItems = 128,
    int maxInboundQueueBytes = 32 * 1024 * 1024,
    Duration stopDrainTimeout = const Duration(milliseconds: 500),
  }) : maxLineBytes = _positiveLimit(maxLineBytes, 'maxLineBytes'),
       maxOutboundQueueItems = _positiveLimit(
         maxOutboundQueueItems,
         'maxOutboundQueueItems',
       ),
       maxOutboundQueueBytes = _positiveLimit(
         maxOutboundQueueBytes,
         'maxOutboundQueueBytes',
       ),
       maxInboundQueueItems = _positiveLimit(
         maxInboundQueueItems,
         'maxInboundQueueItems',
       ),
       maxInboundQueueBytes = _positiveLimit(
         maxInboundQueueBytes,
         'maxInboundQueueBytes',
       ),
       stopDrainTimeout = _positiveDuration(
         stopDrainTimeout,
         'stopDrainTimeout',
       ),
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

  /// Maximum raw UTF-8 bytes accepted in one protocol line.
  final int maxLineBytes;

  /// Maximum accepted output lines, including the active flush.
  final int maxOutboundQueueItems;

  /// Maximum accepted output UTF-8 bytes, including the active flush.
  final int maxOutboundQueueBytes;

  /// Maximum accepted, not-yet-delivered input lines.
  final int maxInboundQueueItems;

  /// Maximum accepted raw input bytes waiting for delivery.
  final int maxInboundQueueBytes;

  /// Maximum total time [stop] or failed-start cleanup waits for asynchronous
  /// resource cleanup, including active output flushes.
  final Duration stopDrainTimeout;

  StreamController<String>? _inboundController;
  StreamController<String>? _outboundController;
  StreamSubscription? _stdinSubscription;
  StreamSubscription<String>? _outboundSubscription;
  StreamChannel<String>? _channel;
  RawTransportLineDecoder? _inputDecoder;
  final ListQueue<_InputFrame> _inputQueue = ListQueue<_InputFrame>();
  final ListQueue<_OutputFrame> _outputQueue = ListQueue<_OutputFrame>();
  _InputFrame? _activeInputFrame;
  var _inputFailed = false;
  var _outputFailed = false;
  var _inputSubscriptionReady = false;
  var _inputListening = false;
  var _inputPaused = false;
  var _inputCancelled = false;
  var _inputDrainScheduled = false;
  var _inputDone = false;
  var _outputDraining = false;
  var _inputQueueBytes = 0;
  var _outputQueueBytes = 0;
  _InputFailure? _terminalFailure;
  var _terminalPublished = false;
  Future<void>? _outputDrainFuture;
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
    late final StreamController<String> inboundController;
    inboundController = StreamController<String>(
      sync: true,
      onListen: () => _handleInputListen(generation, inboundController),
      onPause: () => _handleInputPause(generation, inboundController),
      onResume: () => _handleInputResume(generation, inboundController),
      onCancel: () => _handleInputCancel(generation, inboundController),
    );
    final outboundController = StreamController<String>(sync: true);
    _inboundController = inboundController;
    _outboundController = outboundController;

    _inputFailed = false;
    _outputFailed = false;
    _inputSubscriptionReady = false;
    _inputListening = false;
    _inputPaused = false;
    _inputCancelled = false;
    _inputDrainScheduled = false;
    _inputDone = false;
    _outputDraining = false;
    _inputQueue.clear();
    _outputQueue.clear();
    _activeInputFrame = null;
    _inputQueueBytes = 0;
    _outputQueueBytes = 0;
    _terminalFailure = null;
    _terminalPublished = false;
    _outputDrainFuture = null;
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
          _inputDone = true;
          _scheduleInputDrain(generation, inboundController);
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
    final synchronousFailure = _terminalFailure;
    if (synchronousFailure != null) {
      final cleanupDeadline = Future<void>.delayed(stopDrainTimeout);
      await _waitForCleanup(
        cleanupDeadline: cleanupDeadline,
        cleanupFutures: <Future<void>>[
          _observeCleanup(inputSubscription.cancel),
        ],
      );
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
    _outboundSubscription = outboundController.stream.listen(
      (line) => _enqueueOutput(generation, inboundController, line),
      onError: (_) {
        logger.severe('Outbound stream failed');
      },
    );

    _channel = StreamChannel<String>(
      inboundController.stream,
      outboundController.sink,
    );

    logger.fine('StdinTransport started');
  }

  void _handleInputLine(int generation, RawTransportLine rawLine) {
    if (_activeGeneration != generation || _inputFailed || _inputCancelled) {
      return;
    }
    final String line;
    try {
      line = rawLine.decodeUtf8();
    } on FormatException {
      _failInput(
        generation,
        TransportProtocolDecodeError(resource: 'stdin input line'),
        StackTrace.current,
        discardQueued: true,
      );
      return;
    }
    final inboundController = _inboundController;
    if (inboundController == null) return;
    final observedItems =
        _inputQueue.length + (_activeInputFrame == null ? 0 : 1) + 1;
    final observedBytes =
        _inputQueueBytes +
        (_activeInputFrame?.rawByteLength ?? 0) +
        rawLine.byteLength;
    if (observedItems > maxInboundQueueItems) {
      _failInput(
        generation,
        TransportByteLimitExceeded(
          resource: 'stdin input queue items',
          limit: maxInboundQueueItems,
          observedAtLeast: observedItems,
        ),
        StackTrace.current,
        discardQueued: true,
      );
      return;
    }
    if (observedBytes > maxInboundQueueBytes) {
      _failInput(
        generation,
        TransportByteLimitExceeded(
          resource: 'stdin input queue bytes',
          limit: maxInboundQueueBytes,
          observedAtLeast: observedBytes,
        ),
        StackTrace.current,
        discardQueued: true,
      );
      return;
    }
    _inputQueue.addLast(_InputFrame(line, rawLine.byteLength));
    _inputQueueBytes += rawLine.byteLength;
    _scheduleInputDrain(generation, inboundController);
  }

  void _handleInputListen(int generation, StreamController<String> controller) {
    if (!_ownsInputController(generation, controller)) return;
    _inputListening = true;
    _inputPaused = false;
    _scheduleInputDrain(generation, controller);
  }

  void _handleInputPause(int generation, StreamController<String> controller) {
    if (_ownsInputController(generation, controller)) _inputPaused = true;
  }

  void _handleInputResume(int generation, StreamController<String> controller) {
    if (!_ownsInputController(generation, controller)) return;
    _inputPaused = false;
    _scheduleInputDrain(generation, controller);
  }

  void _handleInputCancel(int generation, StreamController<String> controller) {
    if (!_ownsInputController(generation, controller)) return;
    _inputListening = false;
    _inputPaused = false;
    _inputCancelled = true;
    _inputQueue.clear();
    _activeInputFrame?.accepted = false;
    _activeInputFrame = null;
    _inputQueueBytes = 0;
    _inputDecoder?.cancel();
    final subscription = _stdinSubscription;
    unawaited(_cancelListenerInput(generation, subscription));
  }

  Future<void> _cancelListenerInput(
    int generation,
    StreamSubscription? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } on Object {
      // Listener cancellation owns the protocol; stream cleanup is best effort.
    } finally {
      if (_activeGeneration == generation &&
          identical(_stdinSubscription, subscription)) {
        _stdinSubscription = null;
        _inputSubscriptionReady = false;
      }
    }
  }

  bool _ownsInputController(
    int generation,
    StreamController<String> controller,
  ) =>
      _activeGeneration == generation &&
      identical(_inboundController, controller) &&
      !controller.isClosed;

  void _scheduleInputDrain(
    int generation,
    StreamController<String> controller,
  ) {
    if (_inputDrainScheduled ||
        !_ownsInputController(generation, controller) ||
        !_inputListening ||
        _inputPaused ||
        _inputCancelled) {
      return;
    }
    if (_activeInputFrame == null &&
        _inputQueue.isEmpty &&
        !_inputDone &&
        _terminalFailure == null) {
      return;
    }
    _inputDrainScheduled = true;
    scheduleMicrotask(() {
      if (!_ownsInputController(generation, controller)) return;
      _inputDrainScheduled = false;
      _drainOneInput(generation, controller);
    });
  }

  void _drainOneInput(int generation, StreamController<String> controller) {
    if (!_ownsInputController(generation, controller) ||
        !_inputListening ||
        _inputPaused ||
        _inputCancelled) {
      return;
    }
    var frame = _activeInputFrame;
    if (frame == null && _inputQueue.isNotEmpty) {
      frame = _inputQueue.removeFirst();
      _inputQueueBytes -= frame.rawByteLength;
      _activeInputFrame = frame;
    }
    if (frame != null) {
      logger.finer('Input protocol line received');
      if (!frame.observerDelivered) {
        frame.observerDelivered = true;
        try {
          onProtocolIn?.call(frame.line);
        } on Object catch (error, stackTrace) {
          _reportProtocolObserverFailure(
            generation: generation,
            inboundController: controller,
            direction: 'Inbound',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      if (!_ownsInputController(generation, controller) ||
          !identical(_activeInputFrame, frame) ||
          !frame.accepted) {
        return;
      }
      if (_inputPaused) return;
      _activeInputFrame = null;
      controller.add(frame.line);
      _scheduleInputDrain(generation, controller);
      return;
    }
    final failure = _terminalFailure;
    if (failure != null && !_terminalPublished) {
      _terminalPublished = true;
      controller.addError(failure.error, failure.stackTrace);
      unawaited(controller.close());
    } else if (_inputDone && !controller.isClosed) {
      unawaited(controller.close());
    }
  }

  void _enqueueOutput(
    int generation,
    StreamController<String> inboundController,
    String line,
  ) {
    if (_activeGeneration != generation || _outputFailed) return;
    final bytes = utf8.encode(line);
    if (bytes.length > maxLineBytes) {
      _failOutput(
        generation,
        TransportByteLimitExceeded(
          resource: 'stdin output line',
          limit: maxLineBytes,
          observedAtLeast: bytes.length,
        ),
        StackTrace.current,
      );
      return;
    }
    final observedItems = _outputQueue.length + 1;
    final observedBytes = _outputQueueBytes + bytes.length;
    if (observedItems > maxOutboundQueueItems) {
      _failOutput(
        generation,
        TransportByteLimitExceeded(
          resource: 'stdin output queue items',
          limit: maxOutboundQueueItems,
          observedAtLeast: observedItems,
        ),
        StackTrace.current,
      );
      return;
    }
    if (observedBytes > maxOutboundQueueBytes) {
      _failOutput(
        generation,
        TransportByteLimitExceeded(
          resource: 'stdin output queue bytes',
          limit: maxOutboundQueueBytes,
          observedAtLeast: observedBytes,
        ),
        StackTrace.current,
      );
      return;
    }
    _outputQueue.addLast(_OutputFrame(line, bytes.length));
    _outputQueueBytes = observedBytes;
    _startOutputDrain(generation, inboundController);
  }

  void _startOutputDrain(
    int generation,
    StreamController<String> inboundController,
  ) {
    if (_outputDraining || _outputFailed || _outputQueue.isEmpty) return;
    _outputDraining = true;
    late final Future<void> drain;
    drain = _drainOutput(generation, inboundController);
    _outputDrainFuture = drain;
    unawaited(
      drain.whenComplete(() {
        if (_activeGeneration != generation) return;
        if (identical(_outputDrainFuture, drain)) _outputDrainFuture = null;
        _outputDraining = false;
        if (!_outputFailed && _outputQueue.isNotEmpty) {
          _startOutputDrain(generation, inboundController);
        }
      }),
    );
  }

  Future<void> _drainOutput(
    int generation,
    StreamController<String> inboundController,
  ) async {
    await Future<void>.delayed(Duration.zero);
    while (_activeGeneration == generation &&
        !_outputFailed &&
        _outputQueue.isNotEmpty) {
      final frame = _outputQueue.first;
      logger.finer('Output protocol line sent');
      try {
        onProtocolOut?.call(frame.line);
      } on Object catch (error, stackTrace) {
        _reportProtocolObserverFailure(
          generation: generation,
          inboundController: inboundController,
          direction: 'Outbound',
          error: error,
          stackTrace: stackTrace,
        );
      }
      try {
        _outputSink.writeln(frame.line);
        await _outputSink.flush();
      } on Object catch (_, stackTrace) {
        _failOutput(
          generation,
          TransportWriteError(resource: 'stdin output write'),
          stackTrace,
        );
        return;
      }
      if (_activeGeneration != generation || _outputFailed) return;
      if (_outputQueue.isNotEmpty && identical(_outputQueue.first, frame)) {
        _outputQueue.removeFirst();
        _outputQueueBytes -= frame.utf8Bytes;
      }
    }
  }

  void _failOutput(int generation, Object error, StackTrace stackTrace) {
    _failInput(generation, error, stackTrace, discardQueued: true);
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

  void _failInput(
    int generation,
    Object error,
    StackTrace stackTrace, {
    bool discardQueued = false,
  }) {
    if (_activeGeneration != generation || _terminalFailure != null) return;
    final failure = _InputFailure(error, stackTrace);
    _terminalFailure = failure;
    _inputFailed = true;
    _outputFailed = true;
    _outputQueue.clear();
    _outputQueueBytes = 0;
    unawaited(_outboundSubscription?.cancel());
    if (discardQueued) {
      _inputQueue.clear();
      _activeInputFrame?.accepted = false;
      _activeInputFrame = null;
      _inputQueueBytes = 0;
    }
    _inputDecoder?.cancel();
    logger.severe('Input stream failed');
    if (!_inputSubscriptionReady) return;
    _reportInputFailure(generation);
  }

  void _reportInputFailure(int generation) {
    final controller = _inboundController;
    final subscription = _stdinSubscription;
    unawaited(
      _cancelFailedInput(
        generation: generation,
        controller: controller,
        subscription: subscription,
      ),
    );
    if (controller != null) _scheduleInputDrain(generation, controller);
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
      if (_activeGeneration == generation) {
        if (identical(_stdinSubscription, subscription)) {
          _stdinSubscription = null;
        }
        _inputSubscriptionReady = false;
        if (controller != null) _scheduleInputDrain(generation, controller);
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
      unawaited(inboundController.close().catchError((Object _) {}));
    }
    if (!outboundController.isClosed) {
      unawaited(outboundController.close().catchError((Object _) {}));
    }
    if (_activeGeneration == generation) {
      _activeGeneration = null;
      _inputSubscriptionReady = false;
      _inputDecoder = null;
      _terminalFailure = null;
      _terminalPublished = false;
      _activeInputFrame = null;
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
    final outboundSubscription = _outboundSubscription;
    final inputDecoder = _inputDecoder;
    final inboundController = _inboundController;
    final outboundController = _outboundController;
    final outputDrain = _outputDrainFuture;
    final cleanupDeadline = Future<void>.delayed(stopDrainTimeout);

    _activeGeneration = null;
    _stdinSubscription = null;
    _outboundSubscription = null;
    _inputSubscriptionReady = false;
    _inputDecoder = null;
    _terminalFailure = null;
    _terminalPublished = false;
    _inboundController = null;
    _outboundController = null;
    _channel = null;
    _inputQueue.clear();
    _activeInputFrame?.accepted = false;
    _activeInputFrame = null;
    _outputQueue.clear();
    _inputQueueBytes = 0;
    _outputQueueBytes = 0;
    _inputDone = false;
    _inputCancelled = true;
    _outputFailed = true;

    inputDecoder?.cancel();
    final cleanupFutures = <Future<void>>[];
    if (subscription != null) {
      cleanupFutures.add(_observeCleanup(subscription.cancel));
    }
    if (outboundSubscription != null) {
      cleanupFutures.add(_observeCleanup(outboundSubscription.cancel));
    }
    if (outputDrain != null) {
      cleanupFutures.add(_observeCleanup(() => outputDrain));
    }
    if (outboundController != null && !outboundController.isClosed) {
      cleanupFutures.add(_observeCleanup(outboundController.close));
    }
    await _waitForCleanup(
      cleanupDeadline: cleanupDeadline,
      cleanupFutures: cleanupFutures,
    );
    if (identical(_outputDrainFuture, outputDrain)) {
      _outputDrainFuture = null;
    }
    if (inboundController != null && !inboundController.isClosed) {
      unawaited(_observeCleanup(inboundController.close));
    }
    logger.fine('StdinTransport stopped');
  }

  Future<void> _observeCleanup(FutureOr<void> Function() cleanup) async {
    try {
      await cleanup();
    } on Object {
      // Cleanup is best effort. Observing the future also consumes late errors.
    }
  }

  Future<void> _waitForCleanup({
    required Future<void> cleanupDeadline,
    required List<Future<void>> cleanupFutures,
  }) async {
    if (cleanupFutures.isEmpty) return;
    await Future.any<void>(<Future<void>>[
      Future.wait<void>(cleanupFutures),
      cleanupDeadline,
    ]);
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

class _InputFrame {
  _InputFrame(this.line, this.rawByteLength);

  final String line;
  final int rawByteLength;
  var observerDelivered = false;
  var accepted = true;
}

class _OutputFrame {
  const _OutputFrame(this.line, this.utf8Bytes);

  final String line;
  final int utf8Bytes;
}

int _positiveLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}

Duration _positiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
  return value;
}
