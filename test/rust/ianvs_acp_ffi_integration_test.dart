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
    'Dart FFI rejects interior NUL without rejecting JSON unicode escapes',
    () {
      final native = FfiIanvsAcpNativeApi.open(libraryPath: libraryPath);
      final runtime = native.createRuntime();
      addTearDown(() => native.freeRuntime(runtime));

      expect(
        () => native.listSessions(runtime, requestId: 'before\u0000after'),
        throwsArgumentError,
      );
      expect(
        native.respondPermission(
          runtime,
          requestId: 'json-escape',
          decision: const <String, Object?>{
            'decision': 'selected',
            'optionId': 'contains\u0000unicode',
          },
        ),
        isTrue,
      );
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
  );

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
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'assistant_text',
      );
      expect(message.renderUpdate?['text'], 'permission:allow-once');
      final completed = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'turn_completed',
      );
      expect(
        (completed.renderUpdate?['metadata'] as Map?)?['requestId'],
        'prompt-from-dart',
      );
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI projects ACP available commands before session creation',
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
        agentName: 'commands-fixture',
        command: agentPath,
        processCwd: root,
        environment: const <String, String>{
          'IANVS_FIXTURE_COMMANDS_AFTER_NEW': '1',
        },
      );
      await ready;

      runtime.createSession(
        requestId: 'create-with-commands',
        cwd: Directory.systemTemp.path,
      );
      final commandsEvent = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'commands_changed',
      );
      final payload = commandsEvent.update?['payload'] as Map;
      final command = (payload['availableCommands'] as List).single as Map;
      expect(commandsEvent.update?['sessionId'], 'fixture-session');
      expect(command['name'], 'review');
      expect(command['description'], 'Review the current change.');
      expect((command['input'] as Map)['hint'], '[focus]');
      expect(command.containsKey('_meta'), isFalse);

      final created = await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      expect(created.update?['sessionId'], 'fixture-session');
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
        if (event.type == IanvsRuntimeEventType.renderSnapshotChunk) {
          final update = event.renderUpdates.singleWhere(
            (update) => update['kind'] == 'assistant_text',
          );
          expect(update['text'], 'loaded fixture history');
          history = true;
        } else if (event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_restored') {
          final update = event.update!;
          expect(update['requestId'], 'restore-from-dart');
          restoredPayload = update['payload'] as Map<Object?, Object?>?;
          restored = true;
        }
        if (history && restored) break;
      }
      expect(history && restored, isTrue);
      final restoredOptions = restoredPayload?['configOptions'] as List;
      final restoredById = <Object?, Map<Object?, Object?>>{
        for (final option in restoredOptions.cast<Map<Object?, Object?>>())
          option['id']: option,
      };
      expect(restoredById['model']?['currentValue'], 'fast');
      expect(restoredById['reasoning_effort']?['currentValue'], 'medium');
      expect(restoredById['fast_mode']?['currentValue'], 'off');

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
      var changedById = <Object?, Map<Object?, Object?>>{
        for (final option in changedOptions.cast<Map<Object?, Object?>>())
          option['id']: option,
      };
      expect(changedById['model']?['currentValue'], 'quality');
      expect(changedById['reasoning_effort']?['currentValue'], 'medium');
      expect(changedById['fast_mode']?['currentValue'], 'off');

      final reasoningChanged = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'config_changed' &&
            event.update?['requestId'] == 'reasoning-from-dart',
      );
      runtime.setConfigOption(
        requestId: 'reasoning-from-dart',
        sessionId: 'fixture-session',
        configId: 'reasoning_effort',
        value: const <String, Object?>{'type': 'value_id', 'value': 'high'},
      );
      changedById = <Object?, Map<Object?, Object?>>{
        for (final option
            in (((await reasoningChanged).update?['payload']
                        as Map)['configOptions']
                    as List)
                .cast<Map<Object?, Object?>>())
          option['id']: option,
      };
      expect(changedById['model']?['currentValue'], 'quality');
      expect(changedById['reasoning_effort']?['currentValue'], 'high');
      expect(changedById['fast_mode']?['currentValue'], 'off');

      final speedChanged = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'config_changed' &&
            event.update?['requestId'] == 'speed-from-dart',
      );
      runtime.setConfigOption(
        requestId: 'speed-from-dart',
        sessionId: 'fixture-session',
        configId: 'fast_mode',
        value: const <String, Object?>{'type': 'value_id', 'value': 'on'},
      );
      changedById = <Object?, Map<Object?, Object?>>{
        for (final option
            in (((await speedChanged).update?['payload']
                        as Map)['configOptions']
                    as List)
                .cast<Map<Object?, Object?>>())
          option['id']: option,
      };
      expect(changedById['model']?['currentValue'], 'quality');
      expect(changedById['reasoning_effort']?['currentValue'], 'high');
      expect(changedById['fast_mode']?['currentValue'], 'on');

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
          case IanvsRuntimeEventType.renderUpdate:
            final update = event.renderUpdate!;
            if (update['kind'] == 'assistant_text') {
              expect(update['text'], 'terminal:fixture-terminal:0:false');
              message = true;
            } else if (update['kind'] == 'turn_completed') {
              completed = true;
            }
          case IanvsRuntimeEventType.sessionUpdate ||
              IanvsRuntimeEventType.renderSnapshotChunk:
            break;
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
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'assistant_text',
      );
      expect(message.renderUpdate?['text'], 'content:text,resource');
      await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'turn_completed',
      );
    },
    skip: artifactsAvailable
        ? false
        : 'Run tool/verify_rust_runtime.sh to build native test artifacts.',
    timeout: const Timeout(Duration(seconds: 20)),
  );

  test(
    'Dart FFI observes fixture cancellation before accepting another prompt',
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
        agentName: 'cancellation-fixture',
        command: agentPath,
        processCwd: root,
        environment: const <String, String>{
          'IANVS_FIXTURE_PROMPT_ATTACHMENTS': '1',
          'IANVS_FIXTURE_RESPONSE_DELAY_MS': '60000',
        },
      );
      await ready;

      final created = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.sessionUpdate &&
            event.update?['kind'] == 'session_created',
      );
      runtime.createSession(
        requestId: 'create-cancellation-from-dart',
        cwd: Directory.systemTemp.path,
      );
      await created;

      runtime.prompt(
        requestId: 'prompt-cancellation-from-dart',
        sessionId: 'fixture-session',
        text: 'wait until cancelled',
      );
      await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'assistant_text',
      );

      final cancelled = _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'turn_completed' &&
            (event.renderUpdate?['metadata'] as Map?)?['stopReason'] ==
                'cancelled',
      );
      runtime.cancel(
        requestId: 'cancel-from-dart',
        sessionId: 'fixture-session',
      );
      final cancelledEvent = await cancelled;
      expect(
        (cancelledEvent.renderUpdate?['metadata'] as Map?)?['stopReason'],
        'cancelled',
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
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'assistant_text',
      );
      expect(message.renderUpdate?['text'], 'filesystem:second');
      await _nextWhere(
        iterator,
        (event) =>
            event.type == IanvsRuntimeEventType.renderUpdate &&
            event.renderUpdate?['kind'] == 'turn_completed',
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
