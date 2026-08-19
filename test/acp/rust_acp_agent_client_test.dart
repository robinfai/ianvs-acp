import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_permission_request.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';
import 'package:ianvs_acp/acp/rust_acp_agent_client.dart';
import 'package:ianvs_acp/acp/session_title.dart';
import 'package:ianvs_acp/rust/ianvs_acp_native.dart';

void main() {
  test(
    'projects Rust session, prompt, and permission state into UI models',
    () async {
      final native = _ClientFakeNative();
      final runtime = IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      );
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentPersistenceId: 'stable-fixture',
        agentPersistenceAliases: const <String>['Original fixture'],
        agentCommand: 'fixture-agent',
        runtime: runtime,
      );
      addTearDown(client.dispose);

      await client.connect();
      expect(native.startedConfig?['agentName'], 'fixture');
      expect(native.startedConfig?['persistenceIdentity'], 'stable-fixture');
      expect(native.startedConfig?['persistenceAliases'], <String>[
        'Original fixture',
      ]);
      expect(client.capabilities?.protocolVersion, 1);
      expect(client.capabilities?.client.terminal, isFalse);

      final session = await client.createSession(cwd: '/tmp');
      expect(session.id, 'session-1');
      expect(session.cwd, '/tmp');
      final settings = await client.sessionSettings(session.id);
      expect(settings.modes.currentModeId, 'default');
      expect(settings.modes.availableModes.map((mode) => mode.id), <String>[
        'default',
        'plan',
      ]);

      final permissionFuture = client.permissionRequests.first;
      final eventsFuture = client
          .sendPrompt(
            sessionId: session.id,
            prompt: 'hello',
            attachments: const <PromptAttachment>[
              PromptAttachment(
                path: '/tmp/example.png',
                name: 'example.png',
                mimeType: 'image/png',
                size: 3,
                userApprovedOutsideWorkspace: true,
                forceResourceLink: true,
              ),
            ],
          )
          .toList();
      final permission = await permissionFuture;
      expect(permission.toolName, 'tool-1');
      expect(permission.choices.single.kind, 'allow_once');
      await client.respondToPermissionRequest(
        id: permission.id,
        decision: AcpPermissionDecision.allow,
      );
      final events = await eventsFuture;
      expect(events.map((event) => event.type), <AgentEventType>[
        AgentEventType.agentTextDelta,
        AgentEventType.agentTextDone,
      ]);
      expect(events.first.text, 'allowed');
      expect(events.last.metadata['stopReason'], 'endTurn');
      expect(native.permissionDecision, <String, Object?>{
        'decision': 'selected',
        'optionId': 'allow-once',
      });
      expect(native.promptAttachments, <Map<String, Object?>>[
        <String, Object?>{
          'path': '/tmp/example.png',
          'name': 'example.png',
          'mimeType': 'image/png',
          'size': 3,
          'userApprovedOutsideWorkspace': true,
          'forceResourceLink': true,
        },
      ]);
    },
  );

  test('caches and streams session available command updates', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    final session = await client.createSession(cwd: '/tmp');
    final updateFuture = client.availableCommandsUpdates.first;
    native.emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': session.id,
        'kind': 'commands_changed',
        'payload': <String, Object?>{
          'availableCommands': <Object?>[
            <String, Object?>{
              'name': 'review',
              'description': 'Review the current change.',
              'input': <String, Object?>{'hint': '[focus]'},
            },
          ],
        },
      },
    });

    final update = await updateFuture;
    expect(update.sessionId, session.id);
    expect(update.commands.single['name'], 'review');
    expect((update.commands.single['input'] as Map)['hint'], '[focus]');
    expect(
      (await client.sessionAvailableCommands(session.id))?.commands,
      update.commands,
    );

    final clearedFuture = client.availableCommandsUpdates.first;
    native.emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': session.id,
        'kind': 'commands_changed',
        'payload': <String, Object?>{'availableCommands': <Object?>[]},
      },
    });
    expect((await clearedFuture).commands, isEmpty);
    expect(
      (await client.sessionAvailableCommands(session.id))?.commands,
      isEmpty,
    );
  });

  test('explicit empty session roots never inherit client defaults', () async {
    final native = _ClientFakeNative()..supportsAdditionalDirectories = true;
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      additionalDirectories: const <String>['/configured-extra'],
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    await client.createSession(
      cwd: '/tmp',
      additionalDirectories: const <String>[],
    );

    expect(native.lastCreateAdditionalDirectories, isEmpty);
  });

  test('ignores command updates for unknown sessions', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    final updates = <Object>[];
    final subscription = client.availableCommandsUpdates.listen(updates.add);
    addTearDown(subscription.cancel);
    native.emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': 'unknown-session',
        'kind': 'commands_changed',
        'payload': <String, Object?>{
          'availableCommands': <Object?>[
            <String, Object?>{
              'name': 'bogus',
              'description': 'Must not be retained.',
            },
          ],
        },
      },
    });
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(updates, isEmpty);
    expect(await client.sessionAvailableCommands('unknown-session'), isNull);
  });

  test('recovery clears cached available commands', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    final session = await client.createSession(cwd: '/tmp');
    native.emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': session.id,
        'kind': 'commands_changed',
        'payload': <String, Object?>{
          'availableCommands': <Object?>[
            <String, Object?>{
              'name': 'review',
              'description': 'Review the current change.',
            },
          ],
        },
      },
    });
    await client.availableCommandsUpdates.first;
    final cleared = client.availableCommandsUpdates.first;

    native.emit('status_changed', <String, Object?>{
      'status': 'recovering',
      'detail': 'restarting fixture',
    });

    expect((await cleared).commands, isEmpty);
    expect(await client.sessionAvailableCommands(session.id), isNull);
  });

  test('logout clears cached available commands', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    final session = await client.createSession(cwd: '/tmp');
    final populated = client.availableCommandsUpdates.first;
    native.emitAvailableCommands(session.id, name: 'review');
    await populated;
    final cleared = client.availableCommandsUpdates.first;

    await client.logout();

    expect((await cleared).commands, isEmpty);
    expect(await client.sessionAvailableCommands(session.id), isNull);
  });

  test(
    'available command cache evicts the least recently used session',
    () async {
      final native = _ClientFakeNative();
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        runtime: IanvsRustRuntime(
          native: native,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(client.dispose);

      await client.connect();
      for (var index = 0; index <= 64; index += 1) {
        await client.restoreSession(
          sessionId: 'session-$index',
          cwd: '/tmp',
          replayHistory: false,
          onEvent: (_) {},
        );
      }
      for (var index = 0; index < 64; index += 1) {
        final update = client.availableCommandsUpdates.first;
        native.emitAvailableCommands('session-$index', name: 'command-$index');
        await update;
      }
      expect(await client.sessionAvailableCommands('session-0'), isNotNull);
      final newest = client.availableCommandsUpdates.first;
      native.emitAvailableCommands('session-64', name: 'command-64');
      await newest;

      expect(await client.sessionAvailableCommands('session-0'), isNotNull);
      expect(await client.sessionAvailableCommands('session-1'), isNull);
      expect(await client.sessionAvailableCommands('session-64'), isNotNull);
    },
  );

  test('oversized available command snapshots are not retained', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();
    final session = await client.createSession(cwd: '/tmp');
    final description = List<String>.filled(8 * 1024, 'd').join();
    final hint = List<String>.filled(8 * 1024, 'h').join();
    final update = client.availableCommandsUpdates.first;
    native.emitAvailableCommands(
      session.id,
      commands: List<Map<String, Object?>>.generate(
        1024,
        (index) => <String, Object?>{
          'name': 'command-$index',
          'description': description,
          'input': <String, Object?>{'hint': hint},
        },
      ),
    );

    expect((await update).commands, isEmpty);
    expect(await client.sessionAvailableCommands(session.id), isNull);
  });

  test('connection timeout does not start a second runtime', () async {
    final native = _ClientFakeNative()..emitReadyOnStart = false;
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      connectTimeout: const Duration(milliseconds: 5),
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await expectLater(client.connect(), throwsA(isA<TimeoutException>()));
    expect(native.startCalls, 1);

    final retry = client.connect();
    expect(native.startCalls, 1);
    native.emitReady();
    await retry;
    expect(native.startCalls, 1);
  });

  test('connection timeout includes a pending MCP server provider', () async {
    final native = _ClientFakeNative()..emitReadyOnStart = false;
    final providedServers = Completer<List<Map<String, Object?>>>();
    var providerCalls = 0;
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      connectTimeout: const Duration(milliseconds: 10),
      mcpServersProvider: () {
        providerCalls += 1;
        return providedServers.future;
      },
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await expectLater(client.connect(), throwsA(isA<TimeoutException>()));
    expect(providerCalls, 1);
    expect(native.startCalls, 0);

    await expectLater(client.connect(), throwsA(isA<TimeoutException>()));
    expect(providerCalls, 1);
    expect(native.startCalls, 0);

    providedServers.complete(const <Map<String, Object?>>[]);
    await _waitUntil(() => native.startCalls == 1);
    final connected = client.connect();
    native.emitReady();
    await connected;
    expect(native.startCalls, 1);
  });

  test(
    'dispose prevents a late MCP provider from starting the runtime',
    () async {
      final native = _ClientFakeNative()..emitReadyOnStart = false;
      final providedServers = Completer<List<Map<String, Object?>>>();
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        mcpServersProvider: () => providedServers.future,
        runtime: IanvsRustRuntime(
          native: native,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );

      final connecting = client.connect();
      final connectionFailure = expectLater(
        connecting,
        throwsA(isA<StateError>()),
      );
      await client.dispose();
      await connectionFailure;
      providedServers.complete(const <Map<String, Object?>>[]);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(native.startCalls, 0);
    },
  );

  test('late ready completion is not reused after a later recovery', () async {
    final native = _ClientFakeNative()..emitReadyOnStart = false;
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      connectTimeout: const Duration(milliseconds: 20),
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await expectLater(client.connect(), throwsA(isA<TimeoutException>()));
    native.emitReady();
    await _waitUntil(() => native.events.isEmpty);
    native.emit('status_changed', <String, Object?>{
      'status': 'recovering',
      'detail': 'restarting fixture',
    });
    await _waitUntil(() => native.events.isEmpty);

    var reconnectCompleted = false;
    final reconnect = client.connect().whenComplete(
      () => reconnectCompleted = true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(reconnectCompleted, isFalse);
    expect(native.startCalls, 2);

    native.emitReady();
    await reconnect;
  });

  test(
    'dispose tolerates a completed connection before waiter cleanup',
    () async {
      final native = _ClientFakeNative()..emitReadyOnStart = false;
      final runtime = IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      );
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        runtime: runtime,
      );
      final disposed = Completer<void>();
      final observer = runtime.events.listen((event) {
        if (event.status != 'ready' || disposed.isCompleted) return;
        client.dispose().then(
          (_) => disposed.complete(),
          onError: (Object error, StackTrace stackTrace) =>
              disposed.completeError(error, stackTrace),
        );
      });
      addTearDown(observer.cancel);

      final connecting = client.connect();
      native.emitReady();

      await disposed.future;
      await connecting;
    },
  );

  test('rejects a non-positive connection timeout', () {
    expect(
      () => RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        connectTimeout: Duration.zero,
      ),
      throwsArgumentError,
    );
  });

  test(
    'does not open a parallel protocol connection for unsupported methods',
    () async {
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        runtime: IanvsRustRuntime(
          native: _ClientFakeNative(),
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(client.dispose);
      await client.connect();
      await expectLater(
        client.forkSession(sessionId: 'session-1', cwd: '/tmp'),
        throwsUnsupportedError,
      );
    },
  );

  test('cancels only the requested session when prompts overlap', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    final firstSession = await client.createSession(cwd: '/tmp/first');
    await client.restoreSession(
      sessionId: 'session-2',
      cwd: '/tmp/second',
      onEvent: (_) {},
    );

    final firstPrompt = client
        .sendPrompt(sessionId: firstSession.id, prompt: 'first')
        .listen(null);
    final secondPrompt = client
        .sendPrompt(sessionId: 'session-2', prompt: 'second')
        .listen(null);
    addTearDown(firstPrompt.cancel);
    addTearDown(secondPrompt.cancel);

    await client.cancelSession(sessionId: 'session-2');
    expect(native.cancelledSessionIds, ['session-2']);
    await expectLater(client.cancel(), throwsStateError);
  });

  test('does not project process stderr into concurrent sessions', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    final firstSession = await client.createSession(cwd: '/tmp/first');
    await client.restoreSession(
      sessionId: 'session-2',
      cwd: '/tmp/second',
      onEvent: (_) {},
    );

    final firstEvents = <AgentEvent>[];
    final secondEvents = <AgentEvent>[];
    final firstPrompt = client
        .sendPrompt(sessionId: firstSession.id, prompt: 'first')
        .listen(firstEvents.add);
    addTearDown(firstPrompt.cancel);
    native.emit('stderr_log', <String, Object?>{'line': 'single prompt'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(firstEvents.map((event) => event.text), contains('single prompt'));

    final secondPrompt = client
        .sendPrompt(sessionId: 'session-2', prompt: 'second')
        .listen(secondEvents.add);
    addTearDown(secondPrompt.cancel);
    native.emit('stderr_log', <String, Object?>{'line': 'ambiguous prompt'});
    await Future<void>.delayed(const Duration(milliseconds: 5));

    expect(
      firstEvents.map((event) => event.text),
      isNot(contains('ambiguous prompt')),
    );
    expect(
      secondEvents.map((event) => event.text),
      isNot(contains('ambiguous prompt')),
    );
  });

  test('passes a GUI-safe PATH to absolute script-based agents', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: '/opt/homebrew/bin/npx',
      inheritedProcessEnvironment: const <String, String>{
        'HOME': '/Users/example',
        'PATH': '/usr/bin:/bin',
      },
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);

    await client.connect();

    final environment =
        native.startedConfig?['environment'] as Map<String, String>;
    expect(environment['PATH']?.split(':').first, '/opt/homebrew/bin');
  });

  test('preserves replayed user content block payloads', () async {
    final native = _ClientFakeNative()
      ..restoredUserPayload = <String, Object?>{
        'type': 'resource_link',
        'uri': 'file:///tmp/reference.png',
        'name': 'reference.png',
        'mimeType': 'image/png',
      };
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();

    final history = <AgentEvent>[];
    await client.restoreSession(
      sessionId: 'restored-session',
      cwd: '/tmp',
      onEvent: history.add,
    );

    expect(history.first.type, AgentEventType.userMessage);
    expect(history.first.metadata['contentBlocks'], <Object?>[
      <String, Object?>{
        'type': 'resource_link',
        'uri': 'file:///tmp/reference.png',
        'name': 'reference.png',
        'mimeType': 'image/png',
      },
    ]);
  });

  test('projects Rust session catalog, restore, close, and delete', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();

    expect(client.capabilities?.loadSession, isTrue);
    expect(client.capabilities?.session.list, isTrue);
    expect(client.capabilities?.session.resume, isTrue);
    expect(client.capabilities?.session.close, isTrue);
    expect(client.capabilities?.session.delete, isTrue);
    expect(client.capabilities?.auth.logout, isTrue);
    expect(client.capabilities?.authMethods.single['id'], 'fixture-auth');
    final catalog = await client.listSessions();
    expect(catalog.single.cwd, '/tmp');
    expect(catalog.single.sessions.single.title, 'Fixture session');

    final streamedHistory = <AgentEvent>[];
    final restore = await client.restoreSession(
      sessionId: 'restored-session',
      cwd: '/tmp',
      onEvent: streamedHistory.add,
    );
    expect(streamedHistory.single.text, 'restored history');
    expect(restore.eventCount, 1);
    expect(restore.replayedHistory, isTrue);
    final resumedEvents = <AgentEvent>[];
    final resumed = await client.restoreSession(
      sessionId: 'resumed-session',
      cwd: '/tmp',
      replayHistory: false,
      onEvent: resumedEvents.add,
    );
    expect(native.lastRestoreReplayHistory, isFalse);
    expect(resumedEvents, isEmpty);
    expect(resumed.eventCount, 0);
    expect(resumed.replayedHistory, isFalse);
    final initialSettings = await client.sessionSettings('restored-session');
    expect(initialSettings.configOptions.single.currentValue, 'fast');
    final updatedOptions = await client.setConfigOption(
      sessionId: 'restored-session',
      configId: 'model',
      value: 'quality',
    );
    expect(updatedOptions.single.currentValue, 'quality');
    expect(
      (await client.sessionSettings(
        'restored-session',
      )).configOptions.single.currentValue,
      'quality',
    );
    await client.closeSession(sessionId: 'restored-session');
    await client.deleteSession(sessionId: 'restored-session');
    await client.authenticate(methodId: 'fixture-auth');
    await client.logout();
  });

  test('bounds oversized titles from Rust session catalogs', () async {
    final native = _ClientFakeNative()
      ..sessionTitle = List<String>.filled(300, '会').join();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();

    final title = (await client.listSessions()).single.sessions.single.title;

    expect(title.runes, hasLength(maxSessionTitleCharacters));
    expect(title, endsWith('…'));
  });

  test('advertises and projects Rust terminal provider lifecycle', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      enableTerminalProvider: true,
      maxTerminalHandles: 3,
      maxTerminalHandlesPerSession: 1,
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    expect(native.startedConfig?['enableTerminalProvider'], isTrue);
    expect(native.startedConfig?['maxTerminalHandles'], 3);
    expect(native.startedConfig?['maxTerminalHandlesPerSession'], 1);
    expect(client.capabilities?.client.terminal, isTrue);
    expect(client.capabilities?.client.hasTerminalProvider, isTrue);

    final session = await client.createSession(cwd: '/tmp');
    final permissionFuture = client.permissionRequests.first;
    final eventsFuture = client
        .sendPrompt(sessionId: session.id, prompt: 'terminal')
        .toList();
    final permission = await permissionFuture;
    native.emit('terminal_attached', <String, Object?>{
      'sessionId': session.id,
      'terminalId': 'terminal-1',
      'command': <String>['/bin/echo', 'hello'],
      'cwd': '/tmp',
    });
    native.emit('terminal_output', <String, Object?>{
      'sessionId': session.id,
      'terminalId': 'terminal-1',
      'data': 'hello\n',
    });
    native.emit('terminal_exited', <String, Object?>{
      'sessionId': session.id,
      'terminalId': 'terminal-1',
      'exit': <String, Object?>{'exitCode': 0, 'signal': null},
    });
    native.emit('terminal_released', <String, Object?>{
      'sessionId': session.id,
      'terminalId': 'terminal-1',
    });
    await client.respondToPermissionRequest(
      id: permission.id,
      decision: AcpPermissionDecision.allow,
    );
    final events = await eventsFuture;
    expect(
      events
          .where((event) => event.type == AgentEventType.status)
          .map((event) => event.metadata['kind']),
      <Object?>[
        'terminal',
        'terminal_output',
        'terminal_exited',
        'terminal_released',
      ],
    );
    expect(
      events
          .firstWhere((event) => event.metadata['kind'] == 'terminal_exited')
          .metadata['exitCode'],
      0,
    );
  });

  test('advertises only configured Rust filesystem providers', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: false,
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    expect(native.startedConfig?['enableFilesystemReadTextFile'], isTrue);
    expect(native.startedConfig?['enableFilesystemWriteTextFile'], isFalse);
    expect(client.capabilities?.client.fsReadTextFile, isTrue);
    expect(client.capabilities?.client.fsWriteTextFile, isFalse);
    expect(client.capabilities?.client.hasFsProvider, isTrue);
  });

  test('forwards the durable Rust session store path', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      sessionStorePath: '/tmp/acp-sessions.sqlite3',
      sessionStoreMaxBytes: 512 * 1024 * 1024,
      sessionStoreRetentionDays: 45,
      mcpServers: const <Map<String, Object?>>[
        <String, Object?>{
          'type': 'http',
          'name': 'remote-mcp',
          'url': 'https://example.test/mcp',
          'headers': <String, String>{},
        },
      ],
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    expect(
      native.startedConfig?['sessionStorePath'],
      '/tmp/acp-sessions.sqlite3',
    );
    expect(native.startedConfig?['sessionStoreMaxBytes'], 512 * 1024 * 1024);
    expect(native.startedConfig?['sessionStoreRetentionDays'], 45);
    expect((native.startedConfig?['mcpServers'] as List).length, 1);
    expect(client.capabilities?.mcp.http, isTrue);
  });

  test(
    'fails in-flight work but retains sessions across Rust recovery',
    () async {
      final native = _ClientFakeNative();
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        runtime: IanvsRustRuntime(
          native: native,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(client.dispose);
      await client.connect();
      final session = await client.createSession(cwd: '/tmp');
      final promptFailure = expectLater(
        client.sendPrompt(sessionId: session.id, prompt: 'hello'),
        emitsError(isA<StateError>()),
      );

      native.emit('status_changed', <String, Object?>{
        'status': 'recovering',
        'detail': 'restoring durable sessions',
      });
      await promptFailure;
      native.emit('session_update', <String, Object?>{
        'update': <String, Object?>{
          'sessionId': session.id,
          'kind': 'session_restored',
          'payload': <String, Object?>{
            'cwd': '/tmp',
            'additionalDirectories': <String>[],
            'recoveredAfterRestart': true,
            'configOptions': _fakeConfigOptions('fast'),
          },
        },
      });
      native.emit('status_changed', <String, Object?>{
        'status': 'ready',
        'capabilities': <String, Object?>{
          'protocolVersion': 1,
          'loadSession': true,
          'resumeSession': true,
        },
      });
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(
        (await client.sessionSettings(session.id)).configOptions,
        isNotEmpty,
      );
      final nextPrompt = client
          .sendPrompt(sessionId: session.id, prompt: 'after recovery')
          .listen(null);
      await nextPrompt.cancel();
    },
  );

  test(
    'projects Rust permission invalidation with strict lifecycle match',
    () async {
      final native = _ClientFakeNative();
      final client = RustAcpAgentClient(
        agentName: 'fixture',
        agentCommand: 'fixture-agent',
        runtime: IanvsRustRuntime(
          native: native,
          pollInterval: const Duration(milliseconds: 1),
        ),
      );
      addTearDown(client.dispose);
      await client.connect();
      final session = await client.createSession(cwd: '/tmp');
      final permissionFuture = client.permissionRequests.first;
      final promptSubscription = client
          .sendPrompt(sessionId: session.id, prompt: 'hello')
          .listen(null);
      addTearDown(promptSubscription.cancel);
      final permission = await permissionFuture;
      final invalidationFuture = client.permissionInvalidations.first;
      native.invalidatePermission(
        requestId: permission.id,
        sessionId: session.id,
        reason: 'timed_out',
      );
      final invalidation = await invalidationFuture;
      expect(invalidation.requestId, permission.id);
      expect(invalidation.lifecycleId, permission.lifecycleId);
      expect(invalidation.reason, AcpPermissionInvalidationReason.timedOut);
      await expectLater(
        client.respondToPermissionRequest(
          id: permission.id,
          decision: AcpPermissionDecision.allow,
        ),
        throwsStateError,
      );
    },
  );

  test('fails every pending operation when the Rust runtime fails', () async {
    final native = _ClientFakeNative();
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();
    final session = await client.createSession(cwd: '/tmp');

    final promptFailure = expectLater(
      client.sendPrompt(sessionId: session.id, prompt: 'hello'),
      emitsError(isA<StateError>()),
    );
    final modeFailure = expectLater(
      client.setSessionMode(sessionId: session.id, modeId: 'plan'),
      throwsStateError,
    );
    native.emit('status_changed', <String, Object?>{
      'status': 'failed',
      'detail': 'agent process exited',
    });

    await promptFailure;
    await modeFailure;
    expect(
      () => client.sendPrompt(sessionId: session.id, prompt: 'again'),
      throwsStateError,
    );
  });

  test('fails a pending create when the Rust runtime fails', () async {
    final native = _ClientFakeNative()..completeCreates = false;
    final client = RustAcpAgentClient(
      agentName: 'fixture',
      agentCommand: 'fixture-agent',
      runtime: IanvsRustRuntime(
        native: native,
        pollInterval: const Duration(milliseconds: 1),
      ),
    );
    addTearDown(client.dispose);
    await client.connect();

    final createFailure = expectLater(
      client.createSession(cwd: '/tmp'),
      throwsStateError,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    native.emit('status_changed', <String, Object?>{
      'status': 'failed',
      'detail': 'agent process exited',
    });

    await createFailure;
  });
}

final class _ClientFakeNative implements IanvsAcpNativeApi {
  final Object handle = Object();
  final List<String> events = <String>[];
  var _sequence = 1;
  Map<String, Object?>? permissionDecision;
  final List<String> cancelledSessionIds = <String>[];
  Map<String, Object?>? startedConfig;
  List<Map<String, Object?>>? promptAttachments;
  List<String>? lastCreateAdditionalDirectories;
  bool completeCreates = true;
  bool emitReadyOnStart = true;
  bool supportsAdditionalDirectories = false;
  int startCalls = 0;
  String sessionTitle = 'Fixture session';
  Map<String, Object?>? restoredUserPayload;
  bool? lastRestoreReplayHistory;

  void invalidatePermission({
    required String requestId,
    required String sessionId,
    required String reason,
  }) {
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'permission_invalidated',
        'requestId': requestId,
        'payload': <String, Object?>{'reason': reason},
      },
    });
  }

  void emit(String type, Map<String, Object?> data) {
    events.add(
      jsonEncode(<String, Object?>{
        'schemaVersion': 4,
        'sequence': _sequence++,
        'type': type,
        ...data,
      }),
    );
  }

  @override
  int get ffiVersion => 10;

  @override
  Object createRuntime() => handle;

  @override
  bool startAgent(Object runtime, Map<String, Object?> config) {
    startCalls += 1;
    startedConfig = Map<String, Object?>.from(config);
    if (!emitReadyOnStart) return true;
    emitReady();
    return true;
  }

  void emitReady() {
    final config = startedConfig ?? const <String, Object?>{};
    final terminal = config['enableTerminalProvider'] == true;
    emit('status_changed', <String, Object?>{
      'status': 'ready',
      'capabilities': <String, Object?>{
        'protocolVersion': 1,
        'loadSession': true,
        'listSessions': true,
        'resumeSession': true,
        'closeSession': true,
        'deleteSession': true,
        'logout': true,
        'authMethods': <Object?>[
          <String, Object?>{
            'id': 'fixture-auth',
            'name': 'Fixture authentication',
          },
        ],
        'promptImage': true,
        'promptAudio': true,
        'embeddedContext': true,
        'mcpCapabilities': false,
        'mcpHttp': true,
        'mcpSse': false,
        'additionalDirectories': supportsAdditionalDirectories,
        'filesystemReadTextFile':
            config['enableFilesystemReadTextFile'] == true,
        'filesystemWriteTextFile':
            config['enableFilesystemWriteTextFile'] == true,
        'terminal': terminal,
      },
    });
  }

  void emitAvailableCommands(
    String sessionId, {
    String name = 'review',
    List<Map<String, Object?>>? commands,
  }) {
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'commands_changed',
        'payload': <String, Object?>{
          'availableCommands':
              commands ??
              <Object?>[
                <String, Object?>{
                  'name': name,
                  'description': 'Description for $name.',
                },
              ],
        },
      },
    });
  }

  @override
  bool createSession(
    Object runtime, {
    required String requestId,
    required String cwd,
    required List<String> additionalDirectories,
  }) {
    lastCreateAdditionalDirectories = List<String>.of(additionalDirectories);
    if (!completeCreates) return true;
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': 'session-1',
        'kind': 'session_created',
        'requestId': requestId,
        'payload': <String, Object?>{
          'cwd': cwd,
          'modes': <String, Object?>{
            'currentModeId': 'default',
            'availableModes': <Object?>[
              <String, Object?>{'id': 'default', 'label': 'Default'},
              <String, Object?>{'id': 'plan', 'label': 'Plan'},
            ],
          },
        },
      },
    });
    return true;
  }

  @override
  bool restoreSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String cwd,
    required List<String> additionalDirectories,
    bool replayHistory = true,
  }) {
    lastRestoreReplayHistory = replayHistory;
    if (replayHistory) {
      emit('render_snapshot_chunk', <String, Object?>{
        'requestId': requestId,
        'sessionId': sessionId,
        'chunkIndex': 0,
        'isLast': true,
        'updates': <Object?>[
          if (restoredUserPayload case final payload?)
            <String, Object?>{
              'sessionId': sessionId,
              'kind': 'user_message',
              'metadata': <String, Object?>{
                'contentBlocks': <Object?>[payload],
              },
            },
          <String, Object?>{
            'sessionId': sessionId,
            'kind': 'assistant_text',
            'text': 'restored history',
          },
        ],
      });
    }
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'session_restored',
        'requestId': requestId,
        'payload': <String, Object?>{
          'cwd': cwd,
          'replayedHistory': replayHistory,
          'configOptions': _fakeConfigOptions('fast'),
        },
      },
    });
    return true;
  }

  @override
  bool listSessions(Object runtime, {required String requestId}) {
    emit('session_catalog', <String, Object?>{
      'requestId': requestId,
      'sessions': <Object?>[
        <String, Object?>{
          'sessionId': 'restored-session',
          'cwd': '/tmp',
          'title': sessionTitle,
          'updatedAt': '2026-07-17T10:00:00Z',
        },
      ],
    });
    return true;
  }

  @override
  bool closeSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'session_closed',
        'requestId': requestId,
      },
    });
    return true;
  }

  @override
  bool deleteSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'session_deleted',
        'requestId': requestId,
      },
    });
    return true;
  }

  @override
  bool authenticate(
    Object runtime, {
    required String requestId,
    required String methodId,
  }) {
    emit('authentication_changed', <String, Object?>{
      'requestId': requestId,
      'authenticated': true,
      'methodId': methodId,
    });
    return true;
  }

  @override
  bool logout(Object runtime, {required String requestId}) {
    emit('authentication_changed', <String, Object?>{
      'requestId': requestId,
      'authenticated': false,
    });
    return true;
  }

  @override
  bool prompt(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String text,
    List<Map<String, Object?>> attachments = const <Map<String, Object?>>[],
  }) {
    promptAttachments = attachments
        .map((attachment) => Map<String, Object?>.from(attachment))
        .toList(growable: false);
    emit('permission_request', <String, Object?>{
      'request': <String, Object?>{
        'requestId': 'permission-1',
        'sessionId': sessionId,
        'toolCallId': 'tool-1',
        'title': 'Write file',
        'toolKind': 'edit',
        'options': <Object?>[
          <String, Object?>{
            'optionId': 'allow-once',
            'label': 'Allow once',
            'kind': 'allow_once',
          },
        ],
      },
    });
    return true;
  }

  @override
  bool respondPermission(
    Object runtime, {
    required String requestId,
    required Map<String, Object?> decision,
  }) {
    permissionDecision = decision;
    emit('render_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': 'session-1',
        'kind': 'assistant_text',
        'text': 'allowed',
      },
    });
    emit('render_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': 'session-1',
        'kind': 'turn_completed',
        'metadata': <String, Object?>{
          'stopReason': 'end_turn',
          'requestId': 'prompt-3',
        },
      },
    });
    return true;
  }

  @override
  bool cancel(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    cancelledSessionIds.add(sessionId);
    return true;
  }

  @override
  bool setMode(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String modeId,
  }) => true;

  @override
  bool setConfigOption(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String configId,
    required Map<String, Object?> value,
  }) {
    final current = value['value'];
    if (configId != 'model' || current is! String) return false;
    emit('session_update', <String, Object?>{
      'update': <String, Object?>{
        'sessionId': sessionId,
        'kind': 'config_changed',
        'requestId': requestId,
        'payload': <String, Object?>{
          'configOptions': _fakeConfigOptions(current),
        },
      },
    });
    return true;
  }

  @override
  String? pollEvents(
    Object runtime, {
    required int maxEvents,
    required int maxBytes,
    int timeoutMs = 0,
  }) {
    if (events.isEmpty) return null;
    final batch = <Object?>[];
    var bytes = 2;
    while (batch.length < maxEvents && events.isNotEmpty) {
      final next = events.first;
      if (batch.isNotEmpty && bytes + 1 + next.length > maxBytes) break;
      events.removeAt(0);
      batch.add(jsonDecode(next));
      bytes += (batch.length == 1 ? 0 : 1) + next.length;
    }
    return jsonEncode(<String, Object?>{
      'events': batch,
      'hasMore': events.isNotEmpty,
    });
  }

  @override
  String? lastError(Object runtime) => null;

  @override
  bool dispose(Object runtime) => true;

  @override
  void freeRuntime(Object runtime) {}
}

List<Map<String, Object?>> _fakeConfigOptions(String current) =>
    <Map<String, Object?>>[
      <String, Object?>{
        'id': 'model',
        'name': 'Model',
        'optionType': 'select',
        'currentValue': current,
        'category': 'model',
        'options': <Object?>[
          <String, Object?>{'value': 'fast', 'name': 'Fast'},
          <String, Object?>{'value': 'quality', 'name': 'Quality'},
        ],
      },
    ];

Future<void> _waitUntil(bool Function() condition) async {
  for (var attempt = 0; attempt < 100; attempt += 1) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Condition was not satisfied before the test deadline.');
}
