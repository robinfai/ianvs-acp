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
  }) : assert(maxBodyBytes > 0),
       assert(maxLineBytes > 0),
       assert(maxSseEventBytes > 0);

  final int maxBodyBytes;
  final int maxLineBytes;
  final int maxSseEventBytes;
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

Future<String> readBoundedUtf8Body(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
}) async {
  final bytes = BytesBuilder();
  var observed = 0;
  await for (final chunk in stream) {
    observed += chunk.length;
    if (observed > limit) {
      throw TransportByteLimitExceeded(
        resource: resource,
        limit: limit,
        observedAtLeast: observed,
      );
    }
    bytes.add(chunk);
  }
  return utf8.decode(bytes.takeBytes());
}

Future<void> drainBoundedBytes(
  Stream<List<int>> stream, {
  required int limit,
  required String resource,
}) async {
  var observed = 0;
  await for (final chunk in stream) {
    observed += chunk.length;
    if (observed > limit) {
      throw TransportByteLimitExceeded(
        resource: resource,
        limit: limit,
        observedAtLeast: observed,
      );
    }
  }
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
    final line = utf8.decode(_lineBytes);
    _lineBytes.clear();
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
