import 'dart:async';
import 'dart:io';

import 'task_inbox_controller.dart';

typedef TaskPersistenceAsyncCleanup = Future<void> Function();

abstract interface class TaskPersistenceQuarantineOwner {
  String get path;

  bool get isClosed;

  bool get shouldAutoCleanupWhenQuiesced;

  Future<void> get whenQuiesced;

  Future<void> cleanup();
}

class TaskPersistenceOwnerCleanup implements TaskPersistenceQuarantineOwner {
  TaskPersistenceOwnerCleanup({
    required String? path,
    required this.controller,
    required this.shutdownScheduler,
    required this.disposeController,
    required this.closeRepository,
  }) : path = taskPersistencePathKey(path) {
    _repositoryCleanup = _BoundedAsyncCleanup(
      operationName: 'closeRepository',
      watchdog: controller.persistenceWatchdog,
    );
  }

  @override
  final String path;
  final TaskInboxController controller;
  final TaskPersistenceAsyncCleanup shutdownScheduler;
  final void Function() disposeController;
  final TaskPersistenceAsyncCleanup closeRepository;

  bool _schedulerShutdown = false;
  bool _controllerDisposed = false;
  bool _closed = false;
  Future<void>? _cleanupFuture;
  late final _BoundedAsyncCleanup _repositoryCleanup;

  @override
  bool get isClosed => _closed;

  @override
  bool get shouldAutoCleanupWhenQuiesced => true;

  @override
  Future<void> get whenQuiesced => controller.whenPersistenceQuiesced;

  @override
  Future<void> cleanup() {
    if (_closed) return Future<void>.value();
    final current = _cleanupFuture;
    if (current != null) return current;
    late final Future<void> cleanup;
    cleanup = _cleanup().whenComplete(() {
      if (identical(_cleanupFuture, cleanup)) _cleanupFuture = null;
    });
    _cleanupFuture = cleanup;
    return cleanup;
  }

  Future<void> _cleanup() async {
    if (!_schedulerShutdown) {
      await shutdownScheduler();
      _schedulerShutdown = true;
    }
    try {
      await controller.settle();
    } on TaskPersistenceStalledException {
      if (!controller.isPersistenceQuiesced) rethrow;
    }
    if (!controller.isPersistenceQuiesced) {
      throw StateError(
        'Task persistence for $path still has an in-flight operation.',
      );
    }
    if (!_controllerDisposed) {
      disposeController();
      _controllerDisposed = true;
    }
    await _repositoryCleanup.run(closeRepository);
    _closed = true;
  }
}

class TaskPersistencePendingOperation<T>
    implements TaskPersistenceQuarantineOwner {
  TaskPersistencePendingOperation({
    required String? path,
    required this.operationName,
    required this.watchdog,
    required Future<T> Function() operation,
    required this.closeRepository,
  }) : path = taskPersistencePathKey(path),
       assert(watchdog > Duration.zero) {
    _repositoryCleanup = _BoundedAsyncCleanup(
      operationName: 'closeRepository',
      watchdog: watchdog,
    );
    _source = Future<T>.sync(operation);
    final resultCompleter = Completer<T>();
    final watchdogTimer = Zone.root.run(
      () => Timer(watchdog, () {
        if (resultCompleter.isCompleted) return;
        final fault = _fault ??= TaskPersistenceStalledException(
          operation: operationName,
          watchdog: watchdog,
          generation: 1,
        );
        _abandoned = true;
        resultCompleter.completeError(fault, StackTrace.current);
      }),
    );
    _source.then<void>(
      (value) {
        _markQuiesced();
        watchdogTimer.cancel();
        if (!resultCompleter.isCompleted) resultCompleter.complete(value);
      },
      onError: (Object error, StackTrace stackTrace) {
        _markQuiesced();
        watchdogTimer.cancel();
        if (!resultCompleter.isCompleted) {
          resultCompleter.completeError(error, stackTrace);
        }
      },
    );
    result = resultCompleter.future;
  }

  @override
  final String path;
  final String operationName;
  final Duration watchdog;
  final TaskPersistenceAsyncCleanup closeRepository;
  late final Future<T> _source;
  late final Future<T> result;
  final Completer<void> _quiesced = Completer<void>();
  TaskPersistenceStalledException? _fault;
  bool _sourceQuiesced = false;
  bool _abandoned = false;
  bool _transferred = false;
  bool _closed = false;
  Future<void>? _cleanupFuture;
  late final _BoundedAsyncCleanup _repositoryCleanup;

  @override
  bool get isClosed => _closed;

  @override
  bool get shouldAutoCleanupWhenQuiesced =>
      !_transferred && (_abandoned || _fault != null);

  @override
  Future<void> get whenQuiesced => _quiesced.future;

  void abandon() {
    if (_transferred || _closed) return;
    _abandoned = true;
  }

  void transfer() {
    if (!_sourceQuiesced) {
      throw StateError(
        'Cannot transfer task persistence before $operationName quiesces.',
      );
    }
    if (_fault != null || _abandoned || _closed) {
      throw StateError(
        'Cannot transfer quarantined task persistence for $path.',
      );
    }
    _transferred = true;
  }

  @override
  Future<void> cleanup() {
    if (_closed || _transferred) return Future<void>.value();
    final current = _cleanupFuture;
    if (current != null) return current;
    late final Future<void> cleanup;
    cleanup = _cleanup().whenComplete(() {
      if (identical(_cleanupFuture, cleanup)) _cleanupFuture = null;
    });
    _cleanupFuture = cleanup;
    return cleanup;
  }

  Future<void> _cleanup() async {
    if (!_sourceQuiesced) {
      final fault = _fault;
      if (fault != null) throw fault;
      throw StateError(
        'Task persistence operation $operationName is still in progress for '
        '$path.',
      );
    }
    if (!_abandoned && _fault == null) {
      throw StateError(
        'Task persistence operation $operationName is still owned by its '
        'caller for $path.',
      );
    }
    await _repositoryCleanup.run(closeRepository);
    _closed = true;
  }

  void _markQuiesced() {
    _sourceQuiesced = true;
    if (!_quiesced.isCompleted) _quiesced.complete();
  }
}

class TaskPersistenceQuarantineRegistry {
  static final TaskPersistenceQuarantineRegistry shared =
      TaskPersistenceQuarantineRegistry();

  final Map<String, TaskPersistenceQuarantineOwner> _owners =
      <String, TaskPersistenceQuarantineOwner>{};

  bool get hasOwners => _owners.isNotEmpty;

  bool blocksPath(String? path) {
    return _owners.containsKey(taskPersistencePathKey(path));
  }

  void retain(TaskPersistenceQuarantineOwner owner) {
    final existing = _owners[owner.path];
    if (existing != null && !identical(existing, owner)) {
      throw StateError(
        'Task persistence path is already quarantined: ${owner.path}',
      );
    }
    _owners[owner.path] = owner;
    unawaited(_cleanupWhenQuiesced(owner));
  }

  void release(TaskPersistenceQuarantineOwner owner) {
    if (identical(_owners[owner.path], owner)) _owners.remove(owner.path);
  }

  Future<void> ensurePathAvailable(String? path) async {
    final key = taskPersistencePathKey(path);
    final owner = _owners[key];
    if (owner == null) return;
    try {
      await owner.cleanup();
    } finally {
      if (owner.isClosed && identical(_owners[key], owner)) {
        _owners.remove(key);
      }
    }
  }

  Future<void> _cleanupWhenQuiesced(
    TaskPersistenceQuarantineOwner owner,
  ) async {
    try {
      await owner.whenQuiesced;
      if (!owner.shouldAutoCleanupWhenQuiesced) return;
      await ensurePathAvailable(owner.path);
    } on Object {
      // The owner remains keyed by path. A later lifecycle retry will surface
      // the error and retry cleanup without opening the same repository.
    }
  }
}

class _BoundedAsyncCleanup {
  _BoundedAsyncCleanup({required this.operationName, required this.watchdog});

  final String operationName;
  final Duration watchdog;
  Future<void>? _source;
  bool _quiesced = false;
  Object? _error;
  StackTrace? _stackTrace;
  TaskPersistenceStalledException? _fault;

  Future<void> run(TaskPersistenceAsyncCleanup operation) async {
    var source = _source;
    if (source == null) {
      source = Future<void>.sync(operation);
      _source = source;
      source.then<void>(
        (_) => _quiesced = true,
        onError: (Object error, StackTrace stackTrace) {
          _error = error;
          _stackTrace = stackTrace;
          _quiesced = true;
        },
      );
    }
    if (_quiesced) {
      final error = _error;
      if (error != null) {
        Error.throwWithStackTrace(error, _stackTrace ?? StackTrace.current);
      }
      return;
    }
    final existingFault = _fault;
    if (existingFault != null) throw existingFault;
    await source.timeout(
      watchdog,
      onTimeout: () {
        final fault = _fault ??= TaskPersistenceStalledException(
          operation: operationName,
          watchdog: watchdog,
          generation: 1,
        );
        throw fault;
      },
    );
  }
}

String taskPersistencePathKey(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) {
    return '<default-task-persistence>';
  }
  if (trimmed == '<default-task-persistence>') return trimmed;
  final lexical = _lexicalAbsolutePath(trimmed);
  final resolved = _resolveExistingPathPrefix(lexical);
  // Windows path lookup is case-insensitive. Other platforms fold only when
  // the deepest existing ancestor proves that its actual volume is
  // case-insensitive; case-sensitive macOS volumes must keep distinct files.
  return Platform.isWindows || _isConfirmedCaseInsensitive(resolved)
      ? resolved.toLowerCase()
      : resolved;
}

Future<void> prepareTaskPersistenceTarget({
  required TaskPersistenceQuarantineRegistry registry,
  Future<void>? previousCleanup,
  String? targetPath,
  bool injectedController = false,
}) async {
  if (previousCleanup != null) {
    try {
      await previousCleanup;
    } on Object {
      final errorIsIsolated =
          registry.hasOwners &&
          (injectedController || !registry.blocksPath(targetPath));
      if (!errorIsIsolated) rethrow;
    }
  }
  if (!injectedController) await registry.ensurePathAvailable(targetPath);
}

String _lexicalAbsolutePath(String path) {
  final absolute = File(path).absolute.path;
  try {
    return Uri.file(
      absolute,
      windows: Platform.isWindows,
    ).normalizePath().toFilePath(windows: Platform.isWindows);
  } on Object {
    return absolute;
  }
}

String _resolveExistingPathPrefix(String absolutePath) {
  try {
    final targetType = FileSystemEntity.typeSync(
      absolutePath,
      followLinks: true,
    );
    if (targetType == FileSystemEntityType.file) {
      return _lexicalAbsolutePath(
        File(absolutePath).resolveSymbolicLinksSync(),
      );
    }
    if (targetType == FileSystemEntityType.directory) {
      return _lexicalAbsolutePath(
        Directory(absolutePath).resolveSymbolicLinksSync(),
      );
    }
  } on FileSystemException {
    // Fall through to the deepest resolvable parent.
  }

  final suffix = <String>[_pathBasename(absolutePath)];
  var cursor = File(absolutePath).parent;
  while (true) {
    try {
      if (FileSystemEntity.typeSync(cursor.path, followLinks: true) ==
          FileSystemEntityType.directory) {
        var resolved = cursor.resolveSymbolicLinksSync();
        for (final segment in suffix) {
          resolved = _joinPath(resolved, segment);
        }
        return _lexicalAbsolutePath(resolved);
      }
    } on FileSystemException {
      // Try the next existing ancestor.
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) break;
    suffix.insert(0, _pathBasename(cursor.path));
    cursor = parent;
  }
  return absolutePath;
}

String _pathBasename(String path) {
  final separator = Platform.pathSeparator;
  var end = path.length;
  while (end > 1 && path.substring(end - 1, end) == separator) {
    end -= 1;
  }
  final trimmed = path.substring(0, end);
  final index = trimmed.lastIndexOf(separator);
  return index < 0 ? trimmed : trimmed.substring(index + 1);
}

String _joinPath(String parent, String child) {
  if (parent.endsWith(Platform.pathSeparator)) return '$parent$child';
  return '$parent${Platform.pathSeparator}$child';
}

bool _isConfirmedCaseInsensitive(String path) {
  var cursor = File(path).parent;
  try {
    if (FileSystemEntity.typeSync(path, followLinks: true) ==
        FileSystemEntityType.directory) {
      cursor = Directory(path);
    }
  } on FileSystemException {
    // Start from the lexical parent when the target cannot be inspected.
  }
  while (true) {
    try {
      if (FileSystemEntity.typeSync(cursor.path, followLinks: true) ==
          FileSystemEntityType.directory) {
        final resolved = cursor.resolveSymbolicLinksSync();
        final basename = _pathBasename(resolved);
        final alternateBasename = _asciiCaseVariant(basename);
        if (alternateBasename != basename) {
          final alternate = _joinPath(
            Directory(resolved).parent.path,
            alternateBasename,
          );
          return FileSystemEntity.identicalSync(resolved, alternate);
        }
      }
    } on FileSystemException {
      // Try an existing ancestor with an alphabetic path component.
    }
    final parent = cursor.parent;
    if (parent.path == cursor.path) return false;
    cursor = parent;
  }
}

String _asciiCaseVariant(String value) {
  for (var index = 0; index < value.length; index += 1) {
    final codeUnit = value.codeUnitAt(index);
    if (codeUnit >= 65 && codeUnit <= 90) {
      return '${value.substring(0, index)}'
          '${String.fromCharCode(codeUnit + 32)}'
          '${value.substring(index + 1)}';
    }
    if (codeUnit >= 97 && codeUnit <= 122) {
      return '${value.substring(0, index)}'
          '${String.fromCharCode(codeUnit - 32)}'
          '${value.substring(index + 1)}';
    }
  }
  return value;
}
