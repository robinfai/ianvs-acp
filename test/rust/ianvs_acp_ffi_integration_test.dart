import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_acp_native.dart';
import 'package:ianvs_acp/rust/ianvs_runtime_event.dart';

void main() {
  final root = Directory.current.path;
  final libraryPath = '$root/rust/target/debug/libianvs_acp_ffi.dylib';
  final agentPath = '$root/rust/target/debug/ianvs-acp-fixture-agent';
  final artifactsAvailable =
      File(libraryPath).existsSync() && File(agentPath).existsSync();

  test(
    'Dart FFI drives the Rust ACP subprocess and permission runtime',
    () async {
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final iterator = StreamIterator<IanvsRuntimeEvent>(runtime.events);
      addTearDown(() async {
        await iterator.cancel();
        await runtime.dispose();
      });

      final ready = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.statusChanged &&
            event.status == 'ready',
      );
      runtime.startAgent(
        agentName: 'fixture',
        command: agentPath,
        processCwd: root,
      );
      expect((await ready).data['capabilities'], isA<Map>());

      final created = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      runtime.createSession(
        requestId: 'create-from-dart',
        cwd: Directory.systemTemp.path,
      );
      final createdEvent = await created;
      expect(createdEvent.update?['sessionId'], 'fixture-session');
      final createdPayload = createdEvent.update?['payload'] as Map?;
      final modes = createdPayload?['modes'] as Map?;
      expect(modes?['currentModeId'], 'default');

      final permission = _nextWhere(
        iterator,
        (event) => event.type == IanvsRuntimeEventType.permissionRequest,
      );
      runtime.prompt(
        requestId: 'prompt-from-dart',
        sessionId: 'fixture-session',
        text: 'hello from Dart',
      );
      final permissionEvent = await permission;
      final request = permissionEvent.permissionRequest!;
      expect(request['toolCallId'], 'fixture-tool');
      runtime.respondPermission(
        requestId: request['requestId']! as String,
        decision: const <String, Object?>{
          'decision': 'selected',
          'optionId': 'allow-once',
        },
      );

      final message = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'agent_message_delta',
      );
      expect(message.update?['text'], 'permission:allow-once');
      final completed = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'prompt_completed',
      );
      expect(completed.update?['requestId'], 'prompt-from-dart');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI drives Rust-owned session catalog and lifecycle',
    () async {
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final iterator = StreamIterator<IanvsRuntimeEvent>(runtime.events);
      addTearDown(() async {
        await iterator.cancel();
        await runtime.dispose();
      });

      final ready = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.statusChanged &&
            event.status == 'ready',
      );
      runtime.startAgent(
        agentName: 'session-lifecycle-fixture',
        command: agentPath,
        processCwd: root,
      );
      final capabilities = (await ready).data['capabilities'] as Map?;
      expect(capabilities?['loadSession'], isTrue);
      expect(capabilities?['listSessions'], isTrue);
      expect(capabilities?['resumeSession'], isTrue);
      expect(capabilities?['closeSession'], isTrue);
      expect(capabilities?['deleteSession'], isTrue);
      expect(capabilities?['logout'], isTrue);
      expect((capabilities?['authMethods'] as List).single, isA<Map>());

      final catalog = _nextWhere(
        iterator,
        (event) => event.type == IanvsRuntimeEventType.sessionCatalog,
      );
      runtime.listSessions(requestId: 'list-from-dart');
      final catalogEvent = await catalog;
      expect(catalogEvent.requestId, 'list-from-dart');
      expect(catalogEvent.sessions.single['sessionId'], 'fixture-session');

      final authenticated = _nextWhere(
        iterator,
        (event) => event.type == IanvsRuntimeEventType.authenticationChanged,
      );
      runtime.authenticate(
        requestId: 'auth-from-dart',
        methodId: 'fixture-auth',
      );
      expect((await authenticated).data['authenticated'], isTrue);
      final loggedOut = _nextWhere(
        iterator,
        (event) => event.type == IanvsRuntimeEventType.authenticationChanged,
      );
      runtime.logout(requestId: 'logout-from-dart');
      expect((await loggedOut).data['authenticated'], isFalse);

      runtime.restoreSession(
        requestId: 'restore-from-dart',
        sessionId: 'fixture-session',
        cwd: Directory.systemTemp.path,
      );
      var history = false;
      var restored = false;
      Map<Object?, Object?>? restoredPayload;
      while (await iterator.moveNext()) {
        final event = iterator.current;
        if (event.type != IanvsRuntimeEventType.sessionUpdate) continue;
        final update = event.update!;
        if (update['kind'] == 'agent_message_delta') {
          expect(update['text'], 'loaded fixture history');
          history = true;
        } else if (update['kind'] == 'session_restored') {
          expect(update['requestId'], 'restore-from-dart');
          restoredPayload = update['payload'] as Map<Object?, Object?>?;
          restored = true;
        }
        if (history && restored) break;
      }
      expect(history && restored, isTrue);
      final restoredOptions = restoredPayload?['configOptions'] as List;
      expect((restoredOptions.first as Map)['currentValue'], 'fast');

      final configChanged = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'config_changed' &&
            event.update?['requestId'] == 'config-from-dart',
      );
      runtime.setConfigOption(
        requestId: 'config-from-dart',
        sessionId: 'fixture-session',
        configId: 'model',
        value: const <String, Object?>{'type': 'value_id', 'value': 'quality'},
      );
      final changedPayload = (await configChanged).update?['payload'] as Map;
      final changedOptions = changedPayload['configOptions'] as List;
      expect((changedOptions.first as Map)['currentValue'], 'quality');

      final closed = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_closed',
      );
      runtime.closeSession(
        requestId: 'close-from-dart',
        sessionId: 'fixture-session',
      );
      expect((await closed).update?['requestId'], 'close-from-dart');
      final deleted = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_deleted',
      );
      runtime.deleteSession(
        requestId: 'delete-from-dart',
        sessionId: 'fixture-session',
      );
      expect((await deleted).update?['requestId'], 'delete-from-dart');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI projects approved Rust terminal PTY lifecycle',
    () async {
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final iterator = StreamIterator<IanvsRuntimeEvent>(runtime.events);
      addTearDown(() async {
        await iterator.cancel();
        await runtime.dispose();
      });

      final ready = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.statusChanged &&
            event.status == 'ready',
      );
      runtime.startAgent(
        agentName: 'terminal-fixture',
        command: agentPath,
        processCwd: root,
        environment: const <String, String>{'IANVS_FIXTURE_USE_TERMINAL': '1'},
        enableTerminalProvider: true,
        maxTerminalHandles: 2,
        maxTerminalHandlesPerSession: 1,
        terminalDefaultOutputByteLimit: 64,
        terminalMaxOutputByteLimit: 128,
      );
      final capabilities = (await ready).data['capabilities'] as Map?;
      expect(capabilities?['terminal'], isTrue);

      final created = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      runtime.createSession(
        requestId: 'create-terminal-from-dart',
        cwd: Directory.systemTemp.path,
      );
      await created;

      final permission = _nextWhere(
        iterator,
        (event) => event.type == IanvsRuntimeEventType.permissionRequest,
      );
      runtime.prompt(
        requestId: 'prompt-terminal-from-dart',
        sessionId: 'fixture-session',
        text: 'use terminal',
      );
      final request = (await permission).permissionRequest!;
      expect(request['toolKind'], 'execute');
      expect(request['toolCallId'], startsWith('terminal:'));
      runtime.respondPermission(
        requestId: request['requestId']! as String,
        decision: const <String, Object?>{
          'decision': 'selected',
          'optionId': 'ianvs_terminal_allow_once',
        },
      );

      var attached = false;
      var output = false;
      var exited = false;
      var released = false;
      var message = false;
      var completed = false;
      while (await iterator.moveNext()) {
        final event = iterator.current;
        switch (event.type) {
          case IanvsRuntimeEventType.terminalAttached:
            expect(event.data['command'], <Object?>[
              '/bin/echo',
              'fixture-terminal',
            ]);
            attached = true;
          case IanvsRuntimeEventType.terminalOutput:
            output |= (event.data['data'] as String).contains(
              'fixture-terminal',
            );
          case IanvsRuntimeEventType.terminalExited:
            expect((event.data['exit'] as Map)['exitCode'], 0);
            exited = true;
          case IanvsRuntimeEventType.terminalReleased:
            released = true;
          case IanvsRuntimeEventType.sessionUpdate:
            final update = event.update!;
            if (update['kind'] == 'agent_message_delta') {
              expect(update['text'], 'terminal:fixture-terminal:0:false');
              message = true;
            } else if (update['kind'] == 'prompt_completed') {
              completed = true;
            }
          case IanvsRuntimeEventType.permissionRequest ||
              IanvsRuntimeEventType.sessionCatalog ||
              IanvsRuntimeEventType.authenticationChanged ||
              IanvsRuntimeEventType.statusChanged ||
              IanvsRuntimeEventType.stderrLog ||
              IanvsRuntimeEventType.runtimeError:
            break;
        }
        if (attached && output && exited && released && message && completed) {
          break;
        }
      }
      expect(
        attached && output && exited && released && message && completed,
        isTrue,
      );
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI sends workspace-scoped prompt attachment product DTOs',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'ianvs-ffi-attachment-',
      );
      final attachment = File('${workspace.path}/note.txt')
        ..writeAsStringSync('attachment from Dart');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final iterator = StreamIterator<IanvsRuntimeEvent>(runtime.events);
      addTearDown(() async {
        await iterator.cancel();
        await runtime.dispose();
      });

      final ready = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.statusChanged &&
            event.status == 'ready',
      );
      runtime.startAgent(
        agentName: 'attachment-fixture',
        command: agentPath,
        processCwd: root,
        environment: const <String, String>{
          'IANVS_FIXTURE_PROMPT_ATTACHMENTS': '1',
        },
      );
      final capabilities = (await ready).data['capabilities'] as Map;
      expect(capabilities['embeddedContext'], isTrue);

      final created = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      runtime.createSession(
        requestId: 'create-attachment-from-dart',
        cwd: workspace.path,
      );
      await created;
      runtime.prompt(
        requestId: 'prompt-attachment-from-dart',
        sessionId: 'fixture-session',
        text: 'inspect',
        attachments: <Map<String, Object?>>[
          <String, Object?>{
            'path': attachment.path,
            'name': 'note.txt',
            'mimeType': 'text/plain',
            'size': attachment.lengthSync(),
          },
        ],
      );
      final message = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'agent_message_delta',
      );
      expect(message.update?['text'], 'content:text,resource');
      await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'prompt_completed',
      );
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI approves Rust-owned filesystem reads and atomic writes',
    () async {
      final workspace = Directory.systemTemp.createTempSync(
        'ianvs-ffi-filesystem-',
      );
      File(
        '${workspace.path}/input.txt',
      ).writeAsStringSync('first\nsecond\nthird\n');
      final output = File('${workspace.path}/output.txt');
      addTearDown(() => workspace.deleteSync(recursive: true));
      final runtime = IanvsRustRuntime(
        native: FfiIanvsAcpNativeApi.open(libraryPath: libraryPath),
        pollInterval: const Duration(milliseconds: 1),
      );
      final iterator = StreamIterator<IanvsRuntimeEvent>(runtime.events);
      addTearDown(() async {
        await iterator.cancel();
        await runtime.dispose();
      });

      final ready = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.statusChanged &&
            event.status == 'ready',
      );
      runtime.startAgent(
        agentName: 'filesystem-fixture',
        command: agentPath,
        processCwd: root,
        environment: const <String, String>{
          'IANVS_FIXTURE_USE_FILESYSTEM': '1',
        },
        enableFilesystemReadTextFile: true,
        enableFilesystemWriteTextFile: true,
      );
      final capabilities = (await ready).data['capabilities'] as Map;
      expect(capabilities['filesystemReadTextFile'], isTrue);
      expect(capabilities['filesystemWriteTextFile'], isTrue);

      final created = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      runtime.createSession(
        requestId: 'create-filesystem-from-dart',
        cwd: workspace.path,
      );
      await created;
      runtime.prompt(
        requestId: 'prompt-filesystem-from-dart',
        sessionId: 'fixture-session',
        text: 'use filesystem',
      );
      final readPermission = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.permissionRequest &&
            event.permissionRequest?['toolKind'] == 'read',
      );
      runtime.respondPermission(
        requestId: readPermission.permissionRequest!['requestId']! as String,
        decision: const <String, Object?>{
          'decision': 'selected',
          'optionId': 'ianvs_filesystem_allow_once',
        },
      );
      final writePermission = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.permissionRequest &&
            event.permissionRequest?['toolKind'] == 'edit',
      );
      expect(output.existsSync(), isFalse);
      runtime.respondPermission(
        requestId: writePermission.permissionRequest!['requestId']! as String,
        decision: const <String, Object?>{
          'decision': 'selected',
          'optionId': 'ianvs_filesystem_allow_once',
        },
      );
      final message = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'agent_message_delta',
      );
      expect(message.update?['text'], 'filesystem:second');
      await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'prompt_completed',
      );
      expect(output.readAsStringSync(), 'copy:second\n');
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );
}

Future<IanvsRuntimeEvent> _nextWhere(
  StreamIterator<IanvsRuntimeEvent> iterator,
  bool Function(IanvsRuntimeEvent event) predicate,
) async {
  while (await iterator.moveNext()) {
    if (predicate(iterator.current)) return iterator.current;
  }
  throw StateError(
    'Rust runtime event stream closed before the expected event.',
  );
}
