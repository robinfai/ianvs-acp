import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/tasks/task_inbox_controller.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_persistence_cleanup.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

import '../support/memory_task_repository.dart';

void main() {
  test(
    'quarantine never closes or reuses a path before orphan quiescence',
    () async {
      final createdAt = DateTime(2026, 7, 10, 8);
      final store = MemoryTaskRepository(
        TaskInboxSnapshot(
          updatedAt: createdAt,
          tasks: [
            TaskRecord(
              id: 'task-1',
              title: 'Initial',
              description: '',
              workspacePath: '/workspace/app',
              agentName: 'Codex',
              status: TaskStatus.inbox,
              priority: TaskPriority.normal,
              createdAt: createdAt,
              updatedAt: createdAt,
            ),
          ],
        ),
      );
      final writeStarted = Completer<void>();
      final releaseWrite = Completer<void>();
      store.beforeOperation = (operation) async {
        if (operation != 'updateTask') return;
        if (!writeStarted.isCompleted) writeStarted.complete();
        await releaseWrite.future;
      };
      final controller = TaskInboxController(
        repository: store,
        persistenceWatchdog: const Duration(milliseconds: 20),
      );
      await controller.load();
      final update = controller.updateTask('task-1', title: 'Late commit');
      await writeStarted.future;
      await expectLater(
        update,
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      var shutdownCalls = 0;
      var disposeCalls = 0;
      var closeCalls = 0;
      final owner = TaskPersistenceOwnerCleanup(
        path: '/state/task_inbox.sqlite3',
        controller: controller,
        shutdownScheduler: () async {
          shutdownCalls += 1;
        },
        disposeController: () {
          disposeCalls += 1;
          controller.dispose();
        },
        closeRepository: () async {
          closeCalls += 1;
        },
      );
      final firstStateRegistry = TaskPersistenceQuarantineRegistry.shared;
      final secondStateRegistry = TaskPersistenceQuarantineRegistry.shared;
      expect(identical(firstStateRegistry, secondStateRegistry), isTrue);
      expect(firstStateRegistry.hasOwners, isFalse);
      firstStateRegistry.retain(owner);
      addTearDown(() async {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
        await controller.whenPersistenceQuiesced;
        await firstStateRegistry.ensurePathAvailable(
          '/state/task_inbox.sqlite3',
        );
        expect(firstStateRegistry.hasOwners, isFalse);
      });

      await expectLater(
        secondStateRegistry.ensurePathAvailable('/state/task_inbox.sqlite3'),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      expect(
        secondStateRegistry.blocksPath('/state/task_inbox.sqlite3'),
        isTrue,
      );
      await secondStateRegistry.ensurePathAvailable('/state/other.sqlite3');
      expect(shutdownCalls, 1);
      expect(disposeCalls, 0);
      expect(closeCalls, 0);

      releaseWrite.complete();
      await controller.whenPersistenceQuiesced;
      await secondStateRegistry.ensurePathAvailable(
        '/state/task_inbox.sqlite3',
      );

      expect(
        firstStateRegistry.blocksPath('/state/task_inbox.sqlite3'),
        isFalse,
      );
      expect(shutdownCalls, 1);
      expect(disposeCalls, 1);
      expect(closeCalls, 1);
    },
  );

  test('quarantine keys owners by repository path', () async {
    final firstController = TaskInboxController(
      repository: MemoryTaskRepository(),
    );
    final secondController = TaskInboxController(
      repository: MemoryTaskRepository(),
    );
    await Future.wait([firstController.load(), secondController.load()]);
    final registry = TaskPersistenceQuarantineRegistry();
    final first = TaskPersistenceOwnerCleanup(
      path: '/state/first.sqlite3',
      controller: firstController,
      shutdownScheduler: () async {},
      disposeController: firstController.dispose,
      closeRepository: () async {},
    );
    final second = TaskPersistenceOwnerCleanup(
      path: '/state/second.sqlite3',
      controller: secondController,
      shutdownScheduler: () async {},
      disposeController: secondController.dispose,
      closeRepository: () async {},
    );

    registry.retain(first);
    registry.retain(second);

    expect(registry.blocksPath('/state/first.sqlite3'), isTrue);
    expect(registry.blocksPath('/state/second.sqlite3'), isTrue);
    await registry.ensurePathAvailable('/state/first.sqlite3');
    await registry.ensurePathAvailable('/state/second.sqlite3');
    expect(registry.hasOwners, isFalse);
  });

  test('stalled close stays path-owned and returns at its watchdog', () async {
    final controller = TaskInboxController(
      repository: MemoryTaskRepository(),
      persistenceWatchdog: const Duration(milliseconds: 20),
    );
    await controller.load();
    final releaseClose = Completer<void>();
    final registry = TaskPersistenceQuarantineRegistry();
    final owner = TaskPersistenceOwnerCleanup(
      path: '/state/closing.sqlite3',
      controller: controller,
      shutdownScheduler: () async {},
      disposeController: controller.dispose,
      closeRepository: () => releaseClose.future,
    );
    registry.retain(owner);
    addTearDown(() async {
      if (!releaseClose.isCompleted) releaseClose.complete();
      await registry.ensurePathAvailable('/state/closing.sqlite3');
    });

    await expectLater(
      registry.ensurePathAvailable('/state/closing.sqlite3'),
      throwsA(
        isA<TaskPersistenceStalledException>().having(
          (error) => error.operation,
          'operation',
          'closeRepository',
        ),
      ),
    );
    expect(registry.blocksPath('/state/closing.sqlite3'), isTrue);

    releaseClose.complete();
    await registry.ensurePathAvailable('/state/closing.sqlite3');
    expect(registry.hasOwners, isFalse);
  });

  test('path key normalizes relative absolute dot segments and case', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-persistence-key-',
    );
    final previousCurrent = Directory.current;
    addTearDown(() async {
      Directory.current = previousCurrent;
      await temp.delete(recursive: true);
    });
    Directory.current = temp;

    final absolute = File('${temp.path}/state/task_inbox.sqlite3').path;
    expect(
      taskPersistencePathKey('state/../state/task_inbox.sqlite3'),
      taskPersistencePathKey(absolute),
    );
    expect(
      taskPersistencePathKey('${temp.path}/state/../state/task_inbox.sqlite3'),
      taskPersistencePathKey(absolute),
    );
    final caseVariantsShareKey =
        taskPersistencePathKey(absolute.toUpperCase()) ==
        taskPersistencePathKey(absolute.toLowerCase());
    expect(
      caseVariantsShareKey,
      Platform.isWindows || _directoryIsCaseInsensitive(temp),
    );
  });

  test('default in-memory path key is stable and cannot be bypassed', () async {
    final registry = TaskPersistenceQuarantineRegistry();
    final release = Completer<int>();
    final owner = TaskPersistencePendingOperation<int>(
      path: null,
      operationName: 'defaultStoreOperation',
      watchdog: const Duration(minutes: 1),
      operation: () => release.future,
      closeRepository: () async {},
    );
    registry.retain(owner);

    expect(taskPersistencePathKey(null), '<default-task-persistence>');
    expect(
      taskPersistencePathKey(taskPersistencePathKey(null)),
      '<default-task-persistence>',
    );
    expect(registry.blocksPath(null), isTrue);
    await expectLater(
      registry.ensurePathAvailable(null),
      throwsStateError,
    );

    release.complete(1);
    await owner.result;
    owner.transfer();
    registry.release(owner);
    expect(registry.hasOwners, isFalse);
  });

  test(
    'path key resolves an existing symlinked parent directory',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs-persistence-symlink-',
      );
      addTearDown(() async {
        await temp.delete(recursive: true);
      });
      final realParent = await Directory('${temp.path}/real').create();
      final linkedParent = Link('${temp.path}/linked');
      await linkedParent.create(realParent.path);

      expect(
        taskPersistencePathKey(
          '${linkedParent.path}/task_inbox.sqlite3',
        ),
        taskPersistencePathKey(
          '${realParent.path}/task_inbox.sqlite3',
        ),
      );
    },
    skip: Platform.isWindows
        ? 'Windows symlink creation requires host-specific privileges.'
        : false,
  );

  test(
    'stalled migration remains path-owned until its source quiesces',
    () async {
      final registry = TaskPersistenceQuarantineRegistry();
      final migrationStarted = Completer<void>();
      final releaseMigration = Completer<int>();
      var closeCalls = 0;
      final migration = TaskPersistencePendingOperation<int>(
        path: '/state/migration.sqlite3',
        operationName: 'migrateIfNeeded',
        watchdog: const Duration(milliseconds: 20),
        operation: () {
          migrationStarted.complete();
          return releaseMigration.future;
        },
        closeRepository: () async {
          closeCalls += 1;
        },
      );
      registry.retain(migration);
      addTearDown(() async {
        if (!releaseMigration.isCompleted) releaseMigration.complete(1);
        await migration.whenQuiesced;
        migration.abandon();
        await registry.ensurePathAvailable('/state/migration.sqlite3');
      });

      await migrationStarted.future;
      await expectLater(
        migration.result,
        throwsA(
          isA<TaskPersistenceStalledException>().having(
            (error) => error.operation,
            'operation',
            'migrateIfNeeded',
          ),
        ),
      );
      expect(registry.blocksPath('/state/migration.sqlite3'), isTrue);
      expect(closeCalls, 0);
      await expectLater(
        registry.ensurePathAvailable('/state/migration.sqlite3'),
        throwsA(isA<TaskPersistenceStalledException>()),
      );
      await registry.ensurePathAvailable('/state/different.sqlite3');
      expect(closeCalls, 0);

      releaseMigration.complete(1);
      await migration.whenQuiesced;
      await registry.ensurePathAvailable('/state/migration.sqlite3');
      expect(closeCalls, 1);
      expect(registry.hasOwners, isFalse);
    },
  );

  test(
    'cleanup errors isolate different owned and injected targets',
    () async {
      final registry = TaskPersistenceQuarantineRegistry();
      final releaseOldOwner = Completer<int>();
      final owner = TaskPersistencePendingOperation<int>(
        path: '/state/old.sqlite3',
        operationName: 'oldOwner',
        watchdog: const Duration(minutes: 1),
        operation: () => releaseOldOwner.future,
        closeRepository: () async {},
      );
      registry.retain(owner);

      Future<void> cleanupError() => Future<void>.error(
        StateError('old owner cleanup failed'),
      );
      await prepareTaskPersistenceTarget(
        registry: registry,
        previousCleanup: cleanupError(),
        targetPath: '/state/new.sqlite3',
      );
      await prepareTaskPersistenceTarget(
        registry: registry,
        previousCleanup: cleanupError(),
        injectedController: true,
      );
      await expectLater(
        prepareTaskPersistenceTarget(
          registry: registry,
          previousCleanup: cleanupError(),
          targetPath: '/state/old.sqlite3',
        ),
        throwsStateError,
      );

      releaseOldOwner.complete(1);
      await owner.result;
      owner.transfer();
      registry.release(owner);
      expect(registry.hasOwners, isFalse);
    },
  );
}

bool _directoryIsCaseInsensitive(Directory directory) {
  final name = directory.uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .last;
  final first = name.substring(0, 1);
  final alternateName = first == first.toUpperCase()
      ? '${first.toLowerCase()}${name.substring(1)}'
      : '${first.toUpperCase()}${name.substring(1)}';
  final alternate = '${directory.parent.path}'
      '${Platform.pathSeparator}$alternateName';
  try {
    return FileSystemEntity.identicalSync(directory.path, alternate);
  } on FileSystemException {
    return false;
  }
}
