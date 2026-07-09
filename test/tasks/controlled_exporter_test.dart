import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/controlled_exporter.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';

void main() {
  test('ControlledExporter fails without an approval record', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_snapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final exporter = ControlledExporter(taskController: controller);

    await expectLater(
      exporter.export('approval-missing'),
      throwsA(isA<ExportException>()),
    );
    expect(controller.tasks.single.status, TaskStatus.approvedForExport);
  });

  test('ControlledExporter fails when approval is denied', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        _snapshot(
          approvalStatus: ApprovalStatus.denied,
          resolvedAt: DateTime(2026, 7, 7, 8, 30),
        ),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final exporter = ControlledExporter(taskController: controller);

    await expectLater(
      exporter.export('approval-1'),
      throwsA(isA<ExportException>()),
    );
    expect(controller.tasks.single.status, TaskStatus.approvedForExport);
  });

  test(
    'ControlledExporter runs approved simulated export and records audit',
    () async {
      final store = _MemoryTaskStore(_snapshot());
      final controller = TaskInboxController(
        store: store,
        clock: _clock(),
        idGenerator: _ids().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final exporter = ControlledExporter(
        taskController: controller,
        clock: _clock(),
      );

      final result = await exporter.export('approval-1');

      expect(result.success, isTrue);
      expect(result.target, ExportTarget.simulated);
      expect(result.message, 'Simulated export completed for 1 artifact(s).');
      expect(controller.tasks.single.status, TaskStatus.done);
      expect(controller.tasks.single.summary, result.message);
      expect(controller.tasks.single.error, isNull);
      expect(controller.artifacts.single.status, ArtifactStatus.exported);
      expect(
        store.savedSnapshots.map((snapshot) => snapshot.tasks.single.status),
        containsAllInOrder([TaskStatus.exporting, TaskStatus.done]),
      );
      final exportEvents = controller.events
          .where((event) => event.kind == TaskEventKind.export)
          .toList();
      expect(exportEvents.map((event) => event.text), [
        'Export started.',
        'Export completed.',
      ]);
      expect(exportEvents.first.metadata['approval_id'], 'approval-1');
      expect(exportEvents.first.metadata['artifact_ids'], ['artifact-1']);
      expect(exportEvents.last.metadata['mode'], 'simulated');
    },
  );

  test(
    'ControlledExporter marks task failed when export execution fails',
    () async {
      final store = _MemoryTaskStore(_snapshot());
      final controller = TaskInboxController(
        store: store,
        clock: _clock(),
        idGenerator: _ids().next,
      );
      addTearDown(controller.dispose);
      await controller.load();
      final exporter = ControlledExporter(
        taskController: controller,
        clock: _clock(),
        simulatedExecutor: (_) => throw const ExportException('simulated boom'),
      );

      final result = await exporter.export('approval-1');

      expect(result.success, isFalse);
      expect(result.message, 'simulated boom');
      expect(controller.tasks.single.status, TaskStatus.failed);
      expect(controller.tasks.single.error, 'simulated boom');
      expect(
        controller.events
            .where((event) => event.kind == TaskEventKind.export)
            .map((event) => event.text),
        ['Export started.', 'Export failed: simulated boom'],
      );
    },
  );

  test('ControlledExporter fails when artifacts are not approved', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(
        _snapshot(artifactStatus: ArtifactStatus.candidate),
      ),
    );
    addTearDown(controller.dispose);
    await controller.load();
    final exporter = ControlledExporter(taskController: controller);

    await expectLater(
      exporter.export('approval-1'),
      throwsA(
        isA<ExportException>().having(
          (error) => error.message,
          'message',
          contains('not approved for export'),
        ),
      ),
    );
    expect(controller.tasks.single.status, TaskStatus.approvedForExport);
    expect(controller.artifacts.single.status, ArtifactStatus.candidate);
  });

  test(
    'ControlledExporter fails when approved artifacts are missing',
    () async {
      final controller = TaskInboxController(
        store: _MemoryTaskStore(_snapshot(artifactIds: const ['missing'])),
      );
      addTearDown(controller.dispose);
      await controller.load();
      final exporter = ControlledExporter(taskController: controller);

      await expectLater(
        exporter.export('approval-1'),
        throwsA(isA<ExportException>()),
      );
    },
  );

  test('ControlledExporter creates local git commit export', () async {
    final repo = await Directory.systemTemp.createTemp('ianvs-acp-git-export-');
    addTearDown(() async => repo.delete(recursive: true));
    await _git(repo, ['init']);
    await File('${repo.path}/note.txt').writeAsString('hello\n');

    final store = _MemoryTaskStore(
      _snapshot(
        workspacePath: repo.path,
        target: ExportTarget.gitCommit,
        destination: 'Export approved task artifacts',
      ),
    );
    final controller = TaskInboxController(
      store: store,
      clock: _clock(),
      idGenerator: _ids().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final exporter = ControlledExporter(
      taskController: controller,
      clock: _clock(),
    );

    final result = await exporter.export('approval-1');

    expect(result.success, isTrue);
    expect(result.target, ExportTarget.gitCommit);
    expect(result.message, startsWith('Created git commit '));
    expect(result.metadata['mode'], 'git_commit');
    expect(result.metadata['commit'], isA<String>());
    expect(controller.tasks.single.status, TaskStatus.done);
    expect(controller.artifacts.single.status, ArtifactStatus.exported);

    final subject = await _git(repo, ['log', '-1', '--pretty=%s']);
    expect(subject.trim(), 'Export approved task artifacts');
    final status = await _git(repo, ['status', '--porcelain']);
    expect(status.trim(), isEmpty);
  });
}

TaskInboxSnapshot _snapshot({
  ApprovalStatus approvalStatus = ApprovalStatus.approved,
  ArtifactStatus artifactStatus = ArtifactStatus.approved,
  ExportTarget target = ExportTarget.simulated,
  String workspacePath = '/workspace/app',
  String? destination,
  DateTime? resolvedAt,
  List<String> artifactIds = const ['artifact-1'],
}) {
  return TaskInboxSnapshot(
    updatedAt: DateTime(2026, 7, 7, 8),
    tasks: [
      TaskRecord(
        id: 'task-1',
        title: 'Export me',
        description: '',
        workspacePath: workspacePath,
        agentName: 'Codex',
        status: TaskStatus.approvedForExport,
        priority: TaskPriority.normal,
        createdAt: DateTime(2026, 7, 7, 8),
        updatedAt: DateTime(2026, 7, 7, 8),
        currentRunId: 'run-1',
        sessionId: 'session-1',
      ),
    ],
    runs: [
      TaskRunRecord(
        id: 'run-1',
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.needsHumanReview,
        startedAt: DateTime(2026, 7, 7, 8),
      ),
    ],
    artifacts: [
      ArtifactRecord(
        id: 'artifact-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ArtifactKind.gitDiff,
        status: artifactStatus,
        title: 'Git diff preview',
        createdAt: DateTime(2026, 7, 7, 8),
        contentPreview: '+after',
      ),
    ],
    approvals: [
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ApprovalKind.export,
        status: approvalStatus,
        createdAt: DateTime(2026, 7, 7, 8, 20),
        resolvedAt: resolvedAt ?? DateTime(2026, 7, 7, 8, 20),
        target: target,
        destination: destination,
        artifactIds: artifactIds,
      ),
    ],
  );
}

Future<String> _git(Directory repo, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: repo.path);
  if (result.exitCode != 0) {
    fail(
      'git ${args.join(' ')} failed\n'
      'stdout: ${result.stdout}\n'
      'stderr: ${result.stderr}',
    );
  }
  return result.stdout as String;
}

DateTime Function() _clock() {
  var current = DateTime(2026, 7, 7, 9);
  return () {
    final value = current;
    current = current.add(const Duration(minutes: 1));
    return value;
  };
}

_Ids _ids() => _Ids();

class _Ids {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}

class _MemoryTaskStore implements TaskStore {
  _MemoryTaskStore([TaskInboxSnapshot? snapshot])
    : _snapshot = snapshot ?? TaskInboxSnapshot.empty();

  TaskInboxSnapshot _snapshot;
  final List<TaskInboxSnapshot> savedSnapshots = <TaskInboxSnapshot>[];

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    _snapshot = snapshot;
    savedSnapshots.add(snapshot);
  }
}
