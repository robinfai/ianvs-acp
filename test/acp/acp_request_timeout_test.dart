import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:dart_acp/src/rpc/inbound_gate.dart';
import 'package:dart_acp/src/rpc/peer.dart';
import 'package:dart_acp/src/session/session_manager.dart' show SessionManager;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
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
  final Completer<void> createStarted = Completer<void>();
  final Completer<void> releaseStarted = Completer<void>();
  Completer<acp.TerminalProcessHandle>? createResult;

  Future<acp.TerminalProcessHandle> createLateHandle(String sessionId) =>
      _inner.create(sessionId: sessionId, command: '/usr/bin/true');

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
    return _inner.release(handle).then<void>((_) {
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
        return operation();
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
  }) async {
    final channel = StreamChannelController<String>();
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
    final peer = JsonRpcPeer(
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
    await manager.resumeSession(
      sessionId: harness.sessionId,
      workspaceRoot: '/tmp',
    );
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
      );
      final sent = await harness.takeRequest();
      expect(sent['method'], 'session/prompt');
      expect((sent['params'] as Map)['sessionId'], owner.sessionId);
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
    } finally {
      await harness.dispose();
    }
  });

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
      harness.respond(sent['id'], <String, dynamic>{'stopReason': 'end_turn'});
      expect(await result, <String, dynamic>{'stopReason': 'end_turn'});
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
