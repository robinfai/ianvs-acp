import 'task_record.dart';
import 'task_runner.dart';

abstract interface class TaskWorker {
  Future<TaskRecord> run(TaskRecord task);
}

abstract interface class CancellableTaskWorker implements TaskWorker {
  Future<void> cancelActive();
}

class TaskRunnerWorker implements CancellableTaskWorker {
  const TaskRunnerWorker({required this.runner});

  final TaskRunner runner;

  @override
  Future<TaskRecord> run(TaskRecord task) => runner.runTask(task.id);

  @override
  Future<void> cancelActive() => runner.cancelActive();
}
