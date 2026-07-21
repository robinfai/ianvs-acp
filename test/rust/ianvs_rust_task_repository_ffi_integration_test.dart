import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_rust_task_repository.dart';
import 'package:ianvs_acp/rust/ianvs_workflow_native.dart';
import 'package:ianvs_acp/tasks/runtime_registry.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_scheduler.dart';

void main() {
  final root = Directory.current.path;
  final libraryPath = '$root/rust/target/debug/libianvs_acp_ffi.dylib';
  final artifactsAvailable = File(libraryPath).existsSync();

  test(
    'Rust repository owns TaskInbox transitions, scheduling, wakeups, and recovery',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'ianvs-rust-task-repository-',
      );
      final workspace = Directory('${directory.path}/workspace')..createSync();
      final databasePath = '${directory.path}/workflow.sqlite3';
      var now = DateTime.utc(2026, 7, 17, 10);
      var id = 0;
      String nextId(String prefix) => '$prefix-${++id}';
      final bootstrap = TaskInboxSnapshot.empty(updatedAt: now);
      final firstRepository = IanvsRustTaskRepository(
        databasePath: databasePath,
        bootstrapSnapshot: bootstrap,
        sourceChecksum: 'sha256:repository-fixture',
        authority: IanvsRustWorkflow(
          native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
        ),
      );
      final first = TaskInboxController(
        repository: firstRepository,
        clock: () => now,
        idGenerator: nextId,
      );
      addTearDown(() async {
        first.dispose();
        await firstRepository.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      await first.load();
      expect(first.tasks, isEmpty);
      final created = await first.createTask(
        title: 'Rust scheduled task',
        description: 'Exercise the production repository boundary.',
        workspacePath: workspace.path,
        agentName: 'fixture',
      );
      await first.configureSchedulingAuthority(maxConcurrentTasks: 1);
      await first.publishSchedulingRuntimeStatus(
        LocalRuntimeStatus.available(
          agentName: 'fixture',
          checkedAt: now,
          supportsPermissions: true,
        ),
      );
      await first.updateTask(
        created.id,
        status: TaskStatus.queued,
        summary: 'Queued by Rust.',
      );

      final claimed = await first.claimNextScheduledTask();
      expect(claimed.claim?.task.id, created.id);
      expect(claimed.claim?.task.status, TaskStatus.dispatched);
      expect(claimed.claim?.run.status, TaskStatus.dispatched);
      expect(claimed.claim?.dispatchEvent.text, 'Task dispatched.');
      expect(claimed.nextWakeAt, isNull);

      final runId = claimed.claim!.run.id;
      now = now.add(const Duration(minutes: 1));
      await first.updateRun(
        runId,
        status: TaskStatus.running,
        sessionId: 'session-1',
      );
      expect(first.taskById(created.id)?.status, TaskStatus.running);
      expect(
        first.runs.singleWhere((run) => run.id == runId).sessionId,
        'session-1',
      );

      now = now.add(const Duration(minutes: 1));
      await first.updateRun(
        runId,
        status: TaskStatus.failed,
        endedAt: now,
        error: 'fixture failure',
      );
      expect(first.taskById(created.id)?.status, TaskStatus.failed);

      now = now.add(const Duration(minutes: 1));
      await first.retryTask(created.id, rationale: 'Retry fixture.');
      expect(first.taskById(created.id)?.status, TaskStatus.queued);
      expect(first.taskById(created.id)?.currentRunId, isNull);
      final wakeAt = now.add(const Duration(minutes: 5));
      await first.updateTask(
        created.id,
        metadata: <String, Object?>{
          ...first.taskById(created.id)!.metadata,
          'next_retry_at': wakeAt.toIso8601String(),
        },
      );
      final waiting = await first.claimNextScheduledTask();
      expect(waiting.claim, isNull);
      expect(waiting.nextWakeAt, wakeAt);

      await firstRepository.close();

      final reopenedRepository = IanvsRustTaskRepository(
        databasePath: databasePath,
        bootstrapSnapshot: bootstrap,
        sourceChecksum: 'ignored-after-activation',
        authority: IanvsRustWorkflow(
          native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
        ),
      );
      final reopened = TaskInboxController(
        repository: reopenedRepository,
        clock: () => now,
        idGenerator: nextId,
      );
      addTearDown(() async {
        reopened.dispose();
        await reopenedRepository.close();
      });
      await reopened.load();
      expect(reopened.taskById(created.id)?.status, TaskStatus.queued);
      expect(reopened.runs.single.status, TaskStatus.failed);
      expect(reopened.events.length, 2);

      await reopened.configureSchedulingAuthority(maxConcurrentTasks: 1);
      await reopened.publishSchedulingRuntimeStatus(
        LocalRuntimeStatus.available(
          agentName: 'fixture',
          checkedAt: wakeAt,
          supportsPermissions: true,
        ),
      );
      now = wakeAt;
      final retried = await reopened.claimNextScheduledTask();
      expect(retried.claim?.task.id, created.id);
      expect(retried.claim?.run.attempt, 2);
      expect(retried.repository.snapshot.runs.length, 2);
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
  );

  test(
    'TaskScheduler delegates production dispatch selection to Rust Core',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'ianvs-rust-task-scheduler-',
      );
      final workspace = Directory('${directory.path}/workspace')..createSync();
      final now = DateTime.utc(2026, 7, 17, 12);
      final source = TaskInboxSnapshot(
        updatedAt: now,
        tasks: <TaskRecord>[
          TaskRecord(
            id: 'task-scheduled',
            title: 'Scheduler cutover',
            description: 'Rust must choose and claim this task.',
            workspacePath: workspace.path,
            agentName: 'fixture',
            status: TaskStatus.queued,
            priority: TaskPriority.high,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      final repository = IanvsRustTaskRepository(
        databasePath: '${directory.path}/workflow.sqlite3',
        bootstrapSnapshot: source,
        sourceChecksum: 'sha256:scheduler-cutover',
        authority: IanvsRustWorkflow(
          native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
        ),
      );
      var sequence = 0;
      final controller = TaskInboxController(
        repository: repository,
        clock: () => now,
        idGenerator: (prefix) => '$prefix-${++sequence}',
      );
      final worker = _RustProjectionWorker(controller);
      final scheduler = TaskScheduler(
        taskController: controller,
        worker: worker,
        clock: () => now,
      );
      addTearDown(() async {
        await scheduler.shutdown();
        controller.dispose();
        await repository.close();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      await scheduler.start();
      await worker.completed.future.timeout(const Duration(seconds: 5));
      expect(worker.startedTaskIds, <String>['task-scheduled']);
      expect(controller.tasks.single.status, TaskStatus.needsHumanReview);
      expect(controller.runs.single.status, TaskStatus.needsHumanReview);
      expect(controller.events.single.text, 'Task dispatched.');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
  );
}

final class _RustProjectionWorker implements TaskWorker {
  _RustProjectionWorker(this.controller);

  final TaskInboxController controller;
  final List<String> startedTaskIds = <String>[];
  final Completer<void> completed = Completer<void>();

  @override
  Future<TaskRecord> run(TaskRecord task) async {
    startedTaskIds.add(task.id);
    final runId = task.currentRunId!;
    await controller.updateRun(runId, status: TaskStatus.running);
    await controller.updateRun(runId, status: TaskStatus.collectingArtifacts);
    await controller.updateRun(runId, status: TaskStatus.needsHumanReview);
    if (!completed.isCompleted) completed.complete();
    return controller.taskById(task.id)!;
  }
}
