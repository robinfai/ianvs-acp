import 'dart:io';

import 'package:dart_acp/dart_acp.dart';
import 'package:dart_acp/src/security/workspace_jail.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
