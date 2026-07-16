import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

const int secureFsReadChunkSize = 64 * 1024;

final class SecureFsReadLimitExceeded extends FileSystemException {
  const SecureFsReadLimitExceeded() : super('Secure file read limit exceeded');
}

Future<Uint8List> readSecureTextFile({
  required String canonicalRoot,
  required String relativePath,
  required int maxReadBytes,
  required int maxReturnedBytes,
  required int? line,
  required int? limit,
}) async {
  _validateSecureReadBudgets(
    maxReadBytes: maxReadBytes,
    maxReturnedBytes: maxReturnedBytes,
  );
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError('Secure filesystem reads require macOS or Linux.');
  }
  final outcome = await Isolate.run<Map<String, Object?>>(
    () => _PosixSecureFileReader.read(
      canonicalRoot: canonicalRoot,
      relativePath: relativePath,
      maxReadBytes: maxReadBytes,
      maxReturnedBytes: maxReturnedBytes,
      line: line,
      limit: limit,
      rawBytes: false,
    ),
  );
  return _unwrapSecureReadOutcome(outcome);
}

Future<Uint8List> readSecureFileBytes({
  required String canonicalRoot,
  required String relativePath,
  required int maxReadBytes,
}) async {
  _validateSecureReadBudgets(
    maxReadBytes: maxReadBytes,
    maxReturnedBytes: maxReadBytes,
  );
  if (!Platform.isMacOS && !Platform.isLinux) {
    throw UnsupportedError('Secure filesystem reads require macOS or Linux.');
  }
  final outcome = await Isolate.run<Map<String, Object?>>(
    () => _PosixSecureFileReader.read(
      canonicalRoot: canonicalRoot,
      relativePath: relativePath,
      maxReadBytes: maxReadBytes,
      maxReturnedBytes: maxReadBytes,
      line: null,
      limit: null,
      rawBytes: true,
    ),
  );
  return _unwrapSecureReadOutcome(outcome);
}

Uint8List _unwrapSecureReadOutcome(Map<String, Object?> outcome) {
  final bytes = outcome['bytes'];
  if (bytes is Uint8List) return bytes;
  switch (outcome['failure']) {
    case 'scan_limit':
      throw const SecureFsReadLimitExceeded();
    case 'return_limit':
      throw const SecureFsReadLimitExceeded();
    case 'invalid_utf8':
      throw const FormatException('Invalid UTF-8 file content.');
    case 'not_regular':
      throw const FileSystemException('Not a regular file');
    case 'invalid_budget':
      throw ArgumentError('Secure filesystem read budgets are invalid.');
    default:
      throw const FileSystemException('Secure file open failed');
  }
}

void _validateSecureReadBudgets({
  required int maxReadBytes,
  required int maxReturnedBytes,
}) {
  if (maxReadBytes <= 0) {
    throw ArgumentError.value(maxReadBytes, 'maxReadBytes');
  }
  if (maxReturnedBytes <= 0 || maxReturnedBytes > maxReadBytes) {
    throw ArgumentError.value(maxReturnedBytes, 'maxReturnedBytes');
  }
}

final class _PosixSecureFileReader {
  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final int Function(Pointer<Char>, int) _open = _libc
      .lookupFunction<
        Int32 Function(Pointer<Char>, Int32),
        int Function(Pointer<Char>, int)
      >('open');
  static final int Function(int, Pointer<Char>, int) _openAt = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Char>, Int32),
        int Function(int, Pointer<Char>, int)
      >('openat');
  static final int Function(int, Pointer<Void>, int) _read = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Void>, IntPtr),
        int Function(int, Pointer<Void>, int)
      >('read');
  static final int Function(int, Pointer<Void>) _fstat = _libc
      .lookupFunction<
        Int32 Function(Int32, Pointer<Void>),
        int Function(int, Pointer<Void>)
      >(_fstatSymbol);
  static final int Function(int) _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
  static final Pointer<Void> Function(int) _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final void Function(Pointer<Void>) _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');

  static Map<String, Object?> read({
    required String canonicalRoot,
    required String relativePath,
    required int maxReadBytes,
    required int maxReturnedBytes,
    required int? line,
    required int? limit,
    required bool rawBytes,
  }) {
    if (maxReadBytes <= 0 ||
        maxReturnedBytes <= 0 ||
        maxReturnedBytes > maxReadBytes) {
      return const <String, Object?>{'failure': 'invalid_budget'};
    }
    final relativeSegments = p
        .split(relativePath)
        .where((segment) => segment.isNotEmpty && segment != '.')
        .toList(growable: false);
    if (!p.isAbsolute(canonicalRoot) ||
        relativeSegments.isEmpty ||
        relativeSegments.any(
          (segment) => segment == '..' || segment == p.rootPrefix(relativePath),
        )) {
      return const <String, Object?>{'failure': 'open'};
    }

    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final fileFlags = _readOnly | _nonBlocking | _noFollow | _closeOnExec;
    final descriptors = <int>[];
    Pointer<Void>? buffer;
    try {
      var directory = _withNativePath(
        p.rootPrefix(canonicalRoot),
        (path) => _open(path, directoryFlags),
      );
      if (directory < 0) return const <String, Object?>{'failure': 'open'};
      descriptors.add(directory);

      final rootSegments = p
          .split(canonicalRoot)
          .where(
            (segment) =>
                segment.isNotEmpty &&
                segment != '.' &&
                segment != p.rootPrefix(canonicalRoot),
          )
          .toList(growable: false);
      for (final segment in rootSegments) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return const <String, Object?>{'failure': 'open'};
        descriptors.add(next);
        directory = next;
      }
      for (final segment in relativeSegments.take(
        relativeSegments.length - 1,
      )) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return const <String, Object?>{'failure': 'open'};
        descriptors.add(next);
        directory = next;
      }
      final fileDescriptor = _withNativePath(
        relativeSegments.last,
        (path) => _openAt(directory, path, fileFlags),
      );
      if (fileDescriptor < 0) {
        return const <String, Object?>{'failure': 'open'};
      }
      descriptors.add(fileDescriptor);
      if (!_isRegularFile(fileDescriptor)) {
        return const <String, Object?>{'failure': 'not_regular'};
      }
      if (limit != null && limit <= 0) {
        return <String, Object?>{'bytes': Uint8List(0)};
      }

      final bufferLength = maxReadBytes < secureFsReadChunkSize
          ? maxReadBytes + 1
          : secureFsReadChunkSize;
      buffer = _malloc(bufferLength);
      if (buffer.address == 0) {
        return const <String, Object?>{'failure': 'read'};
      }
      final nativeBytes = buffer.cast<Uint8>().asTypedList(bufferLength);
      final returned = BytesBuilder(copy: false);
      final validator = _Utf8Validator();
      final startLine = line == null || line < 1 ? 1 : line;
      final endLineExclusive = limit == null ? null : startLine + limit;
      var currentLine = 1;
      var inspectedBytes = 0;
      var complete = false;
      while (!complete) {
        final remaining = maxReadBytes - inspectedBytes;
        var requested = remaining + 1;
        if (requested > bufferLength) requested = bufferLength;
        if (requested < 1 || requested > nativeBytes.length) {
          return const <String, Object?>{'failure': 'invalid_budget'};
        }
        final count = _read(fileDescriptor, buffer, requested);
        if (count < 0) {
          if (_errno == 4) continue;
          return const <String, Object?>{'failure': 'read'};
        }
        if (count == 0) break;
        if (rawBytes) {
          inspectedBytes += count;
          if (inspectedBytes > maxReadBytes) {
            return const <String, Object?>{'failure': 'scan_limit'};
          }
          returned.add(nativeBytes.sublist(0, count));
          continue;
        }
        for (var index = 0; index < count; index += 1) {
          final byte = nativeBytes[index];
          inspectedBytes += 1;
          if (inspectedBytes > maxReadBytes) {
            return const <String, Object?>{'failure': 'scan_limit'};
          }
          if (!validator.add(byte)) {
            return const <String, Object?>{'failure': 'invalid_utf8'};
          }
          final selected =
              currentLine >= startLine &&
              (endLineExclusive == null || currentLine < endLineExclusive);
          if (byte == 0x0a) {
            final nextLine = currentLine + 1;
            if (selected &&
                (endLineExclusive == null || nextLine < endLineExclusive)) {
              if (returned.length >= maxReturnedBytes) {
                return const <String, Object?>{'failure': 'return_limit'};
              }
              returned.addByte(byte);
            }
            currentLine = nextLine;
            if (endLineExclusive != null && nextLine >= endLineExclusive) {
              complete = true;
              break;
            }
          } else if (selected) {
            if (returned.length >= maxReturnedBytes) {
              return const <String, Object?>{'failure': 'return_limit'};
            }
            returned.addByte(byte);
          }
        }
      }
      if (!rawBytes && !validator.complete) {
        return const <String, Object?>{'failure': 'invalid_utf8'};
      }
      return <String, Object?>{'bytes': returned.takeBytes()};
    } on Object {
      return const <String, Object?>{'failure': 'read'};
    } finally {
      if (buffer != null && buffer.address != 0) _free(buffer);
      for (final descriptor in descriptors.reversed) {
        _close(descriptor);
      }
    }
  }

  static bool _isRegularFile(int fileDescriptor) {
    final statBuffer = _malloc(512);
    if (statBuffer.address == 0) return false;
    try {
      if (_fstat(fileDescriptor, statBuffer) != 0) return false;
      final mode = switch (Abi.current()) {
        Abi.macosArm64 ||
        Abi.macosX64 => (statBuffer.cast<Uint8>() + 4).cast<Uint16>().value,
        Abi.linuxArm64 => (statBuffer.cast<Uint8>() + 16).cast<Uint32>().value,
        Abi.linuxX64 => (statBuffer.cast<Uint8>() + 24).cast<Uint32>().value,
        _ => 0,
      };
      return mode & 0xf000 == 0x8000;
    } finally {
      _free(statBuffer);
    }
  }

  static T _withNativePath<T>(
    String value,
    T Function(Pointer<Char> path) action,
  ) {
    if (value.contains('\u0000')) {
      throw ArgumentError.value(value, 'value', 'Must not contain NUL.');
    }
    final encoded = utf8.encode(value);
    final allocation = _malloc(encoded.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate native path.');
    }
    try {
      final bytes = allocation.cast<Uint8>().asTypedList(encoded.length + 1);
      bytes.setRange(0, encoded.length, encoded);
      bytes[encoded.length] = 0;
      return action(allocation.cast<Char>());
    } finally {
      _free(allocation);
    }
  }

  static int get _readOnly => 0;
  static int get _directory => Platform.isMacOS ? 0x00100000 : 0x00010000;
  static int get _noFollow => Platform.isMacOS ? 0x00000100 : 0x00020000;
  static int get _closeOnExec => Platform.isMacOS ? 0x01000000 : 0x00080000;
  static int get _nonBlocking => Platform.isMacOS ? 0x00000004 : 0x00000800;

  static int get _errno {
    final symbol = Platform.isMacOS ? '__error' : '__errno_location';
    final accessor = _libc
        .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
          symbol,
        );
    return accessor().value;
  }

  static String get _fstatSymbol =>
      Abi.current() == Abi.macosX64 ? r'fstat$INODE64' : 'fstat';
}

final class _Utf8Validator {
  var _remaining = 0;
  var _nextMin = 0x80;
  var _nextMax = 0xbf;

  bool add(int byte) {
    if (_remaining > 0) {
      if (byte < _nextMin || byte > _nextMax) return false;
      _remaining -= 1;
      _nextMin = 0x80;
      _nextMax = 0xbf;
      return true;
    }
    if (byte <= 0x7f) return true;
    if (byte >= 0xc2 && byte <= 0xdf) {
      _remaining = 1;
      return true;
    }
    if ((byte >= 0xe1 && byte <= 0xec) || (byte >= 0xee && byte <= 0xef)) {
      _remaining = 2;
      return true;
    }
    if (byte == 0xe0) {
      _remaining = 2;
      _nextMin = 0xa0;
      return true;
    }
    if (byte == 0xed) {
      _remaining = 2;
      _nextMax = 0x9f;
      return true;
    }
    if (byte >= 0xf1 && byte <= 0xf3) {
      _remaining = 3;
      return true;
    }
    if (byte == 0xf0) {
      _remaining = 3;
      _nextMin = 0x90;
      return true;
    }
    if (byte == 0xf4) {
      _remaining = 3;
      _nextMax = 0x8f;
      return true;
    }
    return false;
  }

  bool get complete => _remaining == 0;
}
