import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:dart_acp/src/security/workspace_jail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('resolveForSecureWrite', () {
    test('resolves relative and absolute paths under the main root', () async {
      final root = await Directory.systemTemp.createTemp('jail-write-main-');
      addTearDown(() => root.delete(recursive: true));
      final canonicalRoot = await root.resolveSymbolicLinks();
      final jail = WorkspaceJail(workspaceRoot: root.path);

      final relative = await jail.resolveForSecureWrite('nested/value.txt');
      expect(relative.canonicalRoot, canonicalRoot);
      expect(relative.relativePath, 'nested/value.txt');

      final absolute = await jail.resolveForSecureWrite(
        '${root.path}/absolute.txt',
      );
      expect(absolute.canonicalRoot, canonicalRoot);
      expect(absolute.relativePath, 'absolute.txt');
    });

    test(
      'allows additional roots and selects the longest matching root',
      () async {
        final root = await Directory.systemTemp.createTemp('jail-write-root-');
        addTearDown(() => root.delete(recursive: true));
        final additional = Directory('${root.path}/additional');
        await additional.create();
        final canonicalAdditional = await additional.resolveSymbolicLinks();
        final jail = WorkspaceJail(
          workspaceRoot: root.path,
          additionalWorkspaceRoots: <String>[additional.path],
        );

        final resolved = await jail.resolveForSecureWrite(
          '${additional.path}/nested/value.txt',
        );

        expect(resolved.canonicalRoot, canonicalAdditional);
        expect(resolved.relativePath, 'nested/value.txt');
      },
    );

    test('rejects empty, NUL, escaping, and external paths', () async {
      final root = await Directory.systemTemp.createTemp('jail-write-deny-');
      final outside = await Directory.systemTemp.createTemp(
        'jail-write-outside-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      final jail = WorkspaceJail(workspaceRoot: root.path);

      for (final path in <String>[
        '',
        '\u0000',
        '../escape.txt',
        '${root.path}/../escape.txt',
        '${outside.path}/value.txt',
      ]) {
        await expectLater(
          jail.resolveForSecureWrite(path),
          throwsA(isA<FileSystemException>()),
          reason: path,
        );
      }
    });

    test(
      'resolves the nearest existing ancestor for missing descendants',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'jail-write-missing-',
        );
        addTearDown(() => root.delete(recursive: true));
        final existing = Directory('${root.path}/existing');
        await existing.create();
        final jail = WorkspaceJail(workspaceRoot: root.path);

        final resolved = await jail.resolveForSecureWrite(
          'existing/one/two/value.txt',
        );

        expect(resolved.canonicalRoot, await root.resolveSymbolicLinks());
        expect(resolved.relativePath, 'existing/one/two/value.txt');
      },
    );

    test(
      'preserves internal final and intermediate symlink behavior',
      () async {
        final root = await Directory.systemTemp.createTemp('jail-write-link-');
        addTearDown(() => root.delete(recursive: true));
        final real = Directory('${root.path}/real');
        await real.create();
        final finalTarget = File('${real.path}/target.txt');
        await finalTarget.writeAsString('before');
        await Link('${root.path}/directory-link').create(real.path);
        await Link('${root.path}/file-link').create(finalTarget.path);
        final jail = WorkspaceJail(workspaceRoot: root.path);

        final intermediate = await jail.resolveForSecureWrite(
          'directory-link/missing/value.txt',
        );
        final finalLink = await jail.resolveForSecureWrite('file-link');

        expect(intermediate.canonicalRoot, await root.resolveSymbolicLinks());
        expect(intermediate.relativePath, 'real/missing/value.txt');
        expect(finalLink.relativePath, 'real/target.txt');
      },
    );

    test('rejects external and broken symlinks', () async {
      final root = await Directory.systemTemp.createTemp(
        'jail-write-link-root-',
      );
      final outside = await Directory.systemTemp.createTemp(
        'jail-write-link-out-',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      await Link('${root.path}/external').create(outside.path);
      await Link('${root.path}/broken').create('${outside.path}/missing');
      final jail = WorkspaceJail(workspaceRoot: root.path);

      await expectLater(
        jail.resolveForSecureWrite('external/value.txt'),
        throwsA(isA<FileSystemException>()),
      );
      await expectLater(
        jail.resolveForSecureWrite('broken/value.txt'),
        throwsA(isA<FileSystemException>()),
      );
    });
  });

  test('rejects missing descendants below an external symlink', () async {
    final root = await Directory.systemTemp.createTemp('jail-root-');
    final outside = await Directory.systemTemp.createTemp('jail-outside-');
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => outside.delete(recursive: true));
    await Link('${root.path}/link').create(outside.path);

    final jail = WorkspaceJail(workspaceRoot: root.path);
    await expectLater(
      jail.resolveAndEnsureWithin('${root.path}/link/new/nested/file.txt'),
      throwsA(isA<FileSystemException>()),
    );

    final provider = DefaultFsProvider(workspaceRoot: root.path);
    await expectLater(
      provider.writeTextFile(
        '${root.path}/link/new/nested/file.txt',
        'blocked',
      ),
      throwsA(isA<FileSystemException>()),
    );
    expect(File('${outside.path}/new/nested/file.txt').existsSync(), isFalse);
  });

  test('rejects descendants below a broken external symlink', () async {
    final root = await Directory.systemTemp.createTemp('jail-root-');
    final outsideParent = await Directory.systemTemp.createTemp(
      'jail-outside-parent-',
    );
    addTearDown(() => root.delete(recursive: true));
    addTearDown(() => outsideParent.delete(recursive: true));
    final missingOutside = '${outsideParent.path}/not-created';
    await Link('${root.path}/link').create(missingOutside);

    final jail = WorkspaceJail(workspaceRoot: root.path);
    await expectLater(
      jail.resolveAndEnsureWithin('${root.path}/link/new/file.txt'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
