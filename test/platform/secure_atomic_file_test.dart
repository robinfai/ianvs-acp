import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/secure_atomic_file.dart';

void main() {
  test(
    'writes private files atomically with private directory modes',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs-acp-secure-atomic-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/config/settings.json');

      await SecureAtomicFile.writeString(file, '{"ok":true}\n');

      expect((await file.stat()).mode & 0x1ff, 0x180);
      expect((await file.parent.stat()).mode & 0x1ff, 0x1c0);
      expect(await file.readAsString(), '{"ok":true}\n');
    },
  );

  test(
    'rename failure preserves the old file and removes the temporary',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'ianvs-acp-secure-atomic-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/settings.json');
      await file.writeAsString('old-value\n');

      await expectLater(
        SecureAtomicFile.writeString(
          file,
          'new-value\n',
          rename: (source, destination) async {
            throw FileSystemException('injected rename failure', destination);
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(await file.readAsString(), 'old-value\n');
      expect(
        await file.parent
            .list()
            .where((entry) => entry.path.contains('settings.json.tmp-'))
            .toList(),
        isEmpty,
      );
    },
  );

  test('flushes the parent directory after the atomic rename', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    final events = <String>[];

    await SecureAtomicFile.writeString(
      file,
      'new-value\n',
      rename: (source, destination) async {
        events.add('rename');
        return source.rename(destination);
      },
      directorySync: (directory) {
        events.add('directory-sync');
        expect(directory.path, file.parent.path);
        expect(file.readAsStringSync(), 'new-value\n');
      },
    );

    expect(events, <String>['rename', 'directory-sync']);
  });

  test('flushes newly created directory entries from inner to outer', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final first = Directory('${temp.path}/first');
    final second = Directory('${first.path}/second');
    final file = File('${second.path}/settings.json');
    final events = <String>[];

    await SecureAtomicFile.writeString(
      file,
      'new-value\n',
      rename: (source, destination) async {
        events.add('rename');
        return source.rename(destination);
      },
      directorySync: (directory) => events.add(directory.path),
    );

    expect(events, <String>['rename', second.path, first.path, temp.path]);
  });

  test('every newly created ancestor sync failure is reported', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));

    for (final failureLevel in <String>['first', 'root']) {
      final root = Directory('${temp.path}/case-$failureLevel');
      await root.create();
      final first = Directory('${root.path}/first');
      final second = Directory('${first.path}/second');
      final file = File('${second.path}/settings.json');
      final failurePath = failureLevel == 'first' ? first.path : root.path;
      final synced = <String>[];

      await expectLater(
        SecureAtomicFile.writeString(
          file,
          'new-value\n',
          directorySync: (directory) {
            synced.add(directory.path);
            if (directory.path == failurePath) {
              throw FileSystemException(
                'injected ancestor sync failure',
                directory.path,
              );
            }
          },
        ),
        throwsA(isA<FileSystemException>()),
        reason: failureLevel,
      );

      expect(synced.take(2).toList(), <String>[second.path, first.path]);
      if (failureLevel == 'root') expect(synced.last, root.path);
      expect(await file.readAsString(), 'new-value\n');
    }
  });

  test('parent directory sync failure is reported after rename', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString('old-value\n');

    await expectLater(
      SecureAtomicFile.writeString(
        file,
        'new-value\n',
        directorySync: (directory) {
          throw FileSystemException(
            'injected directory sync failure',
            directory.path,
          );
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await file.readAsString(), 'new-value\n');
    expect(
      await file.parent
          .list()
          .where((entry) => entry.path.contains('settings.json.tmp-'))
          .toList(),
      isEmpty,
    );
  });

  test('chmod failure is reported and removes the temporary file', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');
    await file.writeAsString('old-value\n');
    var chmodCalls = 0;

    await expectLater(
      SecureAtomicFile.writeString(
        file,
        'new-value\n',
        processRunner: (executable, arguments) async {
          chmodCalls += 1;
          return ProcessResult(
            pid,
            chmodCalls == 1 ? 1 : 0,
            '',
            chmodCalls == 1 ? 'injected chmod failure' : '',
          );
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(chmodCalls, 1);
    expect(await file.readAsString(), 'old-value\n');
    expect(
      await file.parent
          .list()
          .where((entry) => entry.path.contains('settings.json.tmp-'))
          .toList(),
      isEmpty,
    );
  });

  test('a failed synchronized operation does not poison later work', () async {
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final file = File('${temp.path}/settings.json');

    await expectLater(
      SecureAtomicFile.synchronized<void>(file, () async {
        throw const FileSystemException('injected mutation failure');
      }),
      throwsA(isA<FileSystemException>()),
    );

    final result = await SecureAtomicFile.synchronized(
      file,
      () async => 'later-work-ran',
    );
    expect(result, 'later-work-ran');
  });

  test('cross-process lock serializes real and symlink paths', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-lock-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/settings.json');
    await target.writeAsString('{}\n');
    final alias = File('${temp.path}/alias.json');
    await Link(alias.path).create(target.path);
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondEntered = false;

    final first = SecureAtomicFile.synchronizedAcrossProcesses<void>(target, (
      _,
    ) async {
      firstEntered.complete();
      await releaseFirst.future;
    });
    await firstEntered.future;
    final second = SecureAtomicFile.synchronizedAcrossProcesses<void>(alias, (
      _,
    ) async {
      secondEntered = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(secondEntered, isFalse);

    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(secondEntered, isTrue);
    final lockFile = File('${temp.path}/.settings.json.lock');
    expect(await lockFile.exists(), isTrue);
    expect((await lockFile.stat()).mode & 0x1ff, 0x180);
  });

  test('a replaced temporary path cannot redirect private contents', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final target = File('${temp.path}/settings.json');
    final victim = File('${temp.path}/victim.txt');
    await target.writeAsString('old-value\n');
    await victim.writeAsString('victim-value\n');
    String? replacedPath;

    await expectLater(
      SecureAtomicFile.writeString(
        target,
        'private-new-value\n',
        processRunner: (executable, arguments) async {
          replacedPath = arguments.last;
          await File(replacedPath!).delete();
          await Link(replacedPath!).create(victim.path);
          return ProcessResult(pid, 0, '', '');
        },
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await target.readAsString(), 'old-value\n');
    expect(await victim.readAsString(), 'victim-value\n');
    expect(
      await FileSystemEntity.type(replacedPath!, followLinks: false),
      FileSystemEntityType.notFound,
    );
  });

  test('rejects an existing parent writable by other principals', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final chmod = await Process.run('/bin/chmod', <String>['0777', temp.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    final target = File('${temp.path}/settings.json');
    await target.writeAsString('old-value\n');

    await expectLater(
      SecureAtomicFile.writeString(target, 'private-new-value\n'),
      throwsA(isA<FileSystemException>()),
    );

    expect(await target.readAsString(), 'old-value\n');
    expect((await temp.stat()).mode & 0x1ff, 0x1ff);
  });

  test('allows an existing sticky temporary directory', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final temp = await Directory.systemTemp.createTemp(
      'ianvs-acp-secure-atomic-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final chmod = await Process.run('/bin/chmod', <String>['1777', temp.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    final target = File('${temp.path}/settings.json');

    await SecureAtomicFile.writeString(target, 'private-value\n');

    expect(await target.readAsString(), 'private-value\n');
    expect((await target.stat()).mode & 0x1ff, 0x180);
  });
}
