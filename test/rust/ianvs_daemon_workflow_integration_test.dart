import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_daemon_workflow.dart';
import 'package:ianvs_acp/rust/ianvs_workflow_native.dart';
import 'package:ianvs_acp/tasks/task_inbox_snapshot.dart';
import 'package:ianvs_acp/tasks/task_record.dart';

void main() {
  test(
    'daemon IPC survives disconnect and resumes a revisioned projection',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ianvs-daemon-dart-',
      );
      final databasePath = '${directory.path}/workflow.sqlite3';
      final socketPath = IanvsDaemonProcess.socketPathForDatabase(
        databasePath,
        temporaryDirectory: directory.path,
      );
      final binary = File('rust/target/debug/ianvs-acpd').absolute.path;
      expect(
        File(binary).existsSync(),
        isTrue,
        reason: 'build ianvs-acpd first',
      );

      final process = await Process.start(binary, <String>[
        '--database',
        databasePath,
        '--socket',
        socketPath,
        '--allow-shutdown',
      ]);
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final stdoutDone = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen(stdout.write)
          .asFuture<void>();
      final stderrDone = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen(stderr.write)
          .asFuture<void>();
      IanvsDaemonWorkflow? client;
      addTearDown(() async {
        await client?.dispose();
        process.kill();
        await process.exitCode.timeout(
          const Duration(seconds: 2),
          onTimeout: () => -1,
        );
        await Future.wait(<Future<void>>[stdoutDone, stderrDone]);
        final socket = File(socketPath);
        if (socket.existsSync()) socket.deleteSync();
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });

      await _waitForSocket(socketPath, process, stdout, stderr);
      client = IanvsDaemonWorkflow(socketPath: socketPath);
      final opened = await client.open(databasePath);
      expect(opened.revision, 0);
      final source = TaskInboxSnapshot.empty();
      await client.stageTaskInbox(
        source: source,
        sourceChecksum: 'sha256:dart-daemon-integration',
      );
      await client.materializeTaskInbox();
      final active = await client.activateTaskInbox();

      final now = DateTime.utc(2026, 7, 21, 12);
      final created = await client.applyTaskInbox(
        IanvsTaskInboxCommand.createTask(
          TaskRecord(
            id: 'daemon-task',
            title: 'Persist across reconnect',
            description: 'Projection is owned by the daemon.',
            workspacePath: directory.path,
            agentName: 'fixture',
            status: TaskStatus.inbox,
            priority: TaskPriority.normal,
            createdAt: now,
            updatedAt: now,
          ),
        ),
      );
      expect(created.workflow.revision, greaterThan(active.workflow.revision));
      await client.dispose();

      client = IanvsDaemonWorkflow(socketPath: socketPath);
      final reconnected = await client.currentTaskInboxProjection();
      expect(reconnected, isNotNull);
      expect(reconnected!.workflow.revision, created.workflow.revision);
      expect(reconnected.taskInbox.tasks.single.id, 'daemon-task');
      await client.shutdownForTesting();
      await process.exitCode.timeout(const Duration(seconds: 5));
      expect(stderr.toString(), isEmpty);
    },
  );
}

Future<void> _waitForSocket(
  String socketPath,
  Process process,
  StringBuffer stdout,
  StringBuffer stderr,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    if (File(socketPath).existsSync()) return;
    final exitCode = await process.exitCode.timeout(
      const Duration(milliseconds: 50),
      onTimeout: () => -1,
    );
    if (exitCode != -1) {
      fail(
        'ianvs-acpd exited with $exitCode\nstdout: $stdout\nstderr: $stderr',
      );
    }
  }
  fail('ianvs-acpd socket did not become ready: $socketPath');
}
