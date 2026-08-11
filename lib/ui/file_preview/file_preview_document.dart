import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;

import '../../acp/acp_input_budget.dart';
import '../../platform/bounded_file_snapshot.dart';
import '../../platform/secure_file_reader.dart';

typedef FilePreviewProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef FilePreviewProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);
typedef FilePreviewImageDimensionInspector =
    Future<({int width, int height})> Function(Uint8List bytes);
typedef FilePreviewBeforeSecureRead = FutureOr<void> Function();
typedef FilePreviewBeforeQuickLookSnapshotRead = FutureOr<void> Function();
typedef FilePreviewBeforeQuickLookOutputRead = FutureOr<void> Function();
typedef FilePreviewTemporaryDirectoryCleaner =
    Future<void> Function(Directory directory);

const int filePreviewTextByteLimit = 4 * 1024 * 1024;
const int filePreviewImageByteLimit = 16 * 1024 * 1024;
const int filePreviewQuickLookInputByteLimit = 64 * 1024 * 1024;
const int filePreviewQuickLookRetainedInputByteLimit = 128 * 1024 * 1024;
const int filePreviewQuickLookProcessOutputByteLimit = 64 * 1024;
const Duration filePreviewQuickLookTimeout = Duration(seconds: 12);
const int filePreviewQuickLookQueueLimit = 6;
const int filePreviewQuickLookOutputEntryLimit = 32;
const int filePreviewQuickLookOutputNameByteLimit = 4096;

final class FilePreviewLoadCancelled implements Exception {
  const FilePreviewLoadCancelled();
}

final class FilePreviewLoadCancellationSource {
  final Completer<void> _cancelled = Completer<void>();

  bool get isCancelled => _cancelled.isCompleted;
  Future<void> get whenCancelled => _cancelled.future;

  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  void throwIfCancelled() {
    if (isCancelled) throw const FilePreviewLoadCancelled();
  }
}

final class FilePreviewQuickLookCoordinator {
  FilePreviewQuickLookCoordinator({
    this.maximumQueuedJobs = filePreviewQuickLookQueueLimit,
    this.maximumInFlightInputBytes = filePreviewQuickLookRetainedInputByteLimit,
  }) {
    if (maximumQueuedJobs < 0 || maximumInFlightInputBytes <= 0) {
      throw ArgumentError('Invalid Quick Look coordinator limits.');
    }
  }

  final int maximumQueuedJobs;
  final int maximumInFlightInputBytes;
  final Queue<_QuickLookWaiter> _waiters = Queue<_QuickLookWaiter>();
  bool _active = false;
  bool _disposed = false;
  int _reservedInputBytes = 0;

  bool get hasActiveJob => _active;
  int get queuedJobs => _waiters.length;
  int get reservedInputBytes => _reservedInputBytes;

  Future<FilePreviewQuickLookLease> acquire({
    required int inputBytes,
    required FilePreviewLoadCancellationSource cancellation,
  }) {
    if (_disposed || cancellation.isCancelled) {
      return Future<FilePreviewQuickLookLease>.error(
        const FilePreviewLoadCancelled(),
      );
    }
    if (inputBytes < 0 || inputBytes > maximumInFlightInputBytes) {
      return Future<FilePreviewQuickLookLease>.error(
        FilePreviewByteLimitExceededException(maximumInFlightInputBytes),
      );
    }
    if (inputBytes > maximumInFlightInputBytes - _reservedInputBytes) {
      return Future<FilePreviewQuickLookLease>.error(
        FilePreviewByteLimitExceededException(maximumInFlightInputBytes),
      );
    }
    if (_active && _waiters.length >= maximumQueuedJobs) {
      return Future<FilePreviewQuickLookLease>.error(
        StateError('Too many queued Quick Look jobs.'),
      );
    }
    _reservedInputBytes += inputBytes;
    if (!_active) {
      _active = true;
      return Future<FilePreviewQuickLookLease>.value(
        FilePreviewQuickLookLease._(this, inputBytes),
      );
    }
    final waiter = _QuickLookWaiter(inputBytes, cancellation);
    _waiters.add(waiter);
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!waiter.waiting) return;
        waiter.waiting = false;
        _waiters.remove(waiter);
        _reservedInputBytes -= waiter.inputBytes;
        waiter.completer.completeError(const FilePreviewLoadCancelled());
      }),
    );
    return waiter.completer.future;
  }

  void _release(FilePreviewQuickLookLease lease) {
    if (lease._released) return;
    lease._released = true;
    _reservedInputBytes -= lease.inputBytes;
    _active = false;
    _grantNext();
  }

  void _grantNext() {
    while (!_disposed && !_active && _waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.waiting) continue;
      waiter.waiting = false;
      if (waiter.cancellation.isCancelled) {
        _reservedInputBytes -= waiter.inputBytes;
        waiter.completer.completeError(const FilePreviewLoadCancelled());
        continue;
      }
      _active = true;
      waiter.completer.complete(
        FilePreviewQuickLookLease._(this, waiter.inputBytes),
      );
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeFirst();
      if (!waiter.waiting) continue;
      waiter.waiting = false;
      _reservedInputBytes -= waiter.inputBytes;
      waiter.completer.completeError(const FilePreviewLoadCancelled());
    }
  }
}

final class FilePreviewQuickLookLease {
  FilePreviewQuickLookLease._(this._coordinator, this.inputBytes);

  final FilePreviewQuickLookCoordinator _coordinator;
  final int inputBytes;
  bool _released = false;

  void release() => _coordinator._release(this);
}

final class _QuickLookWaiter {
  _QuickLookWaiter(this.inputBytes, this.cancellation);

  final int inputBytes;
  final FilePreviewLoadCancellationSource cancellation;
  final Completer<FilePreviewQuickLookLease> completer =
      Completer<FilePreviewQuickLookLease>();
  bool waiting = true;
}

final class FilePreviewByteLimitExceededException implements Exception {
  const FilePreviewByteLimitExceededException(this.maximumBytes);

  final int maximumBytes;

  @override
  String toString() => 'File exceeds the $maximumBytes byte preview limit.';
}

enum FilePreviewKind { markdown, text, image, quickLook, unsupported }

final class FilePreviewTarget {
  const FilePreviewTarget({
    required this.path,
    required this.workspacePath,
    this.line,
    this.authorizedRoot,
    this.authorizedRelativePath,
    this.authorizedCapability,
  });

  final String path;
  final String workspacePath;
  final int? line;
  final String? authorizedRoot;
  final String? authorizedRelativePath;
  final SecureFileCapability? authorizedCapability;

  String get name => p.basename(path);

  String get parentPath => p.dirname(path);

  String get displayPath {
    final relative = p.relative(path, from: workspacePath);
    return p.isWithin(workspacePath, path) ? relative : path;
  }
}

final class FilePreviewDocument {
  const FilePreviewDocument({
    required this.target,
    required this.kind,
    required this.mimeType,
    required this.size,
    this.text,
    this.textTruncated = false,
    this.previewBytes,
    this.previewError,
  });

  final FilePreviewTarget target;
  final FilePreviewKind kind;
  final String mimeType;
  final int size;
  final String? text;
  final bool textTruncated;
  final Uint8List? previewBytes;
  final String? previewError;

  String get typeLabel => switch (kind) {
    FilePreviewKind.markdown => 'Markdown',
    FilePreviewKind.text => _textTypeLabel(target.path),
    FilePreviewKind.image => '图片',
    FilePreviewKind.quickLook => _quickLookTypeLabel(target.path),
    FilePreviewKind.unsupported => '文件',
  };
}

Future<FilePreviewTarget> resolveFilePreviewTarget({
  required String href,
  required String workspacePath,
  List<String> additionalDirectories = const <String>[],
  String? baseDirectory,
}) async {
  final rawHref = href.trim();
  if (rawHref.isEmpty) {
    throw const FormatException('链接没有文件路径。');
  }

  final uri = Uri.tryParse(rawHref);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme.isNotEmpty && scheme != 'file') {
    throw FormatException('不支持在文件预览中打开 $scheme 链接。');
  }

  var line = _lineFromFragment(uri?.fragment);
  var rawPath = scheme == 'file'
      ? uri!.toFilePath(windows: Platform.isWindows)
      : Uri.decodeComponent(uri?.path ?? rawHref);
  final suffix = RegExp(r'^(.*?):(\d+)(?::\d+)?$').firstMatch(rawPath);
  if (suffix != null) {
    rawPath = suffix.group(1)!;
    line ??= int.tryParse(suffix.group(2)!);
  }
  if (rawPath.trim().isEmpty) {
    throw const FormatException('链接没有文件路径。');
  }

  final normalizedWorkspace = p.normalize(p.absolute(workspacePath));
  final resolvedWorkspace = await _resolveDirectoryIfPossible(
    normalizedWorkspace,
  );
  final base = baseDirectory == null || baseDirectory.trim().isEmpty
      ? normalizedWorkspace
      : p.normalize(p.absolute(baseDirectory));
  final candidate = p.normalize(
    p.isAbsolute(rawPath) ? rawPath : p.join(base, rawPath),
  );
  final type = await FileSystemEntity.type(candidate, followLinks: true);
  if (type == FileSystemEntityType.notFound) {
    throw FileSystemException('文件不存在', candidate);
  }
  if (type != FileSystemEntityType.file) {
    throw FileSystemException('链接不是可预览的普通文件', candidate);
  }

  final resolvedPath = await File(candidate).resolveSymbolicLinks();
  final allowedRoots = <String>{
    resolvedWorkspace,
    for (final directory in additionalDirectories)
      if (directory.trim().isNotEmpty)
        p.normalize(p.absolute(directory.trim())),
  };
  String? authorizedRoot;
  String? authorizedRelativePath;
  for (final root in allowedRoots) {
    final resolvedRoot = await _resolveDirectoryIfPossible(root);
    if (p.equals(resolvedRoot, resolvedPath) ||
        p.isWithin(resolvedRoot, resolvedPath)) {
      authorizedRoot = resolvedRoot;
      authorizedRelativePath = p.relative(resolvedPath, from: resolvedRoot);
      break;
    }
  }
  if (authorizedRoot == null || authorizedRelativePath == null) {
    throw FileSystemException('文件不在当前工作区或已授权目录中', resolvedPath);
  }
  final authorizedCapability = await captureWorkspaceFileCapabilitySecurely(
    resolvedWorkspacePath: authorizedRoot,
    relativePath: authorizedRelativePath,
  );
  if (authorizedCapability == null) {
    throw FileSystemException('无法安全绑定已授权文件', resolvedPath);
  }

  return FilePreviewTarget(
    path: resolvedPath,
    workspacePath: resolvedWorkspace,
    line: line == null || line < 1 ? null : line,
    authorizedRoot: authorizedRoot,
    authorizedRelativePath: authorizedRelativePath,
    authorizedCapability: authorizedCapability,
  );
}

Future<FilePreviewTarget> resolveMarkdownImageTarget({
  required String source,
  required String workspacePath,
  required String baseDirectory,
  List<String> additionalDirectories = const <String>[],
}) async {
  final value = source.trim();
  if (value.isEmpty) {
    throw const FormatException('图片没有文件路径。');
  }

  try {
    return await resolveFilePreviewTarget(
      href: value,
      workspacePath: workspacePath,
      additionalDirectories: additionalDirectories,
      baseDirectory: baseDirectory,
    );
  } on FileSystemException {
    final uri = Uri.tryParse(value);
    final scheme = uri?.scheme.toLowerCase() ?? '';
    final encodedPath = uri?.path ?? value;
    if (scheme.isNotEmpty ||
        !encodedPath.startsWith('/') ||
        encodedPath.startsWith('//')) {
      rethrow;
    }

    // Markdown authored for GitHub and other web renderers commonly uses a
    // leading slash for a repository-root-relative asset. Prefer a real,
    // authorized absolute path above, then fall back to the workspace root.
    final workspaceRelative = encodedPath.substring(1);
    if (workspaceRelative.isEmpty) rethrow;
    final fragment = uri?.hasFragment == true ? '#${uri!.fragment}' : '';
    return resolveFilePreviewTarget(
      href: '$workspaceRelative$fragment',
      workspacePath: workspacePath,
      additionalDirectories: additionalDirectories,
      baseDirectory: workspacePath,
    );
  }
}

Future<FilePreviewDocument> loadFilePreviewDocument(
  FilePreviewTarget target, {
  FilePreviewProcessStarter? processStarter,
  Duration quickLookTimeout = filePreviewQuickLookTimeout,
  FilePreviewBeforeSecureRead? beforeSecureRead,
  FilePreviewBeforeQuickLookSnapshotRead? beforeQuickLookSnapshotRead,
  FilePreviewBeforeQuickLookOutputRead? beforeQuickLookOutputRead,
  FilePreviewTemporaryDirectoryCleaner? temporaryDirectoryCleaner,
  FilePreviewLoadCancellationSource? cancellation,
  FilePreviewQuickLookCoordinator? quickLookCoordinator,
  FilePreviewImageDimensionInspector imageDimensionInspector =
      inspectFilePreviewImageDimensions,
}) async {
  final loadCancellation = cancellation ?? FilePreviewLoadCancellationSource();
  loadCancellation.throwIfCancelled();
  await beforeSecureRead?.call();
  final prefixSnapshot = await _readAuthorizedSnapshot(target, 64);
  loadCancellation.throwIfCancelled();
  if (prefixSnapshot == null) {
    throw FileSystemException('无法安全打开已授权文件', target.path);
  }
  final prefix = prefixSnapshot.bytes;
  final mimeType =
      mime.lookupMimeType(target.path, headerBytes: prefix) ??
      'application/octet-stream';
  final kind = classifyFilePreview(target.path, mimeType);

  if (kind == FilePreviewKind.markdown || kind == FilePreviewKind.text) {
    final snapshot = await _readAuthorizedSnapshot(
      target,
      filePreviewTextByteLimit,
    );
    if (snapshot == null) {
      throw FileSystemException('无法安全打开已授权文件', target.path);
    }
    final result = _decodeTextPreview(snapshot);
    return FilePreviewDocument(
      target: target,
      kind: kind,
      mimeType: mimeType,
      size: snapshot.sizeBytes,
      text: result.text,
      textTruncated: result.truncated,
    );
  }

  if (kind == FilePreviewKind.quickLook) {
    if (prefixSnapshot.sizeBytes > filePreviewQuickLookInputByteLimit) {
      return FilePreviewDocument(
        target: target,
        kind: kind,
        mimeType: mimeType,
        size: prefixSnapshot.sizeBytes,
        previewError: '文件超过 64 MB Quick Look 安全预览限制。',
      );
    }
    final ownedCoordinator = quickLookCoordinator == null;
    final coordinator =
        quickLookCoordinator ?? FilePreviewQuickLookCoordinator();
    FilePreviewQuickLookLease? lease;
    try {
      lease = await coordinator.acquire(
        // TransferableTypedData.fromList copies the secure snapshot once.
        // Reserving twice the file size bounds the original Uint8List plus
        // the transferable backing store to 128 MiB per active Quick Look.
        inputBytes: prefixSnapshot.sizeBytes * 2,
        cancellation: loadCancellation,
      );
      loadCancellation.throwIfCancelled();
      await beforeQuickLookSnapshotRead?.call();
      loadCancellation.throwIfCancelled();
      var snapshot = await _readAuthorizedSnapshot(
        target,
        filePreviewQuickLookInputByteLimit,
      );
      loadCancellation.throwIfCancelled();
      if (snapshot == null) {
        throw FileSystemException('无法安全打开已授权文件', target.path);
      }
      if (snapshot.exceededLimit) {
        return FilePreviewDocument(
          target: target,
          kind: kind,
          mimeType: mimeType,
          size: snapshot.sizeBytes,
          previewError: '文件超过 64 MB Quick Look 安全预览限制。',
        );
      }
      if (snapshot.sizeBytes != prefixSnapshot.sizeBytes) {
        return FilePreviewDocument(
          target: target,
          kind: kind,
          mimeType: mimeType,
          size: snapshot.sizeBytes,
          previewError: '文件在预览读取期间发生变化。',
        );
      }
      final snapshotSize = snapshot.sizeBytes;
      final inputData = TransferableTypedData.fromList(<Uint8List>[
        snapshot.bytes,
      ]);
      snapshot = null;
      final result = await _renderQuickLookThumbnail(
        target.path,
        inputData: inputData,
        processStarter: processStarter,
        timeout: quickLookTimeout,
        cancellation: loadCancellation,
        beforeOutputRead: beforeQuickLookOutputRead,
        temporaryDirectoryCleaner: temporaryDirectoryCleaner,
        imageDimensionInspector: imageDimensionInspector,
      );
      loadCancellation.throwIfCancelled();
      return FilePreviewDocument(
        target: target,
        kind: kind,
        mimeType: mimeType,
        size: snapshotSize,
        previewBytes: result.bytes,
        previewError: result.error,
      );
    } finally {
      lease?.release();
      if (ownedCoordinator) coordinator.dispose();
    }
  }

  if (kind == FilePreviewKind.image) {
    if (prefixSnapshot.sizeBytes > filePreviewImageByteLimit) {
      return FilePreviewDocument(
        target: target,
        kind: kind,
        mimeType: mimeType,
        size: prefixSnapshot.sizeBytes,
        previewError: '图片文件超过 16 MB 限制，可用其他应用安全打开。',
      );
    }
    final snapshot = await _readAuthorizedSnapshot(
      target,
      filePreviewImageByteLimit,
    );
    if (snapshot == null) {
      throw FileSystemException('无法安全打开已授权文件', target.path);
    }
    if (snapshot.exceededLimit) {
      return FilePreviewDocument(
        target: target,
        kind: kind,
        mimeType: mimeType,
        size: snapshot.sizeBytes,
        previewError: '图片文件超过 16 MB 限制，可用其他应用安全打开。',
      );
    }
    final bytes = snapshot.bytes;
    try {
      final dimensions = await imageDimensionInspector(bytes);
      if (!filePreviewImageDimensionsAreSafe(dimensions)) {
        return FilePreviewDocument(
          target: target,
          kind: kind,
          mimeType: mimeType,
          size: snapshot.sizeBytes,
          previewError: '图片尺寸超过安全预览限制，可用其他应用打开。',
        );
      }
    } on Object {
      return FilePreviewDocument(
        target: target,
        kind: kind,
        mimeType: mimeType,
        size: snapshot.sizeBytes,
        previewError: '无法安全读取图片尺寸，可用其他应用打开。',
      );
    }
    return FilePreviewDocument(
      target: target,
      kind: kind,
      mimeType: mimeType,
      size: snapshot.sizeBytes,
      previewBytes: bytes,
    );
  }

  return FilePreviewDocument(
    target: target,
    kind: kind,
    mimeType: mimeType,
    size: prefixSnapshot.sizeBytes,
  );
}

FilePreviewKind classifyFilePreview(String path, String mimeType) {
  final extension = p.extension(path).toLowerCase();
  if (const {'.md', '.markdown', '.mdown', '.mkd'}.contains(extension)) {
    return FilePreviewKind.markdown;
  }
  if (mimeType.startsWith('image/') ||
      const {
        '.png',
        '.jpg',
        '.jpeg',
        '.gif',
        '.webp',
        '.bmp',
        '.tif',
        '.tiff',
        '.heic',
      }.contains(extension)) {
    return FilePreviewKind.image;
  }
  if (mimeType.startsWith('text/') || _textExtensions.contains(extension)) {
    return FilePreviewKind.text;
  }
  if (_quickLookExtensions.contains(extension)) {
    return FilePreviewKind.quickLook;
  }
  return FilePreviewKind.unsupported;
}

String formatFilePreviewSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kib = bytes / 1024;
  if (kib < 1024) return '${kib.toStringAsFixed(kib < 10 ? 1 : 0)} KB';
  final mib = kib / 1024;
  if (mib < 1024) return '${mib.toStringAsFixed(mib < 10 ? 1 : 0)} MB';
  final gib = mib / 1024;
  return '${gib.toStringAsFixed(1)} GB';
}

const _textExtensions = <String>{
  '.txt',
  '.log',
  '.json',
  '.jsonl',
  '.yaml',
  '.yml',
  '.toml',
  '.xml',
  '.csv',
  '.tsv',
  '.dart',
  '.swift',
  '.kt',
  '.java',
  '.js',
  '.jsx',
  '.ts',
  '.tsx',
  '.css',
  '.scss',
  '.html',
  '.htm',
  '.py',
  '.rb',
  '.go',
  '.rs',
  '.c',
  '.h',
  '.cc',
  '.cpp',
  '.hpp',
  '.sh',
  '.zsh',
  '.fish',
  '.sql',
  '.graphql',
  '.gql',
  '.ini',
  '.conf',
  '.cfg',
  '.env',
  '.properties',
  '.gradle',
  '.lock',
  '.diff',
  '.patch',
  '.gitignore',
};

const _quickLookExtensions = <String>{
  '.pdf',
  '.rtf',
  '.doc',
  '.docx',
  '.xls',
  '.xlsx',
  '.ppt',
  '.pptx',
  '.pages',
  '.numbers',
  '.key',
  '.mov',
  '.mp4',
  '.m4v',
  '.mp3',
  '.m4a',
  '.wav',
  '.aac',
};

String? quickLookContentTypeForPath(String path) =>
    switch (p.extension(path).toLowerCase()) {
      '.txt' || '.log' => 'public.plain-text',
      '.pdf' => 'com.adobe.pdf',
      '.rtf' => 'public.rtf',
      '.doc' => 'com.microsoft.word.doc',
      '.docx' => 'org.openxmlformats.wordprocessingml.document',
      '.xls' => 'com.microsoft.excel.xls',
      '.xlsx' => 'org.openxmlformats.spreadsheetml.sheet',
      '.ppt' => 'com.microsoft.powerpoint.ppt',
      '.pptx' => 'org.openxmlformats.presentationml.presentation',
      '.pages' => 'com.apple.iwork.pages.pages',
      '.numbers' => 'com.apple.iwork.numbers.numbers',
      '.key' => 'com.apple.iwork.keynote.key',
      '.mov' => 'com.apple.quicktime-movie',
      '.mp4' || '.m4v' => 'public.mpeg-4',
      '.mp3' => 'public.mp3',
      '.m4a' => 'public.mpeg-4-audio',
      '.wav' => 'com.microsoft.waveform-audio',
      '.aac' => 'public.aac-audio',
      _ => null,
    };

int? _lineFromFragment(String? fragment) {
  if (fragment == null || fragment.isEmpty) return null;
  final match = RegExp(
    r'(?:^|[&])(?:L|line=)?(\d+)',
    caseSensitive: false,
  ).firstMatch(fragment);
  return match == null ? null : int.tryParse(match.group(1)!);
}

Future<String> _resolveDirectoryIfPossible(String path) async {
  try {
    return await Directory(path).resolveSymbolicLinks();
  } on FileSystemException {
    return path;
  }
}

Future<SecureBoundedFileSnapshot?> _readAuthorizedSnapshot(
  FilePreviewTarget target,
  int maximumBytes,
) {
  final root = target.authorizedRoot;
  final relativePath = target.authorizedRelativePath;
  final capability = target.authorizedCapability;
  if (root == null || relativePath == null || capability == null) {
    return Future<SecureBoundedFileSnapshot?>.value();
  }
  return readWorkspaceFileSnapshotSecurely(
    resolvedWorkspacePath: root,
    relativePath: relativePath,
    maximumBytes: maximumBytes,
    expectedCapability: capability,
  );
}

Future<bool> revalidateFilePreviewTarget(FilePreviewTarget target) {
  final root = target.authorizedRoot;
  final relativePath = target.authorizedRelativePath;
  final capability = target.authorizedCapability;
  if (root == null || relativePath == null || capability == null) {
    return Future<bool>.value(false);
  }
  return validateWorkspaceFileCapabilitySecurely(
    resolvedWorkspacePath: root,
    relativePath: relativePath,
    expectedCapability: capability,
  );
}

/// Reads at most [maximumBytes] into a stable in-memory snapshot.
///
/// The extra byte is read from the same stream so a stale or forged metadata
/// size cannot bypass the limit before the preview decoder sees the content.
Future<Uint8List> readFileBytesBounded(
  File file, {
  required int maximumBytes,
}) async {
  if (maximumBytes < 0) {
    throw RangeError.range(maximumBytes, 0, null, 'maximumBytes');
  }
  try {
    return await readBoundedFileSnapshot(file, maxBytes: maximumBytes);
  } on BoundedFileSnapshotOverflowException {
    throw FilePreviewByteLimitExceededException(maximumBytes);
  }
}

Future<({int width, int height})> inspectFilePreviewImageDimensions(
  Uint8List bytes,
) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return (width: descriptor.width, height: descriptor.height);
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}

bool filePreviewImageDimensionsAreSafe(
  ({int width, int height}) dimensions, {
  AcpInputBudget budget = const AcpInputBudget(),
}) {
  final width = dimensions.width;
  final height = dimensions.height;
  if (width <= 0 || height <= 0) return false;
  if (width > budget.maxImageDimension || height > budget.maxImageDimension) {
    return false;
  }
  return width <= budget.maxImagePixels ~/ height;
}

({String text, bool truncated}) _decodeTextPreview(
  SecureBoundedFileSnapshot snapshot,
) {
  var bytes = snapshot.bytes;
  if (snapshot.exceededLimit) {
    while (bytes.isNotEmpty && (bytes.last & 0xc0) == 0x80) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
  }
  return (
    text: const Utf8Decoder(allowMalformed: true).convert(bytes),
    truncated: snapshot.exceededLimit,
  );
}

Future<({Uint8List? bytes, String? error})> _renderQuickLookThumbnail(
  String path, {
  required TransferableTypedData inputData,
  FilePreviewProcessStarter? processStarter,
  required Duration timeout,
  required FilePreviewLoadCancellationSource cancellation,
  FilePreviewBeforeQuickLookOutputRead? beforeOutputRead,
  FilePreviewTemporaryDirectoryCleaner? temporaryDirectoryCleaner,
  required FilePreviewImageDimensionInspector imageDimensionInspector,
}) async {
  if (!Platform.isMacOS) {
    return (bytes: null, error: '当前平台暂不支持此格式的内嵌预览。');
  }
  final deadline = DateTime.now().add(timeout);
  final resolvedSystemTemp = await Directory.systemTemp.resolveSymbolicLinks();
  final temporary = await createSecureTemporaryDirectory(
    resolvedParentPath: resolvedSystemTemp,
  );
  if (temporary == null) {
    return (bytes: null, error: '无法安全创建系统预览输出目录。');
  }
  const outputName = '0.png';
  try {
    cancellation.throwIfCancelled();
    final contentType = quickLookContentTypeForPath(path);
    if (contentType == null) {
      return (bytes: null, error: '此文件类型没有安全的系统预览内容类型映射。');
    }
    final outputDirectory = Directory(temporary.path);
    final arguments = <String>[
      '-t',
      '-s',
      '1600',
      '-c',
      contentType,
      '-o',
      outputDirectory.path,
      '/dev/fd/0',
    ];
    final processResult = await _runBoundedQuickLookProcess(
      '/usr/bin/qlmanage',
      arguments,
      inputData: inputData,
      resolvedTemporaryDirectoryPath: resolvedSystemTemp,
      processStarter: processStarter,
      deadline: deadline,
      cancellation: cancellation,
    );
    cancellation.throwIfCancelled();
    if (processResult.timedOut) {
      return (bytes: null, error: '系统预览生成超时，已终止相关进程。');
    }
    if (processResult.outputExceeded) {
      return (bytes: null, error: '系统预览器输出超过安全限制。');
    }
    if (processResult.stdinFailed) {
      return (bytes: null, error: '无法向系统预览器安全传输文件内容。');
    }
    if (processResult.exitCode != 0) {
      return (bytes: null, error: '系统无法生成此文件的预览。');
    }
    // qlmanage consumes the already-authorized bounded snapshot only through
    // stdin. There is no mutable input pathname or path-based ABA window. This
    // does not claim isolation from an arbitrary same-UID process, which could
    // inspect application memory or use platform debugging facilities.
    try {
      final generated = await _readQuickLookOutputSecurely(
        outputDirectory,
        outputName: outputName,
        directoryCapability: temporary.capability,
        beforeOutputRead: beforeOutputRead,
      );
      if (generated.error != null) {
        return (bytes: null, error: generated.error);
      }
      final bytes = generated.bytes;
      if (bytes == null) {
        return (bytes: null, error: '系统没有返回可显示的预览。');
      }
      final dimensions = await imageDimensionInspector(bytes);
      if (!filePreviewImageDimensionsAreSafe(dimensions)) {
        return (bytes: null, error: '系统生成的预览尺寸超过安全限制。');
      }
      return (bytes: bytes, error: null);
    } on Object {
      return (bytes: null, error: '系统生成的预览无法安全解码。');
    }
  } on FileSystemException {
    return (bytes: null, error: '系统无法生成此文件的预览。');
  } finally {
    await _cleanupQuickLookTemporaryDirectory(
      temporary,
      fixedOutputName: outputName,
      deadline: deadline,
      cleaner: temporaryDirectoryCleaner,
    );
  }
}

Future<({Uint8List? bytes, String? error})> _readQuickLookOutputSecurely(
  Directory outputDirectory, {
  required String outputName,
  required SecureDirectoryCapability directoryCapability,
  FilePreviewBeforeQuickLookOutputRead? beforeOutputRead,
}) async {
  final capability = await captureWorkspaceFileCapabilitySecurely(
    resolvedWorkspacePath: outputDirectory.path,
    relativePath: outputName,
    expectedRootCapability: directoryCapability,
    requireSingleLink: true,
  );
  if (capability == null) {
    return (bytes: null, error: '系统生成的预览不是安全的普通文件。');
  }
  await beforeOutputRead?.call();
  final snapshot = await readWorkspaceFileSnapshotSecurely(
    resolvedWorkspacePath: outputDirectory.path,
    relativePath: outputName,
    maximumBytes: filePreviewImageByteLimit,
    expectedCapability: capability,
    requireSingleLink: true,
  );
  if (snapshot == null) {
    return (bytes: null, error: '系统生成的预览在读取前发生了变化。');
  }
  if (snapshot.exceededLimit) {
    return (bytes: null, error: '系统生成的预览超过 16 MB 限制。');
  }
  return (bytes: snapshot.bytes, error: null);
}

Future<void> _cleanupQuickLookTemporaryDirectory(
  SecureTemporaryDirectory temporary, {
  required String fixedOutputName,
  required DateTime deadline,
  FilePreviewTemporaryDirectoryCleaner? cleaner,
}) async {
  final cleanup = (() async {
    try {
      final prepared = await quarantineSecureTemporaryDirectoryForCleanup(
        temporary: temporary,
        fixedOutputName: fixedOutputName,
      );
      if (prepared == null || prepared.removed) return;
      final quarantine = prepared.quarantine;
      if (quarantine == null) return;
      await deleteQuarantinedTemporaryDirectorySecurely(quarantine: quarantine);
      if (cleaner != null) {
        await cleaner(Directory(quarantine.path ?? temporary.path));
      }
    } on Object {
      // Cleanup is best-effort and must never surface as a late zone error.
    }
  })();
  final guarded = cleanup.catchError((Object _, StackTrace _) {});
  final completed = await Future.any<bool>(<Future<bool>>[
    guarded.then((_) => true),
    _deadlineFuture(deadline, false),
  ]);
  if (!completed) unawaited(guarded);
}

Future<({int exitCode, bool timedOut, bool outputExceeded, bool stdinFailed})>
_runBoundedQuickLookProcess(
  String executable,
  List<String> arguments, {
  required TransferableTypedData inputData,
  required String resolvedTemporaryDirectoryPath,
  FilePreviewProcessStarter? processStarter,
  required DateTime deadline,
  required FilePreviewLoadCancellationSource cancellation,
}) async {
  if (processStarter == null) {
    return _runNativeQuickLookProcess(
      executable,
      arguments,
      inputData: inputData,
      resolvedTemporaryDirectoryPath: resolvedTemporaryDirectoryPath,
      deadline: deadline,
      cancellation: cancellation,
    );
  }

  // Injectable dart:io processes are retained only as a deterministic test
  // seam. Production always uses the native seekable-stdin process-group path
  // above and therefore never exposes inherited stdout/stderr pipes.
  final inputBytes = inputData.materialize().asUint8List();
  final startFuture = processStarter(
    executable,
    List<String>.unmodifiable(arguments),
  );
  final startOutcome = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      startFuture.then<_QuickLookProcessEvent>(
        _QuickLookProcessStarted.new,
        onError: (Object error, StackTrace stackTrace) =>
            _QuickLookProcessStartFailed(error, stackTrace),
      ),
      _deadlineFuture(deadline, _QuickLookProcessEvent.deadline),
      cancellation.whenCancelled.then((_) => _QuickLookProcessEvent.cancelled),
    ],
  );
  if (startOutcome case _QuickLookProcessStartFailed(
    :final error,
    :final stackTrace,
  )) {
    Error.throwWithStackTrace(error, stackTrace);
  }
  if (startOutcome is! _QuickLookProcessStarted) {
    unawaited(
      startFuture.then<void>(
        _detachAndKillLateQuickLookProcess,
        onError: (Object _, StackTrace _) {},
      ),
    );
    return (
      exitCode: -1,
      timedOut: startOutcome == _QuickLookProcessEvent.deadline,
      outputExceeded: false,
      stdinFailed: false,
    );
  }

  final process = startOutcome.process;
  final outputCounter = _QuickLookOutputCounter();
  final stdoutDrain = _QuickLookPipeDrain(
    process.stdout,
    outputCounter: outputCounter,
  );
  final stderrDrain = _QuickLookPipeDrain(
    process.stderr,
    outputCounter: outputCounter,
  );
  final exitCode = process.exitCode.then<int>(
    (code) => code,
    onError: (Object _, StackTrace _) => -1,
  );
  final stdinWrite = Future<void>.sync(
    () => _writeQuickLookStdin(process, inputBytes),
  );
  final completed =
      Future.wait<Object?>(<Future<Object?>>[
        exitCode,
        stdinWrite,
      ], eagerError: true).then<_QuickLookProcessEvent>(
        (values) => _QuickLookProcessCompleted(values.first! as int),
        onError: (Object _, StackTrace _) => _QuickLookProcessEvent.stdinFailed,
      );
  final first = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      completed,
      outputCounter.reached.then((_) => _QuickLookProcessEvent.outputExceeded),
      cancellation.whenCancelled.then((_) => _QuickLookProcessEvent.cancelled),
      _deadlineFuture(deadline, _QuickLookProcessEvent.deadline),
    ],
  );
  var timedOut = first == _QuickLookProcessEvent.deadline;
  final outputExceeded = first == _QuickLookProcessEvent.outputExceeded;
  final stdinFailed = first == _QuickLookProcessEvent.stdinFailed;
  int? code;
  if (first case _QuickLookProcessCompleted(:final exitCode)) {
    code = exitCode;
    final drains = Future.wait<void>(<Future<void>>[
      stdoutDrain.done,
      stderrDrain.done,
    ]);
    final drainOutcome = await Future.any<_QuickLookProcessEvent>(<
      Future<_QuickLookProcessEvent>
    >[
      drains.then((_) => _QuickLookProcessEvent.drained),
      cancellation.whenCancelled.then((_) => _QuickLookProcessEvent.cancelled),
      outputCounter.reached.then((_) => _QuickLookProcessEvent.outputExceeded),
      _deadlineFuture(deadline, _QuickLookProcessEvent.deadline),
    ]);
    timedOut = drainOutcome == _QuickLookProcessEvent.deadline;
    if (drainOutcome != _QuickLookProcessEvent.drained) {
      stdoutDrain.detach();
      stderrDrain.detach();
    }
    return (
      exitCode: code,
      timedOut: timedOut,
      outputExceeded:
          outputExceeded ||
          drainOutcome == _QuickLookProcessEvent.outputExceeded,
      stdinFailed: false,
    );
  }

  // dart:io cannot create or signal a dedicated process group. We terminate
  // the direct qlmanage child, escalate to SIGKILL, then detach both bounded
  // pipe subscriptions so a descendant retaining inherited pipe FDs cannot
  // keep the preview job or its coordinator lease alive indefinitely.
  process.kill();
  final termDeadline = _earlierDeadline(
    deadline,
    DateTime.now().add(const Duration(milliseconds: 250)),
  );
  final termOutcome =
      await Future.any<_QuickLookProcessEvent>(<Future<_QuickLookProcessEvent>>[
        exitCode.then((_) => _QuickLookProcessEvent.exited),
        _deadlineFuture(termDeadline, _QuickLookProcessEvent.deadline),
      ]);
  if (termOutcome != _QuickLookProcessEvent.exited) {
    process.kill(ProcessSignal.sigkill);
  }
  final reapDeadline = _earlierDeadline(
    deadline,
    DateTime.now().add(const Duration(milliseconds: 250)),
  );
  final finalOutcome =
      await Future.any<_QuickLookProcessEvent>(<Future<_QuickLookProcessEvent>>[
        exitCode.then((_) => _QuickLookProcessEvent.exited),
        _deadlineFuture(reapDeadline, _QuickLookProcessEvent.deadline),
      ]);
  if (finalOutcome == _QuickLookProcessEvent.exited) code = await exitCode;
  if (finalOutcome == _QuickLookProcessEvent.deadline) timedOut = true;
  stdoutDrain.detach();
  stderrDrain.detach();
  return (
    exitCode: code ?? -1,
    timedOut: timedOut,
    outputExceeded: outputExceeded,
    stdinFailed: stdinFailed,
  );
}

Future<({int exitCode, bool timedOut, bool outputExceeded, bool stdinFailed})>
_runNativeQuickLookProcess(
  String executable,
  List<String> arguments, {
  required TransferableTypedData inputData,
  required String resolvedTemporaryDirectoryPath,
  required DateTime deadline,
  required FilePreviewLoadCancellationSource cancellation,
}) async {
  final spawnFuture = spawnProcessWithAnonymousStdin(
    executable: executable,
    arguments: List<String>.unmodifiable(arguments),
    inputData: inputData,
    resolvedTemporaryDirectoryPath: resolvedTemporaryDirectoryPath,
    deadline: deadline,
  );
  final spawnOutcome = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      spawnFuture.then<_QuickLookProcessEvent>(
        _QuickLookNativeSpawnCompleted.new,
        onError: (Object error, StackTrace stackTrace) =>
            _QuickLookProcessStartFailed(error, stackTrace),
      ),
      cancellation.whenCancelled.then((_) => _QuickLookProcessEvent.cancelled),
      _deadlineFuture(deadline, _QuickLookProcessEvent.deadline),
    ],
  );
  if (spawnOutcome is! _QuickLookNativeSpawnCompleted) {
    unawaited(
      spawnFuture.then<void>(
        _detachAndReapLateNativeQuickLookProcess,
        onError: (Object _, StackTrace _) {},
      ),
    );
    return (
      exitCode: -1,
      timedOut: spawnOutcome == _QuickLookProcessEvent.deadline,
      outputExceeded: false,
      stdinFailed: spawnOutcome is _QuickLookProcessStartFailed,
    );
  }

  final process = spawnOutcome.result.process;
  if (process == null) {
    return (
      exitCode: -1,
      timedOut: spawnOutcome.result.deadlineExceeded,
      outputExceeded: false,
      stdinFailed: !spawnOutcome.result.deadlineExceeded,
    );
  }
  final waitFuture = waitForSecureSpawnedProcess(process.pid).then(
    _QuickLookNativeProcessExited.new,
    onError: (Object _, StackTrace _) =>
        const _QuickLookNativeProcessExited(null),
  );
  final first = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      waitFuture,
      cancellation.whenCancelled.then((_) => _QuickLookProcessEvent.cancelled),
      _deadlineFuture(deadline, _QuickLookProcessEvent.deadline),
    ],
  );
  if (first case _QuickLookNativeProcessExited(:final exit)) {
    return (
      exitCode: exit?.exitCode ?? -1,
      timedOut: false,
      outputExceeded: false,
      stdinFailed: exit == null,
    );
  }

  final exit = await _terminateAndReapNativeQuickLookProcess(
    process.pid,
    waitFuture: waitFuture,
    deadline: deadline,
  );
  return (
    exitCode: exit?.exitCode ?? -1,
    timedOut: first == _QuickLookProcessEvent.deadline,
    outputExceeded: false,
    stdinFailed: false,
  );
}

Future<SecureProcessExit?> _terminateAndReapNativeQuickLookProcess(
  int pid, {
  required Future<_QuickLookNativeProcessExited> waitFuture,
  required DateTime deadline,
}) async {
  await signalSecureSpawnedProcessGroup(
    pid,
    ProcessSignal.sigterm.signalNumber,
  );
  final termDeadline = _earlierDeadline(
    deadline,
    DateTime.now().add(const Duration(milliseconds: 250)),
  );
  final termOutcome = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      waitFuture,
      _deadlineFuture(termDeadline, _QuickLookProcessEvent.deadline),
    ],
  );
  if (termOutcome case _QuickLookNativeProcessExited(:final exit)) return exit;

  await signalSecureSpawnedProcessGroup(
    pid,
    ProcessSignal.sigkill.signalNumber,
  );
  final reapDeadline = _earlierDeadline(
    deadline,
    DateTime.now().add(const Duration(milliseconds: 250)),
  );
  final reapOutcome = await Future.any<_QuickLookProcessEvent>(
    <Future<_QuickLookProcessEvent>>[
      waitFuture,
      _deadlineFuture(reapDeadline, _QuickLookProcessEvent.deadline),
    ],
  );
  if (reapOutcome case _QuickLookNativeProcessExited(:final exit)) return exit;
  unawaited(
    waitFuture.catchError(
      (Object _, StackTrace _) => const _QuickLookNativeProcessExited(null),
    ),
  );
  return null;
}

void _detachAndReapLateNativeQuickLookProcess(
  SecureProcessSpawnResult spawnResult,
) {
  final process = spawnResult.process;
  if (process == null) return;
  final waitFuture = waitForSecureSpawnedProcess(process.pid).then(
    _QuickLookNativeProcessExited.new,
    onError: (Object _, StackTrace _) =>
        const _QuickLookNativeProcessExited(null),
  );
  unawaited(
    _terminateAndReapNativeQuickLookProcess(
      process.pid,
      waitFuture: waitFuture,
      deadline: DateTime.now().add(const Duration(milliseconds: 500)),
    ).catchError((Object _, StackTrace _) => null),
  );
}

Future<void> _writeQuickLookStdin(Process process, Uint8List inputBytes) async {
  final stdin = process.stdin;
  stdin.add(inputBytes);
  await stdin.close();
}

sealed class _QuickLookProcessEvent {
  const _QuickLookProcessEvent();

  static const exited = _QuickLookNamedProcessEvent('exited');
  static const drained = _QuickLookNamedProcessEvent('drained');
  static const outputExceeded = _QuickLookNamedProcessEvent('outputExceeded');
  static const stdinFailed = _QuickLookNamedProcessEvent('stdinFailed');
  static const cancelled = _QuickLookNamedProcessEvent('cancelled');
  static const deadline = _QuickLookNamedProcessEvent('deadline');
}

final class _QuickLookNamedProcessEvent extends _QuickLookProcessEvent {
  const _QuickLookNamedProcessEvent(this.name);

  final String name;
}

final class _QuickLookProcessStarted extends _QuickLookProcessEvent {
  _QuickLookProcessStarted(this.process);

  final Process process;
}

final class _QuickLookProcessCompleted extends _QuickLookProcessEvent {
  _QuickLookProcessCompleted(this.exitCode);

  final int exitCode;
}

final class _QuickLookNativeSpawnCompleted extends _QuickLookProcessEvent {
  _QuickLookNativeSpawnCompleted(this.result);

  final SecureProcessSpawnResult result;
}

final class _QuickLookNativeProcessExited extends _QuickLookProcessEvent {
  const _QuickLookNativeProcessExited(this.exit);

  final SecureProcessExit? exit;
}

final class _QuickLookProcessStartFailed extends _QuickLookProcessEvent {
  _QuickLookProcessStartFailed(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

Future<T> _deadlineFuture<T>(DateTime deadline, T value) =>
    Future<T>.delayed(_remainingUntil(deadline), () => value);

Duration _remainingUntil(DateTime deadline) {
  final remaining = deadline.difference(DateTime.now());
  return remaining.isNegative ? Duration.zero : remaining;
}

DateTime _earlierDeadline(DateTime left, DateTime right) =>
    left.isBefore(right) ? left : right;

void _detachAndKillLateQuickLookProcess(Process process) {
  unawaited(
    Future<void>.sync(
      () => process.stdin.close(),
    ).catchError((Object _, StackTrace _) {}),
  );
  final stdout = process.stdout.listen(
    (_) {},
    onError: (Object _, StackTrace _) {},
    cancelOnError: false,
  );
  final stderr = process.stderr.listen(
    (_) {},
    onError: (Object _, StackTrace _) {},
    cancelOnError: false,
  );
  process.kill();
  final forceKill = Timer(const Duration(milliseconds: 250), () {
    process.kill(ProcessSignal.sigkill);
  });
  final detach = Timer(const Duration(seconds: 1), () {
    unawaited(stdout.cancel().catchError((_) {}));
    unawaited(stderr.cancel().catchError((_) {}));
  });
  unawaited(
    process.exitCode.then<void>((_) {
      forceKill.cancel();
      detach.cancel();
      unawaited(stdout.cancel().catchError((_) {}));
      unawaited(stderr.cancel().catchError((_) {}));
    }, onError: (Object _, StackTrace _) {}),
  );
}

final class _QuickLookPipeDrain {
  _QuickLookPipeDrain(Stream<List<int>> stream, {required this.outputCounter}) {
    _subscription = stream.listen(
      _onData,
      onError: (_, _) => _complete(),
      onDone: _complete,
      cancelOnError: false,
    );
  }

  final _QuickLookOutputCounter outputCounter;
  final Completer<void> _done = Completer<void>();
  late final StreamSubscription<List<int>> _subscription;
  bool _detached = false;

  Future<void> get done => _done.future;

  void _onData(List<int> chunk) {
    outputCounter.add(chunk.length);
  }

  void _complete() {
    if (!_done.isCompleted) _done.complete();
  }

  void detach() {
    if (_detached) return;
    _detached = true;
    unawaited(_subscription.cancel().catchError((_) {}));
    _complete();
  }
}

final class _QuickLookOutputCounter {
  final Completer<void> _reached = Completer<void>();
  int _bytes = 0;

  Future<void> get reached => _reached.future;

  void add(int bytes) {
    if (_reached.isCompleted) return;
    _bytes += bytes;
    if (_bytes > filePreviewQuickLookProcessOutputByteLimit) {
      _reached.complete();
    }
  }
}

String _textTypeLabel(String path) {
  return switch (p.extension(path).toLowerCase()) {
    '.dart' => 'Dart',
    '.json' || '.jsonl' => 'JSON',
    '.yaml' || '.yml' => 'YAML',
    '.csv' => 'CSV',
    '.tsv' => 'TSV',
    '.js' || '.jsx' => 'JavaScript',
    '.ts' || '.tsx' => 'TypeScript',
    '.py' => 'Python',
    '.swift' => 'Swift',
    '.go' => 'Go',
    '.rs' => 'Rust',
    '.html' || '.htm' => 'HTML',
    '.css' || '.scss' => 'CSS',
    '.xml' => 'XML',
    '.sql' => 'SQL',
    _ => '文本',
  };
}

String _quickLookTypeLabel(String path) {
  return switch (p.extension(path).toLowerCase()) {
    '.pdf' => 'PDF',
    '.doc' || '.docx' || '.pages' || '.rtf' => '文档',
    '.xls' || '.xlsx' || '.numbers' => '表格',
    '.ppt' || '.pptx' || '.key' => '演示文稿',
    '.mov' || '.mp4' || '.m4v' => '视频',
    '.mp3' || '.m4a' || '.wav' || '.aac' => '音频',
    _ => 'Quick Look',
  };
}
