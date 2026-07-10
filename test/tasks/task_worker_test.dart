import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/fake_agent_client.dart';
import 'package:ianvs_acp/state/chat_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_record.dart';
import 'package:ianvs_acp/tasks/task_runner.dart';
import 'package:ianvs_acp/tasks/task_worker.dart';

import '../support/memory_task_repository.dart';

void main() {
  test('TaskRunnerWorker delegates to TaskRunner.runTask', () async {
    final store = _MemoryTaskStore();
    final taskController = TaskInboxController(
      repository: store,
      clock: () => DateTime(2026, 7, 9, 9),
      idGenerator: _DeterministicIds().next,
    );
    addTearDown(taskController.dispose);
    await taskController.load();
    final task = await taskController.createTask(
      title: 'Worker task',
      description: 'Run through worker.',
      workspacePath: '/workspace/app',
      agentName: 'Codex',
    );
    final fake = FakeAgentClient();
    final chat = ChatController(
      client: fake,
      cwd: '/workspace/default',
      agentName: 'Codex',
    );
    addTearDown(chat.dispose);
    final runner = TaskRunner(
      taskController: taskController,
      controllerForAgent: (_) => chat,
    );
    final worker = TaskRunnerWorker(runner: runner);

    final result = await worker.run(task);

    expect(result.status, TaskStatus.needsHumanReview);
    expect(fake.lastPrompt, contains('Task ID: task-1'));
    expect(taskController.runs.single.status, TaskStatus.needsHumanReview);
  });
}

class _MemoryTaskStore extends MemoryTaskRepository {}

class _DeterministicIds {
  final Map<String, int> _counts = <String, int>{};

  String next(String prefix) {
    final count = (_counts[prefix] ?? 0) + 1;
    _counts[prefix] = count;
    return '$prefix-$count';
  }
}
