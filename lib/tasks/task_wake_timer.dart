import 'dart:async';

abstract interface class TaskWakeTimer {
  bool get isActive;

  void cancel();
}

typedef TaskWakeTimerFactory =
    TaskWakeTimer Function(Duration delay, void Function() callback);

class DartTaskWakeTimer implements TaskWakeTimer {
  DartTaskWakeTimer(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}
