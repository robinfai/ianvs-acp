import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/local_workflow_automation.dart';
import 'package:ianvs_acp/tasks/task_identifier.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_store.dart';

void main() {
  test('TaskTemplate creates a task draft with skills and metadata', () {
    final template = TaskTemplate(
      id: 'template-review',
      title: 'Review {area}',
      description: 'Check {area} for regressions.',
      agentName: 'Codex',
      priority: TaskPriority.high,
      skillIds: const ['reviewer'],
      metadata: const {'source': 'template'},
    );

    final draft = template.instantiate(
      workspacePath: '/workspace/app',
      variables: const {'area': 'export'},
    );

    expect(draft.title, 'Review export');
    expect(draft.description, 'Check export for regressions.');
    expect(draft.skillIds, ['reviewer']);
    expect(draft.metadata['template_id'], 'template-review');
    expect(draft.metadata['source'], 'template');
  });

  test('LocalAutopilot creates queued task from manual trigger only', () async {
    final store = _MemoryTaskStore();
    final controller = TaskInboxController(
      store: store,
      clock: () => DateTime(2026, 7, 9, 8),
      idGenerator: _Ids().next,
    );
    addTearDown(controller.dispose);
    await controller.load();
    final autopilot = LocalAutopilot(taskController: controller);

    final task = await autopilot.createTask(
      AutopilotTaskRequest(
        trigger: AutopilotTrigger.manual,
        title: 'Nightly check',
        description: 'Run local checks',
        workspacePath: '/workspace/app',
        agentName: 'Codex',
        skillIds: const ['qa'],
        enqueue: true,
      ),
    );

    expect(task.status, TaskStatus.queued);
    expect(task.skillIds, ['qa']);
    expect(task.metadata['autopilot_trigger'], 'manual');
    expect(task.metadata['run_only'], isFalse);
  });

  test('LocalTaskRouter only recommends until human confirms', () async {
    final router = LocalTaskRouter(
      rules: const [
        TaskRoutingRule(
          keyword: 'docs',
          agentName: 'DocsAgent',
          skillIds: ['writer'],
        ),
      ],
      fallbackAgentName: 'Codex',
    );

    final recommendation = router.recommend(
      title: 'Update docs',
      description: 'Improve README',
    );

    expect(recommendation.agentName, 'DocsAgent');
    expect(recommendation.skillIds, ['writer']);
    expect(recommendation.requiresHumanConfirmation, isTrue);
  });

  test('buildTaskNotifications derives human notification inbox entries', () {
    final snapshot = TaskInboxSnapshot(
      updatedAt: DateTime(2026, 7, 9, 8),
      tasks: [
        _task('task-review', TaskStatus.needsHumanReview),
        _task('task-failed', TaskStatus.failed),
      ],
      runs: [
        TaskRunRecord(
          id: 'run-1',
          taskId: 'task-failed',
          attempt: 1,
          status: TaskStatus.failed,
          startedAt: DateTime(2026, 7, 9, 8),
        ),
      ],
      events: [
        TaskEventRecord(
          id: 'event-1',
          taskId: 'task-failed',
          runId: 'run-1',
          kind: TaskEventKind.system,
          text: 'Runtime unavailable for Codex.',
          createdAt: DateTime(2026, 7, 9, 8),
          metadata: const {'runtime_availability': 'unavailable'},
        ),
      ],
    );

    final notifications = buildTaskNotifications(snapshot);

    expect(
      notifications.map((notification) => notification.kind),
      containsAll([
        TaskNotificationKind.needsHumanReview,
        TaskNotificationKind.taskFailed,
        TaskNotificationKind.runtimeUnavailable,
      ]),
    );
  });

  test(
    'task identifier helpers format task id, branch, and commit subject',
    () {
      final task = _task(
        'IANVS-123',
        TaskStatus.inbox,
      ).copyWith(title: 'Fix Login Flow!');

      expect(taskIdentifierLine(task), 'Task ID: IANVS-123');
      expect(taskBranchName(task), 'ianvs/IANVS-123-fix-login-flow');
      expect(
        taskCommitSubject(task, 'fix login flow'),
        'IANVS-123: fix login flow',
      );
    },
  );
}

TaskRecord _task(String id, TaskStatus status) {
  return TaskRecord(
    id: id,
    title: id,
    description: '',
    workspacePath: '/workspace/app',
    agentName: 'Codex',
    status: status,
    priority: TaskPriority.normal,
    createdAt: DateTime(2026, 7, 9, 8),
    updatedAt: DateTime(2026, 7, 9, 8),
  );
}

class _Ids {
  var _next = 0;

  String next(String prefix) => '$prefix-${++_next}';
}

class _MemoryTaskStore implements TaskStore {
  TaskInboxSnapshot _snapshot = TaskInboxSnapshot.empty();

  @override
  Future<TaskInboxSnapshot> load() async => _snapshot;

  @override
  Future<void> save(TaskInboxSnapshot snapshot) async {
    _snapshot = snapshot;
  }
}
