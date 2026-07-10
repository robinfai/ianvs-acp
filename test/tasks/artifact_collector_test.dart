import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/artifact_collector.dart';
import 'package:ianvs_acp/tasks/task_data_sanitizer.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
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

  test(
    'ArtifactCollector rejects an outbox symlink outside workspace',
    () async {
      if (Platform.isWindows) return;
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-outbox-link-',
      );
      final external = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-external-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      addTearDown(() => external.delete(recursive: true));
      await File('${external.path}/secret.txt').writeAsString('outside secret');
      final outboxParent = Directory('${workspace.path}/.ianvs/outbox');
      await outboxParent.create(recursive: true);
      await Link(
        '${outboxParent.path}/task-1',
      ).create(external.path, recursive: false);
      final collector = ArtifactCollector(idGenerator: _ids().next);

      final artifacts = await collector.collect(_task(workspace.path), _run());

      expect(artifacts, isEmpty);
    },
  );

  test(
    'ArtifactCollector rejects a file replaced by a symlink before open',
    () async {
      if (!Platform.isMacOS && !Platform.isLinux) return;
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-file-swap-',
      );
      final external = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-file-swap-external-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      addTearDown(() => external.delete(recursive: true));
      final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
      await outbox.create(recursive: true);
      final candidate = File('${outbox.path}/report.md');
      await candidate.writeAsString('safe candidate');
      final secret = File('${external.path}/secret.txt');
      await secret.writeAsString('outside secret');
      var replaced = false;
      final collector = ArtifactCollector(
        idGenerator: _ids().next,
        beforeSecureRead: (_) async {
          await candidate.delete();
          await Link(candidate.path).create(secret.path);
          replaced = true;
        },
      );

      final artifacts = await collector.collect(_task(workspace.path), _run());

      expect(replaced, isTrue);
      expect(artifacts, isEmpty);
    },
  );

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

  test(
    'ArtifactCollector default ids are task and run scoped across restarts',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-ids-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
      await outbox.create(recursive: true);
      await File('${outbox.path}/report.md').writeAsString('candidate');
      final task = _task(workspace.path);
      final firstRun = _run();
      final secondRun = TaskRunRecord(
        id: 'run-2',
        taskId: task.id,
        attempt: 2,
        status: TaskStatus.running,
        startedAt: DateTime(2026, 7, 7, 9),
      );

      final first = await ArtifactCollector().collect(task, firstRun);
      final second = await ArtifactCollector().collect(task, secondRun);

      expect(first.single.id, startsWith('artifact-task-1-run-1-'));
      expect(second.single.id, startsWith('artifact-task-1-run-2-'));
      expect(second.single.id, isNot(first.single.id));
      expect(
        first.single.id.substring('artifact-task-1-run-1-'.length),
        matches(RegExp(r'^[A-Za-z0-9_-]{22}$')),
      );
      expect(
        second.single.id.substring('artifact-task-1-run-2-'.length),
        matches(RegExp(r'^[A-Za-z0-9_-]{22}$')),
      );

      final saved = TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 10),
        tasks: <TaskRecord>[
          task.copyWith(status: TaskStatus.running, currentRunId: secondRun.id),
        ],
        runs: <TaskRunRecord>[firstRun, secondRun],
        artifacts: <ArtifactRecord>[first.single, second.single],
      );
      final reloaded = TaskInboxSnapshot.fromJsonStrict(saved.toJson());

      expect(reloaded.artifacts.map((artifact) => artifact.id), <String>[
        first.single.id,
        second.single.id,
      ]);
    },
  );

  test(
    'ArtifactCollector instances use different ids for the same task run',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-same-run-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
      await outbox.create(recursive: true);
      await File('${outbox.path}/report.md').writeAsString('candidate');

      final first = await ArtifactCollector().collect(
        _task(workspace.path),
        _run(),
      );
      final second = await ArtifactCollector().collect(
        _task(workspace.path),
        _run(),
      );

      expect(first.single.id, isNot(second.single.id));
      expect(first.single.id, startsWith('artifact-task-1-run-1-'));
      expect(second.single.id, startsWith('artifact-task-1-run-1-'));
    },
  );

  test(
    'ArtifactCollector gives every artifact in one run a unique id',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-multiple-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
      await outbox.create(recursive: true);
      await File('${outbox.path}/first.md').writeAsString('first');
      await File('${outbox.path}/second.md').writeAsString('second');

      final artifacts = await ArtifactCollector().collect(
        _task(workspace.path),
        _run(),
      );

      expect(artifacts, hasLength(2));
      expect(
        artifacts.map((artifact) => artifact.id).toSet(),
        hasLength(artifacts.length),
      );
    },
  );

  test(
    'ArtifactCollector preserves injected ids and the artifact prefix',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-injected-id-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
      await outbox.create(recursive: true);
      await File('${outbox.path}/report.md').writeAsString('candidate');
      final prefixes = <String>[];
      final collector = ArtifactCollector(
        idGenerator: (prefix) {
          prefixes.add(prefix);
          return ' custom:Artifact_ID ';
        },
      );

      final artifacts = await collector.collect(_task(workspace.path), _run());

      expect(prefixes, <String>['artifact']);
      expect(artifacts.single.id, 'custom:Artifact_ID');

      final saved = TaskInboxSnapshot(
        updatedAt: DateTime(2026, 7, 7, 10),
        tasks: <TaskRecord>[_task(workspace.path)],
        runs: <TaskRunRecord>[_run()],
        artifacts: artifacts,
      );
      final restored = TaskInboxSnapshot.fromJsonStrict(saved.toJson());
      expect(restored.artifacts.single.id, 'custom:Artifact_ID');
    },
  );

  test('ArtifactCollector retries a repeated generated nonce', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-nonce-retry-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File('${outbox.path}/report.md').writeAsString('candidate');
    final requestedLengths = <int>[];
    var nonceCalls = 0;
    final collector = ArtifactCollector(
      nonceGenerator: (length) {
        requestedLengths.add(length);
        nonceCalls += 1;
        return List<int>.filled(length, nonceCalls <= 2 ? 0 : 1);
      },
    );

    final first = await collector.collect(_task(workspace.path), _run());
    final second = await collector.collect(_task(workspace.path), _run());

    expect(first.single.id, isNot(second.single.id));
    expect(nonceCalls, 3);
    expect(requestedLengths, <int>[16, 16, 16]);
  });

  test('ArtifactCollector fails after one hundred nonce collisions', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-nonce-collisions-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File('${outbox.path}/report.md').writeAsString('candidate');
    var nonceCalls = 0;
    final collector = ArtifactCollector(
      nonceGenerator: (length) {
        nonceCalls += 1;
        return List<int>.filled(length, 7);
      },
    );
    final first = await collector.collect(_task(workspace.path), _run());
    expect(first, hasLength(1));

    await expectLater(
      collector.collect(_task(workspace.path), _run()),
      throwsA(isA<StateError>()),
    );
    expect(nonceCalls, 101);
  });

  test('ArtifactCollector rejects a nonce that is not sixteen bytes', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-invalid-nonce-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File('${outbox.path}/report.md').writeAsString('candidate');
    final collector = ArtifactCollector(
      nonceGenerator: (length) => List<int>.filled(length - 1, 0),
    );

    await expectLater(
      collector.collect(_task(workspace.path), _run()),
      throwsA(isA<StateError>()),
    );
  });

  test('ArtifactCollector caps oversized artifact metadata', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-metadata-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File('${outbox.path}/report.md').writeAsString('candidate');
    final collector = ArtifactCollector(
      dataSanitizer: const TaskDataSanitizer(maxMetadataBytes: 8),
      idGenerator: _ids().next,
    );

    final artifacts = await collector.collect(_task(workspace.path), _run());

    expect(artifacts.single.metadata['truncated'], isTrue);
    expect(artifacts.single.metadata['original_bytes'], greaterThan(8));
    expect(artifacts.single.metadata['sha256'], hasLength(64));
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
