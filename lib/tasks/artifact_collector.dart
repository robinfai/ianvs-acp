import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../platform/secure_file_reader.dart';
import 'task_data_sanitizer.dart';
import 'task_record.dart';

typedef ArtifactCollectorClock = DateTime Function();
typedef ArtifactCollectorIdGenerator = String Function(String prefix);
typedef ArtifactCollectorNonceGenerator = List<int> Function(int length);
typedef ArtifactCollectorBeforeSecureRead =
    FutureOr<void> Function(String relativePath);

const int defaultArtifactPreviewLimit = 64 * 1024;

class ArtifactCollector {
  ArtifactCollector({
    this.previewLimit = defaultArtifactPreviewLimit,
    ArtifactCollectorClock? clock,
    this.idGenerator,
    this.nonceGenerator,
    this.beforeSecureRead,
    TaskDataSanitizer? dataSanitizer,
  }) : _clock = clock ?? DateTime.now,
       dataSanitizer = dataSanitizer ?? const TaskDataSanitizer(),
       _random = math.Random.secure();

  final int previewLimit;
  final ArtifactCollectorClock _clock;
  final ArtifactCollectorIdGenerator? idGenerator;
  final ArtifactCollectorNonceGenerator? nonceGenerator;
  final ArtifactCollectorBeforeSecureRead? beforeSecureRead;
  final TaskDataSanitizer dataSanitizer;
  final math.Random _random;
  final Set<String> _issuedDefaultIds = <String>{};

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
    final ianvsDirectory = Directory(_joinPath(workspace.path, '.ianvs'));
    final outboxParent = Directory(
      _joinPath(workspace.path, '.ianvs', 'outbox'),
    );
    final outbox = Directory(
      _joinPath(workspace.path, '.ianvs', 'outbox', task.id),
    );
    if (!outbox.existsSync()) return const <ArtifactRecord>[];

    late final String resolvedWorkspacePath;
    late final String resolvedOutboxPath;
    try {
      for (final directory in <Directory>[
        ianvsDirectory,
        outboxParent,
        outbox,
      ]) {
        final type = await FileSystemEntity.type(
          directory.path,
          followLinks: false,
        );
        if (type == FileSystemEntityType.link) {
          return const <ArtifactRecord>[];
        }
      }
      resolvedWorkspacePath = await workspace.resolveSymbolicLinks();
      resolvedOutboxPath = await outbox.resolveSymbolicLinks();
    } on Object {
      return const <ArtifactRecord>[];
    }
    if (!_isPathWithin(resolvedWorkspacePath, resolvedOutboxPath)) {
      return const <ArtifactRecord>[];
    }

    final relativePaths = <String>[];
    try {
      await for (final entity in outbox.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        relativePaths.add(_relativePath(workspace.path, entity.path));
      }
    } on Object {
      return const <ArtifactRecord>[];
    }
    relativePaths.sort();

    final artifacts = <ArtifactRecord>[];
    for (final relativePath in relativePaths) {
      await beforeSecureRead?.call(relativePath);
      final record = await _artifactForOutboxFile(
        task,
        run,
        resolvedWorkspacePath,
        relativePath,
      );
      if (record != null) artifacts.add(record);
    }
    return artifacts;
  }

  Future<ArtifactRecord?> _artifactForOutboxFile(
    TaskRecord task,
    TaskRunRecord run,
    String resolvedWorkspacePath,
    String relativePath,
  ) async {
    final read = await readWorkspaceFileSecurely(
      resolvedWorkspacePath: resolvedWorkspacePath,
      relativePath: relativePath,
      previewLimit: previewLimit,
    );
    if (read == null) return null;
    final binary = read.previewBytes.contains(0);
    final contentPreview = binary
        ? null
        : utf8.decode(read.previewBytes, allowMalformed: true);
    return _artifact(
      task: task,
      run: run,
      kind: ArtifactKind.outboxFile,
      title: relativePath,
      path: relativePath,
      contentPreview: contentPreview,
      sha256: read.sha256,
      sizeBytes: read.sizeBytes,
      metadata: <String, Object?>{
        'source': 'outbox',
        'relative_path': relativePath,
        'preview_limit_bytes': previewLimit,
        'truncated': read.sizeBytes > previewLimit,
        'binary': binary,
      },
    );
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
      id: _newId(task: task, run: run),
      taskId: task.id,
      runId: run.id,
      kind: kind,
      title: title,
      createdAt: _clock(),
      path: path,
      contentPreview: contentPreview,
      sha256: sha256,
      sizeBytes: sizeBytes,
      metadata: dataSanitizer.sanitize(metadata),
    );
  }

  String _newId({required TaskRecord task, required TaskRunRecord run}) {
    final id = idGenerator?.call('artifact').trim();
    if (id != null && id.isNotEmpty) return id;
    for (var attempt = 0; attempt < 100; attempt += 1) {
      final nonce = _generateNonce(16);
      final encodedNonce = base64UrlEncode(nonce).replaceAll('=', '');
      final id = 'artifact-${task.id}-${run.id}-$encodedNonce';
      if (_issuedDefaultIds.add(id)) return id;
    }
    throw StateError('Could not generate a unique artifact id.');
  }

  List<int> _generateNonce(int length) {
    final nonce =
        nonceGenerator?.call(length) ??
        List<int>.generate(length, (_) => _random.nextInt(256));
    if (nonce.length != length || nonce.any((byte) => byte < 0 || byte > 255)) {
      throw StateError(
        'Artifact nonce generator must return exactly $length bytes.',
      );
    }
    return nonce;
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
}

class _GitResult {
  const _GitResult(this.stdout, this.stderr);

  final String stdout;
  final String stderr;
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

bool _isPathWithin(String rootPath, String candidatePath) {
  var root = _withoutTrailingSeparator(File(rootPath).absolute.path);
  var candidate = File(candidatePath).absolute.path;
  if (Platform.isWindows) {
    root = root.toLowerCase();
    candidate = candidate.toLowerCase();
  }
  return candidate == root ||
      candidate.startsWith('$root${Platform.pathSeparator}');
}
