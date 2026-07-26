import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_daemon_workflow.dart';

void main() {
  test('daemon socket path uses an explicit portable temporary directory', () {
    final first = IanvsDaemonProcess.socketPathForDatabase(
      '/workspace/one.sqlite3',
      temporaryDirectory: '/tmp/',
    );
    final repeated = IanvsDaemonProcess.socketPathForDatabase(
      '/workspace/one.sqlite3',
      temporaryDirectory: '/tmp',
    );
    final other = IanvsDaemonProcess.socketPathForDatabase(
      '/workspace/two.sqlite3',
      temporaryDirectory: '/tmp',
    );

    expect(first, repeated);
    expect(first, startsWith('/tmp/ianvs-acpd-'));
    expect(first, endsWith('.sock'));
    expect(other, isNot(first));
    expect(
      IanvsDaemonProcess.socketPathForDatabase(
        '/workspace/root.sqlite3',
        temporaryDirectory: '/',
      ),
      startsWith('/ianvs-acpd-'),
    );
  });

  test('daemon socket path defaults to an existing system temp root', () {
    final socket = IanvsDaemonProcess.socketPathForDatabase(
      '/workspace/workflow.sqlite3',
    );
    expect(FileSystemEntity.isAbsolute(socket), isTrue);
    expect(Directory(File(socket).parent.path).existsSync(), isTrue);
  });

  test('daemon socket path rejects relative roots', () {
    expect(
      () => IanvsDaemonProcess.socketPathForDatabase(
        '/workspace/workflow.sqlite3',
        temporaryDirectory: 'tmp',
      ),
      throwsArgumentError,
    );
  });

  test('permission responses require exactly one decision form', () async {
    final client = IanvsDaemonWorkflow(socketPath: '/tmp/not-connected.sock');
    addTearDown(client.dispose);

    await expectLater(
      client.respondTaskPermission(runId: 'run', requestId: 'request'),
      throwsArgumentError,
    );
    await expectLater(
      client.respondTaskPermission(
        runId: 'run',
        requestId: 'request',
        optionId: 'allow-once',
        cancel: true,
      ),
      throwsArgumentError,
    );
  });
}
