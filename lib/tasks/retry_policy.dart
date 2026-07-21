enum TaskFailureReason {
  runtimeOffline,
  timeout,
  authRequired,
  transientRuntimeError,
  agentError,
  permissionDenied,
  artifactCollectionFailed,
  humanRejected,
}

class RetryPolicy {
  const RetryPolicy({
    this.baseDelay = const Duration(seconds: 30),
    this.runtimeOfflineRetries = 2,
    this.timeoutRetries = 1,
    this.transientRuntimeErrorRetries = 2,
  });

  final Duration baseDelay;
  final int runtimeOfflineRetries;
  final int timeoutRetries;
  final int transientRuntimeErrorRetries;

  bool shouldRetry(TaskFailureReason reason, int attempt) {
    if (attempt < 1) return false;
    return attempt <= _retryLimit(reason);
  }

  Duration delayForAttempt(int attempt) {
    if (attempt <= 1) return baseDelay;
    if (baseDelay == Duration.zero) return Duration.zero;
    final multiplier = 1 << (attempt - 1);
    return baseDelay * multiplier;
  }

  int _retryLimit(TaskFailureReason reason) {
    return switch (reason) {
      TaskFailureReason.runtimeOffline => runtimeOfflineRetries,
      TaskFailureReason.timeout => timeoutRetries,
      TaskFailureReason.transientRuntimeError => transientRuntimeErrorRetries,
      TaskFailureReason.authRequired ||
      TaskFailureReason.agentError ||
      TaskFailureReason.permissionDenied ||
      TaskFailureReason.artifactCollectionFailed ||
      TaskFailureReason.humanRejected => 0,
    };
  }
}

TaskFailureReason taskFailureReasonFromText(String? text) {
  final normalized = _normalizedFailureText(text);
  if (normalized.contains('runtimeoffline') ||
      normalized.contains('runtimeoff line') ||
      normalized.contains('offline') ||
      normalized.contains('noacpcontroller') ||
      normalized.contains('noagentcontroller') ||
      normalized.contains('controllerunavailable')) {
    return TaskFailureReason.runtimeOffline;
  }
  if (normalized.contains('timeout') || normalized.contains('timedout')) {
    return TaskFailureReason.timeout;
  }
  if (normalized.contains('authrequired') ||
      normalized.contains('authenticationrequired') ||
      normalized.contains('auth required') ||
      normalized.contains('authentication required') ||
      normalized.contains('loginrequired') ||
      normalized.contains('login required')) {
    return TaskFailureReason.authRequired;
  }
  if (normalized.contains('permissiondenied') ||
      normalized.contains('permission denied')) {
    return TaskFailureReason.permissionDenied;
  }
  if (normalized.contains('humanrejected') ||
      normalized.contains('human rejected')) {
    return TaskFailureReason.humanRejected;
  }
  if (normalized.contains('artifactcollectionfailed') ||
      normalized.contains('artifact collection failed')) {
    return TaskFailureReason.artifactCollectionFailed;
  }
  if (normalized.contains('transientruntimeerror') ||
      normalized.contains('transient runtime error')) {
    return TaskFailureReason.transientRuntimeError;
  }
  return TaskFailureReason.agentError;
}

String taskFailureReasonLabel(TaskFailureReason reason) {
  return switch (reason) {
    TaskFailureReason.runtimeOffline => 'Runtime unavailable',
    TaskFailureReason.timeout => 'Task timed out',
    TaskFailureReason.authRequired => 'Authentication required',
    TaskFailureReason.transientRuntimeError => 'Transient runtime error',
    TaskFailureReason.agentError => 'Agent error',
    TaskFailureReason.permissionDenied => 'Permission denied',
    TaskFailureReason.artifactCollectionFailed => 'Artifact collection failed',
    TaskFailureReason.humanRejected => 'Human rejected',
  };
}

String _normalizedFailureText(String? text) {
  return (text ?? '')
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[_:\-]+'), '')
      .replaceAll(RegExp(r'\s+'), ' ');
}
