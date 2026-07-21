import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/platform/secure_file_reader.dart';

void main() {
  test('secure reader rejects a FIFO without blocking', () async {
    if (!Platform.isMacOS && !Platform.isLinux) return;
    final workspace = await Directory.systemTemp.createTemp(
      'ianvs-secure-reader-fifo-',
    );
    addTearDown(() => workspace.delete(recursive: true));
    final outbox = Directory('${workspace.path}/.ianvs/outbox/task-1');
    await outbox.create(recursive: true);
    final fifoPath = '${outbox.path}/report';
    final result = await Process.run('mkfifo', <String>[fifoPath]);
    expect(result.exitCode, 0, reason: result.stderr.toString());

    final read = await readWorkspaceFileSecurely(
      resolvedWorkspacePath: await workspace.resolveSymbolicLinks(),
      relativePath: '.ianvs/outbox/task-1/report',
      previewLimit: 64,
    ).timeout(const Duration(seconds: 1));

    expect(read, isNull);
  });
}
