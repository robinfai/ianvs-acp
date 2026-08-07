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
        agentCommand: 'fixture-agent',
        runtime: runtime,
      );
      addTearDown(client.dispose);

      await client.connect();
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
  Map<String, Object?>? startedConfig;
  List<Map<String, Object?>>? promptAttachments;
  bool completeCreates = true;
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
  int get ffiVersion => 9;

  @override
  Object createRuntime() => handle;

  @override
  bool startAgent(Object runtime, Map<String, Object?> config) {
    startedConfig = Map<String, Object?>.from(config);
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
        'additionalDirectories': false,
        'filesystemReadTextFile':
            config['enableFilesystemReadTextFile'] == true,
        'filesystemWriteTextFile':
            config['enableFilesystemWriteTextFile'] == true,
        'terminal': terminal,
      },
    });
    return true;
  }

  @override
  bool createSession(
    Object runtime, {
    required String requestId,
    required String cwd,
    required List<String> additionalDirectories,
  }) {
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
  }) => true;

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
