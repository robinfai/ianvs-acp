import 'dart:async';

import 'package:flutter/foundation.dart';

typedef LocalRuntimeProbe =
    FutureOr<LocalRuntimeStatus> Function(String agentName);

enum RuntimeAvailability {
  unknown,
  available,
  busy,
  unavailable,
  authRequired,
  misconfigured,
}

class LocalRuntimeStatus {
  const LocalRuntimeStatus({
    required this.agentName,
    required this.availability,
    required this.checkedAt,
    this.unavailableReason,
    this.supportsSessionResume = false,
    this.supportsPermissions = false,
    this.maxConcurrentTasks = 1,
  });

  factory LocalRuntimeStatus.unknown({
    required String agentName,
    required DateTime checkedAt,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.unknown,
      checkedAt: checkedAt,
    );
  }

  factory LocalRuntimeStatus.available({
    required String agentName,
    required DateTime checkedAt,
    bool supportsSessionResume = false,
    bool supportsPermissions = false,
    int maxConcurrentTasks = 1,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.available,
      checkedAt: checkedAt,
      supportsSessionResume: supportsSessionResume,
      supportsPermissions: supportsPermissions,
      maxConcurrentTasks: maxConcurrentTasks < 1 ? 1 : maxConcurrentTasks,
    );
  }

  factory LocalRuntimeStatus.unavailable({
    required String agentName,
    required DateTime checkedAt,
    String? reason,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.unavailable,
      checkedAt: checkedAt,
      unavailableReason: _trimmedOrNull(reason),
    );
  }

  factory LocalRuntimeStatus.busy({
    required String agentName,
    required DateTime checkedAt,
    String? reason,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.busy,
      checkedAt: checkedAt,
      unavailableReason: _trimmedOrNull(reason),
    );
  }

  factory LocalRuntimeStatus.authRequired({
    required String agentName,
    required DateTime checkedAt,
    String? reason,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.authRequired,
      checkedAt: checkedAt,
      unavailableReason: _trimmedOrNull(reason),
    );
  }

  factory LocalRuntimeStatus.misconfigured({
    required String agentName,
    required DateTime checkedAt,
    String? reason,
  }) {
    return LocalRuntimeStatus(
      agentName: agentName.trim(),
      availability: RuntimeAvailability.misconfigured,
      checkedAt: checkedAt,
      unavailableReason: _trimmedOrNull(reason),
    );
  }

  final String agentName;
  final RuntimeAvailability availability;
  final DateTime checkedAt;
  final String? unavailableReason;
  final bool supportsSessionResume;
  final bool supportsPermissions;
  final int maxConcurrentTasks;

  bool get available => availability == RuntimeAvailability.available;
}

class LocalRuntimeRegistry extends ChangeNotifier {
  LocalRuntimeRegistry({this.probe, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final LocalRuntimeProbe? probe;
  final DateTime Function() _clock;
  final Map<String, LocalRuntimeStatus> _statuses =
      <String, LocalRuntimeStatus>{};

  LocalRuntimeStatus statusForAgent(String agentName) {
    final key = _agentKey(agentName);
    return _statuses[key] ??
        LocalRuntimeStatus.unknown(agentName: key, checkedAt: _clock());
  }

  Future<LocalRuntimeStatus> probeAgent(String agentName) async {
    final key = _agentKey(agentName);
    final runtimeProbe = probe;
    if (runtimeProbe == null) return statusForAgent(key);
    final status = await runtimeProbe(key);
    setStatus(status);
    return statusForAgent(key);
  }

  Future<List<LocalRuntimeStatus>> probeAll(Iterable<String> agentNames) async {
    final statuses = <LocalRuntimeStatus>[];
    for (final agentName in agentNames) {
      statuses.add(await probeAgent(agentName));
    }
    return List.unmodifiable(statuses);
  }

  void setStatus(LocalRuntimeStatus status) {
    final key = _agentKey(status.agentName);
    _statuses[key] = status;
    notifyListeners();
  }
}

String _agentKey(String agentName) => agentName.trim();

String? _trimmedOrNull(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
