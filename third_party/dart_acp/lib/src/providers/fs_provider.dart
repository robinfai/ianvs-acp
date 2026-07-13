import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../security/workspace_jail.dart';
import '../transport/byte_budget.dart';
import 'secure_fs_reader.dart';

/// Default maximum bytes retained in one filesystem read response.
const int defaultFsReturnedByteLimit = 2 * 1024 * 1024;

/// Default maximum simultaneous reads across one provider family.
const int defaultFsConcurrentReadLimit = 2;

/// Default aggregate read reservation across one provider family.
const int defaultFsAggregateReadByteLimit = 16 * 1024 * 1024;

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
         ledger: null,
       );

  DefaultFsProvider._({
    required this.workspaceRoot,
    required this.additionalWorkspaceRoots,
    required this.allowReadOutsideWorkspace,
    required this.maxReadBytes,
    required this.maxReturnedBytes,
    required this.maxConcurrentReads,
    required this.maxAggregateReadBytes,
    required _FsReadLedger? ledger,
  }) : _ledger =
           ledger ??
           _FsReadLedger(
             maxConcurrentReads: maxConcurrentReads,
             maxAggregateReadBytes: maxAggregateReadBytes,
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

  final _FsReadLedger _ledger;

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
    ledger: _ledger,
  );

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) {
    final lease = _ledger.tryAcquire(_readReservationBytes);
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
  }

  static int _secureReadBufferBytes(int maxReadBytes) =>
      maxReadBytes < secureFsReadChunkSize
      ? maxReadBytes + 1
      : secureFsReadChunkSize;

  @override
  Future<void> writeTextFile(String path, String content) async {
    // Writes must stay within the workspace (never allowed outside).
    final canonical = await _jail.resolveForgiving(path);
    if (!await _jail.isWithinWorkspace(canonical)) {
      throw FileSystemException(
        'Write denied: path is outside the workspace root. '
        'Please write within the project directory or adjust the path.',
        canonical,
      );
    }
    final filePath = canonical;
    final dir = Directory(p.dirname(filePath));
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    final file = File(filePath);
    file.writeAsStringSync(content);
  }
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
