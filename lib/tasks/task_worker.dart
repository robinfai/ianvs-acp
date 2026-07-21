import 'task_record.dart';
import 'task_repository.dart';
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

abstract interface class TaskWorkerReservation implements TaskWorkerLease {
  String get reservationId;

  String get agentName;

  String get hostInstanceId;

  DateTime get createdAt;

  DateTime get expiresAt;

  TaskCapacityReservation get capacityReservation;
}

abstract interface class ReservableTaskWorker implements TaskWorker {
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task);
}

abstract interface class CapacityReservableTaskWorker implements TaskWorker {
  Future<TaskWorkerReservation?> tryReserveAgent(String agentName);
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
        CapacityReservableTaskWorker,
        DisposableTaskWorker,
        ResettableTaskWorker,
        AuthenticatableTaskWorker {
  TaskRunnerWorker({
    required this.runner,
    DateTime Function()? clock,
    this.reservationTtl = const Duration(seconds: 5),
    String? hostInstanceId,
  }) : _clock = clock ?? DateTime.now,
       hostInstanceId =
           hostInstanceId ??
           'flutter-${identityHashCode(runner).toRadixString(16)}' {
    if (reservationTtl <= Duration.zero) {
      throw ArgumentError.value(
        reservationTtl,
        'reservationTtl',
        'must be positive',
      );
    }
  }

  final TaskRunner runner;
  final DateTime Function() _clock;
  final Duration reservationTtl;
  final String hostInstanceId;
  int _reservationSequence = 0;

  @override
  Future<TaskRecord> run(TaskRecord task) => runner.runTask(task.id);

  @override
  Future<void> cancelActive() => runner.cancelActive();

  @override
  Future<TaskWorkerLease?> tryAcquire(TaskRecord task) async {
    return tryReserveAgent(task.agentName);
  }

  @override
  Future<TaskWorkerReservation?> tryReserveAgent(String agentName) async {
    final lease = await runner.tryAcquireAgentName(agentName);
    if (lease == null) return null;
    final createdAt = _clock();
    _reservationSequence += 1;
    return _TaskRunnerWorkerLease(
      runner: runner,
      agentLease: lease,
      reservationId:
          '$hostInstanceId-${createdAt.microsecondsSinceEpoch}-$_reservationSequence',
      hostInstanceId: hostInstanceId,
      createdAt: createdAt,
      expiresAt: createdAt.add(reservationTtl),
    );
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

class _TaskRunnerWorkerLease implements TaskWorkerReservation {
  _TaskRunnerWorkerLease({
    required this.runner,
    required this.agentLease,
    required this.reservationId,
    required this.hostInstanceId,
    required this.createdAt,
    required this.expiresAt,
  });

  final TaskRunner runner;
  final TaskAgentLease agentLease;
  bool _used = false;

  @override
  final String reservationId;

  @override
  String get agentName => agentLease.agentName;

  @override
  final String hostInstanceId;

  @override
  final DateTime createdAt;

  @override
  final DateTime expiresAt;

  @override
  TaskCapacityReservation get capacityReservation => TaskCapacityReservation(
    reservationId: reservationId,
    agentName: agentName,
    hostInstanceId: hostInstanceId,
    createdAt: createdAt,
    expiresAt: expiresAt,
  );

  @override
  Future<TaskRecord> run(TaskRecord task) {
    if (_used) throw StateError('Task worker lease has already been used.');
    if (task.agentName.trim() != agentName) {
      throw StateError('Task worker reservation Agent does not match.');
    }
    _used = true;
    return runner.runTaskWithLease(task.id, agentLease);
  }

  @override
  Future<void> release() => agentLease.release();
}
