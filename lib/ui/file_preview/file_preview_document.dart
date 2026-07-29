import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;

typedef FilePreviewProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

const int filePreviewTextByteLimit = 4 * 1024 * 1024;

enum FilePreviewKind { markdown, text, image, quickLook, unsupported }

final class FilePreviewTarget {
  const FilePreviewTarget({
    required this.path,
    required this.workspacePath,
    this.line,
  });

  final String path;
  final String workspacePath;
  final int? line;

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
  var allowed = false;
  for (final root in allowedRoots) {
    final resolvedRoot = await _resolveDirectoryIfPossible(root);
    if (p.equals(resolvedRoot, resolvedPath) ||
        p.isWithin(resolvedRoot, resolvedPath)) {
      allowed = true;
      break;
    }
  }
  if (!allowed) {
    throw FileSystemException('文件不在当前工作区或已授权目录中', resolvedPath);
  }

  return FilePreviewTarget(
    path: resolvedPath,
    workspacePath: resolvedWorkspace,
    line: line == null || line < 1 ? null : line,
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
  FilePreviewProcessRunner? processRunner,
}) async {
  final file = File(target.path);
  final stat = await file.stat();
  final prefix = await _readPrefix(file, 64);
  final mimeType =
      mime.lookupMimeType(target.path, headerBytes: prefix) ??
      'application/octet-stream';
  final kind = classifyFilePreview(target.path, mimeType);

  if (kind == FilePreviewKind.markdown || kind == FilePreviewKind.text) {
    final result = await _readTextPreview(file, stat.size);
    return FilePreviewDocument(
      target: target,
      kind: kind,
      mimeType: mimeType,
      size: stat.size,
      text: result.text,
      textTruncated: result.truncated,
    );
  }

  if (kind == FilePreviewKind.quickLook) {
    final result = await _renderQuickLookThumbnail(
      target.path,
      processRunner: processRunner,
    );
    return FilePreviewDocument(
      target: target,
      kind: kind,
      mimeType: mimeType,
      size: stat.size,
      previewBytes: result.bytes,
      previewError: result.error,
    );
  }

  return FilePreviewDocument(
    target: target,
    kind: kind,
    mimeType: mimeType,
    size: stat.size,
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

Future<Uint8List> _readPrefix(File file, int maxBytes) async {
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, maxBytes)) {
    builder.add(chunk);
  }
  return builder.takeBytes();
}

Future<({String text, bool truncated})> _readTextPreview(
  File file,
  int size,
) async {
  final length = size < filePreviewTextByteLimit
      ? size
      : filePreviewTextByteLimit;
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.openRead(0, length)) {
    builder.add(chunk);
  }
  var bytes = builder.takeBytes();
  if (size > length) {
    while (bytes.isNotEmpty && (bytes.last & 0xc0) == 0x80) {
      bytes = Uint8List.sublistView(bytes, 0, bytes.length - 1);
    }
  }
  return (
    text: const Utf8Decoder(allowMalformed: true).convert(bytes),
    truncated: size > length,
  );
}

Future<({Uint8List? bytes, String? error})> _renderQuickLookThumbnail(
  String path, {
  FilePreviewProcessRunner? processRunner,
}) async {
  if (!Platform.isMacOS) {
    return (bytes: null, error: '当前平台暂不支持此格式的内嵌预览。');
  }
  final temporary = await Directory.systemTemp.createTemp(
    'ianvs-acp-file-preview-',
  );
  try {
    final runner = processRunner ?? Process.run;
    final result = await runner('/usr/bin/qlmanage', <String>[
      '-t',
      '-s',
      '1600',
      '-o',
      temporary.path,
      path,
    ]);
    if (result.exitCode != 0) {
      return (bytes: null, error: '系统无法生成此文件的预览。');
    }
    final generated = await temporary
        .list(followLinks: false)
        .where((entry) => entry is File)
        .cast<File>()
        .toList();
    if (generated.isEmpty) {
      return (bytes: null, error: '系统没有返回可显示的预览。');
    }
    generated.sort((a, b) => a.path.compareTo(b.path));
    return (bytes: await generated.first.readAsBytes(), error: null);
  } on FileSystemException {
    return (bytes: null, error: '系统无法生成此文件的预览。');
  } finally {
    try {
      await temporary.delete(recursive: true);
    } on FileSystemException {
      // Temporary preview cleanup must not hide the preview result.
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
