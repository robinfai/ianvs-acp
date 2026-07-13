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
    _activeHandlers += 1;
    if (!waiter.isReservedControl) _activeOrdinaryHandlers += 1;

    Object? result;
    try {
      result = waiter.operation();
    } on Object catch (error, stackTrace) {
      _finishError(waiter, error, stackTrace);
      return;
    }
    if (result is Future) {
      unawaited(
        result.then<void>(
          (value) => _finishValue(waiter, value),
          onError: (Object error, StackTrace stackTrace) {
            _finishError(waiter, error, stackTrace);
          },
        ),
      );
    } else {
      _finishValue(waiter, result);
    }
  }

  void _finishValue(_HandlerWaiter<dynamic> waiter, Object? value) {
    _finish(waiter);
    if (!waiter.completer.isCompleted) waiter.completer.complete(value);
  }

  void _finishError(
    _HandlerWaiter<dynamic> waiter,
    Object error,
    StackTrace stackTrace,
  ) {
    _finish(waiter);
    if (!waiter.completer.isCompleted) {
      waiter.completer.completeError(error, stackTrace);
    }
  }

  void _finish(_HandlerWaiter<dynamic> waiter) {
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
    final completer = Completer<void>.sync();
    _closeFuture = completer.future;
    _closed = true;

    final queued = _waiters.toList(growable: false);
    _waiters.clear();
    for (final waiter in queued) {
      _rejectWaiter(waiter);
    }
    for (final reservation in _reservations.toList(growable: false)) {
      if (reservation._state == _ReservationState.reserved) {
        _release(reservation);
      }
    }
    completer.complete();
    return completer.future;
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
  _ReservationState _state = _ReservationState.reserved;

  Future<T> run<T>(FutureOr<T> Function() operation) =>
      _gate._run(this, operation);

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

enum _ReservationState { reserved, queued, running, released }
