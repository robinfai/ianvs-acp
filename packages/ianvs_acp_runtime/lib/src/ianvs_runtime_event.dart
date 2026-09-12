import 'dart:collection';

enum IanvsRuntimeEventType {
  sessionUpdate,
  renderUpdate,
  renderSnapshotChunk,
  sessionCatalog,
  authenticationChanged,
  permissionRequest,
  statusChanged,
  stderrLog,
  terminalAttached,
  terminalOutput,
  terminalExited,
  terminalReleased,
  runtimeError,
}

final class IanvsRuntimeEvent {
  IanvsRuntimeEvent._({
    required this.schemaVersion,
    required this.sequence,
    required this.type,
    required Map<String, Object?> data,
  }) : data = UnmodifiableMapView(data);

  factory IanvsRuntimeEvent.fromJson(Map<String, Object?> json) {
    final schemaVersion = json['schemaVersion'];
    final sequence = json['sequence'];
    final rawType = json['type'];
    if (schemaVersion is! int || schemaVersion != supportedSchemaVersion) {
      throw FormatException(
        'Unsupported ianvs Rust event schema: $schemaVersion',
      );
    }
    if (sequence is! int || sequence < 1) {
      throw const FormatException(
        'Rust event sequence must be a positive int.',
      );
    }
    if (rawType is! String) {
      throw const FormatException('Rust event type must be a string.');
    }
    final type = switch (rawType) {
      'session_update' => IanvsRuntimeEventType.sessionUpdate,
      'render_update' => IanvsRuntimeEventType.renderUpdate,
      'render_snapshot_chunk' => IanvsRuntimeEventType.renderSnapshotChunk,
      'session_catalog' => IanvsRuntimeEventType.sessionCatalog,
      'authentication_changed' => IanvsRuntimeEventType.authenticationChanged,
      'permission_request' => IanvsRuntimeEventType.permissionRequest,
      'status_changed' => IanvsRuntimeEventType.statusChanged,
      'stderr_log' => IanvsRuntimeEventType.stderrLog,
      'terminal_attached' => IanvsRuntimeEventType.terminalAttached,
      'terminal_output' => IanvsRuntimeEventType.terminalOutput,
      'terminal_exited' => IanvsRuntimeEventType.terminalExited,
      'terminal_released' => IanvsRuntimeEventType.terminalReleased,
      'runtime_error' => IanvsRuntimeEventType.runtimeError,
      _ => throw FormatException('Unknown Rust event type: $rawType'),
    };
    return IanvsRuntimeEvent._(
      schemaVersion: schemaVersion,
      sequence: sequence,
      type: type,
      data: Map<String, Object?>.unmodifiable(json),
    );
  }

  static const int supportedSchemaVersion = 4;

  final int schemaVersion;
  final int sequence;
  final IanvsRuntimeEventType type;
  final Map<String, Object?> data;

  Map<String, Object?>? get update => _objectMap(data['update']);

  Map<String, Object?>? get renderUpdate => _objectMap(data['update']);

  List<Map<String, Object?>> get renderUpdates =>
      (data['updates'] as List? ?? const <Object?>[])
          .map(_objectMap)
          .whereType<Map<String, Object?>>()
          .toList(growable: false);

  Map<String, Object?>? get permissionRequest => _objectMap(data['request']);

  List<Map<String, Object?>> get sessions =>
      (data['sessions'] as List? ?? const <Object?>[])
          .map(_objectMap)
          .whereType<Map<String, Object?>>()
          .toList(growable: false);

  String? get status => data['status'] as String?;

  String? get errorCode => data['code'] as String?;

  String? get errorMessage => data['message'] as String?;

  String? get requestId => data['requestId'] as String?;

  bool get recoverable => data['recoverable'] == true;
}

Map<String, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map((key, value) => MapEntry(key.toString(), value));
}
