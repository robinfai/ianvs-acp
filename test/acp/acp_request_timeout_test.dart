import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/inbound_gate.dart';
import 'package:dart_acp/src/rpc/peer.dart';
import 'package:dart_acp/src/session/session_manager.dart'
    show PromptLifecycleSnapshot, SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
// ignore: depend_on_referenced_packages
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';

final class _ControlledPermissionProvider
    implements acp.CancellablePermissionProvider {
  final List<acp.PermissionOptions> requests = <acp.PermissionOptions>[];
  final List<Completer<acp.PermissionDecision>> pending =
      <Completer<acp.PermissionDecision>>[];
  final List<(Object, acp.PermissionCancellationReason)> cancellations =
      <(Object, acp.PermissionCancellationReason)>[];
  final Completer<void> requestStarted = Completer<void>();
  final StreamController<int> requestEvents = StreamController<int>.broadcast();
  Object? cancellationFailure;
  void Function(acp.PermissionOptions options)? onRequest;
  void Function(
    Object cancellationToken,
    acp.PermissionCancellationReason reason,
  )?
  onCancel;

  @override
  Future<acp.PermissionDecision> request(acp.PermissionOptions options) {
    requests.add(options);
    onRequest?.call(options);
    if (!requestStarted.isCompleted) requestStarted.complete();
    requestEvents.add(requests.length - 1);
    final completer = Completer<acp.PermissionDecision>();
    pending.add(completer);
    return completer.future;
  }

  void completeAllow(int index) {
    if (!pending[index].isCompleted) {
      pending[index].complete(const acp.PermissionDecision.allow());
    }
  }

  void completeDecision(int index, acp.PermissionDecision decision) {
    if (!pending[index].isCompleted) pending[index].complete(decision);
  }

  void completeError(int index, Object error) {
    if (!pending[index].isCompleted) pending[index].completeError(error);
  }

  void completeTimeout(int index) {
    if (!pending[index].isCompleted) {
      pending[index].completeError(
        const acp.PermissionRequestTimeoutException(),
      );
    }
  }

  @override
  void cancelPendingPermission({
    required Object cancellationToken,
    required acp.PermissionCancellationReason reason,
  }) {
    cancellations.add((cancellationToken, reason));
    onCancel?.call(cancellationToken, reason);
    final failure = cancellationFailure;
    if (failure != null) throw failure;
  }

  void finishPending() {
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(const acp.PermissionDecision.cancelled());
      }
    }
  }

  Future<void> waitForRequest(int index) async {
    if (requests.length > index) return;
    await requestEvents.stream.firstWhere((seen) => seen == index);
  }
}

final class _CountingFsProvider implements acp.FsProvider {
  int readCalls = 0;
  int writeCalls = 0;
  Completer<String>? readResult;
  Completer<void>? writeResult;
  final Completer<void> readStarted = Completer<void>();
  final Completer<void> writeStarted = Completer<void>();

  @override
  Future<String> readTextFile(String path, {int? line, int? limit}) async {
    readCalls += 1;
    if (!readStarted.isCompleted) readStarted.complete();
    final controlled = readResult;
    if (controlled != null) return controlled.future;
    return 'ok';
  }

  @override
  Future<void> writeTextFile(String path, String content) async {
    writeCalls += 1;
    if (!writeStarted.isCompleted) writeStarted.complete();
    final controlled = writeResult;
    if (controlled != null) await controlled.future;
  }
}

final class _CountingTerminalProvider implements acp.TerminalProvider {
  final acp.DefaultTerminalProvider _inner = acp.DefaultTerminalProvider(
    maxActiveHandles: 2,
    maxActiveHandlesPerSession: 1,
  );
  int createCalls = 0;
  int releaseCalls = 0;
  bool releaseThrows = false;
  bool releaseThrowsSynchronously = false;
  void Function()? onCreate;
  Completer<void>? releaseBarrier;
  final Completer<void> createStarted = Completer<void>();
  final Completer<void> releaseStarted = Completer<void>();
  final Completer<void> releaseCompleted = Completer<void>();
  Completer<acp.TerminalProcessHandle>? createResult;

  Future<acp.TerminalProcessHandle> createLateHandle(String sessionId) =>
      _inner.create(
        sessionId: sessionId,
        command: '/bin/sh',
        args: const <String>['-c', 'sleep 30'],
      );

  @override
  Future<acp.TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int outputByteLimit = acp.defaultTerminalOutputByteLimit,
  }) {
    createCalls += 1;
    if (!createStarted.isCompleted) createStarted.complete();
    onCreate?.call();
    final controlled = createResult;
    if (controlled != null) return controlled.future;
    return _inner.create(
      sessionId: sessionId,
      command: command,
      args: args,
      cwd: cwd,
      env: env,
      outputByteLimit: outputByteLimit,
    );
  }

  @override
  Future<String> currentOutput(acp.TerminalProcessHandle handle) =>
      _inner.currentOutput(handle);

  @override
  Future<int> waitForExit(acp.TerminalProcessHandle handle) =>
      _inner.waitForExit(handle);

  @override
  Future<void> kill(acp.TerminalProcessHandle handle) => _inner.kill(handle);

  @override
  Future<void> release(acp.TerminalProcessHandle handle) {
    releaseCalls += 1;
    if (!releaseStarted.isCompleted) releaseStarted.complete();
    final barrier = releaseBarrier;
    final releasing = barrier == null
        ? _inner.release(handle)
        : barrier.future.then<void>((_) => _inner.release(handle));
    if (releaseThrowsSynchronously) {
      unawaited(
        releasing.then<void>(
          (_) {
            if (!releaseCompleted.isCompleted) releaseCompleted.complete();
          },
          onError: (Object _, StackTrace _) {
            if (!releaseCompleted.isCompleted) releaseCompleted.complete();
          },
        ),
      );
      throw StateError('fixed synchronous release failure');
    }
    return releasing.then<void>((_) {
      if (!releaseCompleted.isCompleted) releaseCompleted.complete();
      if (releaseThrows) throw StateError('fixed release failure');
    });
  }
}

final class _RpcReply {
  const _RpcReply(this.raw);

  final Map<String, dynamic> raw;

  Object? get result => raw['result'];
  Map<String, dynamic>? get error => raw['error'] is Map
      ? Map<String, dynamic>.from(raw['error'] as Map)
      : null;
  int? get errorCode => error?['code'] as int?;
  String? get errorMessage => error?['message'] as String?;
  bool get hasErrorData => error?.containsKey('data') ?? false;
}

final class _ObservedFutureOutcome {
  const _ObservedFutureOutcome.value(this.value)
    : error = null,
      stackTrace = null;

  const _ObservedFutureOutcome.error(this.error, this.stackTrace)
    : value = null;

  final Object? value;
  final Object? error;
  final StackTrace? stackTrace;
}

Future<_ObservedFutureOutcome> _observeFuture(Future<dynamic> future) =>
    future.then<_ObservedFutureOutcome>(
      _ObservedFutureOutcome.value,
      onError: (Object error, StackTrace stackTrace) =>
          _ObservedFutureOutcome.error(error, stackTrace),
    );

Future<void> _expectNoZoneErrors(Future<void> Function() body) async {
  final done = Completer<void>();
  final zoneErrors = <Object>[];
  Object? operationError;
  StackTrace? operationStackTrace;
  runZonedGuarded<void>(() {
    unawaited(() async {
      try {
        await body();
      } catch (error, stackTrace) {
        operationError = error;
        operationStackTrace = stackTrace;
      } finally {
        done.complete();
      }
    }());
  }, (error, _) => zoneErrors.add(error));
  await done.future.timeout(const Duration(seconds: 10));
  await pumpEventQueue();
  if (operationError case final error?) {
    Error.throwWithStackTrace(error, operationStackTrace!);
  }
  expect(zoneErrors, isEmpty);
}

final class _PermissionRequestProbe {
  _PermissionRequestProbe(this.id, this.responseCompleter);

  final int id;
  final Completer<_RpcReply> responseCompleter;
  final Completer<void> admissionSeen = Completer<void>();
  final Completer<void> handlerStarted = Completer<void>();
  final Completer<void> reservationReleased = Completer<void>();
  final Completer<void> responseCommitted = Completer<void>();
  int reservationReleaseCount = 0;
  int responseCommitCount = 0;
  int invalidationCount = 0;
  int providerCalls = 0;
  int providerCancellationCount = 0;
  int sideEffectCalls = 0;
  InboundAdmission? admission;
  Future<dynamic>? handlerOperation;

  Future<_RpcReply> get response => responseCompleter.future;
  Future<void> get settled => admission!.settled;
}

final class _ObservedAdmission implements InboundAdmission {
  _ObservedAdmission(this.inner, this.probe);

  final InboundAdmission inner;
  final _PermissionRequestProbe probe;

  @override
  Future<InboundGateTerminal<dynamic>> get terminal => inner.terminal;

  @override
  Future<void> get settled => inner.settled;

  @override
  Future<dynamic> runLocalOperation(FutureOr<dynamic> Function() operation) =>
      inner.runLocalOperation(() {
        if (!probe.handlerStarted.isCompleted) {
          probe.handlerStarted.complete();
        }
        final result = Future<dynamic>.sync(operation);
        probe.handlerOperation = result;
        return result;
      });

  @override
  void bindReservationReleased(Future<void> released) {
    inner.bindReservationReleased(released);
    released.whenComplete(() {
      probe.reservationReleaseCount += 1;
      if (!probe.reservationReleased.isCompleted) {
        probe.reservationReleased.complete();
      }
    });
  }

  @override
  void bindResponseCommitted(Future<void> committed) {
    inner.bindResponseCommitted(committed);
    committed.whenComplete(() {
      probe.responseCommitCount += 1;
      if (!probe.responseCommitted.isCompleted) {
        probe.responseCommitted.complete();
      }
    });
  }

  @override
  void markPeerClosed() => inner.markPeerClosed();
}

final class _FailingFatalClosePeer extends JsonRpcPeer {
  _FailingFatalClosePeer(
    super.channel, {
    required super.timeouts,
    required super.maxConcurrentHandlers,
    required super.maxOrdinaryConcurrentHandlers,
  });

  @override
  Future<void> closeForFatalTimeout({
    AcpPromptCleanupIdentity? cleanupIdentity,
  }) => super
      .closeForFatalTimeout(cleanupIdentity: cleanupIdentity)
      .then<void>((_) => throw StateError('fixed fatal close failure'));
}

final class _SynchronouslyFailingFatalClosePeer extends JsonRpcPeer {
  _SynchronouslyFailingFatalClosePeer(
    super.channel, {
    required super.timeouts,
    required super.maxConcurrentHandlers,
    required super.maxOrdinaryConcurrentHandlers,
  });

  @override
  Future<void> closeForFatalTimeout({
    AcpPromptCleanupIdentity? cleanupIdentity,
  }) {
    throw StateError('fixed synchronous fatal close failure');
  }
}

class _PermissionAdmissionHarness {
  _PermissionAdmissionHarness._({
    required this.channel,
    required this.peer,
    required this.manager,
    required this.permissions,
    required this.fs,
    required this.terminals,
  });

  static Future<_PermissionAdmissionHarness> start({
    acp.AcpTimeouts timeouts = const acp.AcpTimeouts(),
    Duration? promptCancelGrace,
    int maxOrdinaryConcurrentHandlers = 1,
    bool controlFutureSetups = false,
    bool registerInitialSession = true,
    bool synchronousChannel = false,
    bool failFatalCloseFuture = false,
    bool throwSynchronouslyOnFatalClose = false,
  }) async {
    assert(!(failFatalCloseFuture && throwSynchronouslyOnFatalClose));
    final channel = StreamChannelController<String>(sync: synchronousChannel);
    final permissions = _ControlledPermissionProvider();
    final fs = _CountingFsProvider();
    final terminals = _CountingTerminalProvider();
    final effective = promptCancelGrace == null
        ? timeouts
        : acp.AcpTimeouts(
            initialize: timeouts.initialize,
            request: timeouts.request,
            prompt: timeouts.prompt,
            permission: timeouts.permission,
            promptCancelGrace: promptCancelGrace,
          );
    final JsonRpcPeer peer = throwSynchronouslyOnFatalClose
        ? _SynchronouslyFailingFatalClosePeer(
            channel.foreign,
            timeouts: effective,
            maxConcurrentHandlers: maxOrdinaryConcurrentHandlers + 2,
            maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
          )
        : failFatalCloseFuture
        ? _FailingFatalClosePeer(
            channel.foreign,
            timeouts: effective,
            maxConcurrentHandlers: maxOrdinaryConcurrentHandlers + 2,
            maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
          )
        : JsonRpcPeer(
            channel.foreign,
            timeouts: effective,
            maxConcurrentHandlers: maxOrdinaryConcurrentHandlers + 2,
            maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
          );
    final manager = SessionManager(
      config: acp.AcpConfig(
        timeouts: effective,
        permissionProvider: permissions,
        fsProvider: fs,
        terminalProvider: terminals,
      ),
      peer: peer,
      maxTerminalHandles: 2,
      maxTerminalHandlesPerSession: 1,
    );
    final harness = _PermissionAdmissionHarness._(
      channel: channel,
      peer: peer,
      manager: manager,
      permissions: permissions,
      fs: fs,
      terminals: terminals,
    );
    harness._installAdmissionObserver();
    harness._wireSubscription = channel.local.stream.listen(harness._onWire);
    if (registerInitialSession) {
      await manager.resumeSession(
        sessionId: harness.sessionId,
        workspaceRoot: '/tmp',
      );
    }
    harness._holdSetupResponses = controlFutureSetups;
    return harness;
  }

  final StreamChannelController<String> channel;
  final JsonRpcPeer peer;
  final SessionManager manager;
  final _ControlledPermissionProvider permissions;
  final _CountingFsProvider fs;
  final _CountingTerminalProvider terminals;
  final String sessionId = 'timeout-session';
  final Queue<_PermissionRequestProbe> _admissionQueue =
      Queue<_PermissionRequestProbe>();
  final Map<Object?, Completer<_RpcReply>> _responses =
      <Object?, Completer<_RpcReply>>{};
  final StreamController<Map<String, dynamic>> wireRequests =
      StreamController<Map<String, dynamic>>.broadcast();
  final List<Map<String, dynamic>> setupRequests = <Map<String, dynamic>>[];
  final StreamController<int> setupRequestEvents =
      StreamController<int>.broadcast();
  final Completer<void> _ordinaryStarted = Completer<void>();
  final Completer<void> _releaseOrdinary = Completer<void>();
  late final StreamSubscription<String> _wireSubscription;
  int _nextId = 100;
  bool _holdSetupResponses = false;
  Future<_RpcReply>? _ordinaryResponse;

  void _installAdmissionObserver() {
    final production = peer.onInboundAdmission!;
    peer.onInboundAdmission = (method, params, correlation) {
      final probe = _admissionQueue.removeFirst();
      final inner = production(method, params, correlation);
      final observed = _ObservedAdmission(inner, probe);
      probe.admission = observed;
      probe.admissionSeen.complete();
      return observed;
    };
  }

  void _onWire(String line) {
    final decoded = jsonDecode(line);
    if (decoded is List) {
      for (final item in decoded.whereType<Map>()) {
        _acceptWireMap(Map<String, dynamic>.from(item));
      }
      return;
    }
    if (decoded is Map) _acceptWireMap(Map<String, dynamic>.from(decoded));
  }

  void _acceptWireMap(Map<String, dynamic> message) {
    final method = message['method'];
    if (method is String) wireRequests.add(message);
    if (method == 'session/close') {
      channel.local.sink.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        }),
      );
      return;
    }
    if (method == 'session/resume' ||
        method == 'session/load' ||
        method == 'session/new' ||
        method == 'session/fork') {
      if (_holdSetupResponses) {
        setupRequests.add(message);
        setupRequestEvents.add(setupRequests.length - 1);
      } else {
        _completeSetup(message, result: const <String, dynamic>{});
      }
      return;
    }
    if (!message.containsKey('method') && message.containsKey('id')) {
      _responses.remove(message['id'])?.complete(_RpcReply(message));
    }
  }

  Future<void> waitForSetupRequest(int index) async {
    if (setupRequests.length > index) return;
    await setupRequestEvents.stream.firstWhere((seen) => seen == index);
  }

  void completeSetupSuccess(int index, {String? sessionId}) {
    _completeSetup(
      setupRequests[index],
      result: <String, dynamic>{'sessionId': ?sessionId},
    );
  }

  void completeSetupError(int index, String message) {
    final request = setupRequests[index];
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'error': <String, dynamic>{'code': -32000, 'message': message},
      }),
    );
  }

  void _completeSetup(
    Map<String, dynamic> request, {
    required Map<String, dynamic> result,
  }) {
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': request['id'],
        'result': result,
      }),
    );
  }

  Map<String, dynamic> paramsFor(String method) => switch (method) {
    'session/request_permission' => <String, dynamic>{
      'sessionId': sessionId,
      'options': <Map<String, dynamic>>[
        <String, dynamic>{'optionId': 'allow', 'name': 'Allow'},
      ],
      'toolCall': <String, dynamic>{'title': 'tool'},
    },
    'fs/read_text_file' => <String, dynamic>{
      'sessionId': sessionId,
      'path': '/tmp/input.txt',
    },
    'fs/write_text_file' => <String, dynamic>{
      'sessionId': sessionId,
      'path': '/tmp/output.txt',
      'content': 'ok',
    },
    'terminal/create' => <String, dynamic>{
      'sessionId': sessionId,
      'command': '/usr/bin/true',
      'args': <String>[],
    },
    _ => <String, dynamic>{'sessionId': sessionId},
  };

  Future<_PermissionRequestProbe> admit(
    String method, {
    acp.AcpSessionInputBudgetOwner? owner,
    Map<String, dynamic>? params,
  }) => admitRaw(method, params: params ?? paramsFor(method));

  Future<_PermissionRequestProbe> admitRaw(
    String method, {
    Object? params,
  }) async {
    final id = _nextId++;
    final response = Completer<_RpcReply>();
    final probe = _PermissionRequestProbe(id, response);
    _responses[id] = response;
    _admissionQueue.add(probe);
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    await probe.admissionSeen.future.timeout(const Duration(seconds: 2));
    return probe;
  }

  Future<void> occupyAllOrdinaryPermits() async {
    peer.onTerminalOutput = (_) async {
      if (!_ordinaryStarted.isCompleted) _ordinaryStarted.complete();
      await _releaseOrdinary.future;
      return <String, dynamic>{'output': '', 'truncated': false};
    };
    final id = _nextId++;
    final response = Completer<_RpcReply>();
    _responses[id] = response;
    _ordinaryResponse = response.future;
    channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': id,
        'method': 'terminal/output',
        'params': <String, dynamic>{'sessionId': sessionId},
      }),
    );
    await _ordinaryStarted.future.timeout(const Duration(seconds: 2));
  }

  void releaseOrdinaryPermits() {
    if (!_releaseOrdinary.isCompleted) _releaseOrdinary.complete();
  }

  void cancelOwner(
    acp.AcpSessionInputBudgetOwner owner,
    acp.PermissionCancellationReason reason,
  ) {
    manager.settlePromptAdmissions(owner: owner, reason: reason);
  }

  Future<void> dispose() async {
    permissions.finishPending();
    releaseOrdinaryPermits();
    await manager.dispose();
    await peer.close();
    await _wireSubscription.cancel();
    await channel.local.sink.close();
    await permissions.requestEvents.close();
    await setupRequestEvents.close();
    await wireRequests.close();
  }
}

enum _BlockedOutcome {
  requestSelected,
  requestCancelled,
  fsSuccess,
  fsDenied,
  terminalSuccess,
  terminalDenied,
  rpcException,
  handlerError,
}

final class _BlockedBatchProbe {
  _BlockedBatchProbe(
    this.owner,
    this.base,
    this.permission,
    this.providerIndex,
    this.releaseSibling,
    this.permissionResponse,
    this.siblingResponse,
  ) {
    base.peer.addUnavailableListener((state) {
      fatalCloseCount += 1;
      if (!peerUnavailable.isCompleted) peerUnavailable.complete(state);
    });
    permissionResponse.future.then<void>(wireResponses.add);
    siblingResponse.future.then<void>(wireResponses.add);
    permission.settled.whenComplete(() => admissionSettled = true);
  }

  final acp.AcpSessionInputBudgetOwner? owner;
  final _PermissionAdmissionHarness base;
  final _PermissionRequestProbe permission;
  final int providerIndex;
  final Completer<void> releaseSibling;
  final Completer<_RpcReply> permissionResponse;
  final Completer<_RpcReply> siblingResponse;
  final Completer<AcpPeerUnavailableState> peerUnavailable =
      Completer<AcpPeerUnavailableState>();
  final List<_RpcReply> wireResponses = <_RpcReply>[];
  int fatalCloseCount = 0;
  bool admissionSettled = false;

  Future<void> get permissionReservationReleased =>
      permission.reservationReleased.future;
  Future<void> get reservationReleased => permissionReservationReleased;
  bool get responseCommitted => permission.responseCommitCount != 0;
  bool get permissionResponseCompleted => permissionResponse.isCompleted;
  bool get siblingResponseCompleted => siblingResponse.isCompleted;
  int get gatePendingItems => base.peer.inboundPendingItemsForTesting;
  int get correlationPendingItems =>
      base.peer.correlationPendingItemsForTesting;
  int get admissionCount => admissionSettled ? 0 : 1;
  int get cleanupWindowStartCount =>
      base.manager.admissionCleanupWindowStartCountForTesting;
  int get cleanupExpiryCallbackCount =>
      base.manager.ownerCleanupExpiryCallbackCountForTesting;
  int get cleanupWindowCount =>
      base.manager.admissionCleanupWindowCountForTesting;
  Object? _cleanupWindowIdentity;
  void Function()? _cleanupTimerCallback;
  bool Function()? _cleanupTimerIsActive;
  Future<void>? _cleanupReaped;
  DateTime? _cleanupDeadline;

  Object get cleanupWindowIdentity {
    final captured = _cleanupWindowIdentity;
    if (captured != null) return captured;
    final observed = permission.admission! as _ObservedAdmission;
    final identity = base.manager.admissionCleanupWindowIdentityForTesting(
      observed.inner,
    )!;
    _cleanupWindowIdentity = identity;
    _cleanupTimerCallback = base.manager
        .admissionCleanupWindowTimerCallbackForTesting(identity);
    _cleanupTimerIsActive = base.manager
        .admissionCleanupWindowTimerActiveProbeForTesting(identity);
    _cleanupReaped = base.manager.ownerCleanupWindowReapedForTesting(identity);
    _cleanupDeadline = base.manager.ownerCleanupWindowDeadlineForTesting(
      identity,
    );
    return identity;
  }

  Future<void> get cleanupReaped {
    cleanupWindowIdentity;
    return _cleanupReaped!;
  }

  bool get cleanupTimerCancelled {
    cleanupWindowIdentity;
    return !_cleanupTimerIsActive!();
  }

  bool get cleanupTimerActive {
    cleanupWindowIdentity;
    return _cleanupTimerIsActive!();
  }

  void Function() get cleanupTimerCallback {
    cleanupWindowIdentity;
    return _cleanupTimerCallback!;
  }

  DateTime get cleanupDeadline {
    cleanupWindowIdentity;
    return _cleanupDeadline!;
  }

  acp.PermissionCancellationReason? get firstCancellationReason =>
      base.permissions.cancellations.isEmpty
      ? null
      : base.permissions.cancellations.first.$2;

  Future<void> finishLateSibling() async {
    if (!releaseSibling.isCompleted) releaseSibling.complete();
    await pumpEventQueue();
  }

  Future<void> commitResponse() async {
    if (!releaseSibling.isCompleted) releaseSibling.complete();
    await permission.responseCommitted.future.timeout(
      const Duration(seconds: 2),
    );
  }

  void fireCapturedTimerCallback() {
    cleanupWindowIdentity;
    _cleanupTimerCallback!.call();
  }

  Future<void> elapseOwnGrace() =>
      peerUnavailable.future.timeout(const Duration(seconds: 2));
}

final class _PermissionBatchHarness {
  _PermissionBatchHarness._(this.base);

  final _PermissionAdmissionHarness base;

  int get fatalCloseCount => base.peer.isAvailable ? 0 : 1;

  static Future<_PermissionBatchHarness> start({
    required Duration promptCancelGrace,
    bool failFatalCloseFuture = false,
    bool throwSynchronouslyOnFatalClose = false,
  }) async => _PermissionBatchHarness._(
    await _PermissionAdmissionHarness.start(
      timeouts: acp.AcpTimeouts(
        permission: const Duration(milliseconds: 75),
        promptCancelGrace: promptCancelGrace,
      ),
      failFatalCloseFuture: failFatalCloseFuture,
      throwSynchronouslyOnFatalClose: throwSynchronouslyOnFatalClose,
    ),
  );

  Future<_BlockedBatchProbe> _send({
    required String method,
    acp.AcpSessionInputBudgetOwner? owner,
    acp.PermissionCancellationReason? reason,
  }) async {
    final providerIndex = base.permissions.requests.length;
    final releaseSibling = Completer<void>();
    base.peer.onTerminalOutput = (_) async {
      await releaseSibling.future;
      return <String, dynamic>{'output': '', 'truncated': false};
    };
    final permissionId = base._nextId++;
    final siblingId = base._nextId++;
    final permissionReply = Completer<_RpcReply>();
    final siblingReply = Completer<_RpcReply>();
    final probe = _PermissionRequestProbe(permissionId, permissionReply);
    base._responses[permissionId] = permissionReply;
    base._responses[siblingId] = siblingReply;
    base._admissionQueue.add(probe);
    base.channel.local.sink.add(
      jsonEncode(<Object?>[
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': permissionId,
          'method': method,
          'params': base.paramsFor(method),
        },
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': siblingId,
          'method': 'terminal/output',
          'params': <String, dynamic>{'sessionId': base.sessionId},
        },
      ]),
    );
    await probe.admissionSeen.future.timeout(const Duration(seconds: 2));
    if (reason != null && owner != null) base.cancelOwner(owner, reason);
    return _BlockedBatchProbe(
      owner,
      base,
      probe,
      providerIndex,
      releaseSibling,
      permissionReply,
      siblingReply,
    );
  }

  Future<_BlockedBatchProbe> sendBlockedBatch({
    required _BlockedOutcome outcome,
    required bool ownerScoped,
  }) async {
    final method = switch (outcome) {
      _BlockedOutcome.requestSelected ||
      _BlockedOutcome.requestCancelled => 'session/request_permission',
      _BlockedOutcome.terminalSuccess ||
      _BlockedOutcome.terminalDenied => 'terminal/create',
      _ => 'fs/read_text_file',
    };
    final owner = ownerScoped
        ? base.manager.beginPromptTurn(base.sessionId)
        : null;
    final probe = await _send(method: method, owner: owner);
    await base.permissions
        .waitForRequest(probe.providerIndex)
        .timeout(const Duration(seconds: 2));
    switch (outcome) {
      case _BlockedOutcome.requestSelected:
      case _BlockedOutcome.fsSuccess:
      case _BlockedOutcome.terminalSuccess:
        base.permissions.completeAllow(probe.providerIndex);
        break;
      case _BlockedOutcome.requestCancelled:
        base.permissions.completeDecision(
          probe.providerIndex,
          const acp.PermissionDecision.cancelled(),
        );
        break;
      case _BlockedOutcome.fsDenied:
      case _BlockedOutcome.terminalDenied:
        base.permissions.completeDecision(
          probe.providerIndex,
          const acp.PermissionDecision.deny(),
        );
        break;
      case _BlockedOutcome.rpcException:
        base.permissions.completeError(
          probe.providerIndex,
          rpc.RpcException(-32001, 'Fixed test rejection.'),
        );
        break;
      case _BlockedOutcome.handlerError:
        base.permissions.completeError(
          probe.providerIndex,
          StateError('fixed handler error'),
        );
        break;
    }
    return probe;
  }

  Future<_BlockedBatchProbe> sendCancelledPermissionWithBlockedSibling({
    required bool ownerScoped,
    required acp.PermissionCancellationReason reason,
  }) async {
    final owner = ownerScoped
        ? base.manager.beginPromptTurn(base.sessionId)
        : null;
    return _send(
      method: 'fs/read_text_file',
      owner: owner,
      reason: ownerScoped ? reason : null,
    );
  }

  Future<_BlockedBatchProbe> blockResponseCommit({
    acp.AcpSessionInputBudgetOwner? owner,
  }) async {
    final probe = await _send(
      method: 'session/request_permission',
      owner: owner,
    );
    await base.permissions
        .waitForRequest(probe.providerIndex)
        .timeout(const Duration(seconds: 2));
    base.permissions.completeDecision(
      probe.providerIndex,
      const acp.PermissionDecision.cancelled(),
    );
    await probe.permissionReservationReleased.timeout(
      const Duration(seconds: 2),
    );
    return probe;
  }

  Future<void> dispose() => base.dispose();
}

enum _LateCause { close, dispose }

enum _ReleaseFailure { none, synchronous, asynchronous }

final class _LateTerminalHarness {
  _LateTerminalHarness._(this.base, this.events);

  final _PermissionAdmissionHarness base;
  final List<acp.TerminalEvent> events;
  final List<acp.TerminalProcessHandle> _lateHandles =
      <acp.TerminalProcessHandle>[];
  late final StreamSubscription<acp.TerminalEvent> _eventsSubscription;
  Future<dynamic>? _createReply;
  _PermissionRequestProbe? _createProbe;
  Future<void>? _peerClosing;

  static Future<_LateTerminalHarness> start({
    bool releaseThrows = false,
    bool releaseThrowsSynchronously = false,
    int maxOrdinaryConcurrentHandlers = 1,
  }) async {
    final base = await _PermissionAdmissionHarness.start(
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    );
    base.terminals
      ..releaseThrows = releaseThrows
      ..releaseThrowsSynchronously = releaseThrowsSynchronously
      ..createResult = Completer<acp.TerminalProcessHandle>();
    final harness = _LateTerminalHarness._(base, <acp.TerminalEvent>[]);
    harness._eventsSubscription = base.manager.terminalEvents.listen(
      harness.events.add,
    );
    return harness;
  }

  SessionManager get manager => base.manager;
  Completer<void> get createStarted => base.terminals.createStarted;
  Completer<void> get releaseCompleted => base.terminals.releaseCompleted;
  int get releaseCalls => base.terminals.releaseCalls;
  int get registeredTerminalCount =>
      base.manager.managedTerminalCountForTesting;
  Iterable<acp.TerminalCreated> get terminalCreatedEvents =>
      events.whereType<acp.TerminalCreated>();
  int get pendingLeaseCount => base.manager.pendingTerminalLeaseCountForTesting;
  int get totalLeaseCount => base.manager.terminalLeaseCountForTesting;
  _PermissionRequestProbe get createProbe => _createProbe!;
  Object? get sessionGeneration =>
      base.manager.sessionGenerationForTesting(base.sessionId);

  Future<dynamic> createTerminal() {
    final existing = _createReply;
    if (existing != null) return existing;
    final operation = () async {
      final probe = await base.admit('terminal/create');
      _createProbe = probe;
      await base.permissions
          .waitForRequest(0)
          .timeout(const Duration(seconds: 2));
      base.permissions.completeAllow(0);
      await probe.handlerStarted.future.timeout(const Duration(seconds: 2));
      return probe.handlerOperation!;
    }();
    _createReply = operation;
    return operation;
  }

  Future<void> invalidate(_LateCause cause) async {
    switch (cause) {
      case _LateCause.close:
        final unavailable = Completer<void>();
        void observe(AcpPeerUnavailableState _) {
          if (!unavailable.isCompleted) unavailable.complete();
        }
        base.peer.addUnavailableListener(observe);
        final closing = base.peer.closeForTesting(
          AcpPeerUnavailableReason.explicitClose,
        );
        _peerClosing = closing;
        unawaited(closing.catchError((Object _) {}));
        await unavailable.future.timeout(const Duration(seconds: 2));
        base.peer.removeUnavailableListener(observe);
        break;
      case _LateCause.dispose:
        await base.manager.dispose();
        break;
    }
  }

  Future<acp.TerminalProcessHandle> completeCreateHandle() async {
    final handle = await base.terminals.createLateHandle(base.sessionId);
    _lateHandles.add(handle);
    base.terminals.createResult!.complete(handle);
    return handle;
  }

  void completeCreateError(Object error) {
    base.terminals.createResult!.completeError(error);
  }

  Future<void> closeAndReopenSameSession() async {
    await base.manager.closeSession(sessionId: base.sessionId);
    await base.manager.resumeSession(
      sessionId: base.sessionId,
      workspaceRoot: '/tmp',
    );
  }

  Future<void> waitForPeerClose() async {
    final closing = _peerClosing;
    if (closing != null) {
      await closing.timeout(const Duration(seconds: 2));
    }
  }

  Future<_RpcReply> createAndReleaseReplacementTerminal() async {
    base.terminals.createResult = null;
    final providerIndex = base.permissions.requests.length;
    final probe = await base.admit('terminal/create');
    await base.permissions
        .waitForRequest(providerIndex)
        .timeout(const Duration(seconds: 2));
    base.permissions.completeAllow(providerIndex);
    final reply = await probe.response.timeout(const Duration(seconds: 2));
    final result = reply.result! as Map<String, dynamic>;
    await base.manager.releaseTerminal(result['terminalId']! as String);
    return reply;
  }

  Future<void> dispose() async {
    final pendingCreate = base.terminals.createResult;
    if (pendingCreate != null && !pendingCreate.isCompleted) {
      pendingCreate.completeError(StateError('fixed late terminal cleanup'));
      await pumpEventQueue();
    }
    await _eventsSubscription.cancel();
    await base.dispose();
    for (final handle in _lateHandles) {
      try {
        await base.terminals._inner.release(handle);
      } on Object {
        // Test cleanup is best-effort after release behavior was asserted.
      }
      await handle.process.exitCode.timeout(const Duration(seconds: 2));
    }
  }
}

enum _PromptRaceTerminal { response, remoteError, deadline, userCancel }

final class _PromptManagerDriver {
  _PromptManagerDriver(this.core);

  final SessionManager core;
  acp.AcpSessionInputBudgetOwner? activeOwner;

  acp.AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) =>
      activeOwner = core.beginPromptTurn(sessionId);

  void endPromptTurn(acp.AcpSessionInputBudgetOwner owner) =>
      core.endPromptTurn(owner);

  Future<void> cancelPromptTurn(acp.AcpSessionInputBudgetOwner owner) =>
      core.cancelPromptTurn(owner);

  Future<void> closeSession({required String sessionId}) =>
      core.closeSession(sessionId: sessionId);

  Future<Map<String, dynamic>> sendPromptRequest({
    required acp.AcpSessionInputBudgetOwner owner,
    required List<Map<String, dynamic>> content,
  }) => core.sendPromptRequest(owner: owner, content: content);

  Stream<acp.AcpUpdate> prompt({
    required String sessionId,
    required List<Map<String, dynamic>> content,
  }) => core.prompt(sessionId: sessionId, content: content);
}

final class _PromptPublicTransport implements acp.AcpTransport {
  final StreamChannelController<String> controller =
      StreamChannelController<String>();

  @override
  StreamChannel<String> get channel => controller.foreign;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() => controller.local.sink.close();
}

final class _PromptPublicClientFixture {
  _PromptPublicClientFixture._(this.client, this.transport, this.subscription);

  final acp.AcpClient client;
  final _PromptPublicTransport transport;
  final StreamSubscription<String> subscription;
  final Completer<void> promptSeen = Completer<void>();
  Object? promptId;
  int promptWireCount = 0;

  static Future<_PromptPublicClientFixture> start() async {
    final transport = _PromptPublicTransport();
    late final _PromptPublicClientFixture fixture;
    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(timeouts: const acp.AcpTimeouts()),
      transport: transport,
    );
    final subscription = transport.controller.local.stream.listen((line) {
      final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final method = message['method'];
      if (method == 'session/resume' || method == 'session/close') {
        transport.controller.local.sink.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': message['id'],
            'result': <String, dynamic>{},
          }),
        );
      } else if (method == 'session/prompt') {
        fixture.promptId = message['id'];
        fixture.promptWireCount += 1;
        if (!fixture.promptSeen.isCompleted) fixture.promptSeen.complete();
      }
    });
    fixture = _PromptPublicClientFixture._(client, transport, subscription);
    await client.resumeSession(
      sessionId: 'public-prompt-session',
      workspaceRoot: '/tmp',
    );
    return fixture;
  }

  Future<acp.AcpSessionInputBudgetOwner> createStaleOwner() async {
    final stale = client.beginPromptTurn('public-prompt-session');
    client.endPromptTurn(stale);
    await client.closeSession(sessionId: 'public-prompt-session');
    await client.resumeSession(
      sessionId: 'public-prompt-session',
      workspaceRoot: '/tmp',
    );
    return stale;
  }

  Future<acp.AcpSessionInputBudgetOwner> createOtherSessionOwner() async {
    const otherSessionId = 'public-other-session';
    await client.resumeSession(
      sessionId: otherSessionId,
      workspaceRoot: '/tmp',
    );
    final owner = client.beginPromptTurn(otherSessionId);
    client.endPromptTurn(owner);
    return owner;
  }

  void respondSuccess() {
    transport.controller.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': promptId,
        'result': <String, dynamic>{'stopReason': 'end_turn'},
      }),
    );
  }

  Future<void> dispose() async {
    await client.dispose();
    await subscription.cancel();
  }
}

final class _PromptOperationProbe {
  _PromptOperationProbe({
    required this.harness,
    required this.owner,
    required this.result,
    required this.promptSeen,
  }) : admissionBarrier = harness.base.manager
           .promptAdmissionsSettledForTesting(owner);

  final _PromptLifecycleHarness harness;
  final acp.AcpSessionInputBudgetOwner owner;
  final Future<Map<String, dynamic>> result;
  final Completer<void> promptSeen;
  final Future<void> admissionBarrier;
  final Completer<void> admissionStarted = Completer<void>();
  final Completer<void> admissionReservationReleased = Completer<void>();
  _PermissionRequestProbe? admission;
  Completer<void>? responseCommitBlocker;

  PromptLifecycleSnapshot get lifecycle =>
      harness.base.manager.promptLifecycleSnapshotForTesting(owner);

  JsonRpcPromptTerminalKind? get terminalKind => lifecycle.winner?.kind;
  AcpPromptCleanupIdentity? get unavailableCleanupIdentity =>
      lifecycle.cleanupIdentity;
  bool get terminalRecorded =>
      lifecycle.winner != null || lifecycle.cancellationWinner != null;

  acp.PermissionCancellationReason? get permissionReason =>
      harness.base.permissions.cancellations.isEmpty
      ? null
      : harness.base.permissions.cancellations.last.$2;

  int get cancelWireCount => harness.cancelWireCount;
  int get cleanupWindowStartCount =>
      harness.base.manager.admissionCleanupWindowStartCountForTesting;

  Future<Map<String, dynamic>> get promptResult async {
    try {
      return await result;
    } finally {
      harness.manager.endPromptTurn(owner);
    }
  }

  Future<void> commitAdmissionResponse() async {
    final blocker = responseCommitBlocker;
    if (blocker != null && !blocker.isCompleted) blocker.complete();
    await admission?.responseCommitted.future;
  }

  Future<void> finishPromptAndAdmission() => harness.finishPromptRace(this);
}

final class _UnavailablePromptHarness {
  _UnavailablePromptHarness({
    required this.client,
    required this.transport,
    required this.peer,
    required this.manager,
    required this.outboundSubscription,
  });

  final acp.AcpClient client;
  final _PromptPublicTransport transport;
  final JsonRpcPeer peer;
  final SessionManager manager;
  final StreamSubscription<String> outboundSubscription;
  final String sessionId = 'unavailable-prompt-session';
  int promptWireCount = 0;

  Future<void> dispose() async {
    await client.dispose();
    await outboundSubscription.cancel();
  }
}

class _PromptLifecycleHarness {
  _PromptLifecycleHarness._(
    this.base,
    this.foreignBase,
    this.publicFixture,
    this.publicStaleOwner,
  ) : manager = _PromptManagerDriver(base.manager);

  static Future<_PromptLifecycleHarness> start({
    Duration prompt = const Duration(seconds: 2),
    Duration grace = const Duration(milliseconds: 100),
    int maxOrdinaryConcurrentHandlers = 1,
    bool synchronousChannel = false,
  }) async {
    final base = await _PermissionAdmissionHarness.start(
      timeouts: acp.AcpTimeouts(prompt: prompt, promptCancelGrace: grace),
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
      synchronousChannel: synchronousChannel,
      controlFutureSetups: synchronousChannel,
      registerInitialSession: !synchronousChannel,
    );
    if (synchronousChannel) {
      final resume = base.manager.resumeSession(
        sessionId: base.sessionId,
        workspaceRoot: '/tmp',
      );
      await base.waitForSetupRequest(0).timeout(const Duration(seconds: 2));
      base.completeSetupSuccess(0);
      await resume.timeout(const Duration(seconds: 2));
    }
    final foreign = await _PermissionAdmissionHarness.start();
    final publicFixture = await _PromptPublicClientFixture.start();
    final publicStaleOwner = await publicFixture.createStaleOwner();
    final harness = _PromptLifecycleHarness._(
      base,
      foreign,
      publicFixture,
      publicStaleOwner,
    );
    harness._listen();
    harness._foreignOwner = foreign.manager.beginPromptTurn(foreign.sessionId);
    return harness;
  }

  static Future<_UnavailablePromptHarness> startWithUnavailablePeer() async {
    final transport = _PromptPublicTransport();
    late JsonRpcPeer closedPeer;
    late SessionManager replayedManager;
    final client = await acp.AcpClient.start(
      config: acp.AcpConfig(timeouts: const acp.AcpTimeouts()),
      transport: transport,
      beforeSessionManagerForTesting: (peer) {
        closedPeer = peer;
        unawaited(peer.closeForTesting(AcpPeerUnavailableReason.explicitClose));
      },
      afterSessionManagerForTesting: (peer, manager) {
        expect(peer, same(closedPeer));
        replayedManager = manager;
      },
    );
    late final _UnavailablePromptHarness harness;
    final outbound = transport.controller.local.stream.listen((line) {
      final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
      if (message['method'] == 'session/prompt') {
        harness.promptWireCount += 1;
      }
    });
    harness = _UnavailablePromptHarness(
      client: client,
      transport: transport,
      peer: closedPeer,
      manager: replayedManager,
      outboundSubscription: outbound,
    );
    return harness;
  }

  final _PermissionAdmissionHarness base;
  final _PermissionAdmissionHarness foreignBase;
  final _PromptPublicClientFixture publicFixture;
  final acp.AcpSessionInputBudgetOwner publicStaleOwner;
  final _PromptManagerDriver manager;
  JsonRpcPeer get peer => base.peer;
  String get sessionId => base.sessionId;
  final Completer<void> promptSeen = Completer<void>();
  late final acp.AcpSessionInputBudgetOwner _foreignOwner;
  StreamSubscription<Map<String, dynamic>>? _wire;
  Object? _promptRequestId;
  _PromptOperationProbe? _current;
  int promptWireCount = 0;
  int cancelWireCount = 0;
  int rawPromptCalls = 0;
  bool _promptResponded = false;

  acp.AcpSessionInputBudgetOwner get activeOwner => manager.activeOwner!;
  acp.AcpSessionInputBudgetOwner foreignManagerOwner() => _foreignOwner;
  acp.AcpClient get publicClient => publicFixture.client;
  int get publicPromptWireCount => publicFixture.promptWireCount;
  Future<void> get publicPromptSeen => publicFixture.promptSeen.future;
  void respondPublicPromptSuccess() => publicFixture.respondSuccess();
  void failNextCancelSubmission() => peer.failNextCancelSubmissionForTesting();

  void _listen() {
    _wire = base.wireRequests.stream.listen((message) {
      switch (message['method']) {
        case 'session/prompt':
          promptWireCount += 1;
          _promptRequestId = message['id'];
          final activeOwner = base.manager.activePromptOwnerForTesting(
            sessionId,
          );
          _current ??= _PromptOperationProbe(
            harness: this,
            owner: activeOwner,
            result: base.manager.promptResultForTesting(activeOwner),
            promptSeen: Completer<void>(),
          );
          if (!promptSeen.isCompleted) promptSeen.complete();
          final operation = _current!;
          if (!operation.promptSeen.isCompleted) {
            operation.promptSeen.complete();
          }
          break;
        case 'session/cancel':
          cancelWireCount += 1;
          break;
      }
    });
  }

  Future<_PromptOperationProbe> _startPrompt() async {
    final owner = manager.beginPromptTurn(sessionId);
    final seen = Completer<void>();
    final result = manager.sendPromptRequest(
      owner: owner,
      content: const <Map<String, dynamic>>[],
    );
    unawaited(result.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    final operation = _PromptOperationProbe(
      harness: this,
      owner: owner,
      result: result,
      promptSeen: seen,
    );
    _current = operation;
    if (promptSeen.isCompleted) seen.complete();
    await seen.future.timeout(const Duration(seconds: 2));
    return operation;
  }

  Future<_PermissionRequestProbe> _startBlockedAdmission(
    _PromptOperationProbe operation, {
    bool running = true,
    String method = 'fs/read_text_file',
  }) async {
    if (!running) await base.occupyAllOrdinaryPermits();
    final releaseSibling = Completer<void>();
    operation.responseCommitBlocker = releaseSibling;
    base.peer.onTerminalOutput = (_) async {
      await releaseSibling.future;
      return <String, dynamic>{'output': '', 'truncated': false};
    };
    final permissionId = base._nextId++;
    final siblingId = base._nextId++;
    final permissionReply = Completer<_RpcReply>();
    final siblingReply = Completer<_RpcReply>();
    final admission = _PermissionRequestProbe(permissionId, permissionReply);
    final providerIndex = base.permissions.requests.length;
    base._responses[permissionId] = permissionReply;
    base._responses[siblingId] = siblingReply;
    base._admissionQueue.add(admission);
    base.channel.local.sink.add(
      jsonEncode(<Object?>[
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': permissionId,
          'method': method,
          'params': base.paramsFor(method),
        },
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': siblingId,
          'method': 'terminal/output',
          'params': <String, dynamic>{'sessionId': sessionId},
        },
      ]),
    );
    await admission.admissionSeen.future;
    operation.admission = admission;
    admission.reservationReleased.future.then<void>((_) {
      if (!operation.admissionReservationReleased.isCompleted) {
        operation.admissionReservationReleased.complete();
      }
    });
    if (running) await base.permissions.waitForRequest(providerIndex);
    if (!operation.admissionStarted.isCompleted) {
      operation.admissionStarted.complete();
    }
    return admission;
  }

  Future<
    ({_PermissionRequestProbe admission, Completer<void> releaseResponseCommit})
  >
  startSealedAdmissionWithBlockedResponseCommit() async {
    final releaseResponseCommit = Completer<void>();
    base.peer.onTerminalOutput = (_) async {
      await releaseResponseCommit.future;
      return <String, dynamic>{'output': '', 'truncated': false};
    };
    final permissionId = base._nextId++;
    final siblingId = base._nextId++;
    final permissionReply = Completer<_RpcReply>();
    final admission = _PermissionRequestProbe(permissionId, permissionReply);
    base._responses[permissionId] = permissionReply;
    base._admissionQueue.add(admission);
    base.channel.local.sink.add(
      jsonEncode(<Object?>[
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': permissionId,
          'method': 'fs/read_text_file',
          'params': base.paramsFor('fs/read_text_file'),
        },
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': siblingId,
          'method': 'terminal/output',
          'params': <String, dynamic>{'sessionId': sessionId},
        },
      ]),
    );
    await admission.admissionSeen.future.timeout(const Duration(seconds: 2));
    return (admission: admission, releaseResponseCommit: releaseResponseCommit);
  }

  Future<_PromptOperationProbe> startPromptWithBlockedAdmissionCommit() async {
    final operation = await _startPrompt();
    await _startBlockedAdmission(operation);
    base.permissions.completeAllow(base.permissions.pending.length - 1);
    return operation;
  }

  Future<_PromptOperationProbe> startPromptWithRunningAdmission() async {
    final operation = await _startPrompt();
    await _startBlockedAdmission(operation);
    return operation;
  }

  Future<_PromptOperationProbe> startPromptWithAdmission({
    required bool running,
  }) async {
    final operation = await _startPrompt();
    await _startBlockedAdmission(operation, running: running);
    return operation;
  }

  void respondPromptSuccess({String stopReason = 'end_turn'}) {
    if (_promptResponded) return;
    if (_promptRequestId == null) {
      throw StateError('prompt request was not observed');
    }
    _promptResponded = true;
    base.channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': _promptRequestId,
        'result': <String, dynamic>{'stopReason': stopReason},
      }),
    );
  }

  void respondPromptError({required int code, required String message}) {
    if (_promptResponded || _promptRequestId == null) return;
    _promptResponded = true;
    base.channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': _promptRequestId,
        'error': <String, dynamic>{'code': code, 'message': message},
      }),
    );
  }

  void respondPromptMalformed() {
    if (_promptResponded || _promptRequestId == null) return;
    _promptResponded = true;
    base.channel.local.sink.add(
      jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': _promptRequestId,
        'result': <Object?>['not-an-object'],
      }),
    );
  }

  Future<void> recordPromptWinner(
    _PromptOperationProbe operation,
    _PromptRaceTerminal terminal, {
    required bool expectAccepted,
  }) async {
    switch (terminal) {
      case _PromptRaceTerminal.response:
        respondPromptSuccess();
        break;
      case _PromptRaceTerminal.remoteError:
        respondPromptError(code: -32000, message: 'fixed prompt error');
        break;
      case _PromptRaceTerminal.deadline:
        base.peer.firePromptDeadlineForTesting(operation.owner);
        break;
      case _PromptRaceTerminal.userCancel:
        if (expectAccepted) {
          await manager.cancelPromptTurn(operation.owner);
        } else {
          await expectLater(
            manager.cancelPromptTurn(operation.owner),
            throwsStateError,
          );
        }
        return;
    }
    if (expectAccepted) {
      await base.manager
          .promptWinnerRecordedForTesting(operation.owner)
          .timeout(const Duration(seconds: 2));
      await base.manager
          .promptRightRecordedForTesting(operation.owner)
          .timeout(const Duration(seconds: 2));
    } else {
      await pumpEventQueue();
    }
  }

  Future<void> finishPromptRace(_PromptOperationProbe operation) async {
    base.permissions.finishPending();
    base.releaseOrdinaryPermits();
    final blocker = operation.responseCommitBlocker;
    if (blocker != null && !blocker.isCompleted) blocker.complete();
    respondPromptSuccess();
    final admission = operation.admission;
    if (admission != null) {
      await admission.settled.timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError('prompt admission did not settle'),
      );
    }
    await operation.admissionBarrier.timeout(
      const Duration(seconds: 2),
      onTimeout: () => throw StateError('prompt admission barrier stuck'),
    );
    await operation.result
        .then<void>((_) {}, onError: (_, _) {})
        .timeout(
          const Duration(seconds: 2),
          onTimeout: () => throw StateError('prompt result did not settle'),
        );
  }

  Future<void> assertOldSessionUpdateIsDropped() async {
    base.peer.pauseNextSessionUpdateForTesting();
    base.peer.dispatchSessionUpdateForTesting(<String, dynamic>{
      'sessionId': sessionId,
      'update': <String, dynamic>{
        'sessionUpdate': 'current_mode_update',
        'currentModeId': 'stale-mode',
      },
    });
    await base.peer.pausedSessionUpdateCapturedForTesting;
    await base.manager.closeSession(sessionId: sessionId);
    await base.manager.resumeSession(
      sessionId: sessionId,
      workspaceRoot: '/tmp',
    );
    final received = <acp.AcpUpdate>[];
    final subscription = base.manager
        .sessionUpdates(sessionId)
        .listen(received.add);
    base.peer.releasePausedSessionUpdateForTesting();
    await pumpEventQueue();
    expect(received, isEmpty);
    await subscription.cancel();
  }

  Future<void> dispose() async {
    await _wire?.cancel();
    await publicFixture.dispose();
    await foreignBase.dispose();
    await base.dispose();
  }
}

void _expectPromptHarnessDrained(_PromptLifecycleHarness harness) {
  expect(harness.peer.promptOwnerOperationCountForTesting, 0);
  expect(harness.peer.promptSessionOperationCountForTesting, 0);
  expect(harness.base.manager.promptLifecycleCountForTesting, 0);
  expect(harness.base.manager.activeTypedPromptTurnCountForTesting, 0);
  expect(harness.base.manager.inboundAdmissionCountForTesting, 0);
  expect(harness.base.manager.ownerAdmissionBucketCountForTesting, 0);
  expect(harness.base.manager.admissionCleanupWindowCountForTesting, 0);
  expect(harness.base.manager.ownerCleanupActiveTimerCountForTesting, 0);
  expect(harness.base.manager.settlingPromptOwnerCountForTesting, 0);
  expect(harness.base.manager.settlingPromptReasonCountForTesting, 0);
}

Future<void> _expectPromptAndAdmissionShareCleanupWindow(
  _PromptLifecycleHarness harness,
  _PromptOperationProbe operation,
) async {
  await operation.admissionReservationReleased.future.timeout(
    const Duration(seconds: 2),
  );
  final observed = operation.admission!.admission! as _ObservedAdmission;
  final promptIdentity = harness.base.manager
      .promptCleanupWindowIdentityForTesting(operation.owner);
  final admissionIdentity = harness.base.manager
      .admissionCleanupWindowIdentityForTesting(observed.inner);
  expect(promptIdentity, isNotNull);
  expect(admissionIdentity, isNotNull);
  expect(identical(promptIdentity, admissionIdentity), isTrue);

  final lifecycleReaped = harness.base.manager.promptCleanupReapedForTesting(
    operation.owner,
  );
  final promptWindowReaped = harness.base.manager
      .ownerCleanupWindowReapedForTesting(promptIdentity!);
  final admissionWindowReaped = harness.base.manager
      .ownerCleanupWindowReapedForTesting(admissionIdentity!);
  expect(lifecycleReaped, isNotNull);
  expect(identical(lifecycleReaped, promptWindowReaped), isTrue);
  expect(identical(promptWindowReaped, admissionWindowReaped), isTrue);

  final promptDeadline = harness.base.manager
      .ownerCleanupWindowDeadlineForTesting(promptIdentity);
  final admissionDeadline = harness.base.manager
      .ownerCleanupWindowDeadlineForTesting(admissionIdentity);
  expect(promptDeadline, admissionDeadline);
}

Future<void> _expectSealedPromptAdmissionRejected(
  _PromptLifecycleHarness harness,
  _PromptOperationProbe operation,
) async {
  final manager = harness.base.manager;
  final barrier = manager.promptAdmissionsSettledForTesting(operation.owner);
  final windowStartsBefore = manager.admissionCleanupWindowStartCountForTesting;
  final providerRequestsBefore = harness.base.permissions.requests.length;
  final providerCancellationsBefore =
      harness.base.permissions.cancellations.length;
  final sideEffectsBefore = harness.base.fs.readCalls;

  final blocked = await harness.startSealedAdmissionWithBlockedResponseCommit();
  final late = blocked.admission;
  final observed = late.admission! as _ObservedAdmission;
  final ownerBucketsAtAdmission = manager.ownerAdmissionBucketCountForTesting;
  await late.reservationReleased.future.timeout(const Duration(seconds: 2));
  final lateWindow = manager.admissionCleanupWindowIdentityForTesting(
    observed.inner,
  );
  expect(lateWindow, isNotNull);
  expect(manager.ownerCleanupWindowFatalOwnerForTesting(lateWindow!), isNull);
  expect(manager.ownerCleanupWindowBlockerCountForTesting(lateWindow), 1);
  expect(
    manager.admissionCleanupWindowTimerActiveProbeForTesting(lateWindow)(),
    isTrue,
  );
  expect(
    manager.admissionCleanupWindowStartCountForTesting,
    windowStartsBefore + 1,
  );
  expect(manager.admissionCleanupWindowCountForTesting, 1);
  blocked.releaseResponseCommit.complete();
  final reply = await late.response.timeout(const Duration(seconds: 2));
  await late.settled.timeout(const Duration(seconds: 2));

  expect(reply.errorCode, -32003);
  expect(reply.errorMessage, 'Permission request cancelled.');
  expect(ownerBucketsAtAdmission, 0);
  expect(
    manager.admissionCleanupWindowStartCountForTesting,
    windowStartsBefore + 1,
  );
  expect(manager.admissionCleanupWindowCountForTesting, 0);
  expect(manager.ownerAdmissionBucketCountForTesting, 0);
  expect(manager.inboundAdmissionCountForTesting, 0);
  expect(
    identical(
      manager.promptAdmissionsSettledForTesting(operation.owner),
      barrier,
    ),
    isTrue,
  );
  expect(harness.base.permissions.requests.length, providerRequestsBefore);
  expect(
    harness.base.permissions.cancellations.length,
    providerCancellationsBefore + 1,
  );
  expect(
    harness.base.permissions.cancellations.last.$2,
    operation.lifecycle.cancellationWinner,
  );
  expect(harness.base.fs.readCalls, sideEffectsBefore);
  expect(manager.promptLifecycleIsCurrentForTesting(operation.owner), isTrue);
}

const permissionEntries = <_PermissionEntryCase>[
  _PermissionEntryCase(
    method: 'session/request_permission',
    timeoutCode: null,
    cancelledCode: null,
  ),
  _PermissionEntryCase(
    method: 'fs/read_text_file',
    timeoutCode: -32002,
    cancelledCode: -32003,
  ),
  _PermissionEntryCase(
    method: 'fs/write_text_file',
    timeoutCode: -32002,
    cancelledCode: -32003,
  ),
  _PermissionEntryCase(
    method: 'terminal/create',
    timeoutCode: -32002,
    cancelledCode: -32003,
  ),
];

const localReasons = <acp.PermissionCancellationReason>[
  acp.PermissionCancellationReason.promptEnded,
  acp.PermissionCancellationReason.promptCancelled,
  acp.PermissionCancellationReason.sessionClosed,
];

final class _PermissionEntryCase {
  const _PermissionEntryCase({
    required this.method,
    required this.timeoutCode,
    required this.cancelledCode,
  });

  final String method;
  final int? timeoutCode;
  final int? cancelledCode;
}

final class _RequestHarness {
  _RequestHarness(acp.AcpTimeouts timeouts) {
    sink = _CountingStringSink(outputController.sink);
    peer = JsonRpcPeer(
      StreamChannel<String>(input.stream, sink),
      timeouts: timeouts,
    );
    outbound = StreamIterator<String>(outputController.stream);
  }

  final StreamController<String> input = StreamController<String>(sync: true);
  final StreamController<String> outputController = StreamController<String>(
    sync: true,
  );
  late final _CountingStringSink sink;
  late final JsonRpcPeer peer;
  late final StreamIterator<String> outbound;

  Future<Map<String, dynamic>> takeRequest() async {
    expect(
      await outbound.moveNext().timeout(const Duration(seconds: 2)),
      isTrue,
    );
    return jsonDecode(outbound.current) as Map<String, dynamic>;
  }

  void respond(Object? id, Object? result) => input.add(
    jsonEncode(<String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result}),
  );

  void respondError(Object? id, {required int code, required String message}) =>
      input.add(
        jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': id,
          'error': <String, dynamic>{'code': code, 'message': message},
        }),
      );

  Future<void> dispose() async {
    await peer.close();
    await outbound.cancel();
    await input.close();
    await outputController.close();
  }
}

final class _CountingStringSink implements StreamSink<String> {
  _CountingStringSink(this.delegate);

  final StreamSink<String> delegate;
  final List<String> events = <String>[];
  var closeCount = 0;

  @override
  Future<void> get done => delegate.done;

  @override
  void add(String event) {
    events.add(event);
    delegate.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => delegate.addStream(stream);

  @override
  Future<void> close() {
    closeCount += 1;
    return delegate.close();
  }
}

final class _ReentrantInputStream extends Stream<String> {
  _ReentrantInputSubscription? _subscription;

  void add(String value) => _subscription!.add(value);

  void addError(Object error, StackTrace stackTrace) =>
      _subscription!.addError(error, stackTrace);

  void close() => _subscription?.close();

  @override
  StreamSubscription<String> listen(
    void Function(String event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_subscription != null) {
      throw StateError('Reentrant input stream supports one listener.');
    }
    return _subscription = _ReentrantInputSubscription(onData, onError, onDone);
  }
}

final class _ReentrantInputSubscription implements StreamSubscription<String> {
  _ReentrantInputSubscription(this._onData, this._onError, this._onDone);

  void Function(String event)? _onData;
  Function? _onError;
  void Function()? _onDone;
  var _cancelled = false;
  var _paused = false;

  void add(String value) {
    if (!_cancelled && !_paused) _onData?.call(value);
  }

  void addError(Object error, StackTrace stackTrace) {
    if (_cancelled) return;
    final handler = _onError;
    if (handler is void Function(Object, StackTrace)) {
      handler(error, stackTrace);
    } else if (handler is void Function(Object)) {
      handler(error);
    }
  }

  void close() {
    if (_cancelled) return;
    _cancelled = true;
    _onDone?.call();
  }

  @override
  Future<void> cancel() async {
    _cancelled = true;
  }

  @override
  void onData(void Function(String data)? handleData) {
    _onData = handleData;
  }

  @override
  void onError(Function? handleError) {
    _onError = handleError;
  }

  @override
  void onDone(void Function()? handleDone) {
    _onDone = handleDone;
  }

  @override
  void pause([Future<void>? resumeSignal]) {
    _paused = true;
    resumeSignal?.whenComplete(resume);
  }

  @override
  void resume() {
    _paused = false;
  }

  @override
  bool get isPaused => _paused;

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue as E);
}

final class _ReentrantTransportError extends Error {}

final class _TestPromptOwner implements JsonRpcPromptOwner {
  const _TestPromptOwner(this.sessionId, this.generation);

  @override
  final String sessionId;

  @override
  final int generation;
}

final class _StartCountingTransport implements acp.AcpTransport {
  final StreamController<String> _input = StreamController<String>(sync: true);
  final StreamController<String> _output = StreamController<String>(sync: true);
  var startCount = 0;
  var stopCount = 0;

  @override
  StreamChannel<String> get channel =>
      StreamChannel<String>(_input.stream, _output.sink);

  @override
  Future<void> start() async {
    startCount += 1;
  }

  @override
  Future<void> stop() async {
    stopCount += 1;
  }

  Future<void> dispose() async {
    final inputDone = _input.hasListener ? null : _input.stream.drain<void>();
    final outputDone = _output.hasListener
        ? null
        : _output.stream.drain<void>();
    await _input.close();
    await _output.close();
    await inputDone;
    await outputDone;
  }
}

final class _SecondValidationFailsTimeouts extends acp.AcpTimeouts {
  var validationCount = 0;

  @override
  void validate() {
    validationCount += 1;
    if (validationCount == 2) {
      throw ArgumentError('second validation');
    }
  }
}

final class _SecretToken {
  @override
  String toString() => 'TOKEN-CANARY';
}

void main() {
  test('permission harness preserves two reserved control slots', () async {
    for (final ordinary in <int>[1, 2]) {
      final harness = await _PermissionAdmissionHarness.start(
        maxOrdinaryConcurrentHandlers: ordinary,
      );
      try {
        expect(harness.peer.isAvailable, isTrue);
      } finally {
        await harness.dispose();
      }
    }
  });

  test('blocked permission batch outcomes start one response grace', () async {
    const outcomes = <_BlockedOutcome>[
      _BlockedOutcome.requestSelected,
      _BlockedOutcome.requestCancelled,
      _BlockedOutcome.fsSuccess,
      _BlockedOutcome.fsDenied,
      _BlockedOutcome.terminalSuccess,
      _BlockedOutcome.terminalDenied,
      _BlockedOutcome.rpcException,
      _BlockedOutcome.handlerError,
    ];
    for (final outcome in outcomes) {
      for (final ownerScoped in <bool>[false, true]) {
        final harness = await _PermissionBatchHarness.start(
          promptCancelGrace: const Duration(milliseconds: 75),
        );
        try {
          final batch = await harness.sendBlockedBatch(
            outcome: outcome,
            ownerScoped: ownerScoped,
          );
          await batch.permissionReservationReleased.timeout(
            const Duration(seconds: 2),
          );
          final expiredWindowIdentity = batch.cleanupWindowIdentity;
          expect(expiredWindowIdentity, isNotNull);
          expect(batch.responseCommitted, isFalse);
          expect(batch.permissionResponseCompleted, isFalse);
          expect(batch.siblingResponseCompleted, isFalse);
          expect(batch.wireResponses, isEmpty);
          final unavailable = await batch.peerUnavailable.future.timeout(
            const Duration(seconds: 2),
          );
          expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
          final cleanupIdentity = unavailable.cleanupIdentity;
          if (ownerScoped) {
            expect(cleanupIdentity, isNotNull);
            expect(identical(cleanupIdentity!.ownerToken, batch.owner), isTrue);
            expect(cleanupIdentity.generation, batch.owner!.generation);
          } else {
            expect(cleanupIdentity, isNull);
          }
          await batch.cleanupReaped.timeout(const Duration(seconds: 2));
          expect(batch.fatalCloseCount, 1);
          expect(batch.cleanupExpiryCallbackCount, 1);
          expect(batch.gatePendingItems, 0);
          expect(batch.correlationPendingItems, 0);
          expect(batch.admissionCount, 0);
          expect(batch.cleanupWindowCount, 0);
          expect(batch.wireResponses, isEmpty);
          batch.fireCapturedTimerCallback();
          await pumpEventQueue().timeout(const Duration(seconds: 2));
          expect(batch.fatalCloseCount, 1);
          expect(batch.cleanupExpiryCallbackCount, 1);
          expect(batch.cleanupWindowCount, 0);
          await batch.finishLateSibling().timeout(const Duration(seconds: 2));
          expect(batch.fatalCloseCount, 1);
          expect(batch.wireResponses, isEmpty);
        } finally {
          await harness.dispose();
        }
      }
    }
  });

  test(
    'ownerless and owner scoped permission batch siblings share one response grace',
    () async {
      for (final ownerScoped in <bool>[false, true]) {
        final harness = await _PermissionBatchHarness.start(
          promptCancelGrace: const Duration(milliseconds: 75),
        );
        try {
          final batch = await harness.sendCancelledPermissionWithBlockedSibling(
            ownerScoped: ownerScoped,
            reason: ownerScoped
                ? acp.PermissionCancellationReason.promptEnded
                : acp.PermissionCancellationReason.timedOut,
          );
          await batch.permissionReservationReleased.timeout(
            const Duration(seconds: 2),
          );
          final expiredWindowIdentity = batch.cleanupWindowIdentity;
          expect(expiredWindowIdentity, isNotNull);
          expect(batch.cleanupWindowStartCount, 1);
          expect(batch.permissionResponseCompleted, isFalse);
          expect(batch.siblingResponseCompleted, isFalse);
          expect(batch.wireResponses, isEmpty);
          final unavailable = await batch.peerUnavailable.future.timeout(
            const Duration(seconds: 2),
          );
          expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
          final cleanupIdentity = unavailable.cleanupIdentity;
          if (ownerScoped) {
            expect(cleanupIdentity, isNotNull);
            expect(identical(cleanupIdentity!.ownerToken, batch.owner), isTrue);
            expect(cleanupIdentity.generation, batch.owner!.generation);
          } else {
            expect(cleanupIdentity, isNull);
          }
          await batch.cleanupReaped.timeout(const Duration(seconds: 2));
          expect(batch.fatalCloseCount, 1);
          expect(batch.cleanupExpiryCallbackCount, 1);
          expect(
            batch.firstCancellationReason,
            ownerScoped
                ? acp.PermissionCancellationReason.promptEnded
                : acp.PermissionCancellationReason.timedOut,
          );
          expect(batch.gatePendingItems, 0);
          expect(batch.correlationPendingItems, 0);
          expect(batch.admissionCount, 0);
          expect(batch.cleanupWindowCount, 0);
          batch.fireCapturedTimerCallback();
          await pumpEventQueue().timeout(const Duration(seconds: 2));
          expect(batch.fatalCloseCount, 1);
          expect(batch.cleanupExpiryCallbackCount, 1);
          expect(batch.cleanupWindowCount, 0);
        } finally {
          await harness.dispose();
        }
      }
    },
  );

  test(
    'permission response commit revokes grace and later work gets a fresh window',
    () async {
      final harness = await _PermissionBatchHarness.start(
        promptCancelGrace: const Duration(milliseconds: 75),
      ).timeout(const Duration(seconds: 2));
      try {
        final owner = harness.base.manager.beginPromptTurn(
          harness.base.sessionId,
        );
        final first = await harness
            .blockResponseCommit(owner: owner)
            .timeout(const Duration(seconds: 2));
        await first.reservationReleased.timeout(const Duration(seconds: 2));
        final firstIdentity = first.cleanupWindowIdentity;
        await first.commitResponse().timeout(const Duration(seconds: 2));
        expect(first.cleanupTimerCancelled, isTrue);
        final secondStarted = DateTime.now();
        final second = await harness
            .blockResponseCommit(owner: owner)
            .timeout(const Duration(seconds: 2));
        await second.reservationReleased.timeout(const Duration(seconds: 2));
        expect(identical(second.cleanupWindowIdentity, firstIdentity), isFalse);
        expect(second.cleanupDeadline.isAfter(first.cleanupDeadline), isTrue);
        first.fireCapturedTimerCallback();
        expect(harness.fatalCloseCount, 0);
        await second.elapseOwnGrace().timeout(const Duration(seconds: 2));
        expect(
          DateTime.now().difference(secondStarted),
          greaterThanOrEqualTo(const Duration(milliseconds: 40)),
        );
        expect(harness.fatalCloseCount, 1);
      } finally {
        await harness.dispose().timeout(const Duration(seconds: 2));
      }
    },
  );

  test(
    'owner cleanup keys join owned admissions and separate ownerless admissions',
    () async {
      final ownedHarness = await _PermissionBatchHarness.start(
        promptCancelGrace: const Duration(seconds: 1),
      );
      try {
        final owner = ownedHarness.base.manager.beginPromptTurn(
          ownedHarness.base.sessionId,
        );
        final first = await ownedHarness._send(
          method: 'fs/read_text_file',
          owner: owner,
          reason: acp.PermissionCancellationReason.promptEnded,
        );
        await first.reservationReleased.timeout(const Duration(seconds: 2));
        final second = await ownedHarness._send(
          method: 'fs/read_text_file',
          owner: owner,
          reason: acp.PermissionCancellationReason.promptEnded,
        );
        await second.reservationReleased.timeout(const Duration(seconds: 2));

        expect(
          identical(first.cleanupWindowIdentity, second.cleanupWindowIdentity),
          isTrue,
        );
        expect(first.cleanupWindowStartCount, 1);
        expect(
          ownedHarness.base.manager.ownerCleanupWindowBlockerCountForTesting(
            first.cleanupWindowIdentity,
          ),
          2,
        );

        first.fireCapturedTimerCallback();
        final unavailable = await first.peerUnavailable.future.timeout(
          const Duration(seconds: 2),
        );
        await first.cleanupReaped.timeout(const Duration(seconds: 2));
        expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
        expect(unavailable.cleanupIdentity, isNotNull);
        expect(
          identical(unavailable.cleanupIdentity!.ownerToken, owner),
          isTrue,
        );
        expect(unavailable.cleanupIdentity!.generation, owner.generation);
        expect(first.cleanupExpiryCallbackCount, 1);
        second.fireCapturedTimerCallback();
        await pumpEventQueue();
        expect(first.cleanupExpiryCallbackCount, 1);
      } finally {
        await ownedHarness.dispose();
      }

      final ownerlessHarness = await _PermissionBatchHarness.start(
        promptCancelGrace: const Duration(seconds: 1),
      );
      try {
        final first = await ownerlessHarness._send(
          method: 'session/request_permission',
        );
        await ownerlessHarness.base.permissions
            .waitForRequest(first.providerIndex)
            .timeout(const Duration(seconds: 2));
        ownerlessHarness.base.permissions.completeDecision(
          first.providerIndex,
          const acp.PermissionDecision.cancelled(),
        );
        await first.reservationReleased.timeout(const Duration(seconds: 2));
        final second = await ownerlessHarness._send(
          method: 'session/request_permission',
        );
        await second.reservationReleased.timeout(const Duration(seconds: 2));

        expect(
          identical(first.cleanupWindowIdentity, second.cleanupWindowIdentity),
          isFalse,
        );
        expect(first.cleanupWindowStartCount, 2);
        expect(first.cleanupWindowCount, 2);

        first.fireCapturedTimerCallback();
        final unavailable = await first.peerUnavailable.future.timeout(
          const Duration(seconds: 2),
        );
        await Future.wait<void>(<Future<void>>[
          first.cleanupReaped,
          second.cleanupReaped,
        ]).timeout(const Duration(seconds: 2));
        expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
        expect(unavailable.cleanupIdentity, isNull);
        expect(first.cleanupExpiryCallbackCount, 1);
        first.fireCapturedTimerCallback();
        second.fireCapturedTimerCallback();
        await pumpEventQueue();
        expect(first.cleanupExpiryCallbackCount, 1);
        expect(first.cleanupWindowCount, 0);
      } finally {
        await ownerlessHarness.dispose();
      }
    },
  );

  test('fatal cleanup close errors do not leak into the zone', () async {
    final zoneErrors = <Object>[];
    final done = Completer<void>();
    Object? operationError;
    StackTrace? operationStackTrace;
    runZonedGuarded<void>(() {
      unawaited(() async {
        try {
          final harness = await _PermissionBatchHarness.start(
            promptCancelGrace: const Duration(milliseconds: 75),
            failFatalCloseFuture: true,
          );
          try {
            final batch = await harness.blockResponseCommit();
            final cleanupReaped = batch.cleanupReaped;
            await batch.peerUnavailable.future.timeout(
              const Duration(seconds: 2),
            );
            await cleanupReaped.timeout(const Duration(seconds: 2));
            await batch.finishLateSibling().timeout(const Duration(seconds: 2));
            await pumpEventQueue();
          } finally {
            await harness.dispose().timeout(const Duration(seconds: 2));
          }
        } catch (error, stackTrace) {
          operationError = error;
          operationStackTrace = stackTrace;
        } finally {
          done.complete();
        }
      }());
    }, (error, _) => zoneErrors.add(error));
    await done.future.timeout(const Duration(seconds: 5));
    if (operationError case final error?) {
      Error.throwWithStackTrace(error, operationStackTrace!);
    }
    await pumpEventQueue();
    expect(zoneErrors, isEmpty);
  });

  test(
    'synchronous fatal cleanup close failures do not leak or restart cleanup',
    () async {
      final harness = await _PermissionBatchHarness.start(
        promptCancelGrace: const Duration(seconds: 1),
        throwSynchronouslyOnFatalClose: true,
      );
      _BlockedBatchProbe? batch;
      try {
        batch = await harness.blockResponseCommit();
        final cleanupReaped = batch.cleanupReaped;
        final zoneErrors = <Object>[];
        runZonedGuarded<void>(
          batch.fireCapturedTimerCallback,
          (error, _) => zoneErrors.add(error),
        );
        await pumpEventQueue();

        expect(zoneErrors, isEmpty);
        expect(batch.cleanupExpiryCallbackCount, 1);
        expect(batch.cleanupTimerCancelled, isTrue);
        expect(harness.base.peer.isAvailable, isTrue);

        runZonedGuarded<void>(
          batch.fireCapturedTimerCallback,
          (error, _) => zoneErrors.add(error),
        );
        await pumpEventQueue();
        expect(zoneErrors, isEmpty);
        expect(batch.cleanupExpiryCallbackCount, 1);
        expect(batch.cleanupWindowStartCount, 1);

        await batch.commitResponse().timeout(const Duration(seconds: 2));
        await cleanupReaped.timeout(const Duration(seconds: 2));
        expect(batch.cleanupWindowCount, 0);
      } finally {
        if (batch != null) await batch.finishLateSibling();
        await harness.dispose().timeout(const Duration(seconds: 2));
      }
    },
  );

  test(
    'manager dispose stops cleanup windows and rejects late reservation windows',
    () async {
      final harness = await _PermissionBatchHarness.start(
        promptCancelGrace: const Duration(milliseconds: 75),
      );
      _BlockedBatchProbe? batch;
      try {
        batch = await harness.blockResponseCommit();
        final cleanupReaped = batch.cleanupReaped;
        expect(batch.cleanupTimerActive, isTrue);
        expect(batch.cleanupWindowCount, 1);

        await harness.base.manager.dispose().timeout(
          const Duration(seconds: 2),
        );
        expect(batch.cleanupTimerCancelled, isTrue);
        expect(batch.cleanupWindowCount, 1);
        expect(batch.cleanupExpiryCallbackCount, 0);

        batch.fireCapturedTimerCallback();
        await pumpEventQueue();
        expect(batch.cleanupExpiryCallbackCount, 0);
        expect(batch.cleanupWindowCount, 1);
        await Future<void>.delayed(const Duration(milliseconds: 125));
        expect(harness.base.peer.isAvailable, isTrue);
        expect(batch.fatalCloseCount, 0);
        expect(batch.cleanupExpiryCallbackCount, 0);

        await batch.finishLateSibling().timeout(const Duration(seconds: 2));
        await cleanupReaped.timeout(const Duration(seconds: 2));
        expect(batch.cleanupWindowCount, 0);
      } finally {
        if (batch != null) await batch.finishLateSibling();
        await harness.dispose().timeout(const Duration(seconds: 2));
      }

      final lateHarness = await _PermissionAdmissionHarness.start(
        timeouts: const acp.AcpTimeouts(
          permission: Duration(milliseconds: 75),
          promptCancelGrace: Duration(milliseconds: 75),
        ),
      );
      try {
        await lateHarness.occupyAllOrdinaryPermits();
        final request = await lateHarness.admit('session/request_permission');
        expect(request.reservationReleaseCount, 0);
        expect(
          lateHarness.manager.admissionCleanupWindowStartCountForTesting,
          0,
        );

        await lateHarness.manager.dispose().timeout(const Duration(seconds: 2));
        await request.reservationReleased.future.timeout(
          const Duration(seconds: 2),
        );
        await request.response.timeout(const Duration(seconds: 2));
        await request.settled.timeout(const Duration(seconds: 2));
        expect(
          lateHarness.manager.admissionCleanupWindowStartCountForTesting,
          0,
        );
        expect(lateHarness.manager.admissionCleanupWindowCountForTesting, 0);
        await Future<void>.delayed(const Duration(milliseconds: 125));
        expect(lateHarness.peer.isAvailable, isTrue);
      } finally {
        lateHarness.releaseOrdinaryPermits();
        await lateHarness.dispose().timeout(const Duration(seconds: 2));
      }
    },
  );

  test('same owner cleanup joins keep the original real timer', () async {
    const grace = Duration(milliseconds: 800);
    const halfGrace = Duration(milliseconds: 400);
    final harness = await _PermissionBatchHarness.start(
      promptCancelGrace: grace,
    );
    _BlockedBatchProbe? first;
    _BlockedBatchProbe? second;
    try {
      final owner = harness.base.manager.beginPromptTurn(
        harness.base.sessionId,
      );
      first = await harness._send(
        method: 'fs/read_text_file',
        owner: owner,
        reason: acp.PermissionCancellationReason.promptEnded,
      );
      await first.reservationReleased.timeout(const Duration(seconds: 2));
      final firstIdentity = first.cleanupWindowIdentity;
      final firstDeadline = first.cleanupDeadline;
      final firstCallback = first.cleanupTimerCallback;
      expect(first.cleanupTimerActive, isTrue);

      final joinTarget = firstDeadline.subtract(halfGrace);
      final untilJoin = joinTarget.difference(DateTime.now());
      if (!untilJoin.isNegative && untilJoin != Duration.zero) {
        await Future<void>.delayed(untilJoin);
      }

      second = await harness._send(
        method: 'fs/read_text_file',
        owner: owner,
        reason: acp.PermissionCancellationReason.promptEnded,
      );
      await second.reservationReleased.timeout(const Duration(seconds: 2));
      final cleanupReaped = first.cleanupReaped;
      expect(identical(second.cleanupWindowIdentity, firstIdentity), isTrue);
      expect(second.cleanupDeadline, firstDeadline);
      expect(identical(second.cleanupTimerCallback, firstCallback), isTrue);
      expect(second.cleanupWindowStartCount, 1);
      expect(second.cleanupTimerActive, isTrue);
      expect(
        harness.base.manager.ownerCleanupWindowBlockerCountForTesting(
          firstIdentity,
        ),
        2,
      );

      final untilOriginalExpiry = firstDeadline.difference(DateTime.now());
      final fatalWatchdog =
          (untilOriginalExpiry.isNegative
              ? Duration.zero
              : untilOriginalExpiry) +
          const Duration(milliseconds: 250);
      final unavailable = await first.peerUnavailable.future.timeout(
        fatalWatchdog,
      );
      expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
      expect(unavailable.cleanupIdentity, isNotNull);
      expect(identical(unavailable.cleanupIdentity!.ownerToken, owner), isTrue);
      expect(unavailable.cleanupIdentity!.generation, owner.generation);
      await cleanupReaped.timeout(const Duration(seconds: 2));
      expect(first.cleanupExpiryCallbackCount, 1);
    } finally {
      if (first != null) await first.finishLateSibling();
      if (second != null) await second.finishLateSibling();
      await harness.dispose().timeout(const Duration(seconds: 2));
    }
  });

  test(
    'late permission decisions cannot start file or terminal providers after epoch loss',
    () async {
      for (final method in <String>[
        'fs/read_text_file',
        'fs/write_text_file',
        'terminal/create',
      ]) {
        final harness = await _PermissionAdmissionHarness.start();
        try {
          final request = await harness.admit(method);
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));
          final closing = harness.peer.closeForTesting(
            AcpPeerUnavailableReason.transportClosed,
          );
          harness.permissions.completeAllow(0);
          await request.settled.timeout(const Duration(seconds: 2));
          await closing.timeout(const Duration(seconds: 2));
          expect(harness.fs.readCalls, 0);
          expect(harness.fs.writeCalls, 0);
          expect(harness.terminals.createCalls, 0);
          expect(request.reservationReleaseCount, 1);
          expect(request.responseCommitCount, 1);
        } finally {
          await harness.dispose();
        }
      }
    },
  );

  test(
    'late terminal handles release once across close dispose and release failures',
    () async {
      for (final cause in _LateCause.values) {
        for (final releaseFailure in _ReleaseFailure.values) {
          for (final lateError in <bool>[false, true]) {
            await _expectNoZoneErrors(() async {
              final harness = await _LateTerminalHarness.start(
                releaseThrows: releaseFailure == _ReleaseFailure.asynchronous,
                releaseThrowsSynchronously:
                    releaseFailure == _ReleaseFailure.synchronous,
              );
              try {
                final createOutcome = _observeFuture(harness.createTerminal());
                await harness.createStarted.future.timeout(
                  const Duration(seconds: 2),
                );
                await harness.invalidate(cause);

                final earlyOutcome = await createOutcome.timeout(
                  const Duration(seconds: 2),
                );
                final earlyError = earlyOutcome.error;
                expect(earlyError, isA<rpc.RpcException>());
                final rpcError = earlyError! as rpc.RpcException;
                expect(rpcError.code, -32000);
                expect(rpcError.message, 'ACP connection closed.');
                await harness.createProbe.settled.timeout(
                  const Duration(seconds: 2),
                );
                if (cause == _LateCause.dispose) {
                  final reply = await harness.createProbe.response.timeout(
                    const Duration(seconds: 2),
                  );
                  expect(reply.errorCode, -32000);
                  expect(reply.errorMessage, 'ACP connection closed.');
                  expect(reply.hasErrorData, isFalse);
                }
                expect(
                  harness.base.terminals.createResult!.isCompleted,
                  isFalse,
                );
                expect(harness.createProbe.responseCommitCount, 1);
                expect(harness.pendingLeaseCount, 0);
                expect(harness.totalLeaseCount, 0);

                acp.TerminalProcessHandle? lateHandle;
                if (lateError) {
                  harness.completeCreateError(StateError('LATE-CREATE-CANARY'));
                } else {
                  lateHandle = await harness.completeCreateHandle();
                  await harness.releaseCompleted.future.timeout(
                    const Duration(seconds: 2),
                  );
                  await lateHandle.process.exitCode.timeout(
                    const Duration(seconds: 2),
                  );
                }
                await harness.waitForPeerClose();
                await pumpEventQueue();
                expect(harness.releaseCalls, lateError ? 0 : 1);
                expect(harness.terminalCreatedEvents, isEmpty);
                expect(harness.registeredTerminalCount, 0);
                expect(harness.pendingLeaseCount, 0);
                expect(harness.totalLeaseCount, 0);
              } finally {
                await harness.dispose();
              }
            });
          }
        }
      }

      await _expectNoZoneErrors(() async {
        final harness = await _LateTerminalHarness.start();
        try {
          const providerError = acp.AcpConnectionClosedException();
          final createOutcome = _observeFuture(harness.createTerminal());
          await harness.createStarted.future.timeout(
            const Duration(seconds: 2),
          );
          harness.completeCreateError(providerError);
          final outcome = await createOutcome.timeout(
            const Duration(seconds: 2),
          );
          expect(identical(outcome.error, providerError), isTrue);
          await harness.createProbe.settled.timeout(const Duration(seconds: 2));
          expect(harness.base.peer.isAvailable, isTrue);
          expect(harness.releaseCalls, 0);
          expect(harness.pendingLeaseCount, 0);
          expect(harness.totalLeaseCount, 0);
        } finally {
          await harness.dispose();
        }
      });
    },
  );

  test(
    'published terminal success survives dispose before handler tail check',
    () async {
      await _expectNoZoneErrors(() async {
        final harness = await _PermissionAdmissionHarness.start();
        Future<void>? disposing;
        try {
          final probe = await harness.admit('terminal/create');
          final published = Completer<void>();
          unawaited(
            probe.admission!.terminal.then<void>((_) {
              disposing = harness.manager.dispose();
              published.complete();
            }),
          );
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));
          harness.permissions.completeAllow(0);
          await probe.handlerStarted.future.timeout(const Duration(seconds: 2));
          final handlerOutcome = await _observeFuture(
            probe.handlerOperation!,
          ).timeout(const Duration(seconds: 2));
          await published.future.timeout(const Duration(seconds: 2));
          expect(handlerOutcome.error, isNull);
          expect(handlerOutcome.value, isA<Map<String, dynamic>>());
          final reply = await probe.response.timeout(
            const Duration(seconds: 2),
          );
          expect(reply.error, isNull);
          expect(reply.result, isA<Map<String, dynamic>>());
          await disposing!.timeout(const Duration(seconds: 2));
        } finally {
          await harness.dispose();
        }
      });
    },
  );

  test(
    'reentrant invalidation rejects completed create before blocked late release',
    () async {
      await _expectNoZoneErrors(() async {
        for (final closeSession in <bool>[false, true]) {
          final harness = await _LateTerminalHarness.start();
          final releaseBarrier = Completer<void>();
          Future<void>? invalidating;
          acp.TerminalProcessHandle? handle;
          try {
            handle = await harness.base.terminals.createLateHandle(
              harness.base.sessionId,
            );
            harness.base.terminals
              ..createResult!.complete(handle)
              ..releaseBarrier = releaseBarrier
              ..onCreate = () {
                invalidating = closeSession
                    ? harness.manager.closeSession(
                        sessionId: harness.base.sessionId,
                      )
                    : harness.manager.dispose();
              };

            final outcome = await _observeFuture(
              harness.createTerminal(),
            ).timeout(const Duration(seconds: 2));
            final error = outcome.error;
            expect(error, isA<rpc.RpcException>());
            final rpcError = error! as rpc.RpcException;
            final expectedCode = closeSession ? -32003 : -32000;
            final expectedMessage = closeSession
                ? 'Permission request cancelled.'
                : 'ACP connection closed.';
            expect(rpcError.code, expectedCode);
            expect(rpcError.message, expectedMessage);
            await harness.base.terminals.releaseStarted.future.timeout(
              const Duration(seconds: 2),
            );
            expect(releaseBarrier.isCompleted, isFalse);
            expect(harness.releaseCalls, 1);
            expect(harness.registeredTerminalCount, 0);
            expect(harness.pendingLeaseCount, 0);
            expect(harness.totalLeaseCount, 0);
            final reply = await harness.createProbe.response.timeout(
              const Duration(seconds: 2),
            );
            expect(reply.errorCode, expectedCode);
            expect(reply.errorMessage, expectedMessage);
            expect(reply.hasErrorData, isFalse);

            releaseBarrier.complete();
            await harness.releaseCompleted.future.timeout(
              const Duration(seconds: 2),
            );
            await handle.process.exitCode.timeout(const Duration(seconds: 2));
            await invalidating!.timeout(const Duration(seconds: 2));
            expect(harness.releaseCalls, 1);
          } finally {
            if (!releaseBarrier.isCompleted) releaseBarrier.complete();
            await harness.dispose();
            if (handle != null) {
              await handle.process.exitCode.timeout(const Duration(seconds: 2));
            }
          }
        }
      });
    },
  );

  test(
    'late terminal handle cannot register into a replacement session generation',
    () async {
      final harness = await _LateTerminalHarness.start();
      try {
        final generationA = harness.sessionGeneration;
        final createOutcome = _observeFuture(harness.createTerminal());
        await harness.createStarted.future.timeout(const Duration(seconds: 2));
        await harness.closeAndReopenSameSession().timeout(
          const Duration(seconds: 2),
        );
        final generationB = harness.sessionGeneration;
        expect(identical(generationA, generationB), isFalse);
        final earlyOutcome = await createOutcome.timeout(
          const Duration(seconds: 2),
        );
        final earlyError = earlyOutcome.error;
        expect(earlyError, isA<rpc.RpcException>());
        final rpcError = earlyError! as rpc.RpcException;
        expect(rpcError.code, -32003);
        expect(rpcError.message, 'Permission request cancelled.');
        await harness.createProbe.settled.timeout(const Duration(seconds: 2));
        final reply = await harness.createProbe.response.timeout(
          const Duration(seconds: 2),
        );
        expect(reply.errorCode, -32003);
        expect(reply.errorMessage, 'Permission request cancelled.');
        expect(reply.hasErrorData, isFalse);
        expect(harness.base.terminals.createResult!.isCompleted, isFalse);
        expect(harness.createProbe.responseCommitCount, 1);
        expect(harness.pendingLeaseCount, 0);
        expect(harness.totalLeaseCount, 0);

        final lateHandle = await harness.completeCreateHandle();
        await harness.releaseCompleted.future.timeout(
          const Duration(seconds: 2),
        );
        await lateHandle.process.exitCode.timeout(const Duration(seconds: 2));
        expect(harness.releaseCalls, 1);
        expect(harness.registeredTerminalCount, 0);
        expect(harness.terminalCreatedEvents, isEmpty);
        final replacement = await harness.createAndReleaseReplacementTerminal();
        expect(replacement.error, isNull);
        expect(replacement.result, isA<Map<String, dynamic>>());
        expect(harness.registeredTerminalCount, 0);
        expect(harness.pendingLeaseCount, 0);
        expect(harness.totalLeaseCount, 0);
      } finally {
        await harness.dispose();
      }
    },
  );

  for (final setupMethod in <String>['resume', 'load']) {
    for (final method in <String>[
      'session/request_permission',
      'fs/read_text_file',
      'terminal/create',
    ]) {
      test(
        'queued unknown $method cannot cross a successful $setupMethod generation',
        () async {
          final harness = await _PermissionAdmissionHarness.start();
          const unknownSessionId = 'queued-unknown-session';
          try {
            await harness.occupyAllOrdinaryPermits();
            final params = Map<String, dynamic>.from(harness.paramsFor(method))
              ..['sessionId'] = unknownSessionId;
            final stale = await harness.admit(method, params: params);
            expect(
              harness.manager.sessionGenerationForTesting(unknownSessionId),
              isNull,
            );

            if (setupMethod == 'resume') {
              await harness.manager.resumeSession(
                sessionId: unknownSessionId,
                workspaceRoot: '/tmp',
              );
            } else {
              await harness.manager.loadSession(
                sessionId: unknownSessionId,
                workspaceRoot: '/tmp',
              );
            }
            expect(
              harness.manager.sessionGenerationForTesting(unknownSessionId),
              isNotNull,
            );

            harness.releaseOrdinaryPermits();
            await pumpEventQueue();
            expect(harness.permissions.requests, isEmpty);
            expect(harness.fs.readCalls, 0);
            expect(harness.terminals.createCalls, 0);

            final reply = await stale.response.timeout(
              const Duration(seconds: 2),
            );
            expect(reply.errorCode, -32003);
            expect(reply.errorMessage, 'Permission request cancelled.');
            expect(reply.hasErrorData, isFalse);
            await stale.settled.timeout(const Duration(seconds: 2));
            expect(harness.permissions.cancellations, hasLength(1));
            expect(
              harness.permissions.cancellations.single.$2,
              acp.PermissionCancellationReason.sessionClosed,
            );
            expect(stale.reservationReleaseCount, 1);
            expect(stale.responseCommitCount, 1);
            expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
            expect(harness.manager.terminalLeaseCountForTesting, 0);
          } finally {
            await harness.dispose();
          }
        },
      );
    }
  }

  for (final setupMethod in <String>['resume', 'load']) {
    for (final setupSucceeds in <bool>[true, false]) {
      for (final method in <String>['fs/read_text_file', 'terminal/create']) {
        final outcomeName = setupSucceeds ? 'success' : 'failure';
        test(
          'first-time $setupMethod $outcomeName settles its $method phase owner',
          () async {
            final harness = await _PermissionAdmissionHarness.start(
              controlFutureSetups: true,
              registerInitialSession: false,
            );
            final terminalEvents = <acp.TerminalEvent>[];
            final terminalSubscription = harness.manager.terminalEvents.listen(
              terminalEvents.add,
            );
            Future<dynamic> startSetup(String workspaceRoot) =>
                setupMethod == 'resume'
                ? harness.manager.resumeSession(
                    sessionId: harness.sessionId,
                    workspaceRoot: workspaceRoot,
                  )
                : harness.manager.loadSession(
                    sessionId: harness.sessionId,
                    workspaceRoot: workspaceRoot,
                  );
            try {
              final setupOutcome = _observeFuture(
                startSetup('/tmp/first-time-setup'),
              );
              await harness
                  .waitForSetupRequest(0)
                  .timeout(const Duration(seconds: 2));
              expect(
                harness.manager.sessionGenerationForTesting(harness.sessionId),
                isNull,
              );

              final stale = await harness.admit(method);
              await harness.permissions
                  .waitForRequest(0)
                  .timeout(const Duration(seconds: 2));
              await stale.handlerStarted.future.timeout(
                const Duration(seconds: 2),
              );
              expect(harness.permissions.pending.single.isCompleted, isFalse);
              final staleHandler = _observeFuture(stale.handlerOperation!);

              if (setupSucceeds) {
                harness.completeSetupSuccess(0);
              } else {
                harness.completeSetupError(0, '$setupMethod setup canary');
              }
              final completedSetup = await setupOutcome.timeout(
                const Duration(seconds: 2),
              );
              if (setupSucceeds) {
                expect(completedSetup.error, isNull);
              } else {
                expect(completedSetup.error, isA<rpc.RpcException>());
                final setupError = completedSetup.error! as rpc.RpcException;
                expect(setupError.code, -32000);
                expect(setupError.message, '$setupMethod setup canary');
              }

              final handlerOutcome = await staleHandler.timeout(
                const Duration(seconds: 2),
              );
              final handlerError = handlerOutcome.error;
              expect(handlerError, isA<rpc.RpcException>());
              final handlerRpcError = handlerError! as rpc.RpcException;
              expect(handlerRpcError.code, -32003);
              expect(handlerRpcError.message, 'Permission request cancelled.');
              final staleReply = await stale.response.timeout(
                const Duration(seconds: 2),
              );
              expect(staleReply.errorCode, -32003);
              expect(staleReply.errorMessage, 'Permission request cancelled.');
              expect(staleReply.hasErrorData, isFalse);
              await stale.settled.timeout(const Duration(seconds: 2));
              expect(harness.permissions.cancellations, hasLength(1));
              expect(
                harness.permissions.cancellations.single.$2,
                acp.PermissionCancellationReason.sessionClosed,
              );
              expect(stale.reservationReleaseCount, 1);
              expect(stale.responseCommitCount, 1);
              expect(harness.fs.readCalls, 0);
              expect(harness.terminals.createCalls, 0);
              expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
              expect(harness.manager.terminalLeaseCountForTesting, 0);
              expect(harness.manager.managedTerminalCountForTesting, 0);
              expect(terminalEvents, isEmpty);

              await _expectNoZoneErrors(() async {
                harness.permissions.completeAllow(0);
                await pumpEventQueue();
              });
              expect(harness.fs.readCalls, 0);
              expect(harness.terminals.createCalls, 0);
              expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
              expect(harness.manager.terminalLeaseCountForTesting, 0);
              expect(harness.manager.managedTerminalCountForTesting, 0);
              expect(terminalEvents, isEmpty);

              if (!setupSucceeds) {
                expect(
                  harness.manager.sessionGenerationForTesting(
                    harness.sessionId,
                  ),
                  isNull,
                );
                final retry = startSetup('/tmp/first-time-retry');
                await harness
                    .waitForSetupRequest(1)
                    .timeout(const Duration(seconds: 2));
                harness.completeSetupSuccess(1);
                await retry.timeout(const Duration(seconds: 2));
              }
              expect(
                harness.manager.sessionGenerationForTesting(harness.sessionId),
                isNotNull,
              );

              final current = await harness.admit(
                'fs/read_text_file',
                params: <String, dynamic>{
                  'sessionId': harness.sessionId,
                  'path': '/tmp/current.txt',
                },
              );
              await harness.permissions
                  .waitForRequest(1)
                  .timeout(const Duration(seconds: 2));
              harness.permissions.completeAllow(1);
              final currentReply = await current.response.timeout(
                const Duration(seconds: 2),
              );
              expect(currentReply.error, isNull);
              expect(currentReply.result, <String, Object?>{'content': 'ok'});
              await current.settled.timeout(const Duration(seconds: 2));
              expect(harness.fs.readCalls, 1);
              expect(harness.terminals.createCalls, 0);
              expect(terminalEvents, isEmpty);
            } finally {
              await terminalSubscription.cancel();
              await harness.dispose();
            }
          },
        );
      }
    }
  }

  for (final reentrantCase in <({String setupMethod, String permissionMethod})>[
    (setupMethod: 'resume', permissionMethod: 'fs/read_text_file'),
    (setupMethod: 'load', permissionMethod: 'terminal/create'),
  ]) {
    test(
      'first-time ${reentrantCase.setupMethod} failure cancels synchronously reentrant ${reentrantCase.permissionMethod}',
      () async {
        final harness = await _PermissionAdmissionHarness.start(
          controlFutureSetups: true,
          registerInitialSession: false,
          synchronousChannel: true,
        );
        final terminalEvents = <acp.TerminalEvent>[];
        final terminalSubscription = harness.manager.terminalEvents.listen(
          terminalEvents.add,
        );
        Future<dynamic> startSetup(String workspaceRoot) =>
            reentrantCase.setupMethod == 'resume'
            ? harness.manager.resumeSession(
                sessionId: harness.sessionId,
                workspaceRoot: workspaceRoot,
              )
            : harness.manager.loadSession(
                sessionId: harness.sessionId,
                workspaceRoot: workspaceRoot,
              );
        try {
          final setupOutcome = _observeFuture(
            startSetup('/tmp/reentrant-setup'),
          );
          await harness
              .waitForSetupRequest(0)
              .timeout(const Duration(seconds: 2));
          final phaseOwner = harness.manager.sessionInputOwnerForTesting(
            harness.sessionId,
          );
          expect(phaseOwner, isNotNull);
          final original = await harness.admit(reentrantCase.permissionMethod);
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));

          Future<_PermissionRequestProbe>? reentrantFuture;
          var reentrantCreationCount = 0;
          harness.permissions.onCancel = (_, _) {
            reentrantCreationCount += 1;
            harness.permissions.onCancel = null;
            harness.manager.settlePromptAdmissions(
              owner: phaseOwner!,
              reason: acp.PermissionCancellationReason.disposed,
            );
            reentrantFuture = harness.admit(
              reentrantCase.permissionMethod,
              params: harness.paramsFor(reentrantCase.permissionMethod),
            );
          };
          final setupCanary =
              '${reentrantCase.setupMethod} synchronous setup canary';
          harness.completeSetupError(0, setupCanary);

          final completedSetup = await setupOutcome.timeout(
            const Duration(seconds: 2),
          );
          expect(completedSetup.error, isA<rpc.RpcException>());
          final setupError = completedSetup.error! as rpc.RpcException;
          expect(setupError.code, -32000);
          expect(setupError.message, setupCanary);
          expect(reentrantCreationCount, 1);
          final reentrant = await reentrantFuture!.timeout(
            const Duration(seconds: 2),
          );

          for (final probe in <_PermissionRequestProbe>[original, reentrant]) {
            final reply = await probe.response.timeout(
              const Duration(seconds: 2),
            );
            expect(reply.errorCode, -32003);
            expect(reply.errorMessage, 'Permission request cancelled.');
            expect(reply.hasErrorData, isFalse);
            await probe.settled.timeout(const Duration(seconds: 2));
            expect(probe.reservationReleaseCount, 1);
            expect(probe.responseCommitCount, 1);
          }
          expect(harness.permissions.requests, hasLength(1));
          expect(harness.permissions.cancellations, hasLength(2));
          expect(
            harness.permissions.cancellations.map((entry) => entry.$2),
            everyElement(acp.PermissionCancellationReason.sessionClosed),
          );
          expect(
            harness.permissions.cancellations.map((entry) => entry.$1).toSet(),
            hasLength(2),
          );
          expect(harness.fs.readCalls, 0);
          expect(harness.terminals.createCalls, 0);
          expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
          expect(harness.manager.terminalLeaseCountForTesting, 0);
          expect(harness.manager.managedTerminalCountForTesting, 0);
          expect(terminalEvents, isEmpty);
          expect(harness.manager.settlingPromptOwnerCountForTesting, 0);
          expect(harness.manager.settlingPromptReasonCountForTesting, 0);
          expect(
            harness.manager.sessionGenerationForTesting(harness.sessionId),
            isNull,
          );

          final retry = startSetup('/tmp/reentrant-retry');
          await harness
              .waitForSetupRequest(1)
              .timeout(const Duration(seconds: 2));
          harness.completeSetupSuccess(1);
          await retry.timeout(const Duration(seconds: 2));
          expect(
            harness.manager.sessionGenerationForTesting(harness.sessionId),
            isNotNull,
          );

          await _expectNoZoneErrors(() async {
            harness.permissions.completeAllow(0);
            await pumpEventQueue();
          });
          expect(harness.permissions.requests, hasLength(1));
          expect(harness.fs.readCalls, 0);
          expect(harness.terminals.createCalls, 0);
          expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
          expect(harness.manager.terminalLeaseCountForTesting, 0);
          expect(harness.manager.managedTerminalCountForTesting, 0);
          expect(terminalEvents, isEmpty);
        } finally {
          await terminalSubscription.cancel();
          await harness.dispose();
        }
      },
    );
  }

  for (final setupMethod in <String>['resume', 'load']) {
    test(
      'direct $setupMethod replacement settles only the previous terminal generation',
      () async {
        final harness = await _LateTerminalHarness.start(
          maxOrdinaryConcurrentHandlers: 2,
        );
        const otherSessionId = 'unrelated-generation-session';
        try {
          await harness.manager.resumeSession(
            sessionId: otherSessionId,
            workspaceRoot: '/tmp',
          );
          final unrelatedGeneration = harness.manager
              .sessionGenerationForTesting(otherSessionId);
          final generationA = harness.sessionGeneration;

          final createOutcome = _observeFuture(harness.createTerminal());
          await harness.createStarted.future.timeout(
            const Duration(seconds: 2),
          );
          final unrelated = await harness.base.admit(
            'fs/read_text_file',
            params: <String, dynamic>{
              'sessionId': otherSessionId,
              'path': '/tmp/unrelated.txt',
            },
          );
          await harness.base.permissions
              .waitForRequest(1)
              .timeout(const Duration(seconds: 2));

          if (setupMethod == 'resume') {
            await harness.manager.resumeSession(
              sessionId: harness.base.sessionId,
              workspaceRoot: '/tmp',
            );
          } else {
            await harness.manager.loadSession(
              sessionId: harness.base.sessionId,
              workspaceRoot: '/tmp',
            );
          }
          final generationB = harness.sessionGeneration;
          expect(identical(generationA, generationB), isFalse);
          expect(
            identical(
              unrelatedGeneration,
              harness.manager.sessionGenerationForTesting(otherSessionId),
            ),
            isTrue,
          );

          final earlyOutcome = await createOutcome.timeout(
            const Duration(seconds: 2),
          );
          final earlyError = earlyOutcome.error;
          expect(earlyError, isA<rpc.RpcException>());
          final rpcError = earlyError! as rpc.RpcException;
          expect(rpcError.code, -32003);
          expect(rpcError.message, 'Permission request cancelled.');
          final staleReply = await harness.createProbe.response.timeout(
            const Duration(seconds: 2),
          );
          expect(staleReply.errorCode, -32003);
          expect(staleReply.errorMessage, 'Permission request cancelled.');
          expect(staleReply.hasErrorData, isFalse);
          await harness.createProbe.settled.timeout(const Duration(seconds: 2));
          expect(harness.base.terminals.createResult!.isCompleted, isFalse);
          expect(harness.createProbe.responseCommitCount, 1);
          expect(harness.pendingLeaseCount, 0);
          expect(harness.totalLeaseCount, 0);

          expect(harness.base.permissions.pending[1].isCompleted, isFalse);
          harness.base.permissions.completeAllow(1);
          final unrelatedReply = await unrelated.response.timeout(
            const Duration(seconds: 2),
          );
          expect(unrelatedReply.error, isNull);
          expect(unrelatedReply.result, <String, Object?>{'content': 'ok'});
          await unrelated.settled.timeout(const Duration(seconds: 2));
          expect(harness.base.fs.readCalls, 1);

          final lateHandle = await harness.completeCreateHandle();
          await harness.releaseCompleted.future.timeout(
            const Duration(seconds: 2),
          );
          await lateHandle.process.exitCode.timeout(const Duration(seconds: 2));
          expect(harness.releaseCalls, 1);
          expect(harness.registeredTerminalCount, 0);
          expect(harness.terminalCreatedEvents, isEmpty);

          final replacement = await harness
              .createAndReleaseReplacementTerminal();
          expect(replacement.error, isNull);
          expect(replacement.result, isA<Map<String, dynamic>>());
          expect(harness.releaseCalls, 2);
          expect(harness.registeredTerminalCount, 0);
          expect(harness.pendingLeaseCount, 0);
          expect(harness.totalLeaseCount, 0);
        } finally {
          await harness.dispose();
        }
      },
    );
  }

  test(
    'typed prompt uses the public owner bound proxy and rejects stale owners',
    () async {
      final typedHarness = await _PromptLifecycleHarness.start();
      try {
        final sharedUpdates = <acp.AcpUpdate>[];
        final sharedErrors = <Object>[];
        final shared = typedHarness.base.manager
            .sessionUpdates(typedHarness.sessionId)
            .listen(
              sharedUpdates.add,
              onError: (Object error, StackTrace _) => sharedErrors.add(error),
            );
        final typed = _observeFuture(
          typedHarness.manager
              .prompt(
                sessionId: typedHarness.sessionId,
                content: const <Map<String, dynamic>>[],
              )
              .toList(),
        );
        await typedHarness.promptSeen.future.timeout(
          const Duration(seconds: 2),
        );
        expect(typedHarness.promptWireCount, 1);
        expect(typedHarness.peer.promptOperationCountForTesting, 1);
        typedHarness.respondPromptSuccess();
        final outcome = await typed.timeout(const Duration(seconds: 2));
        expect(outcome.error, isNull);
        final updates = outcome.value! as List<acp.AcpUpdate>;
        expect(updates, hasLength(1));
        expect(updates.single, isA<acp.TurnEnded>());
        expect(
          (updates.single as acp.TurnEnded).stopReason,
          acp.StopReason.endTurn,
        );
        expect(sharedUpdates.whereType<acp.TurnEnded>(), isEmpty);
        expect(sharedErrors, isEmpty);
        expect(typedHarness.peer.promptOperationCountForTesting, 0);
        _expectPromptHarnessDrained(typedHarness);
        await shared.cancel();
      } finally {
        await typedHarness.dispose();
      }

      final typedErrorHarness = await _PromptLifecycleHarness.start();
      try {
        final callEvents = <Object>[];
        final sharedUpdates = <acp.AcpUpdate>[];
        final sharedErrors = <Object>[];
        final done = Completer<void>();
        var doneCount = 0;
        final shared = typedErrorHarness.base.manager
            .sessionUpdates(typedErrorHarness.sessionId)
            .listen(
              sharedUpdates.add,
              onError: (Object error, StackTrace _) => sharedErrors.add(error),
            );
        typedErrorHarness.manager
            .prompt(
              sessionId: typedErrorHarness.sessionId,
              content: const <Map<String, dynamic>>[],
            )
            .listen(
              callEvents.add,
              onError: (Object error, StackTrace _) => callEvents.add(error),
              onDone: () {
                doneCount += 1;
                if (!done.isCompleted) done.complete();
              },
            );
        await typedErrorHarness.promptSeen.future.timeout(
          const Duration(seconds: 2),
        );
        expect(typedErrorHarness.peer.promptOperationCountForTesting, 1);
        typedErrorHarness.respondPromptError(
          code: -32000,
          message: 'fixed typed prompt error',
        );
        await done.future.timeout(const Duration(seconds: 2));
        expect(callEvents, hasLength(2));
        expect(callEvents.first, isA<rpc.RpcException>());
        expect(callEvents.last, isA<acp.TurnEnded>());
        expect(
          (callEvents.last as acp.TurnEnded).stopReason,
          acp.StopReason.other,
        );
        expect(doneCount, 1);
        expect(sharedUpdates.whereType<acp.TurnEnded>(), isEmpty);
        expect(sharedErrors, isEmpty);
        expect(typedErrorHarness.peer.promptOperationCountForTesting, 0);
        _expectPromptHarnessDrained(typedErrorHarness);
        await shared.cancel();
      } finally {
        await typedErrorHarness.dispose();
      }

      final typedCancelHarness = await _PromptLifecycleHarness.start();
      try {
        final subscription = typedCancelHarness.manager
            .prompt(
              sessionId: typedCancelHarness.sessionId,
              content: const <Map<String, dynamic>>[],
            )
            .listen((_) {});
        await typedCancelHarness.promptSeen.future.timeout(
          const Duration(seconds: 2),
        );
        expect(typedCancelHarness.peer.promptOperationCountForTesting, 1);
        await subscription.cancel().timeout(const Duration(seconds: 2));
        await pumpEventQueue();
        expect(typedCancelHarness.cancelWireCount, 1);
        expect(typedCancelHarness.peer.promptOperationCountForTesting, 1);
        typedCancelHarness.respondPromptSuccess();
        await pumpEventQueue();
        expect(typedCancelHarness.peer.promptOperationCountForTesting, 0);
        _expectPromptHarnessDrained(typedCancelHarness);
      } finally {
        await typedCancelHarness.dispose();
      }

      final publicHarness = await _PromptLifecycleHarness.start();
      try {
        await publicHarness.assertOldSessionUpdateIsDropped();
        final otherSessionOwner = await publicHarness.publicFixture
            .createOtherSessionOwner();
        final owner = publicHarness.publicClient.beginPromptTurn(
          'public-prompt-session',
        );
        final publicPrompt = _observeFuture(
          publicHarness.publicClient.sendPromptRequest(
            owner: owner,
            content: const <Map<String, dynamic>>[],
          ),
        );
        await publicHarness.publicPromptSeen;
        expect(publicHarness.publicPromptWireCount, 1);
        for (final rejected in <acp.AcpSessionInputBudgetOwner>[
          publicHarness.foreignManagerOwner(),
          publicHarness.publicStaleOwner,
          otherSessionOwner,
          owner,
        ]) {
          final before = publicHarness.publicPromptWireCount;
          final rejectedOutcome = _observeFuture(
            Future<Map<String, dynamic>>.sync(
              () => publicHarness.publicClient.sendPromptRequest(
                owner: rejected,
                content: const <Map<String, dynamic>>[],
              ),
            ),
          );
          await pumpEventQueue();
          expect(publicHarness.publicPromptWireCount, before);
          final outcome = await rejectedOutcome.timeout(
            const Duration(seconds: 2),
          );
          expect(outcome.error, isA<StateError>());
        }
        publicHarness.respondPublicPromptSuccess();
        expect((await publicPrompt).error, isNull);
        publicHarness.publicClient.endPromptTurn(owner);
      } finally {
        await publicHarness.dispose();
      }

      final settlingHarness = await _PromptLifecycleHarness.start();
      try {
        final operation = await settlingHarness
            .startPromptWithBlockedAdmissionCommit();
        var before = settlingHarness.promptWireCount;
        var rejected = await _observeFuture(
          Future<Map<String, dynamic>>.sync(
            () => settlingHarness.manager.sendPromptRequest(
              owner: operation.owner,
              content: const <Map<String, dynamic>>[],
            ),
          ),
        );
        expect(rejected.error, isA<StateError>());
        expect(settlingHarness.promptWireCount, before);

        settlingHarness.respondPromptSuccess();
        await operation.admissionReservationReleased.future.timeout(
          const Duration(seconds: 2),
        );
        await settlingHarness.base.manager
            .promptWinnerRecordedForTesting(operation.owner)
            .timeout(const Duration(seconds: 2));
        before = settlingHarness.promptWireCount;
        rejected = await _observeFuture(
          Future<Map<String, dynamic>>.sync(
            () => settlingHarness.manager.sendPromptRequest(
              owner: operation.owner,
              content: const <Map<String, dynamic>>[],
            ),
          ),
        );
        expect(rejected.error, isA<StateError>());
        expect(settlingHarness.promptWireCount, before);
        expect(
          () => settlingHarness.manager.beginPromptTurn(
            settlingHarness.sessionId,
          ),
          throwsStateError,
        );

        await operation.commitAdmissionResponse();
        await operation.promptResult;
        expect(settlingHarness.peer.promptOperationCountForTesting, 0);
        _expectPromptHarnessDrained(settlingHarness);
      } finally {
        await settlingHarness.dispose();
      }
    },
  );

  test(
    'prompt terminal waits for admission response commit before replacement',
    () async {
      final harness = await _PromptLifecycleHarness.start();
      try {
        final first = await harness.startPromptWithBlockedAdmissionCommit();
        harness.respondPromptSuccess();
        await first.admissionReservationReleased.future;
        expect(
          () => harness.manager.beginPromptTurn(harness.sessionId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP prompt is already active or settling.',
            ),
          ),
        );
        await first.commitAdmissionResponse();
        await first.promptResult;
        final replacement = harness.manager.beginPromptTurn(harness.sessionId);
        harness.manager.endPromptTurn(replacement);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'prompt timeout shares one cancel and one cleanup grace with admissions',
    () async {
      final harness = await _PromptLifecycleHarness.start(
        prompt: const Duration(milliseconds: 75),
        grace: const Duration(milliseconds: 100),
      );
      try {
        final operation = await harness.startPromptWithRunningAdmission();
        await operation.promptSeen.future;
        await operation.admissionStarted.future;
        final result = _observeFuture(operation.result);
        await harness.base.manager
            .promptWinnerRecordedForTesting(operation.owner)
            .timeout(const Duration(seconds: 2));
        await pumpEventQueue();
        await _expectPromptAndAdmissionShareCleanupWindow(harness, operation);
        final resultOutcome = await result.timeout(const Duration(seconds: 2));
        expect(resultOutcome.error, isA<acp.AcpPromptTimeoutException>());
        expect(operation.terminalKind, JsonRpcPromptTerminalKind.timedOut);
        expect(
          operation.permissionReason,
          acp.PermissionCancellationReason.promptEnded,
        );
        expect(operation.cancelWireCount, 1);
        expect(operation.cleanupWindowStartCount, 1);
        expect(
          operation.unavailableCleanupIdentity?.ownerToken,
          same(operation.owner),
        );
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'prompt cancellation keeps replacement settling and stale cancel is isolated',
    () async {
      for (final running in <bool>[false, true]) {
        final harness = await _PromptLifecycleHarness.start();
        try {
          final first = await harness.startPromptWithAdmission(
            running: running,
          );
          await harness.manager.cancelPromptTurn(first.owner);
          await pumpEventQueue();
          expect(first.cancelWireCount, 1);
          expect(
            first.permissionReason,
            acp.PermissionCancellationReason.promptCancelled,
          );
          expect(
            () => harness.manager.beginPromptTurn(harness.sessionId),
            throwsA(isA<StateError>()),
          );
          await first.finishPromptAndAdmission();
          expect(
            harness.base.manager.promptHasDeliveryRightForTesting(first.owner),
            isFalse,
          );
          final replacement = harness.manager.beginPromptTurn(
            harness.sessionId,
          );
          await expectLater(
            harness.manager.cancelPromptTurn(first.owner),
            throwsStateError,
          );
          expect(first.cancelWireCount, 1);
          expect(harness.activeOwner, same(replacement));
          harness.manager.endPromptTurn(replacement);
        } finally {
          await harness.dispose();
        }
      }
    },
  );

  test('prompt settlement seals synchronous reentrant admission', () async {
    final harness = await _PromptLifecycleHarness.start(
      synchronousChannel: true,
    );
    try {
      final operation = await harness.startPromptWithRunningAdmission();
      Future<_PermissionRequestProbe>? reentrantFuture;
      var reentrantCreationCount = 0;
      harness.base.permissions.onCancel = (_, _) {
        reentrantCreationCount += 1;
        harness.base.permissions.onCancel = null;
        reentrantFuture = harness.base.admit(
          'fs/read_text_file',
          params: harness.base.paramsFor('fs/read_text_file'),
        );
      };

      await harness.manager
          .cancelPromptTurn(operation.owner)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () => throw StateError(
              'reentrant prompt cancel notification did not settle',
            ),
          );
      final reentrant = await reentrantFuture!.timeout(
        const Duration(seconds: 2),
      );
      expect(reentrantCreationCount, 1);
      expect(harness.base.permissions.requests, hasLength(1));
      expect(harness.base.permissions.cancellations, hasLength(2));
      expect(
        harness.base.permissions.cancellations.map((entry) => entry.$2),
        everyElement(acp.PermissionCancellationReason.promptCancelled),
      );
      expect(
        harness.base.permissions.cancellations.map((entry) => entry.$1).toSet(),
        hasLength(2),
      );

      await operation.finishPromptAndAdmission();
      final reentrantReply = await reentrant.response.timeout(
        const Duration(seconds: 2),
      );
      expect(reentrantReply.errorCode, -32003);
      expect(reentrantReply.errorMessage, 'Permission request cancelled.');
      await reentrant.settled.timeout(const Duration(seconds: 2));
      _expectPromptHarnessDrained(harness);
    } finally {
      await harness.dispose().timeout(
        const Duration(seconds: 2),
        onTimeout: () => throw StateError(
          'reentrant prompt harness disposal did not settle',
        ),
      );
    }
  });

  test(
    'sealed empty prompt barrier rejects late same owner admission',
    () async {
      final harness = await _PromptLifecycleHarness.start();
      try {
        final operation = await harness._startPrompt();
        harness.respondPromptSuccess();
        await operation.admissionBarrier.timeout(const Duration(seconds: 2));
        await operation.result.timeout(const Duration(seconds: 2));
        expect(
          harness.base.manager.promptLifecycleIsCurrentForTesting(
            operation.owner,
          ),
          isTrue,
        );
        expect(harness.base.manager.admissionCleanupWindowCountForTesting, 0);

        await _expectSealedPromptAdmissionRejected(harness, operation);

        harness.manager.endPromptTurn(operation.owner);
        final replacement = harness.manager.beginPromptTurn(harness.sessionId);
        harness.manager.endPromptTurn(replacement);
        _expectPromptHarnessDrained(harness);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'sealed completed prompt barrier rejects late same owner admission',
    () async {
      final harness = await _PromptLifecycleHarness.start();
      try {
        final operation = await harness.startPromptWithRunningAdmission();
        harness.respondPromptSuccess();
        await harness.base.manager
            .promptWinnerRecordedForTesting(operation.owner)
            .timeout(const Duration(seconds: 2));
        harness.base.permissions.finishPending();
        harness.base.releaseOrdinaryPermits();
        final blocker = operation.responseCommitBlocker;
        if (blocker != null && !blocker.isCompleted) blocker.complete();
        await operation.admission!.settled.timeout(const Duration(seconds: 2));
        await operation.admissionBarrier.timeout(const Duration(seconds: 2));
        await operation.result.timeout(const Duration(seconds: 2));
        expect(
          harness.base.manager.promptLifecycleIsCurrentForTesting(
            operation.owner,
          ),
          isTrue,
        );
        expect(harness.base.manager.admissionCleanupWindowCountForTesting, 0);

        await _expectSealedPromptAdmissionRejected(harness, operation);

        harness.manager.endPromptTurn(operation.owner);
        final replacement = harness.manager.beginPromptTurn(harness.sessionId);
        harness.manager.endPromptTurn(replacement);
        _expectPromptHarnessDrained(harness);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'failed prompt cancel submission still reaps request and admissions before replacement',
    () async {
      final graceful = await _PromptLifecycleHarness.start(
        grace: const Duration(milliseconds: 500),
      );
      try {
        final operation = await graceful.startPromptWithRunningAdmission();
        graceful.failNextCancelSubmission();
        await expectLater(
          graceful.manager.cancelPromptTurn(operation.owner),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'fixed session/cancel submission failure',
            ),
          ),
        );
        expect(graceful.cancelWireCount, 0);
        expect(
          () => graceful.manager.beginPromptTurn(graceful.sessionId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP prompt is already active or settling.',
            ),
          ),
        );

        await graceful
            .finishPromptRace(operation)
            .timeout(const Duration(seconds: 2));
        await operation.admission!.settled.timeout(const Duration(seconds: 2));
        await operation.promptResult
            .then<void>((_) {}, onError: (Object _, StackTrace _) {})
            .timeout(const Duration(seconds: 2));
        expect(graceful.peer.promptOperationCountForTesting, 0);
        final replacement = graceful.manager.beginPromptTurn(
          graceful.sessionId,
        );
        expect(identical(replacement, operation.owner), isFalse);
        graceful.manager.endPromptTurn(replacement);
      } finally {
        await graceful.dispose();
      }

      final fatal = await _PromptLifecycleHarness.start(
        grace: const Duration(milliseconds: 75),
      );
      try {
        final unavailable = Completer<AcpPeerUnavailableState>();
        fatal.peer.addUnavailableListener((state) {
          if (!unavailable.isCompleted) unavailable.complete(state);
        });
        final operation = await fatal.startPromptWithRunningAdmission();
        fatal.failNextCancelSubmission();
        await expectLater(
          fatal.manager.cancelPromptTurn(operation.owner),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'fixed session/cancel submission failure',
            ),
          ),
        );
        expect(
          () => fatal.manager.beginPromptTurn(fatal.sessionId),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'ACP prompt is already active or settling.',
            ),
          ),
        );

        final state = await unavailable.future.timeout(
          const Duration(seconds: 2),
        );
        expect(state.reason, AcpPeerUnavailableReason.fatalTimeout);
        await operation.admission!.settled.timeout(const Duration(seconds: 2));
        await operation.promptResult
            .then<void>((_) {}, onError: (Object _, StackTrace _) {})
            .timeout(const Duration(seconds: 2));
        expect(fatal.peer.promptOperationCountForTesting, 0);
        expect(fatal.base.manager.admissionCleanupWindowCountForTesting, 0);
      } finally {
        await fatal.dispose();
      }
    },
  );

  test(
    'session close shares prompt cancel and reap across response deadline and user cancel',
    () async {
      for (final terminal in _PromptRaceTerminal.values) {
        for (final closeFirst in <bool>[false, true]) {
          final harness = await _PromptLifecycleHarness.start();
          try {
            final operation = await harness.startPromptWithRunningAdmission();
            late final Future<void> close;
            if (closeFirst) {
              close = harness.manager.closeSession(
                sessionId: harness.sessionId,
              );
              await harness.recordPromptWinner(
                operation,
                terminal,
                expectAccepted: false,
              );
            } else {
              await harness.recordPromptWinner(
                operation,
                terminal,
                expectAccepted: true,
              );
              expect(operation.terminalRecorded, isTrue);
              close = harness.manager.closeSession(
                sessionId: harness.sessionId,
              );
            }
            await _expectPromptAndAdmissionShareCleanupWindow(
              harness,
              operation,
            );
            await harness.finishPromptRace(operation);
            await close.catchError((Object _) {});
            final expectedCancelCount =
                !closeFirst &&
                    (terminal == _PromptRaceTerminal.response ||
                        terminal == _PromptRaceTerminal.remoteError)
                ? 0
                : 1;
            expect(operation.cancelWireCount, expectedCancelCount);
            expect(operation.cleanupWindowStartCount, 1);
            if (closeFirst) {
              expect(
                operation.permissionReason,
                acp.PermissionCancellationReason.sessionClosed,
              );
              expect(operation.lifecycle.winner, isNull);
              expect(operation.lifecycle.hasDeliveryRight, isFalse);
            } else if (terminal == _PromptRaceTerminal.userCancel) {
              expect(
                operation.lifecycle.cancellationWinner,
                acp.PermissionCancellationReason.promptCancelled,
              );
              expect(operation.lifecycle.hasDeliveryRight, isFalse);
            } else {
              expect(operation.lifecycle.winner, isNotNull);
              expect(operation.lifecycle.hasDeliveryRight, isTrue);
              expect(operation.lifecycle.winner!.kind, switch (terminal) {
                _PromptRaceTerminal.response =>
                  JsonRpcPromptTerminalKind.response,
                _PromptRaceTerminal.remoteError =>
                  JsonRpcPromptTerminalKind.remoteError,
                _PromptRaceTerminal.deadline =>
                  JsonRpcPromptTerminalKind.timedOut,
                _PromptRaceTerminal.userCancel => throw StateError(
                  'unreachable',
                ),
              });
            }
          } finally {
            await harness.dispose();
          }
        }
      }
    },
  );

  test(
    'late unavailable replay invalidates prompt epoch before dispatch',
    () async {
      final harness = await _PromptLifecycleHarness.startWithUnavailablePeer();
      try {
        expect(harness.peer.isAvailable, isFalse);
        expect(
          () => harness.manager.beginPromptTurn(harness.sessionId),
          throwsStateError,
        );
        expect(harness.promptWireCount, 0);
      } finally {
        await harness.dispose();
      }

      for (final late in <String>['value', 'error', 'malformed']) {
        final active = await _PromptLifecycleHarness.start();
        final zoneErrors = <Object>[];
        try {
          final operation = await active._startPrompt();
          await active.peer.closeForTesting(
            AcpPeerUnavailableReason.transportClosed,
          );
          await expectLater(
            operation.result,
            throwsA(isA<acp.AcpConnectionClosedException>()),
          );
          await runZonedGuarded(
            () async {
              switch (late) {
                case 'value':
                  active.respondPromptSuccess();
                  break;
                case 'error':
                  active.respondPromptError(
                    code: -32000,
                    message: 'late error',
                  );
                  break;
                case 'malformed':
                  active.respondPromptMalformed();
                  break;
              }
              await pumpEventQueue();
            },
            (Object error, StackTrace _) {
              zoneErrors.add(error);
            },
          );
          expect(zoneErrors, isEmpty);
          expect(
            active.base.manager.promptLifecycleIsCurrentForTesting(
              operation.owner,
            ),
            isFalse,
          );
          expect(
            active.base.manager.promptHasDeliveryRightForTesting(
              operation.owner,
            ),
            isFalse,
          );
        } finally {
          await active.dispose();
        }
      }

      for (final matchingOwner in <bool>[false, true]) {
        final direct = _RequestHarness(
          const acp.AcpTimeouts(promptCancelGrace: Duration(milliseconds: 75)),
        );
        const owner = _TestPromptOwner('direct-raw-session', 17);
        final admissionBarrier = Completer<void>();
        final terminalHook = Completer<void>.sync();
        final unavailable = Completer<AcpPeerUnavailableState>.sync();
        direct.peer.addUnavailableListener((state) {
          if (!unavailable.isCompleted) unavailable.complete(state);
        });
        try {
          final result = _observeFuture(
            direct.peer.sendPromptRequest(
              owner: owner,
              content: const <Map<String, dynamic>>[],
              onTerminal: (_, _) {
                if (!terminalHook.isCompleted) terminalHook.complete();
                return JsonRpcPromptSettlement(admissionBarrier.future);
              },
            ),
          );
          final request = await direct.takeRequest();
          direct.respond(request['id'], <String, dynamic>{
            'stopReason': 'end_turn',
          });
          await terminalHook.future.timeout(const Duration(seconds: 2));
          expect(direct.peer.promptOwnerOperationCountForTesting, 1);
          expect(direct.peer.promptSessionOperationCountForTesting, 1);
          if (!matchingOwner) {
            await direct.peer.closeForFatalTimeout(
              cleanupIdentity: AcpPromptCleanupIdentity(Object(), 17),
            );
            expect(
              (await result).error,
              isA<acp.AcpConnectionClosedException>(),
            );
            expect(direct.peer.promptOwnerOperationCountForTesting, 0);
            expect(direct.peer.promptSessionOperationCountForTesting, 0);
          } else {
            await direct.peer.closeForFatalTimeout(
              cleanupIdentity: AcpPromptCleanupIdentity(
                owner,
                owner.generation,
              ),
            );
            final state = await unavailable.future.timeout(
              const Duration(seconds: 2),
            );
            expect(state.reason, AcpPeerUnavailableReason.fatalTimeout);
            expect(state.cleanupIdentity?.ownerToken, same(owner));
            expect(direct.peer.promptOwnerOperationCountForTesting, 1);
            expect(direct.peer.promptSessionOperationCountForTesting, 1);
            admissionBarrier.complete();
            final outcome = await result;
            expect(outcome.error, isNull);
            expect(outcome.value, <String, dynamic>{'stopReason': 'end_turn'});
            expect(direct.peer.promptOwnerOperationCountForTesting, 0);
            expect(direct.peer.promptSessionOperationCountForTesting, 0);
          }
        } finally {
          if (!admissionBarrier.isCompleted) admissionBarrier.complete();
          await direct.dispose();
        }
      }
    },
  );

  test(
    'permission deadline starts at admission for ownerless and owner scoped requests',
    () async {
      final harness = await _PermissionAdmissionHarness.start(
        timeouts: const acp.AcpTimeouts(
          permission: Duration(milliseconds: 75),
          promptCancelGrace: Duration(milliseconds: 100),
        ),
      );
      try {
        await harness.occupyAllOrdinaryPermits();
        for (final ownerScoped in <bool>[false, true]) {
          final owner = ownerScoped
              ? harness.manager.beginPromptTurn(harness.sessionId)
              : null;
          for (final entry in permissionEntries) {
            final request = await harness.admit(entry.method, owner: owner);
            await request.admissionSeen.future;
            final response = await request.response.timeout(
              const Duration(seconds: 2),
            );
            if (entry.method == 'session/request_permission') {
              expect(response.result, <String, Object?>{
                'outcome': <String, Object?>{'outcome': 'cancelled'},
              });
            } else {
              expect(response.errorCode, entry.timeoutCode);
              expect(response.errorMessage, 'Permission request timed out.');
              expect(response.hasErrorData, isFalse);
            }
            expect(harness.permissions.requests, isEmpty);
            expect(harness.fs.readCalls + harness.fs.writeCalls, 0);
            expect(harness.terminals.createCalls, 0);
            expect(request.reservationReleaseCount, 1);
            expect(request.responseCommitCount, 1);
          }
          if (owner != null) harness.manager.endPromptTurn(owner);
        }
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'all permission entries settle queued and running permit races once',
    () async {
      for (final entry in permissionEntries) {
        for (final reason in localReasons) {
          for (final permitFirst in <bool>[false, true]) {
            final harness = await _PermissionAdmissionHarness.start();
            try {
              await harness.occupyAllOrdinaryPermits();
              final owner = harness.manager.beginPromptTurn(harness.sessionId);
              final request = await harness.admit(entry.method, owner: owner);
              if (permitFirst) {
                harness.releaseOrdinaryPermits();
                await harness._ordinaryResponse!.timeout(
                  const Duration(seconds: 2),
                  onTimeout: () => throw StateError(
                    'ordinary response ${entry.method} $reason $permitFirst',
                  ),
                );
                await request.handlerStarted.future.timeout(
                  const Duration(seconds: 2),
                  onTimeout: () => throw StateError(
                    'handler start ${entry.method} $reason $permitFirst',
                  ),
                );
                await harness.permissions.requestStarted.future.timeout(
                  const Duration(seconds: 2),
                  onTimeout: () => throw StateError(
                    'provider start ${entry.method} $reason $permitFirst',
                  ),
                );
                harness.cancelOwner(owner, reason);
              } else {
                harness.cancelOwner(owner, reason);
                harness.releaseOrdinaryPermits();
              }
              final response = await request.response.timeout(
                const Duration(seconds: 2),
                onTimeout: () => throw StateError(
                  'wire response ${entry.method} $reason $permitFirst',
                ),
              );
              expect(request.reservationReleaseCount, 1);
              expect(request.responseCommitCount, 1);
              expect(harness.permissions.cancellations, hasLength(1));
              expect(
                harness.permissions.requests,
                hasLength(permitFirst ? 1 : 0),
              );
              expect(harness.fs.readCalls + harness.fs.writeCalls, 0);
              expect(harness.terminals.createCalls, 0);
              if (entry.method == 'session/request_permission') {
                expect(response.result, <String, Object?>{
                  'outcome': <String, Object?>{'outcome': 'cancelled'},
                });
              } else {
                expect(response.errorCode, entry.cancelledCode);
                expect(response.errorMessage, 'Permission request cancelled.');
                expect(response.hasErrorData, isFalse);
              }
              await request.settled;
              harness.manager.endPromptTurn(owner);
            } finally {
              await harness.dispose();
            }
          }
        }
      }
    },
  );

  test(
    'queued fs and terminal timeout or cancellation do not leak zone errors',
    () async {
      for (final method in <String>['fs/read_text_file', 'terminal/create']) {
        for (final cancelled in <bool>[false, true]) {
          final zoneErrors = <Object>[];
          await runZonedGuarded(
            () async {
              final harness = await _PermissionAdmissionHarness.start(
                timeouts: const acp.AcpTimeouts(
                  permission: Duration(milliseconds: 75),
                ),
              );
              try {
                await harness.occupyAllOrdinaryPermits();
                final owner = harness.manager.beginPromptTurn(
                  harness.sessionId,
                );
                final request = await harness.admit(method, owner: owner);
                await request.admissionSeen.future.timeout(
                  const Duration(seconds: 2),
                );
                if (cancelled) {
                  harness.cancelOwner(
                    owner,
                    acp.PermissionCancellationReason.promptCancelled,
                  );
                }

                final response = await request.response.timeout(
                  const Duration(seconds: 2),
                );
                expect(response.errorCode, cancelled ? -32003 : -32002);
                expect(
                  response.errorMessage,
                  cancelled
                      ? 'Permission request cancelled.'
                      : 'Permission request timed out.',
                );
                await request.settled.timeout(const Duration(seconds: 2));
                expect(harness.permissions.requests, isEmpty);
                expect(harness.fs.readCalls, 0);
                expect(harness.terminals.createCalls, 0);

                harness.releaseOrdinaryPermits();
                await pumpEventQueue().timeout(const Duration(seconds: 2));
                expect(harness.fs.readCalls, 0);
                expect(harness.terminals.createCalls, 0);
                harness.manager.endPromptTurn(owner);
              } finally {
                await harness.dispose().timeout(const Duration(seconds: 2));
              }
            },
            (Object error, StackTrace stackTrace) {
              zoneErrors.add(error);
            },
          );
          expect(
            zoneErrors,
            isEmpty,
            reason: '$method ${cancelled ? 'cancel' : 'timeout'}',
          );
        }
      }
    },
  );

  test(
    'malformed and missing admitted handlers always locally settle',
    () async {
      for (final missingHandler in <bool>[false, true]) {
        final harness = await _PermissionAdmissionHarness.start();
        try {
          if (missingHandler) harness.peer.onReadTextFile = null;
          final request = missingHandler
              ? await harness.admit('fs/read_text_file')
              : await harness.admitRaw(
                  'fs/read_text_file',
                  params: <Object?>['not-an-object'],
                );
          final reply = await request.response.timeout(
            const Duration(seconds: 2),
          );
          expect(reply.errorCode, -32602);
          await request.settled.timeout(const Duration(seconds: 2));
          expect(request.reservationReleaseCount, 1);
          expect(request.responseCommitCount, 1);
          expect(harness.permissions.requests, isEmpty);
          expect(harness.fs.readCalls, 0);
        } finally {
          await harness.dispose();
        }
      }
    },
  );

  test(
    'permission cancellation keeps its reason after side effect starts',
    () async {
      for (final method in <String>[
        'fs/read_text_file',
        'fs/write_text_file',
        'terminal/create',
      ]) {
        for (final reason in localReasons) {
          final harness = await _PermissionAdmissionHarness.start();
          final zoneErrors = <Object>[];
          try {
            switch (method) {
              case 'fs/read_text_file':
                harness.fs.readResult = Completer<String>();
                break;
              case 'fs/write_text_file':
                harness.fs.writeResult = Completer<void>();
                break;
              case 'terminal/create':
                harness.terminals.createResult =
                    Completer<acp.TerminalProcessHandle>();
                break;
            }
            final owner = harness.manager.beginPromptTurn(harness.sessionId);
            final request = await harness.admit(method, owner: owner);
            await harness.permissions.waitForRequest(0);
            harness.permissions.completeAllow(0);
            await (switch (method) {
              'fs/read_text_file' => harness.fs.readStarted.future,
              'fs/write_text_file' => harness.fs.writeStarted.future,
              'terminal/create' => harness.terminals.createStarted.future,
              _ => throw StateError('unreachable permission method'),
            }).timeout(const Duration(seconds: 2));

            harness.cancelOwner(owner, reason);
            final response = await request.response.timeout(
              const Duration(seconds: 2),
            );
            expect(response.errorCode, -32003);
            expect(response.errorMessage, 'Permission request cancelled.');
            expect(response.hasErrorData, isFalse);
            expect(harness.permissions.cancellations.single.$2, reason);
            expect(
              harness.fs.readCalls +
                  harness.fs.writeCalls +
                  harness.terminals.createCalls,
              1,
            );
            await request.reservationReleased.future;
            expect(request.reservationReleaseCount, 1);
            expect(request.responseCommitCount, 1);
            await runZonedGuarded(
              () async {
                final late = StateError('fixed late $method error');
                switch (method) {
                  case 'fs/read_text_file':
                    harness.fs.readResult!.completeError(late);
                    break;
                  case 'fs/write_text_file':
                    harness.fs.writeResult!.completeError(late);
                    break;
                  case 'terminal/create':
                    harness.terminals.createResult!.completeError(late);
                    break;
                }
                await pumpEventQueue();
              },
              (Object error, StackTrace stackTrace) {
                zoneErrors.add(error);
              },
            );
            expect(zoneErrors, isEmpty);
            await request.settled.timeout(const Duration(seconds: 2));
            harness.manager.endPromptTurn(owner);
          } finally {
            await harness.dispose();
          }
        }
      }
    },
  );

  test(
    'permission operation and cancellation atomically consume late value and error',
    () async {
      for (final lateError in <bool>[false, true]) {
        final cancelledFirst = await _PermissionAdmissionHarness.start();
        final zoneErrors = <Object>[];
        try {
          cancelledFirst.fs.readResult = Completer<String>();
          final owner = cancelledFirst.manager.beginPromptTurn(
            cancelledFirst.sessionId,
          );
          final request = await cancelledFirst.admit(
            'fs/read_text_file',
            owner: owner,
          );
          await cancelledFirst.permissions.waitForRequest(0);
          cancelledFirst.permissions.completeAllow(0);
          await cancelledFirst.fs.readStarted.future.timeout(
            const Duration(seconds: 2),
          );
          cancelledFirst.cancelOwner(
            owner,
            acp.PermissionCancellationReason.promptCancelled,
          );
          final reply = await request.response.timeout(
            const Duration(seconds: 2),
          );
          expect(reply.errorCode, -32003);
          expect(reply.errorMessage, 'Permission request cancelled.');
          await runZonedGuarded(
            () async {
              if (lateError) {
                cancelledFirst.fs.readResult!.completeError(
                  StateError('fixed late fs read error'),
                );
              } else {
                cancelledFirst.fs.readResult!.complete('fixed late value');
              }
              await request.settled.timeout(const Duration(seconds: 2));
            },
            (Object error, StackTrace stackTrace) {
              zoneErrors.add(error);
            },
          );
          expect(zoneErrors, isEmpty);
          expect(request.reservationReleaseCount, 1);
          expect(request.responseCommitCount, 1);
          expect(cancelledFirst.fs.readCalls, 1);
          expect(cancelledFirst.permissions.cancellations, hasLength(1));
          cancelledFirst.manager.endPromptTurn(owner);
        } finally {
          await cancelledFirst.dispose();
        }
      }

      final operationFirst = await _PermissionAdmissionHarness.start();
      try {
        operationFirst.fs.readResult = Completer<String>();
        final owner = operationFirst.manager.beginPromptTurn(
          operationFirst.sessionId,
        );
        final request = await operationFirst.admit(
          'fs/read_text_file',
          owner: owner,
        );
        await operationFirst.permissions.waitForRequest(0);
        operationFirst.permissions.completeAllow(0);
        await operationFirst.fs.readStarted.future.timeout(
          const Duration(seconds: 2),
        );
        operationFirst.fs.readResult!.complete('operation won');
        final reply = await request.response.timeout(
          const Duration(seconds: 2),
        );
        expect(reply.result, <String, Object?>{'content': 'operation won'});
        operationFirst.cancelOwner(
          owner,
          acp.PermissionCancellationReason.promptCancelled,
        );
        await request.settled.timeout(const Duration(seconds: 2));
        expect(operationFirst.permissions.cancellations, isEmpty);
        expect(request.reservationReleaseCount, 1);
        expect(request.responseCommitCount, 1);
        operationFirst.manager.endPromptTurn(owner);
      } finally {
        await operationFirst.dispose();
      }
    },
  );

  test(
    'post-allow prompt cancellation prevents filesystem side effects',
    () async {
      final harness = await _PermissionAdmissionHarness.start();
      try {
        final owner = harness.manager.beginPromptTurn(harness.sessionId);
        final request = await harness.admit('fs/read_text_file', owner: owner);
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));

        harness.permissions.completeAllow(0);
        scheduleMicrotask(() {
          harness.cancelOwner(
            owner,
            acp.PermissionCancellationReason.promptCancelled,
          );
        });

        final reply = await request.response.timeout(
          const Duration(seconds: 2),
        );
        expect(reply.errorCode, -32003);
        expect(reply.errorMessage, 'Permission request cancelled.');
        await pumpEventQueue();
        expect(harness.fs.readCalls, 0);
        await request.settled.timeout(const Duration(seconds: 2));
        harness.manager.endPromptTurn(owner);
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'post-create prompt cancellation releases late terminal without registration',
    () async {
      final harness = await _PermissionAdmissionHarness.start();
      final terminalEvents = <acp.TerminalEvent>[];
      final eventSeen = Completer<void>();
      final subscription = harness.manager.terminalEvents.listen((event) {
        terminalEvents.add(event);
        if (!eventSeen.isCompleted) eventSeen.complete();
      });
      try {
        harness.terminals.createResult = Completer<acp.TerminalProcessHandle>();
        final owner = harness.manager.beginPromptTurn(harness.sessionId);
        final request = await harness.admit('terminal/create', owner: owner);
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));
        harness.permissions.completeAllow(0);
        await harness.terminals.createStarted.future.timeout(
          const Duration(seconds: 2),
        );

        harness.cancelOwner(
          owner,
          acp.PermissionCancellationReason.promptCancelled,
        );
        final reply = await request.response.timeout(
          const Duration(seconds: 2),
        );
        expect(reply.errorCode, -32003);
        expect(reply.errorMessage, 'Permission request cancelled.');

        final lateHandle = await harness.terminals.createLateHandle(
          harness.sessionId,
        );
        harness.terminals.createResult!.complete(lateHandle);
        await Future.any<void>(<Future<void>>[
          harness.terminals.releaseStarted.future,
          eventSeen.future,
        ]).timeout(const Duration(seconds: 2));
        await pumpEventQueue();

        expect(harness.terminals.releaseCalls, 1);
        expect(terminalEvents, isEmpty);
        expect(
          await harness.manager.readTerminalOutput(lateHandle.terminalId),
          isEmpty,
        );
        await harness.manager.releaseTerminal(lateHandle.terminalId);
        expect(harness.terminals.releaseCalls, 1);
        await request.settled.timeout(const Duration(seconds: 2));
        harness.manager.endPromptTurn(owner);
      } finally {
        await subscription.cancel();
        await harness.dispose();
      }
    },
  );

  test(
    'terminal registration wins before created listener cancels its prompt',
    () async {
      final harness = await _PermissionAdmissionHarness.start();
      final terminalEvents = <acp.TerminalEvent>[];
      final owner = harness.manager.beginPromptTurn(harness.sessionId);
      final subscription = harness.manager.terminalEvents.listen((event) {
        terminalEvents.add(event);
        if (event is acp.TerminalCreated) {
          harness.cancelOwner(
            owner,
            acp.PermissionCancellationReason.promptCancelled,
          );
        }
      });
      String? terminalId;
      try {
        final request = await harness.admit('terminal/create', owner: owner);
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));
        harness.permissions.completeAllow(0);

        final reply = await request.response.timeout(
          const Duration(seconds: 2),
        );
        expect(reply.errorCode, isNull);
        terminalId = (reply.result as Map)['terminalId'] as String;
        await pumpEventQueue();
        expect(terminalEvents.whereType<acp.TerminalCreated>(), hasLength(1));
        expect(
          terminalEvents.whereType<acp.TerminalCreated>().single.terminalId,
          terminalId,
        );
        expect(harness.permissions.cancellations, isEmpty);
        await request.settled.timeout(const Duration(seconds: 2));
      } finally {
        if (terminalId != null) {
          await harness.manager.releaseTerminal(terminalId);
        }
        harness.manager.endPromptTurn(owner);
        await subscription.cancel();
        await harness.dispose();
      }
    },
  );

  test(
    'throwing cancellable provider cannot break permission settlement',
    () async {
      const canary = 'CANCEL-CALLBACK-STACK-CANARY';
      final previousLogLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final logMessages = <String>[];
      final logSubscription = Logger.root.onRecord.listen((record) {
        if (record.message.startsWith('ACP permission provider cancellation')) {
          logMessages.add(record.message);
        }
      });
      try {
        for (final cause in <String>[
          'timeout',
          'promptCancelled',
          'sessionClosed',
        ]) {
          final zoneErrors = <Object>[];
          final caseDone = Completer<void>.sync();
          runZonedGuarded(
            () async {
              _PermissionAdmissionHarness? harness;
              acp.AcpSessionInputBudgetOwner? owner;
              try {
                harness = await _PermissionAdmissionHarness.start(
                  timeouts: const acp.AcpTimeouts(
                    permission: Duration(milliseconds: 75),
                  ),
                );
                harness.permissions.cancellationFailure = StateError(canary);
                if (cause == 'promptCancelled') {
                  owner = harness.manager.beginPromptTurn(harness.sessionId);
                }
                final request = await harness.admit(
                  'fs/read_text_file',
                  owner: owner,
                );
                await harness.permissions
                    .waitForRequest(0)
                    .timeout(const Duration(seconds: 2));

                Future<void>? close;
                switch (cause) {
                  case 'timeout':
                    break;
                  case 'promptCancelled':
                    harness.cancelOwner(
                      owner!,
                      acp.PermissionCancellationReason.promptCancelled,
                    );
                    break;
                  case 'sessionClosed':
                    close = harness.manager.closeSession(
                      sessionId: harness.sessionId,
                    );
                    break;
                }

                final response = await request.response.timeout(
                  const Duration(seconds: 2),
                );
                expect(
                  response.errorCode,
                  cause == 'timeout' ? -32002 : -32003,
                );
                expect(
                  response.errorMessage,
                  cause == 'timeout'
                      ? 'Permission request timed out.'
                      : 'Permission request cancelled.',
                );
                expect(response.hasErrorData, isFalse);
                expect(jsonEncode(response.raw), isNot(contains(canary)));
                await request.settled.timeout(const Duration(seconds: 2));
                await close?.timeout(const Duration(seconds: 2));
                expect(harness.permissions.cancellations, hasLength(1));
                expect(
                  harness.permissions.cancellations.single.$2,
                  switch (cause) {
                    'timeout' => acp.PermissionCancellationReason.timedOut,
                    'promptCancelled' =>
                      acp.PermissionCancellationReason.promptCancelled,
                    'sessionClosed' =>
                      acp.PermissionCancellationReason.sessionClosed,
                    _ => throw StateError('unreachable cancellation cause'),
                  },
                );
                if (owner != null) harness.manager.endPromptTurn(owner);
              } on Object catch (error, stackTrace) {
                if (!caseDone.isCompleted) {
                  caseDone.completeError(error, stackTrace);
                }
              } finally {
                try {
                  await harness?.dispose().timeout(const Duration(seconds: 2));
                } on Object catch (error, stackTrace) {
                  if (!caseDone.isCompleted) {
                    caseDone.completeError(error, stackTrace);
                  }
                } finally {
                  if (!caseDone.isCompleted) caseDone.complete();
                }
              }
            },
            (Object error, StackTrace stackTrace) {
              zoneErrors.add(error);
              if (!caseDone.isCompleted) {
                caseDone.completeError(error, stackTrace);
              }
            },
          );
          await caseDone.future.timeout(const Duration(seconds: 3));
          expect(zoneErrors, isEmpty, reason: cause);
          expect(
            zoneErrors.map((error) => error.toString()).join('\n'),
            isNot(contains(canary)),
          );
        }
      } finally {
        await logSubscription.cancel();
        Logger.root.level = previousLogLevel;
      }
      expect(
        logMessages,
        everyElement('ACP permission provider cancellation failed.'),
      );
      expect(logMessages, hasLength(3));
      expect(logMessages.join('\n'), isNot(contains(canary)));
    },
  );

  test(
    'queued permission admissions keep their original owner and generation snapshot',
    () async {
      final harness = await _PermissionAdmissionHarness.start(
        timeouts: const acp.AcpTimeouts(permission: Duration(milliseconds: 75)),
      );
      try {
        await harness.occupyAllOrdinaryPermits();
        final generationA = harness.manager.sessionGenerationForTesting(
          harness.sessionId,
        );
        final ownerA = harness.manager.beginPromptTurn(harness.sessionId);
        final ownedA = await harness.admit('terminal/create', owner: ownerA);
        final closeA = harness.manager.closeSession(
          sessionId: harness.sessionId,
        );
        final ownedReply = await ownedA.response.timeout(
          const Duration(seconds: 2),
        );
        expect(ownedReply.errorCode, -32003);
        expect(ownedReply.errorMessage, 'Permission request cancelled.');
        await closeA;
        await harness.manager.resumeSession(
          sessionId: harness.sessionId,
          workspaceRoot: '/tmp',
        );
        final generationB = harness.manager.sessionGenerationForTesting(
          harness.sessionId,
        );
        expect(identical(generationA, generationB), isFalse);
        final ownerB = harness.manager.beginPromptTurn(harness.sessionId);
        harness.releaseOrdinaryPermits();
        await pumpEventQueue();
        expect(harness.permissions.requests, isEmpty);
        expect(harness.terminals.createCalls, 0);
        expect(
          () => harness.manager.beginPromptTurn(harness.sessionId),
          throwsStateError,
        );
        expect(ownedA.responseCommitCount, 1);
        await ownedA.settled;
        harness.manager.endPromptTurn(ownerB);
      } finally {
        await harness.dispose();
      }
    },
  );

  for (final setupMethod in <String>['resume', 'load']) {
    test(
      '$setupMethod rollback invalidates frozen permission generation before retry',
      () async {
        final harness = await _PermissionAdmissionHarness.start(
          controlFutureSetups: true,
        );
        try {
          final generationA = harness.manager.sessionGenerationForTesting(
            harness.sessionId,
          );
          expect(generationA, isNotNull);
          final setup = setupMethod == 'resume'
              ? harness.manager.resumeSession(
                  sessionId: harness.sessionId,
                  workspaceRoot: '/tmp',
                )
              : harness.manager.loadSession(
                  sessionId: harness.sessionId,
                  workspaceRoot: '/tmp',
                );
          final setupError = setup.then<Object?>(
            (_) => null,
            onError: (Object error, StackTrace _) => error,
          );
          await harness
              .waitForSetupRequest(0)
              .timeout(const Duration(seconds: 2));
          final stale = await harness.admit('fs/read_text_file');
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));

          harness.completeSetupError(0, '$setupMethod rollback canary');
          expect(
            await setupError.timeout(const Duration(seconds: 2)),
            isNotNull,
          );
          expect(
            identical(
              generationA,
              harness.manager.sessionGenerationForTesting(harness.sessionId),
            ),
            isTrue,
          );
          harness.permissions.completeAllow(0);
          final staleReply = await stale.response.timeout(
            const Duration(seconds: 2),
          );
          expect(staleReply.errorCode, -32003);
          await stale.settled.timeout(const Duration(seconds: 2));
          expect(harness.fs.readCalls, 0);

          final retry = setupMethod == 'resume'
              ? harness.manager.resumeSession(
                  sessionId: harness.sessionId,
                  workspaceRoot: '/tmp',
                )
              : harness.manager.loadSession(
                  sessionId: harness.sessionId,
                  workspaceRoot: '/tmp',
                );
          await harness
              .waitForSetupRequest(1)
              .timeout(const Duration(seconds: 2));
          harness.completeSetupSuccess(1);
          await retry.timeout(const Duration(seconds: 2));
          final generationC = harness.manager.sessionGenerationForTesting(
            harness.sessionId,
          );
          expect(generationC, isNotNull);
          expect(identical(generationA, generationC), isFalse);

          final current = await harness.admit('fs/read_text_file');
          await harness.permissions
              .waitForRequest(1)
              .timeout(const Duration(seconds: 2));
          harness.permissions.completeAllow(1);
          expect(
            (await current.response.timeout(const Duration(seconds: 2))).result,
            <String, Object?>{'content': 'ok'},
          );
          await current.settled.timeout(const Duration(seconds: 2));
          expect(harness.fs.readCalls, 1);
        } finally {
          await harness.dispose();
        }
      },
    );
  }

  for (final lateCase in <({String name, String method, bool lateError})>[
    (
      name: 'filesystem late value',
      method: 'fs/read_text_file',
      lateError: false,
    ),
    (
      name: 'filesystem late error',
      method: 'fs/read_text_file',
      lateError: true,
    ),
    (name: 'terminal late error', method: 'terminal/create', lateError: true),
  ]) {
    test(
      'setup rollback overrides ${lateCase.name} after side effect starts',
      () async {
        const canary = 'ROLLBACK-LATE-RESULT-CANARY';
        final harness = await _PermissionAdmissionHarness.start(
          controlFutureSetups: true,
        );
        final zoneErrors = <Object>[];
        try {
          if (lateCase.method == 'fs/read_text_file') {
            harness.fs.readResult = Completer<String>();
          } else {
            harness.terminals.createResult =
                Completer<acp.TerminalProcessHandle>();
          }
          final generationA = harness.manager.sessionGenerationForTesting(
            harness.sessionId,
          );
          final setup = harness.manager.resumeSession(
            sessionId: harness.sessionId,
            workspaceRoot: '/tmp',
          );
          final setupError = setup.then<Object?>(
            (_) => null,
            onError: (Object error, StackTrace _) => error,
          );
          await harness
              .waitForSetupRequest(0)
              .timeout(const Duration(seconds: 2));
          final stale = await harness.admit(lateCase.method);
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));
          harness.permissions.completeAllow(0);
          await (lateCase.method == 'fs/read_text_file'
                  ? harness.fs.readStarted.future
                  : harness.terminals.createStarted.future)
              .timeout(const Duration(seconds: 2));

          harness.completeSetupError(0, 'setup rollback canary');
          expect(
            await setupError.timeout(const Duration(seconds: 2)),
            isNotNull,
          );
          expect(
            identical(
              generationA,
              harness.manager.sessionGenerationForTesting(harness.sessionId),
            ),
            isTrue,
          );

          _RpcReply? reply;
          await runZonedGuarded(() async {
            if (lateCase.method == 'fs/read_text_file') {
              if (lateCase.lateError) {
                harness.fs.readResult!.completeError(StateError(canary));
              } else {
                harness.fs.readResult!.complete(canary);
              }
            } else {
              harness.terminals.createResult!.completeError(StateError(canary));
            }
            reply = await stale.response.timeout(const Duration(seconds: 2));
            await stale.settled.timeout(const Duration(seconds: 2));
          }, (Object error, StackTrace _) => zoneErrors.add(error));

          expect(reply, isNotNull);
          expect(reply!.errorCode, -32003);
          expect(reply!.errorMessage, 'Permission request cancelled.');
          expect(reply!.hasErrorData, isFalse);
          expect(jsonEncode(reply!.raw), isNot(contains(canary)));
          expect(zoneErrors, isEmpty);
          expect(stale.reservationReleaseCount, 1);
          expect(stale.responseCommitCount, 1);
          expect(harness.fs.readCalls + harness.terminals.createCalls, 1);
        } finally {
          await harness.dispose();
        }
      },
    );
  }

  test(
    'generated rollback settles provisional permission before successful retry',
    () async {
      const generatedSessionId = 'generated-rollback-session';
      final harness = await _PermissionAdmissionHarness.start(
        controlFutureSetups: true,
      );
      Future<void>? sourceClose;
      try {
        harness.permissions.onRequest = (options) {
          if (options.sessionId != generatedSessionId || sourceClose != null) {
            return;
          }
          sourceClose = harness.manager.closeSession(
            sessionId: harness.sessionId,
          );
        };
        final generated = harness.manager.forkSession(
          sessionId: harness.sessionId,
          workspaceRoot: '/tmp',
        );
        final generatedError = generated.then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
        await harness
            .waitForSetupRequest(0)
            .timeout(const Duration(seconds: 2));
        harness.completeSetupSuccess(0, sessionId: generatedSessionId);
        final stale = await harness.admit(
          'fs/read_text_file',
          params: <String, dynamic>{
            'sessionId': generatedSessionId,
            'path': '/tmp/generated-input.txt',
          },
        );
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));
        final staleCancellationToken =
            harness.permissions.requests.single.cancellationToken!;
        expect(
          harness.manager.sessionGenerationForTesting(generatedSessionId),
          isNull,
        );
        expect(
          await generatedError.timeout(const Duration(seconds: 2)),
          isNotNull,
        );
        await sourceClose?.timeout(const Duration(seconds: 2));
        harness.permissions.completeAllow(0);
        final staleReply = await stale.response.timeout(
          const Duration(seconds: 2),
        );
        expect(staleReply.errorCode, -32003);
        await stale.settled.timeout(const Duration(seconds: 2));
        expect(stale.reservationReleaseCount, 1);
        expect(stale.responseCommitCount, 1);
        expect(harness.fs.readCalls, 0);
        expect(harness.permissions.cancellations, hasLength(1));
        expect(
          identical(
            harness.permissions.cancellations.single.$1,
            staleCancellationToken,
          ),
          isTrue,
        );

        harness.permissions.onRequest = null;
        final resume = harness.manager.resumeSession(
          sessionId: harness.sessionId,
          workspaceRoot: '/tmp',
        );
        await harness
            .waitForSetupRequest(1)
            .timeout(const Duration(seconds: 2));
        harness.completeSetupSuccess(1);
        await resume.timeout(const Duration(seconds: 2));
        final retry = harness.manager.forkSession(
          sessionId: harness.sessionId,
          workspaceRoot: '/tmp',
        );
        await harness
            .waitForSetupRequest(2)
            .timeout(const Duration(seconds: 2));
        harness.completeSetupSuccess(2, sessionId: generatedSessionId);
        expect(
          (await retry.timeout(const Duration(seconds: 2))).sessionId,
          generatedSessionId,
        );
        final generationC = harness.manager.sessionGenerationForTesting(
          generatedSessionId,
        );
        expect(generationC, isNotNull);

        final current = await harness.admit(
          'fs/read_text_file',
          params: <String, dynamic>{
            'sessionId': generatedSessionId,
            'path': '/tmp/generated-input.txt',
          },
        );
        await harness.permissions
            .waitForRequest(1)
            .timeout(const Duration(seconds: 2));
        expect(
          identical(
            harness.permissions.requests[1].cancellationToken,
            staleCancellationToken,
          ),
          isFalse,
        );
        harness.permissions.completeAllow(1);
        expect(
          (await current.response.timeout(const Duration(seconds: 2))).result,
          <String, Object?>{'content': 'ok'},
        );
        await current.settled.timeout(const Duration(seconds: 2));
        expect(harness.fs.readCalls, 1);
        expect(harness.permissions.cancellations, hasLength(1));
      } finally {
        await sourceClose;
        await harness.dispose();
      }
    },
  );

  test(
    'new session rollback settles only its provisional permission owner',
    () async {
      const generatedSessionId = 'new-rollback-session';
      final harness = await _PermissionAdmissionHarness.start(
        controlFutureSetups: true,
      );
      acp.AcpSessionInputBudgetOwner? provisionalOwner;
      try {
        harness.permissions.onRequest = (options) {
          if (options.sessionId != generatedSessionId ||
              provisionalOwner != null) {
            return;
          }
          final owner = harness.manager.sessionInputOwnerForTesting(
            generatedSessionId,
          );
          if (owner == null) {
            throw StateError('Missing provisional generated-session owner.');
          }
          provisionalOwner = owner;
          harness.manager.endPromptTurn(owner);
        };
        final generated = harness.manager.newSession(workspaceRoot: '/tmp');
        final generatedError = generated.then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
        await harness
            .waitForSetupRequest(0)
            .timeout(const Duration(seconds: 2));
        harness.completeSetupSuccess(0, sessionId: generatedSessionId);
        final stale = await harness.admit(
          'fs/read_text_file',
          params: <String, dynamic>{
            'sessionId': generatedSessionId,
            'path': '/tmp/new-generated-input.txt',
          },
        );
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));
        final staleCancellationToken =
            harness.permissions.requests.single.cancellationToken!;
        expect(provisionalOwner, isNotNull);
        expect(
          await generatedError.timeout(const Duration(seconds: 2)),
          isNotNull,
        );

        harness.permissions.completeAllow(0);
        final staleReply = await stale.response.timeout(
          const Duration(seconds: 2),
        );
        expect(staleReply.errorCode, -32003);
        await stale.settled.timeout(const Duration(seconds: 2));
        expect(stale.reservationReleaseCount, 1);
        expect(stale.responseCommitCount, 1);
        expect(harness.fs.readCalls, 0);
        expect(harness.permissions.cancellations, hasLength(1));
        expect(
          identical(
            harness.permissions.cancellations.single.$1,
            staleCancellationToken,
          ),
          isTrue,
        );

        harness.permissions.onRequest = null;
        final retry = harness.manager.newSession(workspaceRoot: '/tmp');
        await harness
            .waitForSetupRequest(1)
            .timeout(const Duration(seconds: 2));
        harness.completeSetupSuccess(1, sessionId: generatedSessionId);
        expect(
          await retry.timeout(const Duration(seconds: 2)),
          generatedSessionId,
        );
        expect(
          harness.manager.sessionGenerationForTesting(generatedSessionId),
          isNotNull,
        );

        final current = await harness.admit(
          'fs/read_text_file',
          params: <String, dynamic>{
            'sessionId': generatedSessionId,
            'path': '/tmp/new-generated-input.txt',
          },
        );
        await harness.permissions
            .waitForRequest(1)
            .timeout(const Duration(seconds: 2));
        expect(
          identical(
            harness.permissions.requests[1].cancellationToken,
            staleCancellationToken,
          ),
          isFalse,
        );
        harness.permissions.completeAllow(1);
        expect(
          (await current.response.timeout(const Duration(seconds: 2))).result,
          <String, Object?>{'content': 'ok'},
        );
        await current.settled.timeout(const Duration(seconds: 2));
        expect(harness.fs.readCalls, 1);
        expect(harness.permissions.cancellations, hasLength(1));
      } finally {
        await harness.dispose();
      }
    },
  );

  test(
    'bridge first and manager first timeouts classify every running permission entry once',
    () async {
      const canary = 'PERMISSION-TIMEOUT-CANARY';
      for (final entry in permissionEntries) {
        for (final bridgeFirst in <bool>[false, true]) {
          final harness = await _PermissionAdmissionHarness.start(
            timeouts: const acp.AcpTimeouts(
              permission: Duration(milliseconds: 75),
            ),
          );
          try {
            final params = harness.paramsFor(entry.method)..['canary'] = canary;
            final request = await harness.admit(entry.method, params: params);
            await harness.permissions
                .waitForRequest(0)
                .timeout(const Duration(seconds: 2));
            if (bridgeFirst) harness.permissions.completeTimeout(0);
            final reply = await request.response.timeout(
              const Duration(seconds: 2),
            );
            if (entry.method == 'session/request_permission') {
              expect(reply.result, <String, Object?>{
                'outcome': <String, Object?>{'outcome': 'cancelled'},
              });
            } else {
              expect(reply.errorCode, -32002);
              expect(reply.errorMessage, 'Permission request timed out.');
              expect(reply.hasErrorData, isFalse);
            }
            expect(reply.raw.toString(), isNot(contains(canary)));
            expect(harness.permissions.cancellations, hasLength(1));
            expect(request.reservationReleaseCount, 1);
            expect(request.responseCommitCount, 1);
          } finally {
            await harness.dispose();
          }
        }
      }
    },
  );

  test(
    'terminal permission timeout and close release pending lease before replacement',
    () async {
      for (final cause in <String>['timeout', 'sessionClosed']) {
        final harness = await _PermissionAdmissionHarness.start(
          timeouts: const acp.AcpTimeouts(
            permission: Duration(milliseconds: 75),
          ),
        );
        try {
          final first = await harness.admit('terminal/create');
          await harness.permissions
              .waitForRequest(0)
              .timeout(const Duration(seconds: 2));
          if (cause == 'sessionClosed') {
            await harness.manager.closeSession(sessionId: harness.sessionId);
            await harness.manager.resumeSession(
              sessionId: harness.sessionId,
              workspaceRoot: '/tmp',
            );
          }
          final firstReply = await first.response.timeout(
            const Duration(seconds: 2),
          );
          expect(firstReply.errorCode, cause == 'timeout' ? -32002 : -32003);
          final replacement = await harness.admit('terminal/create');
          await harness.permissions
              .waitForRequest(1)
              .timeout(const Duration(seconds: 2));
          harness.permissions.completeAllow(1);
          final replacementReply = await replacement.response.timeout(
            const Duration(seconds: 2),
          );
          expect(replacementReply.errorCode, isNull);
          expect(harness.terminals.createCalls, 1);
        } finally {
          await harness.dispose();
        }
      }
    },
  );

  test(
    'manager dispose cleans pending terminal admission exactly once',
    () async {
      final harness = await _PermissionAdmissionHarness.start();
      try {
        final first = await harness.admit('terminal/create');
        await harness.permissions
            .waitForRequest(0)
            .timeout(const Duration(seconds: 2));
        expect(harness.manager.terminalLeaseCountForTesting, 1);
        expect(harness.manager.pendingTerminalLeaseCountForTesting, 1);

        final dispose = harness.manager.dispose();
        expect(harness.manager.terminalLeaseCountForTesting, 0);
        expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
        await dispose;
        harness.permissions.completeAllow(0);

        final firstReply = await first.response.timeout(
          const Duration(seconds: 2),
        );
        expect(firstReply.errorCode, -32000);
        expect(firstReply.errorMessage, 'ACP connection closed.');
        await first.settled.timeout(const Duration(seconds: 2));
        expect(harness.permissions.cancellations, hasLength(1));
        expect(
          harness.permissions.cancellations.single.$2,
          acp.PermissionCancellationReason.disposed,
        );
        expect(first.reservationReleaseCount, 1);
        expect(first.responseCommitCount, 1);
        expect(harness.terminals.createCalls, 0);
        expect(harness.manager.terminalLeaseCountForTesting, 0);
        expect(harness.manager.pendingTerminalLeaseCountForTesting, 0);
      } finally {
        await harness.dispose();
      }
    },
  );

  test('request deadlines close and flush pending operations once', () async {
    for (final initializeFirst in <bool>[true, false]) {
      final harness = _RequestHarness(
        acp.AcpTimeouts(
          initialize: Duration(milliseconds: initializeFirst ? 60 : 1000),
          request: Duration(milliseconds: initializeFirst ? 1000 : 60),
        ),
      );
      final states = <AcpPeerUnavailableState>[];
      void listener(AcpPeerUnavailableState state) => states.add(state);
      harness.peer.addUnavailableListener(listener);
      try {
        final Future<Object?> first = initializeFirst
            ? harness.peer.initialize(<String, dynamic>{})
            : harness.peer.sendRaw('agent/first', <String, dynamic>{});
        final firstFailure = expectLater(
          first.timeout(const Duration(seconds: 2)),
          throwsA(
            isA<acp.AcpRequestTimeoutException>().having(
              (error) => error.toString(),
              'text',
              'ACP request timed out.',
            ),
          ),
        );
        await harness.takeRequest();
        final Future<Object?> sibling = initializeFirst
            ? harness.peer.sendRaw('agent/sibling', <String, dynamic>{})
            : harness.peer.initialize(<String, dynamic>{});
        final siblingFailure = expectLater(
          sibling.timeout(const Duration(seconds: 2)),
          throwsA(
            isA<acp.AcpConnectionClosedException>().having(
              (error) => error.toString(),
              'text',
              'ACP connection closed.',
            ),
          ),
        );
        await harness.takeRequest();
        await firstFailure;
        await siblingFailure;
        expect(states.map((state) => state.reason), <AcpPeerUnavailableReason>[
          AcpPeerUnavailableReason.fatalTimeout,
        ]);
        expect(harness.sink.closeCount, 1);
        await expectLater(
          harness.peer.sendRaw('CANARY-METHOD', <String, dynamic>{
            'p': 'CANARY',
          }),
          throwsA(
            isA<acp.AcpConnectionClosedException>().having(
              (error) => error.toString(),
              'text',
              'ACP connection closed.',
            ),
          ),
        );
      } finally {
        harness.peer.removeUnavailableListener(listener);
        await harness.dispose();
      }
    }
  });

  test(
    'request deadline races consume late responses without zone errors',
    () async {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final early = _RequestHarness(
          const acp.AcpTimeouts(request: Duration(milliseconds: 80)),
        );
        try {
          final result = early.peer.sendRaw('agent/early', <String, dynamic>{});
          final sent = await early.takeRequest();
          early.respond(sent['id'], <String, dynamic>{'ok': true});
          expect(await result, <String, dynamic>{'ok': true});
          await Future<void>.delayed(const Duration(milliseconds: 120));
          expect(early.peer.isAvailable, isTrue);
          expect(early.sink.closeCount, 0);
        } finally {
          await early.dispose();
        }

        final late = _RequestHarness(
          const acp.AcpTimeouts(request: Duration(milliseconds: 60)),
        );
        try {
          final result = late.peer.sendRaw('agent/late', <String, dynamic>{});
          final failure = expectLater(
            result,
            throwsA(isA<acp.AcpRequestTimeoutException>()),
          );
          final sent = await late.takeRequest();
          await failure;
          late.respond(sent['id'], <String, dynamic>{'late': 1});
          late.respond(sent['id'], <String, dynamic>{'late': 2});
          await pumpEventQueue();
          expect(late.sink.closeCount, 1);
        } finally {
          await late.dispose();
        }

        for (final reason in <AcpPeerUnavailableReason>[
          AcpPeerUnavailableReason.explicitClose,
          AcpPeerUnavailableReason.disposed,
        ]) {
          final closed = _RequestHarness(
            const acp.AcpTimeouts(request: Duration(milliseconds: 150)),
          );
          try {
            final result = closed.peer.sendRaw(
              'agent/close-race',
              <String, dynamic>{},
            );
            final failure = expectLater(
              result,
              throwsA(isA<acp.AcpConnectionClosedException>()),
            );
            await closed.takeRequest();
            await closed.peer.closeForTesting(reason);
            await failure;
            await Future<void>.delayed(const Duration(milliseconds: 180));
            expect(closed.sink.closeCount, 1);
          } finally {
            await closed.dispose();
          }
        }
      }, (Object error, StackTrace stackTrace) => zoneErrors.add(error));
      expect(zoneErrors, isEmpty);
    },
  );

  test(
    'reentrant transport close publishes state and blocks all writes',
    () async {
      const canary = 'REENTRANT-OUTPUT-CANARY';
      final input = _ReentrantInputStream();
      final outputController = StreamController<String>(sync: true);
      final outputSubscription = outputController.stream.listen((_) {});
      final sink = _CountingStringSink(outputController.sink);
      final peer = JsonRpcPeer(
        StreamChannel<String>(input, sink),
        timeouts: const acp.AcpTimeouts(),
      );
      final states = <AcpPeerUnavailableState>[];
      AcpPeerUnavailableState? replayed;
      var replayCalls = 0;
      late Future<Object?> closeSettled;
      var reusedCloseOwner = false;
      late Future<Object?> rawSettled;
      late Future<Object?> promptSettled;
      late Future<Object?> cancelSettled;
      late Future<Object?> notificationSettled;
      void replayListener(AcpPeerUnavailableState state) {
        replayCalls += 1;
        replayed = state;
      }

      final pendingSettled = peer
          .sendRaw('agent/pending', <String, dynamic>{})
          .then<Object?>((value) => value, onError: (Object error, _) => error);
      expect(sink.events, hasLength(1));
      final pendingRequest =
          jsonDecode(sink.events.single) as Map<String, dynamic>;
      final pendingId = pendingRequest['id'];
      sink.events.clear();
      void listener(AcpPeerUnavailableState state) {
        states.add(state);
        input.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': pendingId,
            'result': <String, dynamic>{'late': true},
          }),
        );
      }

      peer.addUnavailableListener(listener);
      final updates = peer.sessionUpdates.listen((_) {
        input.addError(_ReentrantTransportError(), StackTrace.current);
        expect(peer.isAvailable, isFalse);
        final closing = peer.close();
        reusedCloseOwner = identical(closing, peer.dispose());
        closeSettled = closing.then<Object?>(
          (_) => null,
          onError: (Object error, StackTrace _) => error,
        );
        peer.addUnavailableListener(replayListener);
        rawSettled = peer
            .sendRaw('CANARY-METHOD', <String, dynamic>{'value': canary})
            .then<Object?>(
              (value) => value,
              onError: (Object error, _) => error,
            );
        promptSettled = peer
            .prompt(<String, dynamic>{
              'sessionId': canary,
              'prompt': <Map<String, dynamic>>[
                <String, dynamic>{'type': 'text', 'text': canary},
              ],
            })
            .then<Object?>(
              (value) => value,
              onError: (Object error, _) => error,
            );
        cancelSettled = peer
            .cancel(<String, dynamic>{'sessionId': canary})
            .then<Object?>((_) => null, onError: (Object error, _) => error);
        notificationSettled = peer
            .sendNotificationRaw('CANARY-NOTIFICATION', <String, dynamic>{
              'value': canary,
            })
            .then<Object?>((_) => null, onError: (Object error, _) => error);
      });

      try {
        input.add(
          jsonEncode(<String, dynamic>{
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': <String, dynamic>{'sequence': 1},
          }),
        );
        expect(reusedCloseOwner, isTrue);
        expect(states, hasLength(1));
        expect(states.single.reason, AcpPeerUnavailableReason.transportClosed);
        expect(replayed, same(states.single));
        expect(replayCalls, 1);
        expect(sink.events, isEmpty);
        expect(await pendingSettled, isA<acp.AcpConnectionClosedException>());
        expect(await rawSettled, isA<acp.AcpConnectionClosedException>());
        expect(await promptSettled, isA<acp.AcpConnectionClosedException>());
        expect(await cancelSettled, isNull);
        expect(await notificationSettled, isNull);
        expect(
          await closeSettled.timeout(const Duration(seconds: 2)),
          isA<_ReentrantTransportError>(),
        );
        expect(sink.events.join(), isNot(contains(canary)));
        expect(sink.closeCount, 1);
      } finally {
        peer.removeUnavailableListener(listener);
        peer.removeUnavailableListener(replayListener);
        await updates.cancel();
        try {
          await peer.close();
        } on Object {
          // The transport error winner is asserted above.
        }
        input.close();
        await outputSubscription.cancel();
        await outputController.close();
      }
    },
  );

  test('prompt request derives session only from its owner', () async {
    final harness = _RequestHarness(const acp.AcpTimeouts());
    const owner = _TestPromptOwner('owner-session', 7);
    try {
      final result = harness.peer.sendPromptRequest(
        owner: owner,
        content: const <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'safe'},
        ],
        onTerminal: (_, _) => JsonRpcPromptSettlement(Future<void>.value()),
      );
      final sent = await harness.takeRequest();
      expect(sent['method'], 'session/prompt');
      expect((sent['params'] as Map)['sessionId'], owner.sessionId);
      expect(harness.peer.promptOwnerOperationCountForTesting, 1);
      expect(harness.peer.promptSessionOperationCountForTesting, 1);
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
      expect(harness.peer.promptOwnerOperationCountForTesting, 0);
      expect(harness.peer.promptSessionOperationCountForTesting, 0);
    } finally {
      await harness.dispose();
    }
  });

  test('prompt terminal hook failure reaps owner operation', () async {
    final harness = _RequestHarness(const acp.AcpTimeouts());
    const owner = _TestPromptOwner('hook-failure-session', 9);
    try {
      final result = harness.peer.sendPromptRequest(
        owner: owner,
        content: const <Map<String, dynamic>>[],
        onTerminal: (_, _) => throw StateError('fixed terminal hook failure'),
      );
      final sent = await harness.takeRequest();
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      await expectLater(
        result,
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'fixed terminal hook failure',
          ),
        ),
      );
      expect(harness.peer.promptOwnerOperationCountForTesting, 0);
      expect(harness.peer.promptSessionOperationCountForTesting, 0);
    } finally {
      await harness.dispose();
    }
  });

  test(
    'prompt timeout hook failure cancels and removes owner before late result',
    () async {
      for (final lateError in <bool>[false, true]) {
        await _expectNoZoneErrors(() async {
          final harness = _RequestHarness(const acp.AcpTimeouts());
          const owner = _TestPromptOwner('timeout-hook-failure-session', 10);
          try {
            var terminalCalls = 0;
            final result = _observeFuture(
              harness.peer.sendPromptRequest(
                owner: owner,
                content: const <Map<String, dynamic>>[],
                onTerminal: (_, _) {
                  terminalCalls += 1;
                  throw StateError('fixed timeout terminal hook failure');
                },
              ),
            );
            final sent = await harness.takeRequest();
            harness.peer.firePromptDeadlineForTesting(owner);
            final early = await result.timeout(
              const Duration(milliseconds: 100),
            );
            final ownerCountBeforeLate =
                harness.peer.promptOwnerOperationCountForTesting;
            final sessionCountBeforeLate =
                harness.peer.promptSessionOperationCountForTesting;
            final cancelCount = harness.sink.events.where((event) {
              final decoded = jsonDecode(event);
              return decoded is Map && decoded['method'] == 'session/cancel';
            }).length;

            if (lateError) {
              harness.respondError(
                sent['id'],
                code: -32000,
                message: 'fixed late prompt error',
              );
            } else {
              harness.respond(sent['id'], <String, dynamic>{
                'stopReason': 'end_turn',
              });
            }
            await pumpEventQueue();

            expect(
              early.error,
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'fixed timeout terminal hook failure',
              ),
            );
            expect(terminalCalls, 1);
            expect(cancelCount, 1);
            expect(ownerCountBeforeLate, 0);
            expect(sessionCountBeforeLate, 0);
            expect(harness.peer.promptOwnerOperationCountForTesting, 0);
            expect(harness.peer.promptSessionOperationCountForTesting, 0);
          } finally {
            await harness.dispose();
          }
        });
      }
    },
  );

  test('sendRaw session/prompt keeps its legacy ownerless path', () async {
    final harness = _RequestHarness(const acp.AcpTimeouts());
    try {
      final result = harness.peer.sendRaw('session/prompt', <String, dynamic>{
        'sessionId': 'legacy-session',
        'prompt': const <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'legacy'},
        ],
      });
      final sent = await harness.takeRequest();
      expect(sent['method'], 'session/prompt');
      expect(harness.peer.promptOwnerOperationCountForTesting, 0);
      expect(harness.peer.promptSessionOperationCountForTesting, 0);
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
      expect(harness.peer.promptOwnerOperationCountForTesting, 0);
      expect(harness.peer.promptSessionOperationCountForTesting, 0);
    } finally {
      await harness.dispose();
    }
  });

  test('ACP timeout defaults and validation are exact', () {
    const defaults = acp.AcpTimeouts();
    expect(defaults.initialize, const Duration(seconds: 15));
    expect(defaults.request, const Duration(seconds: 60));
    expect(defaults.prompt, const Duration(minutes: 30));
    expect(defaults.permission, const Duration(minutes: 5));
    expect(defaults.promptCancelGrace, const Duration(seconds: 2));

    final invalid = <acp.AcpTimeouts>[
      const acp.AcpTimeouts(initialize: Duration.zero),
      const acp.AcpTimeouts(initialize: Duration(microseconds: -1)),
      const acp.AcpTimeouts(request: Duration.zero),
      const acp.AcpTimeouts(request: Duration(microseconds: -1)),
      const acp.AcpTimeouts(prompt: Duration.zero),
      const acp.AcpTimeouts(prompt: Duration(microseconds: -1)),
      const acp.AcpTimeouts(permission: Duration.zero),
      const acp.AcpTimeouts(permission: Duration(microseconds: -1)),
      const acp.AcpTimeouts(promptCancelGrace: Duration.zero),
      const acp.AcpTimeouts(promptCancelGrace: Duration(microseconds: -1)),
    ];
    for (final timeouts in invalid) {
      expect(() => acp.AcpConfig(timeouts: timeouts), throwsArgumentError);
    }
  });

  test('invalid timeouts fail before transport construction', () async {
    final transport = _StartCountingTransport();
    final timeouts = _SecondValidationFailsTimeouts();
    final config = acp.AcpConfig(timeouts: timeouts);
    try {
      await expectLater(
        acp.AcpClient.start(config: config, transport: transport),
        throwsArgumentError,
      );
      expect(timeouts.validationCount, 2);
      expect(transport.startCount, 0);
      expect(transport.stopCount, 0);
      expect(
        () => DartAcpAgentClient(
          timeouts: const acp.AcpTimeouts(request: Duration.zero),
        ),
        throwsArgumentError,
      );
    } finally {
      await transport.dispose();
    }
  });

  test('timeout exceptions and cancellation tokens do not leak context', () {
    expect(
      const acp.AcpRequestTimeoutException().toString(),
      'ACP request timed out.',
    );
    expect(
      const acp.AcpPromptTimeoutException().toString(),
      'ACP prompt timed out.',
    );
    expect(
      const acp.AcpConnectionClosedException().toString(),
      'ACP connection closed.',
    );
    expect(
      const acp.PermissionRequestTimeoutException().toString(),
      'Permission request timed out.',
    );

    final token = _SecretToken();
    final options = acp.PermissionOptions(
      title: 'safe',
      rationale: 'safe',
      options: const <String>['allow'],
      sessionId: 'safe-session',
      toolName: 'safe-tool',
      cancellationToken: token,
      metadata: const <String, Object?>{'safe': true},
    );
    expect(options.cancellationToken, same(token));
    expect(options.metadata.values, isNot(contains(same(token))));
    expect(jsonEncode(options.metadata), isNot(contains('TOKEN-CANARY')));
    expect(options.toString(), isNot(contains('TOKEN-CANARY')));
  });
}
