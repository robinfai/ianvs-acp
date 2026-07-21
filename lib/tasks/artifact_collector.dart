import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'task_data_sanitizer.dart';
import 'task_record.dart';

typedef ArtifactCollectorClock = DateTime Function();
typedef ArtifactCollectorIdGenerator = String Function(String prefix);
typedef ArtifactCollectorNonceGenerator = List<int> Function(int length);
typedef ArtifactCollectorProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
    });
typedef ArtifactCollectionCancellationListener = void Function(String reason);
typedef ArtifactCollectionCancellationListenerRemoval = void Function();

const int defaultArtifactPreviewLimit = 64 * 1024;
const int defaultFullDiffPreviewLimit = 1024 * 1024;
const int _gitWorkspaceProbeLimit = 64;
const int _gitSummaryOutputLimit = 64 * 1024;

class ArtifactCollectionCancellation {
  final Map<int, ArtifactCollectionCancellationListener> _listeners =
      <int, ArtifactCollectionCancellationListener>{};
  int _nextListenerId = 0;
  String? _reason;

  bool get cancelled => _reason != null;
  String? get reason => _reason;

  bool cancel(String reason) {
    if (_reason != null) return false;
    _reason = reason;
    final listeners = List<ArtifactCollectionCancellationListener>.of(
      _listeners.values,
    );
    _listeners.clear();
    for (final listener in listeners) {
      try {
        listener(reason);
      } on Object {
        // Cancellation is a fan-out signal. One observer cannot block others.
      }
    }
    return true;
  }

  ArtifactCollectionCancellationListenerRemoval addListener(
    ArtifactCollectionCancellationListener listener,
  ) {
    final reason = _reason;
    if (reason != null) {
      try {
        listener(reason);
      } on Object {
        // Late observers cannot change or disrupt the settled cancellation.
      }
      return () {};
    }
    final id = _nextListenerId++;
    _listeners[id] = listener;
    return () => _listeners.remove(id);
  }
}

class ArtifactCollector {
  ArtifactCollector({
    int previewLimit = defaultArtifactPreviewLimit,
    ArtifactCollectorClock? clock,
    this.idGenerator,
    this.nonceGenerator,
    ArtifactCollectorProcessStarter? processStarter,
    Duration commandTimeout = const Duration(seconds: 30),
    Duration terminationGracePeriod = const Duration(milliseconds: 500),
    TaskDataSanitizer? dataSanitizer,
  }) : previewLimit = _requirePositiveInt('previewLimit', previewLimit),
       _clock = clock ?? DateTime.now,
       _processStarter = processStarter ?? _defaultProcessStarter,
       _commandTimeout = _requirePositiveDuration(
         'commandTimeout',
         commandTimeout,
       ),
       _terminationGracePeriod = _requirePositiveDuration(
         'terminationGracePeriod',
         terminationGracePeriod,
       ),
       dataSanitizer = dataSanitizer ?? const TaskDataSanitizer(),
       _random = math.Random.secure();

  final int previewLimit;
  final ArtifactCollectorClock _clock;
  final ArtifactCollectorIdGenerator? idGenerator;
  final ArtifactCollectorNonceGenerator? nonceGenerator;
  final ArtifactCollectorProcessStarter _processStarter;
  final Duration _commandTimeout;
  final Duration _terminationGracePeriod;
  final TaskDataSanitizer dataSanitizer;
  final math.Random _random;
  final Set<String> _issuedDefaultIds = <String>{};

  Future<List<ArtifactRecord>> collect(
    TaskRecord task,
    TaskRunRecord run, {
    ArtifactCollectionCancellation? cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final workspace = Directory(task.workspacePath);
    if (!workspace.existsSync()) return const <ArtifactRecord>[];

    final artifacts = <ArtifactRecord>[];
    if (await _isGitWorkspace(workspace.path, cancellation)) {
      _throwIfCancelled(cancellation);
      final status = await _runGit(
        workspace.path,
        const ['status', '--porcelain'],
        stdoutLimit: _gitSummaryOutputLimit,
        cancellation: cancellation,
      );
      _throwIfCancelled(cancellation);
      if (status != null && status.stdout.trim().isNotEmpty) {
        final preview = _previewForText(status.stdout);
        artifacts.add(
          _artifact(
            task: task,
            run: run,
            kind: ArtifactKind.gitStatus,
            title: 'Git status',
            contentPreview: preview.text,
            metadata: _metadataForGitCommand(
              const ['git', 'status', '--porcelain'],
              status,
              preview,
            ),
          ),
        );
      }

      final diffStat = await _runGit(
        workspace.path,
        const ['diff', '--stat'],
        stdoutLimit: _gitSummaryOutputLimit,
        cancellation: cancellation,
      );
      _throwIfCancelled(cancellation);
      if (diffStat != null && diffStat.stdout.trim().isNotEmpty) {
        final preview = _previewForText(diffStat.stdout);
        artifacts.add(
          _artifact(
            task: task,
            run: run,
            kind: ArtifactKind.gitDiff,
            title: 'Git diff stat',
            contentPreview: preview.text,
            metadata: _metadataForGitCommand(
              const ['git', 'diff', '--stat'],
              diffStat,
              preview,
            ),
          ),
        );
      }

      if (task.metadata['retain_full_diff'] == true) {
        final diff = await _runGit(
          workspace.path,
          const ['diff'],
          stdoutLimit: defaultFullDiffPreviewLimit,
          cancellation: cancellation,
        );
        _throwIfCancelled(cancellation);
        if (diff != null && diff.stdout.trim().isNotEmpty) {
          final preview = _previewForText(
            diff.stdout,
            limit: defaultFullDiffPreviewLimit,
          );
          artifacts.add(
            _artifact(
              task: task,
              run: run,
              kind: ArtifactKind.gitDiff,
              title: 'Git diff preview',
              contentPreview: preview.text,
              metadata: <String, Object?>{
                ..._metadataForGitCommand(
                  const ['git', 'diff'],
                  diff,
                  preview,
                  previewLimit: defaultFullDiffPreviewLimit,
                ),
                'raw_payload': true,
              },
            ),
          );
        }
      }
    }
    _throwIfCancelled(cancellation);
    return List.unmodifiable(artifacts);
  }

  Future<bool> _isGitWorkspace(
    String workspacePath,
    ArtifactCollectionCancellation? cancellation,
  ) async {
    final result = await _runGit(
      workspacePath,
      const ['rev-parse', '--is-inside-work-tree'],
      stdoutLimit: _gitWorkspaceProbeLimit,
      cancellation: cancellation,
    );
    return result != null &&
        !result.sourceTruncated &&
        result.stdout.trim() == 'true';
  }

  Future<_GitResult?> _runGit(
    String workspacePath,
    List<String> args, {
    required int stdoutLimit,
    required ArtifactCollectionCancellation? cancellation,
  }) async {
    _throwIfCancelled(cancellation);
    final abort = Completer<_GitAbortReason>();
    String? cancellationReason;
    void requestAbort(_GitAbortReason reason) {
      if (!abort.isCompleted) abort.complete(reason);
    }

    final timer = Timer(
      _commandTimeout,
      () => requestAbort(_GitAbortReason.timeout),
    );
    final removeCancellationListener = cancellation?.addListener((reason) {
      cancellationReason ??= reason;
      requestAbort(_GitAbortReason.cancelled);
    });
    final command = _gitArguments(workspacePath, args);

    late final Future<_ProcessStartOutcome> settledStart;
    try {
      settledStart = _processStarter('git', command).then<_ProcessStartOutcome>(
        _ProcessStarted.new,
        onError: (Object _, StackTrace _) => const _ProcessStartFailed(),
      );
    } on Object {
      timer.cancel();
      removeCancellationListener?.call();
      if (cancellationReason != null) throw StateError(cancellationReason!);
      return null;
    }

    final startOutcome = await Future.any<_ProcessStartOutcome>([
      settledStart,
      abort.future.then<_ProcessStartOutcome>(
        (_) => const _ProcessStartAborted(),
      ),
    ]);
    if (startOutcome is _ProcessStartAborted || abort.isCompleted) {
      timer.cancel();
      removeCancellationListener?.call();
      final lateCleanup = startOutcome is _ProcessStarted
          ? _cleanupLateProcess(
              startOutcome.process,
              gracePeriod: _terminationGracePeriod,
            )
          : settledStart.then<void>((lateOutcome) async {
              if (lateOutcome is _ProcessStarted) {
                await _cleanupLateProcess(
                  lateOutcome.process,
                  gracePeriod: _terminationGracePeriod,
                );
              }
            });
      unawaited(lateCleanup.catchError((Object _) {}));
      if (cancellationReason != null) throw StateError(cancellationReason!);
      return null;
    }
    if (startOutcome is _ProcessStartFailed) {
      timer.cancel();
      removeCancellationListener?.call();
      if (cancellationReason != null) throw StateError(cancellationReason!);
      return null;
    }
    final process = (startOutcome as _ProcessStarted).process;

    final stdout = _BoundedBytes(stdoutLimit);
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();
    StreamSubscription<List<int>>? stdoutSubscription;
    StreamSubscription<List<int>>? stderrSubscription;
    var parentExited = false;
    Future<int>? exitCode;
    final successfulExit = Completer<void>();

    Future<int>? captureExitCode() {
      final captured = exitCode;
      if (captured != null) return captured;
      try {
        final tracked = process.exitCode.then<int>(
          (value) {
            parentExited = true;
            if (!successfulExit.isCompleted) successfulExit.complete();
            return value;
          },
          onError: (Object error, StackTrace stackTrace) {
            requestAbort(_GitAbortReason.exitError);
            Error.throwWithStackTrace(error, stackTrace);
          },
        );
        unawaited(
          tracked.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
        );
        exitCode = tracked;
        return tracked;
      } on Object {
        return null;
      }
    }

    Future<void> cancelOutputStreams() async {
      await _cancelSubscriptionsBounded(<StreamSubscription<List<int>>?>[
        stdoutSubscription,
        stderrSubscription,
      ], timeout: _terminationGracePeriod);
    }

    Future<void> terminateAndReap() async {
      var trackedExit = captureExitCode();
      if (!parentExited) {
        try {
          process.kill(ProcessSignal.sigterm);
        } on Object {
          // Continue to the bounded grace period and forced termination.
        }
        if (trackedExit == null) {
          await Future<void>.delayed(_terminationGracePeriod);
        } else {
          await Future.any<void>([
            successfulExit.future,
            Future<void>.delayed(_terminationGracePeriod),
          ]);
        }
        if (!parentExited) {
          try {
            process.kill(ProcessSignal.sigkill);
          } on Object {
            // Reaping below remains mandatory when an exit future is available.
          }
        }
      }
      trackedExit ??= captureExitCode();
      if (trackedExit != null) {
        try {
          await trackedExit;
        } on Object {
          // A broken Process implementation cannot provide a usable exit code.
        }
      }
      await cancelOutputStreams();
    }

    try {
      try {
        final trackedExit = captureExitCode();
        if (trackedExit == null) {
          throw StateError('Could not observe child process exit.');
        }
        stdoutSubscription = process.stdout.listen(
          stdout.add,
          onError: (Object _, StackTrace _) {
            requestAbort(_GitAbortReason.streamError);
          },
          onDone: stdoutDone.complete,
        );
        stderrSubscription = process.stderr.listen(
          (_) {},
          onError: (Object _, StackTrace _) {
            requestAbort(_GitAbortReason.streamError);
          },
          onDone: stderrDone.complete,
        );
        final stdinClose = process.stdin.close();
        unawaited(
          stdinClose.catchError((Object _) {
            requestAbort(_GitAbortReason.streamError);
          }),
        );
      } on Object {
        await terminateAndReap();
        if (cancellationReason != null) throw StateError(cancellationReason!);
        return null;
      }
      final trackedExit = exitCode!;
      final normalCompletion = Future.wait<Object?>([
        successfulExit.future,
        stdoutDone.future,
        stderrDone.future,
      ]);
      final outcome = await Future.any<Object?>([
        normalCompletion,
        abort.future,
      ]);
      if (outcome is _GitAbortReason) {
        await terminateAndReap();
        if (cancellationReason != null) throw StateError(cancellationReason!);
        return null;
      }
      timer.cancel();
      final code = await trackedExit;
      if (code != 0) return null;
      return _GitResult(
        utf8.decode(stdout.takeBytes(), allowMalformed: true),
        sourceTruncated: stdout.truncated,
      );
    } finally {
      timer.cancel();
      removeCancellationListener?.call();
    }
  }

  ArtifactRecord _artifact({
    required TaskRecord task,
    required TaskRunRecord run,
    required ArtifactKind kind,
    required String title,
    String? path,
    String? contentPreview,
    String? sha256,
    int? sizeBytes,
    Map<String, Object?> metadata = const <String, Object?>{},
  }) {
    return ArtifactRecord(
      id: _newId(task: task, run: run),
      taskId: task.id,
      runId: run.id,
      kind: kind,
      title: dataSanitizer.sanitizeText(title),
      createdAt: _clock(),
      path: path == null ? null : dataSanitizer.sanitizeText(path),
      contentPreview: contentPreview,
      sha256: sha256,
      sizeBytes: sizeBytes,
      metadata: dataSanitizer.sanitize(metadata),
    );
  }

  String _newId({required TaskRecord task, required TaskRunRecord run}) {
    final id = idGenerator?.call('artifact').trim();
    if (id != null && id.isNotEmpty) return id;
    for (var attempt = 0; attempt < 100; attempt += 1) {
      final nonce = _generateNonce(16);
      final encodedNonce = base64UrlEncode(nonce).replaceAll('=', '');
      final id = 'artifact-${task.id}-${run.id}-$encodedNonce';
      if (_issuedDefaultIds.add(id)) return id;
    }
    throw StateError('Could not generate a unique artifact id.');
  }

  List<int> _generateNonce(int length) {
    final nonce =
        nonceGenerator?.call(length) ??
        List<int>.generate(length, (_) => _random.nextInt(256));
    if (nonce.length != length || nonce.any((byte) => byte < 0 || byte > 255)) {
      throw StateError(
        'Artifact nonce generator must return exactly $length bytes.',
      );
    }
    return nonce;
  }

  Map<String, Object?> _metadataForGitCommand(
    List<String> command,
    _GitResult result,
    _TextPreview preview, {
    int? previewLimit,
  }) {
    final effectivePreviewLimit = previewLimit ?? this.previewLimit;
    return <String, Object?>{
      'source': 'git',
      'command': command,
      'preview_limit_bytes': effectivePreviewLimit,
      'truncated': result.sourceTruncated || preview.truncated,
    };
  }

  _TextPreview _previewForText(String value, {int? limit}) {
    final effectiveLimit = limit ?? previewLimit;
    final preview = StringBuffer();
    var retainedBytes = 0;
    var truncated = false;
    for (final rune in value.runes) {
      final runeBytes = _utf8LengthOfRune(rune);
      if (retainedBytes + runeBytes > effectiveLimit) {
        truncated = true;
        break;
      }
      preview.writeCharCode(rune);
      retainedBytes += runeBytes;
    }
    return _TextPreview(preview.toString(), truncated: truncated);
  }

  void _throwIfCancelled(ArtifactCollectionCancellation? cancellation) {
    final reason = cancellation?.reason;
    if (reason != null) throw StateError(reason);
  }
}

class _GitResult {
  const _GitResult(this.stdout, {required this.sourceTruncated});

  final String stdout;
  final bool sourceTruncated;
}

class _TextPreview {
  const _TextPreview(this.text, {required this.truncated});

  final String text;
  final bool truncated;
}

enum _GitAbortReason { timeout, cancelled, streamError, exitError }

sealed class _ProcessStartOutcome {
  const _ProcessStartOutcome();
}

class _ProcessStarted extends _ProcessStartOutcome {
  const _ProcessStarted(this.process);

  final Process process;
}

class _ProcessStartFailed extends _ProcessStartOutcome {
  const _ProcessStartFailed();
}

class _ProcessStartAborted extends _ProcessStartOutcome {
  const _ProcessStartAborted();
}

Future<void> _cleanupLateProcess(
  Process process, {
  required Duration gracePeriod,
}) async {
  StreamSubscription<List<int>>? stdoutSubscription;
  StreamSubscription<List<int>>? stderrSubscription;
  Future<int>? exitCode;
  var parentExited = false;
  final successfulExit = Completer<void>();

  try {
    stdoutSubscription = process.stdout.listen(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  } on Object {
    // Continue terminating the process even if a stream is unavailable.
  }
  try {
    stderrSubscription = process.stderr.listen(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  } on Object {
    // Continue terminating the process even if a stream is unavailable.
  }
  try {
    final stdinClose = process.stdin.close();
    unawaited(stdinClose.catchError((Object _) {}));
  } on Object {
    // Continue terminating the process even if stdin cannot be closed.
  }
  try {
    final trackedExit = process.exitCode.then<int>(
      (value) {
        parentExited = true;
        if (!successfulExit.isCompleted) successfulExit.complete();
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
    unawaited(
      trackedExit.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    exitCode = trackedExit;
  } on Object {
    // The Process contract is broken; termination remains best effort.
  }

  await Future<void>.delayed(Duration.zero);
  if (!parentExited) {
    try {
      process.kill(ProcessSignal.sigterm);
    } on Object {
      // Continue to the bounded grace period and forced termination.
    }
    await Future.any<void>([
      successfulExit.future,
      Future<void>.delayed(gracePeriod),
    ]);
    if (!parentExited) {
      try {
        process.kill(ProcessSignal.sigkill);
      } on Object {
        // Stream cleanup below is still required.
      }
    }
  }

  final trackedExit = exitCode;
  if (trackedExit != null) {
    try {
      await trackedExit;
    } on Object {
      // The late process reported an unusable exit result.
    }
  } else if (!parentExited) {
    await Future<void>.delayed(gracePeriod);
  }
  await _cancelSubscriptionsBounded(<StreamSubscription<List<int>>?>[
    stdoutSubscription,
    stderrSubscription,
  ], timeout: gracePeriod);
}

Future<void> _cancelSubscriptionsBounded(
  List<StreamSubscription<List<int>>?> subscriptions, {
  required Duration timeout,
}) async {
  final cancellations = <Future<void>>[];
  for (final subscription in subscriptions) {
    if (subscription == null) continue;
    try {
      final cancellation = subscription.cancel().then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      cancellations.add(cancellation);
    } on Object {
      // Each stream cancellation is independent and best effort.
    }
  }
  if (cancellations.isEmpty) return;
  await Future.any<void>([
    Future.wait<void>(cancellations),
    Future<void>.delayed(timeout),
  ]);
}

class _BoundedBytes {
  _BoundedBytes(this.limit);

  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: true);
  int _retained = 0;
  bool truncated = false;

  void add(List<int> chunk) {
    final remaining = limit - _retained;
    if (remaining > 0) {
      final count = math.min(remaining, chunk.length);
      if (count == chunk.length) {
        _bytes.add(chunk);
      } else if (count > 0) {
        _bytes.add(chunk.sublist(0, count));
      }
      _retained += count;
    }
    if (chunk.length > remaining) truncated = true;
  }

  List<int> takeBytes() => _bytes.takeBytes();
}

int _utf8LengthOfRune(int rune) {
  if (rune <= 0x7f) return 1;
  if (rune <= 0x7ff) return 2;
  if (rune <= 0xffff) return 3;
  return 4;
}

List<String> _gitArguments(String workspacePath, List<String> args) {
  final commandArgs = switch (args.firstOrNull) {
    'status' => <String>[...args, '--ignore-submodules=all'],
    'diff' => <String>[
      'diff',
      '--no-ext-diff',
      '--no-textconv',
      '--ignore-submodules=all',
      ...args.skip(1),
    ],
    _ => args,
  };
  return <String>[
    '--no-pager',
    '-c',
    'core.fsmonitor=false',
    '-C',
    workspacePath,
    ...commandArgs,
  ];
}

Future<Process> _defaultProcessStarter(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) {
  return Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
}

int _requirePositiveInt(String name, int value) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'Must be greater than zero.');
  }
  return value;
}

Duration _requirePositiveDuration(String name, Duration value) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'Must be greater than zero.');
  }
  return value;
}
