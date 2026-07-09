import 'task_record.dart';
import 'task_runner.dart';

abstract interface class TaskWorker {
  Future<TaskRecord> run(TaskRecord task);
}

class TaskRunnerWorker implements TaskWorker {
  const TaskRunnerWorker({required this.runner});

  final TaskRunner runner;

  @override
  Future<TaskRecord> run(TaskRecord task) => runner.runTask(task.id);
}
