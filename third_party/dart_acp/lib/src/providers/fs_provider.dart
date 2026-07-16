import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../security/workspace_jail.dart';
import '../transport/byte_budget.dart';
import 'secure_fs_reader.dart';
import 'secure_fs_writer.dart';

/// Default maximum bytes retained in one filesystem read response.
const int defaultFsReturnedByteLimit = 2 * 1024 * 1024;

/// Default maximum simultaneous reads across one provider family.
const int defaultFsConcurrentReadLimit = 2;

/// Default aggregate read reservation across one provider family.
const int defaultFsAggregateReadByteLimit = 16 * 1024 * 1024;

/// Default maximum bytes accepted by one filesystem write.
const int defaultFsWriteByteLimit = 8 * 1024 * 1024;

/// Default maximum simultaneous writes across one provider family.
const int defaultFsConcurrentWriteLimit = 2;

/// Default aggregate write reservation across one provider family.
const int defaultFsAggregateWriteByteLimit = 32 * 1024 * 1024;

/// Abstraction for file system operations exposed to agents.
abstract class FsProvider {
  /// Read a text file; `line` and `limit` constrain the range.
  Future<String> readTextFile(String path, {int? line, int? limit});

  /// Write text content to a file (within workspace jail).
  Future<void> writeTextFile(String path, String content);
}

enum FsReadRejectionReason { limit, capacity }

final class FsReadRejectedException extends FileSystemException {
  const FsReadRejectedException(this.reason)
    : super('Filesystem read rejected');

  final FsReadRejectionReason reason;
}

enum FsWriteRejectionReason { limit, capacity }

final class FsWriteRejectedException extends FileSystemException {
  const FsWriteRejectedException(this.reason)
    : super('Filesystem write rejected');

  final FsWriteRejectionReason reason;
}

/// Optional interface for providers that need a session workspace binding.
///
/// Providers that do not implement this interface are passed through unchanged.
abstract interface class SessionScopedFsProvider implements FsProvider {
  /// Return a provider bound to one ACP session's workspace roots.
  FsProvider bindToSession({
    required String workspaceRoot,
    List<String> additionalWorkspaceRoots = const <String>[],
    required bool allowReadOutsideWorkspace,
  });
}

/// Default implementation enforcing a workspace jail.
class DefaultFsProvider implements SessionScopedFsProvider {
  /// Create a default file system provider with a workspace jail.
  DefaultFsProvider({
    required String workspaceRoot,
    List<String> additionalWorkspaceRoots = const <String>[],
    bool allowReadOutsideWorkspace = false,
    int maxReadBytes = defaultTransportByteLimit,
    int? maxReturnedBytes,
    int maxConcurrentReads = defaultFsConcurrentReadLimit,
    int maxAggregateReadBytes = defaultFsAggregateReadByteLimit,
    int maxWriteBytes = defaultFsWriteByteLimit,
    int maxConcurrentWrites = defaultFsConcurrentWriteLimit,
    int maxAggregateWriteBytes = defaultFsAggregateWriteByteLimit,
  }) : this._(
         workspaceRoot: workspaceRoot,
         additionalWorkspaceRoots: additionalWorkspaceRoots,
         allowReadOutsideWorkspace: allowReadOutsideWorkspace,
         maxReadBytes: maxReadBytes,
         maxReturnedBytes:
             maxReturnedBytes ??
             (maxReadBytes < defaultFsReturnedByteLimit
                 ? maxReadBytes
                 : defaultFsReturnedByteLimit),
         maxConcurrentReads: maxConcurrentReads,
         maxAggregateReadBytes: maxAggregateReadBytes,
         maxWriteBytes: maxWriteBytes,
         maxConcurrentWrites: maxConcurrentWrites,
         maxAggregateWriteBytes: maxAggregateWriteBytes,
         readLedger: null,
         writeLedger: null,
       );

  DefaultFsProvider._({
    required this.workspaceRoot,
    required this.additionalWorkspaceRoots,
    required this.allowReadOutsideWorkspace,
    required this.maxReadBytes,
    required this.maxReturnedBytes,
    required this.maxConcurrentReads,
    required this.maxAggregateReadBytes,
    required this.maxWriteBytes,
    required this.maxConcurrentWrites,
    required this.maxAggregateWriteBytes,
    required _FsReadLedger? readLedger,
    required _FsWriteLedger? writeLedger,
  }) : _readLedger =
           readLedger ??
           _FsReadLedger(
             maxConcurrentReads: maxConcurrentReads,
             maxAggregateReadBytes: maxAggregateReadBytes,
           ),
       _writeLedger =
           writeLedger ??
           _FsWriteLedger(
             maxConcurrentWrites: maxConcurrentWrites,
             maxAggregateWriteBytes: maxAggregateWriteBytes,
           ),
       _jail = WorkspaceJail(
         workspaceRoot: workspaceRoot,
         additionalWorkspaceRoots: additionalWorkspaceRoots,
       ) {
    _validateBudgets(
      maxReadBytes: maxReadBytes,
      maxReturnedBytes: maxReturnedBytes,
      maxConcurrentReads: maxConcurrentReads,
      maxAggregateReadBytes: maxAggregateReadBytes,
      maxWriteBytes: maxWriteBytes,
      maxConcurrentWrites: maxConcurrentWrites,
      maxAggregateWriteBytes: maxAggregateWriteBytes,
    );
  }

  /// Workspace root directory.
  final String workspaceRoot;
  final List<String> additionalWorkspaceRoots;
  final WorkspaceJail _jail;

  /// When true, allow reads outside the workspace root (writes still denied).
  final bool allowReadOutsideWorkspace;

  /// Maximum file bytes inspected by one read request.
  final int maxReadBytes;

  /// Maximum selected UTF-8 bytes returned by one read request.
  final int maxReturnedBytes;

  /// Maximum simultaneous reads shared by this marker and its bindings.
  final int maxConcurrentReads;

  /// Maximum aggregate read reservation shared by all bindings.
  final int maxAggregateReadBytes;

  final _FsReadLedger _readLedger;

  /// Maximum UTF-8 bytes accepted by one write.
  final int maxWriteBytes;

  /// Maximum simultaneous writes shared by this marker and its bindings.
  final int maxConcurrentWrites;

  /// Maximum aggregate write reservation shared by all bindings.
  final int maxAggregateWriteBytes;

  final _FsWriteLedger _writeLedger;

  // Writes outside the workspace are never allowed.

  @override
  FsProvider bindToSession({
    required String workspaceRoot,
    List<String> additionalWorkspaceRoots = const <String>[],
    required bool allowReadOutsideWorkspace,
  }) => DefaultFsProvider._(
    workspaceRoot: workspaceRoot,
    additionalWorkspaceRoots: additionalWorkspaceRoots,
    allowReadOutsideWorkspace: allowReadOutsideWorkspace,
    maxReadBytes: maxReadBytes,
    maxReturnedBytes: maxReturnedBytes,
    maxConcurrentReads: maxConcurrentReads,
    maxAggregateReadBytes: maxAggregateReadBytes,
    maxWriteBytes: maxWriteBytes,
    maxConcurrentWrites: maxConcurrentWrites,
    maxAggregateWriteBytes: maxAggregateWriteBytes,
    readLedger: _readLedger,
    writeLedger: _writeLedger,
  );

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) {
    final lease = _readLedger.tryAcquire(_readReservationBytes);
    if (lease == null) {
      return Future<String>.error(
        const FsReadRejectedException(FsReadRejectionReason.capacity),
      );
    }
    try {
      return _readTextFile(
        path,
        line: line,
        limit: limit,
      ).whenComplete(lease.release);
    } on Object catch (error, stackTrace) {
      lease.release();
      return Future<String>.error(error, stackTrace);
    }
  }

  Future<String> _readTextFile(String path, {int? line, int? limit}) async {
    final canonicalPath = allowReadOutsideWorkspace
        ? await _jail.resolveForgiving(path)
        : await _jail.resolveAndEnsureWithin(path);
    final canonicalRoot = await _canonicalReadRoot(canonicalPath);
    final relativePath = p.relative(canonicalPath, from: canonicalRoot);
    if (p.isAbsolute(relativePath) ||
        relativePath == '.' ||
        relativePath.split(p.separator).contains('..')) {
      throw const FileSystemException('Secure file path is invalid');
    }
    late final List<int> bytes;
    try {
      bytes = await readSecureTextFile(
        canonicalRoot: canonicalRoot,
        relativePath: relativePath,
        maxReadBytes: maxReadBytes,
        maxReturnedBytes: maxReturnedBytes,
        line: line,
        limit: limit,
      );
    } on SecureFsReadLimitExceeded {
      throw const FsReadRejectedException(FsReadRejectionReason.limit);
    }
    return utf8.decode(bytes, allowMalformed: false);
  }

  Future<String> _canonicalReadRoot(String canonicalPath) async {
    if (allowReadOutsideWorkspace) return p.rootPrefix(canonicalPath);
    String? selected;
    for (final configuredRoot in <String>[
      _jail.workspaceRoot,
      ..._jail.additionalWorkspaceRoots,
    ]) {
      late final String canonicalRoot;
      try {
        canonicalRoot = await Directory(configuredRoot).resolveSymbolicLinks();
      } on FileSystemException {
        continue;
      }
      if (canonicalPath != canonicalRoot &&
          !p.isWithin(canonicalRoot, canonicalPath)) {
        continue;
      }
      if (selected == null || canonicalRoot.length > selected.length) {
        selected = canonicalRoot;
      }
    }
    if (selected == null) {
      throw const FileSystemException('Access outside workspace is denied');
    }
    return selected;
  }

  int get _readReservationBytes =>
      maxReturnedBytes + _secureReadBufferBytes(maxReadBytes);

  static void _validateBudgets({
    required int maxReadBytes,
    required int maxReturnedBytes,
    required int maxConcurrentReads,
    required int maxAggregateReadBytes,
    required int maxWriteBytes,
    required int maxConcurrentWrites,
    required int maxAggregateWriteBytes,
  }) {
    if (maxReadBytes <= 0) {
      throw ArgumentError.value(maxReadBytes, 'maxReadBytes');
    }
    if (maxReturnedBytes <= 0 || maxReturnedBytes > maxReadBytes) {
      throw ArgumentError.value(maxReturnedBytes, 'maxReturnedBytes');
    }
    if (maxConcurrentReads <= 0) {
      throw ArgumentError.value(maxConcurrentReads, 'maxConcurrentReads');
    }
    final scanReservation = _secureReadBufferBytes(maxReadBytes);
    if (maxAggregateReadBytes < maxReturnedBytes + scanReservation) {
      throw ArgumentError.value(maxAggregateReadBytes, 'maxAggregateReadBytes');
    }
    if (maxWriteBytes <= 0) {
      throw ArgumentError.value(maxWriteBytes, 'maxWriteBytes');
    }
    if (maxConcurrentWrites <= 0) {
      throw ArgumentError.value(maxConcurrentWrites, 'maxConcurrentWrites');
    }
    final writeBufferBytes = maxWriteBytes < secureFsWriteChunkSize
        ? maxWriteBytes
        : secureFsWriteChunkSize;
    if (maxAggregateWriteBytes < writeBufferBytes ||
        maxWriteBytes > maxAggregateWriteBytes - writeBufferBytes) {
      throw ArgumentError.value(
        maxAggregateWriteBytes,
        'maxAggregateWriteBytes',
      );
    }
  }

  static int _secureReadBufferBytes(int maxReadBytes) =>
      maxReadBytes < secureFsReadChunkSize
      ? maxReadBytes + 1
      : secureFsReadChunkSize;

  @override
  Future<void> writeTextFile(String path, String content) {
    final lease = _writeLedger.tryAcquire(_writeReservationBytes);
    if (lease == null) {
      return Future<void>.error(
        const FsWriteRejectedException(FsWriteRejectionReason.capacity),
      );
    }
    try {
      return _writeTextFile(path, content).whenComplete(lease.release);
    } on Object catch (error, stackTrace) {
      lease.release();
      return Future<void>.error(error, stackTrace);
    }
  }

  Future<void> _writeTextFile(String path, String content) async {
    final resolved = await _jail.resolveForSecureWrite(path);
    try {
      await writeSecureTextFile(
        canonicalRoot: resolved.canonicalRoot,
        relativePath: resolved.relativePath,
        content: content,
        maxWriteBytes: maxWriteBytes,
      );
    } on SecureFsWriteLimitExceeded {
      throw const FsWriteRejectedException(FsWriteRejectionReason.limit);
    }
  }

  int get _writeReservationBytes =>
      maxWriteBytes +
      (maxWriteBytes < secureFsWriteChunkSize
          ? maxWriteBytes
          : secureFsWriteChunkSize);
}

final class _FsReadLedger {
  _FsReadLedger({
    required this.maxConcurrentReads,
    required this.maxAggregateReadBytes,
  });

  final int maxConcurrentReads;
  final int maxAggregateReadBytes;
  var _activeReads = 0;
  var _reservedBytes = 0;

  _FsReadLease? tryAcquire(int reservationBytes) {
    if (_activeReads >= maxConcurrentReads ||
        reservationBytes > maxAggregateReadBytes - _reservedBytes) {
      return null;
    }
    _activeReads += 1;
    _reservedBytes += reservationBytes;
    return _FsReadLease(this, reservationBytes);
  }

  void _release(int reservationBytes) {
    _activeReads -= 1;
    _reservedBytes -= reservationBytes;
  }
}

final class _FsReadLease {
  _FsReadLease(this._ledger, this._reservationBytes);

  final _FsReadLedger _ledger;
  final int _reservationBytes;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _ledger._release(_reservationBytes);
  }
}

final class _FsWriteLedger {
  _FsWriteLedger({
    required this.maxConcurrentWrites,
    required this.maxAggregateWriteBytes,
  });

  final int maxConcurrentWrites;
  final int maxAggregateWriteBytes;
  var _activeWrites = 0;
  var _reservedBytes = 0;

  _FsWriteLease? tryAcquire(int reservationBytes) {
    if (_activeWrites >= maxConcurrentWrites ||
        reservationBytes > maxAggregateWriteBytes - _reservedBytes) {
      return null;
    }
    _activeWrites += 1;
    _reservedBytes += reservationBytes;
    return _FsWriteLease(this, reservationBytes);
  }

  void _release(int reservationBytes) {
    _activeWrites -= 1;
    _reservedBytes -= reservationBytes;
  }
}

final class _FsWriteLease {
  _FsWriteLease(this._ledger, this._reservationBytes);

  final _FsWriteLedger _ledger;
  final int _reservationBytes;
  var _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _ledger._release(_reservationBytes);
  }
}
