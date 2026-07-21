import 'dart:collection';

import '../acp/acp_input_budget.dart';

final class BoundedMetadataPreview {
  const BoundedMetadataPreview({required this.text, this.omission});

  final String text;
  final AcpInputOmission? omission;
}

BoundedMetadataPreview writeBoundedMetadataPreview(
  Object? value, {
  required AcpInputBudget budget,
}) {
  budget.validate();
  final sink = _BoundedPreviewSink(budget);
  final activeContainers = HashSet<Object>.identity();
  final stack = <_WriteFrame>[_ValueFrame(value)];

  try {
    while (stack.isNotEmpty && sink.omission == null) {
      final frame = stack.removeLast();
      switch (frame) {
        case _LiteralFrame(:final text):
          sink.writeAscii(text);
        case _StringFrame(:final value):
          _writeJsonString(value, sink);
        case _ListFrame(:final value, :final index):
          if (index >= value.length) {
            sink.writeAscii(']');
            activeContainers.remove(value);
          } else {
            if (index != 0) sink.writeAscii(',');
            stack.add(_ListFrame(value, index + 1));
            stack.add(_ValueFrame(value[index]));
          }
        case _MapFrame(:final value, :final iterator, :final first):
          if (!iterator.moveNext()) {
            sink.writeAscii('}');
            activeContainers.remove(value);
          } else {
            final entry = iterator.current;
            final key = entry.key;
            if (key is! String) throw const _InvalidMetadataPreview();
            if (!first) sink.writeAscii(',');
            stack.add(_MapFrame(value, iterator, false));
            stack.add(_ValueFrame(entry.value));
            stack.add(const _LiteralFrame(':'));
            stack.add(_StringFrame(key));
          }
        case _ValueFrame(:final value):
          if (value == null) {
            sink.writeAscii('null');
          } else if (value is String) {
            _writeJsonString(value, sink);
          } else if (value is bool) {
            sink.writeAscii(value ? 'true' : 'false');
          } else if (value is int) {
            sink.writeAscii(value.toString());
          } else if (value is double) {
            if (!value.isFinite) throw const _InvalidMetadataPreview();
            sink.writeAscii(value.toString());
          } else if (value is num) {
            if (!value.isFinite) throw const _InvalidMetadataPreview();
            sink.writeAscii(value.toString());
          } else if (value is List) {
            if (!activeContainers.add(value)) {
              throw const _InvalidMetadataPreview();
            }
            sink.writeAscii('[');
            stack.add(_ListFrame(value, 0));
          } else if (value is Map) {
            if (!activeContainers.add(value)) {
              throw const _InvalidMetadataPreview();
            }
            sink.writeAscii('{');
            stack.add(_MapFrame(value, value.entries.iterator, true));
          } else {
            throw const _InvalidMetadataPreview();
          }
      }
    }
  } on Object {
    return BoundedMetadataPreview(
      text: '',
      omission: AcpInputOmission(
        reason: AcpInputOmissionReason.invalidStructure,
        resource: 'metadata preview',
        truncated: false,
      ),
    );
  }

  return BoundedMetadataPreview(text: sink.text, omission: sink.omission);
}

sealed class _WriteFrame {
  const _WriteFrame();
}

final class _ValueFrame extends _WriteFrame {
  const _ValueFrame(this.value);
  final Object? value;
}

final class _StringFrame extends _WriteFrame {
  const _StringFrame(this.value);
  final String value;
}

final class _LiteralFrame extends _WriteFrame {
  const _LiteralFrame(this.text);
  final String text;
}

final class _ListFrame extends _WriteFrame {
  const _ListFrame(this.value, this.index);
  final List<Object?> value;
  final int index;
}

final class _MapFrame extends _WriteFrame {
  const _MapFrame(this.value, this.iterator, this.first);
  final Map<Object?, Object?> value;
  final Iterator<MapEntry<Object?, Object?>> iterator;
  final bool first;
}

final class _InvalidMetadataPreview implements Exception {
  const _InvalidMetadataPreview();
}

final class _BoundedPreviewSink {
  _BoundedPreviewSink(this.budget);

  final AcpInputBudget budget;
  final StringBuffer _buffer = StringBuffer();
  var _chars = 0;
  var _bytes = 0;
  AcpInputOmission? omission;

  String get text => _buffer.toString();

  void writeAscii(String value) {
    for (var index = 0; index < value.length; index += 1) {
      if (!_write(value.substring(index, index + 1), 1, 1)) return;
    }
  }

  void writeScalar(String value, int utf8Bytes) {
    _write(value, 1, utf8Bytes);
  }

  bool _write(String value, int chars, int bytes) {
    if (omission != null) return false;
    if (chars > budget.maxMetadataPreviewChars - _chars) {
      omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'metadata preview chars',
        truncated: true,
        limit: budget.maxMetadataPreviewChars,
        observedAtLeast: _chars + chars,
      );
      return false;
    }
    if (bytes > budget.maxMetadataPreviewBytes - _bytes) {
      omission = AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: 'metadata preview bytes',
        truncated: true,
        limit: budget.maxMetadataPreviewBytes,
        observedAtLeast: _bytes + bytes,
      );
      return false;
    }
    _buffer.write(value);
    _chars += chars;
    _bytes += bytes;
    return true;
  }
}

void _writeJsonString(String value, _BoundedPreviewSink sink) {
  sink.writeAscii('"');
  var index = 0;
  while (index < value.length && sink.omission == null) {
    final first = value.codeUnitAt(index);
    switch (first) {
      case 0x22:
        sink.writeAscii(r'\"');
      case 0x5c:
        sink.writeAscii(r'\\');
      case 0x08:
        sink.writeAscii(r'\b');
      case 0x0c:
        sink.writeAscii(r'\f');
      case 0x0a:
        sink.writeAscii(r'\n');
      case 0x0d:
        sink.writeAscii(r'\r');
      case 0x09:
        sink.writeAscii(r'\t');
      default:
        if (first < 0x20) {
          sink.writeAscii('\\u${first.toRadixString(16).padLeft(4, '0')}');
        } else if (_isHighSurrogate(first) &&
            index + 1 < value.length &&
            _isLowSurrogate(value.codeUnitAt(index + 1))) {
          sink.writeScalar(value.substring(index, index + 2), 4);
          index += 1;
        } else if (_isHighSurrogate(first) || _isLowSurrogate(first)) {
          throw const _InvalidMetadataPreview();
        } else {
          sink.writeScalar(
            value.substring(index, index + 1),
            first <= 0x7f
                ? 1
                : first <= 0x7ff
                ? 2
                : 3,
          );
        }
    }
    index += 1;
  }
  sink.writeAscii('"');
}

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;
