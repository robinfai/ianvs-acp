import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/rust/ianvs_acp_native.dart';
import 'package:ianvs_acp/rust/ianvs_runtime_event.dart';

void main() {
  test('uses frame-friendly default FFI drain budgets', () async {
    final runtime = IanvsRustRuntime(
      native: _FakeNativeApi(),
      pollInterval: const Duration(hours: 1),
    );
    addTearDown(runtime.dispose);

    expect(runtime.maxEventsPerPoll, 4);
    expect(runtime.maxBytesPerPoll, 128 * 1024);
    expect(runtime.backlogDrainDelay, const Duration(milliseconds: 4));
  });

  test('rejects FFI batch limits outside the native ABI bounds', () {
    expect(
      () => IanvsRustRuntime(
        native: _FakeNativeApi(),
        maxEventsPerPoll: IanvsRustRuntime.maxNativeEventsPerPoll + 1,
      ),
      throwsArgumentError,
    );
    expect(
      () => IanvsRustRuntime(
        native: _FakeNativeApi(),
        maxBytesPerPoll: IanvsRustRuntime.maxNativeBytesPerPoll + 1,
      ),
      throwsArgumentError,
    );
  });

  test('projects versioned Rust events in strict sequence', () async {
    final native = _FakeNativeApi()
      ..events.addAll(<String>[
        jsonEncode(<String, Object?>{
          'schemaVersion': 4,
          'sequence': 1,
          'type': 'status_changed',
          'status': 'ready',
        }),
        jsonEncode(<String, Object?>{
          'schemaVersion': 4,
          'sequence': 2,
          'type': 'render_update',
          'update': <String, Object?>{
            'sessionId': 'session-1',
            'kind': 'assistant_text',
            'text': 'hello',
          },
        }),
      ]);
    final runtime = IanvsRustRuntime(
      native: native,
      pollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(runtime.dispose);
    final events = await runtime.events.take(2).toList();
    expect(events.map((event) => event.sequence), <int>[1, 2]);
    expect(events.first.type, IanvsRuntimeEventType.statusChanged);
    expect(events.last.update?['text'], 'hello');
  });

  test('decodes an oversized FFI event off the event loop', () async {
    var eventLoopAdvanced = false;
    final native = _FakeNativeApi()
      ..onPoll = () {
        Timer.run(() => eventLoopAdvanced = true);
      }
      ..events.add(
        jsonEncode(<String, Object?>{
          'schemaVersion': 4,
          'sequence': 1,
          'type': 'status_changed',
          'status': 'ready',
          'padding': 'x' * (300 * 1024),
        }),
      );
    final runtime = IanvsRustRuntime(
      native: native,
      pollInterval: const Duration(milliseconds: 1),
    );
    addTearDown(runtime.dispose);

    await runtime.events.first;

    expect(eventLoopAdvanced, isTrue);
  });

  test('drains a native backlog in cooperative slices', () async {
    final native = _FakeNativeApi();
    for (var sequence = 1; sequence <= 9; sequence += 1) {
      native.events.add(
        jsonEncode(<String, Object?>{
          'schemaVersion': 4,
          'sequence': sequence,
          'type': 'status_changed',
          'status': 'ready',
        }),
      );
    }
    final runtime = IanvsRustRuntime(
      native: native,
      pollInterval: const Duration(milliseconds: 100),
      maxEventsPerPoll: 2,
      backlogDrainDelay: const Duration(milliseconds: 4),
    );
    addTearDown(runtime.dispose);

    final stopwatch = Stopwatch()..start();
    final events = await runtime.events.take(9).toList();
    stopwatch.stop();

    expect(
      events.map((event) => event.sequence),
      orderedEquals(<int>[1, 2, 3, 4, 5, 6, 7, 8, 9]),
    );
    expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 350)));
  });

  test('sends stable product commands instead of ACP JSON-RPC', () async {
    final native = _FakeNativeApi();
    final runtime = IanvsRustRuntime(
      native: native,
      pollInterval: const Duration(hours: 1),
    );
    runtime.startAgent(
      agentName: 'Codex',
      persistenceIdentity: 'stable-codex',
      persistenceAliases: const <String>['Codex', 'Original Codex'],
      command: 'codex-acp',
      args: const <String>['--flag'],
      environment: const <String, String>{'TOKEN': 'secret'},
      processCwd: '/tmp',
      sessionStorePath: '/tmp/acp-sessions.sqlite3',
      sessionStoreMaxBytes: 512 * 1024 * 1024,
      sessionStoreRetentionDays: 45,
      mcpServers: const <Map<String, Object?>>[
        <String, Object?>{
          'type': 'stdio',
          'name': 'local-mcp',
          'command': 'mcp-command',
          'args': <String>[],
          'environment': <String, String>{},
        },
      ],
      permissionTimeout: const Duration(seconds: 45),
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      enableTerminalProvider: true,
      maxTerminalHandles: 8,
      maxTerminalHandlesPerSession: 2,
      terminalDefaultOutputByteLimit: 1024,
      terminalMaxOutputByteLimit: 4096,
    );
    runtime.createSession(
      requestId: 'request-1',
      cwd: '/tmp',
      additionalDirectories: const <String>['/private/tmp'],
    );
    runtime.prompt(
      requestId: 'request-2',
      sessionId: 'session-1',
      text: 'hello',
    );
    expect(native.startedConfig?['command'], 'codex-acp');
    expect(native.startedConfig?['persistenceIdentity'], 'stable-codex');
    expect(native.startedConfig?['persistenceAliases'], <String>[
      'Codex',
      'Original Codex',
    ]);
    expect(native.startedConfig?['permissionTimeoutMs'], 45000);
    expect(
      native.startedConfig?['sessionStorePath'],
      '/tmp/acp-sessions.sqlite3',
    );
    expect(native.startedConfig?['sessionStoreMaxBytes'], 512 * 1024 * 1024);
    expect(native.startedConfig?['sessionStoreRetentionDays'], 45);
    expect((native.startedConfig?['mcpServers'] as List).length, 1);
    expect(native.startedConfig?['enableFilesystemReadTextFile'], isTrue);
    expect(native.startedConfig?['enableFilesystemWriteTextFile'], isTrue);
    expect(native.startedConfig?['enableTerminalProvider'], isTrue);
    expect(native.startedConfig?['maxTerminalHandles'], 8);
    expect(native.startedConfig?['maxTerminalHandlesPerSession'], 2);
    expect(native.startedConfig?['terminalDefaultOutputByteLimit'], 1024);
    expect(native.startedConfig?['terminalMaxOutputByteLimit'], 4096);
    expect(native.startedConfig, isNot(contains('jsonrpc')));
    expect(native.startedConfig, isNot(contains('method')));
    expect(native.lastPrompt, <String, String>{
      'requestId': 'request-2',
      'sessionId': 'session-1',
      'text': 'hello',
    });
    await runtime.dispose();
    expect(native.disposed, isTrue);
    expect(native.freed, isTrue);
  });

  test('rejects unsupported event schema at projection boundary', () {
    expect(
      () => IanvsRuntimeEvent.fromJson(<String, Object?>{
        'schemaVersion': 1,
        'sequence': 1,
        'type': 'status_changed',
      }),
      throwsFormatException,
    );
  });

  test('decodes the complete Rust terminal lifecycle event schema', () {
    final types = <String, IanvsRuntimeEventType>{
      'terminal_attached': IanvsRuntimeEventType.terminalAttached,
      'terminal_output': IanvsRuntimeEventType.terminalOutput,
      'terminal_exited': IanvsRuntimeEventType.terminalExited,
      'terminal_released': IanvsRuntimeEventType.terminalReleased,
    };
    var sequence = 1;
    for (final entry in types.entries) {
      final event = IanvsRuntimeEvent.fromJson(<String, Object?>{
        'schemaVersion': 4,
        'sequence': sequence++,
        'type': entry.key,
        'sessionId': 'session-1',
        'terminalId': 'terminal-1',
      });
      expect(event.type, entry.value);
    }
  });

  test('honors an explicitly configured native library path', () {
    expect(
      FfiIanvsAcpNativeApi.resolveLibraryPath(
        environment: const <String, String>{
          'IANVS_ACP_RUST_LIBRARY': '/custom/libianvs.dylib',
        },
        resolvedExecutable: '/Applications/ianvs.app/Contents/MacOS/ianvs',
        currentDirectory: '/workspace',
      ),
      '/custom/libianvs.dylib',
    );
  });
}

final class _FakeNativeApi implements IanvsAcpNativeApi {
  final Object handle = Object();
  final List<String> events = <String>[];
  Map<String, Object?>? startedConfig;
  Map<String, String>? lastPrompt;
  bool disposed = false;
  bool freed = false;
  void Function()? onPoll;

  @override
  int get ffiVersion => 10;

  @override
  Object createRuntime() => handle;

  @override
  bool startAgent(Object runtime, Map<String, Object?> config) {
    expect(runtime, same(handle));
    startedConfig = config;
    return true;
  }

  @override
  bool createSession(
    Object runtime, {
    required String requestId,
    required String cwd,
    required List<String> additionalDirectories,
  }) => true;

  @override
  bool restoreSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String cwd,
    required List<String> additionalDirectories,
    bool replayHistory = true,
  }) => true;

  @override
  bool listSessions(Object runtime, {required String requestId}) => true;

  @override
  bool closeSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) => true;

  @override
  bool deleteSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) => true;

  @override
  bool authenticate(
    Object runtime, {
    required String requestId,
    required String methodId,
  }) => true;

  @override
  bool logout(Object runtime, {required String requestId}) => true;

  @override
  bool prompt(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String text,
    List<Map<String, Object?>> attachments = const <Map<String, Object?>>[],
  }) {
    lastPrompt = <String, String>{
      'requestId': requestId,
      'sessionId': sessionId,
      'text': text,
    };
    return true;
  }

  @override
  bool cancel(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) => true;

  @override
  bool respondPermission(
    Object runtime, {
    required String requestId,
    required Map<String, Object?> decision,
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
  }) => true;

  @override
  String? pollEvents(
    Object runtime, {
    required int maxEvents,
    required int maxBytes,
    int timeoutMs = 0,
  }) {
    if (events.isEmpty) return null;
    final pollCallback = onPoll;
    onPoll = null;
    pollCallback?.call();
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
  bool dispose(Object runtime) {
    disposed = true;
    return true;
  }

  @override
  void freeRuntime(Object runtime) {
    freed = true;
  }
}
