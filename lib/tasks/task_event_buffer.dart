import 'dart:async';

import 'task_record.dart';

typedef TaskEventBufferWriter = Future<void> Function(BufferedTaskEvent event);

typedef TaskEventBufferScheduler =
    TaskEventBufferTimer Function(Duration delay, void Function() callback);

abstract interface class TaskEventBufferTimer {
  void cancel();
}

class BufferedTaskEvent {
  BufferedTaskEvent({
    required this.kind,
    required this.text,
    this.sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) : metadata = Map<String, Object?>.unmodifiable(metadata);

  final TaskEventKind kind;
  final String text;
  final String? sessionId;
  final Map<String, Object?> metadata;
}

/// Coalesces consecutive assistant text deltas without reordering boundaries.
///
/// Writes are serialized. Tool, status, permission, and other boundary work is
/// queued after the current assistant text and before any later assistant text.
class TaskEventBuffer {
  TaskEventBuffer({
    required this.write,
    this.flushInterval = const Duration(milliseconds: 200),
    TaskEventBufferScheduler? scheduler,
  }) : _scheduler = scheduler ?? _defaultTaskEventBufferScheduler,
       assert(flushInterval > Duration.zero);

  final TaskEventBufferWriter write;
  final Duration flushInterval;
  final TaskEventBufferScheduler _scheduler;

  Future<void> _writeTail = Future<void>.value();
  _PendingAssistantEvent? _pendingAssistant;
  TaskEventBufferTimer? _flushTimer;
  int _flushTimerGeneration = 0;
  Object? _firstWriteError;
  StackTrace? _firstWriteStackTrace;
  bool _disposed = false;
  Future<void>? _disposeFuture;

  void addAssistantDelta(
    String text, {
    String? sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    _ensureOpen();
    if (text.isEmpty) return;
    final pending = _pendingAssistant;
    if (pending != null && pending.sessionId == sessionId) {
      pending.text.write(text);
      pending.metadata.addAll(metadata);
      return;
    }
    if (pending != null) {
      _enqueuePending(_takePendingAssistant()!);
    }
    _pendingAssistant = _PendingAssistantEvent(
      text: StringBuffer(text),
      sessionId: sessionId,
      metadata: Map<String, Object?>.of(metadata),
    );
    _scheduleFlush();
  }

  /// Queues a non-delta event after flushing the current assistant text.
  ///
  /// Call [flush] to surface a deferred writer failure.
  Future<void> addEvent({
    required TaskEventKind kind,
    required String text,
    String? sessionId,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return addBoundaryOperation(
      () => write(
        BufferedTaskEvent(
          kind: kind,
          text: text,
          sessionId: sessionId,
          metadata: metadata,
        ),
      ),
    );
  }

  /// Serializes arbitrary boundary work with assistant text persistence.
  ///
  /// This is useful when a boundary also changes task state and must complete
  /// before later assistant deltas are persisted.
  Future<void> addBoundaryOperation(Future<void> Function() operation) {
    _ensureOpen();
    final pending = _takePendingAssistant();
    _enqueueWrite(() async {
      if (pending != null) await write(pending.toEvent());
      await operation();
    });
    return _writeTail;
  }

  Future<void> flush() async {
    if (_disposed) {
      final disposing = _disposeFuture;
      if (disposing != null) {
        await disposing;
        return;
      }
    }
    while (true) {
      final pending = _takePendingAssistant();
      if (pending != null) _enqueuePending(pending);
      final tail = _writeTail;
      await tail;
      if (identical(tail, _writeTail) && _pendingAssistant == null) break;
    }
    _throwFirstWriteError();
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) return existing;
    _disposed = true;
    final disposing = _finishDispose();
    _disposeFuture = disposing;
    return disposing;
  }

  Future<void> _finishDispose() async {
    final pending = _takePendingAssistant();
    if (pending != null) _enqueuePending(pending);
    await _writeTail;
    _throwFirstWriteError();
  }

  void _scheduleFlush() {
    if (_flushTimer != null) return;
    final generation = ++_flushTimerGeneration;
    _flushTimer = _scheduler(flushInterval, () {
      if (generation != _flushTimerGeneration) return;
      _flushTimer = null;
      final pending = _pendingAssistant;
      _pendingAssistant = null;
      if (pending != null) _enqueuePending(pending);
    });
  }

  _PendingAssistantEvent? _takePendingAssistant() {
    final timer = _flushTimer;
    if (timer != null) {
      _flushTimer = null;
      _flushTimerGeneration += 1;
      timer.cancel();
    }
    final pending = _pendingAssistant;
    _pendingAssistant = null;
    return pending;
  }

  void _enqueuePending(_PendingAssistantEvent pending) {
    _enqueueWrite(() => write(pending.toEvent()));
  }

  void _enqueueWrite(Future<void> Function() operation) {
    _writeTail = _writeTail.then((_) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        _firstWriteError ??= error;
        _firstWriteStackTrace ??= stackTrace;
      }
    });
  }

  Never _throwWriteError(Object error, StackTrace stackTrace) {
    Error.throwWithStackTrace(error, stackTrace);
  }

  void _throwFirstWriteError() {
    final error = _firstWriteError;
    if (error == null) return;
    _throwWriteError(error, _firstWriteStackTrace ?? StackTrace.current);
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('TaskEventBuffer has been disposed.');
  }
}

TaskEventBufferTimer _defaultTaskEventBufferScheduler(
  Duration delay,
  void Function() callback,
) {
  return _DartTaskEventBufferTimer(Timer(delay, callback));
}

class _DartTaskEventBufferTimer implements TaskEventBufferTimer {
  const _DartTaskEventBufferTimer(this.timer);

  final Timer timer;

  @override
  void cancel() => timer.cancel();
}

class _PendingAssistantEvent {
  _PendingAssistantEvent({
    required this.text,
    required this.sessionId,
    required this.metadata,
  });

  final StringBuffer text;
  final String? sessionId;

  /// Metadata keys are unioned across a merged delta group; later deltas win
  /// when the same key is emitted more than once.
  final Map<String, Object?> metadata;

  BufferedTaskEvent toEvent() {
    return BufferedTaskEvent(
      kind: TaskEventKind.assistant,
      text: text.toString(),
      sessionId: sessionId,
      metadata: metadata,
    );
  }
}
