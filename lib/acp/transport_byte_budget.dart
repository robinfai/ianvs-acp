// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Default limit for each bounded HTTP transport resource.
const int defaultTransportByteLimit = 16 * 1024 * 1024;

/// Injectable byte limits for HTTP bodies and Server-Sent Events.
class TransportByteBudget {
  const TransportByteBudget({
    this.maxBodyBytes = defaultTransportByteLimit,
    this.maxLineBytes = defaultTransportByteLimit,
    this.maxSseEventBytes = defaultTransportByteLimit,
  });

  final int maxBodyBytes;
  final int maxLineBytes;
  final int maxSseEventBytes;

  /// Reject invalid dynamic budgets in debug and release builds.
  void validate() {
    _requirePositiveTransportByteLimit(maxBodyBytes, 'maxBodyBytes');
    _requirePositiveTransportByteLimit(maxLineBytes, 'maxLineBytes');
    _requirePositiveTransportByteLimit(maxSseEventBytes, 'maxSseEventBytes');
  }
}

/// Payload-free error raised when a transport byte limit is exceeded.
class TransportByteLimitExceeded extends Error {
  TransportByteLimitExceeded({
    required this.resource,
    required this.limit,
    required this.observedAtLeast,
  });

  final String resource;
  final int limit;
  final int observedAtLeast;

  @override
  String toString() {
    return 'TransportByteLimitExceeded('
        'resource: $resource, limit: $limit, '
        'observedAtLeast: $observedAtLeast)';
  }
}

/// Payload-free error raised when a remote transport payload is not valid JSON.
class TransportProtocolDecodeError extends Error {
  TransportProtocolDecodeError({required this.resource});

  final String resource;

  @override
  String toString() {
    return 'TransportProtocolDecodeError(resource: $resource)';
  }
}

/// Payload-free error raised when a transport write fails.
class TransportWriteError extends Error {
  TransportWriteError({required this.resource});

  final String resource;

  @override
  String toString() => 'TransportWriteError(resource: $resource)';
}

/// Payload-free error raised when a one-shot transport body stops making
/// progress before it completes.
class TransportBodyReadTimeout extends Error {
  TransportBodyReadTimeout({required this.resource, required this.timeout});

  final String resource;
  final Duration timeout;

  @override
  String toString() {
    return 'TransportBodyReadTimeout('
        'resource: $resource, timeoutMs: ${timeout.inMilliseconds})';
  }
}

/// Decode remote JSON without retaining its source or original parse error.
Object? decodeTransportJson(String source, {required String resource}) {
  try {
    return jsonDecode(source);
  } on Object {
    throw TransportProtocolDecodeError(resource: resource);
  }
}

void enforceTransportContentLength({
  required int contentLength,
  required int limit,
  required String resource,
}) {
  if (contentLength < 0 || contentLength <= limit) return;
  throw TransportByteLimitExceeded(
    resource: resource,
    limit: limit,
    observedAtLeast: contentLength,
  );
}

abstract interface class TransportBodyReadOperation<T> {
  Future<T> get future;

  Future<void> cancel();
}

TransportBodyReadOperation<String> startBoundedUtf8BodyRead(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
  Duration? timeout,
}) {
  return _TransportBodyReadOperation<String>(
    stream: stream,
    limit: limit,
    resource: resource,
    timeout: timeout,
    collectBytes: true,
    completeValue: (bytes) {
      try {
        return utf8.decode(bytes.takeBytes());
      } on FormatException {
        throw TransportProtocolDecodeError(resource: resource);
      }
    },
  );
}

TransportBodyReadOperation<void> startBoundedByteDrain(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
  Duration? timeout,
}) {
  return _TransportBodyReadOperation<void>(
    stream: stream,
    limit: limit,
    resource: resource,
    timeout: timeout,
    collectBytes: false,
    completeValue: (_) {},
  );
}

Future<String> readBoundedUtf8Body(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
  Duration? timeout,
}) {
  return startBoundedUtf8BodyRead(
    stream,
    limit: limit,
    resource: resource,
    timeout: timeout,
  ).future;
}

Future<void> drainBoundedBytes(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
  Duration? timeout,
}) {
  return startBoundedByteDrain(
    stream,
    limit: limit,
    resource: resource,
    timeout: timeout,
  ).future;
}

class _TransportBodyReadOperation<T> implements TransportBodyReadOperation<T> {
  _TransportBodyReadOperation({
    required Stream<List<int>> stream,
    required this.limit,
    required this.resource,
    required Duration? timeout,
    required bool collectBytes,
    required T Function(BytesBuilder bytes) completeValue,
  }) : _bytes = BytesBuilder(),
       _collectBytes = collectBytes,
       _completeValue = completeValue {
    if (timeout != null) {
      _timer = Timer(
        timeout,
        () => _fail(
          TransportBodyReadTimeout(resource: resource, timeout: timeout),
          StackTrace.current,
        ),
      );
    }
    final subscription = stream.listen(
      _onData,
      onError: _onError,
      onDone: _onDone,
      cancelOnError: false,
    );
    _subscription = subscription;
    final pendingFailure = _pendingFailure;
    if (pendingFailure != null) {
      _pendingFailure = null;
      _startCancellation(subscription, pendingFailure);
    }
  }

  final int limit;
  final String resource;
  final BytesBuilder _bytes;
  final bool _collectBytes;
  final T Function(BytesBuilder bytes) _completeValue;
  final Completer<T> _completer = Completer<T>();

  StreamSubscription<List<int>>? _subscription;
  Timer? _timer;
  _TransportReadFailure? _pendingFailure;
  Future<void>? _cancellation;
  var _observed = 0;
  var _settling = false;

  @override
  Future<T> get future => _completer.future;

  void _onData(List<int> chunk) {
    if (_settling) return;
    _observed += chunk.length;
    if (_observed > limit) {
      _fail(
        TransportByteLimitExceeded(
          resource: resource,
          limit: limit,
          observedAtLeast: _observed,
        ),
        StackTrace.current,
      );
      return;
    }
    if (_collectBytes) _bytes.add(chunk);
  }

  void _onError(Object error, StackTrace stackTrace) {
    _fail(error, stackTrace);
  }

  void _onDone() {
    if (_settling) return;
    _settling = true;
    _timer?.cancel();
    try {
      _completer.complete(_completeValue(_bytes));
    } on Object catch (error, stackTrace) {
      _completer.completeError(error, stackTrace);
    }
  }

  void _fail(Object error, StackTrace stackTrace) {
    if (_settling) return;
    _settling = true;
    _timer?.cancel();
    final failure = _TransportReadFailure(error, stackTrace);
    final subscription = _subscription;
    if (subscription == null) {
      _pendingFailure = failure;
      return;
    }
    _startCancellation(subscription, failure);
  }

  void _startCancellation(
    StreamSubscription<List<int>> subscription,
    _TransportReadFailure failure,
  ) {
    _cancellation ??= () async {
      try {
        await subscription.cancel();
      } on Object {
        // Preserve the original bounded-read failure.
      }
      if (!_completer.isCompleted) {
        _completer.completeError(failure.error, failure.stackTrace);
      }
    }();
  }

  @override
  Future<void> cancel() async {
    if (!_settling) {
      _fail(
        StateError('Transport body read was cancelled.'),
        StackTrace.current,
      );
    }
    final cancellation = _cancellation;
    if (cancellation != null) await cancellation;
  }
}

class _TransportReadFailure {
  const _TransportReadFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

class TransportSseEvent {
  const TransportSseEvent({this.event, required this.data});

  final String? event;
  final String data;
}

/// Decode SSE after enforcing raw line and whole-event byte limits.
Stream<TransportSseEvent> decodeBoundedSse(
  Stream<List<int>> stream, {
  required TransportByteBudget budget,
  required String resource,
}) async* {
  budget.validate();
  final state = _SseDecodeState(budget: budget, resource: resource);
  await for (final chunk in stream) {
    for (final byte in chunk) {
      final event = state.addByte(byte);
      if (event != null) yield event;
    }
  }
  final event = state.close();
  if (event != null) yield event;
}

void _requirePositiveTransportByteLimit(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
}

class _SseDecodeState {
  _SseDecodeState({required this.budget, required this.resource});

  final TransportByteBudget budget;
  final String resource;
  final List<int> _lineBytes = <int>[];
  final List<String> _dataLines = <String>[];
  String? _eventName;
  var _eventBytes = 0;
  var _pendingCarriageReturn = false;

  TransportSseEvent? addByte(int byte) {
    if (_pendingCarriageReturn) {
      _pendingCarriageReturn = false;
      if (byte == 0x0a) {
        _countEventByte();
        return _finishLine();
      }
      final event = _finishLine();
      final currentEvent = _addCurrentByte(byte);
      return event ?? currentEvent;
    }
    return _addCurrentByte(byte);
  }

  TransportSseEvent? _addCurrentByte(int byte) {
    _countEventByte();
    if (byte == 0x0d) {
      _pendingCarriageReturn = true;
      return null;
    }
    if (byte == 0x0a) return _finishLine();
    _lineBytes.add(byte);
    _check('$resource line', budget.maxLineBytes, _lineBytes.length);
    return null;
  }

  void _countEventByte() {
    _eventBytes += 1;
    _check('$resource event', budget.maxSseEventBytes, _eventBytes);
  }

  TransportSseEvent? close() {
    TransportSseEvent? event;
    if (_pendingCarriageReturn) {
      _pendingCarriageReturn = false;
      event = _finishLine();
    } else if (_lineBytes.isNotEmpty) {
      event = _finishLine();
    }
    return event ?? _finishEvent();
  }

  TransportSseEvent? _finishLine() {
    final String line;
    try {
      line = utf8.decode(_lineBytes);
    } on FormatException {
      throw TransportProtocolDecodeError(resource: resource);
    } finally {
      _lineBytes.clear();
    }
    if (line.isEmpty) return _finishEvent();
    if (line.startsWith(':')) return null;
    final separator = line.indexOf(':');
    final field = separator < 0 ? line : line.substring(0, separator);
    var value = separator < 0 ? '' : line.substring(separator + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') {
      _eventName = value;
    } else if (field == 'data') {
      _dataLines.add(value);
    }
    return null;
  }

  TransportSseEvent? _finishEvent() {
    final event = _dataLines.isEmpty
        ? null
        : TransportSseEvent(event: _eventName, data: _dataLines.join('\n'));
    _eventName = null;
    _dataLines.clear();
    _eventBytes = 0;
    return event;
  }

  void _check(String target, int limit, int observed) {
    if (observed <= limit) return;
    throw TransportByteLimitExceeded(
      resource: target,
      limit: limit,
      observedAtLeast: observed,
    );
  }
}
