import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'ianvs_runtime_event.dart';

abstract interface class IanvsAcpNativeApi {
  int get ffiVersion;

  Object createRuntime();

  bool startAgent(Object runtime, Map<String, Object?> config);

  bool createSession(
    Object runtime, {
    required String requestId,
    required String cwd,
    required List<String> additionalDirectories,
  });

  bool restoreSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String cwd,
    required List<String> additionalDirectories,
  });

  bool listSessions(Object runtime, {required String requestId});

  bool closeSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  });

  bool deleteSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  });

  bool authenticate(
    Object runtime, {
    required String requestId,
    required String methodId,
  });

  bool logout(Object runtime, {required String requestId});

  bool prompt(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String text,
    String? memoryContext,
    List<Map<String, Object?>> attachments = const <Map<String, Object?>>[],
  });

  bool cancel(
    Object runtime, {
    required String requestId,
    required String sessionId,
  });

  bool respondPermission(
    Object runtime, {
    required String requestId,
    required Map<String, Object?> decision,
  });

  bool setMode(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String modeId,
  });

  bool setConfigOption(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String configId,
    required Map<String, Object?> value,
  });

  String? pollEvent(Object runtime, {int timeoutMs = 0});

  String? lastError(Object runtime);

  bool dispose(Object runtime);

  void freeRuntime(Object runtime);
}

final class IanvsRustRuntime {
  IanvsRustRuntime({
    IanvsAcpNativeApi? native,
    this.pollInterval = const Duration(milliseconds: 16),
    this.maxEventsPerPoll = 64,
  }) : _native = native ?? FfiIanvsAcpNativeApi.open() {
    if (_native.ffiVersion != expectedFfiVersion) {
      throw StateError(
        'Unsupported ianvs ACP FFI version ${_native.ffiVersion}; '
        'expected $expectedFfiVersion.',
      );
    }
    if (pollInterval <= Duration.zero) {
      throw ArgumentError.value(
        pollInterval,
        'pollInterval',
        'must be positive',
      );
    }
    if (maxEventsPerPoll < 1) {
      throw ArgumentError.value(
        maxEventsPerPoll,
        'maxEventsPerPoll',
        'must be positive',
      );
    }
    _runtime = _native.createRuntime();
    _pollTimer = Timer.periodic(pollInterval, (_) => _drainEvents());
  }

  static const int expectedFfiVersion = 7;

  final IanvsAcpNativeApi _native;
  final Duration pollInterval;
  final int maxEventsPerPoll;
  final StreamController<IanvsRuntimeEvent> _events =
      StreamController<IanvsRuntimeEvent>.broadcast(sync: true);
  late final Object _runtime;
  Timer? _pollTimer;
  int _lastSequence = 0;
  bool _disposed = false;

  Stream<IanvsRuntimeEvent> get events => _events.stream;

  void startAgent({
    required String agentName,
    required String command,
    List<String> args = const <String>[],
    Map<String, String> environment = const <String, String>{},
    String? processCwd,
    String? sessionStorePath,
    int? sessionStoreMaxBytes,
    int? sessionStoreRetentionDays,
    List<Map<String, Object?>> mcpServers = const <Map<String, Object?>>[],
    Duration? permissionTimeout,
    bool enableFilesystemReadTextFile = false,
    bool enableFilesystemWriteTextFile = false,
    bool enableTerminalProvider = false,
    int? maxTerminalHandles,
    int? maxTerminalHandlesPerSession,
    int? terminalDefaultOutputByteLimit,
    int? terminalMaxOutputByteLimit,
  }) {
    _ensureOpen();
    _check(
      _native.startAgent(_runtime, <String, Object?>{
        'agentName': agentName,
        'command': command,
        'args': List<String>.unmodifiable(args),
        'environment': Map<String, String>.unmodifiable(environment),
        if (processCwd?.trim().isNotEmpty == true)
          'processCwd': processCwd!.trim(),
        if (sessionStorePath?.trim().isNotEmpty == true)
          'sessionStorePath': sessionStorePath!.trim(),
        'sessionStoreMaxBytes': ?sessionStoreMaxBytes,
        'sessionStoreRetentionDays': ?sessionStoreRetentionDays,
        'mcpServers': mcpServers
            .map(Map<String, Object?>.unmodifiable)
            .toList(growable: false),
        if (permissionTimeout != null)
          'permissionTimeoutMs': permissionTimeout.inMilliseconds,
        'enableFilesystemReadTextFile': enableFilesystemReadTextFile,
        'enableFilesystemWriteTextFile': enableFilesystemWriteTextFile,
        'enableTerminalProvider': enableTerminalProvider,
        'maxTerminalHandles': ?maxTerminalHandles,
        'maxTerminalHandlesPerSession': ?maxTerminalHandlesPerSession,
        'terminalDefaultOutputByteLimit': ?terminalDefaultOutputByteLimit,
        'terminalMaxOutputByteLimit': ?terminalMaxOutputByteLimit,
      }),
      'startAgent',
    );
  }

  void createSession({
    required String requestId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    _ensureOpen();
    _check(
      _native.createSession(
        _runtime,
        requestId: requestId,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
      ),
      'createSession',
    );
  }

  void restoreSession({
    required String requestId,
    required String sessionId,
    required String cwd,
    List<String> additionalDirectories = const <String>[],
  }) {
    _ensureOpen();
    _check(
      _native.restoreSession(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
        cwd: cwd,
        additionalDirectories: additionalDirectories,
      ),
      'restoreSession',
    );
  }

  void listSessions({required String requestId}) {
    _ensureOpen();
    _check(
      _native.listSessions(_runtime, requestId: requestId),
      'listSessions',
    );
  }

  void closeSession({required String requestId, required String sessionId}) {
    _ensureOpen();
    _check(
      _native.closeSession(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
      ),
      'closeSession',
    );
  }

  void deleteSession({required String requestId, required String sessionId}) {
    _ensureOpen();
    _check(
      _native.deleteSession(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
      ),
      'deleteSession',
    );
  }

  void authenticate({required String requestId, required String methodId}) {
    _ensureOpen();
    _check(
      _native.authenticate(_runtime, requestId: requestId, methodId: methodId),
      'authenticate',
    );
  }

  void logout({required String requestId}) {
    _ensureOpen();
    _check(_native.logout(_runtime, requestId: requestId), 'logout');
  }

  void prompt({
    required String requestId,
    required String sessionId,
    required String text,
    String? memoryContext,
    List<Map<String, Object?>> attachments = const <Map<String, Object?>>[],
  }) {
    _ensureOpen();
    _check(
      _native.prompt(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
        text: text,
        memoryContext: memoryContext,
        attachments: attachments,
      ),
      'prompt',
    );
  }

  void cancel({required String requestId, required String sessionId}) {
    _ensureOpen();
    _check(
      _native.cancel(_runtime, requestId: requestId, sessionId: sessionId),
      'cancel',
    );
  }

  void respondPermission({
    required String requestId,
    required Map<String, Object?> decision,
  }) {
    _ensureOpen();
    _check(
      _native.respondPermission(
        _runtime,
        requestId: requestId,
        decision: decision,
      ),
      'respondPermission',
    );
  }

  void setMode({
    required String requestId,
    required String sessionId,
    required String modeId,
  }) {
    _ensureOpen();
    _check(
      _native.setMode(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
        modeId: modeId,
      ),
      'setMode',
    );
  }

  void setConfigOption({
    required String requestId,
    required String sessionId,
    required String configId,
    required Map<String, Object?> value,
  }) {
    _ensureOpen();
    _check(
      _native.setConfigOption(
        _runtime,
        requestId: requestId,
        sessionId: sessionId,
        configId: configId,
        value: value,
      ),
      'setConfigOption',
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    final disposed = _native.dispose(_runtime);
    _drainEvents(allowDisposed: true);
    final disposeError = disposed ? null : _native.lastError(_runtime);
    _native.freeRuntime(_runtime);
    await _events.close();
    if (!disposed) {
      throw StateError(
        'dispose failed: ${disposeError ?? 'unknown native error'}',
      );
    }
  }

  void _drainEvents({bool allowDisposed = false}) {
    if (_disposed && !allowDisposed) return;
    for (var count = 0; count < maxEventsPerPoll; count += 1) {
      final encoded = _native.pollEvent(_runtime);
      if (encoded == null) return;
      try {
        final decoded = jsonDecode(encoded);
        if (decoded is! Map) {
          throw const FormatException('Rust event envelope must be an object.');
        }
        final event = IanvsRuntimeEvent.fromJson(
          decoded.map((key, value) => MapEntry(key.toString(), value)),
        );
        if (event.sequence <= _lastSequence) {
          throw StateError(
            'Rust event sequence regressed from $_lastSequence '
            'to ${event.sequence}.',
          );
        }
        _lastSequence = event.sequence;
        _events.add(event);
      } on Object catch (error, stackTrace) {
        _events.addError(error, stackTrace);
      }
    }
  }

  void _check(bool success, String operation) {
    if (success) return;
    throw StateError(
      '$operation failed: ${_native.lastError(_runtime) ?? 'unknown native error'}',
    );
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('Rust ACP runtime is disposed.');
  }
}

final class FfiIanvsAcpNativeApi implements IanvsAcpNativeApi {
  FfiIanvsAcpNativeApi._(this._library) {
    _version = _library.lookupFunction<Uint32 Function(), int Function()>(
      'ianvs_acp_ffi_version',
    );
    _runtimeNew = _library
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'ianvs_acp_runtime_new',
        );
    _runtimeFree = _library
        .lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('ianvs_acp_runtime_free');
    _startAgent = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_acp_start_agent');
    _createSession = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_create_session');
    _restoreSession = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_restore_session');
    _listSessions = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_acp_list_sessions');
    _closeSession = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_acp_close_session');
    _deleteSession = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_acp_delete_session');
    _authenticate = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_acp_authenticate');
    _logout = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>)
        >('ianvs_acp_logout');
    _prompt = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_prompt');
    _promptWithAttachments = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_prompt_with_attachments');
    _promptWithContextAndAttachments = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_prompt_with_context_and_attachments');
    _cancel = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_acp_cancel');
    _respondPermission = _library
        .lookupFunction<
          Bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
          bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
        >('ianvs_acp_respond_permission');
    _setMode = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_set_mode');
    _setConfigOption = _library
        .lookupFunction<
          Bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          ),
          bool Function(
            Pointer<Void>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
            Pointer<Utf8>,
          )
        >('ianvs_acp_set_config_option');
    _dispose = _library
        .lookupFunction<
          Bool Function(Pointer<Void>),
          bool Function(Pointer<Void>)
        >('ianvs_acp_dispose');
    _pollEvent = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>, Uint32),
          Pointer<Utf8> Function(Pointer<Void>, int)
        >('ianvs_acp_poll_event');
    _lastError = _library
        .lookupFunction<
          Pointer<Utf8> Function(Pointer<Void>),
          Pointer<Utf8> Function(Pointer<Void>)
        >('ianvs_acp_last_error');
    _stringFree = _library
        .lookupFunction<
          Void Function(Pointer<Utf8>),
          void Function(Pointer<Utf8>)
        >('ianvs_acp_string_free');
  }

  factory FfiIanvsAcpNativeApi.open({String? libraryPath}) {
    return FfiIanvsAcpNativeApi._(
      DynamicLibrary.open(libraryPath ?? resolveLibraryPath()),
    );
  }

  static String resolveLibraryPath({
    Map<String, String>? environment,
    String? resolvedExecutable,
    String? currentDirectory,
  }) {
    final env = environment ?? Platform.environment;
    final configured = env['IANVS_ACP_RUST_LIBRARY']?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    final executable = resolvedExecutable ?? Platform.resolvedExecutable;
    final executableDirectory = File(executable).parent;
    final workingDirectory = currentDirectory ?? Directory.current.path;
    final candidates = <String>[
      '${executableDirectory.path}/../Frameworks/libianvs_acp_ffi.dylib',
      '$workingDirectory/rust/target/debug/libianvs_acp_ffi.dylib',
      '$workingDirectory/rust/target/release/libianvs_acp_ffi.dylib',
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    throw StateError(
      'ianvs ACP Rust library not found. Checked: ${candidates.join(', ')}',
    );
  }

  final DynamicLibrary _library;
  late final int Function() _version;
  late final Pointer<Void> Function() _runtimeNew;
  late final void Function(Pointer<Void>) _runtimeFree;
  late final bool Function(Pointer<Void>, Pointer<Utf8>) _startAgent;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _createSession;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _restoreSession;
  late final bool Function(Pointer<Void>, Pointer<Utf8>) _listSessions;
  late final bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
  _closeSession;
  late final bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
  _deleteSession;
  late final bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
  _authenticate;
  late final bool Function(Pointer<Void>, Pointer<Utf8>) _logout;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _prompt;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _promptWithAttachments;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _promptWithContextAndAttachments;
  late final bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>) _cancel;
  late final bool Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)
  _respondPermission;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _setMode;
  late final bool Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  _setConfigOption;
  late final bool Function(Pointer<Void>) _dispose;
  late final Pointer<Utf8> Function(Pointer<Void>, int) _pollEvent;
  late final Pointer<Utf8> Function(Pointer<Void>) _lastError;
  late final void Function(Pointer<Utf8>) _stringFree;

  @override
  int get ffiVersion => _version();

  @override
  Object createRuntime() {
    final runtime = _runtimeNew();
    if (runtime == nullptr) {
      throw StateError('Failed to allocate Rust runtime.');
    }
    return runtime;
  }

  @override
  bool startAgent(Object runtime, Map<String, Object?> config) {
    return _withUtf8(jsonEncode(config), (value) {
      return _startAgent(_pointer(runtime), value);
    });
  }

  @override
  bool createSession(
    Object runtime, {
    required String requestId,
    required String cwd,
    required List<String> additionalDirectories,
  }) {
    return _withThreeUtf8(
      requestId,
      cwd,
      jsonEncode(additionalDirectories),
      (request, directory, additional) =>
          _createSession(_pointer(runtime), request, directory, additional),
    );
  }

  @override
  bool restoreSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String cwd,
    required List<String> additionalDirectories,
  }) {
    return _withFourUtf8(
      requestId,
      sessionId,
      cwd,
      jsonEncode(additionalDirectories),
      (request, session, directory, additional) => _restoreSession(
        _pointer(runtime),
        request,
        session,
        directory,
        additional,
      ),
    );
  }

  @override
  bool listSessions(Object runtime, {required String requestId}) {
    return _withUtf8(
      requestId,
      (request) => _listSessions(_pointer(runtime), request),
    );
  }

  @override
  bool closeSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    return _withTwoUtf8(
      requestId,
      sessionId,
      (request, session) => _closeSession(_pointer(runtime), request, session),
    );
  }

  @override
  bool deleteSession(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    return _withTwoUtf8(
      requestId,
      sessionId,
      (request, session) => _deleteSession(_pointer(runtime), request, session),
    );
  }

  @override
  bool authenticate(
    Object runtime, {
    required String requestId,
    required String methodId,
  }) {
    return _withTwoUtf8(
      requestId,
      methodId,
      (request, method) => _authenticate(_pointer(runtime), request, method),
    );
  }

  @override
  bool logout(Object runtime, {required String requestId}) {
    return _withUtf8(
      requestId,
      (request) => _logout(_pointer(runtime), request),
    );
  }

  @override
  bool prompt(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String text,
    String? memoryContext,
    List<Map<String, Object?>> attachments = const <Map<String, Object?>>[],
  }) {
    final context = memoryContext?.trim();
    if (context != null && context.isNotEmpty) {
      return _withFiveUtf8(
        requestId,
        sessionId,
        text,
        context,
        jsonEncode(attachments),
        (request, session, promptText, memoryText, encoded) =>
            _promptWithContextAndAttachments(
              _pointer(runtime),
              request,
              session,
              promptText,
              memoryText,
              encoded,
            ),
      );
    }
    if (attachments.isNotEmpty) {
      return _withFourUtf8(
        requestId,
        sessionId,
        text,
        jsonEncode(attachments),
        (request, session, promptText, encoded) => _promptWithAttachments(
          _pointer(runtime),
          request,
          session,
          promptText,
          encoded,
        ),
      );
    }
    return _withThreeUtf8(
      requestId,
      sessionId,
      text,
      (request, session, promptText) =>
          _prompt(_pointer(runtime), request, session, promptText),
    );
  }

  @override
  bool cancel(
    Object runtime, {
    required String requestId,
    required String sessionId,
  }) {
    return _withTwoUtf8(
      requestId,
      sessionId,
      (request, session) => _cancel(_pointer(runtime), request, session),
    );
  }

  @override
  bool respondPermission(
    Object runtime, {
    required String requestId,
    required Map<String, Object?> decision,
  }) {
    return _withTwoUtf8(
      requestId,
      jsonEncode(decision),
      (request, encoded) =>
          _respondPermission(_pointer(runtime), request, encoded),
    );
  }

  @override
  bool setMode(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String modeId,
  }) {
    return _withThreeUtf8(
      requestId,
      sessionId,
      modeId,
      (request, session, mode) =>
          _setMode(_pointer(runtime), request, session, mode),
    );
  }

  @override
  bool setConfigOption(
    Object runtime, {
    required String requestId,
    required String sessionId,
    required String configId,
    required Map<String, Object?> value,
  }) {
    return _withFourUtf8(
      requestId,
      sessionId,
      configId,
      jsonEncode(value),
      (request, session, config, encoded) => _setConfigOption(
        _pointer(runtime),
        request,
        session,
        config,
        encoded,
      ),
    );
  }

  @override
  String? pollEvent(Object runtime, {int timeoutMs = 0}) {
    return _takeNativeString(_pollEvent(_pointer(runtime), timeoutMs));
  }

  @override
  String? lastError(Object runtime) {
    return _takeNativeString(_lastError(_pointer(runtime)));
  }

  @override
  bool dispose(Object runtime) => _dispose(_pointer(runtime));

  @override
  void freeRuntime(Object runtime) => _runtimeFree(_pointer(runtime));

  Pointer<Void> _pointer(Object runtime) {
    if (runtime is! Pointer<Void>) {
      throw ArgumentError.value(runtime, 'runtime', 'invalid native handle');
    }
    return runtime;
  }

  String? _takeNativeString(Pointer<Utf8> value) {
    if (value == nullptr) return null;
    try {
      return value.toDartString();
    } finally {
      _stringFree(value);
    }
  }
}

T _withUtf8<T>(String value, T Function(Pointer<Utf8>) operation) {
  final pointer = value.toNativeUtf8();
  try {
    return operation(pointer);
  } finally {
    malloc.free(pointer);
  }
}

T _withTwoUtf8<T>(
  String first,
  String second,
  T Function(Pointer<Utf8>, Pointer<Utf8>) operation,
) {
  return _withUtf8(first, (firstPointer) {
    return _withUtf8(second, (secondPointer) {
      return operation(firstPointer, secondPointer);
    });
  });
}

T _withThreeUtf8<T>(
  String first,
  String second,
  String third,
  T Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) operation,
) {
  return _withUtf8(first, (firstPointer) {
    return _withUtf8(second, (secondPointer) {
      return _withUtf8(third, (thirdPointer) {
        return operation(firstPointer, secondPointer, thirdPointer);
      });
    });
  });
}

T _withFourUtf8<T>(
  String first,
  String second,
  String third,
  String fourth,
  T Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)
  operation,
) {
  return _withThreeUtf8(first, second, third, (
    firstPointer,
    secondPointer,
    thirdPointer,
  ) {
    return _withUtf8(fourth, (fourthPointer) {
      return operation(
        firstPointer,
        secondPointer,
        thirdPointer,
        fourthPointer,
      );
    });
  });
}

T _withFiveUtf8<T>(
  String first,
  String second,
  String third,
  String fourth,
  String fifth,
  T Function(
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<Utf8>,
  )
  operation,
) {
  return _withFourUtf8(first, second, third, fourth, (
    firstPointer,
    secondPointer,
    thirdPointer,
    fourthPointer,
  ) {
    return _withUtf8(fifth, (fifthPointer) {
      return operation(
        firstPointer,
        secondPointer,
        thirdPointer,
        fourthPointer,
        fifthPointer,
      );
    });
  });
}
