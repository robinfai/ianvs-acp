import 'byte_budget.dart';

/// Incrementally splits raw byte chunks into bounded CR, LF, or CRLF lines.
///
/// This type is public only so transport implementation libraries can share a
/// single decoder. It is not exported from the package API.
class RawTransportLineDecoder {
  RawTransportLineDecoder({
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

  void cancel() {
    _closed = true;
    _pendingCarriageReturn = false;
    _discarding = false;
    _bytes.clear();
  }
}
