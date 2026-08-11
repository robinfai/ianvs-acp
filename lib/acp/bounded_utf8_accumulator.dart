/// Raised before a streamed text response can exceed its UTF-8 byte budget.
final class BoundedUtf8AccumulatorOverflowException implements Exception {
  const BoundedUtf8AccumulatorOverflowException(this.maxBytes);

  final int maxBytes;

  @override
  String toString() =>
      'BoundedUtf8AccumulatorOverflowException: Streamed text exceeds the '
      '$maxBytes byte limit.';
}

/// Accumulates complete string chunks without ever retaining an over-limit
/// chunk. UTF-16 surrogate pairs split across adjacent chunks are counted as
/// the single Unicode scalar they form in the combined response.
final class BoundedUtf8Accumulator {
  BoundedUtf8Accumulator({required this.maxBytes}) {
    if (maxBytes < 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
    }
  }

  final int maxBytes;
  final StringBuffer _buffer = StringBuffer();
  int _lengthBytes = 0;
  bool _endsWithHighSurrogate = false;

  int get lengthBytes => _lengthBytes;
  bool get isEmpty => _buffer.isEmpty;

  void add(String value) {
    final remaining = maxBytes - _lengthBytes;
    final joinsPreviousSurrogate =
        _endsWithHighSurrogate &&
        value.isNotEmpty &&
        _isLowSurrogate(value.codeUnitAt(0));
    final rawAddedBytes = _boundedUtf8Length(
      value,
      remaining + (joinsPreviousSurrogate ? 2 : 0),
    );
    final addedBytes = rawAddedBytes == null
        ? null
        : rawAddedBytes - (joinsPreviousSurrogate ? 2 : 0);
    if (addedBytes == null || addedBytes > remaining) {
      throw BoundedUtf8AccumulatorOverflowException(maxBytes);
    }
    _buffer.write(value);
    _lengthBytes += addedBytes;
    if (value.isNotEmpty) {
      _endsWithHighSurrogate = _isHighSurrogate(
        value.codeUnitAt(value.length - 1),
      );
    }
  }

  @override
  String toString() => _buffer.toString();
}

bool _isHighSurrogate(int value) => value >= 0xd800 && value <= 0xdbff;

bool _isLowSurrogate(int value) => value >= 0xdc00 && value <= 0xdfff;

int? _boundedUtf8Length(String value, int remaining) {
  var bytes = 0;
  for (var index = 0; index < value.length; index += 1) {
    final first = value.codeUnitAt(index);
    if (first <= 0x7f) {
      bytes += 1;
    } else if (first <= 0x7ff) {
      bytes += 2;
    } else if (first >= 0xd800 && first <= 0xdbff) {
      if (index + 1 < value.length) {
        final second = value.codeUnitAt(index + 1);
        if (second >= 0xdc00 && second <= 0xdfff) {
          bytes += 4;
          index += 1;
        } else {
          bytes += 3;
        }
      } else {
        bytes += 3;
      }
    } else {
      bytes += 3;
    }
    if (bytes > remaining) return null;
  }
  return bytes;
}
