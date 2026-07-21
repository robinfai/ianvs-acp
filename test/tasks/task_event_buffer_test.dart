import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_event_buffer.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

void main() {
  test('TaskEventBuffer merges ten thousand assistant deltas', () async {
    final written = <BufferedTaskEvent>[];
    final buffer = TaskEventBuffer(write: (event) async => written.add(event));
    addTearDown(buffer.dispose);

    for (var index = 0; index < 10000; index += 1) {
      buffer.addAssistantDelta('x');
    }
    await buffer.flush();

    expect(written, hasLength(1));
    expect(written.single.kind, TaskEventKind.assistant);
    expect(written.single.text, hasLength(10000));
  });

  test('TaskEventBuffer flushes exactly at two hundred milliseconds', () async {
    final scheduler = _FakeTaskEventBufferScheduler();
    final written = <BufferedTaskEvent>[];
    final buffer = TaskEventBuffer(
      scheduler: scheduler.schedule,
      write: (event) async => written.add(event),
    );
    addTearDown(buffer.dispose);
    buffer.addAssistantDelta('x');

    await scheduler.elapse(const Duration(milliseconds: 199));
    expect(written, isEmpty);

    await scheduler.elapse(const Duration(milliseconds: 1));
    expect(written, hasLength(1));
    expect(written.single.text, 'x');
  });

  test('TaskEventBuffer auto flush writes ten thousand deltas once', () async {
    final scheduler = _FakeTaskEventBufferScheduler();
    final written = <BufferedTaskEvent>[];
    final buffer = TaskEventBuffer(
      scheduler: scheduler.schedule,
      write: (event) async => written.add(event),
    );
    addTearDown(buffer.dispose);

    for (var index = 0; index < 10000; index += 1) {
      buffer.addAssistantDelta('x');
    }
    await scheduler.elapse(const Duration(milliseconds: 200));

    expect(written, hasLength(1));
    expect(written.single.text, hasLength(10000));
  });

  test(
    'TaskEventBuffer preserves whitespace and flushes at boundaries',
    () async {
      final written = <BufferedTaskEvent>[];
      final buffer = TaskEventBuffer(
        write: (event) async => written.add(event),
      );
      addTearDown(buffer.dispose);

      buffer.addAssistantDelta(
        'Hello ',
        metadata: const <String, Object?>{'first': 1, 'shared': 'old'},
      );
      buffer.addAssistantDelta(
        ' world',
        metadata: const <String, Object?>{'last': 2, 'shared': 'new'},
      );
      unawaited(
        buffer.addEvent(
          kind: TaskEventKind.tool,
          text: 'tool',
          metadata: const <String, Object?>{'id': 'tool-1'},
        ),
      );
      buffer.addAssistantDelta(' done ');
      unawaited(buffer.addEvent(kind: TaskEventKind.status, text: 'complete'));
      await buffer.flush();

      expect(
        written.map((event) => '${event.kind.name}:${event.text}'),
        <String>[
          'assistant:Hello  world',
          'tool:tool',
          'assistant: done ',
          'status:complete',
        ],
      );
      expect(written.first.metadata, <String, Object?>{
        'first': 1,
        'shared': 'new',
        'last': 2,
      });
      expect(written[1].metadata, const <String, Object?>{'id': 'tool-1'});
    },
  );

  test('TaskEventBuffer honors a custom flush interval', () async {
    final scheduler = _FakeTaskEventBufferScheduler();
    final written = <BufferedTaskEvent>[];
    final buffer = TaskEventBuffer(
      flushInterval: const Duration(milliseconds: 5),
      scheduler: scheduler.schedule,
      write: (event) async => written.add(event),
    );
    addTearDown(buffer.dispose);

    buffer.addAssistantDelta('eventually persisted');

    await scheduler.elapse(const Duration(milliseconds: 4));
    expect(written, isEmpty);
    await scheduler.elapse(const Duration(milliseconds: 1));
    expect(written.single.text, 'eventually persisted');
  });

  test(
    'a cancelled timer cannot flush the next assistant generation',
    () async {
      final scheduler = _FakeTaskEventBufferScheduler(
        deliverCancelledCallbacks: true,
      );
      final written = <String>[];
      final buffer = TaskEventBuffer(
        scheduler: scheduler.schedule,
        write: (event) async => written.add(event.text),
      );
      addTearDown(buffer.dispose);
      buffer.addAssistantDelta('A');

      await scheduler.elapse(const Duration(milliseconds: 100));
      unawaited(buffer.addEvent(kind: TaskEventKind.status, text: 'boundary'));
      buffer.addAssistantDelta('B');
      await scheduler.elapse(Duration.zero);
      expect(written, <String>['A', 'boundary']);

      await scheduler.elapse(const Duration(milliseconds: 100));
      expect(written, <String>['A', 'boundary']);

      await scheduler.elapse(const Duration(milliseconds: 100));
      expect(written, <String>['A', 'boundary', 'B']);
    },
  );

  test('TaskEventBuffer dispose awaits a pending write', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final buffer = TaskEventBuffer(
      write: (event) async {
        writeStarted.complete();
        await releaseWrite.future;
      },
    );
    buffer.addAssistantDelta('last delta');

    final disposing = buffer.dispose();
    await writeStarted.future;
    var disposed = false;
    unawaited(
      disposing.then<void>((_) {
        disposed = true;
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(disposed, isFalse);

    releaseWrite.complete();
    await disposing;
    expect(disposed, isTrue);
    expect(
      () => buffer.addAssistantDelta('too late'),
      throwsA(isA<StateError>()),
    );
  });

  test('TaskEventBuffer flush includes deltas added while writing', () async {
    final firstWriteStarted = Completer<void>();
    final releaseFirstWrite = Completer<void>();
    final written = <String>[];
    final buffer = TaskEventBuffer(
      write: (event) async {
        written.add(event.text);
        if (written.length == 1) {
          firstWriteStarted.complete();
          await releaseFirstWrite.future;
        }
      },
    );
    addTearDown(buffer.dispose);
    buffer.addAssistantDelta('first');

    final flushing = buffer.flush();
    await firstWriteStarted.future;
    buffer.addAssistantDelta('second');
    releaseFirstWrite.complete();
    await flushing;

    expect(written, <String>['first', 'second']);
  });

  test('concurrent flush and dispose share one successful write', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    var writeCount = 0;
    final buffer = TaskEventBuffer(
      write: (event) async {
        writeCount += 1;
        writeStarted.complete();
        await releaseWrite.future;
      },
    );
    buffer.addAssistantDelta('last');

    final flushing = buffer.flush();
    await writeStarted.future;
    final disposing = buffer.dispose();
    releaseWrite.complete();
    await Future.wait(<Future<void>>[flushing, disposing]);

    expect(writeCount, 1);
  });

  test('concurrent flush and dispose propagate the same write error', () async {
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final error = StateError('same write failure');
    var writeCount = 0;
    final buffer = TaskEventBuffer(
      write: (event) async {
        writeCount += 1;
        writeStarted.complete();
        await releaseWrite.future;
        throw error;
      },
    );
    buffer.addAssistantDelta('last');

    final flushing = buffer.flush();
    await writeStarted.future;
    final disposing = buffer.dispose();
    final flushExpectation = expectLater(flushing, throwsA(same(error)));
    final disposeExpectation = expectLater(disposing, throwsA(same(error)));
    releaseWrite.complete();
    await Future.wait(<Future<void>>[flushExpectation, disposeExpectation]);

    expect(writeCount, 1);
  });

  test('TaskEventBuffer reports deferred writer failures from flush', () async {
    final buffer = TaskEventBuffer(
      write: (event) async => throw StateError('write failed'),
    );
    buffer.addAssistantDelta('delta');

    await expectLater(buffer.flush(), throwsA(isA<StateError>()));
    await expectLater(buffer.dispose(), throwsA(isA<StateError>()));
  });
}

class _FakeTaskEventBufferScheduler {
  _FakeTaskEventBufferScheduler({this.deliverCancelledCallbacks = false});

  final bool deliverCancelledCallbacks;
  var _elapsed = Duration.zero;
  final List<_FakeTaskEventBufferTimer> _timers = <_FakeTaskEventBufferTimer>[];

  TaskEventBufferTimer schedule(Duration delay, void Function() callback) {
    final timer = _FakeTaskEventBufferTimer(
      dueAt: _elapsed + delay,
      callback: callback,
    );
    _timers.add(timer);
    return timer;
  }

  Future<void> elapse(Duration duration) async {
    final target = _elapsed + duration;
    while (true) {
      _FakeTaskEventBufferTimer? next;
      for (final timer in _timers) {
        if (timer.fired || timer.dueAt > target) continue;
        if (timer.cancelled && !deliverCancelledCallbacks) continue;
        if (next == null || timer.dueAt < next.dueAt) next = timer;
      }
      if (next == null) break;
      _elapsed = next.dueAt;
      next.fire(evenIfCancelled: deliverCancelledCallbacks);
    }
    _elapsed = target;
    await Future<void>.delayed(Duration.zero);
  }
}

class _FakeTaskEventBufferTimer implements TaskEventBufferTimer {
  _FakeTaskEventBufferTimer({required this.dueAt, required this.callback});

  final Duration dueAt;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  @override
  void cancel() => cancelled = true;

  void fire({bool evenIfCancelled = false}) {
    if (fired || (cancelled && !evenIfCancelled)) return;
    fired = true;
    callback();
  }
}
