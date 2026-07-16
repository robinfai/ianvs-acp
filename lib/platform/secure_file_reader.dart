import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class SecureFileReadResult {
  const SecureFileReadResult({
    required this.sizeBytes,
    required this.previewBytes,
    required this.sha256,
  });

  final int sizeBytes;
  final List<int> previewBytes;
  final String sha256;
}

/// Opens every path component relative to an already resolved workspace root.
///
/// POSIX `openat` plus `O_NOFOLLOW` binds validation and reading to directory
/// and file descriptors, so a concurrent symlink replacement cannot redirect
/// the read outside the workspace.
Future<SecureFileReadResult?> readWorkspaceFileSecurely({
  required String resolvedWorkspacePath,
  required String relativePath,
  required int previewLimit,
}) {
  if ((!Platform.isMacOS && !Platform.isLinux) || previewLimit < 0) {
    return Future<SecureFileReadResult?>.value();
  }
  return Isolate.run(
    () => _PosixSecureFileReader.read(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      previewLimit: previewLimit,
    ),
  );
}

class _PosixSecureFileReader {
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
      >('fstat');
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

  static const int _chunkSize = 64 * 1024;

  static SecureFileReadResult? read({
    required String resolvedWorkspacePath,
    required String relativePath,
    required int previewLimit,
  }) {
    final segments = relativePath.split(Platform.pathSeparator);
    if (relativePath.isEmpty ||
        File(relativePath).isAbsolute ||
        segments.isEmpty ||
        segments.any(
          (segment) => segment.isEmpty || segment == '.' || segment == '..',
        )) {
      return null;
    }

    final directoryFlags = _readOnly | _directory | _noFollow | _closeOnExec;
    final fileFlags = _readOnly | _nonBlocking | _noFollow | _closeOnExec;
    final descriptors = <int>[];
    Pointer<Void>? buffer;
    try {
      var directory = _withNativePath(
        resolvedWorkspacePath,
        (path) => _open(path, directoryFlags),
      );
      if (directory < 0) return null;
      descriptors.add(directory);

      for (final segment in segments.take(segments.length - 1)) {
        final next = _withNativePath(
          segment,
          (path) => _openAt(directory, path, directoryFlags),
        );
        if (next < 0) return null;
        descriptors.add(next);
        directory = next;
      }

      final fileDescriptor = _withNativePath(
        segments.last,
        (path) => _openAt(directory, path, fileFlags),
      );
      if (fileDescriptor < 0) return null;
      descriptors.add(fileDescriptor);
      if (!_isRegularFile(fileDescriptor)) return null;

      buffer = _malloc(_chunkSize);
      if (buffer.address == 0) return null;
      final bytes = buffer.cast<Uint8>().asTypedList(_chunkSize);
      final preview = BytesBuilder(copy: false);
      final digestSink = _DigestSink();
      final hashSink = sha256.startChunkedConversion(digestSink);
      var sizeBytes = 0;
      while (true) {
        final count = _read(fileDescriptor, buffer, _chunkSize);
        if (count < 0) return null;
        if (count == 0) break;
        final chunk = Uint8List.sublistView(bytes, 0, count);
        hashSink.add(chunk);
        sizeBytes += count;
        final remaining = previewLimit - preview.length;
        if (remaining > 0) {
          preview.add(chunk.sublist(0, count < remaining ? count : remaining));
        }
      }
      hashSink.close();
      final digest = digestSink.value;
      if (digest == null) return null;
      return SecureFileReadResult(
        sizeBytes: sizeBytes,
        previewBytes: List<int>.unmodifiable(preview.takeBytes()),
        sha256: digest.toString(),
      );
    } on Object {
      return null;
    } finally {
      if (buffer != null && buffer.address != 0) _free(buffer);
      for (final descriptor in descriptors.reversed) {
        _close(descriptor);
      }
    }
  }

  static T _withNativePath<T>(
    String value,
    T Function(Pointer<Char> path) action,
  ) {
    final encoded = utf8.encode(value);
    final allocation = _malloc(encoded.length + 1);
    if (allocation.address == 0) {
      throw StateError('Could not allocate a native path buffer.');
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
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value ??= data;
  }

  @override
  void close() {}
}
