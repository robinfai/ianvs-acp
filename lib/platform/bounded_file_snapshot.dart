import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Raised when a file snapshot contains more bytes than its caller permits.
///
/// The exception intentionally retains no file contents.
final class BoundedFileSnapshotOverflowException implements Exception {
  const BoundedFileSnapshotOverflowException({
    required this.path,
    required this.maxBytes,
  });

  final String path;
  final int maxBytes;

  @override
  String toString() =>
      'BoundedFileSnapshotOverflowException: File snapshot exceeds the '
      '$maxBytes byte limit.';
}

/// Reads at most [maxBytes] from one stream-backed file snapshot.
///
/// The stream requests exactly one extra byte so growth after an earlier
/// directory listing or stat cannot turn into an unbounded allocation.
Future<Uint8List> readBoundedFileSnapshot(File file, {required int maxBytes}) {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
  }
  return readBoundedByteStreamSnapshot(
    file.openRead(0, maxBytes + 1),
    resourcePath: file.path,
    maxBytes: maxBytes,
  );
}

/// Accumulates a bounded byte snapshot from [source].
///
/// This is public so non-file producers and regression tests can exercise the
/// exact same max+1 overflow behavior without trusting external metadata.
Future<Uint8List> readBoundedByteStreamSnapshot(
  Stream<List<int>> source, {
  required String resourcePath,
  required int maxBytes,
}) async {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
  }
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in source) {
    if (chunk.isEmpty) continue;
    final remaining = maxBytes + 1 - bytes.length;
    if (remaining > 0) {
      bytes.add(
        chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
      );
    }
    if (bytes.length > maxBytes || chunk.length > remaining) {
      throw BoundedFileSnapshotOverflowException(
        path: resourcePath,
        maxBytes: maxBytes,
      );
    }
  }
  return bytes.takeBytes();
}

Future<String> readBoundedFileStringSnapshot(
  File file, {
  required int maxBytes,
  Encoding encoding = utf8,
}) async {
  final bytes = await readBoundedFileSnapshot(file, maxBytes: maxBytes);
  return encoding.decode(bytes);
}
