import 'dart:convert';
import 'dart:typed_data';

import 'byte_budget.dart';

const _rawTransportLineSegmentBytes = 64 * 1024;

/// One bounded raw transport line backed by fixed-size byte segments.
///
/// The segment backing is intentionally private so completed lines are
/// immutable to consumers. UTF-8 is decoded incrementally across segments
/// without first joining the complete line into another byte list.
class RawTransportLine {
  RawTransportLine._(
    List<Uint8List> segments,
    this.byteLength,
    this._hasInvalidByte,
  ) : _segments = List<Uint8List>.unmodifiable(segments);

  final List<Uint8List> _segments;
  final bool _hasInvalidByte;

  /// Total raw bytes in this line.
  final int byteLength;

  /// Number of fixed-size backing segments retained by this line.
  int get segmentCount => _segments.length;

  /// Used byte count for each segment, exposed without mutable byte backing.
  List<int> get segmentLengths {
    var remaining = byteLength;
    return List<int>.unmodifiable(
      _segments.map((_) {
        final length = remaining < _rawTransportLineSegmentBytes
            ? remaining
            : _rawTransportLineSegmentBytes;
        remaining -= length;
        return length;
      }),
    );
  }

  /// Strictly decodes this line as UTF-8, streaming each retained segment.
  String decodeUtf8() {
    if (_hasInvalidByte) {
      throw const FormatException('Invalid UTF-8 input');
    }
    final output = StringBuffer();
    final input = utf8.decoder.startChunkedConversion(
      StringConversionSink.fromStringSink(output),
    );
    var remaining = byteLength;
    for (final segment in _segments) {
      final length = remaining < segment.length ? remaining : segment.length;
      input.add(Uint8List.sublistView(segment, 0, length));
      remaining -= length;
    }
    input.close();
    return output.toString();
  }
}

/// Incrementally splits raw byte chunks into bounded CR, LF, or CRLF lines.
///
/// This type is public only so transport implementation libraries can share a
/// single decoder. It is not exported from the package API.
class RawTransportLineDecoder {
  RawTransportLineDecoder({
    required int limit,
    required this.resource,
    required this.onLine,
    required this.onOverflow,
    this.discardOversizedLines = false,
  }) : limit = _positiveLimit(limit);

  final int limit;
  final String resource;
  final void Function(RawTransportLine line) onLine;
  final void Function(TransportByteLimitExceeded error) onOverflow;
  final bool discardOversizedLines;
  List<Uint8List> _segments = <Uint8List>[];
  Uint8List? _currentSegment;
  var _currentSegmentLength = 0;
  var _byteLength = 0;
  var _hasInvalidByte = false;
  var _pendingCarriageReturn = false;
  var _discarding = false;
  var _notifyingOverflow = false;
  var _closed = false;

  void add(List<int> chunk) {
    if (_closed || _notifyingOverflow) return;
    for (final byte in chunk) {
      _addByte(byte);
      if (_closed) return;
    }
  }

  void _addByte(int byte) {
    if (_pendingCarriageReturn) {
      _pendingCarriageReturn = false;
      _finishLine();
      if (_closed) return;
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
    if (_byteLength < limit) {
      _appendByte(byte);
      return;
    }
    final error = TransportByteLimitExceeded(
      resource: resource,
      limit: limit,
      observedAtLeast: limit + 1,
    );
    _clearLine();
    if (discardOversizedLines) {
      _discarding = true;
    } else {
      _closed = true;
    }
    _notifyingOverflow = true;
    try {
      onOverflow(error);
    } finally {
      _notifyingOverflow = false;
    }
  }

  void _finishLine() {
    if (_discarding) {
      _discarding = false;
      _clearLine();
      return;
    }
    final line = RawTransportLine._(_segments, _byteLength, _hasInvalidByte);
    _segments = <Uint8List>[];
    _currentSegment = null;
    _currentSegmentLength = 0;
    _byteLength = 0;
    _hasInvalidByte = false;
    onLine(line);
  }

  void _appendByte(int byte) {
    if (byte < 0 || byte > 0xff) {
      _hasInvalidByte = true;
      byte = 0;
    }
    var segment = _currentSegment;
    if (segment == null ||
        _currentSegmentLength == _rawTransportLineSegmentBytes) {
      segment = Uint8List(_rawTransportLineSegmentBytes);
      _segments.add(segment);
      _currentSegment = segment;
      _currentSegmentLength = 0;
    }
    segment[_currentSegmentLength] = byte;
    _currentSegmentLength += 1;
    _byteLength += 1;
  }

  void _clearLine() {
    _segments = <Uint8List>[];
    _currentSegment = null;
    _currentSegmentLength = 0;
    _byteLength = 0;
    _hasInvalidByte = false;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_discarding) return;
    if (_pendingCarriageReturn || _byteLength > 0) _finishLine();
  }

  void cancel() {
    _closed = true;
    _pendingCarriageReturn = false;
    _discarding = false;
    _clearLine();
  }
}

int _positiveLimit(int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, 'limit', 'must be greater than zero');
  }
  return value;
}
