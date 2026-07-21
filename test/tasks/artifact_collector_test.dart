import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

  test(
    'ArtifactCollector records git status and diff stat by default',
    () async {
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

      expect(artifacts, hasLength(2));
      expect(
        artifacts.where((artifact) => artifact.title == 'Git diff preview'),
        isEmpty,
      );
      expect(
        artifacts.map((artifact) => artifact.contentPreview).join('\n'),
        isNot(contains('-before')),
      );
      expect(
        artifacts.map((artifact) => artifact.contentPreview).join('\n'),
        isNot(contains('+after')),
      );
    },
  );

  test(
    'ArtifactCollector retains full diff only when explicitly enabled',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-full-diff-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      await _initGitRepo(workspace);
      final file = File('${workspace.path}/note.txt');
      await file.writeAsString('before\n');
      await _git(workspace, ['add', 'note.txt']);
      await _git(workspace, ['commit', '-m', 'initial']);
      await file.writeAsString('after\n');

      final artifacts = await ArtifactCollector(idGenerator: _ids().next)
          .collect(
            _task(
              workspace.path,
              metadata: const <String, Object?>{'retain_full_diff': true},
            ),
            _run(),
          );

      final diff = artifacts.singleWhere(
        (artifact) => artifact.title == 'Git diff preview',
      );
      expect(diff.kind, ArtifactKind.gitDiff);
      expect(diff.contentPreview, contains('-before'));
      expect(diff.contentPreview, contains('+after'));
      expect(diff.metadata['raw_payload'], isTrue);
    },
  );

  test('ArtifactCollector ignores legacy outbox contents', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-legacy-outbox-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    await File('${outbox.path}/report.md').writeAsString('legacy candidate');

    final artifacts = await ArtifactCollector().collect(
      _task(workspace.path),
      _run(),
    );

    expect(artifacts, isEmpty);
  });

  test('ArtifactCollector caps retained full diff at one MiB', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-full-diff-limit-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    await _initGitRepo(workspace);
    final tracked = File('${workspace.path}/large.txt');
    await tracked.writeAsString('before\n');
    await _git(workspace, ['add', 'large.txt']);
    await _git(workspace, ['commit', '-m', 'initial']);
    await tracked.writeAsString(
      '${List.filled(140000, 'changed').join('\n')}\n',
    );

    final artifacts = await ArtifactCollector(idGenerator: _ids().next).collect(
      _task(
        workspace.path,
        metadata: const <String, Object?>{'retain_full_diff': true},
      ),
      _run(),
    );

    final diff = artifacts.singleWhere(
      (artifact) => artifact.title == 'Git diff preview',
    );
    expect(
      utf8.encode(diff.contentPreview!).length,
      lessThanOrEqualTo(1024 * 1024),
    );
    expect(diff.metadata['truncated'], isTrue);
    expect(diff.metadata['raw_payload'], isTrue);
  });

  test(
    'ArtifactCollector default ids are task and run scoped across restarts',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-ids-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      await _createDirtyGitRepo(workspace);
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
      await _createDirtyGitRepo(workspace);

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
      await _createDirtyGitRepo(workspace, includeDiff: true);

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
      await _createDirtyGitRepo(workspace);
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
    await _createDirtyGitRepo(workspace);
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
    await _createDirtyGitRepo(workspace);
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
    await _createDirtyGitRepo(workspace);
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
    await _createDirtyGitRepo(workspace);
    final collector = ArtifactCollector(
      dataSanitizer: const TaskDataSanitizer(maxMetadataBytes: 8),
      idGenerator: _ids().next,
    );

    final artifacts = await collector.collect(_task(workspace.path), _run());

    expect(artifacts.single.metadata['truncated'], isTrue);
    expect(artifacts.single.metadata['original_bytes'], greaterThan(8));
    expect(artifacts.single.metadata['sha256'], hasLength(64));
  });

  test(
    'ArtifactCollector keeps exact status bytes without truncation',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-status-exact-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final statusBytes = List<int>.filled(64 * 1024, 0x61);
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(stdoutChunks: <List<int>>[statusBytes]),
        _FakeProcess.completed(),
      ]);
      final collector = ArtifactCollector(
        previewLimit: 128 * 1024,
        processStarter: harness.start,
        idGenerator: _ids().next,
      );

      final artifacts = await collector.collect(_task(workspace.path), _run());

      final status = artifacts.single;
      expect(utf8.encode(status.contentPreview!).length, 64 * 1024);
      expect(status.metadata['truncated'], isFalse);
    },
  );

  test(
    'ArtifactCollector drains but does not retain status byte limit plus one',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-status-over-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final statusBytes = List<int>.filled(64 * 1024 + 1, 0x61);
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(stdoutChunks: <List<int>>[statusBytes]),
        _FakeProcess.completed(),
      ]);

      final artifacts = await ArtifactCollector(
        previewLimit: 128 * 1024,
        processStarter: harness.start,
        idGenerator: _ids().next,
      ).collect(_task(workspace.path), _run());

      final status = artifacts.single;
      expect(utf8.encode(status.contentPreview!).length, 64 * 1024);
      expect(status.metadata['truncated'], isTrue);
    },
  );

  test(
    'ArtifactCollector propagates stat and full diff source truncation',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-diff-source-over-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[List<int>.filled(64 * 1024 + 1, 0x73)],
        ),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[
            List<int>.filled(defaultFullDiffPreviewLimit + 1, 0x64),
          ],
        ),
      ]);

      final artifacts =
          await ArtifactCollector(
            previewLimit: 2 * 1024 * 1024,
            processStarter: harness.start,
            idGenerator: _ids().next,
          ).collect(
            _task(
              workspace.path,
              metadata: const <String, Object?>{'retain_full_diff': true},
            ),
            _run(),
          );

      final stat = artifacts.singleWhere((a) => a.title == 'Git diff stat');
      final full = artifacts.singleWhere((a) => a.title == 'Git diff preview');
      expect(utf8.encode(stat.contentPreview!).length, 64 * 1024);
      expect(stat.metadata['truncated'], isTrue);
      expect(
        utf8.encode(full.contentPreview!).length,
        defaultFullDiffPreviewLimit,
      );
      expect(full.metadata['truncated'], isTrue);
    },
  );

  test(
    'ArtifactCollector previews split and malformed UTF-8 within byte limit',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-utf8-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(
          stdoutChunks: const <List<int>>[
            <int>[0x61, 0xe2],
            <int>[0x82, 0xac, 0x62],
          ],
        ),
        _FakeProcess.completed(
          stdoutChunks: const <List<int>>[
            <int>[0x61, 0xff, 0x62],
          ],
        ),
      ]);

      final artifacts = await ArtifactCollector(
        previewLimit: 4,
        processStarter: harness.start,
        idGenerator: _ids().next,
      ).collect(_task(workspace.path), _run());

      final status = artifacts.singleWhere((a) => a.title == 'Git status');
      final stat = artifacts.singleWhere((a) => a.title == 'Git diff stat');
      expect(status.contentPreview, 'a€');
      expect(utf8.encode(status.contentPreview!).length, 4);
      expect(status.metadata['truncated'], isTrue);
      expect(utf8.encode(stat.contentPreview!).length, lessThanOrEqualTo(4));
      expect(stat.metadata['truncated'], isTrue);
    },
  );

  test('ArtifactCollector uses helper-suppressing git arguments', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-git-args-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final harness = _GitHarness(<_FakeProcess>[
      _FakeProcess.completed(stdoutChunks: <List<int>>[utf8.encode('true\n')]),
      _FakeProcess.completed(stdoutChunks: <List<int>>[utf8.encode(' M a\n')]),
      _FakeProcess.completed(
        stdoutChunks: <List<int>>[utf8.encode('a | 1 +\n')],
      ),
      _FakeProcess.completed(stdoutChunks: <List<int>>[utf8.encode('+x\n')]),
    ]);

    await ArtifactCollector(
      processStarter: harness.start,
      idGenerator: _ids().next,
    ).collect(
      _task(
        workspace.path,
        metadata: const <String, Object?>{'retain_full_diff': true},
      ),
      _run(),
    );

    expect(harness.arguments, hasLength(4));
    for (final args in harness.arguments) {
      expect(
        args,
        containsAllInOrder(<String>[
          '--no-pager',
          '-c',
          'core.fsmonitor=false',
        ]),
      );
    }
    expect(harness.arguments[1], contains('--ignore-submodules=all'));
    for (final args in harness.arguments.skip(2)) {
      expect(
        args,
        containsAll(<String>[
          '--no-ext-diff',
          '--no-textconv',
          '--ignore-submodules=all',
        ]),
      );
    }
  });

  test('ArtifactCollector waits for exit and both output streams', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-stream-order-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final status = _FakeProcess();
    final harness = _GitHarness(<_FakeProcess>[
      _FakeProcess.completed(stdoutChunks: <List<int>>[utf8.encode('true\n')]),
      status,
      _FakeProcess.completed(),
    ]);
    var settled = false;
    final collecting = ArtifactCollector(
      processStarter: harness.start,
      commandTimeout: const Duration(seconds: 1),
    ).collect(_task(workspace.path), _run()).whenComplete(() => settled = true);
    await _waitUntil(() => harness.arguments.length == 2);

    status.stdoutController.add(utf8.encode(' M a\n'));
    status.exitCodeCompleter.complete(0);
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    await status.stdoutController.close();
    await Future<void>.delayed(Duration.zero);
    expect(settled, isFalse);
    await status.stderrController.close();
    await collecting;
    expect(status.stdinClosed, isTrue);
  });

  test(
    'ArtifactCollector times out, TERM/KILLs, reaps, then continues',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-timeout-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final status = _FakeProcess(
        onKill: (signal, process) {
          if (signal == ProcessSignal.sigkill &&
              !process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-9);
          }
          return true;
        },
      );
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        status,
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('a | 1 +\n')],
        ),
      ]);

      final artifacts =
          await ArtifactCollector(
                processStarter: harness.start,
                commandTimeout: const Duration(milliseconds: 30),
                terminationGracePeriod: const Duration(milliseconds: 10),
                idGenerator: _ids().next,
              )
              .collect(_task(workspace.path), _run())
              .timeout(const Duration(seconds: 1));

      expect(status.signals, <ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(status.exitCodeAwaited, isTrue);
      expect(artifacts.single.title, 'Git diff stat');
    },
  );

  test(
    'ArtifactCollector cancels active command and starts no later work',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-cancel-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final cancellation = ArtifactCollectionCancellation();
      final status = _FakeProcess(
        onKill: (signal, process) {
          if (!process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-15);
          }
          return true;
        },
      );
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        status,
      ]);
      final collecting = ArtifactCollector(
        processStarter: harness.start,
        terminationGracePeriod: const Duration(milliseconds: 10),
      ).collect(_task(workspace.path), _run(), cancellation: cancellation);
      await _waitUntil(() => harness.arguments.length == 2);

      expect(cancellation.cancel('manual cancellation'), isTrue);
      expect(cancellation.cancel('later reason'), isFalse);

      await expectLater(
        collecting,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'manual cancellation',
          ),
        ),
      );
      expect(harness.arguments, hasLength(2));
      expect(status.signals, contains(ProcessSignal.sigterm));
      expect(status.exitCodeAwaited, isTrue);
    },
  );

  test(
    'ArtifactCollector cancellation returns before a pending start settles',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-late-start-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final cancellation = ArtifactCollectionCancellation();
      final started = Completer<Process>();
      final process = _FakeProcess(
        onKill: (signal, process) {
          if (!process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-15);
          }
          return true;
        },
      );
      final collector = ArtifactCollector(
        processStarter: (_, _, {workingDirectory}) => started.future,
        terminationGracePeriod: const Duration(milliseconds: 10),
      );
      final collecting = collector.collect(
        _task(workspace.path),
        _run(),
        cancellation: cancellation,
      );
      await Future<void>.delayed(Duration.zero);
      cancellation.cancel('cancelled before spawn');
      await expectLater(
        collecting.timeout(const Duration(seconds: 1)),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'cancelled before spawn',
          ),
        ),
      );
      expect(process.signals, isEmpty);

      started.complete(process);
      await _waitUntil(() => process.exitCodeAwaited);
      expect(process.signals, contains(ProcessSignal.sigterm));
      expect(process.exitCodeAwaited, isTrue);
    },
  );

  test(
    'ArtifactCollector timeout returns and later owns a delayed process',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-start-timeout-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final started = Completer<Process>();
      final process = _FakeProcess(
        onKill: (signal, process) {
          if (signal == ProcessSignal.sigkill &&
              !process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-9);
          }
          return true;
        },
      );
      final cancellation = ArtifactCollectionCancellation();
      final collector = ArtifactCollector(
        processStarter: (_, _, {workingDirectory}) => started.future,
        commandTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: const Duration(milliseconds: 10),
      );

      final artifacts = await collector
          .collect(_task(workspace.path), _run(), cancellation: cancellation)
          .timeout(const Duration(seconds: 1));
      expect(artifacts, isEmpty);
      cancellation.cancel('after collect returned');

      started.complete(process);
      await _waitUntil(() => process.signals.contains(ProcessSignal.sigkill));
      await _waitUntil(() => !process.stdoutController.hasListener);
      expect(process.signals, <ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(process.stdinClosed, isTrue);
      expect(process.exitCodeAwaited, isTrue);
      expect(process.stderrController.hasListener, isFalse);
    },
  );

  test(
    'ArtifactCollector drains a late process until its exit future settles',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-late-reap-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final started = Completer<Process>();
      final process = _FakeProcess(onKill: (_, _) => true);
      final collector = ArtifactCollector(
        processStarter: (_, _, {workingDirectory}) => started.future,
        commandTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: const Duration(milliseconds: 10),
      );

      expect(
        await collector
            .collect(_task(workspace.path), _run())
            .timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      started.complete(process);
      await _waitUntil(() => process.signals.contains(ProcessSignal.sigkill));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(process.stdoutController.hasListener, isTrue);
      expect(process.stderrController.hasListener, isTrue);

      process.exitCodeCompleter.complete(-9);
      await _waitUntil(() => !process.stdoutController.hasListener);
      expect(process.stderrController.hasListener, isFalse);
    },
  );

  test(
    'ArtifactCollector swallows an error from a start that settles late',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-late-start-error-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final started = Completer<Process>();
      final collector = ArtifactCollector(
        processStarter: (_, _, {workingDirectory}) => started.future,
        commandTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: const Duration(milliseconds: 10),
      );

      expect(
        await collector
            .collect(_task(workspace.path), _run())
            .timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      started.completeError(StateError('late spawn secret'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    },
  );

  test(
    'ArtifactCollector unregisters cancellation listeners after success',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-listener-cleanup-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final cancellation = ArtifactCollectionCancellation();
      final processes = <_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(),
        _FakeProcess.completed(),
      ];
      final harness = _GitHarness(processes);

      await ArtifactCollector(
        processStarter: harness.start,
      ).collect(_task(workspace.path), _run(), cancellation: cancellation);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      cancellation.cancel('too late');
      await Future<void>.delayed(Duration.zero);

      expect(processes.expand((p) => p.signals), isEmpty);
    },
  );

  test('ArtifactCollectionCancellation notifies once and supports removal', () {
    final cancellation = ArtifactCollectionCancellation();
    final reasons = <String>[];
    final remove = cancellation.addListener(reasons.add);
    remove();
    expect(cancellation.cancel('first'), isTrue);
    expect(cancellation.cancel('second'), isFalse);
    expect(reasons, isEmpty);

    cancellation.addListener(reasons.add);
    expect(reasons, <String>['first']);
    expect(cancellation.reason, 'first');
  });

  test(
    'ArtifactCollector treats start and stream failures as best effort',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-errors-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      var calls = 0;
      final collector = ArtifactCollector(
        terminationGracePeriod: const Duration(milliseconds: 10),
        processStarter: (_, _, {workingDirectory}) {
          calls += 1;
          if (calls == 1) {
            return Future<Process>.error(StateError('spawn secret'));
          }
          throw StateError('must not be called');
        },
      );

      final first = await collector.collect(_task(workspace.path), _run());
      expect(first, isEmpty);

      calls = 0;
      final rev = _FakeProcess(
        onKill: (_, process) {
          if (!process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-15);
          }
          return true;
        },
      );
      final secondCollector = ArtifactCollector(
        terminationGracePeriod: const Duration(milliseconds: 10),
        processStarter: (_, _, {workingDirectory}) {
          calls += 1;
          if (calls == 1) return Future<Process>.value(rev);
          throw StateError('must not be called');
        },
      );
      final collecting = secondCollector.collect(_task(workspace.path), _run());
      await Future<void>.delayed(Duration.zero);
      rev.stdoutController.addError(StateError('stdout secret'));
      await collecting.timeout(const Duration(seconds: 1));
      expect(rev.signals, contains(ProcessSignal.sigterm));
    },
  );

  test(
    'ArtifactCollector bounds rev-parse at exact and limit plus one',
    () async {
      for (final extraByte in <bool>[false, true]) {
        final workspace = await Directory.systemTemp.createTemp(
          'ianvs-artifacts-rev-bound-',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final probe = <int>[
          ...utf8.encode('true'),
          ...List<int>.filled(60, 0x20),
        ];
        if (extraByte) probe.add(0x78);
        final harness = _GitHarness(<_FakeProcess>[
          _FakeProcess.completed(stdoutChunks: <List<int>>[probe]),
          _FakeProcess.completed(),
          _FakeProcess.completed(),
        ]);

        await ArtifactCollector(
          processStarter: harness.start,
        ).collect(_task(workspace.path), _run());

        expect(harness.arguments, hasLength(extraByte ? 1 : 3));
      }
    },
  );

  test(
    'ArtifactCollector keeps exact stat and full diff source limits',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-diff-exact-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[List<int>.filled(64 * 1024, 0x73)],
        ),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[
            List<int>.filled(defaultFullDiffPreviewLimit, 0x64),
          ],
        ),
      ]);

      final artifacts =
          await ArtifactCollector(
            previewLimit: 2 * 1024 * 1024,
            processStarter: harness.start,
            idGenerator: _ids().next,
          ).collect(
            _task(
              workspace.path,
              metadata: const <String, Object?>{'retain_full_diff': true},
            ),
            _run(),
          );

      expect(
        artifacts
            .singleWhere((artifact) => artifact.title == 'Git diff stat')
            .metadata['truncated'],
        isFalse,
      );
      expect(
        artifacts
            .singleWhere((artifact) => artifact.title == 'Git diff preview')
            .metadata['truncated'],
        isFalse,
      );
    },
  );

  test(
    'ArtifactCollector previews a MiB of malformed UTF-8 linearly',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-linear-preview-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(),
        _FakeProcess.completed(),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[
            List<int>.filled(defaultFullDiffPreviewLimit, 0xff),
          ],
        ),
      ]);

      final artifacts =
          await ArtifactCollector(
                processStarter: harness.start,
                idGenerator: _ids().next,
              )
              .collect(
                _task(
                  workspace.path,
                  metadata: const <String, Object?>{'retain_full_diff': true},
                ),
                _run(),
              )
              .timeout(const Duration(seconds: 2));

      final diff = artifacts.single;
      expect(
        utf8.encode(diff.contentPreview!).length,
        lessThanOrEqualTo(defaultFullDiffPreviewLimit),
      );
      expect(diff.metadata['truncated'], isTrue);
    },
  );

  test(
    'ArtifactCollector drains oversized stderr without retaining it',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-stderr-large-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode(' M a\n')],
          stderrChunks: <List<int>>[List<int>.filled(2 * 1024 * 1024, 0x73)],
        ),
        _FakeProcess.completed(),
      ]);

      final artifacts = await ArtifactCollector(
        processStarter: harness.start,
        idGenerator: _ids().next,
      ).collect(_task(workspace.path), _run());

      expect(artifacts.single.contentPreview, ' M a\n');
      expect(artifacts.single.metadata.toString(), isNot(contains('ssssssss')));
    },
  );

  test('ArtifactCollector handles stderr stream errors and reaps', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-stderr-error-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final rev = _FakeProcess(
      onKill: (_, process) {
        if (!process.exitCodeCompleter.isCompleted) {
          process.exitCodeCompleter.complete(-15);
        }
        return true;
      },
    );
    final harness = _GitHarness(<_FakeProcess>[rev]);
    final collecting = ArtifactCollector(
      processStarter: harness.start,
      terminationGracePeriod: const Duration(milliseconds: 10),
    ).collect(_task(workspace.path), _run());
    await _waitUntil(() => harness.arguments.isNotEmpty);

    rev.stderrController.addError(StateError('stderr secret'));

    expect(await collecting.timeout(const Duration(seconds: 1)), isEmpty);
    expect(rev.signals, contains(ProcessSignal.sigterm));
    expect(rev.exitCodeAwaited, isTrue);
  });

  test(
    'ArtifactCollector waits when streams finish before process exit',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-streams-first-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final rev = _FakeProcess();
      final harness = _GitHarness(<_FakeProcess>[rev]);
      var settled = false;
      final collecting =
          ArtifactCollector(
                processStarter: harness.start,
                commandTimeout: const Duration(seconds: 1),
              )
              .collect(_task(workspace.path), _run())
              .whenComplete(() => settled = true);
      await _waitUntil(() => harness.arguments.isNotEmpty);
      rev.stdoutController.add(utf8.encode('not a repo\n'));
      await rev.stdoutController.close();
      await rev.stderrController.close();
      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse);

      rev.exitCodeCompleter.complete(1);

      await collecting;
      expect(settled, isTrue);
    },
  );

  test('ArtifactCollector does not KILL when TERM reaps the child', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-term-exit-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final rev = _FakeProcess(
      onKill: (signal, process) {
        if (signal == ProcessSignal.sigterm &&
            !process.exitCodeCompleter.isCompleted) {
          process.exitCodeCompleter.complete(-15);
        }
        return true;
      },
    );
    final harness = _GitHarness(<_FakeProcess>[rev]);

    await ArtifactCollector(
          processStarter: harness.start,
          commandTimeout: const Duration(milliseconds: 20),
          terminationGracePeriod: const Duration(milliseconds: 20),
        )
        .collect(_task(workspace.path), _run())
        .timeout(const Duration(seconds: 1));

    expect(rev.signals, <ProcessSignal>[ProcessSignal.sigterm]);
    expect(rev.exitCodeAwaited, isTrue);
  });

  test('ArtifactCollector cancels held pipes after the parent exits', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-held-pipes-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final rev = _FakeProcess();
    rev.exitCodeCompleter.complete(0);
    final harness = _GitHarness(<_FakeProcess>[rev]);

    final artifacts =
        await ArtifactCollector(
              processStarter: harness.start,
              commandTimeout: const Duration(milliseconds: 20),
              terminationGracePeriod: const Duration(milliseconds: 10),
            )
            .collect(_task(workspace.path), _run())
            .timeout(const Duration(seconds: 1));

    expect(artifacts, isEmpty);
    expect(rev.signals, isEmpty);
    expect(rev.stdoutController.hasListener, isFalse);
    expect(rev.stderrController.hasListener, isFalse);
  });

  test(
    'ArtifactCollector cancels old timers after successful commands',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-old-timer-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final processes = <_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        _FakeProcess.completed(),
        _FakeProcess.completed(),
      ];
      final harness = _GitHarness(processes);

      await ArtifactCollector(
        processStarter: harness.start,
        commandTimeout: const Duration(milliseconds: 20),
        terminationGracePeriod: const Duration(milliseconds: 10),
      ).collect(_task(workspace.path), _run());
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(processes.expand((p) => p.signals), isEmpty);
    },
  );

  test('ArtifactCollector treats nonzero commands as best effort', () async {
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-artifacts-nonzero-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final harness = _GitHarness(<_FakeProcess>[
      _FakeProcess.completed(stdoutChunks: <List<int>>[utf8.encode('true\n')]),
      _FakeProcess.completed(
        stdoutChunks: <List<int>>[utf8.encode(' M ignored\n')],
        exitCode: 2,
      ),
      _FakeProcess.completed(
        stdoutChunks: <List<int>>[utf8.encode('a | 1 +\n')],
      ),
    ]);

    final artifacts = await ArtifactCollector(
      processStarter: harness.start,
      idGenerator: _ids().next,
    ).collect(_task(workspace.path), _run());

    expect(artifacts, hasLength(1));
    expect(artifacts.single.title, 'Git diff stat');
  });

  test(
    'ArtifactCollector contains synchronous and asynchronous start errors',
    () async {
      for (final asynchronous in <bool>[false, true]) {
        final workspace = await Directory.systemTemp.createTemp(
          'ianvs-artifacts-start-error-',
        );
        addTearDown(() => workspace.delete(recursive: true));
        final collector = ArtifactCollector(
          processStarter: (_, _, {workingDirectory}) {
            if (asynchronous) {
              return Future<Process>.error(StateError('async spawn secret'));
            }
            throw StateError('sync spawn secret');
          },
        );

        expect(await collector.collect(_task(workspace.path), _run()), isEmpty);
      }
    },
  );

  test('ArtifactCollector rejects non-positive limits at runtime', () {
    expect(() => ArtifactCollector(previewLimit: 0), throwsArgumentError);
    expect(
      () => ArtifactCollector(commandTimeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => ArtifactCollector(terminationGracePeriod: Duration.zero),
      throwsArgumentError,
    );
  });

  test(
    'ArtifactCollector copies retained bytes out of a large backing buffer',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-backing-buffer-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final status = _FakeProcess();
      final harness = _GitHarness(<_FakeProcess>[
        _FakeProcess.completed(
          stdoutChunks: <List<int>>[utf8.encode('true\n')],
        ),
        status,
        _FakeProcess.completed(),
      ]);
      final collecting = ArtifactCollector(
        processStarter: harness.start,
        idGenerator: _ids().next,
      ).collect(_task(workspace.path), _run());
      await _waitUntil(() => harness.arguments.length == 2);
      final backing = Uint8List(8 * 1024 * 1024);
      final expected = utf8.encode(' M a\n');
      backing.setRange(0, expected.length, expected);
      final view = Uint8List.sublistView(backing, 0, expected.length);

      status.stdoutController.add(view);
      await Future<void>.delayed(Duration.zero);
      backing.fillRange(0, expected.length, 0x78);
      await status.stdoutController.close();
      await status.stderrController.close();
      status.exitCodeCompleter.complete(0);

      final artifacts = await collecting;
      expect(artifacts.single.contentPreview, ' M a\n');
    },
  );

  test('ArtifactCollectionCancellation contains listener failures', () {
    final cancellation = ArtifactCollectionCancellation();
    final reasons = <String>[];
    cancellation.addListener((_) => throw StateError('listener failure'));
    cancellation.addListener(reasons.add);

    expect(() => cancellation.cancel('first'), returnsNormally);
    expect(reasons, <String>['first']);
    expect(cancellation.reason, 'first');
  });

  test('ArtifactCollector reaps processes when setup getters throw', () async {
    for (final failure in _SetupFailure.values) {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-setup-error-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final process = _SetupThrowingProcess(failure);
      final harness = _GitHarness(<_FakeProcess>[process]);

      final artifacts =
          await ArtifactCollector(
                processStarter: harness.start,
                terminationGracePeriod: const Duration(milliseconds: 10),
              )
              .collect(_task(workspace.path), _run())
              .timeout(const Duration(seconds: 1));

      expect(artifacts, isEmpty, reason: failure.name);
      expect(
        process.signals,
        contains(ProcessSignal.sigterm),
        reason: failure.name,
      );
      expect(process.exitCodeAwaited, isTrue, reason: failure.name);
      expect(
        process.stdoutController.hasListener,
        isFalse,
        reason: failure.name,
      );
      expect(
        process.stderrController.hasListener,
        isFalse,
        reason: failure.name,
      );
    }
  });

  test(
    'ArtifactCollector cleans up when exitCode completes with an error',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-exit-error-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final process = _FakeProcess(onKill: (_, _) => true);
      final harness = _GitHarness(<_FakeProcess>[process]);
      final collecting = ArtifactCollector(
        processStarter: harness.start,
        terminationGracePeriod: const Duration(milliseconds: 10),
      ).collect(_task(workspace.path), _run());
      await _waitUntil(() => harness.arguments.isNotEmpty);

      process.exitCodeCompleter.completeError(StateError('exit secret'));

      expect(await collecting.timeout(const Duration(seconds: 1)), isEmpty);
      expect(process.signals, <ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(process.stdoutController.hasListener, isFalse);
      expect(process.stderrController.hasListener, isFalse);
    },
  );

  test(
    'ArtifactCollector degrades to termination when exitCode is unavailable',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-exit-unavailable-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final process = _AlwaysThrowingExitProcess();
      final harness = _GitHarness(<_FakeProcess>[process]);

      expect(
        await ArtifactCollector(
              processStarter: harness.start,
              terminationGracePeriod: const Duration(milliseconds: 10),
            )
            .collect(_task(workspace.path), _run())
            .timeout(const Duration(seconds: 1)),
        isEmpty,
      );
      expect(process.signals, <ProcessSignal>[
        ProcessSignal.sigterm,
        ProcessSignal.sigkill,
      ]);
      expect(process.stdoutController.hasListener, isFalse);
      expect(process.stderrController.hasListener, isFalse);
    },
  );

  test(
    'ArtifactCollector bounds and starts cancellation for both streams',
    () async {
      final workspace = await Directory.systemTemp.createTemp(
        'ianvs-artifacts-cancel-streams-',
      );
      addTearDown(() => workspace.delete(recursive: true));
      final process = _StallingCancelProcess();
      addTearDown(process.releaseCancellation);
      final harness = _GitHarness(<_FakeProcess>[process]);

      final artifacts =
          await ArtifactCollector(
                processStarter: harness.start,
                commandTimeout: const Duration(milliseconds: 20),
                terminationGracePeriod: const Duration(milliseconds: 10),
              )
              .collect(_task(workspace.path), _run())
              .timeout(const Duration(seconds: 1));

      expect(artifacts, isEmpty);
      expect(process.stdoutCancelStarted.isCompleted, isTrue);
      expect(process.stderrCancelStarted.isCompleted, isTrue);
    },
  );
}

TaskRecord _task(
  String workspacePath, {
  Map<String, Object?> metadata = const <String, Object?>{},
}) {
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
    metadata: metadata,
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

Future<void> _createDirtyGitRepo(
  Directory workspace, {
  bool includeDiff = false,
}) async {
  await _initGitRepo(workspace);
  final candidate = File('${workspace.path}/candidate.txt');
  if (!includeDiff) {
    await candidate.writeAsString('untracked\n');
    return;
  }
  await candidate.writeAsString('before\n');
  await _git(workspace, ['add', 'candidate.txt']);
  await _git(workspace, ['commit', '-m', 'initial']);
  await candidate.writeAsString('after\n');
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

class _GitHarness {
  _GitHarness(this.processes);

  final List<_FakeProcess> processes;
  final List<List<String>> arguments = <List<String>>[];
  int _index = 0;

  Future<Process> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
  }) async {
    expect(executable, 'git');
    arguments.add(List<String>.of(args));
    if (_index >= processes.length) {
      throw StateError('Unexpected process start.');
    }
    return processes[_index++];
  }
}

typedef _OnFakeKill = bool Function(ProcessSignal signal, _FakeProcess process);

class _FakeProcess implements Process {
  _FakeProcess({this.onKill});

  factory _FakeProcess.completed({
    List<List<int>> stdoutChunks = const <List<int>>[],
    List<List<int>> stderrChunks = const <List<int>>[],
    int exitCode = 0,
    bool exitBeforeStreams = false,
  }) {
    final process = _FakeProcess();
    scheduleMicrotask(() async {
      if (exitBeforeStreams && !process.exitCodeCompleter.isCompleted) {
        process.exitCodeCompleter.complete(exitCode);
      }
      for (final chunk in stdoutChunks) {
        process.stdoutController.add(chunk);
      }
      for (final chunk in stderrChunks) {
        process.stderrController.add(chunk);
      }
      await process.stdoutController.close();
      await process.stderrController.close();
      if (!process.exitCodeCompleter.isCompleted) {
        process.exitCodeCompleter.complete(exitCode);
      }
    });
    return process;
  }

  final _OnFakeKill? onKill;
  final StreamController<List<int>> stdoutController =
      StreamController<List<int>>();
  final StreamController<List<int>> stderrController =
      StreamController<List<int>>();
  final Completer<int> exitCodeCompleter = Completer<int>();
  final List<ProcessSignal> signals = <ProcessSignal>[];
  final _DiscardConsumer _stdinConsumer = _DiscardConsumer();
  bool exitCodeAwaited = false;

  bool get stdinClosed => _stdinConsumer.closed;

  @override
  Future<int> get exitCode {
    exitCodeAwaited = true;
    return exitCodeCompleter.future;
  }

  @override
  int get pid => 4242;

  @override
  late final IOSink stdin = IOSink(_stdinConsumer);

  @override
  Stream<List<int>> get stderr => stderrController.stream;

  @override
  Stream<List<int>> get stdout => stdoutController.stream;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    return onKill?.call(signal, this) ?? false;
  }
}

enum _SetupFailure { stdout, stderr, stdin, exitCode }

class _SetupThrowingProcess extends _FakeProcess {
  _SetupThrowingProcess(this.failure)
    : super(
        onKill: (_, process) {
          if (!process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-15);
          }
          return true;
        },
      );

  final _SetupFailure failure;
  bool _exitCodeThrown = false;

  @override
  Stream<List<int>> get stdout {
    if (failure == _SetupFailure.stdout) throw StateError('stdout getter');
    return super.stdout;
  }

  @override
  Stream<List<int>> get stderr {
    if (failure == _SetupFailure.stderr) throw StateError('stderr getter');
    return super.stderr;
  }

  @override
  IOSink get stdin {
    if (failure == _SetupFailure.stdin) throw StateError('stdin getter');
    return super.stdin;
  }

  @override
  Future<int> get exitCode {
    if (failure == _SetupFailure.exitCode && !_exitCodeThrown) {
      _exitCodeThrown = true;
      throw StateError('exitCode getter');
    }
    return super.exitCode;
  }
}

class _AlwaysThrowingExitProcess extends _FakeProcess {
  _AlwaysThrowingExitProcess() : super(onKill: (_, _) => true);

  @override
  Future<int> get exitCode => throw StateError('exitCode unavailable');
}

class _StallingCancelProcess extends _FakeProcess {
  _StallingCancelProcess()
    : super(
        onKill: (_, process) {
          if (!process.exitCodeCompleter.isCompleted) {
            process.exitCodeCompleter.complete(-15);
          }
          return true;
        },
      ) {
    _stdoutController = StreamController<List<int>>(
      onCancel: () {
        if (!stdoutCancelStarted.isCompleted) stdoutCancelStarted.complete();
        return _cancelReleased.future;
      },
    );
    _stderrController = StreamController<List<int>>(
      onCancel: () {
        if (!stderrCancelStarted.isCompleted) stderrCancelStarted.complete();
      },
    );
  }

  final Completer<void> stdoutCancelStarted = Completer<void>();
  final Completer<void> stderrCancelStarted = Completer<void>();
  final Completer<void> _cancelReleased = Completer<void>();
  late final StreamController<List<int>> _stdoutController;
  late final StreamController<List<int>> _stderrController;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  void releaseCancellation() {
    if (!_cancelReleased.isCompleted) _cancelReleased.complete();
  }
}

class _DiscardConsumer implements StreamConsumer<List<int>> {
  bool closed = false;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

Future<void> _waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition did not become true.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}
