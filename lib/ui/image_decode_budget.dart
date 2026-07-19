import 'dart:async';
import 'dart:collection';

import '../acp/acp_input_budget.dart';

abstract interface class AcpImageDecodeReservation {
  bool get decodeFinished;

  bool get installedMemoryReleased;

  void shrinkInstalledReservation({
    required int previewPixels,
    required int reservedBytes,
  });

  void finishDecode();

  void releaseInstalledMemory();
}

abstract interface class AcpImageDecodeCancellation {
  bool get isCancelled;

  void addListener(void Function() listener);

  void removeListener(void Function() listener);
}

final class AcpImageDecodeCancellationSource
    implements AcpImageDecodeCancellation {
  final Set<void Function()> _listeners = <void Function()>{};
  var _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    final errors = <_AcpImageDecodeCallbackError>[];
    for (final listener in listeners) {
      try {
        listener();
      } catch (error, stackTrace) {
        errors.add(_AcpImageDecodeCallbackError(error, stackTrace));
      }
    }
    for (final error in errors) {
      _reportAcpImageDecodeCallbackError(error.error, error.stackTrace);
    }
  }

  @override
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

final class AcpImageDecodeCancelled implements Exception {
  const AcpImageDecodeCancelled();

  @override
  String toString() => 'AcpImageDecodeCancelled';
}

final class _AcpImageDecodeCallbackError {
  const _AcpImageDecodeCallbackError(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

void _reportAcpImageDecodeCallbackError(Object error, StackTrace stackTrace) {
  try {
    Zone.current.handleUncaughtError(error, stackTrace);
  } catch (_) {
    // External Zone error handlers must not interrupt ledger cleanup.
  }
}

final class AcpImageDecodeBudgetLedger {
  AcpImageDecodeBudgetLedger({required AcpInputBudget budget})
    : _budget = budget..validate();

  final AcpInputBudget _budget;
  final LinkedList<_AcpImageDecodeWaiter> _waiters =
      LinkedList<_AcpImageDecodeWaiter>();

  var _activeDecodes = 0;
  var _reservedPreviewPixels = 0;
  var _reservedBytes = 0;

  Future<AcpImageDecodeReservation> acquire({
    required int decodedBytes,
    required AcpImageDecodeCancellation cancellation,
  }) {
    final bool isCancelled;
    try {
      isCancelled = cancellation.isCancelled;
    } catch (error, stackTrace) {
      return Future<AcpImageDecodeReservation>.error(error, stackTrace);
    }
    if (isCancelled) {
      return Future<AcpImageDecodeReservation>.error(
        const AcpImageDecodeCancelled(),
      );
    }
    if (decodedBytes < 0) {
      return Future<AcpImageDecodeReservation>.error(
        RangeError.range(
          decodedBytes,
          0,
          _budget.maxEmbeddedMediaBytes,
          'decodedBytes',
        ),
      );
    }
    if (decodedBytes > _budget.maxEmbeddedMediaBytes) {
      return Future<AcpImageDecodeReservation>.error(
        AcpInputLimitExceeded(
          resource: 'ACP image decoded bytes',
          limit: _budget.maxEmbeddedMediaBytes,
          observedAtLeast: _budget.maxEmbeddedMediaBytes + 1,
        ),
      );
    }

    final previewPixels = _budget.maxImagePreviewPixels;
    final reservedBytes = decodedBytes + previewPixels * 4;
    if (previewPixels >
        _budget.maxImagePreviewPixelsGlobal - _reservedPreviewPixels) {
      return Future<AcpImageDecodeReservation>.error(
        AcpInputLimitExceeded(
          resource: 'ACP image preview pixels',
          limit: _budget.maxImagePreviewPixelsGlobal,
          observedAtLeast: _budget.maxImagePreviewPixelsGlobal + 1,
        ),
      );
    }
    if (reservedBytes > _budget.maxImageDecodeBytesGlobal - _reservedBytes) {
      return Future<AcpImageDecodeReservation>.error(
        AcpInputLimitExceeded(
          resource: 'ACP image decode bytes',
          limit: _budget.maxImageDecodeBytesGlobal,
          observedAtLeast: _budget.maxImageDecodeBytesGlobal + 1,
        ),
      );
    }

    _reservedPreviewPixels += previewPixels;
    _reservedBytes += reservedBytes;

    if (_activeDecodes < _budget.maxConcurrentImageDecodes) {
      _activeDecodes += 1;
      return Future<AcpImageDecodeReservation>.value(
        _AcpImageDecodeReservation(
          this,
          decodedBytes,
          previewPixels,
          reservedBytes,
        ),
      );
    }

    final waiter = _AcpImageDecodeWaiter(
      decodedBytes: decodedBytes,
      previewPixels: previewPixels,
      reservedBytes: reservedBytes,
      cancellation: cancellation,
    );
    _waiters.add(waiter);
    late void Function() cancelListener;
    cancelListener = () => _cancelWaiter(waiter);
    waiter.cancelListener = cancelListener;
    try {
      cancellation.addListener(cancelListener);
    } catch (error, stackTrace) {
      waiter.registrationInProgress = false;
      if (waiter.waiting) {
        waiter.waiting = false;
        waiter.unlink();
        _releaseInstalledCapacity(
          previewPixels: waiter.previewPixels,
          reservedBytes: waiter.reservedBytes,
        );
      }
      final removeError = _removeWaiterListener(waiter);
      _grantWaiters();
      if (removeError != null) {
        _reportAcpImageDecodeCallbackError(
          removeError.error,
          removeError.stackTrace,
        );
      }
      return Future<AcpImageDecodeReservation>.error(error, stackTrace);
    }

    waiter.registrationInProgress = false;
    final completer = Completer<AcpImageDecodeReservation>();
    waiter.completer = completer;
    if (waiter.cancelledDuringRegistration) {
      completer.completeError(const AcpImageDecodeCancelled());
    } else {
      _grantWaiters();
    }
    return completer.future;
  }

  void _cancelWaiter(_AcpImageDecodeWaiter waiter) {
    if (!waiter.waiting) return;
    waiter.waiting = false;
    waiter.unlink();
    _releaseInstalledCapacity(
      previewPixels: waiter.previewPixels,
      reservedBytes: waiter.reservedBytes,
    );
    final removeError = _removeWaiterListener(waiter);
    if (waiter.registrationInProgress) {
      waiter.cancelledDuringRegistration = true;
    } else {
      waiter.completer?.completeError(const AcpImageDecodeCancelled());
    }
    _grantWaiters();
    if (removeError != null) {
      _reportAcpImageDecodeCallbackError(
        removeError.error,
        removeError.stackTrace,
      );
    }
  }

  _AcpImageDecodeCallbackError? _removeWaiterListener(
    _AcpImageDecodeWaiter waiter,
  ) {
    if (waiter.listenerRemovalAttempted) return null;
    waiter.listenerRemovalAttempted = true;
    final cancelListener = waiter.cancelListener;
    if (cancelListener == null) return null;
    try {
      waiter.cancellation.removeListener(cancelListener);
    } catch (error, stackTrace) {
      return _AcpImageDecodeCallbackError(error, stackTrace);
    }
    return null;
  }

  void _releaseDecodeSlot() {
    if (_activeDecodes <= 0) {
      throw StateError('ACP image decode concurrency ledger underflow.');
    }
    _activeDecodes -= 1;
    _grantWaiters();
  }

  void _grantWaiters() {
    while (_activeDecodes < _budget.maxConcurrentImageDecodes &&
        _waiters.isNotEmpty) {
      final waiter = _waiters.first;
      if (waiter.registrationInProgress) return;
      waiter.unlink();
      waiter.waiting = false;
      final removeError = _removeWaiterListener(waiter);
      _activeDecodes += 1;
      waiter.completer!.complete(
        _AcpImageDecodeReservation(
          this,
          waiter.decodedBytes,
          waiter.previewPixels,
          waiter.reservedBytes,
        ),
      );
      if (removeError != null) {
        _reportAcpImageDecodeCallbackError(
          removeError.error,
          removeError.stackTrace,
        );
      }
    }
  }

  void _shrinkInstalledCapacity({
    required int previewPixels,
    required int reservedBytes,
  }) {
    if (previewPixels > _reservedPreviewPixels ||
        reservedBytes > _reservedBytes) {
      throw StateError('ACP image installed-memory ledger underflow.');
    }
    _reservedPreviewPixels -= previewPixels;
    _reservedBytes -= reservedBytes;
  }

  void _releaseInstalledCapacity({
    required int previewPixels,
    required int reservedBytes,
  }) {
    _shrinkInstalledCapacity(
      previewPixels: previewPixels,
      reservedBytes: reservedBytes,
    );
  }
}

final class _AcpImageDecodeWaiter
    extends LinkedListEntry<_AcpImageDecodeWaiter> {
  _AcpImageDecodeWaiter({
    required this.decodedBytes,
    required this.previewPixels,
    required this.reservedBytes,
    required this.cancellation,
  });

  final int decodedBytes;
  final int previewPixels;
  final int reservedBytes;
  final AcpImageDecodeCancellation cancellation;
  Completer<AcpImageDecodeReservation>? completer;
  void Function()? cancelListener;
  var waiting = true;
  var registrationInProgress = true;
  var cancelledDuringRegistration = false;
  var listenerRemovalAttempted = false;
}

final class _AcpImageDecodeReservation implements AcpImageDecodeReservation {
  _AcpImageDecodeReservation(
    this._ledger,
    this._decodedBytes,
    this._previewPixels,
    this._reservedBytes,
  );

  final AcpImageDecodeBudgetLedger _ledger;
  final int _decodedBytes;
  int _previewPixels;
  int _reservedBytes;

  var _decodeFinished = false;
  var _installedMemoryReleased = false;

  @override
  bool get decodeFinished => _decodeFinished;

  @override
  bool get installedMemoryReleased => _installedMemoryReleased;

  @override
  void shrinkInstalledReservation({
    required int previewPixels,
    required int reservedBytes,
  }) {
    if (_installedMemoryReleased) {
      throw StateError('ACP image installed-memory reservation was released.');
    }
    if (previewPixels < 0 || previewPixels > _previewPixels) {
      throw ArgumentError.value(
        previewPixels,
        'previewPixels',
        'must not grow the installed reservation',
      );
    }
    if (reservedBytes < 0 || reservedBytes > _reservedBytes) {
      throw ArgumentError.value(
        reservedBytes,
        'reservedBytes',
        'must not grow the installed reservation',
      );
    }
    final minimumReservedBytes = _decodedBytes + previewPixels * 4;
    if (reservedBytes < minimumReservedBytes) {
      throw ArgumentError.value(
        reservedBytes,
        'reservedBytes',
        'must reserve decodedBytes plus four bytes per preview pixel',
      );
    }

    _ledger._shrinkInstalledCapacity(
      previewPixels: _previewPixels - previewPixels,
      reservedBytes: _reservedBytes - reservedBytes,
    );
    _previewPixels = previewPixels;
    _reservedBytes = reservedBytes;
  }

  @override
  void finishDecode() {
    if (_decodeFinished) return;
    _ledger._releaseDecodeSlot();
    _decodeFinished = true;
  }

  @override
  void releaseInstalledMemory() {
    if (_installedMemoryReleased) return;
    _ledger._releaseInstalledCapacity(
      previewPixels: _previewPixels,
      reservedBytes: _reservedBytes,
    );
    _previewPixels = 0;
    _reservedBytes = 0;
    _installedMemoryReleased = true;
  }
}
