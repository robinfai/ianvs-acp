import 'task_record.dart';
import 'task_runner.dart';
import 'task_agent_pool.dart';

abstract interface class TaskWorker {
  Future<TaskRecord> run(TaskRecord task);
}

abstract interface class CancellableTaskWorker implements TaskWorker {
  Future<void> cancelActive();
}

abstract interface class TaskWorkerLease {
  Future<TaskRecord> run(TaskRecord task);

  Future<void> release();
}

abstract interface class ReservableTaskWorker implements TaskWorker {
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task);
}

abstract interface class DisposableTaskWorker implements TaskWorker {
  Future<void> dispose();
}

abstract interface class ResettableTaskWorker implements TaskWorker {
  Future<void> resetAgent(String agentName);
}

abstract interface class AuthenticatableTaskWorker implements TaskWorker {
  Future<bool> authenticateAgent(String agentName, String methodId);
}

class TaskRunnerWorker
    implements
        CancellableTaskWorker,
        ReservableTaskWorker,
        DisposableTaskWorker,
        ResettableTaskWorker,
        AuthenticatableTaskWorker {
  const TaskRunnerWorker({required this.runner});

  final TaskRunner runner;

  @override
  Future<TaskRecord> run(TaskRecord task) => runner.runTask(task.id);

  @override
  Future<void> cancelActive() => runner.cancelActive();

  @override
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task) async {
    final lease = await runner.tryAcquireAgent(task);
    if (lease == null) return null;
    return _TaskRunnerWorkerLease(runner: runner, agentLease: lease);
  }

  @override
  Future<void> dispose() => runner.dispose();

  @override
  Future<void> resetAgent(String agentName) => runner.resetAgent(agentName);

  @override
  Future<bool> authenticateAgent(String agentName, String methodId) {
    return runner.authenticateAgent(agentName, methodId);
  }
}

class _TaskRunnerWorkerLease implements TaskWorkerLease {
  _TaskRunnerWorkerLease({required this.runner, required this.agentLease});

  final TaskRunner runner;
  final TaskAgentLease agentLease;
  bool _used = false;

  @override
  Future<TaskRecord> run(TaskRecord task) {
    if (_used) throw StateError('Task worker lease has already been used.');
    _used = true;
    return runner.runTaskWithLease(task.id, agentLease);
  }

  @override
  Future<void> release() => agentLease.release();
}
