import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/artifact_collector.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

void main() {
  test(
    'ArtifactCollector ignores non-git workspace without throwing',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-nongit-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final collector = ArtifactCollector(
        clock: () => DateTime(2026, 7, 7, 8),
        idGenerator: _ids().next,
      );

      final artifacts = await collector.collect(_task(workspace.path), _run());

      expect(artifacts, isEmpty);
    },
  );

  test('ArtifactCollector records git status and diff artifacts', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-git-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _initGitRepo(workspace);
    final file = File('${workspace.path}/note.txt');
    await file.writeAsString('before\n');
    await _git(workspace, ['add', 'note.txt']);
    await _git(workspace, ['commit', '-m', 'initial']);
    await file.writeAsString('after\n');

    final collector = ArtifactCollector(
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: _ids().next,
    );

    final artifacts = await collector.collect(_task(workspace.path), _run());

    final status = artifacts.singleWhere(
      (artifact) => artifact.kind == ArtifactKind.gitStatus,
    );
    expect(status.title, 'Git status');
    expect(status.contentPreview, contains('M note.txt'));
    expect(status.metadata['command'], ['git', 'status', '--porcelain']);

    final diffStat = artifacts.singleWhere(
      (artifact) => artifact.title == 'Git diff stat',
    );
    expect(diffStat.kind, ArtifactKind.gitDiff);
    expect(diffStat.contentPreview, contains('note.txt'));

    final diff = artifacts.singleWhere(
      (artifact) => artifact.title == 'Git diff preview',
    );
    expect(diff.kind, ArtifactKind.gitDiff);
    expect(diff.contentPreview, contains('-before'));
    expect(diff.contentPreview, contains('+after'));
  });

  test('ArtifactCollector records outbox file hash size and preview', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-outbox-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    const content = 'export candidate\n';
    await File('${outbox.path}/report.md').writeAsString(content);

    final collector = ArtifactCollector(
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: _ids().next,
    );

    final artifacts = await collector.collect(_task(workspace.path), _run());

    final outboxArtifact = artifacts.single;
    expect(outboxArtifact.kind, ArtifactKind.outboxFile);
    expect(outboxArtifact.path, '.ianvs/outbox/task-1/report.md');
    expect(outboxArtifact.sizeBytes, utf8.encode(content).length);
    expect(
      outboxArtifact.sha256,
      sha256.convert(utf8.encode(content)).toString(),
    );
    expect(outboxArtifact.contentPreview, content);
    expect(outboxArtifact.metadata['truncated'], isFalse);
    expect(outboxArtifact.metadata['binary'], isFalse);
  });

  test('ArtifactCollector truncates large diff and outbox previews', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-large-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _initGitRepo(workspace);
    final tracked = File('${workspace.path}/large.txt');
    await tracked.writeAsString('small\n');
    await _git(workspace, ['add', 'large.txt']);
    await _git(workspace, ['commit', '-m', 'initial']);
    await tracked.writeAsString(List.filled(30, 'changed\n').join());

    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File(
      '${outbox.path}/large.md',
    ).writeAsString(List.filled(80, 'x').join());

    final collector = ArtifactCollector(
      previewLimit: 24,
      clock: () => DateTime(2026, 7, 7, 8),
      idGenerator: _ids().next,
    );

    final artifacts = await collector.collect(_task(workspace.path), _run());

    final diff = artifacts.singleWhere(
      (artifact) => artifact.title == 'Git diff preview',
    );
    expect(utf8.encode(diff.contentPreview!).length, lessThanOrEqualTo(24));
    expect(diff.metadata['truncated'], isTrue);

    final file = artifacts.singleWhere(
      (artifact) => artifact.kind == ArtifactKind.outboxFile,
    );
    expect(utf8.encode(file.contentPreview!).length, lessThanOrEqualTo(24));
    expect(file.metadata['truncated'], isTrue);
  });
}

TaskRecord _task(String workspacePath) {
  return TaskRecord(
    id: 'task-1',
    title: 'Collect artifacts',
    description: '',
    workspacePath: workspacePath,
    agentName: 'Codex',
    status: TaskStatus.collectingArtifacts,
    priority: TaskPriority.normal,
    createdAt: DateTime(2026, 7, 7, 8),
    updatedAt: DateTime(2026, 7, 7, 8),
    currentRunId: 'run-1',
  );
}

TaskRunRecord _run() {
  return TaskRunRecord(
    id: 'run-1',
    taskId: 'task-1',
    attempt: 1,
    status: TaskStatus.running,
    startedAt: DateTime(2026, 7, 7, 8),
  );
}

Future<void> _initGitRepo(Directory workspace) async {
  await _git(workspace, ['init']);
  await _git(workspace, ['config', 'user.email', 'test@example.com']);
  await _git(workspace, ['config', 'user.name', 'Test User']);
}

Future<void> _git(Directory workspace, List<String> args) async {
  final result = await Process.run(
    'git',
    ['-C', workspace.path, ...args],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  expect(
    result.exitCode,
    0,
    reason:
        'git ${args.join(' ')} failed\nstdout: ${result.stdout}\nstderr: ${result.stderr}',
  );
}

_Ids _ids() => _Ids();

class _Ids {
  int _count = 0;

  String next(String prefix) {
    _count += 1;
    return '$prefix-$_count';
  }
}
