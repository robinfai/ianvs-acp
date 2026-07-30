import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../tasks/task_inbox_snapshot.dart';
import 'ianvs_workflow_native.dart';

final class IanvsDaemonProcess {
  IanvsDaemonProcess._();

  static String socketPathForDatabase(String databasePath) {
    final digest = sha256.convert(utf8.encode(databasePath)).toString();
    return '/private/tmp/ianvs-acpd-${digest.substring(0, 32)}.sock';
  }

  static Future<String> ensureRunning({
    required String databasePath,
    String? socketPath,
    String? binaryPath,
    int? maxDatabaseBytes,
    int? retentionDays,
    Duration startupTimeout = const Duration(seconds: 5),
  }) async {
    final resolvedSocket = socketPath ?? socketPathForDatabase(databasePath);
    if (await _canConnect(resolvedSocket)) return resolvedSocket;
    final resolvedBinary = binaryPath ?? _resolveBinaryPath();
    await Process.start(resolvedBinary, <String>[
      '--database',
      databasePath,
      '--socket',
      resolvedSocket,
      if (maxDatabaseBytes != null) ...[
        '--max-database-bytes',
        maxDatabaseBytes.toString(),
      ],
      if (retentionDays != null) ...[
        '--retention-days',
        retentionDays.toString(),
      ],
    ], mode: ProcessStartMode.detached);
    final deadline = DateTime.now().add(startupTimeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _canConnect(resolvedSocket)) return resolvedSocket;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw StateError('ianvs-acpd did not become ready at $resolvedSocket.');
  }

  static Future<bool> _canConnect(String socketPath) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        InternetAddress(socketPath, type: InternetAddressType.unix),
        0,
        timeout: const Duration(milliseconds: 150),
      );
      return true;
    } on Object {
      return false;
    } finally {
      await socket?.close();
    }
  }

  static String _resolveBinaryPath() {
    final override = Platform.environment['IANVS_ACPD_BINARY']?.trim();
    if (override != null && override.isNotEmpty) return override;
    final adjacent = File(
      '${File(Platform.resolvedExecutable).parent.path}/ianvs-acpd',
    );
    if (adjacent.existsSync()) return adjacent.path;
    final development = File(
      '${Directory.current.path}/rust/target/debug/ianvs-acpd',
    );
    if (development.existsSync()) return development.path;
    throw StateError(
      'ianvs-acpd binary was not found beside the app or in rust/target/debug.',
    );
  }
}

final class IanvsDaemonWorkflow
    implements IanvsWorkflowAuthority, IanvsStoragePolicyAuthority {
  IanvsDaemonWorkflow({required this.socketPath});

  static const int protocolVersion = 1;
  static const int maxRequestBytes = 16 * 1024 * 1024;
  static const int maxResponseBytes = 32 * 1024 * 1024;

  final String socketPath;
  Socket? _socket;
  StreamIterator<String>? _lines;
  Future<void> _tail = Future<void>.value();
  int _nextRequestId = 0;
  bool _disposed = false;

  @override
  Future<void> configureStorage({
    required int maxDatabaseBytes,
    required int retentionDays,
  }) async {
    final result = await _call(<String, Object?>{
      'operation': 'configure_storage',
      'maxDatabaseBytes': maxDatabaseBytes,
      'retentionDays': retentionDays,
    });
    _expectType(result, 'ack');
  }

  Future<List<String>> configureAgents(
    List<Map<String, Object?>> agents,
  ) async {
    final result = await _call(<String, Object?>{
      'operation': 'configure_agents',
      'agents': agents,
    });
    _expectType(result, 'agents_configured');
    final names = result['agentNames'];
    if (names is! List || names.any((name) => name is! String)) {
      throw const FormatException('Daemon agentNames must be a string list.');
    }
    return List<String>.unmodifiable(names.cast<String>());
  }

  @override
  Future<IanvsWorkflowProjection> open(String databasePath) async {
    final result = await _call(<String, Object?>{
      'operation': 'open_projection',
      'databasePath': databasePath,
    });
    _expectType(result, 'open_projection');
    return IanvsWorkflowProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<IanvsTaskInboxStageProjection> stageTaskInbox({
    required TaskInboxSnapshot source,
    required String sourceChecksum,
  }) async {
    final result = await _call(<String, Object?>{
      'operation': 'stage_task_inbox',
      'source': source.toJson(),
      'sourceChecksum': sourceChecksum,
    });
    _expectType(result, 'task_inbox_stage');
    return IanvsTaskInboxStageProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<TaskInboxSnapshot?> taskInboxSource() async {
    final result = await _call(<String, Object?>{
      'operation': 'task_inbox_source',
    });
    _expectType(result, 'task_inbox_snapshot');
    final snapshot = result['snapshot'];
    return snapshot == null ? null : TaskInboxSnapshot.fromJsonStrict(snapshot);
  }

  @override
  Future<IanvsTaskInboxMaterializedProjection> materializeTaskInbox() =>
      _taskInboxProjection(<String, Object?>{
        'operation': 'materialize_task_inbox',
      });

  @override
  Future<IanvsTaskInboxMaterializedProjection> activateTaskInbox() =>
      _taskInboxProjection(<String, Object?>{
        'operation': 'activate_task_inbox',
      });

  @override
  Future<IanvsTaskInboxMaterializedProjection> applyTaskInbox(
    IanvsTaskInboxCommand command,
  ) => _taskInboxProjection(<String, Object?>{
    'operation': 'apply_task_inbox',
    'command': command.toJson(),
  });

  @override
  Future<IanvsTaskInboxMaterializedProjection> applyTaskInboxAsExecutor({
    required IanvsExecutorCommandContext context,
    required IanvsTaskInboxCommand command,
  }) => _taskInboxProjection(<String, Object?>{
    'operation': 'apply_task_inbox_as_executor',
    'request': <String, Object?>{
      'context': context.toJson(),
      'command': command.toJson(),
    },
  });

  Future<IanvsTaskInboxMaterializedProjection> _taskInboxProjection(
    Map<String, Object?> command,
  ) async {
    final result = await _call(command);
    _expectType(result, 'task_inbox_projection');
    return IanvsTaskInboxMaterializedProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<IanvsWorkflowProjection> configureScheduler({
    required int maxConcurrentTasks,
    int runtimeStatusFreshnessSeconds = 30,
  }) async {
    final result = await _call(<String, Object?>{
      'operation': 'configure_scheduler',
      'config': <String, Object?>{
        'maxConcurrentTasks': maxConcurrentTasks,
        'runtimeStatusFreshnessSeconds': runtimeStatusFreshnessSeconds,
      },
    });
    _expectType(result, 'workflow_projection');
    return IanvsWorkflowProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<IanvsWorkflowProjection> setSchedulerRuntimeStatus(
    IanvsSchedulerRuntimeStatus status,
  ) async {
    final result = await _call(<String, Object?>{
      'operation': 'set_scheduler_runtime_status',
      'status': status.toJson(),
    });
    _expectType(result, 'workflow_projection');
    return IanvsWorkflowProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<IanvsSchedulerClaimProjection> schedulerClaimNext({
    required String runId,
    required String dispatchEventId,
    required String executorLeaseId,
    required String executorId,
    required String commandId,
    required DateTime now,
    required DateTime leaseExpiresAt,
    List<String> excludedTaskIds = const <String>[],
    List<IanvsSchedulerCapacityReservation> capacityReservations =
        const <IanvsSchedulerCapacityReservation>[],
  }) async {
    final result = await _call(<String, Object?>{
      'operation': 'scheduler_claim_next',
      'request': <String, Object?>{
        'runId': runId,
        'dispatchEventId': dispatchEventId,
        'executorLeaseId': executorLeaseId,
        'executorId': executorId,
        'commandId': commandId,
        'now': now.toIso8601String(),
        'leaseExpiresAt': leaseExpiresAt.toIso8601String(),
        'excludedTaskIds': excludedTaskIds,
        'capacityReservations': capacityReservations
            .map((reservation) => reservation.toJson())
            .toList(growable: false),
      },
    });
    _expectType(result, 'scheduler_claim');
    return IanvsSchedulerClaimProjection.fromJson(
      _map(result['projection'], 'projection'),
    );
  }

  @override
  Future<IanvsExecutorLease?> executorLeaseForRun(String runId) async {
    final result = await _call(<String, Object?>{
      'operation': 'executor_lease_for_run',
      'runId': runId,
    });
    _expectType(result, 'executor_lease');
    final lease = result['lease'];
    return lease == null
        ? null
        : IanvsExecutorLease.fromJson(_map(lease, 'lease'));
  }

  @override
  Future<IanvsExecutorLease> applyExecutorLeaseCommand(
    IanvsExecutorLeaseCommand command,
  ) async {
    final result = await _call(<String, Object?>{
      'operation': 'executor_lease_command',
      'command': command.toJson(),
    });
    _expectType(result, 'executor_lease');
    return IanvsExecutorLease.fromJson(_map(result['lease'], 'lease'));
  }

  @override
  Future<IanvsRuntimeEventPage> runtimeEvents({
    required String runId,
    required int afterSequence,
    int limit = 200,
  }) async {
    final result = await _call(<String, Object?>{
      'operation': 'runtime_events',
      'runId': runId,
      'afterSequence': afterSequence,
      'limit': limit,
    });
    _expectType(result, 'runtime_events');
    return IanvsRuntimeEventPage.fromJson(_map(result['page'], 'page'));
  }

  @override
  Future<TaskInboxSnapshot?> currentTaskInbox() async {
    final result = await _call(<String, Object?>{
      'operation': 'current_task_inbox',
    });
    _expectType(result, 'task_inbox_snapshot');
    final snapshot = result['snapshot'];
    return snapshot == null ? null : TaskInboxSnapshot.fromJsonStrict(snapshot);
  }

  @override
  Future<IanvsTaskInboxMaterializedProjection?>
  currentTaskInboxProjection() async {
    final result = await _call(<String, Object?>{
      'operation': 'current_task_inbox_projection',
    });
    _expectType(result, 'current_task_inbox_projection');
    final projection = result['projection'];
    return projection == null
        ? null
        : IanvsTaskInboxMaterializedProjection.fromJson(
            _map(projection, 'projection'),
          );
  }

  Future<void> shutdownForTesting() async {
    final result = await _call(<String, Object?>{'operation': 'shutdown'});
    _expectType(result, 'ack');
  }

  Future<Map<String, Object?>> _call(Map<String, Object?> command) {
    final completer = Completer<Map<String, Object?>>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await _send(command));
      } on Object catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Map<String, Object?>> _send(Map<String, Object?> command) async {
    if (_disposed) throw StateError('Daemon workflow client is disposed.');
    await _connect();
    final requestId = 'flutter-${++_nextRequestId}';
    final encoded = jsonEncode(<String, Object?>{
      'schemaVersion': protocolVersion,
      'requestId': requestId,
      'command': command,
    });
    if (utf8.encode(encoded).length > maxRequestBytes) {
      throw StateError('ianvs-acpd request exceeded its bounded size.');
    }
    try {
      _socket!.write('$encoded\n');
      await _socket!.flush();
      final lines = _lines;
      if (lines == null || !await lines.moveNext()) {
        throw StateError('ianvs-acpd disconnected before replying.');
      }
      final responseText = lines.current;
      if (responseText.length > maxResponseBytes) {
        throw StateError('ianvs-acpd response exceeded its bounded size.');
      }
      final response = _map(jsonDecode(responseText), 'daemon response');
      if (response['schemaVersion'] != protocolVersion ||
          response['requestId'] != requestId) {
        throw const FormatException('Daemon response envelope is invalid.');
      }
      final result = _map(response['result'], 'daemon result');
      if (result['type'] == 'error') {
        throw StateError(
          'ianvs-acpd ${result['code'] ?? 'error'}: ${result['message']}',
        );
      }
      return result;
    } on Object {
      await _resetConnection();
      rethrow;
    }
  }

  Future<void> _connect() async {
    if (_socket != null) return;
    final socket = await Socket.connect(
      InternetAddress(socketPath, type: InternetAddressType.unix),
      0,
      timeout: const Duration(seconds: 2),
    );
    _socket = socket;
    _lines = StreamIterator<String>(
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter()),
    );
  }

  Future<void> _resetConnection() async {
    final lines = _lines;
    _lines = null;
    await lines?.cancel();
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _tail;
    await _resetConnection();
  }
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is! Map) throw FormatException('$name must be an object.');
  return value.map((key, value) => MapEntry(key.toString(), value));
}

void _expectType(Map<String, Object?> result, String expected) {
  if (result['type'] != expected) {
    throw FormatException(
      'Unexpected daemon result ${result['type']}; expected $expected.',
    );
  }
}
