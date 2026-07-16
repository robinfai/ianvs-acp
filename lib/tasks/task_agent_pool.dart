import 'dart:async';

import '../state/chat_controller.dart';
import '../state/connection_state.dart';
import 'runtime_registry.dart';

typedef TaskAgentControllerFactory = ChatController? Function(String agentName);

abstract interface class TaskAgentLease {
  String get agentName;

  ChatController get controller;

  Future<void> release();

  Future<void> invalidate({
    Duration cancellationTimeout = ChatController.defaultCleanupTimeout,
  });
}

abstract interface class TaskAgentPool {
  Future<TaskAgentLease?> tryAcquire(String agentName);

  Future<LocalRuntimeStatus> probeAgent(String agentName);

  Future<void> dispose();
}

abstract interface class ResettableTaskAgentPool implements TaskAgentPool {
  Future<void> resetAgent(String agentName);
}

abstract interface class AuthenticatableTaskAgentPool implements TaskAgentPool {
  Future<bool> authenticateAgent(String agentName, String methodId);
}

class TaskAgentUnavailableException implements Exception {
  const TaskAgentUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalTaskAgentPool
    implements
        TaskAgentPool,
        ResettableTaskAgentPool,
        AuthenticatableTaskAgentPool {
  LocalTaskAgentPool({
    required this.controllerFactory,
    DateTime Function()? clock,
    this.connectTimeout = const Duration(seconds: 10),
  }) : _clock = clock ?? DateTime.now,
       assert(connectTimeout > Duration.zero);

  final TaskAgentControllerFactory controllerFactory;
  final DateTime Function() _clock;
  final Duration connectTimeout;
  final Map<String, _TaskAgentEntry> _entries = <String, _TaskAgentEntry>{};
  bool _closing = false;
  Future<void>? _disposeFuture;

  @override
  Future<TaskAgentLease?> tryAcquire(String agentName) async {
    if (_closing) {
      throw StateError('The background task agent pool is closed.');
    }
    final key = _agentKey(agentName);
    final entry = _entryFor(key);
    if (entry.leaseToken != null ||
        entry.controller.isStreaming ||
        entry.controller.isSessionOperationRunning) {
      return null;
    }
    final token = Object();
    entry.leaseToken = token;
    return _LocalTaskAgentLease(
      agentName: key,
      controller: entry.controller,
      releaseCallback: () => _release(key, entry, token),
      invalidateCallback: (cancellationTimeout) =>
          _invalidate(key, entry, token, cancellationTimeout),
    );
  }

  @override
  Future<LocalRuntimeStatus> probeAgent(String agentName) async {
    final key = _agentKey(agentName);
    final checkedAt = _clock();
    if (_closing) {
      return LocalRuntimeStatus.unavailable(
        agentName: key,
        checkedAt: checkedAt,
        reason: 'The background task agent pool is closed.',
      );
    }

    _TaskAgentEntry entry;
    try {
      entry = _entryFor(key);
    } on TaskAgentUnavailableException catch (error) {
      return LocalRuntimeStatus.unavailable(
        agentName: key,
        checkedAt: checkedAt,
        reason: error.message,
      );
    } on Object catch (error) {
      return LocalRuntimeStatus.misconfigured(
        agentName: key,
        checkedAt: checkedAt,
        reason: '$error',
      );
    }

    final controller = entry.controller;
    if (entry.leaseToken != null ||
        controller.isStreaming ||
        controller.isSessionOperationRunning) {
      return LocalRuntimeStatus.busy(
        agentName: key,
        checkedAt: checkedAt,
        reason: 'The background task agent is already leased.',
      );
    }
    final previousError = controller.lastError?.trim();
    if (controller.status == ConnectionStatus.error &&
        _looksLikeAuthRequired(previousError)) {
      return LocalRuntimeStatus.authRequired(
        agentName: key,
        checkedAt: checkedAt,
        reason: previousError,
      );
    }
    if (controller.status == ConnectionStatus.disconnected ||
        controller.status == ConnectionStatus.error) {
      try {
        await controller.connect().timeout(connectTimeout);
      } on TimeoutException {
        await _retireEntry(key, entry);
        return LocalRuntimeStatus.unavailable(
          agentName: key,
          checkedAt: checkedAt,
          reason: 'Background ACP agent connection timed out.',
        );
      } on Object catch (error) {
        return LocalRuntimeStatus.unavailable(
          agentName: key,
          checkedAt: checkedAt,
          reason: '$error',
        );
      }
    }
    if (_closing || !identical(_entries[key], entry)) {
      return LocalRuntimeStatus.unavailable(
        agentName: key,
        checkedAt: checkedAt,
        reason: 'The background task agent pool is closed.',
      );
    }
    final lastError = controller.lastError?.trim();
    if (controller.status == ConnectionStatus.error) {
      if (_looksLikeAuthRequired(lastError)) {
        return LocalRuntimeStatus.authRequired(
          agentName: key,
          checkedAt: checkedAt,
          reason: lastError ?? 'Authentication is required.',
        );
      }
      return LocalRuntimeStatus.unavailable(
        agentName: key,
        checkedAt: checkedAt,
        reason: lastError ?? 'Agent connection is in an error state.',
      );
    }
    if (controller.isStreaming || controller.isSessionOperationRunning) {
      return LocalRuntimeStatus.busy(
        agentName: key,
        checkedAt: checkedAt,
        reason: 'The background task agent is already leased.',
      );
    }
    return LocalRuntimeStatus.available(
      agentName: key,
      checkedAt: checkedAt,
      supportsSessionResume: controller.canResumeSessions,
      supportsPermissions: controller.hasPermissionReviewer,
      maxConcurrentTasks: 1,
    );
  }

  @override
  Future<void> resetAgent(String agentName) async {
    if (_closing) {
      throw StateError('The background task agent pool is closed.');
    }
    final key = _agentKey(agentName);
    final entry = _entries[key];
    if (entry == null) return;
    if (entry.leaseToken != null) {
      throw StateError('The background task agent is currently leased.');
    }
    await _retireEntry(key, entry);
  }

  @override
  Future<bool> authenticateAgent(String agentName, String methodId) async {
    if (_closing) return false;
    final key = _agentKey(agentName);
    final entry = _entryFor(key);
    final controller = entry.controller;
    if (entry.leaseToken != null ||
        controller.isStreaming ||
        controller.isSessionOperationRunning) {
      return false;
    }
    if (controller.status == ConnectionStatus.disconnected ||
        (controller.status == ConnectionStatus.error &&
            !controller.canAuthenticate)) {
      try {
        await controller.connect().timeout(connectTimeout);
      } on TimeoutException {
        await _retireEntry(key, entry);
        return false;
      }
    }
    if (_closing || !identical(_entries[key], entry)) return false;
    return controller.authenticate(methodId);
  }

  @override
  Future<void> dispose() {
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    _closing = true;
    final entries = _entries.values.toList(growable: false);
    _entries.clear();
    await Future.wait(
      entries.map((entry) async {
        try {
          await entry.controller.shutdown();
        } on Object {
          // Pool shutdown is best effort across independent agents.
        }
      }),
    );
  }

  Future<void> _retireEntry(String key, _TaskAgentEntry entry) async {
    if (identical(_entries[key], entry)) {
      _entries.remove(key);
    }
    try {
      await entry.controller.shutdown();
    } on Object {
      // A replacement controller must still be allowed after cleanup errors.
    }
  }

  _TaskAgentEntry _entryFor(String key) {
    final existing = _entries[key];
    if (existing != null) return existing;
    final controller = controllerFactory(key);
    if (controller == null) {
      throw TaskAgentUnavailableException(
        'No background ACP controller is configured for $key.',
      );
    }
    final entry = _TaskAgentEntry(controller);
    _entries[key] = entry;
    return entry;
  }

  void _release(String key, _TaskAgentEntry entry, Object token) {
    if (!identical(_entries[key], entry) ||
        !identical(entry.leaseToken, token)) {
      return;
    }
    entry.leaseToken = null;
  }

  Future<void> _invalidate(
    String key,
    _TaskAgentEntry entry,
    Object token,
    Duration cancellationTimeout,
  ) async {
    if (!identical(entry.leaseToken, token)) return;
    entry.leaseToken = null;
    if (identical(_entries[key], entry)) {
      _entries.remove(key);
    }
    try {
      await entry.controller.shutdown(cancellationTimeout: cancellationTimeout);
    } on Object {
      // A failed agent instance must not remain available for another task.
    }
  }
}

class _TaskAgentEntry {
  _TaskAgentEntry(this.controller);

  final ChatController controller;
  Object? leaseToken;
}

class _LocalTaskAgentLease implements TaskAgentLease {
  _LocalTaskAgentLease({
    required this.agentName,
    required this.controller,
    required this._releaseCallback,
    required this._invalidateCallback,
  });

  @override
  final String agentName;

  @override
  final ChatController controller;

  void Function()? _releaseCallback;
  Future<void> Function(Duration cancellationTimeout)? _invalidateCallback;

  @override
  Future<void> release() async {
    final callback = _releaseCallback;
    if (callback == null) return;
    _releaseCallback = null;
    _invalidateCallback = null;
    callback();
  }

  @override
  Future<void> invalidate({
    Duration cancellationTimeout = ChatController.defaultCleanupTimeout,
  }) async {
    final callback = _invalidateCallback;
    if (callback == null) return;
    _invalidateCallback = null;
    _releaseCallback = null;
    await callback(cancellationTimeout);
  }
}

String _agentKey(String agentName) {
  final trimmed = agentName.trim();
  if (trimmed.isEmpty) {
    throw const TaskAgentUnavailableException(
      'A background task agent name is required.',
    );
  }
  return trimmed;
}

bool _looksLikeAuthRequired(String? message) {
  final lower = message?.toLowerCase();
  if (lower == null || lower.isEmpty) return false;
  return lower.contains('auth') ||
      lower.contains('login') ||
      lower.contains('credential');
}
