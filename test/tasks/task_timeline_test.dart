import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';
import 'package:ianvs_acp/tasks/task_timeline.dart';

void main() {
  test('buildTaskTimeline merges task records in chronological order', () {
    final entries = buildTaskTimeline(_snapshot(), 'task-1');

    expect(entries.map((entry) => entry.kind), [
      TaskTimelineEntryKind.runStarted,
      TaskTimelineEntryKind.event,
      TaskTimelineEntryKind.artifact,
      TaskTimelineEntryKind.approval,
      TaskTimelineEntryKind.runEnded,
    ]);
    expect(entries.map((entry) => entry.timestamp), [
      DateTime(2026, 7, 8, 8),
      DateTime(2026, 7, 8, 8, 5),
      DateTime(2026, 7, 8, 8, 20),
      DateTime(2026, 7, 8, 8, 25),
      DateTime(2026, 7, 8, 8, 30),
    ]);
    expect(entries.first.title, 'Run #1 started');
    expect(entries[1].title, 'Agent responded.');
    expect(entries[2].title, 'Git diff');
    expect(entries[3].title, 'Export approval approved');
    expect(entries.last.title, 'Run #1 failed');
  });

  test('buildTaskTimeline filters unrelated tasks', () {
    final entries = buildTaskTimeline(_snapshot(), 'task-2');

    expect(entries.map((entry) => entry.taskId).toSet(), {'task-2'});
    expect(entries.map((entry) => entry.kind), [
      TaskTimelineEntryKind.runStarted,
      TaskTimelineEntryKind.event,
    ]);
    expect(entries.last.title, 'Other task event.');
  });

  test('TaskInboxController exposes task timeline projection', () async {
    final controller = TaskInboxController(
      store: _MemoryTaskStore(_snapshot()),
    );
    addTearDown(controller.dispose);
    await controller.load();

    final entries = controller.timelineForTask('task-1');

    expect(entries, hasLength(5));
    expect(entries.first.id, 'run-run-1-started');
    expect(entries.last.id, 'run-run-1-ended');
  });
}

TaskInboxSnapshot _snapshot() {
  return TaskInboxSnapshot(
    updatedAt: DateTime(2026, 7, 8, 9),
    tasks: [_task('task-1'), _task('task-2')],
    runs: [
      TaskRunRecord(
        id: 'run-1',
        taskId: 'task-1',
        attempt: 1,
        status: TaskStatus.failed,
        startedAt: DateTime(2026, 7, 8, 8),
        endedAt: DateTime(2026, 7, 8, 8, 30),
        error: 'boom',
      ),
      TaskRunRecord(
        id: 'run-2',
        taskId: 'task-2',
        attempt: 1,
        status: TaskStatus.running,
        startedAt: DateTime(2026, 7, 8, 8, 1),
      ),
    ],
    events: [
      TaskEventRecord(
        id: 'event-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: TaskEventKind.assistant,
        text: 'Agent responded.',
        createdAt: DateTime(2026, 7, 8, 8, 5),
      ),
      TaskEventRecord(
        id: 'event-2',
        taskId: 'task-2',
        runId: 'run-2',
        kind: TaskEventKind.system,
        text: 'Other task event.',
        createdAt: DateTime(2026, 7, 8, 8, 6),
      ),
    ],
    artifacts: [
      ArtifactRecord(
        id: 'artifact-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ArtifactKind.gitDiff,
        status: ArtifactStatus.approved,
        title: 'Git diff',
        createdAt: DateTime(2026, 7, 8, 8, 20),
      ),
    ],
    approvals: [
      ApprovalRequestRecord(
        id: 'approval-1',
        taskId: 'task-1',
        runId: 'run-1',
        kind: ApprovalKind.export,
        status: ApprovalStatus.approved,
        createdAt: DateTime(2026, 7, 8, 8, 25),
        resolvedAt: DateTime(2026, 7, 8, 8, 26),
        target: ExportTarget.simulated,
        artifactIds: const ['artifact-1'],
      ),
    ],
  );
}

TaskRecord _task(String id) {
  return TaskRecord(
    id: id,
    title: id,
    description: '',
    workspacePath: '/workspace/app',
    agentName: 'Codex',
    status: TaskStatus.running,
    priority: TaskPriority.normal,
    createdAt: DateTime(2026, 7, 8, 8),
    updatedAt: DateTime(2026, 7, 8, 9),
  );
}

class _MemoryTaskStore implements TaskStore {
  _MemoryTaskStore(this._snapshot);

  TaskInboxSnapshot _snapshot;

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}
