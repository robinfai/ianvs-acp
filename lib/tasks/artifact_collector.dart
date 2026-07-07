import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'task_record.dart';

typedef ArtifactCollectorClock = DateTime Function();
typedef ArtifactCollectorIdGenerator = String Function(String prefix);

const int defaultArtifactPreviewLimit = 64 * 1024;

class ArtifactCollector {
  ArtifactCollector({
    this.previewLimit = defaultArtifactPreviewLimit,
    ArtifactCollectorClock? clock,
    this.idGenerator,
  }) : _clock = clock ?? DateTime.now;

  final int previewLimit;
  final ArtifactCollectorClock _clock;
  final ArtifactCollectorIdGenerator? idGenerator;
  int _idCounter = 0;

  Future<List<ArtifactRecord>> collect(
    TaskRecord task,
    TaskRunRecord run,
  ) async {
    final workspace = Directory(task.workspacePath);
    if (!workspace.existsSync()) return const <ArtifactRecord>[];

    final artifacts = <ArtifactRecord>[];
    if (await _isGitWorkspace(workspace.path)) {
      final status = await _runGit(workspace.path, const [
        'status',
        '--porcelain',
      ]);
      if (status != null && status.stdout.trim().isNotEmpty) {
        artifacts.add(
          _artifact(
            task: task,
            run: run,
            kind: ArtifactKind.gitStatus,
            title: 'Git status',
            contentPreview: _previewForText(status.stdout),
            metadata: _metadataForGitCommand(const [
              'git',
              'status',
              '--porcelain',
            ], status.stdout),
          ),
        );
      }

      final diffStat = await _runGit(workspace.path, const ['diff', '--stat']);
      if (diffStat != null && diffStat.stdout.trim().isNotEmpty) {
        artifacts.add(
          _artifact(
            task: task,
            run: run,
            kind: ArtifactKind.gitDiff,
            title: 'Git diff stat',
            contentPreview: _previewForText(diffStat.stdout),
            metadata: _metadataForGitCommand(const [
              'git',
              'diff',
              '--stat',
            ], diffStat.stdout),
          ),
        );
      }

      final diff = await _runGit(workspace.path, const ['diff']);
      if (diff != null && diff.stdout.trim().isNotEmpty) {
        artifacts.add(
          _artifact(
            task: task,
            run: run,
            kind: ArtifactKind.gitDiff,
            title: 'Git diff preview',
            contentPreview: _previewForText(diff.stdout),
            metadata: _metadataForGitCommand(const [
              'git',
              'diff',
            ], diff.stdout),
          ),
        );
      }
    }

    artifacts.addAll(await _collectOutbox(task, run, workspace));
    return List.unmodifiable(artifacts);
  }

  Future<bool> _isGitWorkspace(String workspacePath) async {
    final result = await _runGit(workspacePath, const [
      'rev-parse',
      '--is-inside-work-tree',
    ]);
    return result != null && result.stdout.trim() == 'true';
  }

  Future<_GitResult?> _runGit(String workspacePath, List<String> args) async {
    try {
      final result = await Process.run(
        'git',
        ['-C', workspacePath, ...args],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
      if (result.exitCode != 0) return null;
      return _GitResult('${result.stdout}', '${result.stderr}');
    } on Object {
      return null;
    }
  }

  Future<List<ArtifactRecord>> _collectOutbox(
    TaskRecord task,
    TaskRunRecord run,
    Directory workspace,
  ) async {
    final outbox = Directory(
      _joinPath(workspace.path, '.ianvs', 'outbox', task.id),
    );
    if (!outbox.existsSync()) return const <ArtifactRecord>[];

    final files = <File>[];
    try {
      await for (final entity in outbox.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) files.add(entity);
      }
    } on Object {
      return const <ArtifactRecord>[];
    }
    files.sort((a, b) => a.path.compareTo(b.path));

    final artifacts = <ArtifactRecord>[];
    for (final file in files) {
      final record = await _artifactForOutboxFile(task, run, workspace, file);
      if (record != null) artifacts.add(record);
    }
    return artifacts;
  }

  Future<ArtifactRecord?> _artifactForOutboxFile(
    TaskRecord task,
    TaskRunRecord run,
    Directory workspace,
    File file,
  ) async {
    try {
      final stat = await file.stat();
      final size = stat.size;
      final relativePath = _relativePath(workspace.path, file.path);
      final preview = await _previewForFile(file, size);
      final digest = await sha256.bind(file.openRead()).first;
      return _artifact(
        task: task,
        run: run,
        kind: ArtifactKind.outboxFile,
        title: relativePath,
        path: relativePath,
        contentPreview: preview.text,
        sha256: digest.toString(),
        sizeBytes: size,
        metadata: <String, Object?>{
          'source': 'outbox',
          'relative_path': relativePath,
          'preview_limit_bytes': previewLimit,
          'truncated': preview.truncated,
          'binary': preview.binary,
        },
      );
    } on Object {
      return null;
    }
  }

  ArtifactRecord _artifact({
    required TaskRecord task,
    required TaskRunRecord run,
    required ArtifactKind kind,
    required String title,
    String? path,
    String? contentPreview,
    String? sha256,
    int? sizeBytes,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return ArtifactRecord(
      id: _newId(),
      taskId: task.id,
      runId: run.id,
      kind: kind,
      title: title,
      createdAt: _clock(),
      path: path,
      contentPreview: contentPreview,
      sha256: sha256,
      sizeBytes: sizeBytes,
      metadata: Map.unmodifiable(metadata),
    );
  }

  String _newId() {
    final generated =
        idGenerator?.call('artifact') ?? 'artifact-${_idCounter++}';
    final id = generated.trim();
    if (id.isEmpty) return 'artifact-${_idCounter++}';
    return id;
  }

  Map<String, Object?> _metadataForGitCommand(
    List<String> command,
    String stdout,
  ) {
    return <String, Object?>{
      'source': 'git',
      'command': command,
      'preview_limit_bytes': previewLimit,
      'truncated': _isTextTruncated(stdout),
    };
  }

  String _previewForText(String value) {
    final bytes = utf8.encode(value);
    if (bytes.length <= previewLimit) return value;
    return utf8.decode(bytes.take(previewLimit).toList(), allowMalformed: true);
  }

  bool _isTextTruncated(String value) {
    return utf8.encode(value).length > previewLimit;
  }

  Future<_FilePreview> _previewForFile(File file, int size) async {
    final bytesToRead = math.min(size, previewLimit + 1);
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, bytesToRead)) {
      bytes.addAll(chunk);
    }
    final truncated = size > previewLimit || bytes.length > previewLimit;
    final previewBytes = truncated
        ? bytes.take(previewLimit).toList(growable: false)
        : bytes;
    final binary = previewBytes.contains(0);
    if (binary) {
      return _FilePreview(text: null, truncated: truncated, binary: binary);
    }
    return _FilePreview(
      text: utf8.decode(previewBytes, allowMalformed: true),
      truncated: truncated,
      binary: binary,
    );
  }
}

class _GitResult {
  const _GitResult(this.stdout, this.stderr);

  final String stdout;
  final String stderr;
}

class _FilePreview {
  const _FilePreview({
    required this.text,
    required this.truncated,
    required this.binary,
  });

  final String? text;
  final bool truncated;
  final bool binary;
}

String _joinPath(String first, String second, [String? third, String? fourth]) {
  final parts = [first, second, ?third, ?fourth];
  return parts
      .where((part) => part.isNotEmpty)
      .join(Platform.pathSeparator)
      .replaceAll(
        RegExp('${RegExp.escape(Platform.pathSeparator)}+'),
        Platform.pathSeparator,
      );
}

String _relativePath(String rootPath, String filePath) {
  final normalizedRoot = _withoutTrailingSeparator(
    File(rootPath).absolute.path,
  );
  final normalizedFile = File(filePath).absolute.path;
  final prefix = '$normalizedRoot${Platform.pathSeparator}';
  if (!normalizedFile.startsWith(prefix)) return normalizedFile;
  return normalizedFile.substring(prefix.length);
}

String _withoutTrailingSeparator(String path) {
  var value = path;
  while (value.endsWith(Platform.pathSeparator) &&
      value.length > Platform.pathSeparator.length) {
    value = value.substring(0, value.length - Platform.pathSeparator.length);
  }
  return value;
}
