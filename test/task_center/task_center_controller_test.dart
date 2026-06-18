import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/task_center/task_center_controller.dart';
import 'package:ianvs_acp/task_center/task_center_models.dart';
import 'package:ianvs_acp/task_center/task_center_store.dart';

void main() {
  test('answerHumanQuestion refreshes selected workspace state', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs_task_center_controller',
    );
    addTearDown(() => temp.delete(recursive: true));
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 17, 12),
      idGenerator: _IdSequence().next,
    );
    final controller = TaskCenterController(store: store);

    final workspace = await controller.createWorkspace(title: 'Human loop');
    final task = await controller.createTask(
      workspaceId: workspace.id,
      title: 'Confirm work can continue',
      humanQuestions: const <TaskCenterHumanQuestion>[
        TaskCenterHumanQuestion(
          id: 'human-question-1',
          question: 'Can the worker proceed?',
        ),
      ],
      currentOwner: const TaskCenterTaskOwner.human(),
      readiness: TaskCenterReadiness.waitingHuman,
    );

    final answered = await controller.answerHumanQuestion(
      workspaceId: workspace.id,
      taskId: task.id,
      questionId: 'human-question-1',
      answer: '可以继续，按当前验收条件执行。',
    );

    expect(answered.humanQuestions.single.resolved, isTrue);
    expect(answered.humanQuestions.single.answer, contains('可以继续'));
    final reloadedTask = controller.selectedWorkspace!.tasks.single;
    expect(reloadedTask.humanQuestions.single.resolved, isTrue);
    expect(reloadedTask.events.last.type, 'human_question_answered');
  });

  test('controller exposes worker run recovery actions', () async {
    final temp = await Directory.systemTemp.createTemp('ianvs_task_center');
    addTearDown(() => temp.delete(recursive: true));
    final store = TaskCenterStore(
      path: '${temp.path}/task_center.json',
      now: () => DateTime.utc(2026, 6, 17, 19),
      idGenerator: _IdSequence().next,
    );
    final controller = TaskCenterController(store: store);
    final workspace = await controller.createWorkspace(title: 'Controller run');
    final task = await controller.createTask(
      workspaceId: workspace.id,
      title: 'Start run',
    );

    final started = await controller.startWorkRun(
      workspaceId: workspace.id,
      taskId: task.id,
      agentName: 'codex-worker',
    );
    expect(started.workRuns.single.state, TaskCenterWorkRunState.running);

    final stalled = await controller.listStalledWork(workspaceId: workspace.id);
    expect(stalled, isEmpty);
  });
}

class _IdSequence {
  int _next = 1;

  String next() => 'id-${_next++}';
}
