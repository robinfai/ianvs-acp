import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_workflow_native.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/workspace_resource.dart';

void main() {
  final root = Directory.current.path;
  final libraryPath = '$root/rust/target/debug/libianvs_acp_ffi.dylib';
  final artifactsAvailable = File(libraryPath).existsSync();

  test(
    'Dart FFI drives durable Rust workflow transitions and crash recovery',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'ianvs-workflow-ffi-',
      );
      final workspace = Directory('${directory.path}/workspace')..createSync();
      final databasePath = '${directory.path}/workflow.sqlite3';
      final native = FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath);
      final first = IanvsRustWorkflow(native: native);
      addTearDown(() {
        first.dispose();
        directory.deleteSync(recursive: true);
      });

      final opened = first.open(databasePath);
      expect(opened.revision, 0);
      first.apply(
        IanvsWorkflowCommand.createTask(
          taskId: 'task-1',
          workspacePath: workspace.path,
          agentName: 'fixture',
        ),
      );
      first.apply(IanvsWorkflowCommand.queueTask('task-1'));
      first.apply(
        IanvsWorkflowCommand.dispatchTask(taskId: 'task-1', runId: 'run-1'),
      );
      final running = first.apply(IanvsWorkflowCommand.startRun('run-1'));
      expect(running.revision, 4);
      expect(running.tasks.single.status, IanvsWorkflowTaskStatus.running);
      expect(running.runs.single.status, IanvsWorkflowRunStatus.running);
      first.dispose();

      final reopened = IanvsRustWorkflow(
        native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
      );
      addTearDown(reopened.dispose);
      final recovered = reopened.open(databasePath);
      expect(recovered.revision, 5);
      expect(recovered.recoveredFailedTaskIds, <String>['task-1']);
      expect(recovered.tasks.single.status, IanvsWorkflowTaskStatus.failed);
      expect(recovered.runs.single.status, IanvsWorkflowRunStatus.failed);

      expect(
        () => reopened.apply(IanvsWorkflowCommand.startRun('missing')),
        throwsA(isA<StateError>()),
      );
      expect(reopened.snapshot().revision, 5);
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
  );

  test(
    'Dart FFI activates and atomically persists the complete TaskInbox',
    () {
      final directory = Directory.systemTemp.createTempSync(
        'ianvs-task-inbox-stage-',
      );
      final workspace = Directory('${directory.path}/workspace')..createSync();
      final editedWorkspace = Directory('${directory.path}/workspace-edited')
        ..createSync();
      final databasePath = '${directory.path}/workflow.sqlite3';
      final workflow = IanvsRustWorkflow(
        native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
      );
      addTearDown(() {
        workflow.dispose();
        directory.deleteSync(recursive: true);
      });
      workflow.open(databasePath);
      final now = DateTime.utc(2026, 7, 17, 8);
      final source = TaskInboxSnapshot(
        updatedAt: now,
        tasks: <TaskRecord>[
          TaskRecord(
            id: 'task-imported',
            title: 'Imported task',
            description: 'Retain the complete Dart projection.',
            workspacePath: workspace.path,
            agentName: 'fixture',
            status: TaskStatus.approvedForExport,
            priority: TaskPriority.high,
            createdAt: now.subtract(const Duration(hours: 1)),
            updatedAt: now,
            metadata: const <String, Object?>{
              'nested': <String, Object?>{'value': true},
            },
          ),
        ],
      );

      final staged = workflow.stageTaskInbox(
        source: source,
        sourceChecksum: 'sha256:fixture',
      );
      expect(staged.workflow.revision, 1);
      expect(
        staged.workflow.migration.phase,
        IanvsWorkflowMigrationPhase.staged,
      );
      expect(staged.workflow.migration.sourceChecksum, 'sha256:fixture');
      expect(staged.normalizedHistoricalTaskIds, <String>['task-imported']);
      expect(
        staged.workflow.tasks.single.status,
        IanvsWorkflowTaskStatus.needsHumanReview,
      );
      expect(workflow.taskInboxSource()?.toJson(), source.toJson());
      final materialized = workflow.materializeTaskInbox();
      expect(materialized.workflow.revision, 2);
      expect(
        materialized.workflow.migration.phase,
        IanvsWorkflowMigrationPhase.ready,
      );
      expect(
        materialized.taskInbox.tasks.single.status,
        TaskStatus.needsHumanReview,
      );
      expect(
        workflow.currentTaskInbox()?.toJson(),
        materialized.taskInbox.toJson(),
      );
      expect(
        workflow.taskInboxSource()?.tasks.single.status,
        TaskStatus.approvedForExport,
      );
      final activated = workflow.activateTaskInbox();
      expect(activated.workflow.revision, 3);
      expect(
        activated.workflow.migration.phase,
        IanvsWorkflowMigrationPhase.active,
      );
      expect(
        () => workflow.apply(IanvsWorkflowCommand.cancelTask('task-imported')),
        throwsA(
          isA<StateError>().having(
            (error) => error.toString(),
            'message',
            contains('TaskInbox transaction API'),
          ),
        ),
      );
      final cancelled = workflow.applyTaskInbox(
        IanvsTaskInboxCommand.cancelTask(
          taskId: 'task-imported',
          updatedAt: now.add(const Duration(minutes: 1)),
        ),
      );
      expect(cancelled.workflow.revision, 4);
      expect(cancelled.taskInbox.tasks.single.status, TaskStatus.cancelled);

      final taskCreatedAt = now.add(const Duration(minutes: 2));
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.createTask(
          TaskRecord(
            id: 'task-active',
            title: 'Active Rust task',
            description: 'Persist every TaskInbox record kind.',
            workspacePath: workspace.path,
            agentName: 'fixture',
            status: TaskStatus.inbox,
            priority: TaskPriority.urgent,
            createdAt: taskCreatedAt,
            updatedAt: taskCreatedAt,
          ),
        ),
      );
      final editedAt = now.add(const Duration(minutes: 2, seconds: 30));
      final edited = workflow.applyTaskInbox(
        IanvsTaskInboxCommand.updateTaskDefinition(
          task: TaskRecord(
            id: 'task-active',
            title: 'Edited active Rust task',
            description: 'Definition edits are Rust-owned before dispatch.',
            workspacePath: editedWorkspace.path,
            agentName: 'fixture-edited',
            status: TaskStatus.inbox,
            priority: TaskPriority.urgent,
            createdAt: taskCreatedAt,
            updatedAt: editedAt,
          ),
          updatedAt: editedAt,
        ),
      );
      expect(
        edited.taskInbox.tasks
            .singleWhere((task) => task.id == 'task-active')
            .agentName,
        'fixture-edited',
      );
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.queueTask(
          taskId: 'task-active',
          updatedAt: now.add(const Duration(minutes: 3)),
        ),
      );
      workflow.configureScheduler(maxConcurrentTasks: 1);
      workflow.setSchedulerRuntimeStatus(
        IanvsSchedulerRuntimeStatus(
          agentName: 'fixture-edited',
          availability: IanvsSchedulerRuntimeAvailability.available,
          observedAt: now.add(const Duration(minutes: 4)),
          supportsPermissions: true,
          maxConcurrentTasks: 1,
        ),
      );
      final schedulerClaim = workflow.schedulerClaimNext(
        runId: 'run-active',
        dispatchEventId: 'event-dispatch-active',
        now: now.add(const Duration(minutes: 4)),
      );
      expect(schedulerClaim.claim?.taskId, 'task-active');
      expect(schedulerClaim.claim?.attempt, 1);
      expect(schedulerClaim.nextWakeAt, isNull);
      expect(schedulerClaim.workflow.revision, 8);
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.transitionRun(
          runId: 'run-active',
          transition: IanvsTaskInboxRunTransition.start,
          updatedAt: now.add(const Duration(minutes: 5)),
        ),
      );
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.appendEvents(
          events: <TaskEventRecord>[
            TaskEventRecord(
              id: 'event-active',
              taskId: 'task-active',
              runId: 'run-active',
              kind: TaskEventKind.assistant,
              text: 'Working',
              createdAt: now.add(const Duration(minutes: 6)),
            ),
          ],
          updatedAt: now.add(const Duration(minutes: 6)),
        ),
      );
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.replaceArtifacts(
          taskId: 'task-active',
          runId: 'run-active',
          artifacts: <ArtifactRecord>[
            ArtifactRecord(
              id: 'artifact-active',
              taskId: 'task-active',
              runId: 'run-active',
              kind: ArtifactKind.testLog,
              title: 'Test log',
              createdAt: now.add(const Duration(minutes: 7)),
              contentPreview: 'ok',
            ),
          ],
          updatedAt: now.add(const Duration(minutes: 7)),
        ),
      );
      workflow.applyTaskInbox(
        IanvsTaskInboxCommand.upsertApproval(
          approval: ApprovalRequestRecord(
            id: 'approval-active',
            taskId: 'task-active',
            runId: 'run-active',
            kind: ApprovalKind.toolPermission,
            status: ApprovalStatus.pending,
            createdAt: now.add(const Duration(minutes: 8)),
            artifactIds: const <String>['artifact-active'],
          ),
          updatedAt: now.add(const Duration(minutes: 8)),
        ),
      );
      final complete = workflow.applyTaskInbox(
        IanvsTaskInboxCommand.upsertResource(
          resource: WorkspaceResource.localDirectory(
            id: 'resource-active',
            label: 'Workspace',
            path: workspace.path,
          ),
          updatedAt: now.add(const Duration(minutes: 9)),
        ),
      );
      expect(complete.workflow.revision, 13);
      expect(
        complete.taskInbox.events.map((event) => event.id),
        containsAll(<String>['event-dispatch-active', 'event-active']),
      );
      expect(complete.taskInbox.artifacts.single.id, 'artifact-active');
      expect(complete.taskInbox.approvals.single.id, 'approval-active');
      expect(complete.taskInbox.resources.single.id, 'resource-active');
      workflow.dispose();

      final reopened = IanvsRustWorkflow(
        native: FfiIanvsWorkflowNativeApi.open(libraryPath: libraryPath),
      );
      addTearDown(reopened.dispose);
      final recovered = reopened.open(databasePath);
      expect(recovered.revision, 14);
      expect(recovered.recoveredFailedTaskIds, <String>['task-active']);
      expect(recovered.migration.phase, IanvsWorkflowMigrationPhase.active);
      final current = reopened.currentTaskInbox()!;
      expect(
        current.tasks.singleWhere((task) => task.id == 'task-active').status,
        TaskStatus.failed,
      );
      expect(current.runs.single.status, TaskStatus.failed);
      expect(
        current.events.map((event) => event.id),
        containsAll(<String>['event-dispatch-active', 'event-active']),
      );
      expect(current.artifacts.single.id, 'artifact-active');
      expect(current.approvals.single.id, 'approval-active');
      expect(current.resources.single.id, 'resource-active');
      expect(
        reopened.taskInboxSource()?.tasks.single.status,
        TaskStatus.approvedForExport,
      );
      final deleted = reopened.applyTaskInbox(
        IanvsTaskInboxCommand.deleteTask(
          taskId: 'task-active',
          updatedAt: now.add(const Duration(minutes: 10)),
        ),
      );
      expect(deleted.workflow.revision, 15);
      expect(
        deleted.taskInbox.tasks.map((task) => task.id),
        isNot(contains('task-active')),
      );
      expect(deleted.taskInbox.runs, isEmpty);
      expect(deleted.taskInbox.events, isEmpty);
      expect(deleted.taskInbox.artifacts, isEmpty);
      expect(deleted.taskInbox.approvals, isEmpty);
      expect(deleted.taskInbox.resources.single.id, 'resource-active');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
  );
}
