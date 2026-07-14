import 'dart:async';
import 'dart:collection';

/// One decoded non-response JSON-RPC element awaiting processing.
class InboundGateElement {
  const InboundGateElement({required this.method, required this.byteLength});

  /// Method name, when the element is a valid request or notification.
  final String? method;

  /// Canonically encoded UTF-8 byte length for this element.
  final int byteLength;
}

/// A local terminal outcome that may settle queued inbound work.
sealed class InboundGateTerminal<T> {
  const InboundGateTerminal();
}

/// A local terminal value for queued inbound work.
final class InboundGateTerminalValue<T> extends InboundGateTerminal<T> {
  /// Create a terminal [value].
  const InboundGateTerminalValue(this.value);

  /// Value used to settle the queued waiter.
  final T value;
}

/// A local terminal error for queued inbound work.
final class InboundGateTerminalError<T> extends InboundGateTerminal<T> {
  /// Create a terminal [error] with its optional [stackTrace].
  const InboundGateTerminalError(this.error, [this.stackTrace]);

  /// Error used to settle the queued waiter.
  final Object error;

  /// Original stack trace when one is available.
  final StackTrace? stackTrace;
}

/// Bounds admitted inbound work and limits asynchronous handler concurrency.
class InboundGate {
  InboundGate({
    this.maxPendingItems = 128,
    this.maxPendingBytes = 32 * 1024 * 1024,
    this.maxConcurrentHandlers = 16,
    this.maxOrdinaryConcurrentHandlers = 14,
  }) {
    validateLimits(
      maxPendingItems: maxPendingItems,
      maxPendingBytes: maxPendingBytes,
      maxConcurrentHandlers: maxConcurrentHandlers,
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    );
  }

  final int maxPendingItems;
  final int maxPendingBytes;
  final int maxConcurrentHandlers;
  final int maxOrdinaryConcurrentHandlers;

  final ListQueue<_HandlerWaiter<dynamic>> _waiters =
      ListQueue<_HandlerWaiter<dynamic>>();
  final Set<_HandlerWaiter<dynamic>> _running = <_HandlerWaiter<dynamic>>{};
  final Set<InboundGateReservation> _reservations = <InboundGateReservation>{};
  Future<void>? _closeFuture;
  var _pendingItems = 0;
  var _pendingBytes = 0;
  var _activeHandlers = 0;
  var _activeOrdinaryHandlers = 0;
  var _pumping = false;
  var _closed = false;

  int get pendingItems => _pendingItems;
  int get pendingBytes => _pendingBytes;
  int get activeHandlers => _activeHandlers;
  bool get isClosed => _closed;

  static void validateLimits({
    required int maxPendingItems,
    required int maxPendingBytes,
    required int maxConcurrentHandlers,
    required int maxOrdinaryConcurrentHandlers,
  }) {
    if (maxPendingItems <= 0) {
      throw ArgumentError.value(
        maxPendingItems,
        'maxPendingItems',
        'must be greater than zero',
      );
    }
    if (maxPendingBytes <= 0) {
      throw ArgumentError.value(
        maxPendingBytes,
        'maxPendingBytes',
        'must be greater than zero',
      );
    }
    if (maxConcurrentHandlers <= 0) {
      throw ArgumentError.value(
        maxConcurrentHandlers,
        'maxConcurrentHandlers',
        'must be greater than zero',
      );
    }
    if (maxOrdinaryConcurrentHandlers <= 0) {
      throw ArgumentError.value(
        maxOrdinaryConcurrentHandlers,
        'maxOrdinaryConcurrentHandlers',
        'must be greater than zero',
      );
    }
    if (maxOrdinaryConcurrentHandlers > maxConcurrentHandlers - 2) {
      throw ArgumentError.value(
        maxOrdinaryConcurrentHandlers,
        'maxOrdinaryConcurrentHandlers',
        'must leave two reserved handler slots',
      );
    }
  }

  /// Atomically reserves pending item and byte capacity for a decoded batch.
  List<InboundGateReservation>? tryReserveBatch(
    List<InboundGateElement> elements,
  ) {
    if (_closed) return null;
    var addedBytes = 0;
    for (final element in elements) {
      if (element.byteLength <= 0) {
        throw ArgumentError.value(
          element.byteLength,
          'byteLength',
          'must be greater than zero',
        );
      }
      addedBytes += element.byteLength;
    }
    final observedItems = _pendingItems + elements.length;
    final observedBytes = _pendingBytes + addedBytes;
    if (observedItems > maxPendingItems || observedBytes > maxPendingBytes) {
      return null;
    }

    final reservations = elements
        .map((element) => InboundGateReservation._(this, element))
        .toList(growable: false);
    _pendingItems = observedItems;
    _pendingBytes = observedBytes;
    _reservations.addAll(reservations);
    return reservations;
  }

  Future<T> _run<T>(
    InboundGateReservation reservation,
    FutureOr<T> Function() operation,
  ) {
    if (!_reservations.contains(reservation) ||
        reservation._state != _ReservationState.reserved ||
        _closed) {
      return Future<T>.error(StateError('Inbound gate reservation is closed.'));
    }
    reservation._state = _ReservationState.queued;
    final waiter = _HandlerWaiter<T>(reservation, operation);
    _waiters.addLast(waiter);
    _pump();
    return waiter.completer.future;
  }

  Future<T> _runCancellable<T>(
    InboundGateReservation reservation, {
    required FutureOr<T> Function() operation,
    required Future<InboundGateTerminal<T>> terminal,
  }) {
    if (!_reservations.contains(reservation) ||
        reservation._state != _ReservationState.reserved ||
        _closed) {
      return Future<T>.error(StateError('Inbound gate reservation is closed.'));
    }
    reservation._state = _ReservationState.queued;
    final waiter = _HandlerWaiter<T>(reservation, operation);
    _waiters.addLast(waiter);
    unawaited(
      terminal.then<void>(
        (outcome) {
          if (reservation._state != _ReservationState.queued) return;
          _waiters.remove(waiter);
          _release(reservation);
          switch (outcome) {
            case InboundGateTerminalValue<T>(:final value):
              waiter.completer.complete(value);
            case InboundGateTerminalError<T>(:final error, :final stackTrace):
              waiter.completer.completeError(
                error,
                stackTrace ?? StackTrace.current,
              );
          }
          _pump();
        },
        onError: (Object error, StackTrace stackTrace) {
          if (reservation._state != _ReservationState.queued) return;
          _waiters.remove(waiter);
          _release(reservation);
          waiter.completer.completeError(error, stackTrace);
          _pump();
        },
      ),
    );
    _pump();
    return waiter.completer.future;
  }

  T _runSync<T>(InboundGateReservation reservation, T Function() operation) {
    if (reservation.method != 'session/update') {
      throw StateError('Only session/update may bypass handler permits.');
    }
    if (!_reservations.contains(reservation) ||
        reservation._state != _ReservationState.reserved ||
        _closed) {
      throw StateError('Inbound gate reservation is closed.');
    }
    reservation._state = _ReservationState.running;
    try {
      return operation();
    } finally {
      _release(reservation);
    }
  }

  void _pump() {
    if (_pumping || _closed) return;
    _pumping = true;
    try {
      while (_activeHandlers < maxConcurrentHandlers && _waiters.isNotEmpty) {
        _HandlerWaiter<dynamic>? selected;
        for (final waiter in _waiters) {
          if (waiter.isReservedControl ||
              _activeOrdinaryHandlers < maxOrdinaryConcurrentHandlers) {
            selected = waiter;
            break;
          }
        }
        if (selected == null) return;
        _waiters.remove(selected);
        _start(selected);
      }
    } finally {
      _pumping = false;
    }
  }

  void _start(_HandlerWaiter<dynamic> waiter) {
    final reservation = waiter.reservation;
    if (_closed || reservation._state != _ReservationState.queued) {
      _rejectWaiter(waiter);
      return;
    }
    reservation._state = _ReservationState.running;
    _running.add(waiter);
    _activeHandlers += 1;
    if (!waiter.isReservedControl) _activeOrdinaryHandlers += 1;

    final Future<dynamic> operation;
    try {
      operation = Future<dynamic>.sync(waiter.operation);
    } on Object catch (error, stackTrace) {
      _finishError(waiter, error, stackTrace);
      return;
    }
    unawaited(
      operation.then<void>(
        (value) => _finishValue(waiter, value),
        onError: (Object error, StackTrace stackTrace) {
          _finishError(waiter, error, stackTrace);
        },
      ),
    );
  }

  void _finishValue(_HandlerWaiter<dynamic> waiter, Object? value) {
    if (waiter.reservation._state == _ReservationState.detached) return;
    if (waiter.reservation._state != _ReservationState.running) return;
    _finish(waiter);
    if (!waiter.completer.isCompleted) waiter.completer.complete(value);
  }

  void _finishError(
    _HandlerWaiter<dynamic> waiter,
    Object error,
    StackTrace stackTrace,
  ) {
    if (waiter.reservation._state == _ReservationState.detached) return;
    if (waiter.reservation._state != _ReservationState.running) return;
    _finish(waiter);
    if (!waiter.completer.isCompleted) {
      waiter.completer.completeError(error, stackTrace);
    }
  }

  void _finish(_HandlerWaiter<dynamic> waiter) {
    if (!_running.remove(waiter)) return;
    _activeHandlers -= 1;
    if (!waiter.isReservedControl) _activeOrdinaryHandlers -= 1;
    _release(waiter.reservation);
    _pump();
  }

  void _release(InboundGateReservation reservation) {
    if (!_reservations.remove(reservation)) return;
    reservation._state = _ReservationState.released;
    _pendingItems -= 1;
    _pendingBytes -= reservation.byteLength;
    if (!reservation._released.isCompleted) reservation._released.complete();
  }

  void _detach(_HandlerWaiter<dynamic> waiter) {
    final reservation = waiter.reservation;
    if (reservation._state != _ReservationState.running) return;
    _running.remove(waiter);
    reservation._state = _ReservationState.detached;
    _reservations.remove(reservation);
    _activeHandlers -= 1;
    if (!waiter.isReservedControl) _activeOrdinaryHandlers -= 1;
    _pendingItems -= 1;
    _pendingBytes -= reservation.byteLength;
    if (!reservation._released.isCompleted) reservation._released.complete();
    if (!waiter.completer.isCompleted) {
      waiter.completer.completeError(StateError('Inbound gate is closed.'));
    }
  }

  void _releaseUnused(InboundGateReservation reservation) {
    if (reservation._state == _ReservationState.released) return;
    if (reservation._state != _ReservationState.reserved) {
      throw StateError('Inbound gate reservation is already in use.');
    }
    _release(reservation);
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    final owner = Completer<void>.sync();
    _closeFuture = owner.future;
    _closed = true;

    final queued = _waiters.toList(growable: false);
    _waiters.clear();
    for (final waiter in queued) {
      _rejectWaiter(waiter);
    }
    for (final waiter in _running.toList(growable: false)) {
      _detach(waiter);
    }
    for (final reservation in _reservations.toList(growable: false)) {
      if (reservation._state == _ReservationState.reserved) {
        _release(reservation);
      }
    }
    owner.complete();
    return owner.future;
  }

  void _rejectWaiter(_HandlerWaiter<dynamic> waiter) {
    _release(waiter.reservation);
    if (!waiter.completer.isCompleted) {
      waiter.completer.completeError(StateError('Inbound gate is closed.'));
    }
  }
}

class InboundGateReservation {
  InboundGateReservation._(this._gate, InboundGateElement element)
    : method = element.method,
      byteLength = element.byteLength;

  final InboundGate _gate;
  final String? method;
  final int byteLength;
  final Completer<void> _released = Completer<void>.sync();
  _ReservationState _state = _ReservationState.reserved;

  /// Completes when this reservation no longer consumes gate capacity.
  Future<void> get released => _released.future;

  Future<T> run<T>(FutureOr<T> Function() operation) =>
      _gate._run(this, operation);

  /// Run [operation] unless [terminal] settles this reservation while queued.
  Future<T> runCancellable<T>({
    required FutureOr<T> Function() operation,
    required Future<InboundGateTerminal<T>> terminal,
  }) => _gate._runCancellable(this, operation: operation, terminal: terminal);

  T runSync<T>(T Function() operation) => _gate._runSync(this, operation);

  void release() => _gate._releaseUnused(this);
}

class _HandlerWaiter<T> {
  _HandlerWaiter(this.reservation, this.operation);

  final InboundGateReservation reservation;
  final FutureOr<T> Function() operation;
  // Complete asynchronously so a synchronously throwing handler cannot report
  // an unhandled Future error before [run] returns it to its caller.
  final Completer<T> completer = Completer<T>();

  bool get isReservedControl =>
      reservation.method == 'terminal/kill' ||
      reservation.method == 'terminal/release';
}

enum _ReservationState { reserved, queued, running, released, detached }
