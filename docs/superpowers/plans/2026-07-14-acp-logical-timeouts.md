# ACP 逻辑请求超时 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 ACP initialize、普通请求、typed/raw prompt 和四类权限请求增加统一且有限的逻辑截止时间，并在 timeout、cancel、close、dispose、迟到结果竞态下精确释放 peer pending、入站门禁、权限卡片和 terminal 租约。

**Architecture:** `JsonRpcPeer` 统一拥有出站 request deadline、内部 correlation tracker 和带原因的不可用状态；`InboundGate` 提供可短路排队请求与运行中逻辑脱离；`SessionManager` 在入站接纳时冻结 session/prompt/peer 快照，用组合 barrier 管理 prompt RPC、permission reservation 与 response commit；应用层只投射 owner-bound raw prompt 终态和 reason-bearing permission invalidation。

**Tech Stack:** Dart、Flutter、`json_rpc_2`、ACP stdio/WebSocket/Streamable HTTP transport、`flutter_test`、本地 `HttpServer`/SSE。

---

## 执行约束

- **Task 1 的硬前置：**批准规格与本计划必须已经作为一个仅含文档的独立提交进入当前 `HEAD`；执行者不得一边实施一边补交规格/计划。开始 Task 1 前运行 `git show --stat --oneline HEAD`、`git ls-tree -r --name-only HEAD -- docs/superpowers/specs/2026-07-14-acp-logical-timeouts-design.md docs/superpowers/plans/2026-07-14-acp-logical-timeouts.md` 与 `git diff --exit-code HEAD -- docs/superpowers/specs/2026-07-14-acp-logical-timeouts-design.md docs/superpowers/plans/2026-07-14-acp-logical-timeouts.md`。Expected: `HEAD` 是只包含这两份文档的提交，两个路径都由 `ls-tree` 列出，`git diff` exit 0。任一条件不满足就停止，不得开始 Task 1。
- 每个任务先写指定 RED，再做最小实现；未观察到预期失败不得进入实现步骤。
- 单元测试使用 50–100 ms 注入时限、2 秒外层 watchdog；先等待 request/admission 已发生的 `Completer`，再等待超时。
- heartbeat 使用 10–20 ms，transport `sseIdleTimeout` 至少 1 秒；每个测试在 `finally` 关闭 Timer、SSE response、stream、server 和 blocker。
- timeout/close/cancel 新路径只使用规格固定错误，不记录 method、params、sessionId、prompt、tool、token、路径、provider error 或 stack canary。
- 每个提交前运行该任务的定向测试、`dart format` 和 `git diff --check`；不要顺手改 Task26–30 的范围。

### Task 1: 公开时限、固定异常与权限取消原语

**Files:**
- Modify: `third_party/dart_acp/lib/src/config.dart`
- Modify: `third_party/dart_acp/lib/src/providers/permission_provider.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Create: `test/acp/acp_request_timeout_test.dart`
- Verify: `test/acp/acp_client_inbound_gate_lifecycle_test.dart`

- [ ] 1. 新建测试文件并加入可复用的 transport；它记录 `startCount`，并在 `finally` 可关闭 input/sink：

```dart
import 'dart:async';
import 'dart:convert';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';
import 'package:stream_channel/stream_channel.dart';

final class _StartCountingTransport implements acp.AcpTransport {
  final StreamController<String> _input =
      StreamController<String>(sync: true);
  final StreamController<String> _output =
      StreamController<String>(sync: true);
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
    await _input.close();
    await _output.close();
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
```

- [ ] 2. 写 named RED `ACP timeout defaults and validation are exact`：

```dart
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
```

- [ ] 3. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "ACP timeout defaults and validation are exact"`。Expected: FAIL at compile time because old `AcpTimeouts` has no `request` or `promptCancelGrace`, and `prompt`/`permission` are nullable。

- [ ] 4. 写 named RED `invalid timeouts fail before transport construction`；第二次校验必须是 `AcpClient.start` 的第一条可失败语句，且 wrapper 构造时拒绝非法值：

```dart
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
```

- [ ] 5. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "invalid timeouts fail before transport construction"`。Expected: FAIL at compile time because `validate()` and wrapper `timeouts` do not exist; without those additions old `AcpClient.start` would call `transport.start()`。

- [ ] 6. 写 named RED `timeout exceptions and cancellation tokens do not leak context`：

```dart
test('timeout exceptions and cancellation tokens do not leak context', () {
  expect(const acp.AcpRequestTimeoutException().toString(),
      'ACP request timed out.');
  expect(const acp.AcpPromptTimeoutException().toString(),
      'ACP prompt timed out.');
  expect(const acp.AcpConnectionClosedException().toString(),
      'ACP connection closed.');
  expect(const acp.PermissionRequestTimeoutException().toString(),
      'Permission request timed out.');

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
```

- [ ] 7. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "timeout exceptions and cancellation tokens do not leak context"`。Expected: FAIL at compile time because the four fixed exception/token APIs are absent。

- [ ] 8. 在 `config.dart` 写入完整有限默认值、校验与三种出站异常：

```dart
class AcpTimeouts {
  const AcpTimeouts({
    this.initialize = const Duration(seconds: 15),
    this.request = const Duration(seconds: 60),
    this.prompt = const Duration(minutes: 30),
    this.permission = const Duration(minutes: 5),
    this.promptCancelGrace = const Duration(seconds: 2),
  });

  final Duration initialize;
  final Duration request;
  final Duration prompt;
  final Duration permission;
  final Duration promptCancelGrace;

  void validate() {
    if (initialize <= Duration.zero ||
        request <= Duration.zero ||
        prompt <= Duration.zero ||
        permission <= Duration.zero ||
        promptCancelGrace <= Duration.zero) {
      throw ArgumentError('ACP timeouts must be positive.');
    }
  }
}

final class AcpRequestTimeoutException implements Exception {
  const AcpRequestTimeoutException();
  @override
  String toString() => 'ACP request timed out.';
}

final class AcpPromptTimeoutException implements Exception {
  const AcpPromptTimeoutException();
  @override
  String toString() => 'ACP prompt timed out.';
}

final class AcpConnectionClosedException implements Exception {
  const AcpConnectionClosedException();
  @override
  String toString() => 'ACP connection closed.';
}
```

- [ ] 9. 在 `permission_provider.dart` 增加本地 token、权限 timeout 与精确取消接口；`PermissionOptions` 不覆写 `toString()`，且任何 JSON/metadata 组装点不得读取 token：

```dart
class PermissionOptions {
  PermissionOptions({
    required this.title,
    required this.rationale,
    required this.options,
    required this.sessionId,
    required this.toolName,
    this.choices = const <PermissionChoice>[],
    this.toolKind,
    this.metadata = const <String, Object?>{},
    this.transientPolicyContext = const <String, Object?>{},
    this.cancellationToken,
  });

  // Keep all existing fields unchanged.
  final Object? cancellationToken;
}

final class PermissionRequestTimeoutException implements Exception {
  const PermissionRequestTimeoutException();
  @override
  String toString() => 'Permission request timed out.';
}

enum PermissionCancellationReason {
  timedOut,
  promptEnded,
  promptCancelled,
  sessionClosed,
  connectionClosed,
  disposed,
}

abstract interface class CancellablePermissionProvider
    implements PermissionProvider {
  void cancelPendingPermission({
    required Object cancellationToken,
    required PermissionCancellationReason reason,
  });
}
```

- [ ] 10. 保持 `dart_acp.dart` 对 `config.dart` 与 `permission_provider.dart` 的公开导出，并加入编译期 show-list 检查（若改为精确导出，必须包含四异常、reason 与 cancellable provider）；运行 `rg -n "export 'src/(config|providers/permission_provider)\.dart'" third_party/dart_acp/lib/dart_acp.dart`。Expected: 两个公开导出均存在。

- [ ] 11. 在现有 `AcpConfig` 参数表中把 `this.timeouts = const AcpTimeouts()` 替换为局部参数 `AcpTimeouts timeouts = const AcpTimeouts()`；在现有 initializer list 最前面加入下列赋值与 helper：

```dart
// Constructor parameter replacement:
AcpTimeouts timeouts = const AcpTimeouts(),

// First initializer:
timeouts = _validatedAcpTimeouts(timeouts),

static AcpTimeouts _validatedAcpTimeouts(AcpTimeouts value) {
  value.validate();
  return value;
}
```

- [ ] 12. 在 `AcpClient.start` 的方法体第一行加入 `config.timeouts.validate();`，保持它早于 `inputBudget.validate()`、transport 选择/构造和 `actualTransport.start()`。

- [ ] 13. 在现有 `DartAcpAgentClient` 参数表加入 timeouts，在 initializer list 最前面校验，在字段区保存，并在 connect 的现有 `AcpConfig` 参数中加入同一实例：

```dart
// Constructor parameter:
acp.AcpTimeouts timeouts = const acp.AcpTimeouts(),

// First initializer:
timeouts = _validatedAcpTimeouts(timeouts),

final acp.AcpTimeouts timeouts;

static acp.AcpTimeouts _validatedAcpTimeouts(acp.AcpTimeouts value) {
  value.validate();
  return value;
}

// Add to the existing AcpConfig call in connect():
timeouts: timeouts,
```

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "ACP timeout defaults and validation are exact"`。Expected: PASS。

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "invalid timeouts fail before transport construction"`。Expected: PASS。

- [ ] 16. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "timeout exceptions and cancellation tokens do not leak context"`。Expected: PASS。

- [ ] 17. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/acp_client_inbound_gate_lifecycle_test.dart`。Expected: PASS。

- [ ] 18. 运行 `dart format third_party/dart_acp/lib/src/config.dart third_party/dart_acp/lib/src/providers/permission_provider.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart`。Expected: exit 0。

- [ ] 19. 运行 `git diff --check`。Expected: exit 0，无输出。

- [ ] 20. 运行 `git add third_party/dart_acp/lib/src/config.dart third_party/dart_acp/lib/src/providers/permission_provider.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart`。

- [ ] 21. 运行 `git commit -m "feat: define ACP logical timeouts"`。Expected: commit 成功。

### Task 2: 可取消入站 reservation 与运行中逻辑脱离

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `third_party/dart_acp/lib/src/rpc/inbound_gate.dart`
- Modify: `test/acp/inbound_gate_test.dart`

- [ ] 1. 根测试会直接 import `package:json_rpc_2/json_rpc_2.dart`；先在根 `pubspec.yaml` 的 `dev_dependencies` 增加直接测试依赖，后续 Task 3/6 的根测试统一复用，不得依赖 `third_party/dart_acp` 的传递依赖：

```yaml
dev_dependencies:
  flutter_test:
    sdk: flutter
  json_rpc_2: ^4.0.0
```

- [ ] 2. 运行 `flutter pub get`。Expected: exit 0；`pubspec.lock` 保持解析到兼容的 `json_rpc_2 4.x`，且不改动无关 dependency constraint。

- [ ] 3. 运行以下 lock 归属检查：

```bash
awk '/^  json_rpc_2:$/ { found=1; next } found && /dependency:/ { print; exit }' pubspec.lock
```

Expected: 精确输出 `dependency: "direct dev"`；若仍为 `transitive`，不得继续写 RED。

- [ ] 4. 在 `test/acp/inbound_gate_test.dart` 增加 `package:json_rpc_2/json_rpc_2.dart` 的 `rpc` import，并写 named RED `queued terminal short circuits before handler invocation`；同步 `started` 后才结算 terminal，`finally` 必须释放唯一 blocker：

```dart
test('queued terminal short circuits before handler invocation', () async {
  final gate = InboundGate(
    maxConcurrentHandlers: 3,
    maxOrdinaryConcurrentHandlers: 1,
  );
  final reservations = gate.tryReserveBatch(const <InboundGateElement>[
    InboundGateElement(method: 'fs/read_text_file', byteLength: 3),
    InboundGateElement(method: 'fs/write_text_file', byteLength: 5),
    InboundGateElement(method: 'terminal/create', byteLength: 7),
  ])!;
  final blockerStarted = Completer<void>();
  final releaseBlocker = Completer<void>();
  final queuedValue = Completer<InboundGateTerminal<String>>.sync();
  final queuedError = Completer<InboundGateTerminal<String>>.sync();
  var valueHandlerCalls = 0;
  var errorHandlerCalls = 0;

  final blocker = reservations[0].run(() async {
    blockerStarted.complete();
    await releaseBlocker.future;
  });
  try {
    await blockerStarted.future.timeout(const Duration(seconds: 2));
    final value = reservations[1].runCancellable<String>(
      operation: () {
        valueHandlerCalls += 1;
        return 'handler';
      },
      terminal: queuedValue.future,
    );
    final error = reservations[2].runCancellable<String>(
      operation: () {
        errorHandlerCalls += 1;
        return 'handler';
      },
      terminal: queuedError.future,
    );
    final errorExpectation = expectLater(
      error,
      throwsA(isA<rpc.RpcException>().having((e) => e.code, 'code', -32003)),
    );

    queuedValue.complete(const InboundGateTerminalValue<String>('cancelled'));
    queuedError.complete(
      InboundGateTerminalError<String>(
        rpc.RpcException(-32003, 'Permission request cancelled.'),
      ),
    );

    expect(await value.timeout(const Duration(seconds: 2)), 'cancelled');
    await errorExpectation;
    await Future.wait<void>(<Future<void>>[
      reservations[1].released,
      reservations[2].released,
    ]).timeout(const Duration(seconds: 2));
    expect(valueHandlerCalls, 0);
    expect(errorHandlerCalls, 0);
    expect(gate.pendingItems, 1);
    expect(gate.pendingBytes, 3);
    expect(gate.activeHandlers, 1);
  } finally {
    if (!releaseBlocker.isCompleted) releaseBlocker.complete();
    await blocker;
    await gate.close();
  }
});
```

- [ ] 5. 运行 `./tool/flutter_test_isolated.sh test/acp/inbound_gate_test.dart --plain-name "queued terminal short circuits before handler invocation"`。Expected: FAIL at compile time because `InboundGateTerminal`, `runCancellable` and `released` do not exist。

- [ ] 6. 写 helper 与 named RED `running reservation detaches and consumes late outcomes on close`，分别给实际 operation 注入迟到 value/error，并用 zone 收集未处理错误：

```dart
test('running reservation detaches and consumes late outcomes on close', () async {
  for (final lateError in <bool>[false, true]) {
    final zoneErrors = <Object>[];
    await runZonedGuarded(() async {
      final gate = InboundGate();
      final reservation = gate.tryReserveBatch(const <InboundGateElement>[
        InboundGateElement(method: 'fs/read_text_file', byteLength: 11),
      ])!.single;
      final started = Completer<void>();
      final operation = Completer<String>();
      final neverTerminal = Completer<InboundGateTerminal<String>>();
      final waiter = reservation.runCancellable<String>(
        operation: () {
          started.complete();
          return operation.future;
        },
        terminal: neverTerminal.future,
      );
      final waiterFailure = expectLater(waiter, throwsStateError);
      try {
        await started.future.timeout(const Duration(seconds: 2));
        await gate.close().timeout(const Duration(seconds: 2));
        await reservation.released.timeout(const Duration(seconds: 2));
        await waiterFailure;
        expect(gate.pendingItems, 0);
        expect(gate.pendingBytes, 0);
        expect(gate.activeHandlers, 0);
        if (lateError) {
          operation.completeError(StateError('late operation'));
        } else {
          operation.complete('late value');
        }
        await pumpEventQueue();
        expect(gate.pendingItems, 0);
        expect(gate.activeHandlers, 0);
      } finally {
        if (!operation.isCompleted) operation.complete('cleanup');
        if (!neverTerminal.isCompleted) {
          neverTerminal.complete(
            const InboundGateTerminalValue<String>('cleanup'),
          );
        }
        await gate.close();
      }
    }, (Object error, StackTrace stackTrace) {
      zoneErrors.add(error);
    });
    expect(zoneErrors, isEmpty);
  }
});
```

- [ ] 7. 运行 `./tool/flutter_test_isolated.sh test/acp/inbound_gate_test.dart --plain-name "running reservation detaches and consumes late outcomes on close"`。Expected: FAIL because old `close()` leaves running reservation/items active until the operation returns and exposes no `released` future。

- [ ] 8. 增加 peer/manager 共用但不从 `dart_acp.dart` 导出的 terminal 契约；构造器与字段保持完整：

```dart
sealed class InboundGateTerminal<T> {
  const InboundGateTerminal();
}

final class InboundGateTerminalValue<T> extends InboundGateTerminal<T> {
  const InboundGateTerminalValue(this.value);
  final T value;
}

final class InboundGateTerminalError<T> extends InboundGateTerminal<T> {
  const InboundGateTerminalError(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;
}

class InboundGateReservation {
  final Completer<void> _released = Completer<void>.sync();
  Future<void> get released => _released.future;

  Future<T> runCancellable<T>({
    required FutureOr<T> Function() operation,
    required Future<InboundGateTerminal<T>> terminal,
  }) => _gate._runCancellable(this, operation: operation, terminal: terminal);
}
```

- [ ] 9. 把 reservation 状态改为 `reserved/queued/running/released/detached`，并实现只归还一次预算的完整 release/detach body：

```dart
void _release(InboundGateReservation reservation) {
  if (!_reservations.remove(reservation)) return;
  reservation._state = _ReservationState.released;
  _pendingItems -= 1;
  _pendingBytes -= reservation.byteLength;
  if (!reservation._released.isCompleted) reservation._released.complete();
}

void _detach(_HandlerWaiter<dynamic> waiter) {
  final reservation = waiter.reservation;
  if (reservation._state != _ReservationState.running) return;
  _running.remove(waiter);
  reservation._state = _ReservationState.detached;
  _reservations.remove(reservation);
  _activeHandlers -= 1;
  if (!waiter.isReservedControl) _activeOrdinaryHandlers -= 1;
  _pendingItems -= 1;
  _pendingBytes -= reservation.byteLength;
  if (!reservation._released.isCompleted) reservation._released.complete();
  if (!waiter.completer.isCompleted) {
    waiter.completer.completeError(StateError('Inbound gate is closed.'));
  }
}

enum _ReservationState { reserved, queued, running, released, detached }
```

- [ ] 10. 给 waiter 登记 terminal value/error consumer，并实现 queued first-wins；terminal 回调必须先从队列移除、再 `_release`、最后完成 waiter：

```dart
Future<T> _runCancellable<T>(
  InboundGateReservation reservation, {
  required FutureOr<T> Function() operation,
  required Future<InboundGateTerminal<T>> terminal,
}) {
  if (!_reservations.contains(reservation) ||
      reservation._state != _ReservationState.reserved ||
      _closed) {
    return Future<T>.error(StateError('Inbound gate reservation is closed.'));
  }
  reservation._state = _ReservationState.queued;
  final waiter = _HandlerWaiter<T>(reservation, operation);
  _waiters.addLast(waiter);
  unawaited(terminal.then<void>((outcome) {
    if (reservation._state != _ReservationState.queued) return;
    _waiters.remove(waiter);
    _release(reservation);
    switch (outcome) {
      case InboundGateTerminalValue<T>(:final value):
        waiter.completer.complete(value);
      case InboundGateTerminalError<T>(:final error, :final stackTrace):
        waiter.completer.completeError(error, stackTrace ?? StackTrace.current);
    }
    _pump();
  }, onError: (Object error, StackTrace stackTrace) {
    if (reservation._state != _ReservationState.queued) return;
    _waiters.remove(waiter);
    _release(reservation);
    waiter.completer.completeError(error, stackTrace);
    _pump();
  }));
  _pump();
  return waiter.completer.future;
}
```

- [ ] 11. 给 gate 增加 `final Set<_HandlerWaiter<dynamic>> _running = <_HandlerWaiter<dynamic>>{};`，并用以下完整 body 替换 `_start/_finishValue/_finishError/_finish/close`。operation 的迟到 value/error 始终有 consumer；detached callback 不再减计数或完成 waiter：

```dart
void _start(_HandlerWaiter<dynamic> waiter) {
  final reservation = waiter.reservation;
  if (_closed || reservation._state != _ReservationState.queued) {
    _rejectWaiter(waiter);
    return;
  }
  reservation._state = _ReservationState.running;
  _running.add(waiter);
  _activeHandlers += 1;
  if (!waiter.isReservedControl) _activeOrdinaryHandlers += 1;

  final Future<dynamic> operation;
  try {
    operation = Future<dynamic>.sync(waiter.operation);
  } on Object catch (error, stackTrace) {
    _finishError(waiter, error, stackTrace);
    return;
  }
  unawaited(operation.then<void>(
    (value) => _finishValue(waiter, value),
    onError: (Object error, StackTrace stackTrace) {
      _finishError(waiter, error, stackTrace);
    },
  ));
}

void _finishValue(_HandlerWaiter<dynamic> waiter, Object? value) {
  if (waiter.reservation._state == _ReservationState.detached) return;
  if (waiter.reservation._state != _ReservationState.running) return;
  _finish(waiter);
  if (!waiter.completer.isCompleted) waiter.completer.complete(value);
}

void _finishError(
  _HandlerWaiter<dynamic> waiter,
  Object error,
  StackTrace stackTrace,
) {
  if (waiter.reservation._state == _ReservationState.detached) return;
  if (waiter.reservation._state != _ReservationState.running) return;
  _finish(waiter);
  if (!waiter.completer.isCompleted) {
    waiter.completer.completeError(error, stackTrace);
  }
}

void _finish(_HandlerWaiter<dynamic> waiter) {
  if (!_running.remove(waiter)) return;
  _activeHandlers -= 1;
  if (!waiter.isReservedControl) _activeOrdinaryHandlers -= 1;
  _release(waiter.reservation);
  _pump();
}

Future<void> close() {
  final existing = _closeFuture;
  if (existing != null) return existing;
  final owner = Completer<void>.sync();
  _closeFuture = owner.future;
  _closed = true;

  final queued = _waiters.toList(growable: false);
  _waiters.clear();
  for (final waiter in queued) {
    _rejectWaiter(waiter);
  }
  for (final waiter in _running.toList(growable: false)) {
    _detach(waiter);
  }
  for (final reservation in _reservations.toList(growable: false)) {
    if (reservation._state == _ReservationState.reserved) {
      _release(reservation);
    }
  }
  owner.complete();
  return owner.future;
}
```

- [ ] 12. 运行 `./tool/flutter_test_isolated.sh test/acp/inbound_gate_test.dart --plain-name "queued terminal short circuits before handler invocation"`。Expected: PASS。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/inbound_gate_test.dart --plain-name "running reservation detaches and consumes late outcomes on close"`。Expected: PASS。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/inbound_gate_test.dart`。Expected: PASS。

- [ ] 15. 运行 `dart format third_party/dart_acp/lib/src/rpc/inbound_gate.dart test/acp/inbound_gate_test.dart`。Expected: exit 0。

- [ ] 16. 运行 `git diff --check`。Expected: exit 0，无输出。

- [ ] 17. 运行 `git add pubspec.yaml pubspec.lock third_party/dart_acp/lib/src/rpc/inbound_gate.dart test/acp/inbound_gate_test.dart`。Expected: 只暂存根依赖声明/lock 与本任务两个 gate 文件。

- [ ] 18. 运行 `git commit -m "fix: cancel queued ACP inbound work"`。Expected: commit 成功；后续根测试可直接 import `json_rpc_2`，无需再次调整依赖。

### Task 3: 入站 correlation 与 response commit

**Files:**
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `test/acp/json_rpc_peer_inbound_gate_test.dart`

- [ ] 1. 在 `test/acp/json_rpc_peer_inbound_gate_test.dart` 写 named RED `internal correlation restores duplicate and null wire ids exactly`；沿用文件已有 `StreamChannelController`/`StreamIterator`，只有三个 handler 都开始后才读 batch response：

```dart
test('internal correlation restores duplicate and null wire ids exactly', () async {
  final channel = StreamChannelController<String>(sync: true);
  final outbound = StreamIterator<String>(channel.local.stream);
  final peer = JsonRpcPeer(channel.foreign);
  final allStarted = Completer<void>();
  var starts = 0;
  peer.onReadTextFile = (params) async {
    starts += 1;
    if (starts == 3) allStarted.complete();
    return <String, dynamic>{'marker': params['marker']};
  };
  try {
    channel.local.sink.add(jsonEncode(<Object?>[
      for (final entry in <(Object?, String)>[(7, 'a'), (7, 'b'), (null, 'c')])
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': entry.$1,
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{'marker': entry.$2},
        },
    ]));
    await allStarted.future.timeout(const Duration(seconds: 2));
    expect(await outbound.moveNext(), isTrue);
    final wire = outbound.current;
    final response = jsonDecode(wire) as List<dynamic>;
    expect(response.map((e) => (e as Map)['id']).toList(), <Object?>[7, 7, null]);
    expect(
      response.map((e) => ((e as Map)['result'] as Map)['marker']).toList(),
      <String>['a', 'b', 'c'],
    );
    expect(wire, isNot(contains('_acp_internal_')));
    expect(peer.correlationPendingItemsForTesting, 0);
    expect(peer.correlationPendingBytesForTesting, 0);
  } finally {
    await peer.close();
    await outbound.cancel();
    await channel.local.sink.close();
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "internal correlation restores duplicate and null wire ids exactly"`。Expected: FAIL at compile time because correlation counters do not exist; old peer also passes duplicate/null wire IDs directly to `json_rpc_2` and cannot distinguish their response commits。

- [ ] 3. 写 named RED `response commit retains correlation capacity behind a blocked batch sibling`；快速 handler 完成后仍须保留两个 tracker，`finally` 完成 sibling：

```dart
test('response commit retains correlation capacity behind a blocked batch sibling', () async {
  final channel = StreamChannelController<String>(sync: true);
  final peer = JsonRpcPeer(channel.foreign, maxPendingItems: 2);
  final quickFinished = Completer<void>();
  final blockedStarted = Completer<void>();
  final releaseBlocked = Completer<void>();
  peer.onReadTextFile = (params) async {
    quickFinished.complete();
    return <String, dynamic>{'content': 'ok'};
  };
  peer.onWriteTextFile = (params) async {
    blockedStarted.complete();
    await releaseBlocked.future;
    return null;
  };
  try {
    channel.local.sink.add(jsonEncode(<Object?>[
      <String, dynamic>{
        'jsonrpc': '2.0', 'id': 1, 'method': 'fs/read_text_file',
        'params': <String, dynamic>{},
      },
      <String, dynamic>{
        'jsonrpc': '2.0', 'id': 2, 'method': 'fs/write_text_file',
        'params': <String, dynamic>{},
      },
    ]));
    await Future.wait<void>(<Future<void>>[
      quickFinished.future,
      blockedStarted.future,
    ]).timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(peer.inboundPendingItemsForTesting, 1);
    expect(peer.correlationPendingItemsForTesting, 2);
    await peer.close().timeout(const Duration(seconds: 2));
    expect(peer.correlationPendingItemsForTesting, 0);
    expect(peer.correlationPendingBytesForTesting, 0);
  } finally {
    if (!releaseBlocked.isCompleted) releaseBlocked.complete();
    await peer.close();
    await channel.local.sink.close();
  }
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "response commit retains correlation capacity behind a blocked batch sibling"`。Expected: FAIL because old peer has no independent tracker and releases the quick reservation before the batch response reaches the sink。

- [ ] 5. 写 named RED `correlation batch reservation rolls back gate atomically`；先制造 gate 有空间但 correlation 满的 batch，再以当前 internal id 作为恶意 wire id，确认 direct capacity response 不完成旧 tracker：

```dart
test('correlation batch reservation rolls back gate atomically', () async {
  for (final byteLimited in <bool>[false, true]) {
    final quickRequest = <String, dynamic>{
      'jsonrpc': '2.0', 'id': 1, 'method': 'fs/read_text_file',
      'params': <String, dynamic>{},
    };
    final blockedRequest = <String, dynamic>{
      'jsonrpc': '2.0', 'id': 2, 'method': 'fs/read_text_file',
      'params': <String, dynamic>{'blocked': true},
    };
    final firstBatchBytes = utf8.encode(jsonEncode(quickRequest)).length +
        utf8.encode(jsonEncode(blockedRequest)).length;
    final channel = StreamChannelController<String>(sync: true);
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(
      channel.foreign,
      maxPendingItems: byteLimited ? 128 : 2,
      maxPendingBytes: byteLimited ? firstBatchBytes : 32 * 1024 * 1024,
    );
    final quickFinished = Completer<void>();
    final blockedStarted = Completer<void>();
    final releaseBlocked = Completer<void>();
    peer.onReadTextFile = (params) async {
      if (params['blocked'] == true) {
        blockedStarted.complete();
        await releaseBlocked.future;
      } else {
        quickFinished.complete();
      }
      return <String, dynamic>{'content': 'ok'};
    };
    try {
      channel.local.sink.add(
        jsonEncode(<Object?>[quickRequest, blockedRequest]),
      );
      await Future.wait<void>(<Future<void>>[
        quickFinished.future,
        blockedStarted.future,
      ]).timeout(const Duration(seconds: 2));
      await pumpEventQueue();
      final maliciousId = peer.correlationIdsForTesting.first;
      final gateItemsBefore = peer.inboundPendingItemsForTesting;
      final trackerItemsBefore = peer.correlationPendingItemsForTesting;

      channel.local.sink.add(jsonEncode(<String, dynamic>{
        ...quickRequest,
        'id': byteLimited ? 3 : maliciousId,
      }));
      expect(await outbound.moveNext(), isTrue);
      final rejection = jsonDecode(outbound.current) as Map<String, dynamic>;
      expect(rejection['id'], byteLimited ? 3 : maliciousId);
      expect((rejection['error'] as Map)['code'], -32000);
      expect(peer.inboundPendingItemsForTesting, gateItemsBefore);
      expect(peer.correlationPendingItemsForTesting, trackerItemsBefore);
    } finally {
      if (!releaseBlocked.isCompleted) releaseBlocked.complete();
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "correlation batch reservation rolls back gate atomically"`。Expected: FAIL at compile time because the independent item/byte budget, correlation ids and gate counters are absent。

- [ ] 7. 在 `peer.dart` 定义只服务 correlation 的 tracker；本提交不得引入 unavailable、prompt owner 或 admission 类型：

```dart
final class _InboundCorrelation {
  _InboundCorrelation({
    required this.internalId,
    required this.wireId,
    required this.arrivalIdentity,
    required this.canonicalByteLength,
    required this.reservation,
  });
  final String internalId;
  final Object? wireId;
  final Object arrivalIdentity;
  final int canonicalByteLength;
  final InboundGateReservation reservation;
  final Completer<void> responseCommitted = Completer<void>.sync();
  bool finished = false;
}
```

- [ ] 8. 加入原子预留/回滚方法和测试只读 getters；byte 预算使用接纳时 canonical byteLength，notification 不预留：

```dart
final Map<String, _InboundCorrelation> _correlations =
    <String, _InboundCorrelation>{};
var _nextCorrelationId = 0;
var _correlationPendingBytes = 0;

@visibleForTesting
int get correlationPendingItemsForTesting => _correlations.length;
@visibleForTesting
int get correlationPendingBytesForTesting => _correlationPendingBytes;
@visibleForTesting
int get inboundPendingItemsForTesting => _gate.pendingItems;
@visibleForTesting
Set<String> get correlationIdsForTesting =>
    Set<String>.unmodifiable(_correlations.keys);

List<_InboundCorrelation>? _reserveCorrelations(
  List<Object?> requests,
  List<InboundGateReservation> reservations,
) {
  final candidates = <_InboundCorrelation>[];
  var addedBytes = 0;
  for (var i = 0; i < requests.length; i += 1) {
    final request = requests[i];
    if (!_hasLegalRequestId(request)) continue;
    final byteLength = utf8.encode(jsonEncode(request)).length;
    addedBytes += byteLength;
    candidates.add(_InboundCorrelation(
      internalId: '_acp_internal_${++_nextCorrelationId}',
      wireId: (request as Map)['id'],
      arrivalIdentity: Object(),
      canonicalByteLength: byteLength,
      reservation: reservations[i],
    ));
  }
  if (_correlations.length + candidates.length > _gate.maxPendingItems ||
      _correlationPendingBytes + addedBytes > _gate.maxPendingBytes) {
    return null;
  }
  for (final entry in candidates) {
    _correlations[entry.internalId] = entry;
  }
  _correlationPendingBytes += addedBytes;
  return candidates;
}
```

- [ ] 9. `_handleInboundLine` 先 gate reserve，再 correlation reserve；后者失败时逐 reservation `release()` 并走 direct wire response。成功时用以下 body 浅复制 request 并替换合法 id；notification 保持原对象且不进 tracker：

```dart
List<Object?> _rewriteInboundCorrelationIds(
  List<Object?> requests,
  List<InboundGateReservation> reservations,
  List<_InboundCorrelation> correlations,
) {
  final byReservation =
      HashMap<InboundGateReservation, _InboundCorrelation>.identity();
  for (final correlation in correlations) {
    byReservation[correlation.reservation] = correlation;
  }
  return List<Object?>.generate(requests.length, (index) {
    final request = requests[index];
    final correlation = byReservation[reservations[index]];
    if (correlation == null) return request;
    return <Object?, Object?>{
      ...(request as Map),
      'id': correlation.internalId,
    };
  }, growable: false);
}

void _admitAndDispatchRequests(
  List<Object?> requests, {
  required bool wasBatch,
}) {
  final gateElements = requests.map((request) => InboundGateElement(
        method: _methodOf(request),
        byteLength: utf8.encode(jsonEncode(request)).length,
      )).toList(growable: false);
  final reservations = _gate.tryReserveBatch(gateElements);
  if (reservations == null) {
    _rejectForCapacity(requests, wasBatch: wasBatch);
    return;
  }
  final correlations = _reserveCorrelations(requests, reservations);
  if (correlations == null) {
    for (final reservation in reservations) {
      reservation.release();
    }
    _rejectForCapacity(requests, wasBatch: wasBatch);
    return;
  }
  final rewritten = _rewriteInboundCorrelationIds(
    requests,
    reservations,
    correlations,
  );
  try {
    _dispatchDecoded(_DecodedDelivery(
      wasBatch ? rewritten : rewritten.single,
      reservations: reservations,
    ));
  } on Object {
    for (final correlation in correlations) {
      _finishCorrelation(correlation.internalId);
    }
    rethrow;
  }
}
```

`_handleInboundLine` 完成 response/request 分流后只调用 `_admitAndDispatchRequests(requests, wasBatch: decoded is List)`；parse/capacity 必须调用 `_writeWireResponse`，不能走 internal-id 恢复。

- [ ] 10. 给 `_JsonEncodingSink` 注入 response adapter；`add` 先恢复单个/批量 internal id，底层 `_sink.add(jsonEncode(restored))` 同步成功后才逐项 `_finishCorrelation`。实现 body 固定为：

```dart
void _finishCorrelation(String internalId) {
  final entry = _correlations.remove(internalId);
  if (entry == null || entry.finished) return;
  entry.finished = true;
  _correlationPendingBytes -= entry.canonicalByteLength;
  if (!entry.responseCommitted.isCompleted) {
    entry.responseCommitted.complete();
  }
}

void _finishAllCorrelationsForPeerClose() {
  for (final id in _correlations.keys.toList(growable: false)) {
    _finishCorrelation(id);
  }
}

void _writeWireResponse(Object? response) {
  _decodedSink.addWireResponse(response);
}
```

`addWireResponse` 直接编码原 wire id，严禁查 `_correlations`；parse/capacity 调用点全部改用它。编码或 sink 同步 `add` 抛错时，对本次命中的 tracker 调相同 `_finishCorrelation` 后 rethrow；peer close 调 `_finishAllCorrelationsForPeerClose()`。

同一步把 sink adapter 写成可编译 body，并在 `JsonRpcPeer` 构造体中以 `_prepareCorrelationResponse`、`_finishCommittedCorrelations`、`_finishRejectedCorrelations` 三个 tear-off 构造 `_decodedSink`：

```dart
typedef _PreparedCorrelationResponse = ({
  Object? wireValue,
  List<String> internalIds,
});

_PreparedCorrelationResponse _prepareCorrelationResponse(Object? event) {
  final ids = <String>[];
  Object? restore(Object? element) {
    if (element is! Map || !element.containsKey('id')) return element;
    final internalId = element['id'];
    if (internalId is! String) return element;
    final correlation = _correlations[internalId];
    if (correlation == null) return element;
    ids.add(internalId);
    return <Object?, Object?>{...element, 'id': correlation.wireId};
  }
  final wireValue = event is List
      ? event.map<Object?>(restore).toList(growable: false)
      : restore(event);
  return (wireValue: wireValue, internalIds: ids);
}

void _finishCommittedCorrelations(List<String> ids) {
  for (final id in ids) {
    _finishCorrelation(id);
  }
}

void _finishRejectedCorrelations(List<String> ids) {
  for (final id in ids) {
    _finishCorrelation(id);
  }
}

final class _JsonEncodingSink implements StreamSink<Object?> {
  _JsonEncodingSink(
    this._sink, {
    required this.prepare,
    required this.onCommitted,
    required this.onWriteRejected,
  });
  final StreamSink<String> _sink;
  final _PreparedCorrelationResponse Function(Object? event) prepare;
  final void Function(List<String> ids) onCommitted;
  final void Function(List<String> ids) onWriteRejected;
  Future<void>? _closeFuture;
  bool _writesEnabled = true;

  void disableWrites() => _writesEnabled = false;

  @override
  void add(Object? event) {
    if (!_writesEnabled) return;
    final prepared = prepare(event);
    try {
      _sink.add(jsonEncode(prepared.wireValue));
    } on Object {
      onWriteRejected(prepared.internalIds);
      rethrow;
    }
    onCommitted(prepared.internalIds);
  }

  void addWireResponse(Object? event) {
    if (!_writesEnabled) return;
    _sink.add(jsonEncode(event));
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    if (_writesEnabled) _sink.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final event in stream) {
      add(event);
    }
  }

  @override Future<void> get done => _sink.done;
  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _writesEnabled = false;
    return _closeFuture = Future<void>.sync(_sink.close);
  }
}
```

- [ ] 11. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "internal correlation restores duplicate and null wire ids exactly"`。Expected: PASS。

- [ ] 12. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "response commit retains correlation capacity behind a blocked batch sibling"`。Expected: PASS。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "correlation batch reservation rolls back gate atomically"`。Expected: PASS for both item-limit and byte-limit iterations。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: PASS。

- [ ] 15. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: exit 0。

- [ ] 16. 运行 `git diff --check`。Expected: exit 0，无输出。

- [ ] 17. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。

- [ ] 18. 运行 `git commit -m "fix: track ACP inbound response commits"`。Expected: commit 成功。

### Task 4: 带原因的 peer unavailable 状态

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `test/acp/json_rpc_peer_inbound_gate_test.dart`
- Modify: `test/acp/acp_client_inbound_gate_lifecycle_test.dart`

- [ ] 1. 在 `test/acp/json_rpc_peer_inbound_gate_test.dart` 写 named RED `peer unavailable listener reentry preserves first reason and one close future`；每个首因使用新的 sync channel，listener 内同步重入 dispose，随后再触发其余原因与 late replay：

```dart
test('peer unavailable listener reentry preserves first reason and one close future', () async {
  for (final first in AcpPeerUnavailableReason.values) {
    final channel = StreamChannelController<String>(sync: true);
    final peer = JsonRpcPeer(channel.foreign);
    final observed = <AcpPeerUnavailableState>[];
    Future<void>? reentrantClose;
    var reentrantCalls = 0;
    void throwing(AcpPeerUnavailableState state) => throw StateError('listener');
    void reenter(AcpPeerUnavailableState state) {
      reentrantCalls += 1;
      reentrantClose = peer.dispose();
    }
    void recording(AcpPeerUnavailableState state) => observed.add(state);
    peer.addUnavailableListener(throwing);
    peer.addUnavailableListener(reenter);
    peer.addUnavailableListener(recording);
    try {
      expect(peer.isAvailable, isTrue);
      final firstClose = peer.closeForTesting(first);
      expect(reentrantClose, isNotNull);
      expect(identical(firstClose, reentrantClose), isTrue);
      for (final later in AcpPeerUnavailableReason.values.where((r) => r != first)) {
        expect(identical(firstClose, peer.closeForTesting(later)), isTrue);
      }
      await firstClose.timeout(const Duration(seconds: 2));
      expect(peer.isAvailable, isFalse);
      expect(reentrantCalls, 1);
      expect(observed, hasLength(1));
      expect(observed.single.reason, first);
      AcpPeerUnavailableState? replayed;
      peer.addUnavailableListener((state) => replayed = state);
      expect(replayed, same(observed.single));
    } finally {
      peer.removeUnavailableListener(throwing);
      peer.removeUnavailableListener(reenter);
      peer.removeUnavailableListener(recording);
      await peer.close();
      await channel.local.sink.close();
    }
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "peer unavailable listener reentry preserves first reason and one close future"`。Expected: FAIL at compile time because reason/state/listener/isAvailable APIs do not exist；若只在 listener 返回后安装 `_closeFuture`，重入 dispose 会创建第二个 close owner 或覆盖首因。

- [ ] 3. 写 named RED `unavailable peer drops waiter responses before writing the wire`；沿用本文件 `_ManualInputStream` 与 `_RecordingSink`，同步等 handler start 后 close，`finally` 才放迟到结果：

```dart
test('unavailable peer drops waiter responses before writing the wire', () async {
  const canary = 'WAITER-STACK-DATA-CANARY';
  final input = _ManualInputStream();
  final output = _RecordingSink();
  final peer = JsonRpcPeer(StreamChannel<String>(input, output));
  final started = Completer<void>();
  final release = Completer<void>();
  peer.onReadTextFile = (params) async {
    started.complete();
    await release.future;
    throw StateError(canary);
  };
  try {
    input.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': 9,
      'method': 'fs/read_text_file',
      'params': <String, dynamic>{},
    }));
    await started.future.timeout(const Duration(seconds: 2));
    await peer
        .closeForTesting(AcpPeerUnavailableReason.explicitClose)
        .timeout(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(output.events, isEmpty);
    expect(output.events.join(), isNot(contains(canary)));
    expect(output.closeCount, 1);
  } finally {
    if (!release.isCompleted) release.complete();
    await pumpEventQueue();
    input.close();
    await peer.close();
  }
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "unavailable peer drops waiter responses before writing the wire"`。Expected: FAIL because old close does not synchronously make the encoding sink unwritable or detach the running waiter。

- [ ] 5. 在 `test/acp/acp_client_inbound_gate_lifecycle_test.dart` 写 public-proxy RED `AcpClient replays disposed unavailability through its public proxy`，复用该文件 `_LifecycleTransport`：

```dart
test('AcpClient replays disposed unavailability through its public proxy', () async {
  final transport = _LifecycleTransport();
  final client = await AcpClient.start(
    config: AcpConfig(),
    transport: transport,
  );
  final observed = <AcpPeerUnavailableState>[];
  void listener(AcpPeerUnavailableState state) => observed.add(state);
  client.addPeerUnavailableListener(listener);
  try {
    expect(client.isAvailable, isTrue);
    await client.dispose();
    expect(client.isAvailable, isFalse);
    expect(observed.single.reason, AcpPeerUnavailableReason.disposed);
    AcpPeerUnavailableState? replay;
    client.addPeerUnavailableListener((state) => replay = state);
    expect(replay, same(observed.single));
  } finally {
    client.removePeerUnavailableListener(listener);
    await client.dispose();
    await transport.closeInput();
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_client_inbound_gate_lifecycle_test.dart --plain-name "AcpClient replays disposed unavailability through its public proxy"`。Expected: FAIL at compile time because the public proxy and disposed close cause do not exist。

- [ ] 7. 在 `peer.dart` 增加并由 `dart_acp.dart` 精确导出 unavailable 协议：

```dart
enum AcpPeerUnavailableReason {
  fatalTimeout,
  transportClosed,
  explicitClose,
  disposed,
}

final class AcpPromptCleanupIdentity {
  const AcpPromptCleanupIdentity(this.ownerToken, this.generation);
  final Object ownerToken;
  final int generation;
}

final class AcpPeerUnavailableState {
  const AcpPeerUnavailableState(this.reason, {this.cleanupIdentity});
  final AcpPeerUnavailableReason reason;
  final AcpPromptCleanupIdentity? cleanupIdentity;
}

typedef AcpPeerUnavailableListener = void Function(
  AcpPeerUnavailableState state,
);
```

- [ ] 8. peer 提供状态型 listener registry；late add 同步回放，listener error 隔离：

```dart
AcpPeerUnavailableState? _unavailableState;
final Set<AcpPeerUnavailableListener> _unavailableListeners =
    <AcpPeerUnavailableListener>{};

bool get isAvailable => _unavailableState == null;
void addUnavailableListener(AcpPeerUnavailableListener listener) {
  _unavailableListeners.add(listener);
  final state = _unavailableState;
  if (state != null) {
    try { listener(state); } on Object {}
  }
}
void removeUnavailableListener(AcpPeerUnavailableListener listener) {
  _unavailableListeners.remove(listener);
}
```

- [ ] 9. 把所有 close 原因汇入唯一 first-wins body；测试入口只转发该 body：

```dart
Future<void> close() => _becomeUnavailable(AcpPeerUnavailableReason.explicitClose);
Future<void> dispose() => _becomeUnavailable(AcpPeerUnavailableReason.disposed);
Future<void> closeForFatalTimeout({AcpPromptCleanupIdentity? cleanupIdentity}) =>
    _becomeUnavailable(
      AcpPeerUnavailableReason.fatalTimeout,
      cleanupIdentity: cleanupIdentity,
    );
@visibleForTesting
Future<void> closeForTesting(AcpPeerUnavailableReason reason) =>
    _becomeUnavailable(reason);

Future<void> _becomeUnavailable(
  AcpPeerUnavailableReason reason, {
  AcpPromptCleanupIdentity? cleanupIdentity,
}) {
  final existing = _closeFuture;
  if (existing != null) return existing;
  final closeOwner = Completer<void>.sync();
  final closeFuture = closeOwner.future;
  _closeFuture = closeFuture;
  final state = AcpPeerUnavailableState(
    reason,
    cleanupIdentity: cleanupIdentity,
  );
  _unavailableState = state;
  _decodedSink.disableWrites();
  for (final listener in _unavailableListeners.toList(growable: false)) {
    try { listener(state); } on Object {}
  }
  unawaited(_closeUnavailableResources(closeOwner));
  return closeFuture;
}

Future<void> _closeUnavailableResources(Completer<void> closeOwner) async {
  try {
    _acceptingInbound = false;
    await _gate.close();
    _finishAllCorrelationsForPeerClose();
    await _closeUnderlyingPeerAfterGate();
    if (!closeOwner.isCompleted) closeOwner.complete();
  } on Object catch (error, stackTrace) {
    if (!closeOwner.isCompleted) {
      closeOwner.completeError(error, stackTrace);
    }
  }
}
```

`_handleInboundDone/_handleInboundError` 在排入 terminal 前调用 transportClosed 入口。`_becomeUnavailable` 必须依次同步安装 `_closeFuture`、写 `_unavailableState`、disable sink、通知 listeners；listener 重入任一 close/dispose 因而返回同一 Future。`_closeUnderlyingPeerAfterGate` 不再关闭 gate，只执行底层 peer、decoded input、sink、subscription、sessionUpdates 的现有幂等清理。

- [ ] 10. 在 `_JsonEncodingSink` 增加同步 `disableWrites()`，使 `add/addError/addStream` 在 disabled 后直接丢弃；资源清理固定顺序是同步 future/state + disable/notify → await gate close/detach → correlation peer-close 替代终态 → underlying peer。

- [ ] 11. 在 `AcpClient` 增加 `isAvailable`、add/remove proxy；`_dispose` 调 `_peer.dispose()`，普通显式 close 仍映射 explicitClose：

```dart
bool get isAvailable => _peer.isAvailable;
void addPeerUnavailableListener(AcpPeerUnavailableListener listener) =>
    _peer.addUnavailableListener(listener);
void removePeerUnavailableListener(AcpPeerUnavailableListener listener) =>
    _peer.removeUnavailableListener(listener);
```

- [ ] 12. 在 `dart_acp.dart` 加入 `export 'src/rpc/peer.dart' show AcpPeerUnavailableReason, AcpPromptCleanupIdentity, AcpPeerUnavailableState, AcpPeerUnavailableListener;`。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "peer unavailable listener reentry preserves first reason and one close future"`。Expected: PASS。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "unavailable peer drops waiter responses before writing the wire"`。Expected: PASS。

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_client_inbound_gate_lifecycle_test.dart --plain-name "AcpClient replays disposed unavailability through its public proxy"`。Expected: PASS。

- [ ] 16. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/acp_client_inbound_gate_lifecycle_test.dart`。Expected: PASS。

- [ ] 17. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/acp_client_inbound_gate_lifecycle_test.dart`。Expected: exit 0。

- [ ] 18. 运行 `git diff --check`。Expected: exit 0，无输出。

- [ ] 19. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/acp_client_inbound_gate_lifecycle_test.dart`。

- [ ] 20. 运行 `git commit -m "fix: publish ACP peer unavailability"`。Expected: commit 成功。

### Task 5: 普通出站 deadline、fatal pending 冲刷与 prompt API 地基

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Verify: `test/acp/json_rpc_peer_inbound_gate_test.dart`

- [ ] 1. 在 `test/acp/acp_request_timeout_test.dart` 加入 `import 'package:dart_acp/src/rpc/peer.dart';`，并增加 `_RequestHarness`、`_CountingStringSink` 和 `_TestPromptOwner`；`takeRequest` 是“请求已发出”的同步点，dispose 必须关闭 peer/iterator/controllers：

```dart
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
  final StreamController<String> outputController =
      StreamController<String>(sync: true);
  late final _CountingStringSink sink;
  late final JsonRpcPeer peer;
  late final StreamIterator<String> outbound;

  Future<Map<String, dynamic>> takeRequest() async {
    expect(await outbound.moveNext().timeout(const Duration(seconds: 2)), isTrue);
    return jsonDecode(outbound.current) as Map<String, dynamic>;
  }
  void respond(Object? id, Object? result) => input.add(jsonEncode(
        <String, dynamic>{'jsonrpc': '2.0', 'id': id, 'result': result},
      ));
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
  var closeCount = 0;
  @override Future<void> get done => delegate.done;
  @override void add(String event) => delegate.add(event);
  @override void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);
  @override Future<void> addStream(Stream<String> stream) =>
      delegate.addStream(stream);
  @override Future<void> close() {
    closeCount += 1;
    return delegate.close();
  }
}

final class _TestPromptOwner implements JsonRpcPromptOwner {
  const _TestPromptOwner(this.sessionId, this.generation);
  @override final String sessionId;
  @override final int generation;
}
```

- [ ] 2. 写 named RED `request deadlines close and flush pending operations once`；两轮分别让 initialize/request 使用 60 ms，另一类 sibling 使用 1 s：

```dart
test('request deadlines close and flush pending operations once', () async {
  for (final initializeFirst in <bool>[true, false]) {
    final harness = _RequestHarness(acp.AcpTimeouts(
      initialize: Duration(milliseconds: initializeFirst ? 60 : 1000),
      request: Duration(milliseconds: initializeFirst ? 1000 : 60),
    ));
    final states = <AcpPeerUnavailableState>[];
    void listener(AcpPeerUnavailableState state) => states.add(state);
    harness.peer.addUnavailableListener(listener);
    try {
      final Future<Object?> first = initializeFirst
          ? harness.peer.initialize(<String, dynamic>{})
          : harness.peer.sendRaw('agent/first', <String, dynamic>{});
      final firstFailure = expectLater(
        first.timeout(const Duration(seconds: 2)),
        throwsA(isA<acp.AcpRequestTimeoutException>().having(
          (e) => e.toString(), 'text', 'ACP request timed out.')),
      );
      await harness.takeRequest();
      final Future<Object?> sibling = initializeFirst
          ? harness.peer.sendRaw('agent/sibling', <String, dynamic>{})
          : harness.peer.initialize(<String, dynamic>{});
      final siblingFailure = expectLater(
        sibling.timeout(const Duration(seconds: 2)),
        throwsA(isA<acp.AcpConnectionClosedException>().having(
          (e) => e.toString(), 'text', 'ACP connection closed.')),
      );
      await harness.takeRequest();
      await firstFailure;
      await siblingFailure;
      expect(states.map((s) => s.reason),
          <AcpPeerUnavailableReason>[AcpPeerUnavailableReason.fatalTimeout]);
      expect(harness.sink.closeCount, 1);
      await expectLater(
        harness.peer.sendRaw('CANARY-METHOD', <String, dynamic>{'p': 'CANARY'}),
        throwsA(isA<acp.AcpConnectionClosedException>().having(
          (e) => e.toString(), 'text', 'ACP connection closed.')),
      );
    } finally {
      harness.peer.removeUnavailableListener(listener);
      await harness.dispose();
    }
  }
});
```

- [ ] 3. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "request deadlines close and flush pending operations once"`。Expected: FAIL at compile time because `JsonRpcPeer` has no `timeouts`; without it both requests exceed the 2-second watchdog。

- [ ] 4. 写 named RED `request deadline races consume late responses without zone errors`；response-before、timeout-before-late-duplicate、explicit/dispose-before-deadline 各使用新 harness：

```dart
test('request deadline races consume late responses without zone errors', () async {
  final zoneErrors = <Object>[];
  await runZonedGuarded(() async {
    final early = _RequestHarness(const acp.AcpTimeouts(
      request: Duration(milliseconds: 80),
    ));
    try {
      final result = early.peer.sendRaw('agent/early', <String, dynamic>{});
      final sent = await early.takeRequest();
      early.respond(sent['id'], <String, dynamic>{'ok': true});
      expect(await result, <String, dynamic>{'ok': true});
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(early.peer.isAvailable, isTrue);
      expect(early.sink.closeCount, 0);
    } finally { await early.dispose(); }

    final late = _RequestHarness(const acp.AcpTimeouts(
      request: Duration(milliseconds: 60),
    ));
    try {
      final result = late.peer.sendRaw('agent/late', <String, dynamic>{});
      final failure = expectLater(
        result, throwsA(isA<acp.AcpRequestTimeoutException>()));
      final sent = await late.takeRequest();
      await failure;
      late.respond(sent['id'], <String, dynamic>{'late': 1});
      late.respond(sent['id'], <String, dynamic>{'late': 2});
      await pumpEventQueue();
      expect(late.sink.closeCount, 1);
    } finally { await late.dispose(); }

    for (final reason in <AcpPeerUnavailableReason>[
      AcpPeerUnavailableReason.explicitClose,
      AcpPeerUnavailableReason.disposed,
    ]) {
      final closed = _RequestHarness(const acp.AcpTimeouts(
        request: Duration(milliseconds: 150),
      ));
      try {
        final result = closed.peer.sendRaw('agent/close-race', <String, dynamic>{});
        final failure = expectLater(
          result, throwsA(isA<acp.AcpConnectionClosedException>()));
        await closed.takeRequest();
        await closed.peer.closeForTesting(reason);
        await failure;
        await Future<void>.delayed(const Duration(milliseconds: 180));
        expect(closed.sink.closeCount, 1);
      } finally { await closed.dispose(); }
    }
  }, (Object error, StackTrace stackTrace) => zoneErrors.add(error));
  expect(zoneErrors, isEmpty);
});
```

- [ ] 5. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "request deadline races consume late responses without zone errors"`。Expected: FAIL because old peer has no deadline first-wins operation and close errors are not fixed-mapped。

- [ ] 6. 写 named RED `prompt request derives session only from its owner`：

```dart
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
```

- [ ] 7. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt request derives session only from its owner"`。Expected: FAIL at compile time because `JsonRpcPromptOwner` and owner-bound API do not exist。

- [ ] 8. 增加最小中立 owner 协议；terminal winner/lifecycle 留到 Task 9：

```dart
abstract interface class JsonRpcPromptOwner {
  String get sessionId;
  int get generation;
}
```

- [ ] 9. 保持直接构造兼容；`JsonRpcPeer` 使用公开只读字段 `final AcpTimeouts timeouts`，构造体第一行 `timeouts.validate()`，`AcpClient.start` 构造 peer 时传 `timeouts: config.timeouts`：

```dart
JsonRpcPeer(
  StreamChannel<String> channel, {
  this.timeouts = const AcpTimeouts(),
  int maxPendingItems = 128,
  int maxPendingBytes = 32 * 1024 * 1024,
  int maxConcurrentHandlers = 16,
  int maxOrdinaryConcurrentHandlers = 14,
}) : _gate = InboundGate(
       maxPendingItems: maxPendingItems,
       maxPendingBytes: maxPendingBytes,
       maxConcurrentHandlers: maxConcurrentHandlers,
       maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
     ) {
  timeouts.validate();
  _decodedSink = _JsonEncodingSink(
    channel.sink,
    prepare: _prepareCorrelationResponse,
    onCommitted: _finishCommittedCorrelations,
    onWriteRejected: _finishRejectedCorrelations,
  );
  _peer = rpc.Peer.withoutJson(
    StreamChannel<Object?>(_decodedIncoming.stream, _decodedSink),
  );
  _registerClientHandlers();
  unawaited(_listenToUnderlyingPeer());
  _inboundSubscription = channel.stream.listen(
    _handleInboundLine,
    onError: _handleInboundError,
    onDone: _handleInboundDone,
  );
}

final AcpTimeouts timeouts;

Future<void> _listenToUnderlyingPeer() async {
  try {
    await _peer.listen();
  } on Object {
    await _becomeUnavailable(AcpPeerUnavailableReason.transportClosed);
  }
}

Future<Object?> _sendRequest(
  String method,
  Map<String, dynamic> params, {
  JsonRpcPromptOwner? promptOwner,
});
```

`initialize` 选 `timeouts.initialize`，普通请求选 `timeouts.request`。notification 不建 operation。`session/prompt` 暂以 null deadline 进入同一 private entry；Task 9 把这个分支替换为 prompt cancel/reap，避免本提交以普通 fatal 语义错误处理 prompt。

- [ ] 10. 实现 ordinary request 的 first-wins body；unavailable state 设置后、底层 peer 关闭前，对仍 pending operation 调 `completeConnectionClosed()`：

```dart
final class _OutboundRequestOperation {
  final Completer<Object?> result = Completer<Object?>.sync();
  Timer? timer;
  bool get isCompleted => result.isCompleted;
  void completeValue(Object? value) {
    if (!result.isCompleted) result.complete(value);
  }
  void completeError(Object error, StackTrace stackTrace) {
    if (!result.isCompleted) result.completeError(error, stackTrace);
  }
  void completeConnectionClosed() {
    if (!result.isCompleted) {
      result.completeError(const AcpConnectionClosedException());
    }
  }
}

final class _OutboundRequestRegistry {
  final Set<_OutboundRequestOperation> _pending =
      <_OutboundRequestOperation>{};

  void add(_OutboundRequestOperation operation) => _pending.add(operation);
  void remove(_OutboundRequestOperation operation) =>
      _pending.remove(operation);

  void completeConnectionClosed() {
    for (final operation in _pending.toList(growable: false)) {
      operation.completeConnectionClosed();
    }
  }
}

final _OutboundRequestRegistry _outboundRequests =
    _OutboundRequestRegistry();

Future<Object?> _sendRequest(
  String method,
  Json params, {
  JsonRpcPromptOwner? promptOwner,
}) {
  if (!isAvailable) {
    return Future<Object?>.error(const AcpConnectionClosedException());
  }
  if (method == 'session/prompt' && promptOwner == null) {
    return Future<Object?>.error(
      StateError('session/prompt requires an owner.'),
    );
  }
  final operation = _OutboundRequestOperation();
  _outboundRequests.add(operation);
  final Duration? deadline = method == 'session/prompt'
      ? null
      : method == 'initialize'
          ? timeouts.initialize
          : timeouts.request;
  late final Future<Object?> raw;
  try {
    raw = _peer.sendRequest(method, params);
  } on Object catch (error, stackTrace) {
    _outboundRequests.remove(operation);
    operation.completeError(error, stackTrace);
    return operation.result.future;
  }
  unawaited(raw.then<void>(operation.completeValue,
      onError: operation.completeError));
  if (deadline != null) {
    operation.timer = Timer(deadline, () {
      if (operation.isCompleted) return;
      operation.completeError(
        const AcpRequestTimeoutException(),
        StackTrace.current,
      );
      unawaited(closeForFatalTimeout());
    });
  }
  return operation.result.future.whenComplete(() {
    operation.timer?.cancel();
    _outboundRequests.remove(operation);
  });
}
```

所有 raw Future 必须保留 value/error consumer；timeout 已完成的 operation 不被 fatal close 改写，其他 pending 与 fatal 后新请求固定为 connection-closed。并在 Task 4 的唯一 `_becomeUnavailable` body 中，把 pending 冲刷放在首因与同步禁写已经安装之后、listener 通知与任何资源 `await` 之前；这是所有 fatal/transport/explicit/dispose unavailable 路径共用的同步步骤，不得只放进 timeout callback：

```dart
final state = AcpPeerUnavailableState(
  reason,
  cleanupIdentity: cleanupIdentity,
);
_unavailableState = state;
_decodedSink.disableWrites();
_outboundRequests.completeConnectionClosed();
for (final listener in _unavailableListeners.toList(growable: false)) {
  try {
    listener(state);
  } on Object {
    // One listener cannot block the remaining unavailable observers.
  }
}
unawaited(_closeUnavailableResources(closeOwner));
```

`completeConnectionClosed()` 必须同步遍历快照；operation 自己的 first-wins guard 保证已经以 timeout/value/error 胜出的请求不被改写，`whenComplete` 随后再从 registry 移除。

- [ ] 11. 把 initialize/new/load/set-mode/sendRaw 的底层调用改为 `_sendRequest`；initialize/new/sendRaw 逐字复用下面完整 object-result guard，load/set-mode 允许合法 null；notification 保持 `_peer.sendNotification`：

```dart
Map<String, dynamic> requireJsonRpcObjectResult(Object? raw) {
  if (raw is! Map) {
    throw const FormatException(
      'JSON-RPC result must be a JSON object.',
    );
  }
  return Map<String, dynamic>.from(raw);
}

Future<Map<String, dynamic>> initialize(Map<String, dynamic> params) async {
  final raw = await _sendRequest('initialize', params);
  return requireJsonRpcObjectResult(raw);
}

Future<Map<String, dynamic>> newSession(
  Map<String, dynamic> params,
) async {
  final raw = await _sendRequest('session/new', params);
  return requireJsonRpcObjectResult(raw);
}

Future<Map<String, dynamic>> sendRaw(
  String method,
  Map<String, dynamic> params,
) async {
  final raw = await _sendRequest(method, params);
  return requireJsonRpcObjectResult(raw);
}
```

- [ ] 12. 增加只从 owner 读取 sessionId 的包内 API：

```dart
Future<Map<String, dynamic>> sendPromptRequest({
  required JsonRpcPromptOwner owner,
  required List<Map<String, dynamic>> content,
}) async {
  final raw = await _sendRequest(
    'session/prompt',
    <String, dynamic>{'sessionId': owner.sessionId, 'prompt': content},
    promptOwner: owner,
  );
  if (raw is! Map) {
    throw const FormatException(
      'JSON-RPC session/prompt result must be a JSON object.',
    );
  }
  return Map<String, dynamic>.from(raw);
}
```

不得对 `Object?` 直接调用 `Map<String, dynamic>.from`；必须先用 `raw is Map` guard 固定 malformed result 为 `FormatException`。`AcpClient` 公开 owner-bound proxy 留到 Task 9；`sendRaw('session/prompt')` 拒绝留到 Task 11 完成 raw caller 迁移后。本提交不得创建临时 owner/barrier。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "request deadlines close and flush pending operations once"`。Expected: PASS。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "request deadline races consume late responses without zone errors"`。Expected: PASS。

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt request derives session only from its owner"`。Expected: PASS。

- [ ] 16. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: PASS。

- [ ] 17. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/acp_request_timeout_test.dart`。Expected: exit 0。

- [ ] 18. 运行 `git diff --check`。Expected: exit 0，无输出。

- [ ] 19. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/acp_request_timeout_test.dart`。

- [ ] 20. 运行 `git commit -m "fix: enforce ACP request deadlines"`。Expected: commit 成功。

### Task 6: 接纳快照、session generation 与统一权限 helper

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`
- Modify: `test/acp/json_rpc_peer_inbound_gate_test.dart`

在任何 Task 6 harness 或 RED 引用 admission 符号前，先在 `peer.dart` 加入下列纯协议脚手架；Task 2 已把根 `json_rpc_2` 固定为 direct dev dependency，因此本 Task 的根测试可直接 import `package:json_rpc_2/json_rpc_2.dart`。这里先定义类型与 callback 形状，后文 Step 14 再补 `_DecodedDelivery → _DispatchContext` 的行为 wiring：

```dart
abstract interface class InboundAdmission {
  Future<InboundGateTerminal<dynamic>> get terminal;
  Future<void> get settled;
  Future<dynamic> runLocalOperation(FutureOr<dynamic> Function() operation);
  void bindReservationReleased(Future<void> released);
  void bindResponseCommitted(Future<void> committed);
  void markPeerClosed();
}

typedef InboundAdmissionHook = InboundAdmission Function(
  String method,
  Map<String, dynamic>? params,
  Object arrivalIdentity,
);

typedef AdmittedInboundHandler = Future<dynamic> Function(
  Map<String, dynamic> params,
  InboundAdmission admission,
);

final class _AdmittedDispatchSlot {
  const _AdmittedDispatchSlot({
    required this.arrivalIdentity,
    required this.reservation,
    required this.responseCommitted,
  });

  final Object arrivalIdentity;
  final InboundGateReservation reservation;
  final Future<void> responseCommitted;
}
```

Task 6 在生产 `session_manager.dart` 首次使用 `HashSet`/`HashMap` 前先补直接 import；不能等 Task 9 才补，也不能依赖测试 library 的 import：

```dart
// third_party/dart_acp/lib/src/session/session_manager.dart
import 'dart:collection';
```

随后在 `test/acp/acp_request_timeout_test.dart` 增加下列 imports，明确 `SessionManager` 来自内部文件。Task 9 定义 `PromptLifecycleSnapshot` 时，在同一条 import 的 `show` 列表追加该符号；不得在 Task 6 提前引用尚不存在的类型，也不能假定 `dart_acp.dart` 会导出测试快照。随后定义 Task 6–10 共用的真实 wire harness；它使用真实 `StreamChannelController<String>`、`JsonRpcPeer`、`SessionManager`，只包装公开 `onInboundAdmission` hook 观察 reservation/response 两阶段。

```dart
import 'dart:collection';
import 'dart:convert';

import 'package:dart_acp/src/session/session_manager.dart'
    show SessionManager; // Task 9: show PromptLifecycleSnapshot, SessionManager
import 'package:logging/logging.dart';
import 'package:stream_channel/stream_channel.dart';
```

```dart
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

final class _ControlledPermissionProvider
    implements CancellablePermissionProvider {
  final List<PermissionOptions> requests = <PermissionOptions>[];
  final List<Completer<PermissionDecision>> pending =
      <Completer<PermissionDecision>>[];
  final List<(Object, PermissionCancellationReason)> cancellations =
      <(Object, PermissionCancellationReason)>[];
  final Completer<void> requestStarted = Completer<void>();
  final StreamController<int> requestEvents = StreamController<int>.broadcast();
  Object? cancellationFailure;

  @override
  Future<PermissionDecision> request(PermissionOptions options) {
    requests.add(options);
    if (!requestStarted.isCompleted) requestStarted.complete();
    requestEvents.add(requests.length - 1);
    final completer = Completer<PermissionDecision>();
    pending.add(completer);
    return completer.future;
  }

  void completeAllow(int index) {
    if (!pending[index].isCompleted) {
      pending[index].complete(const PermissionDecision.allow());
    }
  }

  void completeDecision(int index, PermissionDecision decision) {
    if (!pending[index].isCompleted) pending[index].complete(decision);
  }

  void completeError(int index, Object error) {
    if (!pending[index].isCompleted) pending[index].completeError(error);
  }

  void completeTimeout(int index) {
    if (!pending[index].isCompleted) {
      pending[index].completeError(const PermissionRequestTimeoutException());
    }
  }

  @override
  void cancelPendingPermission({
    required Object cancellationToken,
    required PermissionCancellationReason reason,
  }) {
    cancellations.add((cancellationToken, reason));
    final failure = cancellationFailure;
    if (failure != null) throw failure;
  }

  void finishPending() {
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.complete(const PermissionDecision.cancelled());
      }
    }
  }

  Future<void> waitForRequest(int index) async {
    if (requests.length > index) return;
    await requestEvents.stream.firstWhere((seen) => seen == index);
  }
}

final class _CountingFsProvider implements FsProvider {
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

final class _CountingTerminalProvider implements TerminalProvider {
  final DefaultTerminalProvider _inner = DefaultTerminalProvider(
    maxActiveHandles: 2,
    maxActiveHandlesPerSession: 1,
  );
  int createCalls = 0;
  int releaseCalls = 0;
  bool releaseThrows = false;
  final Completer<void> createStarted = Completer<void>();
  Completer<TerminalProcessHandle>? createResult;

  @override
  Future<TerminalProcessHandle> create({
    required String sessionId,
    required String command,
    List<String> args = const <String>[],
    String? cwd,
    Map<String, String>? env,
    int outputByteLimit = defaultTerminalOutputByteLimit,
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
  Future<String> currentOutput(TerminalProcessHandle handle) =>
      _inner.currentOutput(handle);
  @override
  Future<int> waitForExit(TerminalProcessHandle handle) =>
      _inner.waitForExit(handle);
  @override
  Future<void> kill(TerminalProcessHandle handle) => _inner.kill(handle);
  @override
  Future<void> release(TerminalProcessHandle handle) {
    releaseCalls += 1;
    return _inner.release(handle).then<void>((_) {
      if (releaseThrows) throw StateError('fixed release failure');
    });
  }
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
  Future<dynamic> runLocalOperation(
    FutureOr<dynamic> Function() operation,
  ) => inner.runLocalOperation(operation);
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
      if (!probe.responseCommitted.isCompleted) probe.responseCommitted.complete();
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
    AcpTimeouts timeouts = const AcpTimeouts(),
    Duration? promptCancelGrace,
    int maxOrdinaryConcurrentHandlers = 1,
  }) async {
    final channel = StreamChannelController<String>();
    final permissions = _ControlledPermissionProvider();
    final fs = _CountingFsProvider();
    final terminals = _CountingTerminalProvider();
    final effective = promptCancelGrace == null
        ? timeouts
        : AcpTimeouts(
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
      config: AcpConfig(
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
  final Completer<void> _ordinaryStarted = Completer<void>();
  final Completer<void> _releaseOrdinary = Completer<void>();
  late final StreamSubscription<String> _wireSubscription;
  int _nextId = 100;
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
    if (method == 'session/resume' || method == 'session/close') {
      channel.local.sink.add(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, dynamic>{},
      }));
      return;
    }
    if (!message.containsKey('method') && message.containsKey('id')) {
      _responses.remove(message['id'])?.complete(_RpcReply(message));
    }
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
    AcpSessionInputBudgetOwner? owner,
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
    channel.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    }));
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
    channel.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': id,
      'method': 'terminal/output',
      'params': <String, dynamic>{'sessionId': sessionId},
    }));
    await _ordinaryStarted.future.timeout(const Duration(seconds: 2));
  }

  void releaseOrdinaryPermits() {
    if (!_releaseOrdinary.isCompleted) _releaseOrdinary.complete();
  }

  void cancelOwner(
    AcpSessionInputBudgetOwner owner,
    PermissionCancellationReason reason,
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
    await wireRequests.close();
  }
}
```

- [ ] 1. 先给 harness 写 named 自验 `permission harness preserves two reserved control slots`，然后再增加四入口表与可重复运行的竞态断言。测试 harness 必须以真实 `StreamChannelController<String>`、`JsonRpcPeer`、`SessionManager` 驱动 wire；`admit` 等到 internal correlation 已登记后才返回，`releasePermit` 只释放指定 reservation，`finishResponseCommit` 只推进 sink commit，不用 `Future.delayed` 猜顺序。

harness 自验必须按 RED → GREEN 顺序执行：先保留旧的 `maxConcurrentHandlers: 2` / `maxOrdinaryConcurrentHandlers: 1` 构造体运行本测试，确认抛出“必须预留两个 handler 槽位”的 `ArgumentError`；再换入本 Task 上方已给出的最终 `start` 签名和 `ordinary + 2` 构造体，重跑为 GREEN。不得删掉 named 参数或把 total 重新硬编码为 2。

```dart
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
```

先运行：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission harness preserves two reserved control slots"
```

Expected RED：旧 `2/1` 构造在 harness start 阶段抛 `ArgumentError`，且尚未发送任何 wire。换入 `maxConcurrentHandlers: maxOrdinaryConcurrentHandlers + 2` 与 `maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers` 后原命令 Expected GREEN: PASS；`ordinary == 2` 的子流程同时证明 Task 10 专用 fixture 实际使用 total 4。

```dart
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

const localReasons = <PermissionCancellationReason>[
  PermissionCancellationReason.promptEnded,
  PermissionCancellationReason.promptCancelled,
  PermissionCancellationReason.sessionClosed,
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
```

- [ ] 2. 写 named RED `permission deadline starts at admission for ownerless and owner scoped requests`；用 75 ms `config.timeouts.permission` 占满 ordinary permits，再分别接纳 ownerless 与 owner-scoped 四入口，关键断言固定为：

```dart
test(
  'permission deadline starts at admission for ownerless and owner scoped requests',
  () async {
    final harness = await _PermissionAdmissionHarness.start(
      timeouts: const AcpTimeouts(
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
```

- [ ] 3. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission deadline starts at admission for ownerless and owner scoped requests"`。Expected: FAIL；旧实现从 handler 启动后才等待 provider，排队 admission 在 2 秒 watchdog 内不结算。

- [ ] 4. 写 named RED `all permission entries settle queued and running permit races once`；它必须完整覆盖四入口 × 三种本地原因 × queued/running 两种 permit 顺序，并对每个 case 断言一次 reservation release、一次 response commit；只有 provider 已启动的 running case 才有一次 provider cancellation，queued case 必须是零 provider request、零 cancellation callback 与零副作用。同一步增加独立 named RED `queued fs and terminal timeout or cancellation do not leak zone errors` 与 `throwing cancellable provider cannot break permission settlement`。前者把 fs read/terminal create 保持在 ordinary queue，分别让 admission deadline 与 `promptCancelled` 获胜；后者让 cancel callback 抛出含 canary 异常，精确覆盖 timeout、prompt cancel 与真实 session close。两条都在 guarded zone 内运行，并断言无 zone error、无 canary 外泄、固定 wire 终态与 `settled` 完成：

```dart
test('all permission entries settle queued and running permit races once', () async {
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
            await harness.permissions.requestStarted.future.timeout(
              const Duration(seconds: 2),
            );
            harness.cancelOwner(owner, reason);
          } else {
            harness.cancelOwner(owner, reason);
            harness.releaseOrdinaryPermits();
          }
          final response = await request.response.timeout(
            const Duration(seconds: 2),
          );
          expect(request.reservationReleaseCount, 1);
          expect(request.responseCommitCount, 1);
          expect(
            harness.permissions.cancellations,
            hasLength(permitFirst ? 1 : 0),
          );
          expect(harness.permissions.requests, hasLength(permitFirst ? 1 : 0));
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
});

test('queued fs and terminal timeout or cancellation do not leak zone errors', () async {
  for (final method in <String>[
    'fs/read_text_file',
    'terminal/create',
  ]) {
    for (final cancelled in <bool>[false, true]) {
      final zoneErrors = <Object>[];
      await runZonedGuarded(() async {
        final harness = await _PermissionAdmissionHarness.start(
          timeouts: const AcpTimeouts(
            permission: Duration(milliseconds: 75),
          ),
        );
        try {
          await harness.occupyAllOrdinaryPermits();
          final owner =
              harness.manager.beginPromptTurn(harness.sessionId);
          final request = await harness.admit(method, owner: owner);
          await request.admissionSeen.future
              .timeout(const Duration(seconds: 2));
          if (cancelled) {
            harness.cancelOwner(
              owner,
              PermissionCancellationReason.promptCancelled,
            );
          }

          final response = await request.response
              .timeout(const Duration(seconds: 2));
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

          // 迟到 permit 也不能补跑 local operation；多泵一轮让未监听的
          // `_localResult` error（若存在）进入当前 guarded zone。
          harness.releaseOrdinaryPermits();
          await pumpEventQueue().timeout(const Duration(seconds: 2));
          expect(harness.fs.readCalls, 0);
          expect(harness.terminals.createCalls, 0);
          harness.manager.endPromptTurn(owner);
        } finally {
          await harness.dispose().timeout(const Duration(seconds: 2));
        }
      }, (Object error, StackTrace stackTrace) {
        zoneErrors.add(error);
      });
      expect(
        zoneErrors,
        isEmpty,
        reason: '$method ${cancelled ? 'cancel' : 'timeout'}',
      );
    }
  }
});

test('permission cancellation keeps its reason after side effect starts', () async {
  for (final method in <String>[
    'fs/read_text_file',
    'fs/write_text_file',
    'terminal/create',
  ]) {
    for (final reason in <PermissionCancellationReason>[
      PermissionCancellationReason.promptEnded,
      PermissionCancellationReason.promptCancelled,
      PermissionCancellationReason.sessionClosed,
    ]) {
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
                Completer<TerminalProcessHandle>();
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
        expect(harness.fs.readCalls + harness.fs.writeCalls +
            harness.terminals.createCalls, 1);

        // reservation 已从 running gate detach，response 也已固定提交；
        // 此时真实 provider Future 仍未完成。
        await request.reservationReleased.future;
        expect(request.reservationReleaseCount, 1);
        expect(request.responseCommitCount, 1);
        await runZonedGuarded(() async {
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
        }, (Object error, StackTrace stackTrace) {
          zoneErrors.add(error);
        });
        expect(zoneErrors, isEmpty);
        await request.settled.timeout(const Duration(seconds: 2));
        harness.manager.endPromptTurn(owner);
      } finally {
        await harness.dispose();
      }
    }
  }
});

test('permission operation and cancellation atomically consume late value and error', () async {
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
        PermissionCancellationReason.promptCancelled,
      );
      final reply = await request.response.timeout(const Duration(seconds: 2));
      expect(reply.errorCode, -32003);
      expect(reply.errorMessage, 'Permission request cancelled.');

      await runZonedGuarded(() async {
        if (lateError) {
          cancelledFirst.fs.readResult!.completeError(
            StateError('fixed late fs read error'),
          );
        } else {
          cancelledFirst.fs.readResult!.complete('fixed late value');
        }
        await request.settled.timeout(const Duration(seconds: 2));
      }, (Object error, StackTrace stackTrace) {
        zoneErrors.add(error);
      });
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
    final reply = await request.response.timeout(const Duration(seconds: 2));
    expect(reply.result, <String, Object?>{'content': 'operation won'});

    operationFirst.cancelOwner(
      owner,
      PermissionCancellationReason.promptCancelled,
    );
    await request.settled.timeout(const Duration(seconds: 2));
    expect(operationFirst.permissions.cancellations, isEmpty);
    expect(request.reservationReleaseCount, 1);
    expect(request.responseCommitCount, 1);
    operationFirst.manager.endPromptTurn(owner);
  } finally {
    await operationFirst.dispose();
  }
});

test('malformed and missing admitted handlers always locally settle', () async {
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
      final reply = await request.response.timeout(const Duration(seconds: 2));
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
});

test('throwing cancellable provider cannot break permission settlement',
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
      runZonedGuarded(() async {
      final harness = await _PermissionAdmissionHarness.start(
        timeouts: const AcpTimeouts(
          permission: Duration(milliseconds: 75),
        ),
      );
      AcpSessionInputBudgetOwner? owner;
      try {
        harness.permissions.cancellationFailure = StateError(canary);
        if (cause == 'promptCancelled') {
          owner = harness.manager.beginPromptTurn(harness.sessionId);
        }
        final request = await harness.admit(
          'fs/read_text_file',
          owner: owner,
        );
        await harness.permissions.waitForRequest(0).timeout(
          const Duration(seconds: 2),
        );

        Future<void>? close;
        switch (cause) {
          case 'timeout':
            break;
          case 'promptCancelled':
            harness.cancelOwner(
              owner!,
              PermissionCancellationReason.promptCancelled,
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
        expect(response.errorCode, cause == 'timeout' ? -32002 : -32003);
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
        expect(harness.permissions.cancellations.single.$2, switch (cause) {
          'timeout' => PermissionCancellationReason.timedOut,
          'promptCancelled' => PermissionCancellationReason.promptCancelled,
          'sessionClosed' => PermissionCancellationReason.sessionClosed,
          _ => throw StateError('unreachable cancellation cause'),
        });
        if (owner != null) harness.manager.endPromptTurn(owner);
      } finally {
        try {
          await harness.dispose().timeout(const Duration(seconds: 2));
        } finally {
          if (!caseDone.isCompleted) caseDone.complete();
        }
      }
      }, (Object error, StackTrace stackTrace) {
        zoneErrors.add(error);
      });
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
  expect(logMessages, everyElement('ACP permission provider cancellation failed.'));
  expect(logMessages, hasLength(3));
  expect(logMessages.join('\n'), isNot(contains(canary)));
});
```

- [ ] 5. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "all permission entries settle queued and running permit races once"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "queued fs and terminal timeout or cancellation do not leak zone errors"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission cancellation keeps its reason after side effect starts"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission operation and cancellation atomically consume late value and error"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "malformed and missing admitted handlers always locally settle"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "throwing cancellable provider cannot break permission settlement"`。Expected: 六者均 FAIL；旧 handler 不能在 queued 时 short-circuit，queued fs/terminal 在 `runLocalOperation` 尚未绑定时完成 `_localResult` error 会向 guarded zone 泄漏，fs read/write/terminal allow 后的 running side effect 不能统一 detach 并保留三种首因，operation/cancellation 没有用同一个同步首赢点消费迟到 value/error，malformed/缺失 handler 也会绕过 manager 的 local-settle；旧 `_notifyPermissionProviderCancellation` 还会让第三方 cancel callback 的 canary 异常逃入 zone，打断固定结算或 session close。

- [ ] 6. 写 named RED `queued permission admissions keep their original owner and generation snapshot`；generation A 的 owner-scoped admission 在 ordinary gate 排队后，必须走真实 `closeSession → resumeSession` 重建同 sessionId 为 generation B，不得调用 testing replace。A 固定以 `sessionClosed` 结算且 provider/副作用为零，迟到 permit release 不能把旧 admission 改绑到 B：

```dart
test('queued permission admissions keep their original owner and generation snapshot', () async {
  final harness = await _PermissionAdmissionHarness.start(
    timeouts: const AcpTimeouts(
      permission: Duration(milliseconds: 75),
    ),
  );
  try {
    await harness.occupyAllOrdinaryPermits();
    final generationA =
        harness.manager.sessionGenerationForTesting(harness.sessionId);
    final ownerA = harness.manager.beginPromptTurn(harness.sessionId);
    final ownedA = await harness.admit('terminal/create', owner: ownerA);
    final closeA = harness.manager.closeSession(sessionId: harness.sessionId);
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
    final generationB =
        harness.manager.sessionGenerationForTesting(harness.sessionId);
    expect(identical(generationA, generationB), isFalse);
    final ownerB = harness.manager.beginPromptTurn(harness.sessionId);
    harness.releaseOrdinaryPermits();
    await pumpEventQueue();
    expect(harness.permissions.requests, isEmpty);
    expect(harness.terminals.createCalls, 0);
    expect(() => harness.manager.beginPromptTurn(harness.sessionId), throwsStateError);
    expect(ownedA.responseCommitCount, 1);
    expect(await ownedA.settled, isNull);
    harness.manager.endPromptTurn(ownerB);
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 7. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "queued permission admissions keep their original owner and generation snapshot"`。Expected: FAIL；旧 handler 按当前 sessionId 重查并可能把 A admission 改绑到真实 close+resume 后的 B generation。

- [ ] 8. 写 named RED `bridge first and manager first timeouts classify every running permission entry once`。四入口各跑 bridge-first 与 manager-first；bridge-first 由 provider Future 抛公开 timeout，manager-first 由 admission timer 获胜。两者都必须原子 `tryCancel(timedOut)`、一次 provider cancellation、一次 reservation/response，且固定 response 不含 canary：

```dart
test('bridge first and manager first timeouts classify every running permission entry once', () async {
  const canary = 'PERMISSION-TIMEOUT-CANARY';
  for (final entry in permissionEntries) {
    for (final bridgeFirst in <bool>[false, true]) {
      final harness = await _PermissionAdmissionHarness.start(
        timeouts: const AcpTimeouts(
          permission: Duration(milliseconds: 75),
        ),
      );
      try {
        final params = harness.paramsFor(entry.method)
          ..['canary'] = canary;
        final request = await harness.admit(entry.method, params: params);
        await harness.permissions.waitForRequest(0).timeout(
          const Duration(seconds: 2),
        );
        if (bridgeFirst) harness.permissions.completeTimeout(0);
        final reply = await request.response.timeout(const Duration(seconds: 2));
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
});
```

- [ ] 9. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "bridge first and manager first timeouts classify every running permission entry once"`。Expected: FAIL；bridge timeout 旧路径会退化为 provider error/deny，且不会把 admission 首因原子归类为 `timedOut`。

- [ ] 10. 写 named RED `terminal permission timeout close and dispose release pending lease before replacement`。timeout 与 session close 在同 manager 上立即创建 replacement；dispose 使用同一 terminal provider 创建新 manager，三种 cause 都要求首个 create 调用为零、replacement 不触发 per-session limit：

```dart
test('terminal permission timeout close and dispose release pending lease before replacement', () async {
  for (final cause in <String>['timeout', 'sessionClosed', 'disposed']) {
    var harness = await _PermissionAdmissionHarness.start(
      timeouts: const AcpTimeouts(
        permission: Duration(milliseconds: 75),
      ),
    );
    try {
      final first = await harness.admit('terminal/create');
      await harness.permissions.waitForRequest(0).timeout(
        const Duration(seconds: 2),
      );
      if (cause == 'sessionClosed') {
        await harness.manager.closeSession(sessionId: harness.sessionId);
        await harness.manager.resumeSession(
          sessionId: harness.sessionId,
          workspaceRoot: '/tmp',
        );
      } else if (cause == 'disposed') {
        await harness.manager.dispose();
      }
      if (cause != 'disposed') {
        final firstReply = await first.response.timeout(
          const Duration(seconds: 2),
        );
        expect(firstReply.errorCode, cause == 'timeout' ? -32002 : -32003);
        final replacement = await harness.admit('terminal/create');
        await harness.permissions.waitForRequest(1).timeout(
          const Duration(seconds: 2),
        );
        harness.permissions.completeAllow(1);
        final replacementReply = await replacement.response.timeout(
          const Duration(seconds: 2),
        );
        expect(replacementReply.errorCode, isNull);
        expect(harness.terminals.createCalls, 1);
      } else {
        expect(harness.terminals.createCalls, 0);
        final replacement = await _PermissionAdmissionHarness.start();
        try {
          final request = await replacement.admit('terminal/create');
          await replacement.permissions.waitForRequest(0);
          replacement.permissions.completeAllow(0);
          expect((await request.response).errorCode, isNull);
          expect(replacement.terminals.createCalls, 1);
        } finally {
          await replacement.dispose();
        }
      }
    } finally {
      await harness.dispose();
    }
  }
});
```

- [ ] 11. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "terminal permission timeout close and dispose release pending lease before replacement"`。Expected: FAIL；旧 terminal permission wait 持有 pending lease，replacement 命中 per-session limit。

- [ ] 12. 在 `test/acp/json_rpc_peer_inbound_gate_test.dart` 增加 `import 'package:json_rpc_2/json_rpc_2.dart' as rpc;`，定义真实 pass-through admission，并把当前文件中 **全部 16 处** `onReadTextFile/onWriteTextFile/onRequestPermission/onTerminalCreate` 一参 callback 从 `(params)` 迁为 `(params, admission)`（不使用 admission 的旧断言写 `(params, _)`）。每个直接构造且安装上述四类 handler 的 peer 都立即调用 `_installPassThroughAdmissions(peer)`，不能用 nullable hook 或 fake reservation 绕过 production admitted 路径：

```dart
final class _PassThroughInboundAdmission implements InboundAdmission {
  _PassThroughInboundAdmission({
    required this.method,
    required this.params,
    required this.arrivalIdentity,
  });

  final String method;
  final Map<String, dynamic>? params;
  final Object arrivalIdentity;
  final Completer<InboundGateTerminal<dynamic>> _terminal =
      Completer<InboundGateTerminal<dynamic>>.sync();
  final Completer<void> _settled = Completer<void>.sync();
  bool _localFinished = false;
  bool _reservationFinished = false;
  bool _responseFinished = false;
  int responseCommitCount = 0;

  @override
  Future<InboundGateTerminal<dynamic>> get terminal => _terminal.future;
  @override
  Future<void> get settled => _settled.future;

  @override
  Future<dynamic> runLocalOperation(
    FutureOr<dynamic> Function() operation,
  ) => Future<dynamic>.sync(operation).whenComplete(() {
    _localFinished = true;
    _tryCompleteSettled();
  });

  @override
  void bindReservationReleased(Future<void> released) {
    void finish() {
      if (_reservationFinished) return;
      _reservationFinished = true;
      _tryCompleteSettled();
    }
    released.then<void>((_) => finish(), onError: (_, __) => finish());
  }

  @override
  void bindResponseCommitted(Future<void> committed) {
    void finish() {
      if (_responseFinished) return;
      _responseFinished = true;
      responseCommitCount += 1;
      _tryCompleteSettled();
    }
    committed.then<void>((_) => finish(), onError: (_, __) => finish());
  }

  @override
  void markPeerClosed() {
    if (_responseFinished) return;
    _responseFinished = true;
    responseCommitCount += 1;
    _tryCompleteSettled();
  }

  void _tryCompleteSettled() {
    if (!_localFinished ||
        !_reservationFinished ||
        !_responseFinished ||
        _settled.isCompleted) {
      return;
    }
    _settled.complete();
  }
}

void _installPassThroughAdmissions(
  JsonRpcPeer peer, {
  void Function(_PassThroughInboundAdmission admission)? onAdmission,
}) {
  peer.onInboundAdmission = (method, params, arrivalIdentity) {
    final admission = _PassThroughInboundAdmission(
      method: method,
      params: params,
      arrivalIdentity: arrivalIdentity,
    );
    onAdmission?.call(admission);
    return admission;
  };
}
```

同一步写 named RED `admitted slots preserve malformed and notification response stages`。一个 batch 同时放入带 id 的 malformed positional params 与合法 notification；notification handler 保持阻塞，使它的无响应阶段先完成，而带 id 请求必须继续等待真实 batch tracker commit。两个 admission 必须取得不同 arrival identity，且 malformed 仍通过 admission 的 local-settle：

```dart
test(
  'admitted slots preserve malformed and notification response stages',
  () async {
    final channel = StreamChannelController<String>(sync: true);
    final outbound = StreamIterator<String>(channel.local.stream);
    final peer = JsonRpcPeer(channel.foreign);
    final admissions = <_PassThroughInboundAdmission>[];
    final notificationStarted = Completer<void>.sync();
    final releaseNotification = Completer<void>.sync();
    _installPassThroughAdmissions(peer, onAdmission: admissions.add);
    peer.onReadTextFile = (params, _) async {
      if (params['notification'] == true) {
        notificationStarted.complete();
        await releaseNotification.future;
      }
      return <String, dynamic>{'content': 'ok'};
    };
    try {
      channel.local.sink.add(jsonEncode(<Object?>[
        <String, dynamic>{
          'jsonrpc': '2.0',
          'id': 41,
          'method': 'fs/read_text_file',
          'params': <Object?>['not-an-object'],
        },
        <String, dynamic>{
          'jsonrpc': '2.0',
          'method': 'fs/read_text_file',
          'params': <String, dynamic>{'notification': true},
        },
      ]));
      await notificationStarted.future.timeout(const Duration(seconds: 2));
      await pumpEventQueue();
      expect(admissions, hasLength(2));
      final malformed = admissions.singleWhere((item) => item.params == null);
      final notification = admissions.singleWhere(
        (item) => item.params?['notification'] == true,
      );
      expect(identical(
        malformed.arrivalIdentity,
        notification.arrivalIdentity,
      ), isFalse);
      expect(notification.responseCommitCount, 1,
          reason: 'notification response stage is completed at admission');
      expect(malformed.responseCommitCount, 0,
          reason: 'request tracker waits for the blocked batch sibling');

      releaseNotification.complete();
      expect(await outbound.moveNext(), isTrue);
      final decoded = jsonDecode(outbound.current);
      final response = Map<String, dynamic>.from(
        (decoded is List ? decoded.single : decoded) as Map,
      );
      expect(response['id'], 41);
      expect(
        (response['error'] as Map)['code'],
        rpc.RpcException.invalidParams('fixed expected error').code,
      );
      await Future.wait<void>(<Future<void>>[
        malformed.settled,
        notification.settled,
      ]).timeout(const Duration(seconds: 2));
      expect(malformed.responseCommitCount, 1);
      expect(notification.responseCommitCount, 1);
    } finally {
      if (!releaseNotification.isCompleted) releaseNotification.complete();
      await peer.close();
      await outbound.cancel();
      await channel.local.sink.close();
    }
  },
);
```

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "admitted slots preserve malformed and notification response stages"`。Expected: FAIL at compile time或 admission hook 缺 slot；Task 3 的 `_DecodedDelivery` 只携带 reservations，无法把 notification 的已完成 response stage和带 id 请求的真实 tracker Future 精确送到同一 dispatch element。

- [ ] 14. 把四个 permission gate 切到前文已经定义的 admitted 契约；`_runAdmittedInbound` 必须在 `runCancellable` 前对象化 params、同步调用 hook并绑定 reservation/response阶段：

```dart
InboundAdmissionHook? onInboundAdmission;
AdmittedInboundHandler? onReadTextFile;
AdmittedInboundHandler? onWriteTextFile;
AdmittedInboundHandler? onRequestPermission;
AdmittedInboundHandler? onTerminalCreate;
```

在 `_registerClientHandlers` 内完整替换原有四个 registration，其他普通 handler 继续使用 `_runInbound`：

```dart
_peer.registerMethod(
  'fs/read_text_file',
  (rpc.Parameters params) => _runAdmittedInbound(
    'fs/read_text_file',
    params,
    onReadTextFile,
  ),
);
_peer.registerMethod(
  'fs/write_text_file',
  (rpc.Parameters params) => _runAdmittedInbound(
    'fs/write_text_file',
    params,
    onWriteTextFile,
  ),
);
_peer.registerMethod(
  'session/request_permission',
  (rpc.Parameters params) => _runAdmittedInbound(
    'session/request_permission',
    params,
    onRequestPermission,
  ),
);
_peer.registerMethod(
  'terminal/create',
  (rpc.Parameters params) => _runAdmittedInbound(
    'terminal/create',
    params,
    onTerminalCreate,
  ),
);
```

随后在同一 class 内加入完整 admitted runner：

```dart
Future<dynamic> _runAdmittedInbound(
  String method,
  rpc.Parameters params,
  AdmittedInboundHandler? handler,
) {
  final context = _dispatchContext;
  final slot = context?.takeAdmitted(method);
  if (slot == null) {
    return Future<dynamic>.error(
      StateError('Missing inbound reservation for $method.'),
    );
  }
  final reservation = slot.reservation;
  final raw = params.value;
  final request = raw is Map
      ? Map<String, dynamic>.from(raw)
      : null;
  final hook = onInboundAdmission;
  if (hook == null) {
    slot.reservation.release();
    return Future<dynamic>.error(
      StateError('Missing inbound admission hook for $method.'),
    );
  }
  final InboundAdmission admission;
  try {
    admission = hook(method, request, slot.arrivalIdentity);
  } on Object catch (error, stackTrace) {
    reservation.release();
    return Future<dynamic>.error(error, stackTrace);
  }
  admission.bindReservationReleased(reservation.released);
  admission.bindResponseCommitted(slot.responseCommitted);
  final running = reservation.runCancellable<dynamic>(
    terminal: admission.terminal,
    operation: () => admission.runLocalOperation(() {
      if (request == null || handler == null) {
        throw rpc.RpcException(-32602, 'Invalid params.');
      }
      return handler(request, admission);
    }),
  );
  context!.track(running);
  return running;
}
```

`runLocalOperation` 必须包住 malformed params、缺失 handler 与四个正常 handler；因此无论哪条路径抛错或返回，都由 manager 的同一个同步首赢点结算，不能绕过 admission 的 `settled` 清理。

`_DispatchContext.takeAdmitted` 不得重新按 method 猜 correlation；下面把 Task 3 的 reservation→correlation 映射完整固化到 `_DecodedDelivery`。带合法 id 的请求复用 `_InboundCorrelation.arrivalIdentity` 与真实 `responseCommitted.future`；notification 没有 tracker，但仍以自己的 reservation 绑定一个不可复用 arrival identity，并使用已经完成的 response stage：

```dart
List<_AdmittedDispatchSlot> _buildAdmittedDispatchSlots(
  List<InboundGateReservation> reservations,
  List<_InboundCorrelation> correlations,
) {
  final byReservation =
      HashMap<InboundGateReservation, _InboundCorrelation>.identity();
  for (final correlation in correlations) {
    byReservation[correlation.reservation] = correlation;
  }
  return List<_AdmittedDispatchSlot>.generate(reservations.length, (index) {
    final reservation = reservations[index];
    final correlation = byReservation[reservation];
    if (correlation == null) {
      return _AdmittedDispatchSlot(
        arrivalIdentity: Object(),
        reservation: reservation,
        responseCommitted: Future<void>.value(),
      );
    }
    return _AdmittedDispatchSlot(
      arrivalIdentity: correlation.arrivalIdentity,
      reservation: reservation,
      responseCommitted: correlation.responseCommitted.future,
    );
  }, growable: false);
}

// Task 3 `_admitAndDispatchRequests` 在 correlation reserve 成功后增加：
final admittedSlots = _buildAdmittedDispatchSlots(
  reservations,
  correlations,
);
final rewritten = _rewriteInboundCorrelationIds(
  requests,
  reservations,
  correlations,
);
_dispatchDecoded(_DecodedDelivery(
  wasBatch ? rewritten : rewritten.single,
  reservations: reservations,
  admittedSlots: admittedSlots,
));

// Replace `_DecodedDelivery` normal/terminal constructors and fields.
class _DecodedDelivery {
  _DecodedDelivery(
    this.message, {
    this.reservations,
    this.admittedSlots,
  }) : assert(
         reservations == null ||
             (admittedSlots != null &&
                 admittedSlots.length == reservations.length),
       ),
       isTerminal = false,
       terminalError = null,
       terminalStackTrace = null;

  _DecodedDelivery.terminal({Object? error, StackTrace? stackTrace})
    : message = null,
      reservations = null,
      admittedSlots = null,
      isTerminal = true,
      terminalError = error,
      terminalStackTrace = stackTrace;

  final Object? message;
  final List<InboundGateReservation>? reservations;
  final List<_AdmittedDispatchSlot>? admittedSlots;
  final bool isTerminal;
  final Object? terminalError;
  final StackTrace? terminalStackTrace;

  void releaseUndelivered() {
    final held = reservations;
    if (held == null) return;
    for (final reservation in held) {
      reservation.release();
    }
  }
}
```

`_deliverDecoded` 在写入 `_decodedIncoming` 前必须同时取得两个等长列表；缺任一列表视为内部错误并释放尚未 claim 的 reservation。正常路径用 `final context = _DispatchContext(reservations, admittedSlots);`。`_DispatchContext` 构造器和 `takeAdmitted` 完整方法体为：

```dart
class _DispatchContext {
  _DispatchContext(this.reservations, this.admittedSlots)
    : assert(reservations.length == admittedSlots.length),
      assert(() {
        for (var index = 0; index < reservations.length; index += 1) {
          if (!identical(
            reservations[index],
            admittedSlots[index].reservation,
          )) {
            return false;
          }
        }
        return true;
      }()),
      _claimed = List<bool>.filled(reservations.length, false);

  final List<InboundGateReservation> reservations;
  final List<_AdmittedDispatchSlot> admittedSlots;
  final List<bool> _claimed;
  final List<Future<void>> _claimedSettled = <Future<void>>[];

  InboundGateReservation? take(String method) {
    for (var index = 0; index < reservations.length; index += 1) {
      if (_claimed[index]) continue;
      if (reservations[index].method == method) {
        _claimed[index] = true;
        return reservations[index];
      }
    }
    return null;
  }

  _AdmittedDispatchSlot? takeAdmitted(String method) {
    for (var index = 0; index < admittedSlots.length; index += 1) {
      if (_claimed[index]) continue;
      final slot = admittedSlots[index];
      if (slot.reservation.method != method) continue;
      if (!identical(slot.reservation, reservations[index])) {
        throw StateError('Inbound admitted slot reservation mismatch.');
      }
      _claimed[index] = true;
      return slot;
    }
    return null;
  }

  // 保留 Task 3 已有 track/retainUnclaimed/releaseUnused 方法体；它们与
  // take/takeAdmitted 共用同一 `_claimed`，不能建立第二份 claimed 状态。
}
```

`_deliverDecoded` 的对应替换必须是可执行 body，而不是只改构造器：

```dart
void _deliverDecoded(_DecodedDelivery delivery) {
  if (delivery.isTerminal) {
    if (_decodedIncomingClosed) return;
    final error = delivery.terminalError;
    if (error != null) {
      _decodedIncoming.addError(error, delivery.terminalStackTrace);
    }
    unawaited(_closeDecodedIncoming());
    return;
  }

  final reservations = delivery.reservations;
  if (reservations == null) {
    _decodedIncoming.add(delivery.message);
    return;
  }
  final admittedSlots = delivery.admittedSlots;
  if (admittedSlots == null || admittedSlots.length != reservations.length) {
    for (final reservation in reservations) {
      reservation.release();
    }
    throw StateError('Inbound admitted dispatch slots are missing.');
  }

  final previousContext = _dispatchContext;
  final context = _DispatchContext(reservations, admittedSlots);
  _dispatchContext = context;
  var delivered = false;
  try {
    _decodedIncoming.add(delivery.message);
    delivered = true;
  } finally {
    if (delivered) {
      context.retainUnclaimed();
    } else {
      context.releaseUnused();
    }
    _dispatchContext = previousContext;
  }
}
```

- [ ] 15. 在 `session_manager.dart` 增加不可复用的 session/peer identity；`AcpSessionInputBudgetOwner` 在本提交实现 Task 5 的 `JsonRpcPromptOwner`，并携带 manager identity，保证 Task 6 提交本身可编译：

```dart
final class _SessionGeneration {
  _SessionGeneration(this.sessionId, this.value);
  final String sessionId;
  final int value;
  bool active = true;
}

final class _PeerEpoch {
  bool active = true;
}

final Object _managerIdentity = Object();

final class AcpSessionInputBudgetOwner implements JsonRpcPromptOwner {
  const AcpSessionInputBudgetOwner._(
    this.sessionId,
    this.generation,
    this.managerIdentity,
  );
  @override
  final String sessionId;
  @override
  final int generation;
  final Object managerIdentity;
}

// `_beginInputBudgetPhase` 构造 owner 时同步补第三个参数，确保 Task 6
// 改完 owner 构造器后本提交自身可编译。
final owner = AcpSessionInputBudgetOwner._(
  sessionId,
  ++_nextInputBudgetGeneration,
  _managerIdentity,
);
```

- [ ] 16. 增加 first-wins admission。构造函数必须先给 `_localResult.future` 同步安装 value/error drain，再从同一个 `config.timeouts.permission` 启动 deadline；因此 queued admission 即使在 permit 前 timeout/cancel、从未调用 `runLocalOperation`，其 payload-free local error 也已有监听者，不会作为未处理异步错误泄漏到 zone。`runLocalOperation` 仍返回同一个原始 Future，running caller 的 value/error 语义不变。`tryCancel`、provider 正常完成、peer close 和最终 settled 都取消同一 timer。下面的方法体直接作为实现基线：

```dart
final class _InboundPermissionAdmission implements InboundAdmission {
  _InboundPermissionAdmission({
    required this.manager,
    required this.method,
    required this.correlationIdentity,
    required this.sessionId,
    required this.sessionGeneration,
    required this.promptOwner,
    required this.peerEpoch,
  }) {
    // 必须早于 timer 与任何可同步触发 `tryCancel` 的 hook。这个分支只
    // drain，无状态写入；真实 local operation 仍监听同一个原始 Future。
    unawaited(_localResult.future.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    ));
    deadlineTimer = Timer(manager.config.timeouts.permission, () {
      tryCancel(PermissionCancellationReason.timedOut);
    });
  }
  final SessionManager manager;
  final String method;
  final Object correlationIdentity;
  final String? sessionId;
  final _SessionGeneration? sessionGeneration;
  final AcpSessionInputBudgetOwner? promptOwner;
  final _PeerEpoch peerEpoch;
  final Object cancellationToken = Object();
  final Completer<InboundGateTerminal<dynamic>> _terminal =
      Completer<InboundGateTerminal<dynamic>>.sync();
  final Completer<PermissionCancellationReason> _cancellation =
      Completer<PermissionCancellationReason>.sync();
  final Completer<dynamic> _localResult = Completer<dynamic>.sync();
  final Completer<void> _settled = Completer<void>.sync();
  PermissionCancellationReason? terminalReason;
  Timer? deadlineTimer;
  bool providerStarted = false;
  bool providerCancellationSent = false;
  bool localSettled = false;
  bool reservationReleased = false;
  bool responseFinished = false;
  bool peerClosed = false;
  bool settledCompleted = false;
  @override Future<InboundGateTerminal<dynamic>> get terminal => _terminal.future;
  @override Future<void> get settled => _settled.future;
  Future<PermissionCancellationReason> get cancellation =>
      _cancellation.future;

  bool tryCompleteLocal(
    InboundGateTerminal<dynamic> outcome, {
    StackTrace? stackTrace,
    PermissionCancellationReason? cancellationReason,
  }) {
    if (localSettled) return false;
    localSettled = true;
    terminalReason = cancellationReason;
    deadlineTimer?.cancel();
    if (!_terminal.isCompleted) _terminal.complete(outcome);
    switch (outcome) {
      case InboundGateTerminalValue<dynamic>(:final value):
        _localResult.complete(value);
      case InboundGateTerminalError<dynamic>(
          :final error,
          stackTrace: final outcomeStackTrace,
        ):
        _localResult.completeError(
          error,
          stackTrace ?? outcomeStackTrace ?? StackTrace.current,
        );
    }
    if (cancellationReason case final reason?) {
      if (!_cancellation.isCompleted) _cancellation.complete(reason);
      manager._notifyPermissionProviderCancellation(this, reason);
    }
    tryCompleteSettled();
    return true;
  }

  bool tryCancel(PermissionCancellationReason reason) => tryCompleteLocal(
    manager._permissionGateTerminal(method, reason),
    cancellationReason: reason,
  );

  @override
  Future<dynamic> runLocalOperation(
    FutureOr<dynamic> Function() operation,
  ) {
    Future<dynamic>.sync(operation).then<void>((value) {
      // Callback 同步竞争；失败分支只消费迟到 value，不再投递第二次结果。
      tryCompleteLocal(InboundGateTerminalValue<dynamic>(value));
    }, onError: (Object error, StackTrace stackTrace) {
      // Callback 同步竞争；失败分支只消费迟到 error，避免 zone 泄漏。
      tryCompleteLocal(
        InboundGateTerminalError<dynamic>(error, stackTrace),
        stackTrace: stackTrace,
      );
    });
    return _localResult.future;
  }

  @override
  void bindReservationReleased(Future<void> released) {
    void finish() {
      if (reservationReleased) return;
      reservationReleased = true;
      manager._onAdmissionReservationReleased(this);
      tryCompleteSettled();
    }
    released.then<void>((_) => finish(), onError: (_, __) => finish());
  }

  @override
  void bindResponseCommitted(Future<void> committed) {
    void finish() {
      if (responseFinished) return;
      responseFinished = true;
      manager._onAdmissionResponseFinished(this);
      tryCompleteSettled();
    }
    committed.then<void>((_) => finish(), onError: (_, __) => finish());
  }

  @override
  void markPeerClosed() {
    if (peerClosed) return;
    peerClosed = true;
    responseFinished = true;
    deadlineTimer?.cancel();
    tryCancel(PermissionCancellationReason.connectionClosed);
    manager._onAdmissionResponseFinished(this);
    tryCompleteSettled();
  }

  void tryCompleteSettled() {
    if (settledCompleted ||
        !localSettled ||
        !reservationReleased ||
        !responseFinished) {
      return;
    }
    settledCompleted = true;
    deadlineTimer?.cancel();
    manager._removeInboundAdmission(this);
    _settled.complete();
  }
}
```

- [ ] 17. 增加下列 identity 索引与完整 generation helper。Task 6 必须在本提交内定义 counter、helper、testing getter 和所有调用点，不能等 Task 10 补符号；只在 new/fork/load/resume 成功 commit 后换 generation，在 close/rollback/dispose 的首个 `await` 前同步失效。Task 9 会把 `_settlingPromptOwners` 收拢进完整 lifecycle，但 Task 6 提交先以该 map 保持可编译和旧 owner 归属：

```dart
var _nextSessionGeneration = 0;
final Map<String, _SessionGeneration> _sessionGenerations =
    <String, _SessionGeneration>{};
final Set<_InboundPermissionAdmission> _inboundAdmissions =
    HashSet<_InboundPermissionAdmission>.identity();
final Map<AcpSessionInputBudgetOwner, Set<_InboundPermissionAdmission>>
    _admissionsByOwner =
        HashMap<AcpSessionInputBudgetOwner,
            Set<_InboundPermissionAdmission>>.identity();
final Map<String, AcpSessionInputBudgetOwner> _settlingPromptOwners =
    <String, AcpSessionInputBudgetOwner>{};

_SessionGeneration _replaceSessionGeneration(String sessionId) {
  final previous = _sessionGenerations[sessionId];
  if (previous != null) previous.active = false;

  final replacement = _SessionGeneration(
    sessionId,
    ++_nextSessionGeneration,
  );
  _sessionGenerations[sessionId] = replacement;
  return replacement;
}

void _invalidateSessionGeneration(String sessionId) {
  final current = _sessionGenerations[sessionId];
  if (current == null) return;
  current.active = false;
}

Object? sessionGenerationForTesting(String sessionId) =>
    _sessionGenerations[sessionId];

// `_hasAnySessionState` 同步加入这一项，generated new/fork 不得把尚未
// cleanup 的 inactive identity 当作完全空闲的 sessionId。
// || _sessionGenerations.containsKey(sessionId)

void settlePromptAdmissions({
  required AcpSessionInputBudgetOwner owner,
  required PermissionCancellationReason reason,
}) {
  final owned = _admissionsByOwner[owner];
  if (owned == null) return;
  _settlingPromptOwners[owner.sessionId] = owner;
  for (final admission in owned.toList(growable: false)) {
    admission.tryCancel(reason);
  }
}

void _settleSessionAdmissionsForClose(String sessionId) {
  final admissions = _inboundAdmissions
      .where((admission) => admission.sessionId == sessionId)
      .toList(growable: false);
  for (final admission in admissions) {
    admission.tryCancel(PermissionCancellationReason.sessionClosed);
  }
}
```

调用点必须在 Task 6 同一提交落齐，位置固定如下：

```dart
// newSession：generated registration 与 update drain 均成功后。
_commitGeneratedSessionRegistration(registration);
_replaceSessionGeneration(id);

// forkSession：generated registration 与 update drain 均成功后。
_commitGeneratedSessionRegistration(registration);
_replaceSessionGeneration(newId);

// loadSession 的 `_runSessionSetup` commit callback 最后一项。
commit: (result) {
  _commitSessionResultModes(sessionId, result);
  _publishSessionResultObservation(
    operation: AcpBoundedSessionOperation.loadSession,
    sessionId: sessionId,
    result: result,
  );
  _replaceSessionGeneration(sessionId);
},

// resumeSession 的 `_runSessionSetup` commit callback 最后一项。
commit: (result) {
  _commitSessionResultModes(sessionId, result);
  _publishSessionResultObservation(
    operation: AcpBoundedSessionOperation.resumeSession,
    sessionId: sessionId,
    result: result,
  );
  _replaceSessionGeneration(sessionId);
},
```

close、setup rollback、generated rollback 与 dispose 的失效点不得放到任何异步 cleanup 之后：

```dart
Object _beginSessionClose(String sessionId) {
  _invalidateSessionGeneration(sessionId); // 本方法第一项同步失效动作。
  _invalidateInputBudgetPhase(sessionId);
  _invalidateRequestInputBudgetPhasesForSource(sessionId);
  _cancelledPromptOwners.remove(sessionId);
  final owner = Object();
  _sessionClosingOwners.putIfAbsent(sessionId, () => <Object>{}).add(owner);
  _settleSessionAdmissionsForClose(sessionId);
  _revokeTerminalLeases(sessionId: sessionId);
  return owner;
}

// `_runSessionSetup` 的 catch 入口；若 action/commit 已触及 session，
// 先阻断该 identity 的迟到 update/permission，再回滚局部状态。
} catch (_) {
  _invalidateSessionGeneration(sessionId);
  // 原 rollback body。
  rethrow;
}

Future<void> _rollbackGeneratedSession(
  _GeneratedSessionRegistration registration,
) async {
  final sessionId = registration.sessionId;
  if (!identical(
    _generatedSessionRegistrationOwners[sessionId],
    registration.identity,
  )) {
    return;
  }
  final invalidatedGeneration = _sessionGenerations[sessionId];
  _invalidateSessionGeneration(sessionId); // 早于本方法首个 await。
  // 原同步 map/controller rollback body。
  try {
    await _releaseSessionTerminals(sessionId);
  } finally {
    if (identical(
      _sessionGenerations[sessionId],
      invalidatedGeneration,
    )) {
      _sessionGenerations.remove(sessionId);
    }
  }
}

// `dispose` 在 `_disposed = true` 后、原同步 invalidation 前插入；此段
// 自身没有 await，保证所有 generation 在 dispose 首个 await 前失效。
final generationsAtDispose =
    Map<String, _SessionGeneration>.from(_sessionGenerations);
for (final sessionId in generationsAtDispose.keys) {
  _invalidateSessionGeneration(sessionId);
}

// 原 dispose async cleanup 用 try/finally 包住；在 finally 中仅删除
// dispose 开始时捕获且仍为 current 的 identity。
finally {
  _sessionGenerations.removeWhere(
    (sessionId, current) =>
        identical(generationsAtDispose[sessionId], current),
  );
}
```

`_settleSessionAdmissionsForClose` 是 Task 6–9 过渡版 close 接线：它在 `_beginSessionClose` 的同步前缀内、任何远端 RPC 或首个 `await` 之前快照并结算该 session 的 admissions，使本 Task 的 generation close/resume、terminal lease replacement 和抛错 cancellable provider 三条 close GREEN 在 Task 6 独立提交就能收敛。只有已经启动的 provider 才会收到 cancel callback，且该 callback 已由 Step 19 的 `_notifyPermissionProviderCancellation` 隔离；queued admission 保持零 callback，单个第三方抛错也不得中断这个 snapshot 循环。

Task 10 完整替换 close 时必须从 `_beginSessionClose` **删除**这一过渡调用：先选出并登记 ordinary/frozen cleanup key，再且只在 `_prepareSessionClose` 调用一次 `_settleSessionAdmissionsForClose(sessionId)`。不得在 begin 与 prepare 各保留一次；否则 admission response grace 会在 frozen selection 前按 admission identity 建第二个 window。

`_replaceSessionGeneration` 不得出现在 request 发出、workspace 暂存、generated registration 暂存或 update drain 之前；rollback/dispose 的 identity 删除必须复核当前 map 对象，不能删除并发建立的 replacement。Task 6 的 admission snapshot 与 `sessionGenerationForTesting` 均只读取这里已经存在的 map，因此该提交单独 analyze/test 时不依赖 Task 10 声明。

- [ ] 18. 在 `SessionManager` 构造体完成现有校验后注册 `peer.onInboundAdmission = _admitInboundPermission` 与 Task 4 的状态型 unavailable listener；hook 只读取 sessionId并同步冻结 generation、pending/settling owner和peer epoch，随后立即构造 admission，因此 timer 已在返回 peer 前启动。

- [ ] 19. provider decision 仍单独消费迟到 provider value/error；provider allow 只结束 decision 阶段。真实 operation 不再另建一套 `Future.any`，而由 Step 16 的单一同步 `tryCompleteLocal(value/error)` 与 `tryCancel` 竞争；operation callback 的失败分支只消费迟到 value/error。取消分支始终使用 admission 已保存的原始 reason，并按入口固定映射：

```dart
final class _PermissionProviderResult {
  const _PermissionProviderResult.value(this.value)
    : error = null,
      stackTrace = null;
  const _PermissionProviderResult.error(this.error, this.stackTrace)
    : value = null;
  final PermissionDecision? value;
  final Object? error;
  final StackTrace? stackTrace;
}

final class _PermissionGateCancellation implements Exception {
  const _PermissionGateCancellation(this.reason);
  final PermissionCancellationReason reason;
}

_InboundPermissionAdmission _admitInboundPermission(
  String method,
  Map<String, dynamic>? params,
  Object correlationIdentity,
 ) {
  final sessionId = _sessionIdFromMap(params);
  final generation = sessionId == null ? null : _sessionGenerations[sessionId];
  final owner = sessionId == null
      ? null
      : (_settlingPromptOwners[sessionId] ??
            _inputBudgetPhases[sessionId]?.owner);
  final admission = _InboundPermissionAdmission(
    manager: this,
    method: method,
    correlationIdentity: correlationIdentity,
    sessionId: sessionId,
    sessionGeneration: generation,
    promptOwner: owner,
    peerEpoch: _peerEpoch,
  );
  _inboundAdmissions.add(admission);
  if (owner != null) {
    (_admissionsByOwner[owner] ??=
            HashSet<_InboundPermissionAdmission>.identity())
        .add(admission);
  }
  return admission;
}

Future<PermissionDecision> _permissionProviderDecision({
  required _InboundPermissionAdmission admission,
  required PermissionOptions options,
}) async {
  if (admission.terminalReason case final reason?) {
    return _permissionDecisionForCancellation(reason);
  }
  admission.providerStarted = true;
  final providerOptions = PermissionOptions(
    title: options.title,
    rationale: options.rationale,
    options: options.options,
    choices: options.choices,
    sessionId: options.sessionId,
    toolName: options.toolName,
    toolKind: options.toolKind,
    metadata: options.metadata,
    transientPolicyContext: options.transientPolicyContext,
    cancellationToken: admission.cancellationToken,
  );
  final providerResult = config.permissionProvider
      .request(providerOptions)
      .then<_PermissionProviderResult>(
        _PermissionProviderResult.value,
        onError: (Object error, StackTrace stackTrace) =>
            _PermissionProviderResult.error(error, stackTrace),
      );
  final cancelled = admission.cancellation.then<_PermissionProviderResult>(
    (reason) => _PermissionProviderResult.error(
      _PermissionGateCancellation(reason),
      StackTrace.empty,
    ),
  );
  final winner = await Future.any<_PermissionProviderResult>(
    <Future<_PermissionProviderResult>>[providerResult, cancelled],
  );
  final error = winner.error;
  if (error is _PermissionGateCancellation) {
    return _permissionDecisionForCancellation(error.reason);
  }
  if (error is PermissionRequestTimeoutException) {
    admission.tryCancel(PermissionCancellationReason.timedOut);
    return _permissionDecisionForCancellation(
      admission.terminalReason ?? PermissionCancellationReason.timedOut,
    );
  }
  if (error != null) Error.throwWithStackTrace(error, winner.stackTrace!);
  return winner.value!;
}

Future<T> _runPermissionHandler<T>({
  required _InboundPermissionAdmission admission,
  required PermissionOptions options,
  required Future<T> Function(PermissionDecision decision) operation,
}) async {
  final decision = await _permissionProviderDecision(
    admission: admission,
    options: options,
  );
  return operation(decision);
}

T _permissionOperationCancellation<T>(
  String method,
  PermissionCancellationReason reason,
) {
  if (method == 'session/request_permission') {
    return <String, Object?>{
      'outcome': <String, Object?>{'outcome': 'cancelled'},
    } as T;
  }
  if (reason == PermissionCancellationReason.timedOut) {
    throw rpc.RpcException(-32002, 'Permission request timed out.');
  }
  if (reason == PermissionCancellationReason.promptEnded ||
      reason == PermissionCancellationReason.promptCancelled ||
      reason == PermissionCancellationReason.sessionClosed) {
    throw rpc.RpcException(-32003, 'Permission request cancelled.');
  }
  throw const AcpConnectionClosedException();
}

InboundGateTerminal<dynamic> _permissionGateTerminal(
  String method,
  PermissionCancellationReason reason,
 ) {
  if (method == 'session/request_permission') {
    return const InboundGateTerminalValue<dynamic>(<String, Object?>{
      'outcome': <String, Object?>{'outcome': 'cancelled'},
    });
  }
  if (reason == PermissionCancellationReason.timedOut) {
    return InboundGateTerminalError<dynamic>(
      rpc.RpcException(-32002, 'Permission request timed out.'),
    );
  }
  if (reason == PermissionCancellationReason.promptEnded ||
      reason == PermissionCancellationReason.promptCancelled ||
      reason == PermissionCancellationReason.sessionClosed) {
    return InboundGateTerminalError<dynamic>(
      rpc.RpcException(-32003, 'Permission request cancelled.'),
    );
  }
  return const InboundGateTerminalError<dynamic>(
    AcpConnectionClosedException(),
  );
}
```

取消分类与 provider 通知使用以下方法体；token 只通过 interface 传递，不写 metadata/log：

```dart
PermissionDecision _permissionDecisionForCancellation(
  PermissionCancellationReason reason,
) {
  switch (reason) {
    case PermissionCancellationReason.timedOut:
      throw const PermissionRequestTimeoutException();
    case PermissionCancellationReason.promptEnded:
    case PermissionCancellationReason.promptCancelled:
    case PermissionCancellationReason.sessionClosed:
      return const PermissionDecision.cancelled();
    case PermissionCancellationReason.connectionClosed:
    case PermissionCancellationReason.disposed:
      throw const AcpConnectionClosedException();
  }
}

void _notifyPermissionProviderCancellation(
  _InboundPermissionAdmission admission,
  PermissionCancellationReason reason,
) {
  if (!admission.providerStarted || admission.providerCancellationSent) {
    return;
  }
  final provider = config.permissionProvider;
  if (provider is! CancellablePermissionProvider) return;
  admission.providerCancellationSent = true;
  try {
    provider.cancelPendingPermission(
      cancellationToken: admission.cancellationToken,
      reason: reason,
    );
  } on Object {
    // Third-party cancellation is best-effort. Never expose its error, stack,
    // token or provider content, and never interrupt the admission CAS.
    _log.warning('ACP permission provider cancellation failed.');
  }
}

void _removeInboundAdmission(_InboundPermissionAdmission admission) {
  _inboundAdmissions.remove(admission);
  final owner = admission.promptOwner;
  if (owner == null) return;
  final owned = _admissionsByOwner[owner];
  owned?.remove(admission);
  if (owned != null && owned.isEmpty) _admissionsByOwner.remove(owner);
}
```

provider 尚未开始时必须直接返回：不调用第三方 callback，也不把 `providerCancellationSent` 置位；只有 `providerStarted` 为 true 的 running admission 才可能通知一次。`providerCancellationSent` 必须在调用第三方 callback 之前同步置位，保证 callback 抛错时也不会重试。`catch` 不得带 `error`、`stackTrace`、token、provider 类名或 permission 内容记录日志；它返回后 `tryCompleteLocal` 必须继续到 `tryCompleteSettled()`，保留 timeout/cancel/session-close 已获胜的固定终态。

- [ ] 20. 把 `_onReadTextFile`、`_onWriteTextFile`、`_onRequestPermission`、`_onTerminalCreate` 改为第二参数接收 `InboundAdmission`，在入口做一次 checked cast 到 `_InboundPermissionAdmission`，只消费 admission 快照并调用 `_runPermissionHandler`；不得另建 timer/token或重查当前 owner。四个外层 handler 的 `operation` callback 必须 `await` 完整 fs/request/terminal value 或 error；唯一 local-settle 路径是 Step 16 的 `runLocalOperation → tryCompleteLocal`，provider allow 不能提前结算。malformed params、缺失 handler、正常 value/error 与副作用开始后的 `promptEnded`、`promptCancelled`、`sessionClosed` 全部在这个同步首赢点竞争，并按原 reason 生成固定 mapping。

- [ ] 21. 运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart --plain-name "admitted slots preserve malformed and notification response stages"`。Expected: PASS；malformed 请求绑定带 id tracker 的真实 `responseCommitted.future`，notification 使用独立 arrival identity 与已完成 response stage，两者 reservation/local/response 三阶段各只结算一次。

- [ ] 22. 立即运行 `./tool/flutter_test_isolated.sh test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: PASS；本文件全部 16 处 admitted callback 已迁为二参形式，所有直接 peer 均安装真实 pass-through admission hook，旧 gate/correlation/batch 行为无回归。

- [ ] 23. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission deadline starts at admission for ownerless and owner scoped requests"`。Expected: PASS。

- [ ] 24. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "all permission entries settle queued and running permit races once"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "queued fs and terminal timeout or cancellation do not leak zone errors"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission cancellation keeps its reason after side effect starts"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission operation and cancellation atomically consume late value and error"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "malformed and missing admitted handlers always locally settle"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "throwing cancellable provider cannot break permission settlement"`。Expected: 六者均 PASS；其中 `queued fs and terminal timeout or cancellation do not leak zone errors` 完整跑 fs read/terminal create × timeout/cancel 四个 guarded-zone case，`zoneErrors` 最终严格等于 0；`throwing cancellable provider cannot break permission settlement` 的 timeout/prompt-cancel/session-close 三个子流程均保留固定 code/message、无 data、无 canary/zone error，且 `settled` 完成；其余覆盖 24 个 queued/running case，并明确 queued 为零 provider request/零 cancellation callback、running 才恰一次 callback；同时覆盖 fs read/write/terminal × 3 个 side-effect-started reason、operation-first/cancel-late、cancel-first/late value/error 与两条 malformed/missing local-settle 路径。running reservation 先 detach/release，迟到 provider error 被消费且不进入 zone。

- [ ] 25. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "queued permission admissions keep their original owner and generation snapshot"`。Expected: PASS。

- [ ] 26. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "bridge first and manager first timeouts classify every running permission entry once"`。Expected: PASS（8 个 bridge/manager first case 均归类 timedOut）。

- [ ] 27. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "terminal permission timeout close and dispose release pending lease before replacement"`。Expected: PASS。

- [ ] 28. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: PASS。

- [ ] 29. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: exit 0。

- [ ] 30. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 31. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: 只暂存本任务五个文件。

- [ ] 32. 运行 `git commit -m "fix: snapshot ACP permission admissions"`。Expected: commit成功，提交后 `dart analyze third_party/dart_acp` 不出现未定义符号。

### Task 7: response commit grace、batch sibling 与 blocker 撤销

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/json_rpc_peer_inbound_gate_test.dart`

本 Task 在 `test/acp/acp_request_timeout_test.dart` 显式补充异常构造所需别名，后续 `_BlockedOutcome.rpcException` 不得依赖其他测试文件的 import：

```dart
import 'package:json_rpc_2/json_rpc_2.dart' as rpc;
```

在本 Task 第一个 RED 前定义 batch driver；它组合 Task 6 的真实 harness，不创建第二个 peer/manager。`_BlockedBatchProbe` 的 gate/correlation 数值直接读取 Task 3 testing getters，cleanup 数值读取本 Task 随实现增加的只读 testing getters。

```dart
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
  final AcpSessionInputBudgetOwner? owner;
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
  Future<void>? _cleanupReaped;
  Object get cleanupWindowIdentity {
    final captured = _cleanupWindowIdentity;
    if (captured != null) return captured;
    final identity =
        base.manager.admissionCleanupWindowIdentitiesForTesting.single;
    _cleanupWindowIdentity = identity;
    _cleanupTimerCallback = base.manager
        .admissionCleanupWindowTimerCallbackForTesting(identity);
    _cleanupReaped =
        base.manager.ownerCleanupWindowReapedForTesting(identity);
    return identity;
  }
  Future<void> get cleanupReaped {
    cleanupWindowIdentity;
    return _cleanupReaped!;
  }
  bool get cleanupTimerCancelled =>
      base.manager.admissionCleanupWindowCountForTesting == 0;
  PermissionCancellationReason? get firstCancellationReason =>
      base.permissions.cancellations.isEmpty
          ? null
          : base.permissions.cancellations.first.$2;

  Future<void> finishLateSibling() async {
    if (!releaseSibling.isCompleted) releaseSibling.complete();
    await pumpEventQueue();
  }

  Future<void> commitResponse() async {
    if (!releaseSibling.isCompleted) releaseSibling.complete();
    await permission.responseCommitted.future
        .timeout(const Duration(seconds: 2));
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
  }) async => _PermissionBatchHarness._(
    await _PermissionAdmissionHarness.start(
      timeouts: AcpTimeouts(
        permission: const Duration(milliseconds: 75),
        promptCancelGrace: promptCancelGrace,
      ),
    ),
  );

  Future<_BlockedBatchProbe> _send({
    required String method,
    AcpSessionInputBudgetOwner? owner,
    PermissionCancellationReason? reason,
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
    base.channel.local.sink.add(jsonEncode(<Object?>[
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
    ]));
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
          const PermissionDecision.cancelled(),
        );
        break;
      case _BlockedOutcome.fsDenied:
      case _BlockedOutcome.terminalDenied:
        base.permissions.completeDecision(
          probe.providerIndex,
          const PermissionDecision.deny(),
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

  Future<_BlockedBatchProbe>
      sendCancelledPermissionWithBlockedSibling({
    required bool ownerScoped,
    required PermissionCancellationReason reason,
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

  Future<_BlockedBatchProbe> blockResponseCommit() async {
    final probe = await _send(method: 'session/request_permission');
    await base.permissions
        .waitForRequest(probe.providerIndex)
        .timeout(const Duration(seconds: 2));
    base.permissions.completeDecision(
      probe.providerIndex,
      const PermissionDecision.cancelled(),
    );
    await probe.permissionReservationReleased
        .timeout(const Duration(seconds: 2));
    return probe;
  }

  Future<void> dispose() => base.dispose();
}
```

- [ ] 1. 写 named RED `blocked permission batch outcomes start one response grace`，先于任何实现覆盖 ownerless 的正常 selected/cancelled、fs/terminal success/deny、`RpcException`/handler error；每个权限元素与永不返回 sibling 同批，reservation 已释放但 response 未提交。fatal unavailable 返回后还要断言 window count 为 0，并重放 fatal 前捕获的 timer callback，证明迟到回调既不二次 close 也不重建窗口。关键表驱动骨架：

```dart
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
        await batch.permissionReservationReleased
            .timeout(const Duration(seconds: 2));
        final expiredWindowIdentity = batch.cleanupWindowIdentity;
        expect(expiredWindowIdentity, isNotNull);
        expect(batch.responseCommitted, isFalse);
        expect(batch.permissionResponseCompleted, isFalse);
        expect(batch.siblingResponseCompleted, isFalse);
        expect(batch.wireResponses, isEmpty);
        await batch.peerUnavailable.future.timeout(const Duration(seconds: 2));
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
      } finally {
        await harness.dispose();
      }
    }
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "blocked permission batch outcomes start one response grace"`。Expected: FAIL；Task 6 只等待 response commit，没有 blocker timer，测试在 2 秒 watchdog 超时。

- [ ] 3. 写 named RED `ownerless and owner scoped permission batch siblings share one response grace`，让 ownerless admission deadline 与 owner-scoped `promptEnded` 分别在 blocked batch 中获胜；断言 batch 不拆分、每个 lifecycle 只有一个 grace、fatal 后 reservation/correlation/admission/window 同时归零且 cancellation 首因不被 `connectionClosed` 覆盖；重放已捕获 callback 仍保持一次 fatal：

```dart
test('ownerless and owner scoped permission batch siblings share one response grace', () async {
  for (final ownerScoped in <bool>[false, true]) {
    final harness = await _PermissionBatchHarness.start(
      promptCancelGrace: const Duration(milliseconds: 75),
    );
    try {
      final batch = await harness.sendCancelledPermissionWithBlockedSibling(
        ownerScoped: ownerScoped,
        reason: ownerScoped
            ? PermissionCancellationReason.promptEnded
            : PermissionCancellationReason.timedOut,
      );
      await batch.permissionReservationReleased
          .timeout(const Duration(seconds: 2));
      final expiredWindowIdentity = batch.cleanupWindowIdentity;
      expect(expiredWindowIdentity, isNotNull);
      expect(batch.cleanupWindowStartCount, 1);
      expect(batch.permissionResponseCompleted, isFalse);
      expect(batch.siblingResponseCompleted, isFalse);
      expect(batch.wireResponses, isEmpty);
      await batch.peerUnavailable.future.timeout(const Duration(seconds: 2));
      await batch.cleanupReaped.timeout(const Duration(seconds: 2));
      expect(batch.fatalCloseCount, 1);
      expect(batch.cleanupExpiryCallbackCount, 1);
      expect(batch.firstCancellationReason, ownerScoped
          ? PermissionCancellationReason.promptEnded
          : PermissionCancellationReason.timedOut);
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
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "ownerless and owner scoped permission batch siblings share one response grace"`。Expected: FAIL；旧实现没有 owner/ownerless response blocker identity。

- [ ] 5. 写 named RED `permission response commit revokes grace and later work gets a fresh window`，使用 harness 的真实 75 ms timer，在 A 的 deadline 前提交真实 response commit，再创建 blocker B；所有事件等待都加 2 秒 watchdog。保存 A 的旧 timer callback，只在 A 已提交并确认窗口撤销后手动调用，断言旧 callback 无效，而 B 等待自己的真实完整 grace：

```dart
test('permission response commit revokes grace and later work gets a fresh window', () async {
  final harness = await _PermissionBatchHarness.start(
    promptCancelGrace: const Duration(milliseconds: 75),
  ).timeout(const Duration(seconds: 2));
  try {
    final first = await harness
        .blockResponseCommit()
        .timeout(const Duration(seconds: 2));
    await first.reservationReleased.timeout(const Duration(seconds: 2));
    final firstIdentity = first.cleanupWindowIdentity;
    await first.commitResponse().timeout(const Duration(seconds: 2));
    expect(first.cleanupTimerCancelled, isTrue);
    final second = await harness
        .blockResponseCommit()
        .timeout(const Duration(seconds: 2));
    await second.reservationReleased.timeout(const Duration(seconds: 2));
    expect(identical(second.cleanupWindowIdentity, firstIdentity), isFalse);
    first.fireCapturedTimerCallback();
    expect(harness.fatalCloseCount, 0);
    await second.elapseOwnGrace().timeout(const Duration(seconds: 2));
    expect(harness.fatalCloseCount, 1);
  } finally {
    await harness.dispose().timeout(const Duration(seconds: 2));
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission response commit revokes grace and later work gets a fresh window"`。Expected: FAIL；旧实现没有 window identity 复核与 timer 撤销。

- [ ] 7. 在 `session_manager.dart` 增加跨 Task 7/9/10 复用的 owner cleanup window。它不引用 prompt/session-close私有类型，只保存通用 blocker identity与其真实 reaped Future，所以 Task 7 仍可独立编译。正常阶段 owner-scoped key固定为接纳时 `AcpSessionInputBudgetOwner`，ownerless 初始 key固定为 admission identity；close 开始后则由 session 级 frozen selection统一解析。一个 window只有一个绝对 deadline、一个 Timer、一个 expiry Future、一个 reaped Future与至多一个 fatal owner；更早 ownerless window被选中时允许在 map/window identity仍 current 的前提下安全绑定当前 prompt owner，但绝不更换 key、identity、deadline或 Timer：

```dart
final class _OwnerCleanupWindow {
  _OwnerCleanupWindow({
    required this.identity,
    required this.fatalOwner,
    required this.deadline,
  });

  final Object identity;
  AcpSessionInputBudgetOwner? fatalOwner;
  final DateTime deadline;
  final Map<Object, Future<void>> blockers =
      HashMap<Object, Future<void>>.identity();
  final Completer<void> _expiry = Completer<void>.sync();
  final Completer<void> _reaped = Completer<void>.sync();
  Timer? timer;
  void Function()? expireForTesting;
  bool expirySignalled = false;
  bool fatalCloseStarted = false;
  bool finished = false;

  Future<void> get expiryFuture => _expiry.future;
  Future<void> get reaped => _reaped.future;
}

final Map<Object, _OwnerCleanupWindow> _ownerCleanupWindows =
    HashMap<Object, _OwnerCleanupWindow>.identity();
final Map<String, ({Object closingOwner, Object key})>
    _frozenSessionCleanupWindowSelections =
        <String, ({Object closingOwner, Object key})>{};
int _ownerCleanupWindowStartCount = 0;
int _ownerCleanupExpiryCallbackCount = 0;

// Compatibility names keep Task 7's admission-only tests readable.
int get admissionCleanupWindowCountForTesting => _ownerCleanupWindows.length;
int get admissionCleanupWindowStartCountForTesting =>
    _ownerCleanupWindowStartCount;
int get ownerCleanupExpiryCallbackCountForTesting =>
    _ownerCleanupExpiryCallbackCount;
Set<Object> get admissionCleanupWindowIdentitiesForTesting =>
    Set<Object>.unmodifiable(
      _ownerCleanupWindows.values.map((window) => window.identity),
    );
void Function() admissionCleanupWindowTimerCallbackForTesting(
  Object identity,
) => _ownerCleanupWindows.values
    .singleWhere((window) => identical(window.identity, identity))
    .expireForTesting!;
Future<void> ownerCleanupWindowReapedForTesting(Object identity) =>
    _ownerCleanupWindows.values
        .singleWhere((window) => identical(window.identity, identity))
        .reaped;
DateTime ownerCleanupWindowDeadlineForTesting(Object identity) =>
    _ownerCleanupWindows.values
        .singleWhere((window) => identical(window.identity, identity))
        .deadline;
AcpSessionInputBudgetOwner? ownerCleanupWindowFatalOwnerForTesting(
  Object identity,
) => _ownerCleanupWindows.values
    .singleWhere((window) => identical(window.identity, identity))
    .fatalOwner;
int ownerCleanupWindowBlockerCountForTesting(Object identity) =>
    _ownerCleanupWindows.values
        .singleWhere((window) => identical(window.identity, identity))
        .blockers
        .length;
```

- [ ] 8. 实现唯一 `_getOrJoinOwnerCleanupWindow`。创建者以 `DateTime.now() + promptCancelGrace` 固定绝对 deadline并安装全 owner唯一 Timer；后加入的 admission、prompt或session close只登记新 blocker identity，既不改 deadline也不创建 Timer/`Future.delayed`/`Future.timeout`。blocker Future无论 value/error都只释放自己的 identity：

```dart
_OwnerCleanupWindow _getOrJoinOwnerCleanupWindow({
  required Object key,
  required AcpSessionInputBudgetOwner? fatalOwner,
  required Object blockerIdentity,
  required Future<void> blockerReaped,
}) {
  final existing = _ownerCleanupWindows[key];
  if (existing != null && !existing.finished) {
    if (fatalOwner != null) {
      _bindOwnerCleanupFatalOwner(key, existing, fatalOwner);
    }
    _joinOwnerCleanupBlocker(
      key,
      existing,
      blockerIdentity,
      blockerReaped,
    );
    return existing;
  }

  final identity = Object();
  final deadline = DateTime.now().add(config.timeouts.promptCancelGrace);
  final window = _OwnerCleanupWindow(
    identity: identity,
    fatalOwner: fatalOwner,
    deadline: deadline,
  );
  _ownerCleanupWindows[key] = window;
  _ownerCleanupWindowStartCount += 1;
  _joinOwnerCleanupBlocker(key, window, blockerIdentity, blockerReaped);
  void expire() => _expireOwnerCleanupWindow(key, identity);
  window.expireForTesting = expire;
  final remaining = deadline.difference(DateTime.now());
  window.timer = Timer(remaining.isNegative ? Duration.zero : remaining, expire);
  return window;
}

void _bindOwnerCleanupFatalOwner(
  Object key,
  _OwnerCleanupWindow window,
  AcpSessionInputBudgetOwner fatalOwner,
) {
  if (!identical(_ownerCleanupWindows[key], window) || window.finished) {
    throw StateError('ACP cleanup window is no longer current.');
  }
  final existing = window.fatalOwner;
  if (existing == null) {
    window.fatalOwner = fatalOwner;
    return;
  }
  if (!identical(existing, fatalOwner) ||
      existing.generation != fatalOwner.generation) {
    throw StateError('ACP cleanup window owner mismatch.');
  }
}

void _joinOwnerCleanupBlocker(
  Object key,
  _OwnerCleanupWindow window,
  Object blockerIdentity,
  Future<void> blockerReaped,
) {
  final previous = window.blockers[blockerIdentity];
  if (previous != null) {
    if (!identical(previous, blockerReaped)) {
      throw StateError('ACP cleanup blocker identity was rebound.');
    }
    return;
  }
  window.blockers[blockerIdentity] = blockerReaped;
  blockerReaped.then<void>(
    (_) => _releaseOwnerCleanupBlocker(key, window, blockerIdentity),
    onError: (Object _, StackTrace __) =>
        _releaseOwnerCleanupBlocker(key, window, blockerIdentity),
  );
}
```

- [ ] 9. admission reservation release只调用 get-or-join；response commit/peer settle用同一 `_ownerCleanupKeyForAdmission` 释放 blocker。该 resolver先读 session frozen selection，再退回 prompt owner/admission identity，保证 `_beginSessionClose` 后才释放 reservation的 ownerless admission也加入 close已选 key。最后一个 blocker结束时才取消唯一 Timer、按 window identity移除 map，并完成 `expiryFuture/reaped`；expired window在 blockers真正 reaped前保留在 map，使 expiry后才到达的 prompt/close也只能 join旧窗口：

```dart
void _startAdmissionResponseGrace(_InboundPermissionAdmission admission) {
  if (!admission.reservationReleased ||
      admission.responseFinished ||
      admission.peerClosed) {
    return;
  }
  final key = _ownerCleanupKeyForAdmission(admission);
  _getOrJoinOwnerCleanupWindow(
    key: key,
    fatalOwner: admission.promptOwner,
    blockerIdentity: admission,
    blockerReaped: admission.settled,
  );
}

Object _ownerCleanupKeyForAdmission(
  _InboundPermissionAdmission admission,
) {
  final frozen = _frozenSessionCleanupWindowSelections[admission.sessionId];
  return frozen?.key ?? admission.promptOwner ?? admission;
}

void _releaseOwnerCleanupBlocker(
  Object key,
  _OwnerCleanupWindow window,
  Object blockerIdentity,
) {
  if (!identical(_ownerCleanupWindows[key], window) || window.finished) return;
  window.blockers.remove(blockerIdentity);
  if (window.blockers.isNotEmpty) return;
  _finishOwnerCleanupWindow(key, window);
}

void _finishOwnerCleanupWindow(Object key, _OwnerCleanupWindow window) {
  if (window.finished) return;
  window.finished = true;
  window.timer?.cancel();
  if (identical(_ownerCleanupWindows[key], window)) {
    _ownerCleanupWindows.remove(key);
  }
  if (!window.expirySignalled) {
    window.expirySignalled = true;
    window._expiry.complete();
  }
  if (!window._reaped.isCompleted) window._reaped.complete();
}
```

- [ ] 10. 唯一 expiry callback先复核 key + window identity + 未完成状态；只有真实当前 callback增加计数并 complete `expiryFuture`。有 blocker时只发起一次 Task 4 fatal close，fatal cleanup identity来自 window当前已安全冻结/绑定的 `fatalOwner`；不移除 window、不自建第二个 close/reap timer。旧 callback在window完成或 donor被合并后直接返回，selected旧 callback仍命中原 identity，callback count与fatal close count都不变：

```dart
void _expireOwnerCleanupWindow(Object key, Object identity) {
  final window = _ownerCleanupWindows[key];
  if (window == null ||
      window.finished ||
      window.expirySignalled ||
      !identical(window.identity, identity)) {
    return;
  }
  _ownerCleanupExpiryCallbackCount += 1;
  window.timer?.cancel();
  window.expirySignalled = true;
  window._expiry.complete();
  if (window.blockers.isEmpty) {
    _finishOwnerCleanupWindow(key, window);
    return;
  }
  if (window.fatalCloseStarted) return;
  window.fatalCloseStarted = true;
  final owner = window.fatalOwner;
  unawaited(peer.closeForFatalTimeout(
    cleanupIdentity: owner == null
        ? null
        : AcpPromptCleanupIdentity(owner, owner.generation),
  ));
}
```

- [ ] 11. 在窗口到期路径只调用 Task 4 已定义的 `peer.closeForFatalTimeout(cleanupIdentity: ...)`；不得在 Task 7、peer prompt reap或session close新增 `_closeUnavailable`、第二个 close owner、Timer、`Future.delayed`或`Future.timeout`。Task 9/10只能把 blocker交给本窗口并 await其 `expiryFuture/reaped`。

- [ ] 12. Task 6 admission回调接到共享窗口；peer unavailable先同步终止每个 window的唯一 Timer并完成 expiry Future，再让 admission/prompt真实 reaped Future逐 identity释放 blocker。不得提前伪造 reaped或清空 map；最后一个真实 blocker结束时由 `_finishOwnerCleanupWindow`移除。迟到 callback因 `expirySignalled` 或 map identity失效而无效：

```dart
void _onAdmissionReservationReleased(_InboundPermissionAdmission admission) {
  if (admission.responseFinished || admission.peerClosed) return;
  _startAdmissionResponseGrace(admission);
}

void _onAdmissionResponseFinished(_InboundPermissionAdmission admission) {
  final key = _ownerCleanupKeyForAdmission(admission);
  final window = _ownerCleanupWindows[key];
  if (window != null) {
    _releaseOwnerCleanupBlocker(key, window, admission);
  }
}

void _markOwnerCleanupWindowsPeerUnavailable() {
  for (final entry in _ownerCleanupWindows.entries.toList(growable: false)) {
    final window = entry.value;
    window.timer?.cancel();
    if (!window.expirySignalled) {
      window.expirySignalled = true;
      window._expiry.complete();
    }
    if (window.blockers.isEmpty) {
      _finishOwnerCleanupWindow(entry.key, window);
    }
  }
}

void _handlePeerUnavailable(AcpPeerUnavailableState state) {
  _markOwnerCleanupWindowsPeerUnavailable();
  for (final admission in _inboundAdmissions.toList(growable: false)) {
    admission.markPeerClosed();
  }
  // Continue the existing provider/prompt unavailable handling. Their real
  // reaped futures release the remaining generic blocker identities.
}
```

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "blocked permission batch outcomes start one response grace"`。Expected: PASS（八种 outcome 均不拆 batch）。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "ownerless and owner scoped permission batch siblings share one response grace"`。Expected: PASS。

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission response commit revokes grace and later work gets a fresh window"`。Expected: PASS。

- [ ] 16. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/inbound_gate_test.dart`。Expected: PASS。

- [ ] 17. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: exit 0。

- [ ] 18. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 19. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`。Expected: 只暂存本任务四个文件。

- [ ] 20. 运行 `git commit -m "fix: reap ACP permission responses"`。Expected: commit成功，Task 7 提交不依赖 Task 9 prompt state machine即可编译。

### Task 8: peer epoch 副作用闸门与 late terminal handle

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`
- Verify: `test/acp/terminal_provider_test.dart`

在首个 RED 前扩展 Task 6 harness；测试文件增加 `dart:io` import。driver 通过真实 manager close/dispose 与真实 `TerminalProcessHandle` 驱动 late value/error，不读取私有 lease set；Task 8 同时增加只读 testing getters，与 Task 3 的预算 getters 一样不从 `dart_acp.dart` 导出。

```dart
enum _LateCause { close, dispose }

final class _LateTerminalHarness {
  _LateTerminalHarness._(this.base, this.events);
  final _PermissionAdmissionHarness base;
  final List<TerminalEvent> events;
  late final StreamSubscription<TerminalEvent> _eventsSubscription;
  Future<_RpcReply>? _createReply;

  static Future<_LateTerminalHarness> start({
    bool releaseThrows = false,
  }) async {
    final base = await _PermissionAdmissionHarness.start();
    base.terminals
      ..releaseThrows = releaseThrows
      ..createResult = Completer<TerminalProcessHandle>();
    final harness = _LateTerminalHarness._(base, <TerminalEvent>[]);
    harness._eventsSubscription = base.manager.terminalEvents.listen(
      harness.events.add,
    );
    return harness;
  }

  SessionManager get manager => base.manager;
  Completer<void> get createStarted => base.terminals.createStarted;
  int get releaseCalls => base.terminals.releaseCalls;
  int get registeredTerminalCount =>
      base.manager.managedTerminalCountForTesting;
  Iterable<TerminalCreated> get terminalCreatedEvents =>
      events.whereType<TerminalCreated>();
  int get pendingLeaseCount =>
      base.manager.pendingTerminalLeaseCountForTesting;
  Object? get sessionGeneration =>
      base.manager.sessionGenerationForTesting(base.sessionId);

  Future<_RpcReply> createTerminal() {
    final existing = _createReply;
    if (existing != null) return existing;
    final operation = () async {
      final probe = await base.admit('terminal/create');
      await base.permissions.waitForRequest(0);
      base.permissions.completeAllow(0);
      return await probe.response;
    }();
    _createReply = operation;
    return operation;
  }

  Future<void> invalidate(_LateCause cause) async {
    switch (cause) {
      case _LateCause.close:
        await base.peer.closeForTesting(AcpPeerUnavailableReason.explicitClose);
        break;
      case _LateCause.dispose:
        await base.manager.dispose();
        break;
    }
  }

  Future<void> completeCreateHandle() async {
    final process = await Process.start('/bin/sh', const <String>['-c', 'sleep 30']);
    base.terminals.createResult!.complete(TerminalProcessHandle(
      terminalId: 'late-terminal',
      process: process,
      outputByteLimit: defaultTerminalOutputByteLimit,
    ));
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

  Future<bool> canReserveReplacementLease() async =>
      base.manager.pendingTerminalLeaseCountForTesting == 0;

  Future<void> dispose() async {
    await _eventsSubscription.cancel();
    await base.dispose();
  }
}
```

- [ ] 1. 写 named RED `late permission decisions cannot start file or terminal providers after epoch loss`，用真实 provider completer 参数化 read/write/terminal；先等 permission provider 被调用，再让 Task 4 unavailable 首赢，最后迟到 allow。关键骨架：

```dart
test('late permission decisions cannot start file or terminal providers after epoch loss', () async {
  for (final method in <String>[
    'fs/read_text_file',
    'fs/write_text_file',
    'terminal/create',
  ]) {
    final harness = await _PermissionAdmissionHarness.start();
    try {
      final request = await harness.admit(method);
      await harness.permissions.waitForRequest(0);
      await harness.peer.closeForTesting(
        AcpPeerUnavailableReason.transportClosed,
      );
      harness.permissions.completeAllow(0);
      await request.settled.timeout(const Duration(seconds: 2));
      expect(harness.fs.readCalls, 0);
      expect(harness.fs.writeCalls, 0);
      expect(harness.terminals.createCalls, 0);
      expect(request.reservationReleaseCount, 1);
      expect(request.responseCommitCount, 1);
    } finally {
      await harness.dispose();
    }
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late permission decisions cannot start file or terminal providers after epoch loss"`。Expected: FAIL；旧 handler 在 permission `await` 后仍会进入副作用。

- [ ] 3. 写 named RED `late terminal handles release once across close dispose and release failures`，覆盖 close/dispose × release success/throw × late handle/error。每个 case 断言未登记 handle 最多 release 一次、lease 可复用且无 `TerminalCreated`：

```dart
test('late terminal handles release once across close dispose and release failures', () async {
  for (final cause in _LateCause.values) {
    for (final releaseThrows in <bool>[false, true]) {
      for (final lateError in <bool>[false, true]) {
        final harness = await _LateTerminalHarness.start(
          releaseThrows: releaseThrows,
        );
        try {
          final create = harness.createTerminal();
          await harness.createStarted.future;
          await harness.invalidate(cause);
          if (lateError) {
            harness.completeCreateError(StateError('LATE-CREATE-CANARY'));
          } else {
            await harness.completeCreateHandle();
          }
          await expectLater(create, throwsA(anything));
          expect(harness.releaseCalls, lateError ? 0 : 1);
          expect(harness.terminalCreatedEvents, isEmpty);
          expect(harness.pendingLeaseCount, 0);
          expect(await harness.canReserveReplacementLease(), isTrue);
        } finally {
          await harness.dispose();
        }
      }
    }
  }
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late terminal handles release once across close dispose and release failures"`。Expected: FAIL；旧路径可能登记 late handle 或重复释放 lease。

- [ ] 5. 写 named RED `late terminal handle cannot register into a replacement session generation`；generation A 的 `provider.create` 已启动后，走真实 `closeSession → resumeSession` 重建同 sessionId 为 generation B，再返回 A handle；不得直接替换 generation map：

```dart
test('late terminal handle cannot register into a replacement session generation', () async {
  final harness = await _LateTerminalHarness.start();
  try {
    final generationA = harness.sessionGeneration;
    final createA = harness.createTerminal();
    await harness.createStarted.future;
    await harness.closeAndReopenSameSession();
    final generationB = harness.sessionGeneration;
    expect(identical(generationA, generationB), isFalse);
    await harness.completeCreateHandle();
    await expectLater(createA, throwsA(isA<AcpConnectionClosedException>()));
    expect(harness.releaseCalls, 1);
    expect(harness.registeredTerminalCount, 0);
    expect(await harness.canReserveReplacementLease(), isTrue);
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late terminal handle cannot register into a replacement session generation"`。Expected: FAIL；旧实现只按 sessionId 判断。

- [ ] 7. 实现统一 freshness guard，并在 read/write/request_permission/terminal 每个 `await` 后及下一副作用前调用：

```dart
bool _isAdmissionCurrent(_InboundPermissionAdmission admission) {
  final sessionId = admission.sessionId;
  final generation = admission.sessionGeneration;
  return !_disposed &&
      admission.peerEpoch.active &&
      sessionId != null &&
      generation != null &&
      generation.active &&
      identical(_sessionGenerations[sessionId], generation) &&
      !_isSessionClosing(sessionId);
}
void _requireAdmissionCurrent(_InboundPermissionAdmission admission) {
  if (!_isAdmissionCurrent(admission)) {
    throw const AcpConnectionClosedException();
  }
}

int get pendingTerminalLeaseCountForTesting => _pendingTerminalLeases.length;
int get managedTerminalCountForTesting => _terminals.length;
Object? sessionGenerationForTesting(String sessionId) =>
    _sessionGenerations[sessionId];
```

- [ ] 8. 抽取未登记 handle 一次性清理；同步缓存 operation 保证 close/dispose/retry 只能调用一次真实 `provider.release`：

```dart
final class _UnregisteredTerminalRelease {
  Future<void>? operation;
}

Future<void> _releaseUnregisteredTerminalHandleOnce({
  required TerminalProvider provider,
  required TerminalProcessHandle handle,
  required _UnregisteredTerminalRelease guard,
}) {
  final existing = guard.operation;
  if (existing != null) return existing;
  final operation = Future<void>.sync(() => provider.release(handle)).catchError(
    (Object _) {
      _log.warning('terminal unregistered handle release failed');
    },
  );
  guard.operation = operation;
  return operation;
}
```

- [ ] 9. 重排 terminal create 检查点：snapshot → reserve lease → permission → freshness → jail resolve/check → freshness → markCreating → `provider.create` → freshness → serialized registration → active/index/event；未登记时外层 `finally` 总调用现有 `lease.release()` 一次。

- [ ] 10. 给 `provider.create` 的 Future 立即安装以下统一 value/error consumer。`invalidated` 先赢时，consumer 继续持有原 Future：late error 变成数据后丢弃，late handle 调一次 `_releaseUnregisteredTerminalHandleOnce`；只有 create result 先赢且 freshness 仍成立才能进入 serialized registration。

```dart
final class _TerminalCreateResult {
  const _TerminalCreateResult.handle(this.handle)
    : error = null,
      stackTrace = null;
  const _TerminalCreateResult.error(this.error, this.stackTrace)
    : handle = null;
  final TerminalProcessHandle? handle;
  final Object? error;
  final StackTrace? stackTrace;
}

Future<TerminalProcessHandle> _createTerminalWithLateConsumer({
  required _InboundPermissionAdmission admission,
  required TerminalProvider provider,
  required Future<TerminalProcessHandle> createFuture,
}) async {
  final release = _UnregisteredTerminalRelease();
  final observed = createFuture.then<_TerminalCreateResult>(
    _TerminalCreateResult.handle,
    onError: (Object error, StackTrace stackTrace) =>
        _TerminalCreateResult.error(error, stackTrace),
  );
  final invalidated = admission.cancellation.then<_TerminalCreateResult>(
    (_) => _TerminalCreateResult.error(
      const AcpConnectionClosedException(),
      StackTrace.empty,
    ),
  );
  final winner = await Future.any<_TerminalCreateResult>(
    <Future<_TerminalCreateResult>>[observed, invalidated],
  );
  if (winner.error is AcpConnectionClosedException) {
    unawaited(observed.then<void>((late) async {
      final handle = late.handle;
      if (handle != null) {
        await _releaseUnregisteredTerminalHandleOnce(
          provider: provider,
          handle: handle,
          guard: release,
        );
      }
    }));
    throw const AcpConnectionClosedException();
  }
  if (winner.error case final error?) {
    Error.throwWithStackTrace(error, winner.stackTrace!);
  }
  final handle = winner.handle!;
  if (!_isAdmissionCurrent(admission)) {
    await _releaseUnregisteredTerminalHandleOnce(
      provider: provider,
      handle: handle,
      guard: release,
    );
    throw const AcpConnectionClosedException();
  }
  return handle;
}
```

- [ ] 11. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late permission decisions cannot start file or terminal providers after epoch loss"`。Expected: PASS。

- [ ] 12. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late terminal handles release once across close dispose and release failures"`。Expected: PASS。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late terminal handle cannot register into a replacement session generation"`。Expected: PASS。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart test/acp/terminal_provider_test.dart`。Expected: PASS。

- [ ] 15. 运行 `dart format third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: exit 0。

- [ ] 16. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 17. 运行 `git add third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: 只暂存本任务三个文件。

- [ ] 18. 运行 `git commit -m "fix: reject late ACP permission side effects"`。Expected: commit成功；`test/acp/terminal_provider_test.dart` 只验证、不暂存。

### Task 9: Owner-bound Prompt 核心与共享 barrier

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

Task 6 已在生产 `session_manager.dart` 首次使用 identity collection 前加入 `dart:collection`；本 Task 只确认该文件保留这一条 import，不得重复添加。`meta` 仍由本 Task 在各自生产 library 直接导入，禁止依赖测试文件或其他 library 的传递 import：

```dart
// third_party/dart_acp/lib/src/session/session_manager.dart
// Task 6 已存在；这里只保留单一 import。
import 'dart:collection';

import 'package:meta/meta.dart';

// third_party/dart_acp/lib/src/acp_client.dart
import 'package:meta/meta.dart';
```

本 Task 新增的 package-visible 测试 envelope、testing getters 以及 `AcpClient.start` 的 before/after testing callback 声明均加 `@visibleForTesting`。Task 11 若在 wrapper library 新增或标注对应 testing wrapper，必须在 Task 11 自己的文件列表和改动中加入其所需 `package:meta/meta.dart`（及该 wrapper 直接使用的其他 imports），不能依赖本 Task 的 library import，也不提前纳入本 Task 的暂存范围。

本 Task 在定义只读 snapshot 的同一步，把 Task 6 的内部 import 更新为最终形式，明确测试类型来源：

```dart
import 'package:dart_acp/src/session/session_manager.dart'
    show PromptLifecycleSnapshot, SessionManager;
```

在首个 RED 前定义以下 driver。常规 prompt/permission/close 继续组合 Task 6 的同一个 `StreamChannelController<String> → JsonRpcPeer → SessionManager`；late unavailable replay 专用 fixture 则按下文改走 `AcpClient.start → transport/client/peer/manager` 的真实组装顺序。`_PromptManagerDriver` 只记录测试可见的 active owner，不替代生产状态机。Task 7 cleanup-window testing getters 继续只用于观察，不参与驱动结果。

同一步让 `JsonRpcPeer` 自己始终使用真实、默认透明的 `_FailNextCancelSink` 包装原 channel sink；这样 Task 6 direct peer harness 与 Task 11 改成 `AcpClient.start` 后仍复用同一注入点。失败开关只让下一条实际编码出的 `session/cancel` 在 `StreamSink.add` 抛错；不得直接 complete `notificationSubmitted`、`cleanup.reaped` 或任何 production Completer：

```dart
final class _FailNextCancelSink implements StreamSink<String> {
  _FailNextCancelSink(this.delegate);

  final StreamSink<String> delegate;
  bool _failNextCancel = false;

  void failNextCancelSubmission() {
    if (_failNextCancel) {
      throw StateError('A cancel submission failure is already armed.');
    }
    _failNextCancel = true;
  }

  @override
  Future<void> get done => delegate.done;

  @override
  void add(String event) {
    if (_failNextCancel) {
      final decoded = jsonDecode(event);
      if (decoded is Map && decoded['method'] == 'session/cancel') {
        _failNextCancel = false;
        throw StateError('fixed session/cancel submission failure');
      }
    }
    delegate.add(event);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      delegate.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<String> stream) => delegate.addStream(stream);

  @override
  Future<void> close() => delegate.close();
}

// `JsonRpcPeer` constructor body 中替换原 `_JsonEncodingSink(channel.sink)`；
// gate、listener 与其余构造顺序不变。
_outboundSink = _FailNextCancelSink(channel.sink);
_decodedSink = _JsonEncodingSink(_outboundSink);

late final _FailNextCancelSink _outboundSink;

@visibleForTesting
void failNextCancelSubmissionForTesting() =>
    _outboundSink.failNextCancelSubmission();

// `_PromptLifecycleHarness` 只转发到同一个 production peer 的真实 sink。
void failNextCancelSubmission() =>
    peer.failNextCancelSubmissionForTesting();
```

Task 9 的 harness 读取 active owner、prompt result、winner barrier、right barrier 时，必须在本 Task 直接调用 `base.manager.activePromptOwnerForTesting`、`base.manager.promptResultForTesting`、`base.manager.promptWinnerRecordedForTesting`、`base.manager.promptRightRecordedForTesting`。不得依赖 Task 10 才出现的四个 `base` 转发方法；Task 10 若为自身 driver 保留同名转发，只能服务 Task 10 之后的用例。

```dart
enum _PromptRaceTerminal { response, remoteError, deadline, userCancel }

final class _PromptManagerDriver {
  _PromptManagerDriver(this.core);
  final SessionManager core;
  AcpSessionInputBudgetOwner? activeOwner;

  AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) =>
      activeOwner = core.beginPromptTurn(sessionId);
  void endPromptTurn(AcpSessionInputBudgetOwner owner) =>
      core.endPromptTurn(owner);
  Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner) =>
      core.cancelPromptTurn(owner);
  Future<void> closeSession({required String sessionId}) =>
      core.closeSession(sessionId: sessionId);
  Future<Map<String, dynamic>> sendPromptRequest({
    required AcpSessionInputBudgetOwner owner,
    required List<Map<String, dynamic>> content,
  }) => core.sendPromptRequest(owner: owner, content: content);
  Stream<AcpUpdate> prompt({
    required String sessionId,
    required List<Map<String, dynamic>> content,
  }) => core.prompt(sessionId: sessionId, content: content);
}

final class _HarnessOwnerBoundClient {
  _HarnessOwnerBoundClient(this.harness);
  final _PromptLifecycleHarness harness;
  Future<Map<String, dynamic>> sendPromptRequest({
    required AcpSessionInputBudgetOwner owner,
    required List<Map<String, dynamic>> content,
  }) {
    harness.ownerBoundProxyCalls += 1;
    return harness.manager.sendPromptRequest(owner: owner, content: content);
  }
}

final class _PromptPublicTransport implements AcpTransport {
  final StreamChannelController<String> controller =
      StreamChannelController<String>();
  @override StreamChannel<String> get channel => controller.foreign;
  @override Future<void> start() async {}
  @override Future<void> stop() => controller.local.sink.close();
}

final class _PromptPublicClientFixture {
  _PromptPublicClientFixture._(this.client, this.transport, this.subscription);
  final AcpClient client;
  final _PromptPublicTransport transport;
  final StreamSubscription<String> subscription;
  final Completer<void> promptSeen = Completer<void>();
  Object? promptId;
  int promptWireCount = 0;

  static Future<_PromptPublicClientFixture> start() async {
    final transport = _PromptPublicTransport();
    late final _PromptPublicClientFixture fixture;
    final client = await AcpClient.start(
      config: AcpConfig(timeouts: const AcpTimeouts()),
      transport: transport,
    );
    final subscription = transport.controller.local.stream.listen((line) {
      final message = Map<String, dynamic>.from(jsonDecode(line) as Map);
      final method = message['method'];
      if (method == 'session/resume' || method == 'session/close') {
        transport.controller.local.sink.add(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        }));
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

  Future<AcpSessionInputBudgetOwner> createStaleOwner() async {
    final stale = client.beginPromptTurn('public-prompt-session');
    client.endPromptTurn(stale);
    await client.closeSession(sessionId: 'public-prompt-session');
    await client.resumeSession(
      sessionId: 'public-prompt-session',
      workspaceRoot: '/tmp',
    );
    return stale;
  }

  void respondSuccess() {
    transport.controller.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': promptId,
      'result': <String, dynamic>{'stopReason': 'end_turn'},
    }));
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
  });
  final _PromptLifecycleHarness harness;
  final AcpSessionInputBudgetOwner owner;
  final Future<Map<String, dynamic>> result;
  final Completer<void> promptSeen;
  final Completer<void> admissionStarted = Completer<void>();
  final Completer<void> admissionReservationReleased = Completer<void>();
  _PermissionRequestProbe? admission;
  Completer<void>? responseCommitBlocker;
  PromptLifecycleSnapshot get lifecycle =>
      harness.base.manager.promptLifecycleSnapshotForTesting(owner);
  JsonRpcPromptTerminalKind? get terminalKind => lifecycle.winner?.kind;
  DateTime? get promptCleanupDeadline => lifecycle.cleanupDeadline;
  DateTime? get admissionCleanupDeadline =>
      lifecycle.admissionCleanupDeadline;
  AcpPromptCleanupIdentity? get unavailableCleanupIdentity =>
      lifecycle.cleanupIdentity;
  bool get terminalRecorded =>
      lifecycle.winner != null || lifecycle.cancellationWinner != null;
  int get reapFutureIdentityCount => lifecycle.cleanupStarted ? 1 : 0;

  PermissionCancellationReason? get permissionReason =>
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
  final AcpClient client;
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
  )
      : manager = _PromptManagerDriver(base.manager) {
    client = _HarnessOwnerBoundClient(this);
  }

  static Future<_PromptLifecycleHarness> start({
    Duration prompt = const Duration(seconds: 2),
    Duration grace = const Duration(milliseconds: 100),
    int maxOrdinaryConcurrentHandlers = 1,
  }) async {
    final base = await _PermissionAdmissionHarness.start(
      timeouts: AcpTimeouts(
        prompt: prompt,
        promptCancelGrace: grace,
      ),
      maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    );
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
    harness._foreignOwner =
        foreign.manager.beginPromptTurn(foreign.sessionId);
    return harness;
  }

  // `maxOrdinaryConcurrentHandlers` 只向下透传给承载本测试业务的
  // `base`；foreign owner 只做 identity 错配校验，继续使用默认 1。
  // Task 10 只在需要 ownerless + owner-scoped 并行 blocker 的 fixture
  // 传 2，并由 Task 6 harness 公式得到 total 4。

  static Future<_UnavailablePromptHarness> startWithUnavailablePeer() async {
    final transport = _PromptPublicTransport();
    late JsonRpcPeer closedPeer;
    late SessionManager replayedManager;
    final client = await AcpClient.start(
      config: AcpConfig(timeouts: const AcpTimeouts()),
      transport: transport,
      beforeSessionManagerForTesting: (peer) {
        closedPeer = peer;
        // `_becomeUnavailable` 同步安装 explicitClose state；不等待底层
        // close，随后 SessionManager 构造器注册 listener 并收到 late replay。
        unawaited(peer.closeForTesting(
          AcpPeerUnavailableReason.explicitClose,
        ));
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
  final AcpSessionInputBudgetOwner publicStaleOwner;
  late final _HarnessOwnerBoundClient client;
  final _PromptManagerDriver manager;
  JsonRpcPeer get peer => base.peer;
  String get sessionId => base.sessionId;
  final Completer<void> promptSeen = Completer<void>();
  late final AcpSessionInputBudgetOwner _foreignOwner;
  StreamSubscription<Map<String, dynamic>>? _wire;
  Object? _promptRequestId;
  _PromptOperationProbe? _current;
  int promptWireCount = 0;
  int cancelWireCount = 0;
  int ownerBoundProxyCalls = 0;
  int rawPromptCalls = 0;
  bool _promptResponded = false;

  AcpSessionInputBudgetOwner get activeOwner => manager.activeOwner!;
  AcpSessionInputBudgetOwner foreignManagerOwner() => _foreignOwner;
  AcpClient get publicClient => publicFixture.client;
  int get publicPromptWireCount => publicFixture.promptWireCount;
  Future<void> get publicPromptSeen => publicFixture.promptSeen.future;
  void respondPublicPromptSuccess() => publicFixture.respondSuccess();

  void _listen() {
    _wire = base.wireRequests.stream.listen((message) {
      switch (message['method']) {
        case 'session/prompt':
          promptWireCount += 1;
          _promptRequestId = message['id'];
          final activeOwner =
              base.manager.activePromptOwnerForTesting(sessionId);
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

  Future<Map<String, dynamic>> startTypedPromptWithOwner(
    AcpSessionInputBudgetOwner owner,
  ) => client.sendPromptRequest(
    owner: owner,
    content: const <Map<String, dynamic>>[],
  );

  Future<_PromptOperationProbe> _startPrompt() async {
    final owner = manager.beginPromptTurn(sessionId);
    final seen = Completer<void>();
    late final _PromptOperationProbe operation;
    final result = manager.sendPromptRequest(
      owner: owner,
      content: const <Map<String, dynamic>>[],
    );
    operation = _PromptOperationProbe(
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
    base.channel.local.sink.add(jsonEncode(<Object?>[
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
    ]));
    await admission.admissionSeen.future;
    operation.admission = admission;
    admission.reservationReleased.future.then<void>((_) {
      if (!operation.admissionReservationReleased.isCompleted) {
        operation.admissionReservationReleased.complete();
      }
    });
    if (running) {
      await base.permissions.waitForRequest(providerIndex);
    }
    if (!operation.admissionStarted.isCompleted) {
      operation.admissionStarted.complete();
    }
    return admission;
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
    if (_promptResponded || _promptRequestId == null) return;
    _promptResponded = true;
    base.channel.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': _promptRequestId,
      'result': <String, dynamic>{'stopReason': stopReason},
    }));
  }

  void respondPromptError({required int code, required String message}) {
    if (_promptResponded || _promptRequestId == null) return;
    _promptResponded = true;
    base.channel.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': _promptRequestId,
      'error': <String, dynamic>{'code': code, 'message': message},
    }));
  }

  void respondPromptMalformed() {
    if (_promptResponded || _promptRequestId == null) return;
    _promptResponded = true;
    base.channel.local.sink.add(jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0',
      'id': _promptRequestId,
      'result': <Object?>['not-an-object'],
    }));
  }

  Future<void> recordPromptWinner(
    _PromptOperationProbe operation,
    _PromptRaceTerminal terminal,
    {required bool expectAccepted},
  ) async {
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
    await operation.result.then<void>((_) {}, onError: (_, __) {});
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
    final received = <AcpUpdate>[];
    final subscription = base.manager.sessionUpdates(sessionId).listen(
      received.add,
    );
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
```

为上述 late-replay fixture，`AcpClient.start` 增加仅包内测试使用的两个可选同步回调：`void Function(JsonRpcPeer)? beforeSessionManagerForTesting` 与 `void Function(JsonRpcPeer, SessionManager)? afterSessionManagerForTesting`。顺序固定为 `transport.start → JsonRpcPeer 构造 → before → SessionManager 构造 → after → AcpClient 构造`。before 返回前 unavailable state 已同步安装，manager 构造时的 listener replay 因而走生产注册路径；after 只把 client 即将持有的同一 peer/manager 交给 fixture。fixture 禁止再构造第二套 channel/peer/manager，也禁止访问 `_PermissionAdmissionHarness._`、`_onWire`、`peerForTesting/sessionManagerForTesting` 或私有字段。

- [ ] 1. 写 named RED `typed prompt uses the public owner bound proxy and rejects stale owners`，覆盖 `AcpClient.sendPromptRequest` 的公开 owner/content 签名、typed `SessionManager.prompt` 只经该 owner-bound 路径，以及 foreign manager、stale generation、session mismatch、settling owner、同 session 第二 prompt 在 wire 前拒绝：

```dart
test('typed prompt uses the public owner bound proxy and rejects stale owners', () async {
  final harness = await _PromptLifecycleHarness.start();
  try {
    await harness.assertOldSessionUpdateIsDropped();
    final owner =
        harness.publicClient.beginPromptTurn('public-prompt-session');
    final typed = harness.publicClient.sendPromptRequest(
      owner: owner,
      content: const <Map<String, dynamic>>[],
    );
    await harness.publicPromptSeen;
    expect(harness.publicPromptWireCount, 1);
    for (final rejected in <AcpSessionInputBudgetOwner>[
      harness.foreignManagerOwner(),
      harness.publicStaleOwner,
      owner,
    ]) {
      final before = harness.publicPromptWireCount;
      await expectLater(
        harness.publicClient.sendPromptRequest(
          owner: rejected,
          content: const <Map<String, dynamic>>[],
        ),
        throwsStateError,
      );
      expect(harness.publicPromptWireCount, before);
    }
    harness.respondPublicPromptSuccess();
    await typed;
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt uses the public owner bound proxy and rejects stale owners"`。Expected: FAIL；`AcpClient` 尚无公开 owner-bound 代理，typed 仍直达旧 peer prompt。

- [ ] 3. 写 named RED `prompt terminal waits for admission response commit before replacement`；prompt response 已到、permission reservation 已释放但 response commit blocker 未解除时，新 owner 固定失败，commit 或 peer-close 后成功：

```dart
test('prompt terminal waits for admission response commit before replacement', () async {
  final harness = await _PromptLifecycleHarness.start();
  try {
    final first = await harness.startPromptWithBlockedAdmissionCommit();
    harness.respondPromptSuccess();
    await first.admissionReservationReleased.future;
    expect(
      () => harness.manager.beginPromptTurn(harness.sessionId),
      throwsA(isA<StateError>().having(
        (error) => error.message,
        'message',
        'ACP prompt is already active or settling.',
      )),
    );
    await first.commitAdmissionResponse();
    await first.promptResult;
    final replacement = harness.manager.beginPromptTurn(harness.sessionId);
    harness.manager.endPromptTurn(replacement);
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt terminal waits for admission response commit before replacement"`。Expected: FAIL；旧 `endPromptTurn` 在 response commit 前移除 owner。

- [ ] 5. 写 named RED `prompt timeout shares one cancel and one cleanup grace with admissions`；prompt request 与 owner admission 都不结算，75 ms deadline 获胜后断言先缓存 timeout winner、权限首因 `promptEnded`、一次 cancel、一个最早 cleanup deadline 与同 owner cleanup identity：

```dart
test('prompt timeout shares one cancel and one cleanup grace with admissions', () async {
  final harness = await _PromptLifecycleHarness.start(
    prompt: const Duration(milliseconds: 75),
    grace: const Duration(milliseconds: 100),
  );
  try {
    final operation = await harness.startPromptWithRunningAdmission();
    await operation.promptSeen.future;
    await operation.admissionStarted.future;
    await expectLater(
      operation.result,
      throwsA(isA<AcpPromptTimeoutException>()),
    );
    expect(operation.terminalKind, JsonRpcPromptTerminalKind.timedOut);
    expect(operation.permissionReason, PermissionCancellationReason.promptEnded);
    expect(operation.cancelWireCount, 1);
    expect(operation.cleanupWindowStartCount, 1);
    expect(operation.promptCleanupDeadline, operation.admissionCleanupDeadline);
    expect(operation.unavailableCleanupIdentity?.ownerToken, same(operation.owner));
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt timeout shares one cancel and one cleanup grace with admissions"`。Expected: FAIL；缺统一 prompt deadline、cancel-once 与共享 grace。

- [ ] 7. 写 named RED `prompt cancellation keeps replacement settling and stale cancel is isolated`；queued/running permission 各跑一次，用户取消立即返回但后台 reap 保留 barrier；queued provider 从未启动，因此 cancellation callback reason 保持 null，running provider 才收到 `promptCancelled`。旧 response/permission 全结算后 replacement 成功，旧 owner 再 cancel 不影响新 owner：

```dart
test('prompt cancellation keeps replacement settling and stale cancel is isolated', () async {
  for (final running in <bool>[false, true]) {
    final harness = await _PromptLifecycleHarness.start();
    try {
      final first = await harness.startPromptWithAdmission(running: running);
      await harness.manager.cancelPromptTurn(first.owner);
      expect(first.cancelWireCount, 1);
      expect(
        first.permissionReason,
        running ? PermissionCancellationReason.promptCancelled : null,
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
      final replacement = harness.manager.beginPromptTurn(harness.sessionId);
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
});
```

- [ ] 8. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt cancellation keeps replacement settling and stale cancel is isolated"`。Expected: FAIL；旧 cancel 过早释放 owner 或按 sessionId 误取消 replacement。

- [ ] 9. 写 named RED `failed prompt cancel submission still reaps request and admissions before replacement`。第一子流程让真实 sink 拒绝 `session/cancel` 后在 grace 内释放原 prompt/admission，必须先观察 cancel API 的固定发送错误、replacement 在真实 reap 前固定拒绝，随后原 request 与 admission 全部 reaped 后 replacement 才能创建。第二子流程保持两者不结算，必须仍由 Task 7 唯一窗口触发 fatal；notification error 不得提前移除 peer operation 或 cleanup blocker：

```dart
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

      await graceful.finishPromptRace(operation).timeout(
        const Duration(seconds: 2),
      );
      await operation.admission!.settled.timeout(const Duration(seconds: 2));
      await operation.promptResult.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ).timeout(const Duration(seconds: 2));
      expect(graceful.peer.promptOperationCountForTesting, 0);
      final replacement = graceful.manager.beginPromptTurn(graceful.sessionId);
      expect(identical(replacement, operation.owner), isFalse);
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

      final state = await unavailable.future.timeout(const Duration(seconds: 2));
      expect(state.reason, AcpPeerUnavailableReason.fatalTimeout);
      await operation.admission!.settled.timeout(const Duration(seconds: 2));
      await operation.promptResult.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      ).timeout(const Duration(seconds: 2));
      expect(fatal.peer.promptOperationCountForTesting, 0);
      expect(fatal.base.manager.admissionCleanupWindowCountForTesting, 0);
    } finally {
      await fatal.dispose();
    }
  },
);
```

- [ ] 10. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "failed prompt cancel submission still reaps request and admissions before replacement"`。Expected: FAIL；旧 cleanup 在 notification error 后直接执行 removal，第一子流程的原 caller 永不完成，第二子流程也不会保留 blocker到 fatal。

- [ ] 11. 写 named RED `session close shares prompt cancel and reap across response deadline and user cancel`；参数化 `response`、`remoteError`、`deadline`、`userCancel` 与 close-first/terminal-first。terminal-first 前三类先由生产 snapshot 观察 winner+right，userCancel 只有 `promptCancelled`；close-first 四类都保持 `sessionClosed`、无 winner/right，manager stale terminal hook 返回 rejected settlement 而不抛。所有 case 只允许一个 cancel、一个最早 grace、一个 reap Future：

```dart
test('session close shares prompt cancel and reap across response deadline and user cancel', () async {
  for (final terminal in _PromptRaceTerminal.values) {
    for (final closeFirst in <bool>[false, true]) {
      final harness = await _PromptLifecycleHarness.start();
      try {
        final operation = await harness.startPromptWithRunningAdmission();
        late final Future<void> close;
        if (closeFirst) {
          close = harness.manager.closeSession(sessionId: harness.sessionId);
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
          close = harness.manager.closeSession(sessionId: harness.sessionId);
        }
        await harness.finishPromptRace(operation);
        await close.catchError((Object _) {});
        expect(operation.cancelWireCount, 1);
        expect(operation.cleanupWindowStartCount, 1);
        expect(operation.reapFutureIdentityCount, 1);
        if (closeFirst) {
          expect(operation.permissionReason, PermissionCancellationReason.sessionClosed);
          expect(operation.lifecycle.winner, isNull);
          expect(operation.lifecycle.hasDeliveryRight, isFalse);
        } else if (terminal == _PromptRaceTerminal.userCancel) {
          expect(
            operation.lifecycle.cancellationWinner,
            PermissionCancellationReason.promptCancelled,
          );
          expect(operation.lifecycle.hasDeliveryRight, isFalse);
        } else {
          expect(operation.lifecycle.winner, isNotNull);
          expect(operation.lifecycle.hasDeliveryRight, isTrue);
          expect(
            operation.lifecycle.winner!.kind,
            switch (terminal) {
              _PromptRaceTerminal.response =>
                JsonRpcPromptTerminalKind.response,
              _PromptRaceTerminal.remoteError =>
                JsonRpcPromptTerminalKind.remoteError,
              _PromptRaceTerminal.deadline =>
                JsonRpcPromptTerminalKind.timedOut,
              _PromptRaceTerminal.userCancel => throw StateError('unreachable'),
            },
          );
        }
      } finally {
        await harness.dispose();
      }
    }
  }
});
```

- [ ] 12. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close shares prompt cancel and reap across response deadline and user cancel"`。Expected: FAIL；旧 close、deadline 与 cancel 各自发送/等待。

- [ ] 13. 写 named RED `late unavailable replay invalidates prompt epoch before dispatch`：先让 peer unavailable 再构造 manager，验证 listener 同步 replay；另对 active prompt 让普通 unavailable 同步完成 caller connection-closed并移除双索引，再分别注入迟到 value/error/malformed，三者只消费且 `then` callback 自身不向 zone 泄漏。最后用 direct peer 验证 winner+cleanup 已登记后，other-owner fatal 仍 connection-closed，而同 owner/generation cleanup fatal 保留 operation/caller并在 cleanup 后投缓存 response：

```dart
test('late unavailable replay invalidates prompt epoch before dispatch', () async {
  final harness = await _PromptLifecycleHarness.startWithUnavailablePeer();
  try {
    expect(harness.peer.isAvailable, isFalse);
    expect(() => harness.manager.beginPromptTurn(harness.sessionId), throwsStateError);
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
        throwsA(isA<AcpConnectionClosedException>()),
      );
      await runZonedGuarded(() async {
        switch (late) {
          case 'value':
            active.respondPromptSuccess();
            break;
          case 'error':
            active.respondPromptError(code: -32000, message: 'late error');
            break;
          case 'malformed':
            active.respondPromptMalformed();
            break;
        }
        await pumpEventQueue();
      }, (Object error, StackTrace stackTrace) {
        zoneErrors.add(error);
      });
      expect(zoneErrors, isEmpty);
      expect(
        active.base.manager.promptLifecycleIsCurrentForTesting(operation.owner),
        isFalse,
      );
      expect(
        active.base.manager.promptHasDeliveryRightForTesting(operation.owner),
        isFalse,
      );
    } finally {
      await active.dispose();
    }
  }

  for (final matchingOwner in <bool>[false, true]) {
    final direct = _RequestHarness(const acp.AcpTimeouts(
      promptCancelGrace: Duration(milliseconds: 75),
    ));
    const owner = _TestPromptOwner('direct-raw-session', 17);
    final admissionBarrier = Completer<void>();
    final terminalHook = Completer<void>.sync();
    final unavailable = Completer<AcpPeerUnavailableState>.sync();
    direct.peer.addUnavailableListener((state) {
      if (!unavailable.isCompleted) unavailable.complete(state);
    });
    try {
      final result = direct.peer.sendPromptRequest(
        owner: owner,
        content: const <Map<String, dynamic>>[],
        onTerminal: (_, __) {
          if (!terminalHook.isCompleted) terminalHook.complete();
          return JsonRpcPromptSettlement(admissionBarrier.future);
        },
      );
      final request = await direct.takeRequest();
      direct.respond(
        request['id'],
        <String, dynamic>{'stopReason': 'end_turn'},
      );
      await terminalHook.future;
      if (!matchingOwner) {
        await direct.peer.closeForFatalTimeout(
          cleanupIdentity: AcpPromptCleanupIdentity(Object(), 17),
        );
        await expectLater(
          result,
          throwsA(isA<AcpConnectionClosedException>()),
        );
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
        expect(
          await result,
          <String, dynamic>{'stopReason': 'end_turn'},
        );
      }
    } finally {
      await direct.dispose();
    }
  }
});
```

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late unavailable replay invalidates prompt epoch before dispatch"`。Expected: FAIL；manager 尚未消费 Task 4 同步回放，普通 unavailable 未同步移除 pending operation，且 peer 尚未区分 same-owner cleanup fatal 与其他 close。

- [ ] 15. 在 `peer.dart` 增加 prompt 中立协议与 first-wins operation；这些类型不得回填到 Task 3 correlation 提交。所有状态方法必须有方法体：

```dart
enum JsonRpcPromptTerminalKind { response, remoteError, timedOut }

final class JsonRpcPromptTerminalWinner {
  const JsonRpcPromptTerminalWinner({
    required this.kind,
    this.response,
    this.error,
    this.stackTrace,
  });
  final JsonRpcPromptTerminalKind kind;
  final Map<String, dynamic>? response;
  final Object? error;
  final StackTrace? stackTrace;
}

final class JsonRpcPromptSettlement {
  const JsonRpcPromptSettlement(
    this.admissionsSettled,
    {this.accepted = true},
  });
  factory JsonRpcPromptSettlement.rejected() => JsonRpcPromptSettlement(
    Future<void>.value(),
    accepted: false,
  );
  final Future<void> admissionsSettled;
  final bool accepted;
}

final class JsonRpcPromptCleanup {
  const JsonRpcPromptCleanup({
    required this.notificationSubmitted,
    required this.reaped,
  });
  final Future<void> notificationSubmitted;
  final Future<void> reaped;
}

typedef JsonRpcPromptTerminalHandler = JsonRpcPromptSettlement Function(
  JsonRpcPromptOwner owner,
  JsonRpcPromptTerminalWinner winner,
);

Future<Map<String, dynamic>> sendPromptRequest({
  required JsonRpcPromptOwner owner,
  required List<Map<String, dynamic>> content,
  required JsonRpcPromptTerminalHandler onTerminal,
});
JsonRpcPromptCleanup cancelPromptRequest({
  required JsonRpcPromptOwner owner,
  required Future<void> admissionsSettled,
  bool sendCancel = true,
});

final class _JsonRpcPromptOperation {
  _JsonRpcPromptOperation({
    required this.owner,
    required this.request,
  });
  final JsonRpcPromptOwner owner;
  final Future<Map<String, dynamic>> request;
  JsonRpcPromptTerminalWinner? winner;
  Future<void>? cleanupFuture;
  Future<void>? cancelSubmission;
  final Completer<Map<String, dynamic>> caller =
      Completer<Map<String, dynamic>>.sync();
  Timer? deadlineTimer;
  void Function()? deadlineCallbackForTesting;
  bool cancelSent = false;
  bool reaped = false;

  bool tryRecordWinner(JsonRpcPromptTerminalWinner candidate) {
    if (winner != null) return false;
    winner = candidate;
    deadlineTimer?.cancel();
    return true;
  }

  Future<void> sendCancelOnce(JsonRpcPeer peer) {
    if (cancelSent) return Future<void>.value();
    cancelSent = true;
    return peer.sendNotificationRaw('session/cancel', <String, dynamic>{
      'sessionId': owner.sessionId,
    });
  }
}

JsonRpcPromptCleanup cancelPromptRequest({
  required JsonRpcPromptOwner owner,
  required Future<void> admissionsSettled,
  bool sendCancel = true,
}) {
  final operation = _promptOperationsByOwner[owner];
  if (operation == null || !_isCurrentPromptOperation(operation)) {
    final error = Future<void>.error(
      StateError('ACP prompt phase owner is no longer active.'),
    );
    return JsonRpcPromptCleanup(notificationSubmitted: error, reaped: error);
  }
  final existing = operation.cleanupFuture;
  if (existing != null) {
    return JsonRpcPromptCleanup(
      notificationSubmitted:
          operation.cancelSubmission ?? Future<void>.value(),
      reaped: existing,
    );
  }
  final notification = sendCancel && !operation.reaped
      ? operation.sendCancelOnce(this)
      : Future<void>.value();
  operation.cancelSubmission = notification;
  final notificationObserved = notification.then<void>(
    (_) {},
    onError: (Object _, StackTrace __) {},
  );
  unawaited(notificationObserved);
  final requestReaped = operation.request.then<void>(
    (_) {},
    onError: (Object _, StackTrace __) {},
  );
  final cleanup = () async {
    try {
      await Future.wait<void>(<Future<void>>[
        requestReaped,
        admissionsSettled,
      ], eagerError: false);
    } finally {
      operation.reaped = true;
      _removePromptOperation(operation);
    }
  }();
  operation.cleanupFuture = cleanup;
  return JsonRpcPromptCleanup(
    notificationSubmitted: notification,
    reaped: cleanup,
  );
}

bool _isCurrentPromptOperation(_JsonRpcPromptOperation operation) =>
    identical(_promptOperationsByOwner[operation.owner], operation) &&
    identical(
      _promptOperationsBySession[operation.owner.sessionId],
      operation,
    );

void _removePromptOperation(_JsonRpcPromptOperation operation) {
  if (!_isCurrentPromptOperation(operation)) return;
  operation.deadlineTimer?.cancel();
  final owner = operation.owner;
  _promptOperationsByOwner.remove(owner);
  _promptOperationsBySession.remove(owner.sessionId);
}
```

- [ ] 16. 在 peer 增加以下两个索引；登记函数同步拒绝已有 pending/settling operation，迟到 callback 只有两个 map 都仍指向同一对象时才能 reap。response、remote error、deadline 用 `tryRecordWinner` 竞争，request Future 的 value/error 在登记时即安装 consumer。

```dart
final Map<String, _JsonRpcPromptOperation> _promptOperationsBySession =
    <String, _JsonRpcPromptOperation>{};
final Map<JsonRpcPromptOwner, _JsonRpcPromptOperation>
    _promptOperationsByOwner =
        HashMap<JsonRpcPromptOwner, _JsonRpcPromptOperation>.identity();

@visibleForTesting
int get promptOperationCountForTesting => _promptOperationsByOwner.length;

@visibleForTesting
final class PausedSessionUpdateForTesting {
  PausedSessionUpdateForTesting(this.envelope, this.release);
  final Object? envelope;
  final Future<void> release;
}

Completer<void>? _pauseNextSessionUpdate;
final Completer<void> _pausedSessionUpdateCaptured = Completer<void>.sync();
Future<void> get pausedSessionUpdateCapturedForTesting =>
    _pausedSessionUpdateCaptured.future;
void pauseNextSessionUpdateForTesting() {
  _pauseNextSessionUpdate = Completer<void>.sync();
}
void releasePausedSessionUpdateForTesting() {
  _pauseNextSessionUpdate?.complete();
}

void dispatchSessionUpdateForTesting(Object? envelope) {
  final gate = _pauseNextSessionUpdate;
  _pauseNextSessionUpdate = null;
  if (gate == null) {
    _sessionUpdates.add(envelope);
    return;
  }
  _sessionUpdates.add(PausedSessionUpdateForTesting(envelope, gate.future));
  if (!_pausedSessionUpdateCaptured.isCompleted) {
    _pausedSessionUpdateCaptured.complete();
  }
}

void _completePromptOperationsUnavailable(AcpPeerUnavailableState state) {
  for (final operation in
      _promptOperationsByOwner.values.toList(growable: false)) {
    if (!_isCurrentPromptOperation(operation)) continue;
    final cleanup = state.cleanupIdentity;
    final preservesCachedTerminal =
        state.reason == AcpPeerUnavailableReason.fatalTimeout &&
        cleanup != null &&
        identical(cleanup.ownerToken, operation.owner) &&
        cleanup.generation == operation.owner.generation &&
        operation.winner != null &&
        operation.cleanupFuture != null;
    if (preservesCachedTerminal) {
      // cleanup Future 继续持有 operation/caller；其完成分支投递缓存 winner。
      continue;
    }
    if (!operation.caller.isCompleted) {
      operation.caller.completeError(const AcpConnectionClosedException());
    }
    final lateConsumer = operation.request.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    unawaited(lateConsumer.catchError((Object _, StackTrace __) {}));
    if (operation.cleanupFuture == null) {
      _removePromptOperation(operation);
    }
  }
}

Future<Map<String, dynamic>> sendPromptRequest({
  required JsonRpcPromptOwner owner,
  required List<Map<String, dynamic>> content,
  required JsonRpcPromptTerminalHandler onTerminal,
}) {
  if (!isAvailable ||
      _promptOperationsBySession.containsKey(owner.sessionId) ||
      _promptOperationsByOwner.containsKey(owner)) {
    return Future<Map<String, dynamic>>.error(
      StateError('ACP prompt is already active or settling.'),
    );
  }
  final original = Completer<Map<String, dynamic>>.sync();
  final operation = _JsonRpcPromptOperation(
    owner: owner,
    request: original.future,
  );
  _promptOperationsBySession[owner.sessionId] = operation;
  _promptOperationsByOwner[owner] = operation;

  void finish(JsonRpcPromptTerminalWinner winner) {
    if (!_isCurrentPromptOperation(operation) ||
        !operation.tryRecordWinner(winner)) {
      return;
    }
    final settlement = onTerminal(owner, winner);
    if (!settlement.accepted) {
      if (operation.cleanupFuture == null) {
        _removePromptOperation(operation);
      }
      if (!operation.caller.isCompleted) {
        operation.caller.completeError(const AcpConnectionClosedException());
      }
      return;
    }
    final cleanup = cancelPromptRequest(
      owner: owner,
      admissionsSettled: settlement.admissionsSettled,
      sendCancel: winner.kind == JsonRpcPromptTerminalKind.timedOut,
    );
    unawaited(cleanup.reaped.then<void>((_) {
      if (operation.caller.isCompleted) return;
      switch (winner.kind) {
        case JsonRpcPromptTerminalKind.response:
          operation.caller.complete(winner.response!);
          break;
        case JsonRpcPromptTerminalKind.remoteError:
          operation.caller.completeError(
            winner.error!,
            winner.stackTrace ?? StackTrace.empty,
          );
          break;
        case JsonRpcPromptTerminalKind.timedOut:
          operation.caller.completeError(const AcpPromptTimeoutException());
          break;
      }
    }, onError: (Object error, StackTrace stackTrace) {
      if (!operation.caller.isCompleted) {
        operation.caller.completeError(error, stackTrace);
      }
    }));
  }

  final rawRequest = _sendRequest(
    'session/prompt',
    <String, dynamic>{'sessionId': owner.sessionId, 'prompt': content},
    promptOwner: owner,
  );
  final rawConsumer = rawRequest.then<void>((raw) {
    if (!_isCurrentPromptOperation(operation)) return;
    if (raw is! Map) {
      const error = FormatException('Invalid session/prompt response.');
      if (!original.isCompleted) original.completeError(error);
      operation.reaped = true;
      finish(const JsonRpcPromptTerminalWinner(
        kind: JsonRpcPromptTerminalKind.remoteError,
        error: error,
      ));
      return;
    }
    final response = Map<String, dynamic>.from(raw);
    if (!original.isCompleted) original.complete(response);
    operation.reaped = true;
    finish(JsonRpcPromptTerminalWinner(
      kind: JsonRpcPromptTerminalKind.response,
      response: response,
    ));
  }, onError: (Object error, StackTrace stackTrace) {
    if (!_isCurrentPromptOperation(operation)) return;
    if (!original.isCompleted) original.completeError(error, stackTrace);
    operation.reaped = true;
    finish(JsonRpcPromptTerminalWinner(
      kind: JsonRpcPromptTerminalKind.remoteError,
      error: error,
      stackTrace: stackTrace,
    ));
  });
  // `then` callback 自身的 Map conversion/onTerminal 错误也必须被消费；
  // 不能只给 rawRequest 提供 onError。
  unawaited(rawConsumer.catchError((Object _, StackTrace __) {}));
  void deadline() {
    finish(const JsonRpcPromptTerminalWinner(
      kind: JsonRpcPromptTerminalKind.timedOut,
    ));
  }
  operation.deadlineCallbackForTesting = deadline;
  operation.deadlineTimer = Timer(timeouts.prompt, deadline);
  return operation.caller.future;
}

void firePromptDeadlineForTesting(JsonRpcPromptOwner owner) {
  final operation = _promptOperationsByOwner[owner];
  if (operation == null || !_isCurrentPromptOperation(operation)) {
    throw StateError('Prompt operation is no longer current.');
  }
  operation.deadlineCallbackForTesting!.call();
}
```

Task 4 `_becomeUnavailable` 在安装 `state` 与禁写后、通知 manager listener 和关闭底层 peer 前，同步调用 `_completePromptOperationsUnavailable(state)`。只有 fatalTimeout 的 cleanup identity 同时匹配 operation owner identity/generation，且 winner 已登记、cleanup Future 已安装时，保留 caller供原 cleanup 完成分支投缓存终态。transport/request fatal、explicit close、dispose、other-owner fatal，以及 winner/cleanup 尚未建立的同 owner fatal，都立刻完成固定 `AcpConnectionClosedException`；但若 operation 已有 cleanup Future，双索引仍由该 cleanup 在原 request与admissions真实 reap后唯一移除，unavailable或 rejected late terminal不得抢先移除。只有从未开始 cleanup 的 operation 才在 unavailable/rejected 分支同步移除。之后到达的 raw value/error/malformed 仅被 consumer 吃掉；`rawConsumer.catchError` 还消费 `then` callback 自身抛错。

- [ ] 17. 在 `session_manager.dart` 增加 lifecycle 与 delivery right。Task 6 已加入 owner 的 `managerIdentity`；本任务把 owner/session generation/not-closing/peer epoch 同步验证与 peer operation 登记放在同一无 `await` 调用栈：

```dart
final class AcpSessionInputBudgetOwner implements JsonRpcPromptOwner {
  const AcpSessionInputBudgetOwner._(
    this.sessionId,
    this.generation,
    this.managerIdentity,
  );
  @override
  final String sessionId;
  @override
  final int generation;
  final Object managerIdentity;
}

enum _PromptDeliveryRightState { pending, claimed, revoked }
enum _PromptLifecycleState { active, settling, terminalReady, removed }

final class _PromptDeliveryRight {
  _PromptDeliveryRight(this.owner, this.winner);
  final AcpSessionInputBudgetOwner owner;
  final JsonRpcPromptTerminalWinner winner;
  _PromptDeliveryRightState state = _PromptDeliveryRightState.pending;
  bool tryClaim() {
    if (state != _PromptDeliveryRightState.pending) return false;
    state = _PromptDeliveryRightState.claimed;
    return true;
  }
  void revoke() {
    if (state == _PromptDeliveryRightState.pending) {
      state = _PromptDeliveryRightState.revoked;
    }
  }
}

final class _PromptLifecycle {
  _PromptLifecycle(this.owner, this.sessionGeneration);
  final AcpSessionInputBudgetOwner owner;
  final Object sessionGeneration;
  JsonRpcPromptTerminalWinner? winner;
  PermissionCancellationReason? cancellationWinner;
  _PromptDeliveryRight? deliveryRight;
  _OwnerCleanupWindow? cleanupWindow;
  Future<void>? promptReaped;
  Future<void>? cleanupFuture;
  Future<void>? cancelSubmitted;
  Future<Map<String, dynamic>>? promptResult;
  AcpPromptCleanupIdentity? cleanupIdentity;
  final Completer<void> winnerRecorded = Completer<void>.sync();
  final Completer<void> rightRecorded = Completer<void>.sync();
  final Completer<void> barrierReleased = Completer<void>.sync();
  final Completer<void> claimSeen = Completer<void>.sync();
  Completer<void>? preclaimBarrierForTesting;
  final Completer<void> preclaimReachedForTesting = Completer<void>.sync();
  _PromptLifecycleState state = _PromptLifecycleState.active;
  bool callerEnded = false;
  bool terminalOnly = false;
  bool get settling => state != _PromptLifecycleState.active;
  bool get removed => state == _PromptLifecycleState.removed;
  final Set<_InboundPermissionAdmission> admissions =
      HashSet<_InboundPermissionAdmission>.identity();
  final Completer<void> _admissionsSettled = Completer<void>.sync();

  Future<void> get admissionsSettled => _admissionsSettled.future;

  void attachAdmission(_InboundPermissionAdmission admission) {
    if (removed) {
      admission.tryCancel(
        cancellationWinner ?? PermissionCancellationReason.promptEnded,
      );
      return;
    }
    admissions.add(admission);
    if (settling && cancellationWinner != null) {
      admission.tryCancel(cancellationWinner!);
    }
  }

  void markAdmissionSettled(_InboundPermissionAdmission admission) {
    admissions.remove(admission);
    if (settling && admissions.isEmpty && !_admissionsSettled.isCompleted) {
      _admissionsSettled.complete();
    }
  }

  void startSettling() {
    if (state == _PromptLifecycleState.active) {
      state = _PromptLifecycleState.settling;
    }
    if (admissions.isEmpty && !_admissionsSettled.isCompleted) {
      _admissionsSettled.complete();
    }
  }
}

// `_managerIdentity` 已由 Task 6 定义；本 Task 直接复用，不得重复声明。
final Map<String, _PromptLifecycle> _promptLifecycles =
    <String, _PromptLifecycle>{};
final Map<AcpSessionInputBudgetOwner, PromptLifecycleSnapshot>
    _releasedPromptLifecycleSnapshots =
        HashMap<AcpSessionInputBudgetOwner, PromptLifecycleSnapshot>.identity();

final class PromptLifecycleSnapshot {
  const PromptLifecycleSnapshot({
    required this.winner,
    required this.cancellationWinner,
    required this.hasDeliveryRight,
    required this.cleanupDeadline,
    required this.admissionCleanupDeadline,
    required this.cleanupIdentity,
    required this.cleanupStarted,
  });
  final JsonRpcPromptTerminalWinner? winner;
  final PermissionCancellationReason? cancellationWinner;
  final bool hasDeliveryRight;
  final DateTime? cleanupDeadline;
  final DateTime? admissionCleanupDeadline;
  final AcpPromptCleanupIdentity? cleanupIdentity;
  final bool cleanupStarted;
}

PromptLifecycleSnapshot _snapshotPromptLifecycle(
  _PromptLifecycle lifecycle,
) => PromptLifecycleSnapshot(
  winner: lifecycle.winner,
  cancellationWinner: lifecycle.cancellationWinner,
  hasDeliveryRight: lifecycle.deliveryRight != null,
  cleanupDeadline: lifecycle.cleanupWindow?.deadline,
  admissionCleanupDeadline: lifecycle.cleanupWindow?.deadline,
  cleanupIdentity: lifecycle.cleanupIdentity,
  cleanupStarted: lifecycle.cleanupFuture != null,
);

PromptLifecycleSnapshot promptLifecycleSnapshotForTesting(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle != null && identical(lifecycle.owner, owner)) {
    return _snapshotPromptLifecycle(lifecycle);
  }
  return _releasedPromptLifecycleSnapshots[owner] ??
      (throw StateError('Prompt lifecycle snapshot is unavailable.'));
}


bool _isCurrentPromptLifecycle(_PromptLifecycle lifecycle) =>
    lifecycle.state != _PromptLifecycleState.removed &&
    identical(
      _promptLifecycles[lifecycle.owner.sessionId],
      lifecycle,
    );

void _routeSessionUpdateForGeneration(
  String sessionId,
  _SessionGeneration generation,
  Object? envelope,
) {
  final current = _sessionGenerations[sessionId];
  if (!generation.active ||
      current == null ||
      !identical(current, generation)) {
    return;
  }
  _routeSessionUpdate(envelope);
}

void _onPeerSessionUpdate(Object? incoming) {
  final envelope = incoming is PausedSessionUpdateForTesting
      ? incoming.envelope
      : incoming;
  final sessionId = _sessionIdFromEnvelope(envelope);
  final generation = sessionId == null ? null : _sessionGenerations[sessionId];
  if (sessionId == null || generation == null) return;
  if (incoming is PausedSessionUpdateForTesting) {
    unawaited(incoming.release.then<void>((_) {
      _routeSessionUpdateForGeneration(sessionId, generation, envelope);
    }));
    return;
  }
  _routeSessionUpdateForGeneration(sessionId, generation, envelope);
}

_PromptLifecycle _promptLifecycleForOwnerForTesting(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null ||
      !_isCurrentPromptLifecycle(lifecycle) ||
      !identical(lifecycle.owner, owner)) {
    throw StateError('Prompt lifecycle is no longer current.');
  }
  return lifecycle;
}

AcpSessionInputBudgetOwner activePromptOwnerForTesting(String sessionId) =>
    _promptLifecycles[sessionId]!.owner;
Future<Map<String, dynamic>> promptResultForTesting(
  AcpSessionInputBudgetOwner owner,
) => _promptLifecycleForOwnerForTesting(owner).promptResult!;
Future<void> promptWinnerRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _promptLifecycleForOwnerForTesting(owner).winnerRecorded.future;
Future<void> promptRightRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _promptLifecycleForOwnerForTesting(owner).rightRecorded.future;
Future<void> promptBarrierReleasedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _promptLifecycleForOwnerForTesting(owner).barrierReleased.future;
Future<void> promptClaimSeenForTesting(
  AcpSessionInputBudgetOwner owner,
) => _promptLifecycleForOwnerForTesting(owner).claimSeen.future;
Future<void> holdPromptPreclaimForTesting(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycleForOwnerForTesting(owner);
  lifecycle.preclaimBarrierForTesting ??= Completer<void>.sync();
  return lifecycle.preclaimReachedForTesting.future;
}
void releasePromptPreclaimForTesting(AcpSessionInputBudgetOwner owner) {
  _promptLifecycleForOwnerForTesting(owner)
      .preclaimBarrierForTesting
      ?.complete();
}
bool promptHasDeliveryRightForTesting(AcpSessionInputBudgetOwner owner) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  return lifecycle != null &&
      identical(lifecycle.owner, owner) &&
      _isCurrentPromptLifecycle(lifecycle) &&
      lifecycle.deliveryRight != null;
}
bool promptLifecycleIsCurrentForTesting(AcpSessionInputBudgetOwner owner) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  return lifecycle != null &&
      identical(lifecycle.owner, owner) &&
      _isCurrentPromptLifecycle(lifecycle);
}

AcpSessionInputBudgetOwner beginPromptTurn(String sessionId) {
  if (_disposed || !peer.isAvailable) {
    throw StateError('ACP connection is not available.');
  }
  if (_isSessionClosing(sessionId) ||
      _sessionSetupTails.containsKey(sessionId)) {
    throw StateError('Session is closing or setup is active.');
  }
  if (_promptLifecycles.containsKey(sessionId)) {
    throw StateError('ACP prompt is already active or settling.');
  }
  final sessionGeneration = _sessionGenerations[sessionId];
  if (sessionGeneration == null || !sessionGeneration.active) {
    throw StateError('Unknown or closed session.');
  }
  final owner = _beginInputBudgetPhase(
    sessionId,
    managerIdentity: _managerIdentity,
  );
  _promptLifecycles[sessionId] =
      _PromptLifecycle(owner, sessionGeneration);
  return owner;
}

void endPromptTurn(AcpSessionInputBudgetOwner owner) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null ||
      !_isCurrentPromptLifecycle(lifecycle) ||
      !identical(lifecycle.owner, owner)) {
    return;
  }
  lifecycle.callerEnded = true;
  final cleanup = lifecycle.cleanupFuture;
  if (cleanup != null) {
    unawaited(cleanup.whenComplete(() {
      if (lifecycle.callerEnded) _releasePromptLifecycle(lifecycle);
    }));
  }
}

Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner) async {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null ||
      !_isCurrentPromptLifecycle(lifecycle) ||
      !identical(lifecycle.owner, owner) ||
      !identical(owner.managerIdentity, _managerIdentity)) {
    throw StateError('ACP prompt phase owner is no longer active.');
  }
  _settlePromptLifecycle(
    lifecycle,
    PermissionCancellationReason.promptCancelled,
    sendCancel: true,
  );
  await lifecycle.cancelSubmitted;
}

```

`peer.sessionUpdates` 的真实订阅入口 `_onPeerSessionUpdate` 必须在收到 envelope 时捕获当时的 `_SessionGeneration`，随后统一调用 `_routeSessionUpdateForGeneration`；测试 pause 也只能暂停这个已发生的真实 peer callback。close 在首个 `await` 前把 A generation 标成 inactive，resume 建立 B 后才释放 callback，所以旧 update 会被 identity guard 丢弃；fixture 不得直接调用 manager route 或注入 generation。`winnerRecorded` 与 `rightRecorded` 是 lifecycle 内两个独立 `Completer.sync()`，不得从 caller `promptResult.then(...)` 或彼此派生。

- [ ] 18. 实现 owner 验证与 lifecycle 登记的方法体；固定 settling 错误在 manager 与 peer 两层一致，foreign owner、同 session 旧 generation owner 与 settling owner 不可写 wire：

```dart
_PromptLifecycle _requireDispatchablePrompt(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  final generation = _sessionGenerations[owner.sessionId];
  if (_disposed ||
      !peer.isAvailable ||
      !identical(owner.managerIdentity, _managerIdentity) ||
      lifecycle == null ||
      !_isCurrentPromptLifecycle(lifecycle) ||
      !identical(lifecycle.owner, owner) ||
      lifecycle.settling ||
      generation == null ||
      !generation.active ||
      !identical(lifecycle.sessionGeneration, generation) ||
      _isSessionClosing(owner.sessionId)) {
    throw StateError('ACP prompt is already active or settling.');
  }
  return lifecycle;
}

Future<Map<String, dynamic>> sendPromptRequest({
  required AcpSessionInputBudgetOwner owner,
  required List<Map<String, dynamic>> content,
}) {
  final lifecycle = _requireDispatchablePrompt(owner);
  final result = peer.sendPromptRequest(
    owner: owner,
    content: content,
    onTerminal: (terminalOwner, winner) {
      if (!identical(terminalOwner, owner) ||
          !_isCurrentPromptLifecycle(lifecycle) ||
          lifecycle.state == _PromptLifecycleState.removed ||
          lifecycle.winner != null) {
        return JsonRpcPromptSettlement.rejected();
      }
      final cancellationWinner = lifecycle.cancellationWinner;
      if (cancellationWinner == PermissionCancellationReason.promptCancelled ||
          cancellationWinner == PermissionCancellationReason.sessionClosed) {
        // cancellation/close 已建立并持有唯一 cleanup；迟到 terminal 只被
        // peer consumer 吃掉，不能被当作新的 accepted winner。
        return JsonRpcPromptSettlement.rejected();
      }
      lifecycle.winner = winner;
      if (!lifecycle.winnerRecorded.isCompleted) {
        lifecycle.winnerRecorded.complete();
      }
      lifecycle.deliveryRight = _PromptDeliveryRight(owner, winner);
      if (!lifecycle.rightRecorded.isCompleted) {
        lifecycle.rightRecorded.complete();
      }
      lifecycle.state = _PromptLifecycleState.terminalReady;
      _settlePromptLifecycle(
        lifecycle,
        PermissionCancellationReason.promptEnded,
        sendCancel: winner.kind == JsonRpcPromptTerminalKind.timedOut,
      );
      return JsonRpcPromptSettlement(
        lifecycle.admissionsSettled,
      );
    },
  );
  lifecycle.promptResult = result;
  return result;
}
```

Task 4 的唯一 unavailable listener 在失效 peer epoch 后，必须同步处理仍无 delivery right 的 lifecycle：先核对 `_isCurrentPromptLifecycle`，写入 `connectionClosed`，撤销 pending right（如有），把 `state` 置为 `removed` 并按对象 identity 从 map 删除。随后到达的 request value/error 仍由 peer consumer 吃掉；上面的 terminal hook 因 current-map identity/state 检查拒绝它，不能登记 winner、完成 `winnerRecorded/rightRecorded` 或补建 delivery right。Task 10 只会为“同 owner cleanup fatal 且 right 已存在”的例外保留 terminal-only 交付。

- [ ] 19. 在 `AcpClient` 增加以下公开代理，方法体必须逐字使用 manager owner-bound 入口；不能访问私有 peer，也不接受第二个 sessionId。同一步按前述固定顺序加入 `beforeSessionManagerForTesting/afterSessionManagerForTesting` 同步组装回调，且正常调用不传回调时行为完全不变：

```dart
Future<Map<String, dynamic>> sendPromptRequest({
  required AcpSessionInputBudgetOwner owner,
  required List<Map<String, dynamic>> content,
}) => _sessionManager.sendPromptRequest(owner: owner, content: content);
```

- [ ] 20. 把 typed `SessionManager.prompt` 的后台主体替换为以下真实调用。Task 9 先加入调用专属 `_TypedPromptTurn` 与可编译的初始 delivery body；Task 10 只把该 body 收紧为 right claim/unavailable first-wins。删除旧 `_sessionStreams[sessionId]?.add(turnEnded)` 与共享 stream `addError` 终态路径，避免双投递：

```dart
final class _TypedPromptTurn {
  _TypedPromptTurn(this.owner, this.controller);
  final AcpSessionInputBudgetOwner owner;
  final StreamController<AcpUpdate> controller;
  StreamSubscription<AcpUpdate>? updates;
  bool terminalOnly = false;
  bool closed = false;
}

Future<void> _runTypedPrompt(
  _TypedPromptTurn turn,
  List<Map<String, dynamic>> content,
) async {
  final lifecycle = _requireDispatchablePrompt(turn.owner);
  Object? rpcFailure;
  StackTrace? rpcFailureStack;
  try {
    try {
      await sendPromptRequest(owner: turn.owner, content: content);
    } on Object catch (error, stackTrace) {
      rpcFailure = error;
      rpcFailureStack = stackTrace;
    }
    if (lifecycle.winner == null) {
      if (!turn.closed) {
        turn.controller.addError(
          rpcFailure ?? const AcpConnectionClosedException(),
          rpcFailureStack ?? StackTrace.empty,
        );
        _closeTypedPromptTurn(turn);
      }
      return;
    }
    try {
      await lifecycle.cleanupFuture;
    } on Object {
      // winner 已登记时，cleanup fatal 只影响 peer 可用性；缓存的
      // terminal/right 仍必须穿过 barrier 并精确交付一次。
    }
    if (!lifecycle.barrierReleased.isCompleted) {
      lifecycle.barrierReleased.complete();
    }
    await _deliverTypedPromptWinner(lifecycle, turn);
  } finally {
    endPromptTurn(turn.owner);
  }
}

final Map<AcpSessionInputBudgetOwner, _TypedPromptTurn> _activeTypedTurns =
    HashMap<AcpSessionInputBudgetOwner, _TypedPromptTurn>.identity();

void _registerTypedPromptTurn(_TypedPromptTurn turn) {
  final previous = _activeTypedTurns[turn.owner];
  if (previous != null && !identical(previous, turn)) {
    throw StateError('ACP typed prompt turn is already registered.');
  }
  _activeTypedTurns[turn.owner] = turn;
}

Future<void> _deliverTypedPromptWinner(
  _PromptLifecycle lifecycle,
  _TypedPromptTurn turn,
) async {
  final winner = lifecycle.winner!;
  if (winner.kind == JsonRpcPromptTerminalKind.response) {
    turn.controller.add(TurnEnded(stopReasonFromWire(
      (winner.response?['stopReason'] as String?) ?? 'other',
    )));
  } else {
    turn.controller.addError(
      winner.kind == JsonRpcPromptTerminalKind.timedOut
          ? const AcpPromptTimeoutException()
          : winner.error!,
      winner.stackTrace ?? StackTrace.empty,
    );
    turn.controller.add(const TurnEnded(StopReason.other));
  }
  _closeTypedPromptTurn(turn);
  _releasePromptLifecycle(lifecycle);
}

void _closeTypedPromptTurn(_TypedPromptTurn turn) {
  if (turn.closed) return;
  turn.closed = true;
  if (identical(_activeTypedTurns[turn.owner], turn)) {
    _activeTypedTurns.remove(turn.owner);
  }
  _closeControllerWithoutWaiting(turn.controller);
}

void _releasePromptLifecycle(_PromptLifecycle lifecycle) {
  if (!_isCurrentPromptLifecycle(lifecycle)) return;
  _releasedPromptLifecycleSnapshots[lifecycle.owner] =
      _snapshotPromptLifecycle(lifecycle);
  lifecycle.state = _PromptLifecycleState.removed;
  _promptLifecycles.remove(lifecycle.owner.sessionId);
  final phase = _inputBudgetPhases[lifecycle.owner.sessionId];
  if (phase != null && identical(phase.owner, lifecycle.owner)) {
    phase.invalidated = true;
    _inputBudgetPhases.remove(lifecycle.owner.sessionId);
  }
}
```

创建 owner、创建 turn、调用 `_registerTypedPromptTurn(turn)`、调用 `_runTypedPrompt` 之间不得 `await`；这样 Task 4 unavailable 的同步回放也能找到调用专属 sink。外层 `finally` 的 `endPromptTurn` 先标记 `callerEnded=true`，并只在共享 cleanup 已结束后调用幂等 `_releasePromptLifecycle`。typed terminal delivery 的 `finally` 也调用同一 helper，从而让同 session replacement 在交付结束后立即可登记且不会双重移除。

- [ ] 21. prompt cleanup只向Task 7共享window登记 lifecycle blocker。peer `cancelPromptRequest` 只负责 notification与真实request/admissions reap，不接受 deadline、不创建 Timer/`Future.delayed`/`Future.timeout`、不自行 fatal close；`notificationSubmitted` 始终保留原 Future，所以 cancel API 可观察真实成功或失败，同时独立 error drain 防止未等待的 deadline/close 路径泄漏 zone error。notification error绝不能进入或短路 `cleanup.reaped`：后者无条件等待已安装 consumer 的原 request与 `admissionsSettled`，两者都真实完成后才在 finally 标记 reaped并移除双索引。manager把该 `cleanup.reaped` 作为 blocker Future get-or-join owner window，并把 `window.reaped` 保存为 lifecycle唯一 cleanup Future：

```dart
Future<void> _settlePromptLifecycle(
  _PromptLifecycle lifecycle,
  PermissionCancellationReason reason, {
  bool sendCancel = false,
}) {
  final existing = lifecycle.cleanupFuture;
  if (existing != null) return existing;
  lifecycle.startSettling();
  lifecycle.cancellationWinner ??= reason;
  _cancelAdmissionsForOwner(lifecycle.owner, lifecycle.cancellationWinner!);
  final cleanup = peer.cancelPromptRequest(
    owner: lifecycle.owner,
    admissionsSettled: lifecycle.admissionsSettled,
    sendCancel: sendCancel,
  );
  final window = _getOrJoinOwnerCleanupWindow(
    key: lifecycle.owner,
    fatalOwner: lifecycle.owner,
    blockerIdentity: lifecycle,
    blockerReaped: cleanup.reaped,
  );
  lifecycle.cancelSubmitted = cleanup.notificationSubmitted;
  lifecycle.promptReaped = cleanup.reaped;
  lifecycle.cleanupWindow = window;
  lifecycle.cleanupFuture = window.reaped;
  return window.reaped;
}

void _cancelAdmissionsForOwner(
  AcpSessionInputBudgetOwner owner,
  PermissionCancellationReason reason,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null || !identical(lifecycle.owner, owner)) return;
  settlePromptAdmissions(owner: owner, reason: reason);
  for (final admission in lifecycle.admissions.toList(growable: false)) {
    admission.tryCancel(reason);
  }
}
```

Task 6 的 admission hook 在找到 lifecycle 时调用 `lifecycle.attachAdmission(admission)`；reservation release随后以 admission identity调用同一个 `_getOrJoinOwnerCleanupWindow`。`_removeInboundAdmission` 在移除 identity set 前调用 `lifecycle.markAdmissionSettled(admission)`。这样 admission先创建、prompt后加入，或prompt先创建、admission后加入，都冻结同一个 deadline/Timer/expiryFuture/reaped；后加入只增 blocker。

- [ ] 22. 实现 deadline 首赢固定顺序：记录 `timedOut` winner并签发 delivery right → manager terminal hook 以 `promptEnded` 同步结算 permissions → 调 `_settlePromptLifecycle(..., sendCancel: true)` → 在同一 deadline 等原 request 与 admissions；迟到 response/error 只用于清 peer pending，不能改 winner。正常 response/remote error 调同一 helper但 `sendCancel: false`。

- [ ] 23. 实现用户取消：owner identity 验证通过后先把首因设为 `promptCancelled` 并取消 owner admissions，再调用 `_settlePromptLifecycle(..., sendCancel: true)`；`cancelPromptTurn` 只 `await lifecycle.cancelSubmitted`，不等待 `cleanupFuture`，notification失败原样传给调用方但不影响后台 cleanup；旧 reap 前 barrier 保留。stale owner 直接固定 StateError，不按 sessionId 查新 lifecycle。

- [ ] 24. 实现 session close 复用：`_beginSessionClose` 在首个 `await` 前把首因设为 `sessionClosed`、失效 generation并调用 `_settlePromptLifecycle(..., sendCancel: true)`；Task 10 再以close owner identity get-or-join同一window。与 response/deadline/user cancel竞态时只复用 operation的 `sendCancelOnce`、共享window与 `cleanupFuture`，不新增任何计时路径。

- [ ] 25. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt uses the public owner bound proxy and rejects stale owners"`。Expected: PASS。

- [ ] 26. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt terminal waits for admission response commit before replacement"`。Expected: PASS。

- [ ] 27. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt timeout shares one cancel and one cleanup grace with admissions"`。Expected: PASS。

- [ ] 28. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "prompt cancellation keeps replacement settling and stale cancel is isolated"`。Expected: PASS。

- [ ] 29. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "failed prompt cancel submission still reaps request and admissions before replacement"`。Expected: PASS；cancel API 收到固定真实 sink error，graceful子流程在 request/admission真实 reap前拒绝replacement且reap后允许新 owner，fatal子流程在同一 Task 7 window 到期前保持 settling并只触发一次 `fatalTimeout`，两条路径的 cleanup window/peer operation/admission 均归零。

- [ ] 30. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close shares prompt cancel and reap across response deadline and user cancel"`。Expected: PASS。

- [ ] 31. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "late unavailable replay invalidates prompt epoch before dispatch"`。Expected: PASS。

- [ ] 32. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: PASS。

- [ ] 33. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: exit 0。

- [ ] 34. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 35. 运行 `git add third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: 只暂存本任务五个文件。

- [ ] 36. 运行 `git commit -m "fix: bind ACP prompt lifecycle owners"`。Expected: commit成功；本提交保留 raw 旧 caller到 Task 11，但 typed 已完全 owner-bound。

### Task 10: Typed delivery right 与 session close finally

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

在首个 RED 前加入下列 test driver。它们组合 Task 9 的真实 `_PromptLifecycleHarness`，不另造 peer；所有事件仍由同一个 wire、真实 `SessionManager.prompt` 和 fake provider 驱动：

```dart
enum _TypedClaimRace {
  closeBeforeClaim,
  claimBeforeClose,
  otherOwnerFatal,
  sameOwnerCleanupAfterWinner,
  sameOwnerAdmissionFatalBeforeWinner,
}

enum _TypedAdmissionEntry { fsRead, fsWrite, terminal }

enum _TypedUnavailableFirst {
  transportClosed,
  requestFatal,
  explicitClose,
  dispose,
}

enum _RemoteCloseFailure {
  remoteError,
  requestTimeout,
  ownerlessAdmission,
  peerFatal,
  remoteAndCleanupError,
}

enum _SessionCloseReapSource { admission, prompt }

final class _TypedTurnProbe {
  _TypedTurnProbe(Stream<AcpUpdate> stream) {
    _subscription = stream.listen(
      (event) {
        _events.add(event);
        if (event is TurnEnded) terminalDeliveryCount += 1;
      },
      onError: (Object error, StackTrace stackTrace) {
        errors.add(error);
        if (error is AcpConnectionClosedException) {
          connectionClosedCount += 1;
        }
      },
      onDone: () {
        streamDoneCount += 1;
        if (!done.isCompleted) done.complete();
        if (!_eventsDone.isCompleted) _eventsDone.complete(_events);
      },
    );
  }

  late final StreamSubscription<AcpUpdate> _subscription;
  final List<AcpUpdate> _events = <AcpUpdate>[];
  final List<Object> errors = <Object>[];
  final Completer<List<AcpUpdate>> _eventsDone =
      Completer<List<AcpUpdate>>();
  final Completer<void> cleanupFatalSeen = Completer<void>();
  final Completer<void> winnerRecorded = Completer<void>();
  final Completer<void> rightRecorded = Completer<void>();
  final Completer<void> barrierReleased = Completer<void>();
  final Completer<void> claimSeen = Completer<void>();
  final Completer<void> done = Completer<void>();
  int streamDoneCount = 0;
  int terminalDeliveryCount = 0;
  int connectionClosedCount = 0;

  Future<List<AcpUpdate>> get events => _eventsDone.future;

  Future<void> dispose() async {
    await _subscription.cancel();
    if (!done.isCompleted) done.complete();
    if (!_eventsDone.isCompleted) _eventsDone.complete(_events);
  }
}

final class _TypedPromptHarness {
  _TypedPromptHarness._(this.prompt);

  static Future<_TypedPromptHarness> start() async {
    final prompt = await _PromptLifecycleHarness.start(
      grace: const Duration(milliseconds: 75),
    );
    final harness = _TypedPromptHarness._(prompt);
    prompt.peer.addUnavailableListener((state) {
      final turn = harness._activeTurn;
      final operation = prompt._current;
      final cleanup = state.cleanupIdentity;
      if (turn != null &&
          operation != null &&
          state.reason == AcpPeerUnavailableReason.fatalTimeout &&
          cleanup != null &&
          identical(cleanup.ownerToken, operation.owner) &&
          cleanup.generation == operation.owner.generation &&
          !turn.cleanupFatalSeen.isCompleted) {
        turn.cleanupFatalSeen.complete();
      }
    });
    return harness;
  }

  final _PromptLifecycleHarness prompt;
  _TypedTurnProbe? _activeTurn;
  JsonRpcPeer get peer => prompt.peer;

  Future<_TypedTurnProbe> startWithRunningAdmission({
    _TypedAdmissionEntry? sideEffect,
  }) async {
    switch (sideEffect) {
      case _TypedAdmissionEntry.fsRead:
        prompt.base.fs.readResult = Completer<String>();
        break;
      case _TypedAdmissionEntry.fsWrite:
        prompt.base.fs.writeResult = Completer<void>();
        break;
      case _TypedAdmissionEntry.terminal:
        prompt.base.terminals.createResult =
            Completer<TerminalProcessHandle>();
        break;
      case null:
        break;
    }
    final turn = _TypedTurnProbe(prompt.manager.prompt(
      sessionId: prompt.sessionId,
      content: const <Map<String, dynamic>>[],
    ));
    _activeTurn = turn;
    await prompt.promptSeen.future.timeout(const Duration(seconds: 2));
    final operation = prompt._current!;
    final method = switch (sideEffect) {
      _TypedAdmissionEntry.fsRead || null => 'fs/read_text_file',
      _TypedAdmissionEntry.fsWrite => 'fs/write_text_file',
      _TypedAdmissionEntry.terminal => 'terminal/create',
    };
    final providerIndex = prompt.base.permissions.requests.length;
    await prompt._startBlockedAdmission(operation, method: method);
    if (sideEffect != null) {
      prompt.base.permissions.completeAllow(providerIndex);
      await (switch (sideEffect) {
        _TypedAdmissionEntry.fsRead => prompt.base.fs.readStarted.future,
        _TypedAdmissionEntry.fsWrite => prompt.base.fs.writeStarted.future,
        _TypedAdmissionEntry.terminal =>
          prompt.base.terminals.createStarted.future,
      }).timeout(const Duration(seconds: 2));
    }
    prompt.base.promptWinnerRecordedForTesting(operation.owner).then<void>((_) {
      if (!turn.winnerRecorded.isCompleted) turn.winnerRecorded.complete();
    });
    prompt.base.promptRightRecordedForTesting(operation.owner).then<void>((_) {
      if (!turn.rightRecorded.isCompleted) turn.rightRecorded.complete();
    });
    prompt.base.promptBarrierReleasedForTesting(operation.owner).then<void>((_) {
      if (!turn.barrierReleased.isCompleted) turn.barrierReleased.complete();
    });
    prompt.base.promptClaimSeenForTesting(operation.owner).then<void>((_) {
      if (!turn.claimSeen.isCompleted) turn.claimSeen.complete();
    });
    return turn;
  }

  bool sideEffectStarted(_TypedAdmissionEntry entry) => switch (entry) {
    _TypedAdmissionEntry.fsRead => prompt.base.fs.readCalls == 1,
    _TypedAdmissionEntry.fsWrite => prompt.base.fs.writeCalls == 1,
    _TypedAdmissionEntry.terminal => prompt.base.terminals.createCalls == 1,
  };

  void respondPrompt({required String stopReason}) {
    prompt.respondPromptSuccess(stopReason: stopReason);
  }

  void respondPromptError({required int code, required String message}) {
    prompt.respondPromptError(code: code, message: message);
  }

  void firePromptDeadline() {
    prompt.peer.firePromptDeadlineForTesting(prompt._current!.owner);
  }

  Future<_TypedTurnProbe> startClaimRace(_TypedClaimRace scenario) async {
    final turn = await startWithRunningAdmission();
    if (scenario == _TypedClaimRace.closeBeforeClaim) {
      unawaited(prompt.base.holdPromptPreclaimForTesting(
        prompt._current!.owner,
      ));
    }
    return turn;
  }

  Future<void> runClaimRace(
    _TypedTurnProbe turn,
    _TypedClaimRace scenario,
  ) async {
    switch (scenario) {
      case _TypedClaimRace.closeBeforeClaim:
        prompt.respondPromptSuccess();
        await turn.winnerRecorded.future;
        await turn.rightRecorded.future;
        await prompt.base.releaseAdmissionAndCommitForTesting(prompt._current!);
        await turn.barrierReleased.future;
        await prompt.base.holdPromptPreclaimForTesting(
          prompt._current!.owner,
        );
        await prompt.peer.close();
        prompt.base.releasePromptPreclaimForTesting(prompt._current!.owner);
        break;
      case _TypedClaimRace.claimBeforeClose:
        prompt.respondPromptSuccess();
        await turn.winnerRecorded.future;
        await turn.rightRecorded.future;
        await prompt.base.releaseAdmissionAndCommitForTesting(prompt._current!);
        await turn.barrierReleased.future;
        await turn.claimSeen.future;
        await prompt.peer.close();
        break;
      case _TypedClaimRace.otherOwnerFatal:
        await prompt.peer.closeForFatalTimeout(
          cleanupIdentity: AcpPromptCleanupIdentity(Object(), 1),
        );
        break;
      case _TypedClaimRace.sameOwnerCleanupAfterWinner:
        prompt.respondPromptSuccess();
        await turn.winnerRecorded.future;
        await turn.rightRecorded.future;
        await prompt.base.expireAdmissionResponseGraceForTesting();
        await turn.cleanupFatalSeen.future;
        break;
      case _TypedClaimRace.sameOwnerAdmissionFatalBeforeWinner:
        await prompt.base.completePermissionAndBlockCommitForTesting(
          prompt._current!,
        );
        await prompt.base.expireAdmissionResponseGraceForTesting();
        await turn.cleanupFatalSeen.future;
        prompt.respondPromptSuccess();
        break;
    }
    await turn.done.future.timeout(const Duration(seconds: 2));
  }

  Future<void> runUnavailableFirst(
    _TypedTurnProbe turn,
    _TypedUnavailableFirst cause,
  ) async {
    switch (cause) {
      case _TypedUnavailableFirst.transportClosed:
        await prompt.peer.closeForTesting(
          AcpPeerUnavailableReason.transportClosed,
        );
        break;
      case _TypedUnavailableFirst.requestFatal:
        await prompt.peer.closeForFatalTimeout();
        break;
      case _TypedUnavailableFirst.explicitClose:
        await prompt.peer.close();
        break;
      case _TypedUnavailableFirst.dispose:
        await prompt.base.manager.dispose();
        break;
    }
    prompt.respondPromptSuccess();
    await turn.done.future.timeout(const Duration(seconds: 2));
  }

  Future<void> dispose() async {
    final read = prompt.base.fs.readResult;
    if (read != null && !read.isCompleted) {
      read.completeError(StateError('typed harness disposed'));
    }
    final write = prompt.base.fs.writeResult;
    if (write != null && !write.isCompleted) {
      write.completeError(StateError('typed harness disposed'));
    }
    final terminal = prompt.base.terminals.createResult;
    if (terminal != null && !terminal.isCompleted) {
      terminal.completeError(StateError('typed harness disposed'));
    }
    await _activeTurn?.dispose();
    await prompt.dispose();
  }
}

final class _SessionCloseManagerDriver {
  _SessionCloseManagerDriver(this.base, this.failure);
  final _PermissionAdmissionHarness base;
  final _RemoteCloseFailure failure;

  Future<void> closeSession({required String sessionId}) async {
    if (failure == _RemoteCloseFailure.peerFatal) {
      await base.peer.closeForFatalTimeout();
      await base.manager.closeSession(sessionId: sessionId);
      throw const AcpConnectionClosedException();
    }
    return base.manager.closeSession(sessionId: sessionId);
  }
}

final class _SessionCloseHarness {
  _SessionCloseHarness._(this.base, this.failure)
      : manager = _SessionCloseManagerDriver(base, failure) {
    _fatalListener = (state) {
      if (state.reason == AcpPeerUnavailableReason.fatalTimeout) {
        fatalCloseCount += 1;
      }
    };
    base.peer.addUnavailableListener(_fatalListener);
  }

  static Future<_SessionCloseHarness> start({
    required _RemoteCloseFailure failure,
  }) async {
    final base = await _PermissionAdmissionHarness.start(
      timeouts: const AcpTimeouts(
        request: Duration(milliseconds: 75),
        promptCancelGrace: Duration(milliseconds: 75),
      ),
    );
    final harness = _SessionCloseHarness._(base, failure);
    if (failure == _RemoteCloseFailure.remoteAndCleanupError) {
      base.terminals.releaseThrows = true;
    }
    await base.configureRemoteSessionCloseFailureForTesting(failure.name);
    return harness;
  }

  final _PermissionAdmissionHarness base;
  final _RemoteCloseFailure failure;
  final _SessionCloseManagerDriver manager;
  late final AcpPeerUnavailableListener _fatalListener;
  int fatalCloseCount = 0;
  String get sessionId => base.sessionId;
  int get cleanupWindowStartCount =>
      base.manager.admissionCleanupWindowStartCountForTesting;
  int get remoteCloseCalls => base.remoteCloseCallsForTesting;
  Set<String> get remainingLocalState =>
      base.manager.localSessionStateKeysForTesting(sessionId);
  int get pendingPermissionCount =>
      base.manager.pendingPermissionCountForTesting(sessionId);
  int get pendingTerminalLeaseCount =>
      base.manager.pendingTerminalLeaseCountForTesting(sessionId);
  int get sessionCloseSelectionCount =>
      base.manager.sessionCloseSelectionCountForTesting(sessionId);
  bool get ownerlessSideEffectStarted => base.fs.readCalls == 1;

  Future<void> populateEverySessionState() =>
      base.populateEverySessionStateForTesting();

  Future<void> startOwnerlessRunningAdmission() =>
      base.startOwnerlessRunningAdmissionForTesting();

  void failNextPrepareSynchronously(
    Object error,
    StackTrace stackTrace,
  ) => base.manager.failNextSessionClosePrepareSynchronouslyForTesting(
    error,
    stackTrace,
  );

  Future<void> dispose() async {
    try {
      await base.dispose();
    } finally {
      base.peer.removeUnavailableListener(_fatalListener);
    }
  }
}
```

同一 RED 提交把以下 driver 直接加进 `_PermissionAdmissionHarness`；把 Task 6 的 `_wireSubscription` 从 `late final` 改成 `late`，以便 close fixture 在 session 已建立后替换 wire responder。driver 只通过真实 wire、Task 7 timer callback 与 fake providers 建立/观察状态，不直接完成生产 lifecycle completer：

```dart
String? _remoteSessionCloseFailure;
int _remoteCloseCalls = 0;
_PermissionRequestProbe? _ownerlessCloseAdmission;

Future<void> configureRemoteSessionCloseFailureForTesting(String failure) async {
  _remoteSessionCloseFailure = failure;
  if (failure == _RemoteCloseFailure.peerFatal.name) return;
  await _wireSubscription.cancel();
  _wireSubscription = channel.local.stream.listen(_onTask10Wire);
}

int get remoteCloseCallsForTesting => _remoteCloseCalls;

void _onTask10Wire(String line) {
  final decoded = jsonDecode(line);
  if (decoded is! Map) return;
  final message = Map<String, dynamic>.from(decoded);
  if (message['method'] != 'session/close') {
    _acceptWireMap(message);
    return;
  }
  _remoteCloseCalls += 1;
  switch (_remoteSessionCloseFailure) {
    case 'remoteError':
    case 'remoteAndCleanupError':
    case 'ownerlessAdmission':
      channel.local.sink.add(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'error': <String, dynamic>{
          'code': -32000,
          'message': 'fixed session close failure',
        },
      }));
      break;
    case 'requestTimeout':
      break;
    default:
      throw StateError('Unexpected close failure driver.');
  }
}

Future<void> populateEverySessionStateForTesting() async {
  manager.sessionUpdates(sessionId).listen((_) {});
  await manager.resumeSession(
    sessionId: sessionId,
    workspaceRoot: '/tmp',
    additionalDirectories: const <String>['/tmp/additional'],
  );
  peer.dispatchSessionUpdateForTesting(<String, dynamic>{
    'sessionId': sessionId,
    'update': <String, dynamic>{
      'sessionUpdate': 'current_mode_update',
      'currentModeId': 'fixed-mode',
    },
  });
  peer.dispatchSessionUpdateForTesting(<String, dynamic>{
    'sessionId': sessionId,
    'update': <String, dynamic>{
      'sessionUpdate': 'tool_call',
      'toolCallId': 'fixed-tool',
      'title': 'fixed tool',
      'status': 'pending',
    },
  });
  final fsIndex = permissions.requests.length;
  final fsRequest = await admit('fs/read_text_file');
  await permissions.waitForRequest(fsIndex);
  permissions.completeAllow(fsIndex);
  await fsRequest.response;
  final terminalIndex = permissions.requests.length;
  final terminalRequest = await admit('terminal/create');
  await permissions.waitForRequest(terminalIndex);
  permissions.completeAllow(terminalIndex);
  await terminalRequest.response;
}

Future<void> startOwnerlessRunningAdmissionForTesting() async {
  fs.readResult = Completer<String>();
  final releaseSibling = Completer<void>();
  peer.onTerminalOutput = (_) async {
    await releaseSibling.future;
    return <String, dynamic>{'output': '', 'truncated': false};
  };
  final index = permissions.requests.length;
  final permissionId = _nextId++;
  final siblingId = _nextId++;
  final permissionReply = Completer<_RpcReply>();
  final siblingReply = Completer<_RpcReply>();
  final admission = _PermissionRequestProbe(permissionId, permissionReply);
  _ownerlessCloseAdmission = admission;
  _responses[permissionId] = permissionReply;
  _responses[siblingId] = siblingReply;
  _admissionQueue.add(admission);
  channel.local.sink.add(jsonEncode(<Object?>[
    <String, dynamic>{
      'jsonrpc': '2.0',
      'id': permissionId,
      'method': 'fs/read_text_file',
      'params': paramsFor('fs/read_text_file'),
    },
    <String, dynamic>{
      'jsonrpc': '2.0',
      'id': siblingId,
      'method': 'terminal/output',
      'params': <String, dynamic>{'sessionId': sessionId},
    },
  ]));
  await admission.admissionSeen.future;
  await permissions.waitForRequest(index);
  permissions.completeAllow(index);
  await fs.readStarted.future.timeout(const Duration(seconds: 2));
}

void failNextSessionCloseReapForTesting(
  _SessionCloseReapSource source,
  Object error,
  StackTrace stackTrace,
) {
  switch (source) {
    case _SessionCloseReapSource.admission:
      manager.failNextSessionCloseAdmissionReapForTesting(error, stackTrace);
      break;
    case _SessionCloseReapSource.prompt:
      manager.failNextSessionClosePromptReapForTesting(error, stackTrace);
      break;
  }
}

AcpSessionInputBudgetOwner activePromptOwnerForTesting(String sessionId) =>
    manager.activePromptOwnerForTesting(sessionId);
Future<Map<String, dynamic>> promptResultForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.promptResultForTesting(owner);
Future<void> promptWinnerRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.promptWinnerRecordedForTesting(owner);
Future<void> promptRightRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.promptRightRecordedForTesting(owner);
Future<void> promptBarrierReleasedForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.promptBarrierReleasedForTesting(owner);
Future<void> promptClaimSeenForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.promptClaimSeenForTesting(owner);
Future<void> holdPromptPreclaimForTesting(
  AcpSessionInputBudgetOwner owner,
) => manager.holdPromptPreclaimForTesting(owner);
void releasePromptPreclaimForTesting(AcpSessionInputBudgetOwner owner) =>
    manager.releasePromptPreclaimForTesting(owner);

Future<void> releaseAdmissionAndCommitForTesting(
  _PromptOperationProbe operation,
) async {
  permissions.finishPending();
  releaseOrdinaryPermits();
  final blocker = operation.responseCommitBlocker;
  if (blocker != null && !blocker.isCompleted) blocker.complete();
  await operation.admission?.responseCommitted.future;
}

Future<void> completePermissionAndBlockCommitForTesting(
  _PromptOperationProbe operation,
) async {
  final admission = operation.admission!;
  final providerIndex = permissions.requests.length - 1;
  permissions.completeAllow(providerIndex);
  await admission.reservationReleased.future;
  if (operation.responseCommitBlocker?.isCompleted ?? false) {
    throw StateError('Batch response commit blocker was released too early.');
  }
  if (admission.responseCommitCount != 0) {
    throw StateError('Batch response committed before grace expiry.');
  }
}

Future<void> expireAdmissionResponseGraceForTesting() async {
  final unavailable = Completer<AcpPeerUnavailableState>();
  void listener(AcpPeerUnavailableState state) {
    if (state.reason == AcpPeerUnavailableReason.fatalTimeout &&
        !unavailable.isCompleted) {
      unavailable.complete(state);
    }
  }
  peer.addUnavailableListener(listener);
  final identity =
      manager.admissionCleanupWindowIdentitiesForTesting.single;
  final callback =
      manager.admissionCleanupWindowTimerCallbackForTesting(identity);
  callback();
  await unavailable.future;
  peer.removeUnavailableListener(listener);
}
```

组合 RED 另给 `_PermissionAdmissionHarness.start` 与 `_PromptLifecycleHarness.start` 增加默认值仍为 1 的 `maxOrdinaryConcurrentHandlers` 参数，并由 `_PromptLifecycleHarness.start` 把该值原样传给底层 `_PermissionAdmissionHarness.start`。下面两个需要 ownerless blocker 与 active prompt/owner-scoped blocker 并行存在的测试必须在调用 `_PromptLifecycleHarness.start` 时显式传 `maxOrdinaryConcurrentHandlers: 2`；Task 6/11 已固定底层 total=`ordinary + 2`，所以这两处实际使用 total 4，不能只改默认值、依赖隐式 fixture 状态或恢复非法 `2/1`。`startActivePromptWithEarlierOwnerlessWindowForTesting` 必须按真实顺序：先用 `_PermissionBatchHarness._(base).sendBlockedBatch(ownerScoped: false, ...)` 建立 ownerless response window并等待 reservation release，保存 identity/deadline/callback；再间隔 10ms 启动真实 prompt与其 owner-scoped blocked admission，等待第二个 reservation release并保存 prompt window identity/deadline/callback。返回的 `promptOwner` 必须来自 production lifecycle。不得写 window map、改 deadline、直接完成 blocker或伪造 callback；两个 sibling 在 cleanup fatal 后走真实 peer unavailable 才 reap，因此 close 合并后唯一 window 的 blocker 数应为 ownerless admission、owner-scoped admission、close 的 `localReaped` 三个。

`startActivePromptWithEarlierOwnerlessWindowButNoOwnerWindowForTesting` 复用同一 ownerless 建窗步骤，但随后只启动真实 prompt并等 `session/prompt` 已发出，不创建 owner-scoped admission、也不触发 prompt terminal；close 前必须断言 map 中只有 ownerless identity、start count为1且 `fatalOwner == null`。这条 fixture专门证明 close frozen selection 能被 prompt lifecycle cleanup resolver复用，不能靠“预先已有 owner window”偶然通过。

串行 RED 的 delayed setup/replacement driver 只扣住并释放真实 `session/load`、`session/resume` 与 `session/close` wire reply；`requestSeen`、`done` 和 generation/state 都读生产对象。`replayCapturedRollbackForTesting` 只重放 setup 开始时捕获的 production rollback identity 检查，不能直接删 map；旧 cleanup callback同样必须是 Task 7 window 原 callback。由此 RED 能证明 queue 顺序与 stale identity 防护，而不是测试 completer伪造状态。

另外为 typed driver 增加只读同步投影：`activePromptOwnerForTesting`、`promptResultForTesting`、`promptWinnerRecordedForTesting`、`promptRightRecordedForTesting`、`promptBarrierReleasedForTesting`、`promptClaimSeenForTesting` 与 `releaseAdmissionAndCommitForTesting`。前六个只返回生产 lifecycle 已有 Future/identity；最后一个只释放 `_PromptOperationProbe.responseCommitBlocker` 并等待其真实 `responseCommitted`，不得伪造 winner、right、barrier 或 claim。这样旧实现的 RED 来自 close/prompt 行为，而不是 fixture 符号缺失。

- [ ] 1. 写 named RED `typed prompt preserves success across its cleanup fatal`，让 prompt success 先登记 winner，running admission 超过 grace 触发同 owner cleanup fatal；typed stream 精确收到一次原 stop reason 的 `TurnEnded` 后 done：

```dart
test('typed prompt preserves success across its cleanup fatal', () async {
  for (final entry in _TypedAdmissionEntry.values) {
    final harness = await _TypedPromptHarness.start();
    try {
      final turn = await harness.startWithRunningAdmission(sideEffect: entry);
      expect(harness.sideEffectStarted(entry), isTrue);
      harness.respondPrompt(stopReason: 'end_turn');
      await turn.cleanupFatalSeen.future;
      final events = await turn.events.timeout(const Duration(seconds: 2));
      final terminals = events.whereType<TurnEnded>().toList();
      expect(terminals, hasLength(1));
      expect(terminals.single.stopReason, StopReason.endTurn);
      expect(turn.errors, isEmpty);
      expect(turn.streamDoneCount, 1);
      expect(harness.peer.isAvailable, isFalse);
    } finally {
      await harness.dispose();
    }
  }
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves success across its cleanup fatal"`。Expected: FAIL；旧共享 session stream 会在 unavailable 时丢 terminal。

- [ ] 3. 写 named RED `typed prompt preserves remote error across its cleanup fatal`；远端 error 先登记，cleanup fatal 后只投原 error与一次 `TurnEnded(other)`，不得出现 connection-closed：

```dart
test('typed prompt preserves remote error across its cleanup fatal', () async {
  for (final entry in _TypedAdmissionEntry.values) {
    final harness = await _TypedPromptHarness.start();
    try {
      final turn = await harness.startWithRunningAdmission(sideEffect: entry);
      expect(harness.sideEffectStarted(entry), isTrue);
      harness.respondPromptError(code: -32000, message: 'fixed remote error');
      await turn.cleanupFatalSeen.future;
      final events = await turn.events.timeout(const Duration(seconds: 2));
      expect(turn.errors, hasLength(1));
      expect(turn.errors.single.toString(), contains('fixed remote error'));
      expect(turn.errors.whereType<AcpConnectionClosedException>(), isEmpty);
      final terminals = events.whereType<TurnEnded>().toList();
      expect(terminals, hasLength(1));
      expect(terminals.single.stopReason, StopReason.other);
      expect(turn.streamDoneCount, 1);
    } finally {
      await harness.dispose();
    }
  }
});

test('typed prompt preserves timeout across its cleanup fatal', () async {
  final harness = await _TypedPromptHarness.start();
  try {
    final turn = await harness.startWithRunningAdmission(
      sideEffect: _TypedAdmissionEntry.fsRead,
    );
    harness.firePromptDeadline();
    await turn.winnerRecorded.future;
    await turn.rightRecorded.future;
    await turn.cleanupFatalSeen.future;
    final events = await turn.events.timeout(const Duration(seconds: 2));
    expect(turn.errors, hasLength(1));
    expect(turn.errors.single, isA<AcpPromptTimeoutException>());
    final terminals = events.whereType<TurnEnded>().toList();
    expect(terminals, hasLength(1));
    expect(terminals.single.stopReason, StopReason.other);
    expect(turn.connectionClosedCount, 0);
    expect(turn.streamDoneCount, 1);
  } finally {
    await harness.dispose();
  }
});

test('raw owner bound prompt preserves cached winner without a typed turn', () async {
  final harness = await _PromptLifecycleHarness.start(
    grace: const Duration(milliseconds: 75),
  );
  try {
    final operation = await harness.startPromptWithBlockedAdmissionCommit();
    harness.respondPromptSuccess(stopReason: 'end_turn');
    await harness.base.promptWinnerRecordedForTesting(operation.owner);
    await harness.base.promptRightRecordedForTesting(operation.owner);
    expect(
      await operation.promptResult.timeout(const Duration(seconds: 2)),
      <String, dynamic>{'stopReason': 'end_turn'},
    );
    final snapshot = harness.base.manager
        .promptLifecycleSnapshotForTesting(operation.owner);
    expect(snapshot.winner?.kind, JsonRpcPromptTerminalKind.response);
    expect(snapshot.hasDeliveryRight, isTrue);
    expect(snapshot.cleanupIdentity?.ownerToken, same(operation.owner));
    expect(harness.peer.isAvailable, isFalse);
  } finally {
    await harness.dispose();
  }
});
```

- [ ] 4. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves remote error across its cleanup fatal"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves timeout across its cleanup fatal"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw owner bound prompt preserves cached winner without a typed turn"`。Expected: FAIL；旧 owner 失效后丢缓存 error/timeout，且无 typed turn 的 raw lifecycle 会被 unavailable listener 错误撤销。

- [ ] 5. 写 named RED `typed external close and terminal claim are first wins`，参数化 close-before-claim、claim-before-close、其他 owner fatal、同 owner cleanup fatal、同 owner admission-fatal-before-winner。最后一类即使 cleanup identity 相同也不得补签 right：

```dart
test('typed external close and terminal claim are first wins', () async {
  for (final scenario in _TypedClaimRace.values) {
    final harness = await _TypedPromptHarness.start();
    try {
      final turn = await harness.startClaimRace(scenario);
      await harness.runClaimRace(turn, scenario);
      await turn.done.future.timeout(const Duration(seconds: 2));
      expect(turn.streamDoneCount, 1);
      expect(turn.terminalDeliveryCount + turn.connectionClosedCount, 1);
      if (scenario == _TypedClaimRace.sameOwnerCleanupAfterWinner ||
          scenario == _TypedClaimRace.claimBeforeClose) {
        expect(turn.terminalDeliveryCount, 1);
      } else {
        expect(turn.connectionClosedCount, 1);
      }
    } finally {
      await harness.dispose();
    }
  }
});

test('typed unavailable before terminal is fixed connection closed once', () async {
  for (final cause in _TypedUnavailableFirst.values) {
    final harness = await _TypedPromptHarness.start();
    try {
      final turn = await harness.startWithRunningAdmission();
      await harness.runUnavailableFirst(turn, cause);
      final expectedPermissionReason =
          cause == _TypedUnavailableFirst.dispose
              ? PermissionCancellationReason.disposed
              : PermissionCancellationReason.connectionClosed;
      expect(turn.connectionClosedCount, 1);
      expect(turn.terminalDeliveryCount, 0);
      expect(turn.streamDoneCount, 1);
      expect(turn.claimSeen.isCompleted, isFalse);
      expect(
        harness.prompt.base.permissions.cancellations.single.$2,
        expectedPermissionReason,
      );
      expect(
        harness.prompt.base.manager
            .promptLifecycleSnapshotForTesting(harness.prompt._current!.owner)
            .cancellationWinner,
        expectedPermissionReason,
      );
    } finally {
      await harness.dispose();
    }
  }
});
```

- [ ] 6. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed external close and terminal claim are first wins"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed unavailable before terminal is fixed connection closed once"`。Expected: FAIL；缺 pending/claimed/revoked 原子状态，且 unavailable reason 尚未统一映射到 admission/provider/lifecycle（dispose→disposed，其余→connectionClosed）。

- [ ] 7. 写 named RED `session close cleans local state in finally after remote failure`，覆盖远端 error、request timeout、ownerless admission 永不返回、peer 已 fatal，以及远端 error 与 terminal cleanup error 同时发生；一个共享 grace 后 stream/replay/workspace/additional directories/provider/mode/registration/tool/input/permission/generation/terminal 全清空，双失败时固定由 `SessionCloseCleanupException` 获胜：

```dart
test('session close cleans local state in finally after remote failure', () async {
  for (final failure in _RemoteCloseFailure.values) {
    final harness = await _SessionCloseHarness.start(failure: failure);
    try {
      await harness.populateEverySessionState();
      if (failure == _RemoteCloseFailure.ownerlessAdmission) {
        await harness.startOwnerlessRunningAdmission();
        expect(harness.ownerlessSideEffectStarted, isTrue);
      }
      Object? closeError;
      try {
        await harness.manager.closeSession(sessionId: harness.sessionId);
      } on Object catch (error) {
        closeError = error;
      }
      expect(closeError, isNotNull);
      if (failure == _RemoteCloseFailure.remoteAndCleanupError) {
        expect(
          closeError,
          isA<SessionCloseCleanupException>().having(
            (error) => error.failedStages,
            'failedStages',
            contains('terminals'),
          ),
        );
        expect(closeError.toString(), isNot(contains('fixed session close failure')));
      }
      if (failure == _RemoteCloseFailure.ownerlessAdmission ||
          failure == _RemoteCloseFailure.peerFatal) {
        expect(closeError, isA<AcpConnectionClosedException>());
      }
      expect(harness.cleanupWindowStartCount, 1);
      expect(
        harness.remoteCloseCalls,
        failure == _RemoteCloseFailure.peerFatal ||
                failure == _RemoteCloseFailure.ownerlessAdmission
            ? 0
            : 1,
      );
      expect(harness.remainingLocalState, isEmpty);
      expect(harness.pendingPermissionCount, 0);
      expect(harness.pendingTerminalLeaseCount, 0);
    } finally {
      await harness.dispose();
    }
  }
});
```

同一步先给 `SessionManager` 加只负责 arm、尚不触发的 RED 编译脚手架，避免测试因缺符号而失败。Step 13 才在 `_prepareSessionClose` 的同步前缀消费它；RED 阶段旧 close 会继续走远端 error，因此失败来自错误对象/stack、远端调用次数与清理行为，而不是 compile error：

```dart
({Object error, StackTrace stackTrace})?
    _nextSessionClosePrepareFailureForTesting;

@visibleForTesting
void failNextSessionClosePrepareSynchronouslyForTesting(
  Object error,
  StackTrace stackTrace,
) {
  if (_nextSessionClosePrepareFailureForTesting != null) {
    throw StateError('Session close prepare failure is already armed.');
  }
  _nextSessionClosePrepareFailureForTesting = (
    error: error,
    stackTrace: stackTrace,
  );
}

int sessionCloseSelectionCountForTesting(String sessionId) =>
    _frozenSessionCleanupWindowSelections.containsKey(sessionId) ? 1 : 0;
```

随后写 named RED `session close cleans local state after synchronous prepare failure`。专用注错点必须在 `_prepareSessionClose` 的同步前缀内以 `Error.throwWithStackTrace` 抛出，不能返回 error Future；它只确定性模拟 prepare 内任意同步异常，不替换真实 provider cancellation 路径。断言外层 close 原样保留该 error/stack、完全不发远端 close，并把全部本地状态、closing owner、普通/frozen cleanup selection 清零。

同一步再写 named RED `session close preserves admission and prompt reap errors unless local cleanup fails`。注错点只包装真实 admission `settled` 或 prompt `cleanup.reaped`：必须先等待原 source 真实完成，再用指定 error/stack 结束包装 Future；不得直接 complete admission、prompt、window 或 close completer。两个 source 都分别覆盖本地 cleanup 成功/失败：成功时 close 原对象、原 stack 重抛 reap error；失败时只抛 `SessionCloseCleanupException`，且异常文本不含 reap error/stack：

```dart
Future<({Object error, StackTrace stackTrace})> _captureCloseFailure(
  Future<void> closing,
) async {
  try {
    await closing;
  } on Object catch (error, stackTrace) {
    return (error: error, stackTrace: stackTrace);
  }
  throw StateError('Expected session close to fail.');
}

test('session close cleans local state after synchronous prepare failure',
    () async {
  final harness = await _SessionCloseHarness.start(
    failure: _RemoteCloseFailure.remoteError,
  );
  final injectedError = StateError('fixed synchronous prepare failure');
  final stackMarker = 'fixed-synchronous-prepare-stack';
  final injectedStackTrace = StackTrace.fromString(stackMarker);
  try {
    await harness.populateEverySessionState();
    harness.failNextPrepareSynchronously(
      injectedError,
      injectedStackTrace,
    );

    final captured = await _captureCloseFailure(
      harness.manager.closeSession(sessionId: harness.sessionId),
    );
    expect(captured.error, same(injectedError));
    expect(captured.stackTrace.toString(), contains(stackMarker));
    expect(harness.remoteCloseCalls, 0);
    expect(harness.remainingLocalState, isEmpty);
    expect(harness.sessionCloseSelectionCount, 0);
  } finally {
    await harness.dispose();
  }
});

test(
  'session close preserves admission and prompt reap errors unless local cleanup fails',
  () async {
    for (final source in _SessionCloseReapSource.values) {
      for (final localCleanupFails in <bool>[false, true]) {
        final injectedError = StateError('fixed ${source.name} reap failure');
        final stackMarker = 'fixed-${source.name}-reap-stack';
        final injectedStackTrace = StackTrace.fromString(stackMarker);

        if (source == _SessionCloseReapSource.admission) {
          final harness = await _SessionCloseHarness.start(
            failure: _RemoteCloseFailure.ownerlessAdmission,
          );
          try {
            await harness.populateEverySessionState();
            await harness.startOwnerlessRunningAdmission();
            harness.base.failNextSessionCloseReapForTesting(
              source,
              injectedError,
              injectedStackTrace,
            );
            harness.base.terminals.releaseThrows = localCleanupFails;

            final captured = await _captureCloseFailure(
              harness.manager.closeSession(sessionId: harness.sessionId),
            );
            if (localCleanupFails) {
              expect(captured.error, isA<SessionCloseCleanupException>());
              expect(captured.error.toString(), isNot(contains(stackMarker)));
            } else {
              expect(captured.error, same(injectedError));
              expect(captured.stackTrace.toString(), contains(stackMarker));
            }
            expect(harness.remainingLocalState, isEmpty);
          } finally {
            await harness.dispose();
          }
          continue;
        }

        final harness = await _PromptLifecycleHarness.start(
          grace: const Duration(milliseconds: 75),
        );
        try {
          await harness.base.populateEverySessionStateForTesting();
          final operation = await harness._startPrompt();
          await operation.promptSeen.future.timeout(const Duration(seconds: 2));
          harness.base.failNextSessionCloseReapForTesting(
            source,
            injectedError,
            injectedStackTrace,
          );
          harness.base.terminals.releaseThrows = localCleanupFails;

          final captured = await _captureCloseFailure(
            harness.base.manager.closeSession(sessionId: harness.sessionId),
          );
          if (localCleanupFails) {
            expect(captured.error, isA<SessionCloseCleanupException>());
            expect(captured.error.toString(), isNot(contains(stackMarker)));
          } else {
            expect(captured.error, same(injectedError));
            expect(captured.stackTrace.toString(), contains(stackMarker));
          }
          expect(
            harness.base.manager.localSessionStateKeysForTesting(
              harness.sessionId,
            ),
            isEmpty,
          );
        } finally {
          await harness.dispose();
        }
      }
    }
  },
);
```

同一步写 named RED `admission prompt and close share one owner cleanup callback`，在同一测试内跑两个独立子流程。第一条必须真实覆盖 ownerless admission仍在运行 → 调用 close 时 `_beginSessionClose` 先冻结 selection → `_prepareSessionClose` 结算 admission并促使 reservation release → admission grace按 frozen key加入同一 window；因此测试必须先调用 close，再读取唯一 window。第二条继续覆盖 owner-scoped admission → prompt terminal → close。每条子流程都保存其唯一 callback，触发一次 fatal，并在完全 reaped 后重放旧 callback；各自的 start count、有效 callback count、fatal close count始终都是1：

同一步另写 named RED `session close routes prompt cleanup to a frozen ownerless key`：更早 ownerless window存在，随后只启动 active prompt但不创建 owner window；close必须先冻结 ownerless key，prompt reap、ownerless admission与close blocker全加入同一 identity，start/callback/fatal各1且 deadline不变。触发 fatal后 close固定抛 `AcpConnectionClosedException`，本地状态仍清空，旧 callback重放无效。

```dart
test('admission prompt and close share one owner cleanup callback', () async {
  final ownerless = await _SessionCloseHarness.start(
    failure: _RemoteCloseFailure.ownerlessAdmission,
  );
  try {
    await ownerless.startOwnerlessRunningAdmission();
    final manager = ownerless.base.manager;
    final closing = ownerless.manager.closeSession(
      sessionId: ownerless.sessionId,
    );
    final identity =
        manager.admissionCleanupWindowIdentitiesForTesting.single;
    final oldCallback =
        manager.admissionCleanupWindowTimerCallbackForTesting(identity);
    expect(manager.admissionCleanupWindowStartCountForTesting, 1);
    expect(manager.admissionCleanupWindowCountForTesting, 1);

    oldCallback();
    Object? closeError;
    try {
      await closing.timeout(const Duration(seconds: 2));
    } on Object catch (error) {
      closeError = error;
    }
    expect(closeError, isA<AcpConnectionClosedException>());
    expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
    expect(ownerless.fatalCloseCount, 1);
    expect(manager.admissionCleanupWindowCountForTesting, 0);

    oldCallback();
    await pumpEventQueue().timeout(const Duration(seconds: 2));
    expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
    expect(ownerless.fatalCloseCount, 1);
  } finally {
    await ownerless.dispose();
  }

  final harness = await _PromptLifecycleHarness.start(
    grace: const Duration(milliseconds: 75),
  );
  var promptFatalCloseCount = 0;
  late final AcpPeerUnavailableListener promptFatalListener;
  promptFatalListener = (state) {
    if (state.reason == AcpPeerUnavailableReason.fatalTimeout) {
      promptFatalCloseCount += 1;
    }
  };
  harness.base.peer.addUnavailableListener(promptFatalListener);
  try {
    final operation = await harness._startPrompt();
    await harness._startBlockedAdmission(operation);
    harness.base.permissions.completeAllow(
      harness.base.permissions.pending.length - 1,
    );
    await operation.admissionReservationReleased.future.timeout(
      const Duration(seconds: 2),
    );
    final manager = harness.base.manager;
    final identity =
        manager.admissionCleanupWindowIdentitiesForTesting.single;
    final oldCallback =
        manager.admissionCleanupWindowTimerCallbackForTesting(identity);
    expect(manager.admissionCleanupWindowStartCountForTesting, 1);

    harness.respondPromptSuccess();
    await manager.promptWinnerRecordedForTesting(operation.owner).timeout(
      const Duration(seconds: 2),
    );
    final closing = manager.closeSession(sessionId: harness.sessionId);
    expect(manager.admissionCleanupWindowStartCountForTesting, 1);

    oldCallback();
    await expectLater(
      closing.timeout(const Duration(seconds: 2)),
      throwsA(isA<AcpConnectionClosedException>()),
    );
    expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
    expect(promptFatalCloseCount, 1);
    expect(manager.admissionCleanupWindowCountForTesting, 0);

    oldCallback();
    await pumpEventQueue().timeout(const Duration(seconds: 2));
    expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
    expect(promptFatalCloseCount, 1);
  } finally {
    try {
      await harness.dispose();
    } finally {
      harness.base.peer.removeUnavailableListener(promptFatalListener);
    }
  }
});

test(
  'session close keeps the earliest ownerless window with an active prompt',
  () async {
    final harness = await _PromptLifecycleHarness.start(
      grace: const Duration(milliseconds: 750),
      maxOrdinaryConcurrentHandlers: 2,
    );
    var fatalCloseCount = 0;
    late final AcpPeerUnavailableListener fatalListener;
    fatalListener = (state) {
      if (state.reason == AcpPeerUnavailableReason.fatalTimeout) {
        fatalCloseCount += 1;
      }
    };
    harness.base.peer.addUnavailableListener(fatalListener);
    try {
      final fixture =
          await harness.startActivePromptWithEarlierOwnerlessWindowForTesting();
      final manager = harness.base.manager;
      expect(
        fixture.ownerlessDeadline.isBefore(fixture.promptDeadline),
        isTrue,
      );

      final closing = manager.closeSession(sessionId: harness.sessionId);
      final identities = manager.admissionCleanupWindowIdentitiesForTesting;
      expect(identities, hasLength(1));
      expect(identities.single, same(fixture.ownerlessWindowIdentity));
      expect(
        manager.ownerCleanupWindowDeadlineForTesting(identities.single),
        fixture.ownerlessDeadline,
      );
      expect(
        manager.ownerCleanupWindowFatalOwnerForTesting(identities.single),
        same(fixture.promptOwner),
      );
      expect(
        manager.ownerCleanupWindowBlockerCountForTesting(identities.single),
        3,
      );

      // donor callback 已失去 map identity；最早 window 的旧 callback
      // 仍命中原 identity，既不重排 deadline，也不新建 Timer。
      fixture.promptWindowOldCallback();
      expect(manager.ownerCleanupExpiryCallbackCountForTesting, 0);
      fixture.ownerlessWindowOldCallback();
      await expectLater(
        closing.timeout(const Duration(seconds: 2)),
        throwsA(isA<AcpConnectionClosedException>()),
      );
      expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
      expect(fatalCloseCount, 1);
      expect(manager.admissionCleanupWindowStartCountForTesting, 2);
      expect(manager.admissionCleanupWindowCountForTesting, 0);

      fixture.promptWindowOldCallback();
      fixture.ownerlessWindowOldCallback();
      await pumpEventQueue().timeout(const Duration(seconds: 2));
      expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
      expect(fatalCloseCount, 1);
    } finally {
      try {
        await harness.dispose();
      } finally {
        harness.base.peer.removeUnavailableListener(fatalListener);
      }
    }
  },
);

test(
  'session close routes prompt cleanup to a frozen ownerless key',
  () async {
    final harness = await _PromptLifecycleHarness.start(
      grace: const Duration(milliseconds: 750),
      maxOrdinaryConcurrentHandlers: 2,
    );
    var fatalCloseCount = 0;
    late final AcpPeerUnavailableListener fatalListener;
    fatalListener = (state) {
      if (state.reason == AcpPeerUnavailableReason.fatalTimeout) {
        fatalCloseCount += 1;
      }
    };
    harness.base.peer.addUnavailableListener(fatalListener);
    try {
      final fixture = await harness
          .startActivePromptWithEarlierOwnerlessWindowButNoOwnerWindowForTesting();
      final manager = harness.base.manager;
      expect(manager.admissionCleanupWindowIdentitiesForTesting,
          <Object>{fixture.ownerlessWindowIdentity});
      expect(manager.admissionCleanupWindowStartCountForTesting, 1);
      expect(
        manager.ownerCleanupWindowFatalOwnerForTesting(
          fixture.ownerlessWindowIdentity,
        ),
        isNull,
      );

      final closing = manager.closeSession(sessionId: harness.sessionId);
      expect(manager.admissionCleanupWindowIdentitiesForTesting,
          <Object>{fixture.ownerlessWindowIdentity});
      expect(manager.admissionCleanupWindowStartCountForTesting, 1);
      expect(
        manager.ownerCleanupWindowDeadlineForTesting(
          fixture.ownerlessWindowIdentity,
        ),
        fixture.ownerlessDeadline,
      );
      expect(
        manager.ownerCleanupWindowFatalOwnerForTesting(
          fixture.ownerlessWindowIdentity,
        ),
        same(fixture.promptOwner),
      );
      expect(
        manager.ownerCleanupWindowBlockerCountForTesting(
          fixture.ownerlessWindowIdentity,
        ),
        3,
      );

      fixture.ownerlessWindowOldCallback();
      await expectLater(
        closing.timeout(const Duration(seconds: 2)),
        throwsA(isA<AcpConnectionClosedException>()),
      );
      expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
      expect(fatalCloseCount, 1);
      expect(manager.admissionCleanupWindowCountForTesting, 0);

      fixture.ownerlessWindowOldCallback();
      await pumpEventQueue();
      expect(manager.ownerCleanupExpiryCallbackCountForTesting, 1);
      expect(fatalCloseCount, 1);
    } finally {
      try {
        await harness.dispose();
      } finally {
        harness.base.peer.removeUnavailableListener(fatalListener);
      }
    }
  },
);

test('session close stays serialized across setup and replacement', () async {
  for (final method in <String>['session/load', 'session/resume']) {
    final harness = await _SessionCloseHarness.start(
      failure: _RemoteCloseFailure.remoteError,
    );
    try {
      final setup = harness.base.startDelayedSetupForTesting(method);
      await setup.requestSeen;
      final oldGeneration = harness.base.manager
          .sessionGenerationForTesting(harness.sessionId);
      final closing = harness.manager.closeSession(sessionId: harness.sessionId);
      final replacement = harness.base.startDelayedReplacementForTesting(method);
      expect(harness.base.remoteCloseCallsForTesting, 0);
      expect(replacement.requestSeen.isCompleted, isFalse);

      setup.releaseSuccess();
      await setup.done;
      await harness.base.remoteCloseSeenForTesting;
      expect(replacement.requestSeen.isCompleted, isFalse);
      final oldCleanupCallback =
          harness.base.captureCurrentCleanupCallbackForTesting();

      harness.base.releaseRemoteCloseErrorForTesting();
      await expectLater(closing, throwsA(isA<rpc.RpcException>()));
      await replacement.requestSeen;
      replacement.releaseSuccess();
      await replacement.done;
      final replacementGeneration = harness.base.manager
          .sessionGenerationForTesting(harness.sessionId);
      expect(replacementGeneration, isNot(same(oldGeneration)));

      oldCleanupCallback();
      await setup.replayCapturedRollbackForTesting();
      await pumpEventQueue();
      expect(
        harness.base.manager.sessionGenerationForTesting(harness.sessionId),
        same(replacementGeneration),
      );
      expect(harness.remainingLocalState, containsAll(<String>{
        'workspace',
        'generation',
      }));
    } finally {
      await harness.dispose();
    }
  }
});
```

- [ ] 8. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close cleans local state in finally after remote failure"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close cleans local state after synchronous prepare failure"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close preserves admission and prompt reap errors unless local cleanup fails"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "admission prompt and close share one owner cleanup callback"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close keeps the earliest ownerless window with an active prompt"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close routes prompt cleanup to a frozen ownerless key"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close stays serialized across setup and replacement"`。Expected: FAIL；旧 close 尚不消费同步 prepare 注错，且本地清理只在远端 close 成功分支；原有 `_beginSessionClose` 也位于最外层 `try/finally` 之前，任意 setup 同步抛错会残留本地状态与 cleanup selection。旧实现还会把 admission/prompt reap error 当作 blocker 完成信号吞掉、在 close 后按 admission identity 再建 ownerless window、让 `_settlePromptLifecycle` 绕过 frozen selection按 owner key建第二个 window、以 active prompt 无条件覆盖更早 ownerless deadline，并让远端 close 绕过同 session mutation queue。

- [ ] 9. 增加调用专属 typed sink并复用 Task 9 delivery right。terminal winner 登记后立即取消共享 update subscription并进入 terminal-only；close 方法体幂等：

```dart
final class _TypedPromptTurn {
  _TypedPromptTurn(this.owner, this.controller);
  final AcpSessionInputBudgetOwner owner;
  final StreamController<AcpUpdate> controller;
  StreamSubscription<AcpUpdate>? updates;
  bool terminalOnly = false;
  bool closed = false;
  Future<void>? terminalOnlyFuture;

  Future<void> enterTerminalOnly() =>
      terminalOnlyFuture ??= _enterTerminalOnly();

  Future<void> _enterTerminalOnly() async {
    terminalOnly = true;
    final current = updates;
    updates = null;
    await current?.cancel();
  }
}

Future<void> _deliverTypedPromptWinner(
  _PromptLifecycle lifecycle,
  _TypedPromptTurn turn,
);
void _closeTypedPromptTurn(_TypedPromptTurn turn);
```

- [ ] 10. 实现 `_closeTypedPromptTurn`，先设置 `closed` 再关闭 controller，防止 close/dispose/claim 竞态重复 done：

```dart
void _closeTypedPromptTurn(_TypedPromptTurn turn) {
  if (turn.closed) return;
  turn.closed = true;
  if (identical(_activeTypedTurns[turn.owner], turn)) {
    _activeTypedTurns.remove(turn.owner);
  }
  _closeControllerWithoutWaiting(turn.controller);
}
```

- [ ] 11. 实现 delivery 方法体。barrier 后先 `tryClaim()`；success 直接向专属 sink 投一次 `TurnEnded`，remote error/timeout 投缓存 error 与一次 `TurnEnded(other)`；revoked 不投缓存 terminal。replay 只在相同 session generation 仍登记时追加：

```dart
Future<void> _deliverTypedPromptWinner(
  _PromptLifecycle lifecycle,
  _TypedPromptTurn turn,
) async {
  final preclaim = lifecycle.preclaimBarrierForTesting;
  if (preclaim != null) {
    if (!lifecycle.preclaimReachedForTesting.isCompleted) {
      lifecycle.preclaimReachedForTesting.complete();
    }
    await preclaim.future;
  }
  final right = lifecycle.deliveryRight;
  if (right == null || !right.tryClaim()) return;
  if (!lifecycle.claimSeen.isCompleted) lifecycle.claimSeen.complete();
  await turn.enterTerminalOnly();
  try {
    final winner = right.winner;
    if (winner.kind == JsonRpcPromptTerminalKind.response) {
      final stop = stopReasonFromWire(
        (winner.response?['stopReason'] as String?) ?? 'other',
      );
      final terminal = TurnEnded(stop);
      turn.controller.add(terminal);
      if (_isSameSessionGeneration(lifecycle)) {
        _replayBuffers[lifecycle.owner.sessionId]?.add(terminal);
      }
    } else {
      final error = winner.kind == JsonRpcPromptTerminalKind.timedOut
          ? const AcpPromptTimeoutException()
          : winner.error!;
      turn.controller.addError(error, winner.stackTrace ?? StackTrace.empty);
      const terminal = TurnEnded(StopReason.other);
      turn.controller.add(terminal);
      if (_isSameSessionGeneration(lifecycle)) {
        _replayBuffers[lifecycle.owner.sessionId]?.add(terminal);
      }
    }
  } finally {
    _closeTypedPromptTurn(turn);
    _releasePromptLifecycle(lifecycle);
  }
}

bool _isSameSessionGeneration(_PromptLifecycle lifecycle) {
  final current = _sessionGenerations[lifecycle.owner.sessionId];
  return current != null &&
      current.active &&
      identical(current, lifecycle.sessionGeneration);
}

// Task 9 的 `_releasePromptLifecycle` 是唯一 lifecycle release helper。
```

- [ ] 12. 在 Task 4 unavailable listener 中按 owner token + generation 比较 cleanup identity。只有 same-owner cleanup fatal 且 winner/right 已存在时进入 terminal-only 并保留 right；其他原因撤销 right、投一次固定 connection-closed并关流。方法体固定为：

```dart
PermissionCancellationReason _permissionReasonForUnavailable(
  AcpPeerUnavailableState state,
) => state.reason == AcpPeerUnavailableReason.disposed
    ? PermissionCancellationReason.disposed
    : PermissionCancellationReason.connectionClosed;

void _handlePeerUnavailable(AcpPeerUnavailableState state) {
  // Freeze every existing cleanup window before admission cancellation can
  // synchronously release a blocker, remove a window or expose a stale Timer.
  _markOwnerCleanupWindowsPeerUnavailable();
  if (!_peerEpoch.active) return;
  _peerEpoch.active = false;
  final permissionReason = _permissionReasonForUnavailable(state);
  for (final generation in _sessionGenerations.values) {
    generation.active = false;
  }
  for (final admission in _inboundAdmissions.toList(growable: false)) {
    admission.tryCancel(permissionReason);
    admission.markPeerClosed();
  }

  _handleActiveTypedTurnsUnavailable(state, permissionReason);
  for (final lifecycle in _promptLifecycles.values.toList(growable: false)) {
    if (!_isCurrentPromptLifecycle(lifecycle) ||
        _activeTypedTurns.containsKey(lifecycle.owner)) {
      continue;
    }
    lifecycle.cleanupIdentity = state.cleanupIdentity;
    final cleanup = state.cleanupIdentity;
    final preservesRawWinner =
        state.reason == AcpPeerUnavailableReason.fatalTimeout &&
        cleanup != null &&
        identical(cleanup.ownerToken, lifecycle.owner) &&
        cleanup.generation == lifecycle.owner.generation &&
        lifecycle.winner != null &&
        lifecycle.deliveryRight != null &&
        lifecycle.cleanupFuture != null;
    if (preservesRawWinner) {
      // 无 typed turn 也保留 lifecycle/right，raw caller 由 peer cleanup
      // 投递缓存 winner；不能因 `_activeTypedTurns` 中没有它而撤销。
      continue;
    }
    lifecycle.cancellationWinner ??= permissionReason;
    lifecycle.deliveryRight?.revoke();
    _releasePromptLifecycle(lifecycle);
  }
}

void _handleActiveTypedTurnsUnavailable(
  AcpPeerUnavailableState state,
  PermissionCancellationReason permissionReason,
) {
  for (final entry in _activeTypedTurns.entries.toList(growable: false)) {
    final owner = entry.key;
    final turn = entry.value;
    final lifecycle = _promptLifecycles[owner.sessionId];
    if (lifecycle == null || !identical(lifecycle.owner, owner)) {
      if (!turn.closed) {
        turn.controller.addError(const AcpConnectionClosedException());
        _closeTypedPromptTurn(turn);
      }
      continue;
    }
    _handleTypedPromptUnavailable(
      lifecycle,
      turn,
      state,
      permissionReason,
    );
  }
}

void _handleTypedPromptUnavailable(
  _PromptLifecycle lifecycle,
  _TypedPromptTurn turn,
  AcpPeerUnavailableState state,
  PermissionCancellationReason permissionReason,
) {
  lifecycle.cleanupIdentity = state.cleanupIdentity;
  final right = lifecycle.deliveryRight;
  if (right?.state == _PromptDeliveryRightState.claimed) {
    // delivery 的 finally 负责 close sink 与释放 lifecycle。
    return;
  }
  if (turn.closed) {
    _releasePromptLifecycle(lifecycle);
    return;
  }
  final cleanup = state.cleanupIdentity;
  final preservesWinner =
      state.reason == AcpPeerUnavailableReason.fatalTimeout &&
      cleanup != null &&
      identical(cleanup.ownerToken, lifecycle.owner) &&
      cleanup.generation == lifecycle.owner.generation &&
      lifecycle.winner != null &&
      right != null;
  if (preservesWinner) {
    lifecycle.terminalOnly = true;
    unawaited(turn.enterTerminalOnly());
    return;
  }
  lifecycle.cancellationWinner ??= permissionReason;
  right?.revoke();
  if (!turn.closed) {
    turn.controller.addError(const AcpConnectionClosedException());
    _closeTypedPromptTurn(turn);
  }
  _releasePromptLifecycle(lifecycle);
}
```

`SessionManager` 构造函数在全部字段校验后把 Task 4 唯一 listener 注册为 `_handlePeerUnavailable`；listener 的 late replay 也执行完整 body。完整 handler 的第一项动作固定为 `_markOwnerCleanupWindowsPeerUnavailable()`：先按现有 window identity 取消唯一 Timer、完成 expiry并冻结 peer-unavailable 状态，再检查 peer epoch和遍历 admission执行 `tryCancel/markPeerClosed`；不得在 admission 循环之后保留第二次或旧的后置调用。reason mapper 对 `disposed` 固定生成 `PermissionCancellationReason.disposed`，其余 transport/request fatal/explicit/fatalTimeout 均生成 `connectionClosed`，同一 reason 传给 admission CAS、cancellable provider 与被撤销 lifecycle。处理 typed turn 后，无 typed sink 的 raw lifecycle 仍先按 owner identity+generation 检查：同 owner cleanup fatal且 winner/right/cleanup均已登记时保留，否则才撤销并移除。不得注册第二套 peer listener。

`claimed` 检查必须早于 cleanup identity 与 unavailable reason：claim 已赢后到达的 external close 既不能追加 connection-closed，也不能关闭专属 sink；delivery 的 `finally` 是唯一关流者。transport/request fatal/explicit/dispose/other-owner fatal，以及 admission-fatal-before-winner，全部进入撤销分支；同 cleanup identity 也不能在 winner 迟到后补签 right。

- [ ] 13. 把 `closeSession` 改为以下所有权结构；serialized action 先创建 `closingOwner`，随后用最外层 `try/finally` 同时覆盖同步 `_beginSessionClose`、同步 `_prepareSessionClose`、异步 reap与远端阶段。`_beginSessionClose` 在 action 首个 `await` 前失效 generation并冻结 cleanup key，但完整替换必须删除 Task 6 过渡版本中的 `_settleSessionAdmissionsForClose`；`_prepareSessionClose` 先捕获 admissions identity，再在 frozen selection 已存在的同步前缀调用该 helper恰一次，以 `sessionClosed` 结算并加入 Task 9 共享 reap。任一 begin/prepare 同步异常（包括未被下层隔离的 provider cancel callback 异常）也必须进入同一 error/stack 保存路径，并无条件执行 `_cleanupSessionLocally` 与 `_endSessionClose`。Task 9 已有 `_settlePromptLifecycle` 在本 Task 只做一个最小改动：它的 cleanup key也必须走同一 resolver，不能硬编码 `lifecycle.owner`。远端阶段必须精确读取 Task 4 已定义的 `JsonRpcPeer.isAvailable` getter，禁止新增本地 bool 或 try-send 探测；prepared 后 peer 已 unavailable 时固定抛 `AcpConnectionClosedException`，不能把“跳过远端 close”当成功：

```dart
Object _ownerCleanupKeyForPromptLifecycle(
  _PromptLifecycle lifecycle,
) {
  final frozen =
      _frozenSessionCleanupWindowSelections[lifecycle.owner.sessionId];
  return frozen?.key ?? lifecycle.owner;
}

_OwnerCleanupWindow _joinPromptLifecycleCleanup(
  _PromptLifecycle lifecycle,
  JsonRpcPromptCleanup cleanup,
) {
  final cleanupKey = _ownerCleanupKeyForPromptLifecycle(lifecycle);
  return _getOrJoinOwnerCleanupWindow(
    key: cleanupKey,
    fatalOwner: lifecycle.owner,
    blockerIdentity: lifecycle,
    blockerReaped: cleanup.reaped,
  );
}

// Task 9 `_settlePromptLifecycle` 中只把原 get-or-join block替换为：
// final window = _joinPromptLifecycleCleanup(lifecycle, cleanup);

final Map<Object, ({
  String sessionId,
  Object key,
  AcpSessionInputBudgetOwner? promptOwner,
})>
    _sessionCloseCleanupSelections =
        HashMap<Object, ({
          String sessionId,
          Object key,
          AcpSessionInputBudgetOwner? promptOwner,
        })>.identity();

// 原位替换 Step 7 的 RED 观察 getter；实现后同时计普通与 frozen selection。
int sessionCloseSelectionCountForTesting(String sessionId) {
  var count = _sessionCloseCleanupSelections.values
      .where((selection) => selection.sessionId == sessionId)
      .length;
  if (_frozenSessionCleanupWindowSelections.containsKey(sessionId)) {
    count += 1;
  }
  return count;
}

bool _isOwnerlessCleanupWindowForSession(
  _OwnerCleanupWindow window,
  String sessionId,
) =>
    window.fatalOwner == null &&
    window.blockers.keys.whereType<_InboundPermissionAdmission>().any(
      (admission) => admission.sessionId == sessionId,
    );

void _mergeSessionCleanupWindow({
  required Object selectedKey,
  required _OwnerCleanupWindow selected,
  required Object donorKey,
  required _OwnerCleanupWindow donor,
}) {
  if (identical(selected, donor) || donor.finished) return;
  for (final blocker in donor.blockers.entries.toList(growable: false)) {
    _joinOwnerCleanupBlocker(
      selectedKey,
      selected,
      blocker.key,
      blocker.value,
    );
  }
  donor.timer?.cancel();
  if (identical(_ownerCleanupWindows[donorKey], donor)) {
    _ownerCleanupWindows.remove(donorKey);
  }
  donor.finished = true;
  donor.blockers.clear();
  if (donor.expirySignalled && !selected.expirySignalled) {
    selected.timer?.cancel();
    selected.expirySignalled = true;
    selected._expiry.complete();
  }
  selected.fatalCloseStarted =
      selected.fatalCloseStarted || donor.fatalCloseStarted;
  selected.expiryFuture.then<void>((_) {
    if (donor.expirySignalled) return;
    donor.expirySignalled = true;
    donor._expiry.complete();
  });
  selected.reaped.then<void>((_) {
    if (!donor._reaped.isCompleted) donor._reaped.complete();
  });
}

Object _selectSessionCloseCleanupKey({
  required String sessionId,
  required Object closingOwner,
  required AcpSessionInputBudgetOwner? promptOwner,
}) {
  final candidates = _ownerCleanupWindows.entries
      .where(
        (entry) => !entry.value.finished &&
            ((promptOwner != null && identical(entry.key, promptOwner)) ||
                _isOwnerlessCleanupWindowForSession(
                  entry.value,
                  sessionId,
                )),
      )
      .toList()
    ..sort(
      (left, right) =>
          left.value.deadline.compareTo(right.value.deadline),
    );
  if (candidates.isEmpty) return promptOwner ?? closingOwner;

  final earliest = candidates.first;
  if (promptOwner != null) {
    _bindOwnerCleanupFatalOwner(
      earliest.key,
      earliest.value,
      promptOwner,
    );
  }
  for (final donor in candidates.skip(1)) {
    _mergeSessionCleanupWindow(
      selectedKey: earliest.key,
      selected: earliest.value,
      donorKey: donor.key,
      donor: donor.value,
    );
  }
  return earliest.key;
}

// Task 10 修改 Task 6 已有方法；以下选择与登记仍在 serialized close
// action 的首个 await 前。完整替换必须删除 Task 6 过渡版本在这里的
// `_settleSessionAdmissionsForClose(sessionId)`；只有 `_prepareSessionClose`
// 能在 frozen selection 已登记后调用该 helper 一次。
void _beginSessionClose(String sessionId, Object closingOwner) {
  _invalidateSessionGeneration(sessionId);
  _invalidateInputBudgetPhase(sessionId);
  _invalidateRequestInputBudgetPhasesForSource(sessionId);
  _cancelledPromptOwners.remove(sessionId);
  _sessionClosingOwners
      .putIfAbsent(sessionId, () => <Object>{})
      .add(closingOwner);
  _revokeTerminalLeases(sessionId: sessionId);
  final lifecycle = _promptLifecycles[sessionId];
  final promptOwner = lifecycle != null && _isCurrentPromptLifecycle(lifecycle)
      ? lifecycle.owner
      : null;
  final cleanupKey = _selectSessionCloseCleanupKey(
    sessionId: sessionId,
    closingOwner: closingOwner,
    promptOwner: promptOwner,
  );
  final previousFrozen = _frozenSessionCleanupWindowSelections[sessionId];
  if (previousFrozen != null) {
    throw StateError('Session close cleanup selection is already frozen.');
  }
  _sessionCloseCleanupSelections[closingOwner] = (
    sessionId: sessionId,
    key: cleanupKey,
    promptOwner: promptOwner,
  );
  _frozenSessionCleanupWindowSelections[sessionId] = (
    closingOwner: closingOwner,
    key: cleanupKey,
  );
}

void _endSessionClose(String sessionId, Object closingOwner) {
  _sessionCloseCleanupSelections.remove(closingOwner);
  final frozen = _frozenSessionCleanupWindowSelections[sessionId];
  if (frozen != null && identical(frozen.closingOwner, closingOwner)) {
    _frozenSessionCleanupWindowSelections.remove(sessionId);
  }
  final owners = _sessionClosingOwners[sessionId];
  if (owners == null) return;
  owners.remove(closingOwner);
  if (owners.isEmpty) _sessionClosingOwners.remove(sessionId);
}

({Object error, StackTrace stackTrace})?
    _nextSessionCloseAdmissionReapFailureForTesting;
({Object error, StackTrace stackTrace})?
    _nextSessionClosePromptReapFailureForTesting;

void _throwNextSessionClosePrepareFailureForTesting() {
  // Step 7 已加入只负责 arm 的 RED 编译脚手架；本步骤首次消费它。
  final injected = _nextSessionClosePrepareFailureForTesting;
  if (injected == null) return;
  _nextSessionClosePrepareFailureForTesting = null;
  Error.throwWithStackTrace(injected.error, injected.stackTrace);
}

@visibleForTesting
void failNextSessionCloseAdmissionReapForTesting(
  Object error,
  StackTrace stackTrace,
) {
  if (_nextSessionCloseAdmissionReapFailureForTesting != null) {
    throw StateError('Session close admission reap failure is already armed.');
  }
  _nextSessionCloseAdmissionReapFailureForTesting = (
    error: error,
    stackTrace: stackTrace,
  );
}

@visibleForTesting
void failNextSessionClosePromptReapForTesting(
  Object error,
  StackTrace stackTrace,
) {
  if (_nextSessionClosePromptReapFailureForTesting != null) {
    throw StateError('Session close prompt reap failure is already armed.');
  }
  _nextSessionClosePromptReapFailureForTesting = (
    error: error,
    stackTrace: stackTrace,
  );
}

Future<void> _sessionCloseAdmissionReaped(
  _InboundPermissionAdmission admission,
) {
  final injected = _nextSessionCloseAdmissionReapFailureForTesting;
  if (injected == null) return admission.settled;
  _nextSessionCloseAdmissionReapFailureForTesting = null;
  return admission.settled.then<void>((_) {
    Error.throwWithStackTrace(injected.error, injected.stackTrace);
  });
}

Future<void> _sessionClosePromptReaped(Future<void> promptReaped) {
  final injected = _nextSessionClosePromptReapFailureForTesting;
  if (injected == null) return promptReaped;
  _nextSessionClosePromptReapFailureForTesting = null;
  return promptReaped.then<void>((_) {
    Error.throwWithStackTrace(injected.error, injected.stackTrace);
  });
}

Future<void> _prepareSessionClose(String sessionId, Object closingOwner) {
  final owners = _sessionClosingOwners[sessionId];
  final selection = _sessionCloseCleanupSelections[closingOwner];
  if (owners == null ||
      !owners.contains(closingOwner) ||
      selection == null ||
      selection.sessionId != sessionId) {
    return Future<void>.error(
      StateError('Session close owner is no longer current.'),
    );
  }
  _throwNextSessionClosePrepareFailureForTesting();

  // `_beginSessionClose` 已在调用本方法前、且在 closeSession 首个 await 前
  // 失效 generation。这里继续同步冻结本次 close 的全部对象 identity。
  final lifecycle = _promptLifecycles[sessionId];
  final currentLifecycle = lifecycle != null &&
          _isCurrentPromptLifecycle(lifecycle)
      ? lifecycle
      : null;
  final admissions = _inboundAdmissions
      .where((admission) => admission.sessionId == sessionId)
      .toList(growable: false);

  // 所有结算动作都发生在本方法首个 await 前。
  _settleSessionAdmissionsForClose(sessionId);
  Future<void>? promptReaped;
  if (currentLifecycle != null) {
    _settlePromptLifecycle(
      currentLifecycle,
      PermissionCancellationReason.sessionClosed,
      sendCancel: true,
    );
    final source = currentLifecycle.promptReaped;
    if (source != null) promptReaped = _sessionClosePromptReaped(source);
  }

  final localReaped = Future.wait<void>(<Future<void>>[
    for (final admission in admissions) _sessionCloseAdmissionReaped(admission),
    if (promptReaped != null) promptReaped,
  ], eagerError: false);
  Object? reapError;
  StackTrace? reapStackTrace;
  final observedLocalReaped = localReaped.then<void>(
    (_) {},
    onError: (Object error, StackTrace stackTrace) {
      reapError = error;
      reapStackTrace = stackTrace;
    },
  );
  final key = selection.key;
  final window = _getOrJoinOwnerCleanupWindow(
    key: key,
    fatalOwner: selection.promptOwner,
    blockerIdentity: closingOwner,
    blockerReaped: observedLocalReaped,
  );
  return () async {
    await Future.any<void>(<Future<void>>[
      window.expiryFuture,
      window.reaped,
    ]);
    await window.reaped;
    final error = reapError;
    if (error != null) {
      Error.throwWithStackTrace(error, reapStackTrace!);
    }
  }();
}

Future<void> closeSession({required String sessionId}) {
  return _runSerializedSessionMutation(sessionId, () async {
    // `_runSerializedSessionMutation` 已取得本 session mutation turn。
    // closing owner 必须在 begin 之前存在，使 begin 部分写入后同步抛错时，
    // finally 仍能按同一 identity 清理全部 bookkeeping。
    final closingOwner = Object();
    Object? primaryError;
    StackTrace? primaryStackTrace;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    try {
      try {
        // begin + prepare 都在本 action 首个 await 前同步执行，并且已经位于
        // 最外层 finally 内。任一同步 throw 都走同一个 primary error槽。
        _beginSessionClose(sessionId, closingOwner);
        final prepared = _prepareSessionClose(sessionId, closingOwner);
        await prepared;
        if (!peer.isAvailable) {
          throw const AcpConnectionClosedException();
        }
        await peer.sendRaw('session/close', <String, dynamic>{
          'sessionId': sessionId,
        });
      } on Object catch (error, stackTrace) {
        primaryError = error;
        primaryStackTrace = stackTrace;
      }
    } finally {
      try {
        await _cleanupSessionLocally(sessionId);
      } on Object catch (error, stackTrace) {
        cleanupError = error;
        cleanupStackTrace = stackTrace;
      } finally {
        _endSessionClose(sessionId, closingOwner);
      }
    }
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStackTrace!);
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError!, primaryStackTrace!);
    }
  });
}
```

Task 10 直接复用 Task 6 已完整实现的 `_replaceSessionGeneration`、`_invalidateSessionGeneration`、`_nextSessionGeneration` 与 new/fork/load/resume/close/rollback/dispose 调用点，不得重新声明 generation counter 或 helper。保留现有 `_runSerializedSessionMutation` 协调：整个 close（同步 begin/prepare、远端 close、本地 cleanup）是一个同 session mutation turn；更早的 load/resume 先结束，更晚的 replacement 必须等 close cleanup 完成。`closingOwner` 由 serialized action 在进入最外层 `try` 前唯一创建，再作为参数交给 `_beginSessionClose`；这样 begin 部分写入后同步抛错时，finally 仍有稳定 identity 可供 `_endSessionClose` 幂等回收。`_beginSessionClose` 在该 turn 首个 await 前按该 identity 同时登记 `_sessionCloseCleanupSelections` 与 Task 7 `_frozenSessionCleanupWindowSelections`。这是对 Task 6 过渡 `_beginSessionClose` 的完整替换：必须删除其中原有的 `_settleSessionAdmissionsForClose(sessionId)`，不得在 frozen selection 建立前取消 admission；唯一生产调用留在 `_prepareSessionClose`，它先捕获本次 admissions identity，再在同步前缀调用 helper恰一次。`_endSessionClose` 仅按同一 identity移除两处 selection，再执行 Task 6 原 closing-owner set 清理；若 begin 尚未登记或只完成部分登记，对缺失项必须安全 no-op，不能误删另一个 close 的 frozen selection。`localSessionStateKeysForTesting` 与 `sessionCloseSelectionCountForTesting` 验证无残留。

Task 9 曾把 prompt settle描述在 `_beginSessionClose`；本 Task 的完整替换必须把该调用移到 `_prepareSessionClose` 所示位置，确保 `_beginSessionClose` 先完成 selection比较与两处 frozen登记，再调用任何 `_settlePromptLifecycle`。不得在 frozen selection之前保留一份旧 settle调用，否则 active prompt尚无 owner window时仍会先按 owner key创建第二个 window。

`_prepareSessionClose` 不创建 Timer、`Future.delayed`或`Future.timeout`。选择器必须把当前 prompt owner已有 window与同 session所有 ownerless window放在一起比较绝对 deadline，保留真实最早 window的 key、identity、deadline、Timer和callback；其余 donor 的全部 blocker转入该 window，donor Timer取消，expiry/reaped桥接到 selected，绝不新建或重排 Timer。若 selected 是 ownerless 而当前 prompt有效，先用 map identity + owner identity/generation 安全绑定其 `fatalOwner`。begin 后才释放 reservation或结束 response的 admission，`_startAdmissionResponseGrace`、`_onAdmissionResponseFinished` 与 `_settlePromptLifecycle` 都先解析 session frozen key，不能再按 admission或owner identity建第二个 window；即使 active prompt尚无 owner window，prompt reap也必须加入更早 ownerless identity。`_prepareSessionClose` 只对该 selection get-or-join。`localReaped` 的 error不能直接交给 Task 7 window吞成“blocker 已释放”：必须由 `observedLocalReaped` 保存原 error/stack并以成功完成释放 blocker；close 在 `await window.reaped` 后再用 `Error.throwWithStackTrace` 恢复原失败。peer unavailable若没有更早 reap error，才以固定 `AcpConnectionClosedException` 进入现有 `remoteError` 优先级。

Task 6 会在其自身边界捕获 provider cancel callback 异常，Task 10 与此兼容；但这里的所有权结构不得依赖下层永不抛。只要 `_beginSessionClose` 或 `_prepareSessionClose` 内仍有任意同步异常向上传播，都必须由 `primaryError/primaryStackTrace` 原样保存，再经过同一个 cleanup/end finally。

异常优先级固定：`localReaped` 首个真实 admission/prompt reap error先保存对象与 stack，并阻止远端 `session/close` 开始；本地 cleanup 成功时原样重抛该 reap error。没有 reap error时才保留 begin/prepare 同步 error或既有远端/request/peer-unavailable error及其 stack。本地 cleanup 自身失败时，`SessionCloseCleanupException` 覆盖 prepare、reap与远端错误，因为它表示本地资源可能未完全释放，且不得把被覆盖的 error、stack或远端 payload 塞入该异常。

- [ ] 14. 实现 `_cleanupSessionLocally` 的十一阶段固定顺序：stream、replay、workspace、additionalDirectories、filesystemProvider、modes、registration、toolCalls、inputPhase（同一 stage 内结算 permissions）、generation、terminals。每个 stage 独立捕获，失败只记录 stage 名；任一失败最终抛下列异常，不附远端 payload。这里是**原位替换** `session_manager.dart` 顶部已经存在的 `SessionCloseCleanupException` 定义，不得新增第二个同名类型；保留 `dart_acp.dart` 现有 export：

```dart
class SessionCloseCleanupException implements Exception {
  SessionCloseCleanupException(List<String> failedStages)
      : failedStages = List<String>.unmodifiable(failedStages);
  final List<String> failedStages;

  @override
  String toString() =>
      'SessionCloseCleanupException(${failedStages.join(', ')})';
}

Future<void> _cleanupSessionLocally(String sessionId) async {
  final failedStages = <String>[];

  Future<void> cleanup(
    String stage,
    FutureOr<void> Function() action,
  ) async {
    try {
      await action();
    } on Object {
      failedStages.add(stage);
      _log.warning('session close cleanup stage $stage failed');
    }
  }

  await cleanup('stream', () {
    _closeControllerWithoutWaiting(_sessionStreams.remove(sessionId));
  });
  await cleanup('replay', () => _replayBuffers.remove(sessionId));
  await cleanup('workspace', () => _sessionWorkspaceRoots.remove(sessionId));
  await cleanup(
    'additionalDirectories',
    () => _sessionAdditionalDirectories.remove(sessionId),
  );
  await cleanup(
    'filesystemProvider',
    () => _sessionFsProviders.remove(sessionId),
  );
  await cleanup('modes', () => _sessionModes.remove(sessionId));
  await cleanup(
    'registration',
    () => _generatedSessionRegistrationOwners.remove(sessionId),
  );
  await cleanup('toolCalls', () => _removeToolCalls(sessionId));
  await cleanup('inputPhase', () async {
    _invalidateInputBudgetPhase(sessionId);
    _invalidateRequestInputBudgetPhasesForSource(sessionId);
    _cancelledPromptOwners.remove(sessionId);
    final lifecycle = _promptLifecycles[sessionId];
    if (lifecycle != null) _releasePromptLifecycle(lifecycle);
    final admissions = _inboundAdmissions
        .where((admission) => admission.sessionId == sessionId)
        .toList(growable: false);
    for (final admission in admissions) {
      admission.tryCancel(PermissionCancellationReason.sessionClosed);
    }
    await Future.wait<void>(
      admissions.map((admission) => admission.settled),
      eagerError: false,
    );
  });
  await cleanup('generation', () {
    final generation = _sessionGenerations[sessionId];
    if (generation == null) return;
    generation.active = false;
    if (identical(_sessionGenerations[sessionId], generation)) {
      _sessionGenerations.remove(sessionId);
    }
  });
  await cleanup('terminals', () => _releaseSessionTerminals(sessionId));

  if (failedStages.isNotEmpty) {
    throw SessionCloseCleanupException(failedStages);
  }
}

Set<String> localSessionStateKeysForTesting(String sessionId) {
  final keys = <String>{};
  if (_sessionStreams.containsKey(sessionId)) keys.add('stream');
  if (_replayBuffers.containsKey(sessionId)) keys.add('replay');
  if (_sessionWorkspaceRoots.containsKey(sessionId)) keys.add('workspace');
  if (_sessionAdditionalDirectories.containsKey(sessionId)) {
    keys.add('additionalDirectories');
  }
  if (_sessionFsProviders.containsKey(sessionId)) keys.add('provider');
  if (_sessionModes.containsKey(sessionId)) keys.add('mode');
  if (_generatedSessionRegistrationOwners.containsKey(sessionId)) {
    keys.add('registration');
  }
  if (_toolCalls.containsKey(sessionId)) keys.add('tool');
  if (_inputBudgetPhases.containsKey(sessionId)) keys.add('input');
  if (_sessionGenerations.containsKey(sessionId)) keys.add('generation');
  if (_inboundAdmissions.any((item) => item.sessionId == sessionId)) {
    keys.add('permission');
  }
  if (_terminalLeaseCountBySession.containsKey(sessionId)) {
    keys.add('terminal');
  }
  if (_sessionCloseCleanupSelections.values.any(
    (selection) => selection.sessionId == sessionId,
  )) {
    keys.add('sessionCloseCleanupSelection');
  }
  if (_frozenSessionCleanupWindowSelections.containsKey(sessionId)) {
    keys.add('frozenSessionCloseCleanupSelection');
  }
  if (_sessionClosingOwners[sessionId]?.isNotEmpty ?? false) {
    keys.add('sessionClosingOwner');
  }
  return Set<String>.unmodifiable(keys);
}

int pendingPermissionCountForTesting(String sessionId) =>
    _inboundAdmissions.where((item) => item.sessionId == sessionId).length;
```

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves success across its cleanup fatal"`。Expected: PASS。

- [ ] 16. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves remote error across its cleanup fatal"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed prompt preserves timeout across its cleanup fatal"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw owner bound prompt preserves cached winner without a typed turn"`。Expected: PASS（timeout 对用户投原 `AcpPromptTimeoutException`、一次 `TurnEnded(other)`、一次 done；同 owner cleanup fatal 不改写 typed 或 raw 缓存终态）。

- [ ] 17. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed external close and terminal claim are first wins"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "typed unavailable before terminal is fixed connection closed once"`。Expected: PASS（完整 claim 同步顺序与四种 unavailable-first cause 均执行；cleanup window先于 admission cancellation冻结唯一 Timer/expiry，admission/provider/lifecycle再观察同一个 mapped reason）。

- [ ] 18. 分别运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close cleans local state in finally after remote failure"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close cleans local state after synchronous prepare failure"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close preserves admission and prompt reap errors unless local cleanup fails"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "admission prompt and close share one owner cleanup callback"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close keeps the earliest ownerless window with an active prompt"`、`./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close routes prompt cleanup to a frozen ownerless key"` 与 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "session close stays serialized across setup and replacement"`。Expected: PASS；两个并行 blocker fixture都显式使用 ordinary 2 / total 4；同步 prepare error与真实 admission/prompt reap error都保留原对象/stack，本地 cleanup error精确覆盖；`_settleSessionAdmissionsForClose` 只在 frozen selection后的 prepare同步前缀调用一次，任一失败路径后本地状态、closing owner与普通/frozen selection均清空，prepare 失败不发远端 close；有无预存 owner window都只有一个有效 identity/callback/fatal，最早 deadline不变，cleanup fatal后的 close在无 reap error时固定抛 connection-closed，setup→close→replacement 严格串行，旧 callback/rollback 不改 replacement generation/state。

- [ ] 19. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: PASS。

- [ ] 20. 运行 `dart format third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: exit 0。

- [ ] 21. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 22. 运行 `git add third_party/dart_acp/lib/src/session/session_manager.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: 只暂存本任务三个文件。

- [ ] 23. 运行 `git commit -m "fix: preserve ACP typed prompt terminals"`。Expected: commit成功，Task 10 独立提交可编译且继续保留 Task 11 raw caller。

### Task 11: Raw terminal-only、owner API 迁移与绕过封口

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `third_party/dart_acp/lib/src/rpc/peer.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

Task 11 必须在本任务内补齐新增注解与 identity collection 的直接 imports，不能依赖别的任务碰巧导入：根 `pubspec.yaml` 的 `dependencies` 增加 `meta: ^1.16.0`，运行 pub get 将现有 lock 中 `meta 1.18.0` 从 transitive改为 direct main；`lib/acp/dart_acp_agent_client.dart` 增加 `import 'dart:collection';` 与 `import 'package:meta/meta.dart';`；`third_party/dart_acp/lib/src/acp_client.dart`、`third_party/dart_acp/lib/src/session/session_manager.dart` 各增加 `import 'package:meta/meta.dart';`。原有 `dart:async` 等 import 保留，重复 import 由 formatter 排序。

- [ ] 1. 先把 Task 6 `_PermissionAdmissionHarness` 的 client 构造统一为公开 `AcpClient.start`；不得调用私有构造器，也不得另建一个与 client 脱节的 manager。真实 manager-owned lifecycle 只通过 `AcpClient` 的 Task 9/11 代理进入。这是对 Task 6 harness 的完整替换，所以必须保留 named `maxOrdinaryConcurrentHandlers = 1`，并把 `maxConcurrentHandlers` 固定传为 `maxOrdinaryConcurrentHandlers + 2`；不得删参数、忽略参数或恢复非法 `2/1` 硬编码。transport 与 `nextOutbound` 完整定义为：

```dart
final class _HarnessTransport implements AcpTransport {
  _HarnessTransport()
      : _controller = StreamChannelController<String>(sync: true) {
    _agentSubscription = _controller.foreign.stream.listen((line) {
      _outbound.add(
        Map<String, dynamic>.from(jsonDecode(line) as Map),
      );
    });
  }

  final StreamChannelController<String> _controller;
  final StreamController<Map<String, dynamic>> _outbound =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  late final StreamSubscription<String> _agentSubscription;
  bool _stopped = false;

  @override
  StreamChannel<String> get channel => _controller.local;

  Stream<Map<String, dynamic>> get outbound => _outbound.stream;

  Future<Map<String, dynamic>> nextOutbound(String method) => _outbound.stream
      .firstWhere((message) => message['method'] == method)
      .timeout(const Duration(seconds: 2));

  void sendAgentMessage(Map<String, dynamic> message) {
    if (_stopped) throw StateError('Harness transport is stopped.');
    _controller.foreign.sink.add(jsonEncode(message));
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    await _controller.foreign.sink.close();
    await _agentSubscription.cancel();
    await _outbound.close();
  }
}

// Replace Task 6's old detached peer/manager constructor and fields.
_PermissionAdmissionHarness._({
  required this.acpClient,
  required this.config,
  required this.transport,
  required this.peer,
  required this.manager,
  required this.permissions,
  required this.fs,
  required this.terminals,
  required this.sessionId,
});

final AcpClient acpClient;
final AcpConfig config;
final _HarnessTransport transport;
final JsonRpcPeer peer;
final SessionManager manager;
final _ControlledPermissionProvider permissions;
final _CountingFsProvider fs;
final _CountingTerminalProvider terminals;
final String sessionId;
late StreamSubscription<Map<String, dynamic>> _wireSubscription;
late final AcpPeerUnavailableListener _peerUnavailableListener;
final Map<AcpSessionInputBudgetOwner,
        Completer<AcpPeerUnavailableState>>
    _unavailableByOwner =
        <AcpSessionInputBudgetOwner,
            Completer<AcpPeerUnavailableState>>{};
AcpPeerUnavailableState? _lastPeerUnavailable;
bool _disposed = false;

static Future<_PermissionAdmissionHarness> start({
  AcpTimeouts timeouts = const AcpTimeouts(
    permission: Duration(milliseconds: 100),
    promptCancelGrace: Duration(milliseconds: 750),
  ),
  int maxOrdinaryConcurrentHandlers = 1,
}) async {
  final transport = _HarnessTransport();
  final permissions = _ControlledPermissionProvider();
  final fs = _CountingFsProvider();
  final terminals = _CountingTerminalProvider();
  final config = AcpConfig(
    timeouts: timeouts,
    permissionProvider: permissions,
    fsProvider: fs,
    terminalProvider: terminals,
  );
  final acpClient = await AcpClient.start(
    config: config,
    transport: transport,
    maxConcurrentHandlers: maxOrdinaryConcurrentHandlers + 2,
    maxOrdinaryConcurrentHandlers: maxOrdinaryConcurrentHandlers,
    maxTerminalHandles: 2,
    maxTerminalHandlesPerSession: 1,
  );
  final initializeSeen = transport.nextOutbound('initialize');
  final initializing = acpClient.initialize();
  final initialize = await initializeSeen;
  transport.sendAgentMessage(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': initialize['id'],
    'result': <String, dynamic>{
      'protocolVersion': 1,
      'agentCapabilities': <String, dynamic>{},
      'authMethods': <Map<String, dynamic>>[],
    },
  });
  await initializing;
  final newSeen = transport.nextOutbound('session/new');
  final creating = acpClient.newSession('/workspace');
  final sessionNew = await newSeen;
  transport.sendAgentMessage(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': sessionNew['id'],
    'result': <String, dynamic>{'sessionId': 'session-1'},
  });
  final sessionId = await creating;
  final harness = _PermissionAdmissionHarness._(
    acpClient: acpClient,
    config: config,
    transport: transport,
    peer: acpClient.peerForTesting,
    manager: acpClient.sessionManagerForTesting,
    permissions: permissions,
    fs: fs,
    terminals: terminals,
    sessionId: sessionId,
  );
  harness._installPeerUnavailableObserver();
  harness._installAdmissionObserver();
  harness._wireSubscription = transport.outbound.listen(harness._acceptWireMap);
  return harness;
}

void sendAgentMessage(Map<String, dynamic> message) =>
    transport.sendAgentMessage(message);
Future<Map<String, dynamic>> nextOutbound(String method) =>
    transport.nextOutbound(method);

Future<void> closePeer() => acpClient.closePeerExplicitlyForTesting();
Future<void> admissionResponseGraceStarted(
  AcpSessionInputBudgetOwner owner,
) => acpClient.admissionResponseGraceStartedForTesting(owner);

bool _unavailableMatchesOwner(
  AcpPeerUnavailableState state,
  AcpSessionInputBudgetOwner owner,
) {
  final cleanup = state.cleanupIdentity;
  return cleanup == null ||
      (identical(cleanup.ownerToken, owner) &&
          cleanup.generation == owner.generation);
}

void _installPeerUnavailableObserver() {
  _peerUnavailableListener = (state) {
    _lastPeerUnavailable = state;
    for (final entry in _unavailableByOwner.entries.toList(growable: false)) {
      if (!_unavailableMatchesOwner(state, entry.key)) continue;
      _unavailableByOwner.remove(entry.key);
      if (!entry.value.isCompleted) entry.value.complete(state);
    }
  };
  peer.addUnavailableListener(_peerUnavailableListener);
}

Future<AcpPeerUnavailableState> unavailableSeen(
  AcpSessionInputBudgetOwner owner,
) {
  final current = _lastPeerUnavailable;
  if (current != null && _unavailableMatchesOwner(current, owner)) {
    return Future<AcpPeerUnavailableState>.value(current);
  }
  return _unavailableByOwner
      .putIfAbsent(owner, Completer<AcpPeerUnavailableState>.sync)
      .future;
}

AcpPeerUnavailableState get peerUnavailable => _lastPeerUnavailable ??
    (throw StateError('ACP peer is still available.'));

Future<void> expireOwnerAdmissionResponseGrace(
  AcpSessionInputBudgetOwner owner,
) async {
  final unavailable = unavailableSeen(owner);
  acpClient.expireOwnerAdmissionResponseGraceForTesting(owner);
  await unavailable;
}

Future<void> dispose() async {
  if (_disposed) return;
  _disposed = true;
  peer.removeUnavailableListener(_peerUnavailableListener);
  await _wireSubscription.cancel();
  await acpClient.dispose();
  await transport.stop();
}
```

完成这个公开 client 替换后，立即重跑 Task 6 的 harness 自验：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission harness preserves two reserved control slots"
```

Expected: PASS；默认 ordinary 1 使用 total 3，Task 10 传 ordinary 2 时使用 total 4。若本命令抛预留槽位 `ArgumentError`、named 参数未定义或实际仍只传 ordinary 1，必须留在 Step 1 修正，不得继续 raw RED。

Task 6 原有 `_onWire(String)` 拆成 `_acceptWireMap(Map<String, dynamic>)`，其 response/correlation/admission probe 逻辑原样保留；所有旧 `channel.local.sink.add(...)` 改调 `sendAgentMessage(...)`，所有旧 `channel.local.stream.listen(...)` 删除。`peer/manager` 只是同一个 `AcpClient` 内部实例的只读测试代理，用于复用 Task 6 已有 driver，不得另行构造。`AcpClient` 代理体为：

```dart
@visibleForTesting
JsonRpcPeer get peerForTesting => _peer;

@visibleForTesting
SessionManager get sessionManagerForTesting => _sessionManager;
```

harness 的 `admissionBarrierSeen(owner)`、`cancelSeen(owner)`、`releaseAdmissionCommit(owner)`、`backgroundReapDone(owner)` 与 `releaseClaimBarrier(owner)` 都连接 Task 6/9 已建立的真实 Future；`closePeer()` 只调用本任务新增的 `acpClient.closePeerExplicitlyForTesting()`，不得用 dispose代替。core harness 只断言 manager lifecycle/right；raw event、delivery claim、stream close全部在同文件 `_RawStdioFixture` 断言。Task 9 terminal hook、delivery-right 创建、pre-claim、claim 与 peer unavailable 各自完成独立同步点：

```dart
final class _RawPromptProbe {
  _RawPromptProbe({
    required this.acpClient,
    required this.owner,
    required this.requestId,
    required this.result,
    required this.winnerRecorded,
    required this.rightRecorded,
    required this.preClaimSeen,
    required this.claimSeen,
    required this.graceStarted,
    required this.unavailableSeen,
  });
  final AcpClient acpClient;
  final AcpSessionInputBudgetOwner owner;
  final Object requestId;
  final Future<Map<String, dynamic>> result;
  final Future<void> winnerRecorded;
  final Future<void> rightRecorded;
  final Future<void> preClaimSeen;
  final Future<void> claimSeen;
  final Future<void> graceStarted;
  final Future<void> unavailableSeen;
}

Future<_RawPromptProbe> startRawPrompt() async {
  final outbound = nextOutbound('session/prompt');
  final owner = acpClient.beginPromptTurn(sessionId);
  final result = acpClient.sendPromptRequest(
    owner: owner,
    content: const <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': 'raw-probe'},
    ],
  );
  final request = await outbound.timeout(const Duration(seconds: 2));
  final probe = _RawPromptProbe(
    acpClient: acpClient,
    owner: owner,
    requestId: request['id']!,
    result: result,
    winnerRecorded: acpClient.promptWinnerRecordedForTesting(owner),
    rightRecorded: acpClient.promptRightRecordedForTesting(owner),
    preClaimSeen: acpClient.promptBarrierReleasedForTesting(owner),
    claimSeen: acpClient.promptClaimSeenForTesting(owner),
    graceStarted: acpClient.promptGraceStartedForTesting(owner),
    unavailableSeen: unavailableSeen(owner),
  );
  return probe;
}

void completeRawPromptSuccess(_RawPromptProbe probe) {
  sendAgentMessage(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': probe.requestId,
    'result': <String, dynamic>{'stopReason': 'end_turn'},
  });
}

void completeRawPromptError(_RawPromptProbe probe) {
  sendAgentMessage(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': probe.requestId,
    'error': <String, dynamic>{'code': -32000, 'message': 'fixed remote error'},
  });
}
```

`winnerRecorded/rightRecorded` 必须直接使用 Task 9 lifecycle 中两个互相独立的只读 Future；严禁从 `result.then(...)` 派生，也不得由测试手动 complete。Task 9 的 `AcpClient` 只读代理必须保留以下逐层转发，barrier/claim 同理；它们只观察 production lifecycle，不创建 winner/right：

```dart
@visibleForTesting
Future<void> promptWinnerRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.promptWinnerRecordedForTesting(owner);

@visibleForTesting
Future<void> promptRightRecordedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.promptRightRecordedForTesting(owner);

@visibleForTesting
Future<void> promptBarrierReleasedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.promptBarrierReleasedForTesting(owner);

@visibleForTesting
Future<void> promptClaimSeenForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.promptClaimSeenForTesting(owner);

@visibleForTesting
Future<void> promptGraceStartedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.promptGraceStartedForTesting(owner);

@visibleForTesting
Future<void> admissionResponseGraceStartedForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.admissionResponseGraceStartedForTesting(owner);

@visibleForTesting
void expireOwnerAdmissionResponseGraceForTesting(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.expireOwnerAdmissionResponseGraceForTesting(owner);

@visibleForTesting
Future<void> closePeerExplicitlyForTesting() => _peer.close();
```

上面两个 grace getter 与 owner 定向 expiry 的 manager 完整方法体为：

```dart
@visibleForTesting
Future<void> promptGraceStartedForTesting(
  AcpSessionInputBudgetOwner owner,
) => admissionResponseGraceStartedForTesting(owner);

@visibleForTesting
Future<void> admissionResponseGraceStartedForTesting(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null || !identical(lifecycle.owner, owner)) {
    return Future<void>.error(
      StateError('ACP prompt phase owner is no longer active.'),
    );
  }
  return lifecycle.graceStarted.future;
}

@visibleForTesting
void expireOwnerAdmissionResponseGraceForTesting(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null || !identical(lifecycle.owner, owner)) {
    throw StateError('ACP prompt phase owner is no longer active.');
  }
  final window = _ownerCleanupWindows[owner];
  if (window == null || window.finished || window.blockers.isEmpty) {
    throw StateError('ACP admission response grace is not active.');
  }
  final expire = window.expireForTesting ??
      (throw StateError('ACP admission response grace has no timer callback.'));
  expire();
}
```

`_startAdmissionResponseGrace` 创建 owner-scoped 新窗口时，在登记 blocker、写入 Task 7 唯一 `_ownerCleanupWindows[key]` 后且启动 timer 前，同步找到相同 identity 的 `_PromptLifecycle` 并 complete `lifecycle.graceStarted`；复用已有同 owner窗口时也确保该 Completer 已完成。getter/expiry只读取同 owner production lifecycle/window，不新建 timer、不直接 close peer。harness 的 `unavailableSeen(owner)` 来自 Task 4 真实 peer listener，`peerUnavailable` 是该 listener最后一次真实状态，不能由测试主动赋值。

`DartAcpAgentClient.closePeerExplicitlyForTesting` 在 Task 11 同步加入并只代理真实 core close；不得等到 Task 13，也不得用 dispose冒充 explicit close：

```dart
@visibleForTesting
Future<void> closePeerExplicitlyForTesting() =>
    _requireClient().closePeerExplicitlyForTesting();
```

Task 6 的真实 admission hook 同步扩成一个公开只读/释放探针；它绑定下一条实际 `_InboundPermissionAdmission`，不自行完成 production Future：

```dart
final class AcpPromptAdmissionProbeForTesting {
  AcpPromptAdmissionProbeForTesting._(this._state);
  final _ArmedPromptAdmissionProbeForTesting _state;

  AcpSessionInputBudgetOwner get owner => _state.owner;
  Future<void> get admissionBarrierSeen => _state.admissionBarrierSeen.future;
  Future<void> get sideEffectStarted => _state.sideEffectStarted.future;
  Future<void> get graceStarted => _state.graceStarted.future;
  Future<void> get reaped => _state.reaped.future;
  void releaseReservationOnly() => _state.releaseReservationOnly();
  void releaseCommit() => _state.releaseCommit();
}

final class _ArmedPromptAdmissionProbeForTesting {
  late final AcpSessionInputBudgetOwner owner;
  final Completer<void> admissionBarrierSeen = Completer<void>.sync();
  final Completer<void> sideEffectStarted = Completer<void>.sync();
  final Completer<void> graceStarted = Completer<void>.sync();
  final Completer<void> reservationGate = Completer<void>.sync();
  final Completer<void> responseCommitGate = Completer<void>.sync();
  final Completer<void> reaped = Completer<void>.sync();
  bool bound = false;

  void releaseReservationOnly() {
    if (!reservationGate.isCompleted) reservationGate.complete();
  }

  void releaseCommit() {
    releaseReservationOnly();
    if (!responseCommitGate.isCompleted) responseCommitGate.complete();
  }
}

// Add these fields and methods to _InboundPermissionAdmission. The two
// production bind callbacks await the installed gates before calling finish;
// the signals complete only from those real finish callbacks.
Future<void> _reservationReleaseTestingGate = Future<void>.value();
Future<void> _responseCommitTestingGate = Future<void>.value();
final Completer<void> _reservationReleasedForTesting =
    Completer<void>.sync();
final Completer<void> _responseCommittedForTesting = Completer<void>.sync();

Future<void> get reservationReleasedForTesting =>
    _reservationReleasedForTesting.future;
Future<void> get responseCommittedForTesting =>
    _responseCommittedForTesting.future;

void installTestingGates({
  required Future<void> reservationRelease,
  required Future<void> responseCommit,
}) {
  if (reservationReleased || responseFinished) {
    throw StateError('Admission testing gates must be installed before release.');
  }
  _reservationReleaseTestingGate = reservationRelease;
  _responseCommitTestingGate = responseCommit;
}

// Replace the callbacks inside bindReservationReleased/bindResponseCommitted.
Future<void> waitForReservationReleaseForTesting(Future<void> released) =>
    released.then<void>(
      (_) => _reservationReleaseTestingGate,
      onError: (_, __) => _reservationReleaseTestingGate,
    );
Future<void> waitForResponseCommitForTesting(Future<void> committed) =>
    committed.then<void>(
      (_) => _responseCommitTestingGate,
      onError: (_, __) => _responseCommitTestingGate,
    );

void markReservationReleasedForTesting() {
  if (!_reservationReleasedForTesting.isCompleted) {
    _reservationReleasedForTesting.complete();
  }
}

void markResponseCommittedForTesting() {
  if (!_responseCommittedForTesting.isCompleted) {
    _responseCommittedForTesting.complete();
  }
}

_ArmedPromptAdmissionProbeForTesting? _armedPromptAdmissionProbeForTesting;
final Map<_InboundPermissionAdmission, _ArmedPromptAdmissionProbeForTesting>
    _promptAdmissionProbesForTesting =
        HashMap<_InboundPermissionAdmission,
            _ArmedPromptAdmissionProbeForTesting>.identity();

AcpPromptAdmissionProbeForTesting armNextPromptAdmissionForTesting() {
  if (_armedPromptAdmissionProbeForTesting != null) {
    throw StateError('A prompt admission probe is already armed.');
  }
  final state = _ArmedPromptAdmissionProbeForTesting();
  _armedPromptAdmissionProbeForTesting = state;
  return AcpPromptAdmissionProbeForTesting._(state);
}

void _attachPromptAdmissionProbeForTesting(
  _PromptLifecycle lifecycle,
  _InboundPermissionAdmission admission,
) {
  final state = _armedPromptAdmissionProbeForTesting;
  if (state == null) return;
  _armedPromptAdmissionProbeForTesting = null;
  state.bound = true;
  state.owner = lifecycle.owner;
  _promptAdmissionProbesForTesting[admission] = state;
  admission.installTestingGates(
    reservationRelease: state.reservationGate.future,
    responseCommit: state.responseCommitGate.future,
  );
  if (!state.admissionBarrierSeen.isCompleted) {
    state.admissionBarrierSeen.complete();
  }
  lifecycle.graceStarted.future.then<void>((_) {
    if (!state.graceStarted.isCompleted) state.graceStarted.complete();
  });
  Future.wait<void>(<Future<void>>[
    admission.settled,
    admission.reservationReleasedForTesting,
    admission.responseCommittedForTesting,
  ]).then<void>((_) {
    _promptAdmissionProbesForTesting.remove(admission);
    if (!state.reaped.isCompleted) state.reaped.complete();
  });
}

void _markPromptAdmissionSideEffectStartedForTesting(
  _InboundPermissionAdmission admission,
) {
  final state = _promptAdmissionProbesForTesting[admission];
  if (state != null && !state.sideEffectStarted.isCompleted) {
    state.sideEffectStarted.complete();
  }
}

void _disposePromptAdmissionProbesForTesting() {
  final armed = _armedPromptAdmissionProbeForTesting;
  _armedPromptAdmissionProbeForTesting = null;
  if (armed != null) {
    armed.releaseCommit();
    if (!armed.reaped.isCompleted) armed.reaped.complete();
  }
  for (final state in _promptAdmissionProbesForTesting.values) {
    state.releaseCommit();
  }
}

// AcpClient proxy; it owns no second probe state.
@visibleForTesting
AcpPromptAdmissionProbeForTesting armNextPromptAdmissionForTesting() =>
    _sessionManager.armNextPromptAdmissionForTesting();
```

在 `_PromptLifecycle` 增加 `final Completer<void> graceStarted = Completer<void>.sync()`，`startCleanup` 首次写入绝对 deadline时同步 complete。Task 6 attach admission 的同一调用栈在 `lifecycle.attachAdmission(admission)` 后调用 `_attachPromptAdmissionProbeForTesting`；permission allow后、真正调用 fs/write/terminal provider前调用 `_markPromptAdmissionSideEffectStartedForTesting`。`bindReservationReleased` 改为先 `waitForReservationReleaseForTesting(released)`，再执行原 `finish()`，且在 `finish()` 内设置 production bool 后调用 `markReservationReleasedForTesting()`；`bindResponseCommitted` 对称地先 `waitForResponseCommitForTesting(committed)`，并在原 `finish()` 内调用 `markResponseCommittedForTesting()`。gate 只串入原 production Future，不替换原 Future，也不能直接改 production bool。因而 `reaped` 等真实 `settled + reservationReleasedForTesting + responseCommittedForTesting`。`dispose` 在关闭 admission 前调用 `_disposePromptAdmissionProbesForTesting()`：未绑定 armed probe释放两 gate并完成其 `reaped`，已绑定 probe只释放 gate，仍由真实三项 Future 完成 `reaped`。

在 `dart_acp.dart` 做本任务完整类型导出：现有 `src/rpc/peer.dart show ...` 列表加入 `JsonRpcPromptTerminalKind, JsonRpcPromptTerminalWinner`；`src/session/session_manager.dart show ...` 列表加入 `AcpPromptAdmissionProbeForTesting, AcpPromptDeliveryClaim`。`AcpPromptTimeoutException` 已由无 `show` 的 `src/config.dart` 导出，不再重复声明。wrapper 与测试只能从 `package:dart_acp/dart_acp.dart` 使用这些类型，不得从 `src/` 私有路径导入。

Step 1 同步加入下列纯契约/只读观察脚手架，使 Step 2 起的行为 RED 在旧行为上失败，而不是因 claim 类型、export、counter 或 barrier 未定义而编译失败。这里只增加 opaque claim 类型、lifecycle 观察字段和只读查询；`wait/tryClaim/release` 的行为实现仍留在 Step 14–15：

```dart
// Add to Task 9's `_PromptLifecycle`.
AcpPromptDeliveryClaim? activeDeliveryClaim;

final class AcpPromptDeliveryClaim {
  const AcpPromptDeliveryClaim._({
    required this.owner,
    required this.winner,
    required Object rightIdentity,
  }) : _rightIdentity = rightIdentity;

  final AcpSessionInputBudgetOwner owner;
  final JsonRpcPromptTerminalWinner winner;
  final Object _rightIdentity;
}

// SessionManager read-only projections. They never create or claim a right.
bool hasPromptDeliveryRight(AcpSessionInputBudgetOwner owner) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  return lifecycle != null &&
      identical(lifecycle.owner, owner) &&
      lifecycle.deliveryRight?.state == _PromptDeliveryRightState.pending;
}

bool hasActivePromptDeliveryClaim(AcpSessionInputBudgetOwner owner) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  return lifecycle != null &&
      identical(lifecycle.owner, owner) &&
      lifecycle.activeDeliveryClaim != null &&
      lifecycle.deliveryRight?.state == _PromptDeliveryRightState.claimed;
}

// AcpClient owns no mirror state.
bool hasPromptDeliveryRight(AcpSessionInputBudgetOwner owner) =>
    _sessionManager.hasPromptDeliveryRight(owner);

bool hasActivePromptDeliveryClaim(AcpSessionInputBudgetOwner owner) =>
    _sessionManager.hasActivePromptDeliveryClaim(owner);
```

wrapper 的逐层测试观察口完整方法体为：

```dart
acp.AcpPromptAdmissionProbeForTesting? _rawAdmissionProbeForTesting;
final StreamController<acp.AcpPeerUnavailableState> _peerUnavailableStates =
    StreamController<acp.AcpPeerUnavailableState>.broadcast(sync: true);
acp.AcpClient? _peerUnavailableListenerClient;
acp.AcpPeerUnavailableListener? _peerUnavailableListener;
final Set<acp.AcpClient> _disposingPeerSources =
    HashSet<acp.AcpClient>.identity();
Completer<void>? _rawUnavailablePublicationGateForTesting;
final Completer<void> _rawUnavailablePublicationPausedForTesting =
    Completer<void>.sync();

bool _isCurrentPeerSource(acp.AcpClient source) =>
    identical(_client, source) ||
    identical(_connectingClient, source) ||
    _disposingPeerSources.contains(source);

void _publishPeerUnavailable(acp.AcpPeerUnavailableState state) {
  if (!_peerUnavailableStates.isClosed) _peerUnavailableStates.add(state);
}

void _handleTask11PeerUnavailable(
  acp.AcpClient source,
  acp.AcpPeerUnavailableState state,
) {
  if (!_isCurrentPeerSource(source)) return;
  final gate = _rawUnavailablePublicationGateForTesting;
  if (gate == null) {
    _publishPeerUnavailable(state);
    return;
  }
  if (!_rawUnavailablePublicationPausedForTesting.isCompleted) {
    _rawUnavailablePublicationPausedForTesting.complete();
  }
  unawaited(gate.future.then<void>((_) {
    if (identical(_rawUnavailablePublicationGateForTesting, gate)) {
      _rawUnavailablePublicationGateForTesting = null;
    }
    if (_isCurrentPeerSource(source)) _publishPeerUnavailable(state);
  }));
}

void _replacePeerUnavailableListener(acp.AcpClient source) {
  if (_peerUnavailableListenerClient != null ||
      _peerUnavailableListener != null) {
    throw StateError('Previous ACP unavailable listener is still installed.');
  }
  late final acp.AcpPeerUnavailableListener listener;
  listener = (state) => _handleTask11PeerUnavailable(source, state);
  _peerUnavailableListenerClient = source;
  _peerUnavailableListener = listener;
  source.addPeerUnavailableListener(listener);
}

acp.AcpPeerUnavailableListener? _listenerFor(acp.AcpClient? source) =>
    identical(_peerUnavailableListenerClient, source)
        ? _peerUnavailableListener
        : null;

void _removePeerUnavailableListenerAfterCoreDispose(
  acp.AcpClient source,
  acp.AcpPeerUnavailableListener listener,
) {
  source.removePeerUnavailableListener(listener);
  if (identical(_peerUnavailableListenerClient, source) &&
      identical(_peerUnavailableListener, listener)) {
    _peerUnavailableListenerClient = null;
    _peerUnavailableListener = null;
  }
}

@visibleForTesting
void holdNextRawUnavailablePublicationForTesting() {
  if (_rawUnavailablePublicationGateForTesting != null) {
    throw StateError('Raw unavailable publication is already held.');
  }
  _rawUnavailablePublicationGateForTesting = Completer<void>.sync();
}

@visibleForTesting
Future<void> get rawUnavailablePublicationPausedForTesting =>
    _rawUnavailablePublicationPausedForTesting.future;

@visibleForTesting
void releaseRawUnavailablePublicationForTesting() {
  final gate = _rawUnavailablePublicationGateForTesting;
  if (gate != null && !gate.isCompleted) gate.complete();
}

@visibleForTesting
acp.AcpClient get acpClientForTesting => _requireClient();

@visibleForTesting
Stream<acp.AcpPeerUnavailableState> get peerUnavailableForTesting =>
    _peerUnavailableStates.stream;

@visibleForTesting
acp.AcpPromptAdmissionProbeForTesting installRawAdmissionProbeForTesting() {
  if (_rawAdmissionProbeForTesting != null) {
    throw StateError('Raw admission probe is already armed.');
  }
  return _rawAdmissionProbeForTesting =
      _requireClient().armNextPromptAdmissionForTesting();
}

@visibleForTesting
Future<void> rawProviderSideEffectStartedForTesting(
  acp.AcpSessionInputBudgetOwner owner,
) {
  final probe = _rawAdmissionProbeForTesting;
  if (probe == null || !identical(probe.owner, owner)) {
    return Future<void>.error(StateError('Raw admission owner mismatch.'));
  }
  return probe.sideEffectStarted;
}
```

同一 Step 1 在 wrapper 加入纯 observation/control 字段与 API。counter 只初始化为零，claim/error 完成点仍由 Step 16/19/21 的真实行为调用；attachment gate 只暂停下一次真实附件转换，不代替转换结果：

```dart
final Map<acp.AcpSessionInputBudgetOwner, int> _rawDeliveryClaimCounts =
    HashMap<acp.AcpSessionInputBudgetOwner, int>.identity();
final Map<acp.AcpSessionInputBudgetOwner, int> _rawStreamCloseCounts =
    HashMap<acp.AcpSessionInputBudgetOwner, int>.identity();
final Map<acp.AcpSessionInputBudgetOwner, Completer<void>>
    _rawDeliveryClaimBarriers =
        HashMap<acp.AcpSessionInputBudgetOwner, Completer<void>>.identity();
final Map<acp.AcpSessionInputBudgetOwner, Completer<void>>
    _rawConnectionResultErrorsForTesting =
        HashMap<acp.AcpSessionInputBudgetOwner, Completer<void>>.identity();
int _rawPromptDispatchCount = 0;
int _rawPromptCancelCount = 0;
int _beginPromptTurnCount = 0;

@visibleForTesting
void Function(acp.AcpSessionInputBudgetOwner owner)?
    onRawPromptDispatchedForTesting;

Completer<void>? _rawAttachmentConversionGateForTesting;
Completer<void>? _rawAttachmentConversionPausedForTesting;

@visibleForTesting
int get rawPromptDispatchCountForTesting => _rawPromptDispatchCount;
@visibleForTesting
int get rawPromptCancelCountForTesting => _rawPromptCancelCount;
@visibleForTesting
int get beginPromptTurnCountForTesting => _beginPromptTurnCount;
@visibleForTesting
int rawDeliveryClaimCountForTesting(acp.AcpSessionInputBudgetOwner owner) =>
    _rawDeliveryClaimCounts[owner] ?? 0;
@visibleForTesting
int rawStreamCloseCountForTesting(acp.AcpSessionInputBudgetOwner owner) =>
    _rawStreamCloseCounts[owner] ?? 0;

@visibleForTesting
Future<void> rawConnectionResultErrorSeenForTesting(
  acp.AcpSessionInputBudgetOwner owner,
) => _rawConnectionResultErrorsForTesting
    .putIfAbsent(owner, Completer<void>.sync)
    .future;

@visibleForTesting
void holdRawDeliveryClaimForTesting(acp.AcpSessionInputBudgetOwner owner) {
  _rawDeliveryClaimBarriers.putIfAbsent(owner, Completer<void>.sync);
}

@visibleForTesting
void releaseRawDeliveryClaimForTesting(acp.AcpSessionInputBudgetOwner owner) {
  final barrier = _rawDeliveryClaimBarriers.remove(owner);
  if (barrier != null && !barrier.isCompleted) barrier.complete();
}

@visibleForTesting
void holdNextRawAttachmentConversionForTesting() {
  if (_rawAttachmentConversionGateForTesting != null) {
    throw StateError('Raw attachment conversion is already held.');
  }
  _rawAttachmentConversionGateForTesting = Completer<void>.sync();
  _rawAttachmentConversionPausedForTesting = Completer<void>.sync();
}

@visibleForTesting
Future<void> get rawAttachmentConversionPausedForTesting {
  final paused = _rawAttachmentConversionPausedForTesting;
  return paused?.future ?? Future<void>.error(
    StateError('Raw attachment conversion is not held.'),
  );
}

@visibleForTesting
void releaseRawAttachmentConversionForTesting() {
  final gate = _rawAttachmentConversionGateForTesting;
  if (gate != null && !gate.isCompleted) gate.complete();
}

Future<void> _waitForRawAttachmentConversionGateForTesting() async {
  final gate = _rawAttachmentConversionGateForTesting;
  if (gate == null) return;
  final paused = _rawAttachmentConversionPausedForTesting;
  if (paused != null && !paused.isCompleted) paused.complete();
  await gate.future;
  if (identical(_rawAttachmentConversionGateForTesting, gate)) {
    _rawAttachmentConversionGateForTesting = null;
    _rawAttachmentConversionPausedForTesting = null;
  }
}

Future<void> _waitForRawDeliveryClaimTestBarrier(
  acp.AcpSessionInputBudgetOwner owner,
) async {
  final barrier = _rawDeliveryClaimBarriers[owner];
  if (barrier != null) await barrier.future;
}
```

`_peerUnavailableStates` 是 wrapper 唯一 production raw unavailable分发器，同时提供只读测试投影；不得再建第二个 core listener。connect 在 `_connectingClient = client` 后、initialize 前立即 `_replacePeerUnavailableListener(client)`；开头的 reconnect cleanup 必须已完整 await旧 source的 core dispose与 listener移除，才允许安装新 identity。connect异常清理、reconnect `_disposeActiveClient` 与 public dispose 都先缓存 `_listenerFor(source)` 并把 source加入 `_disposingPeerSources`，再清 wrapper active/connecting字段并调用统一 `_disposeClient`：

```dart
Future<void> _disposeClient(
  acp.AcpClient? source,
  acp.AcpTransport? transport, [
  acp.AcpBoundedObservationListener? observationListener,
  acp.AcpPeerUnavailableListener? peerUnavailableListener,
]) async {
  if (source != null && observationListener != null) {
    source.removeBoundedObservationListener(observationListener);
  }
  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await transport?.stop();
  } on Object catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await source?.dispose().timeout(const Duration(milliseconds: 500));
  } on TimeoutException {
    // Keep the existing bounded core-dispose behavior.
  } on Object catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  } finally {
    if (source != null && peerUnavailableListener != null) {
      _removePeerUnavailableListenerAfterCoreDispose(
        source,
        peerUnavailableListener,
      );
    }
    if (source != null) _disposingPeerSources.remove(source);
  }
  if (firstError case final error?) {
    Error.throwWithStackTrace(error, firstStackTrace!);
  }
}
```

reconnect/public dispose 的 call-site 顺序固定为以下同步前缀；中间原有 cache、observation、raw/config queue清理保持原顺序，不能先移除 listener：

```dart
// _disposeActiveClient / reconnect:
await _invalidateAllRawPromptOperations(sendCancel: false);
final source = _client;
final listener = _listenerFor(source);
if (source != null) _disposingPeerSources.add(source);
_client = null;
// Clear the existing active fields/caches here.
await _disposeClient(source, transport, observationListener, listener);
// Only after this Future may connect install the next source listener.

// public dispose, for the connecting identity captured by _disposeAll:
final connectingSource = _connectingClient;
final connectingListener = _listenerFor(connectingSource);
if (connectingSource != null) _disposingPeerSources.add(connectingSource);
_connectingClient = null;
// Pass both captured values through _disposeAll to _disposeClient.
```

Task 11 在此处已经把 raw finished barrier 前移到 reconnect/dispose 共用的 `_disposeActiveClient`；必须 await 完成后才读取/清除 `_client`，所以旧 owner 与 stream done 不会跨进 replacement client。加入 `_disposingPeerSources` 必须发生在清除 `_client/_connectingClient` 之前；因此 stop/core dispose发出的真实 unavailable仍由原 source listener同步发布，raw stream可投一次 connectionClosed。listener只在 core dispose尝试完成后移除，随后才从 disposing set删除。public dispose在 connecting/active两个 source listener均移除后才 `await _peerUnavailableStates.close()`；reconnect不关闭该 controller。fixture 的 `unavailableSeen` 只复用 factory 启动时取得的 `peerUnavailableForTesting.first`，不声明同名 wrapper getter或测试 Completer。Task 13 不得重声明这些字段、安装/移除方法或 dispose/reconnect顺序；它只替换上述 `_handleTask11PeerUnavailable` body，在 publication gate 前追加 permission first-wins commit，并保留唯一 `_publishPeerUnavailable`。

wrapper 侧在 `dart_acp_agent_client_test.dart` 内从现有 `raw stream cancel before owner never sends prompt or leaks phase` 抽出 `_RawStdioFixture`；不得跨 test library 引用 private fixture。它保留真实 stdio agent，并公开真实 `client/events` 与下面完整扩展。

fixture 的字段、构造、启动、同步与清理必须在同一 test file 内完整落地。可以把现有 raw stdio test 的启动代码搬入 factory，但不能省略以下扩展；所有公开等待点都是 `Future<void>`，只有 fixture 内部真正需要主动完成的状态才保存 `Completer`：

```dart
final class _RawStdioFixture {
  _RawStdioFixture._({
    required this.tempDir,
    required this.client,
    required this.acpClient,
    required this.session,
    required this.promptSeenFile,
    required this.cancelSeenFile,
    required this.releaseResponseFile,
    required this.lateTerminalSentFile,
    required this.controlFile,
    required this.providerResponseFile,
    required this.requestFatalSeenFile,
    required Future<acp.AcpPeerUnavailableState> unavailable,
  }) : _unavailable = unavailable;

  final Directory tempDir;
  final DartAcpAgentClient client;
  final acp.AcpClient acpClient;
  final AgentSession session;
  final File promptSeenFile;
  final File cancelSeenFile;
  final File releaseResponseFile;
  final File lateTerminalSentFile;
  final File controlFile;
  final File providerResponseFile;
  final File requestFatalSeenFile;
  final Future<acp.AcpPeerUnavailableState> _unavailable;
  final StreamController<AgentEvent> _eventsController =
      StreamController<AgentEvent>.broadcast(sync: true);
  late final Stream<AgentEvent> events = _eventsController.stream;
  final Completer<void> _publicStreamDone = Completer<void>.sync();
  late final StreamSubscription<AgentEvent> _rawPromptSubscription;
  late final StreamSubscription<AcpPermissionRequest> permissionSubscription;
  late final acp.AcpPromptAdmissionProbeForTesting admissionProbe;
  bool _disposed = false;

  acp.AcpSessionInputBudgetOwner? _owner;
  Future<void>? _winnerRecorded;
  Future<void>? _rightRecorded;
  Future<void>? _preClaimSeen;
  Future<void>? _claimSeen;
  acp.AcpSessionInputBudgetOwner get owner => _owner ??
      (throw StateError('Raw prompt has not dispatched.'));
  int get promptCount => client.rawPromptDispatchCountForTesting;
  int get cancelCount => client.rawPromptCancelCountForTesting;
  int get beginPromptTurnCount => client.beginPromptTurnCountForTesting;
  int get deliveryClaimCount => client.rawDeliveryClaimCountForTesting(owner);
  int get streamCloseCount => client.rawStreamCloseCountForTesting(owner);

  static Future<_RawStdioFixture> startRawWithBlockedAdmission({
    acp.AcpTimeouts timeouts = const acp.AcpTimeouts(
      request: Duration(milliseconds: 100),
      permission: Duration(milliseconds: 100),
      promptCancelGrace: Duration(milliseconds: 750),
    ),
    String providerMethod = 'fs/read_text_file',
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('raw-stdio-');
    File path(String name) => File('${tempDir.path}/$name');
    final script = path('raw_agent.dart');
    final promptSeen = path('prompt-seen');
    final cancelSeen = path('cancel-seen');
    final releaseResponse = path('release-response');
    final lateTerminalSent = path('late-terminal-sent');
    final control = path('control');
    final providerResponse = path('provider-response');
    final requestFatalSeen = path('request-fatal-seen');
    await path('input.txt').writeAsString('fixed input');
    await script.writeAsString(_rawAgentSource);
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[
        script.path,
        promptSeen.path,
        cancelSeen.path,
        releaseResponse.path,
        lateTerminalSent.path,
        control.path,
        providerResponse.path,
        requestFatalSeen.path,
      ],
      timeouts: timeouts,
      enableFilesystemReadTextFile: true,
      enableFilesystemWriteTextFile: true,
      enableTerminalProvider: true,
    );
    await client.connect().timeout(const Duration(seconds: 2));
    final session = await client.createSession(cwd: tempDir.path);
    final unavailable = client.peerUnavailableForTesting.first;
    final fixture = _RawStdioFixture._(
      tempDir: tempDir,
      client: client,
      acpClient: client.acpClientForTesting,
      session: session,
      promptSeenFile: promptSeen,
      cancelSeenFile: cancelSeen,
      releaseResponseFile: releaseResponse,
      lateTerminalSentFile: lateTerminalSent,
      controlFile: control,
      providerResponseFile: providerResponse,
      requestFatalSeenFile: requestFatalSeen,
      unavailable: unavailable,
    );
    fixture.admissionProbe = client.installRawAdmissionProbeForTesting();
    fixture.permissionSubscription = client.permissionRequests.listen(
      (request) {
        unawaited(client.respondToPermissionRequest(
          id: request.id,
          decision: AcpPermissionDecision.allow,
        ));
      },
    );
    client.onRawPromptDispatchedForTesting = (owner) {
      if (fixture._owner != null) return;
      fixture._owner = owner;
      fixture._winnerRecorded =
          fixture.acpClient.promptWinnerRecordedForTesting(owner);
      fixture._rightRecorded =
          fixture.acpClient.promptRightRecordedForTesting(owner);
      fixture._preClaimSeen =
          fixture.acpClient.promptBarrierReleasedForTesting(owner);
      fixture._claimSeen =
          fixture.acpClient.promptClaimSeenForTesting(owner);
    };
    fixture._rawPromptSubscription = client
        .sendPrompt(
          sessionId: session.id,
          prompt: 'raw fixture prompt',
        )
        .listen(
          fixture._eventsController.add,
          onError: fixture._eventsController.addError,
          onDone: () {
            if (!fixture._publicStreamDone.isCompleted) {
              fixture._publicStreamDone.complete();
            }
            unawaited(fixture._eventsController.close());
          },
        );
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    fixture.startRawProviderAdmission(providerMethod);
    await fixture.admissionBarrierSeen.timeout(const Duration(seconds: 2));
    return fixture;
  }

  Future<void> get promptSeen => _waitForFile(promptSeenFile);
  Future<void> get cancelSeen => _waitForFile(cancelSeenFile);
  Future<void> get streamDone => _publicStreamDone.future;
  Future<void> get admissionBarrierSeen => admissionProbe.admissionBarrierSeen;
  Future<void> get graceStarted => admissionProbe.graceStarted;
  Future<void> get winnerRecorded => _winnerRecorded ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get rightRecorded => _rightRecorded ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get cleanupFatalSeen => _unavailable.then<void>((state) {
    if (state.reason != acp.AcpPeerUnavailableReason.fatalTimeout) {
      throw StateError('Expected cleanup fatal, got ${state.reason}.');
    }
  });
  Future<void> get backgroundReapDone => admissionProbe.reaped;
  Future<void> get lateTerminalSent => _waitForFile(lateTerminalSentFile);
  Future<void> get sideEffectStarted =>
      client.rawProviderSideEffectStartedForTesting(owner);
  Future<void> get preClaimSeen => _preClaimSeen ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get claimSeen => _claimSeen ??
      Future<void>.error(StateError('Raw prompt has not dispatched.'));
  Future<void> get unavailableSeen => _unavailable.then<void>((_) {});
  Future<Map<String, dynamic>> get providerResponse async {
    await _waitForFile(providerResponseFile);
    return Map<String, dynamic>.from(
      jsonDecode(await providerResponseFile.readAsString()) as Map,
    );
  }
  Future<void> get requestFatalSeen => _waitForFile(requestFatalSeenFile);
  Future<void> get connectionResultErrorSeen =>
      client.rawConnectionResultErrorSeenForTesting(owner);
  Future<void> get unavailablePublicationPaused =>
      client.rawUnavailablePublicationPausedForTesting;

  void completePromptSuccess() =>
      releaseResponseFile.writeAsStringSync('success');
  void completePromptError({
    int code = -32000,
    String message = 'fixed remote error',
    Map<String, Object?>? data,
  }) => releaseResponseFile.writeAsStringSync(jsonEncode(
        <String, Object?>{
          'code': code,
          'message': message,
          if (data != null) 'data': data,
        },
      ));
  void releaseLateSuccess() => completePromptSuccess();
  void releaseLateError() => completePromptError();
  void releaseAdmissionReservationOnly() =>
      admissionProbe.releaseReservationOnly();
  void releaseAdmissionCommit() => admissionProbe.releaseCommit();
  void requestTransportClose() => controlFile.writeAsStringSync('transport-close');
  void startRawProviderAdmission(String method) =>
      controlFile.writeAsStringSync('provider:$method');
  void holdDeliveryClaim() => client.holdRawDeliveryClaimForTesting(owner);
  void releaseDeliveryClaim() => client.releaseRawDeliveryClaimForTesting(owner);
  void holdUnavailablePublication() =>
      client.holdNextRawUnavailablePublicationForTesting();
  void releaseUnavailablePublication() =>
      client.releaseRawUnavailablePublicationForTesting();

  Future<void> requestFatal() async {
    final request = acpClient.sendRaw(
      '_raw/request-fatal',
      const <String, dynamic>{},
    );
    await requestFatalSeen.timeout(const Duration(seconds: 2));
    Object? failure;
    try {
      await request;
    } on Object catch (error) {
      failure = error;
    }
    if (failure == null) {
      throw StateError('Request-fatal probe unexpectedly succeeded.');
    }
  }

  Future<void> winUnavailableBeforeClaim(
    _RawUnavailableFirst first,
  ) async {
    final unavailable = unavailableSeen;
    switch (first) {
      case _RawUnavailableFirst.transportClose:
        requestTransportClose();
        break;
      case _RawUnavailableFirst.requestFatal:
        await requestFatal();
        break;
      case _RawUnavailableFirst.explicitClose:
        await client.closePeerExplicitlyForTesting();
        break;
      case _RawUnavailableFirst.dispose:
        await client.dispose();
        break;
    }
    await unavailable.timeout(const Duration(seconds: 2));
  }

  Future<List<AgentEvent>> startReplacement() => client
      .sendPrompt(sessionId: session.id, prompt: 'replacement')
      .toList()
      .timeout(const Duration(seconds: 2));

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    client.onRawPromptDispatchedForTesting = null;
    client.releaseRawUnavailablePublicationForTesting();
    await permissionSubscription.cancel();
    await _rawPromptSubscription.cancel();
    await client.dispose();
    if (!_eventsController.isClosed) await _eventsController.close();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

enum _RawUnavailableFirst { transportClose, requestFatal, explicitClose, dispose }
enum _RawCloseRaceOrder { listenerFirst, resultErrorFirst, userCancelFirst }
```

`DartAcpAgentClient` 的上述 `ForTesting` 入口只逐层返回真实 client/owner/counter/Future，`installRawAdmissionProbeForTesting` 只把 Task 6 已有真实 hook 的到达/释放投影到文件，不能完成 winner/right 或伪造计数。`timeouts` 是 Task 1 已加入 wrapper 的公开构造参数。
`holdRawDeliveryClaimForTesting/releaseRawDeliveryClaimForTesting` 只控制 Task 9 已有 pre-claim barrier；request-fatal 先等 agent 写 `requestFatalSeenFile` 证明已收到真实 `_raw/request-fatal`，再等待真实 request deadline；transport-close 由 agent 真正退出；explicit-close 走上面的 `_peer.close()` 代理且 wrapper 仍存活；dispose 才调 wrapper 自身。四者均不得直接发 unavailable event。winner、right、pre-claim、claim、unavailable 五个等待点都来自 production lifecycle/peer Future，不得用测试 Completer代替。

同一步把现有 inline stdio agent 抽成同文件顶层 `const _rawAgentSource`；完整可编译控制循环为：

```dart
const _rawAgentSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final promptSeen = File(args[0]);
  final cancelSeen = File(args[1]);
  final releaseResponse = File(args[2]);
  final lateTerminalSent = File(args[3]);
  final control = File(args[4]);
  final providerResponse = File(args[5]);
  final requestFatalSeen = File(args[6]);
  Map<String, dynamic>? promptRequest;
  var stopped = false;
  var providerSent = false;

  void send(Map<String, dynamic> message) {
    stdout.writeln(jsonEncode(message));
  }

  Future<void> poll() async {
    while (!stopped) {
      if (await control.exists() &&
          (await control.readAsString()).trim() == 'transport-close') {
        await stdout.flush();
        exit(0);
      }
      if (await control.exists()) {
        final action = (await control.readAsString()).trim();
        if (!providerSent && action.startsWith('provider:')) {
          providerSent = true;
          final method = action.substring('provider:'.length);
          final params = switch (method) {
            'fs/read_text_file' => <String, dynamic>{
              'sessionId': 'session-1',
              'path': 'input.txt',
            },
            'fs/write_text_file' => <String, dynamic>{
              'sessionId': 'session-1',
              'path': 'output.txt',
              'content': 'fixed output',
            },
            'terminal/create' => <String, dynamic>{
              'sessionId': 'session-1',
              'command': 'printf fixed',
              'args': <String>[],
            },
            _ => throw StateError('Unsupported provider method: $method'),
          };
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': 'raw-provider-1',
            'method': method,
            'params': params,
          });
          await stdout.flush();
        }
      }
      final current = promptRequest;
      if (current != null && await releaseResponse.exists()) {
        final terminal = (await releaseResponse.readAsString()).trim();
        promptRequest = null;
        if (terminal == 'success') {
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': current['id'],
            'result': <String, dynamic>{'stopReason': 'end_turn'},
          });
        } else {
          final error = Map<String, dynamic>.from(
            jsonDecode(terminal) as Map,
          );
          send(<String, dynamic>{
            'jsonrpc': '2.0',
            'id': current['id'],
            'error': error,
          });
        }
        await stdout.flush();
        await lateTerminalSent.writeAsString('sent');
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  final polling = poll();
  await for (final line in stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())) {
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    final message = Map<String, dynamic>.from(decoded);
    if (message['id'] == 'raw-provider-1' && message['method'] == null) {
      await providerResponse.writeAsString(jsonEncode(message));
      continue;
    }
    switch (message['method']) {
      case 'initialize':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{
            'protocolVersion': 1,
            'agentCapabilities': <String, dynamic>{
              'promptCapabilities': <String, dynamic>{},
            },
            'authMethods': <Map<String, dynamic>>[],
          },
        });
        break;
      case 'session/new':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{'sessionId': 'session-1'},
        });
        break;
      case 'session/prompt':
        promptRequest = message;
        await promptSeen.writeAsString('seen');
        break;
      case 'session/cancel':
        await cancelSeen.writeAsString('seen');
        break;
      case '_raw/request-fatal':
        await requestFatalSeen.writeAsString('seen');
        // Deliberately do not respond: the real request deadline must win.
        break;
      case 'logout':
        send(<String, dynamic>{
          'jsonrpc': '2.0',
          'id': message['id'],
          'result': <String, dynamic>{},
        });
        break;
    }
    await stdout.flush();
  }
  stopped = true;
  await polling;
}
''';
```

Task 13 需要的 permission/control 分支在其任务中继续扩展这一同文件常量；Task 11 本身不得引用尚未定义的 Task 13 fixture 字段。

- [ ] 2. 写 named RED `raw pre-owner cancel reconnect and dispose settle blocked attachment once`。使用下面独立的 fresh stdio fixture，不复用已自动发送 prompt 的 `_RawStdioFixture`；每个 cause 都用真实 `PromptAttachment.fromPath`，由 Step 1 的 gate 卡在真实 `_promptContentBlocks` 入口。gate 只在 `finally` 释放，因此 cancel/reconnect/dispose 必须在附件仍阻塞时于 2 秒内完成公开 stream；这条 RED 的失败必须来自旧行为不能收敛，而不是未定义测试符号：

```dart
enum _RawPreOwnerExit { cancel, reconnect, dispose }

final class _RawPreOwnerFixture {
  _RawPreOwnerFixture._({
    required this.tempDir,
    required this.client,
    required this.session,
    required this.attachment,
  });

  final Directory tempDir;
  final DartAcpAgentClient client;
  final AgentSession session;
  final PromptAttachment attachment;

  static Future<_RawPreOwnerFixture> start() async {
    final tempDir = await Directory.systemTemp.createTemp('raw-pre-owner-');
    File path(String name) => File('${tempDir.path}/$name');
    final script = path('raw_agent.dart');
    final attachmentFile = path('blocked.txt');
    await attachmentFile.writeAsString('fixed attachment');
    await script.writeAsString(_rawAgentSource);
    final client = DartAcpAgentClient(
      agentCommand: _dartExecutable(),
      agentArgs: <String>[
        script.path,
        path('prompt-seen').path,
        path('cancel-seen').path,
        path('release-response').path,
        path('late-terminal-sent').path,
        path('control').path,
        path('provider-response').path,
        path('request-fatal-seen').path,
      ],
    );
    await client.connect().timeout(const Duration(seconds: 2));
    final session = await client.createSession(cwd: tempDir.path);
    return _RawPreOwnerFixture._(
      tempDir: tempDir,
      client: client,
      session: session,
      attachment: PromptAttachment.fromPath(
        path: attachmentFile.path,
        mimeType: 'text/plain',
        size: await attachmentFile.length(),
      ),
    );
  }

  Future<void> dispose() async {
    client.releaseRawAttachmentConversionForTesting();
    await client.dispose();
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  }
}

test(
  'raw pre-owner cancel reconnect and dispose settle blocked attachment once',
  () async {
    for (final cause in _RawPreOwnerExit.values) {
      final fixture = await _RawPreOwnerFixture.start();
      final events = <AgentEvent>[];
      final streamErrors = <Object>[];
      final done = Completer<void>.sync();
      StreamSubscription<AgentEvent>? subscription;
      var doneCount = 0;
      try {
        fixture.client.holdNextRawAttachmentConversionForTesting();
        subscription = fixture.client
            .sendPrompt(
              sessionId: fixture.session.id,
              prompt: 'pre-owner-${cause.name}',
              attachments: <PromptAttachment>[fixture.attachment],
            )
            .listen(
              events.add,
              onError: (Object error, StackTrace _) => streamErrors.add(error),
              onDone: () {
                doneCount += 1;
                if (!done.isCompleted) done.complete();
              },
            );
        await fixture.client.rawAttachmentConversionPausedForTesting.timeout(
          const Duration(seconds: 2),
        );

        switch (cause) {
          case _RawPreOwnerExit.cancel:
            await fixture.client.cancel().timeout(const Duration(seconds: 2));
            break;
          case _RawPreOwnerExit.reconnect:
            await fixture.client.connect().timeout(const Duration(seconds: 2));
            expect(done.isCompleted, isTrue,
                reason: 'replacement cannot cross the old finished barrier');
            break;
          case _RawPreOwnerExit.dispose:
            await fixture.client.dispose().timeout(const Duration(seconds: 2));
            break;
        }

        await done.future.timeout(const Duration(seconds: 2));
        expect(streamErrors, isEmpty, reason: cause.name);
        expect(doneCount, 1, reason: cause.name);
        if (cause == _RawPreOwnerExit.dispose) {
          expect(events, hasLength(1));
          expect(events.single.type, AgentEventType.error);
          expect(events.single.text, 'ACP connection closed.');
        } else {
          expect(events, isEmpty, reason: cause.name);
        }
        expect(fixture.client.rawPromptDispatchCountForTesting, 0,
            reason: cause.name);
        expect(fixture.client.rawPromptCancelCountForTesting, 0,
            reason: cause.name);
        expect(fixture.client.beginPromptTurnCountForTesting, 0,
            reason: cause.name);
      } finally {
        fixture.client.releaseRawAttachmentConversionForTesting();
        await subscription?.cancel();
        await fixture.dispose();
      }
    }
  },
);
```

- [ ] 3. 运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw pre-owner cancel reconnect and dispose settle blocked attachment once"`。Expected: FAIL；旧实现要么卡在附件转换，要么在 replacement/dispose 返回后仍残留公开 stream，且 dispose 尚不能在 pre-owner 阶段精确投一次 connectionClosed/done。三个 case 都由 2 秒 watchdog 收敛。

- [ ] 4. 在 `test/acp/dart_acp_agent_client_test.dart` 写 named RED `raw cleanup fatal preserves one cached success terminal`；fixture 与测试位于同一 test library，不跨文件引用 private helper。先登记 success delivery right，再让同 owner admission response grace fatal。断言 `AgentEventType.agentTextDone` 恰一个、connection-closed error 为零、`fixture.deliveryClaimCount == 1`、`fixture.streamCloseCount == 1`；计数来自 wrapper 的真实调用点只读观察口。

```dart
final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
  timeouts: const acp.AcpTimeouts(
    request: Duration(milliseconds: 100),
    permission: Duration(milliseconds: 100),
    promptCancelGrace: Duration(milliseconds: 75),
  ),
);
try {
  final eventsFuture = fixture.events.toList();
  fixture.completePromptSuccess();
  await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
  await fixture.rightRecorded.timeout(const Duration(seconds: 2));
  await fixture.graceStarted.timeout(const Duration(seconds: 2));
  fixture.releaseAdmissionReservationOnly();
  await fixture.cleanupFatalSeen.timeout(const Duration(seconds: 2));
  final events = await eventsFuture.timeout(const Duration(seconds: 2));
  expect(events, hasLength(1));
  expect(events.single.type, AgentEventType.agentTextDone);
  expect(events.single.text, isEmpty);
  expect(events.single.metadata['kind'], 'turn');
  expect(events.single.metadata['stopReason'], 'endTurn');
  expect(fixture.deliveryClaimCount, 1);
  expect(fixture.streamCloseCount, 1);
} finally {
  await fixture.dispose();
}
```

- [ ] 5. 运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cleanup fatal preserves one cached success terminal"`。Expected: FAIL，旧 raw invalidation 会丢 success 或重复 close。

- [ ] 6. 在 `test/acp/dart_acp_agent_client_test.dart` 写 named RED `raw cleanup fatal preserves one cached remote error terminal`；复用同文件 `_RawStdioFixture`，不得引用 `acp_request_timeout_test.dart` 的 private core。先登记 remote error delivery right，再触发同 owner cleanup fatal。断言固定 remote error 投影恰一个、connection-closed error 为零、claim 与 stream close 各一次。

```dart
final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
  timeouts: const acp.AcpTimeouts(
    request: Duration(milliseconds: 100),
    permission: Duration(milliseconds: 100),
    promptCancelGrace: Duration(milliseconds: 75),
  ),
);
try {
  final eventsFuture = fixture.events.toList();
  const canary = 'raw-remote-secret-canary';
  fixture.completePromptError(
    code: -32000,
    message: 'fixed remote error',
    data: const <String, Object?>{
      'path': '/private/raw-remote-secret-canary',
      'payload': <String, Object?>{
        'token': 'raw-remote-secret-canary',
      },
    },
  );
  await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
  await fixture.rightRecorded.timeout(const Duration(seconds: 2));
  await fixture.graceStarted.timeout(const Duration(seconds: 2));
  fixture.releaseAdmissionReservationOnly();
  await fixture.cleanupFatalSeen.timeout(const Duration(seconds: 2));
  final events = await eventsFuture.timeout(const Duration(seconds: 2));
  final errors = events.where((e) => e.type == AgentEventType.error).toList();
  expect(events, hasLength(1));
  expect(errors, hasLength(1));
  expect(errors.single.text, 'fixed remote error');
  expect(errors.single.text, isNot('ACP connection closed.'));
  expect(errors.single.metadata, const <String, Object?>{
    'kind': 'turn',
    'terminalKind': 'remoteError',
  });
  expect(
    jsonEncode(<String, Object?>{
      'text': errors.single.text,
      'metadata': errors.single.metadata,
    }),
    isNot(contains(canary)),
  );
  expect(fixture.deliveryClaimCount, 1);
  expect(fixture.streamCloseCount, 1);
} finally {
  await fixture.dispose();
}
```

- [ ] 7. 运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cleanup fatal preserves one cached remote error terminal"`。Expected: FAIL，旧 raw 状态不能保留 error winner。

- [ ] 8. 写 named RED `raw admission fatal before terminal winner cannot backfill a delivery right`；顺序固定为开始 raw prompt、取得 request id、owner admission response grace 先 fatal、确认 right 不存在、再注入迟到 success。这里明确复用并扩展 Task 6 的真实 `_PermissionAdmissionHarness`：

```dart
final core = await _PermissionAdmissionHarness.start(
  timeouts: const AcpTimeouts(
    permission: Duration(milliseconds: 100),
    promptCancelGrace: Duration(milliseconds: 75),
  ),
);
try {
  final operation = await core.startRawPrompt();
  final expiry = core.expireOwnerAdmissionResponseGrace(operation.owner);
  await core.admissionResponseGraceStarted(operation.owner).timeout(
    const Duration(seconds: 2),
  );
  await expiry;
  expect(core.peerUnavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
  expect(operation.acpClient.hasPromptDeliveryRight(operation.owner), isFalse);
  core.completeRawPromptSuccess(operation);
  await expectLater(
    operation.result,
    throwsA(isA<AcpConnectionClosedException>()),
  );
  expect(operation.acpClient.hasPromptDeliveryRight(operation.owner), isFalse);
} finally {
  await core.dispose();
}
```

core harness 只验证 manager lifecycle/right，不再断言 wrapper event、delivery claim 或 stream close计数；这些断言全部由同文件 `_RawStdioFixture` 的真实 wrapper观察口承担。

- [ ] 9. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw admission fatal before terminal winner cannot backfill a delivery right"`。Expected: FAIL，迟到 response 仍可能补签 right。

- [ ] 10. 写七个 named RED。原四条 raw lifecycle RED 加 provider success、provider remote error、四 unavailable 首因三条；全部使用真实同步点，不能用 `Future.delayed` 猜 race。`raw external close and terminal claim are first wins` 的关键 body 为：

```dart
for (final closeFirst in <bool>[true, false]) {
  final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
  try {
    final eventsFuture = fixture.events.toList();
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    fixture.holdDeliveryClaim();
    fixture.completePromptSuccess();
    await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
    await fixture.rightRecorded.timeout(const Duration(seconds: 2));
    await fixture.preClaimSeen.timeout(const Duration(seconds: 2));
    final unavailable = fixture.unavailableSeen;
    if (closeFirst) {
      await fixture.client.closePeerExplicitlyForTesting();
      await unavailable.timeout(const Duration(seconds: 2));
      fixture.releaseDeliveryClaim();
    } else {
      fixture.releaseDeliveryClaim();
      await fixture.claimSeen.timeout(const Duration(seconds: 2));
      await fixture.client.closePeerExplicitlyForTesting();
      await unavailable.timeout(const Duration(seconds: 2));
    }
    final events = await eventsFuture.timeout(const Duration(seconds: 2));
    final connectionClosed = events.where(
      (event) => event.type == AgentEventType.error &&
          event.text == 'ACP connection closed.',
    );
    final cachedTerminal = events.where(
      (event) => event.type == AgentEventType.agentTextDone,
    );
    expect(connectionClosed, closeFirst ? hasLength(1) : isEmpty);
    expect(cachedTerminal, closeFirst ? isEmpty : hasLength(1));
    expect(fixture.deliveryClaimCount, closeFirst ? 0 : 1);
    expect(fixture.streamCloseCount, 1);
  } finally {
    await fixture.dispose();
  }
}
```

`raw cancel after dispatch closes stream while background reap continues`：等真实 `promptSeen` 后调用 wrapper cancel；cancel 返回时 raw 已不接受 terminal、事件流 done 恰一次，但 Task 9 manager cleanup/reap 仍后台等待原 response/admission。迟到 response 到达前 replacement 固定被 active-or-settling 拒绝；释放原 response与 admission后 replacement 成功。

`raw cancel or close before terminal hook cannot backfill right`：参数化 owner cancel 与 peer close，两者都先于 terminal hook。等 `cancelSeen`/`unavailableSeen` 后注入 success，断言 `hasPromptDeliveryRight == false`、claim 0；这严格复用 Task 9 “terminal hook 只有 pending lifecycle 才能创建 right”的约定。

```dart
for (final closePeer in <bool>[false, true]) {
  for (final lateError in <bool>[false, true]) {
    final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
    try {
      final eventsFuture = fixture.events.toList();
      await fixture.promptSeen.timeout(const Duration(seconds: 2));
      if (closePeer) {
        final unavailable = fixture.unavailableSeen;
        await fixture.client.closePeerExplicitlyForTesting();
        await unavailable.timeout(const Duration(seconds: 2));
      } else {
        await fixture.client.cancel().timeout(const Duration(seconds: 2));
        await fixture.cancelSeen.timeout(const Duration(seconds: 2));
      }
      expect(fixture.acpClient.hasPromptDeliveryRight(fixture.owner), isFalse);
      if (lateError) {
        fixture.releaseLateError();
      } else {
        fixture.releaseLateSuccess();
      }
      await fixture.lateTerminalSent.timeout(const Duration(seconds: 2));
      expect(fixture.acpClient.hasPromptDeliveryRight(fixture.owner), isFalse);
      expect(fixture.deliveryClaimCount, 0);
      expect(fixture.streamCloseCount, 1);
      final events = await eventsFuture.timeout(const Duration(seconds: 2));
      expect(
        events.where((event) => event.type == AgentEventType.agentTextDone),
        isEmpty,
      );
      expect(
        events.where((event) => event.type == AgentEventType.error),
        closePeer ? hasLength(1) : isEmpty,
      );
    } finally {
      await fixture.dispose();
    }
  }
}
```

`raw late success and error after cancel emit zero terminals`：参数化 `releaseLateSuccess/releaseLateError`，dispatch 后取消并等 stream done，再释放迟到终态；断言 terminal/error 事件都为 0、done 仍为 1、cancel 为 1。等后台 reap barrier 完成后第二轮 prompt 成功，证明不是直接丢弃原 request Future。

```dart
for (final lateError in <bool>[false, true]) {
  final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
  try {
    final events = <AgentEvent>[];
    var doneCount = 0;
    final done = Completer<void>.sync();
    fixture.events.listen(
      events.add,
      onDone: () {
        doneCount += 1;
        done.complete();
      },
    );
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    await fixture.client.cancel().timeout(const Duration(seconds: 2));
    await done.future.timeout(const Duration(seconds: 2));
    expect(events, isEmpty);
    expect(doneCount, 1);
    expect(fixture.cancelCount, 1);
    await expectLater(
      fixture.startReplacement(),
      throwsA(isA<StateError>()),
    );
    if (lateError) {
      fixture.releaseLateError();
    } else {
      fixture.releaseLateSuccess();
    }
    fixture.releaseAdmissionCommit();
    await fixture.backgroundReapDone.timeout(const Duration(seconds: 2));
    expect(events, isEmpty);
    expect(doneCount, 1);
    expect(await fixture.startReplacement(), isNotEmpty);
  } finally {
    await fixture.dispose();
  }
}
```

`raw fs read write and terminal allow side effects before success` 与 `raw fs read write and terminal allow side effects before remote error`：两条 named RED 都在 `dart_acp_agent_client_test.dart` 使用上述同文件 fixture，各自遍历 `fs/read_text_file`、`fs/write_text_file`、`terminal/create`。真实 provider policy 选择 allow 后，必须先等 Task 6 admission 进入真实 side effect，再允许 response commit；agent 从 stdin 捕获的 provider response 必须是 success。随后分别释放 raw prompt success/remote error，直接等 Task 9 winner/right Future，再断言 raw terminal 恰一次。关键 body 为：

```dart
for (final terminalError in <bool>[false, true]) {
  for (final method in const <String>[
    'fs/read_text_file',
    'fs/write_text_file',
    'terminal/create',
  ]) {
    final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
      providerMethod: method,
    );
    try {
      final eventsFuture = fixture.events.toList();
      await fixture.promptSeen.timeout(const Duration(seconds: 2));
      await fixture.sideEffectStarted.timeout(const Duration(seconds: 2));
      fixture.releaseAdmissionCommit();
      final providerResponse = await fixture.providerResponse.timeout(
        const Duration(seconds: 2),
      );
      expect(providerResponse['error'], isNull, reason: method);
      if (terminalError) {
        fixture.completePromptError();
      } else {
        fixture.completePromptSuccess();
      }
      await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
      await fixture.rightRecorded.timeout(const Duration(seconds: 2));
      final events = await eventsFuture.timeout(const Duration(seconds: 2));
      expect(fixture.deliveryClaimCount, 1, reason: method);
      expect(fixture.streamCloseCount, 1, reason: method);
      expect(
        events.where((event) => event.type == AgentEventType.error).length,
        terminalError ? 1 : 0,
        reason: method,
      );
    } finally {
      await fixture.dispose();
    }
  }
}
```

两条测试按 `terminalError` 分拆为独立 named test，不能把循环包在同一个 test 后让一半场景失败时遮住另一半。

`raw transport request fatal explicit close and dispose before claim revoke right`：每个 case 都先安装真实 claim barrier，再完成 success并只等待独立 `winnerRecorded/rightRecorded`；随后让 transport close、真实 request deadline fatal、underlying explicit close、wrapper dispose 之一在 claim 前首赢。释放 barrier后 claim 必须失败，迟到 terminal 不得补 right或投 raw terminal：

```dart
for (final first in _RawUnavailableFirst.values) {
  final fixture = await _RawStdioFixture.startRawWithBlockedAdmission(
    timeouts: const acp.AcpTimeouts(
      request: Duration(milliseconds: 250),
      permission: Duration(milliseconds: 100),
      promptCancelGrace: Duration(milliseconds: 750),
    ),
  );
  try {
    final eventsFuture = fixture.events.toList();
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    fixture.holdDeliveryClaim();
    fixture.completePromptSuccess();
    await fixture.winnerRecorded.timeout(const Duration(seconds: 2));
    await fixture.rightRecorded.timeout(const Duration(seconds: 2));
    await fixture.preClaimSeen.timeout(const Duration(seconds: 2));
    await fixture.winUnavailableBeforeClaim(first);
    fixture.releaseDeliveryClaim();
    expect(
      fixture.acpClient.hasPromptDeliveryRight(fixture.owner),
      isFalse,
      reason: first.name,
    );
    expect(fixture.deliveryClaimCount, 0, reason: first.name);
    expect(fixture.streamCloseCount, 1, reason: first.name);
    final events = await eventsFuture.timeout(const Duration(seconds: 2));
    expect(events, hasLength(1), reason: first.name);
    expect(events.single.type, AgentEventType.error, reason: first.name);
    expect(events.single.text, 'ACP connection closed.', reason: first.name);
  } finally {
    await fixture.dispose();
  }
}
```

这里 `owner` 在 underlying close/dispose 后仍由 fixture 缓存同一个 owner identity，不能通过读取已经清除的 active owner getter获得。缓存发生在 Step 18 `beginPromptTurn` 后的同步 `onRawPromptDispatchedForTesting(owner)` 回调中，早于 prompt wire dispatch；同时缓存 winner/right/pre-claim/claim 四个真实 Future。`promptSeen` 只证明 agent 收到 wire，不负责补抓 owner。上述 success、remote error、connection closed 三组断言读取的都必须是 `fixture.events`，即最外层公开 `DartAcpAgentClient.sendPrompt(...).listen(...)` 的输出；测试不得直接订阅 `_sendRawPrompt` 或内部 controller，否则无法捕获外层二次过滤回归。

再写 named RED `raw connection closed and close are once across callback orders`。listener-first走正常 source listener同步发布；result-error-first只用 Task 11 的 publication gate暂停 wrapper分发，等 owner-bound result真实完成 `AcpConnectionClosedException` 后再释放；user-cancel-first先依次 await cancel notification 与 fixture 从最外层公开 stream `onDone` 完成的独立 `streamDone`，不得用稍后统一等待的 `eventsFuture` 冒充 done，然后才让真实 transport close迟到。三者都必须经过 `_finishRawOutput`；前两者各投一个 connectionClosed，用户 cancel不投 error，但三者 stream close计数都只能为1：

```dart
for (final order in _RawCloseRaceOrder.values) {
  final fixture = await _RawStdioFixture.startRawWithBlockedAdmission();
  try {
    final eventsFuture = fixture.events.toList();
    await fixture.promptSeen.timeout(const Duration(seconds: 2));
    switch (order) {
      case _RawCloseRaceOrder.listenerFirst:
        fixture.requestTransportClose();
        await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
        break;
      case _RawCloseRaceOrder.resultErrorFirst:
        fixture.holdUnavailablePublication();
        final resultError = fixture.connectionResultErrorSeen;
        fixture.requestTransportClose();
        await fixture.unavailablePublicationPaused.timeout(
          const Duration(seconds: 2),
        );
        await resultError.timeout(const Duration(seconds: 2));
        fixture.releaseUnavailablePublication();
        await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
        break;
      case _RawCloseRaceOrder.userCancelFirst:
        await fixture.client.cancel().timeout(const Duration(seconds: 2));
        await fixture.cancelSeen.timeout(const Duration(seconds: 2));
        await fixture.streamDone.timeout(const Duration(seconds: 2));
        fixture.requestTransportClose();
        await fixture.unavailableSeen.timeout(const Duration(seconds: 2));
        break;
    }
    final events = await eventsFuture.timeout(const Duration(seconds: 2));
    final connectionClosed = events.where(
      (event) => event.type == AgentEventType.error &&
          event.text == 'ACP connection closed.',
    );
    expect(
      connectionClosed,
      order == _RawCloseRaceOrder.userCancelFirst
          ? isEmpty
          : hasLength(1),
      reason: order.name,
    );
    expect(events.length, connectionClosed.length, reason: order.name);
    expect(fixture.streamCloseCount, 1, reason: order.name);
  } finally {
    fixture.releaseUnavailablePublication();
    await fixture.dispose();
  }
}
```

- [ ] 11. 运行八个精确 RED：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw external close and terminal claim are first wins"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cancel after dispatch closes stream while background reap continues"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cancel or close before terminal hook cannot backfill right"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw late success and error after cancel emit zero terminals"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw fs read write and terminal allow side effects before success"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw fs read write and terminal allow side effects before remote error"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw transport request fatal explicit close and dispose before claim revoke right"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw connection closed and close are once across callback orders"
```

Expected: FAIL，旧实现会继续接收 terminal、补签 right、重复 close，或取消时错误等待完整 reap。

- [ ] 12. 写 named RED `raw session prompt cannot bypass owner bound api`；两层 `sendRaw` 都得到 `StateError('session/prompt must use owner-bound API.')`，Task 6 真实 wire 的 prompt 计数为 0。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw session prompt cannot bypass owner bound api"`。Expected: FAIL，当前仍允许绕过。

- [ ] 14. 在 `SessionManager` 为 Step 1 已定义并导出的 `AcpPromptDeliveryClaim` 补 manager-owned 原子 wait/claim/release 行为。Step 1 的 lifecycle 字段、opaque 类型与两个只读查询保持原样，不在这里重复声明；只读查询不得创建、恢复或 claim right，raw 不能自行用 local bool 代替 manager claim：

```dart
Future<bool> waitForPromptDeliveryBarrier(
  AcpSessionInputBudgetOwner owner,
) async {
  final lifecycle = _promptLifecycles[owner.sessionId];
  if (lifecycle == null || !identical(lifecycle.owner, owner)) {
    return false;
  }
  final cleanup = lifecycle.cleanupFuture;
  if (lifecycle.winner == null ||
      lifecycle.deliveryRight == null ||
      cleanup == null) {
    return false;
  }
  try {
    await cleanup;
  } on Object {
    if (lifecycle.winner == null || lifecycle.deliveryRight == null) rethrow;
  }
  if (!lifecycle.barrierReleased.isCompleted) {
    lifecycle.barrierReleased.complete();
  }
  return true;
}

AcpPromptDeliveryClaim? tryClaimPromptDeliveryRight(
  AcpSessionInputBudgetOwner owner,
) {
  final lifecycle = _promptLifecycles[owner.sessionId];
  final right = lifecycle?.deliveryRight;
  if (lifecycle == null ||
      !identical(lifecycle.owner, owner) ||
      lifecycle.activeDeliveryClaim != null ||
      right == null ||
      !right.tryClaim()) {
    return null;
  }
  final claim = AcpPromptDeliveryClaim._(
    owner: owner,
    winner: right.winner,
    rightIdentity: right,
  );
  lifecycle.activeDeliveryClaim = claim;
  if (!lifecycle.claimSeen.isCompleted) lifecycle.claimSeen.complete();
  return claim;
}

void releasePromptDeliveryRight(AcpPromptDeliveryClaim claim) {
  final lifecycle = _promptLifecycles[claim.owner.sessionId];
  final right = lifecycle?.deliveryRight;
  if (lifecycle == null ||
      !identical(lifecycle.owner, claim.owner) ||
      !identical(lifecycle.activeDeliveryClaim, claim) ||
      !identical(right, claim._rightIdentity)) {
    return;
  }
  lifecycle.activeDeliveryClaim = null;
  _releaseClaimedPromptLifecycle(lifecycle);
}

void _releaseClaimedPromptLifecycle(_PromptLifecycle lifecycle) {
  final current = _promptLifecycles[lifecycle.owner.sessionId];
  final right = lifecycle.deliveryRight;
  if (!identical(current, lifecycle) ||
      lifecycle.removed ||
      lifecycle.activeDeliveryClaim != null ||
      right == null ||
      right.state != _PromptDeliveryRightState.claimed) {
    return;
  }
  right.state = _PromptDeliveryRightState.revoked;
  _releasePromptLifecycle(lifecycle);
}
```

所有 revoke/unavailable/session close 路径先检查 `activeDeliveryClaim` 或 `right.state == claimed`；claim 已成功时不得抢先 remove lifecycle，唯一 release 点是上述 helper。owner cancel、session close、transport/request fatal、explicit close、dispose 若先于 terminal hook，则先写 cancellation/unavailable winner 并 revoke pending right；后到 success/error 的 terminal hook看到 lifecycle 非 pending后直接返回，不能补建 right。

- [ ] 15. 在 `AcpClient` 为 Step 1 的两个只读代理补 wait/claim/release 代理，不缓存第二份状态：

```dart
Future<bool> waitForPromptDeliveryBarrier(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.waitForPromptDeliveryBarrier(owner);

AcpPromptDeliveryClaim? tryClaimPromptDeliveryRight(
  AcpSessionInputBudgetOwner owner,
) => _sessionManager.tryClaimPromptDeliveryRight(owner);

void releasePromptDeliveryRight(AcpPromptDeliveryClaim claim) =>
    _sessionManager.releasePromptDeliveryRight(claim);
```

- [ ] 16. 用带方法体状态机替换 raw 布尔组合：

```dart
enum _RawPromptOperationState { active, terminalOnly, invalidated, finished }

final class _RawPromptOperation {
  _RawPromptOperation(this.sessionId);
  final String sessionId;
  acp.AcpSessionInputBudgetOwner? owner;
  _RawPromptOperationState state = _RawPromptOperationState.active;
  bool cancelRequested = false;
  bool cancelSent = false;
  bool terminalClaimed = false;
  bool unavailableWonBeforeTerminal = false;
  bool streamClosed = false;
  Future<void> Function()? enterTerminalOnlyAction;
  Future<void> Function({required bool emitConnectionClosed})?
      finishOutputAction;
  Future<void>? _terminalOnlyEntered;
  final Completer<void> streamCancellation = Completer<void>();
  final Completer<void> _finished = Completer<void>.sync();

  Future<void> get finished => _finished.future;

  void markFinished() {
    if (!_finished.isCompleted) _finished.complete();
  }

  bool get acceptsUpdates =>
      state == _RawPromptOperationState.active && !cancelRequested;
  bool get acceptsTerminal =>
      state == _RawPromptOperationState.active ||
      state == _RawPromptOperationState.terminalOnly;

  Future<void> enterTerminalOnly() {
    final action = enterTerminalOnlyAction;
    if (action == null) return Future<void>.value();
    return _terminalOnlyEntered ??= action();
  }

  Future<void> finishOutput({required bool emitConnectionClosed}) =>
      finishOutputAction?.call(
        emitConnectionClosed: emitConnectionClosed,
      ) ??
      Future<void>.error(
        StateError('Raw output settlement is not installed.'),
      );

  bool handleUnavailable({
    required bool sameOwnerCleanupFatal,
    required bool deliveryRightExists,
  }) {
    if (state != _RawPromptOperationState.active) return false;
    if (sameOwnerCleanupFatal && deliveryRightExists) {
      state = _RawPromptOperationState.terminalOnly;
      return false;
    }
    unavailableWonBeforeTerminal = true;
    state = _RawPromptOperationState.invalidated;
    return true;
  }

  bool tryAcceptClaimedTerminal() {
    if (!acceptsTerminal || unavailableWonBeforeTerminal || terminalClaimed) {
      return false;
    }
    terminalClaimed = true;
    state = _RawPromptOperationState.finished;
    return true;
  }

  bool tryCloseStream() {
    if (streamClosed) return false;
    streamClosed = true;
    return true;
  }
}

final class _RawAttachmentConversionOutcome {
  const _RawAttachmentConversionOutcome.content(this.content)
      : error = null,
        stackTrace = null,
        cancelled = false;
  const _RawAttachmentConversionOutcome.error(this.error, this.stackTrace)
      : content = null,
        cancelled = false;
  const _RawAttachmentConversionOutcome.cancelled()
      : content = null,
        error = null,
        stackTrace = null,
        cancelled = true;

  final List<Map<String, dynamic>>? content;
  final Object? error;
  final StackTrace? stackTrace;
  final bool cancelled;
}

bool _tryCloseRawStream(_RawPromptOperation operation) {
  if (!operation.tryCloseStream()) return false;
  final owner = operation.owner;
  if (owner != null) {
    _rawStreamCloseCounts.update(owner, (count) => count + 1,
        ifAbsent: () => 1);
  }
  return true;
}
```

这些计数只在下面真实 begin/dispatch/cancel/manager-claim/stream-close 调用点递增，fixture 只读；不得由测试动作或 control file直接修改。owner callback 与四个 lifecycle Future在同一同步 dispatch 栈缓存，因此 close/remove 后仍可等待原 identity。

同一步把 wrapper 的四个 raw 入口整体迁到上述 enum；以下方法体替换旧 `finished/locallyInvalidated/acceptsEvents` 分支：

```dart
@override
Stream<AgentEvent> sendPrompt({
  required String sessionId,
  required String prompt,
  List<PromptAttachment> attachments = const <PromptAttachment>[],
}) {
  late final StreamController<AgentEvent> controller;
  final operation = _RawPromptOperation(sessionId);
  controller = StreamController<AgentEvent>(
    onListen: () {
      final client = _requireClient();
      if (_rawPromptOperationsBySession.containsKey(sessionId)) {
        controller.addError(StateError('An ACP prompt operation is already active.'));
        unawaited(controller.close());
        return;
      }
      _rawPromptOperationsBySession[sessionId] = operation;
      // Install the real public-output settlement before any attachment await.
      // cancel/reconnect/dispose can therefore win while conversion is blocked.
      operation.finishOutputAction = ({required bool emitConnectionClosed}) async {
        if (emitConnectionClosed &&
            operation.state != _RawPromptOperationState.finished) {
          operation.unavailableWonBeforeTerminal = true;
          operation.state = _RawPromptOperationState.invalidated;
        }
        if (!operation.streamCancellation.isCompleted) {
          operation.streamCancellation.complete();
        }
        await operation.enterTerminalOnly();
        await _finishRawOutput(
          operation,
          controller,
          emitConnectionClosed: emitConnectionClosed,
        );
      };
      unawaited(_runRawPromptOperation(
        client: client,
        operation: operation,
        prompt: prompt,
        attachments: attachments,
        output: controller,
      ));
    },
    onCancel: () async {
      await _invalidateRawPromptOperation(
        _requireClient(),
        operation,
        sendCancel: true,
      );
    },
  );
  return controller.stream;
}

Future<void> _runRawPromptOperation({
  required acp.AcpClient client,
  required _RawPromptOperation operation,
  required String prompt,
  required List<PromptAttachment> attachments,
  required StreamController<AgentEvent> output,
}) async {
  try {
    if (operation.state != _RawPromptOperationState.active) return;
    final conversion = () async {
      await _waitForRawAttachmentConversionGateForTesting();
      return _promptContentBlocks(
        prompt,
        attachments,
        workspaceRoot: _cwdBySession[operation.sessionId],
      );
    }().then<_RawAttachmentConversionOutcome>(
      _RawAttachmentConversionOutcome.content,
      onError: (Object error, StackTrace stackTrace) =>
          _RawAttachmentConversionOutcome.error(error, stackTrace),
    );
    // Both branches own value/error consumers before the race starts. A late
    // attachment value or error is consumed after cancellation wins.
    final conversionOutcome = await Future.any<_RawAttachmentConversionOutcome>(
      <Future<_RawAttachmentConversionOutcome>>[
        conversion,
        operation.streamCancellation.future.then(
          (_) => const _RawAttachmentConversionOutcome.cancelled(),
        ),
      ],
    );
    if (conversionOutcome.cancelled) return;
    final conversionError = conversionOutcome.error;
    if (conversionError != null) {
      Error.throwWithStackTrace(
        conversionError,
        conversionOutcome.stackTrace!,
      );
    }
    if (operation.cancelRequested ||
        operation.state != _RawPromptOperationState.active) {
      return;
    }
    await _sendRawPrompt(
      client: client,
      operation: operation,
      content: conversionOutcome.content!,
      output: output,
    );
  } on Object catch (error, stackTrace) {
    if (operation.state == _RawPromptOperationState.active &&
        !output.isClosed) {
      output.addError(error, stackTrace);
    }
  } finally {
    await operation.enterTerminalOnly();
    operation.state = _RawPromptOperationState.finished;
    if (identical(
      _rawPromptOperationsBySession[operation.sessionId],
      operation,
    )) {
      _rawPromptOperationsBySession.remove(operation.sessionId);
    }
    // Public close is part of the barrier. markFinished is always last.
    await _finishRawOutput(
      operation,
      output,
      emitConnectionClosed: false,
    );
    operation.markFinished();
  }
}

Future<void> _invalidateRawPromptOperation(
  acp.AcpClient client,
  _RawPromptOperation operation, {
  required bool sendCancel,
}) async {
  if (operation.state == _RawPromptOperationState.finished) return;
  operation.cancelRequested = true;
  operation.unavailableWonBeforeTerminal = true;
  operation.state = _RawPromptOperationState.invalidated;
  if (!operation.streamCancellation.isCompleted) {
    operation.streamCancellation.complete();
  }
  await operation.enterTerminalOnly();
  final owner = operation.owner;
  if (owner != null && sendCancel && !operation.cancelSent) {
    operation.cancelSent = true;
    _rawPromptCancelCount += 1;
    await client.cancelPromptTurn(owner);
  }
  await operation.finishOutput(emitConnectionClosed: false);
}

Future<void> _invalidateAllRawPromptOperations({
  required bool sendCancel,
}) async {
  final client = _client;
  if (client == null) return;
  final snapshot = _rawPromptOperationsBySession.values.toList(growable: false);
  final invalidations = <Future<void>>[
    for (final operation in snapshot)
      _invalidateRawPromptOperation(client, operation, sendCancel: sendCancel),
  ];
  try {
    await Future.wait<void>(invalidations, eagerError: false);
  } finally {
    await Future.wait<void>(<Future<void>>[
      for (final operation in snapshot) operation.finished,
    ], eagerError: false);
  }
}

Future<void> _finishAllRawOutputsForUnavailable() async {
  final snapshot = _rawPromptOperationsBySession.values.toList(growable: false);
  final settlements = <Future<void>>[
    for (final operation in snapshot)
      operation.finishOutput(emitConnectionClosed: true),
  ];
  try {
    await Future.wait<void>(settlements, eagerError: false);
  } finally {
    await Future.wait<void>(<Future<void>>[
      for (final operation in snapshot) operation.finished,
    ], eagerError: false);
  }
}
```

`sendPrompt.onListen` 在 map 登记后、启动 `_runRawPromptOperation` 前安装唯一公开 output settlement；因此 attachment conversion 尚未返回时，cancel/reconnect/dispose 也已有真实 close owner。`_runRawPromptOperation` 的 conversion Future 在参与 `Future.any` 前已安装 value/error consumer，`streamCancellation` 首赢后不等待 gate，迟到 conversion value/error 只被消费。最外层 finally 固定按 `enterTerminalOnly → identity map remove → 公开 output close → operation.markFinished` 执行，任何内部 terminal/close 都不得提前完成 `finished`。`_invalidateAllRawPromptOperations` 先构造全部 invalidation Future（触发整批状态切换），再 await invalidation，且 finally 必须 await snapshot 每个 `finished`；因此旧 stream done、owner end 与 map remove 都在 barrier 返回前完成。reconnect 调 `_invalidateAllRawPromptOperations(sendCancel: false)`，公开流无 terminal；public dispose 调 `_finishAllRawOutputsForUnavailable()`，公开流精确投一次 connectionClosed 后 done；pre-owner 两者都不创建 owner、不发 prompt RPC或 cancel notification。迁移提交必须运行 `rg -n "bool finished|locallyInvalidated|acceptsEvents" lib/acp/dart_acp_agent_client.dart`，Expected: raw operation旧布尔字段/引用无输出；enum 的 `finished` 状态保留。

- [ ] 17. 删除旧的 `cancelCompletion` 与分叉取消逻辑，让 pre-owner、owner-bound cancel都复用 Step 16 唯一 invalidation 方法；pre-owner 因 `owner == null` 自然不会调用 `beginPromptTurn` 或 `cancelPromptTurn`：

```dart
Future<void> _cancelRawPromptOperation(
  acp.AcpClient client,
  _RawPromptOperation operation,
) => _invalidateRawPromptOperation(client, operation, sendCancel: true);
```

dispatch 后的 owner cancel 只等待 Task 9 `cancelPromptTurn` 的 `notificationSubmitted`；不得等待 `cleanupFuture/reaped`。因此 wrapper 事件流立即且只关闭一次，而 peer request 与 admission barrier 仍由 manager 后台 reap。

- [ ] 18. 附件转换后先检查 `cancelRequested/state`；只有仍 active 才在同一同步调用栈创建 owner、立即缓存 owner与四个 production Future、再发送 prompt；中间不得出现 `await`、microtask 或异步 listener 安装：

```dart
final owner = client.beginPromptTurn(operation.sessionId);
_beginPromptTurnCount += 1;
operation.owner = owner;
onRawPromptDispatchedForTesting?.call(owner);
final response = client.sendPromptRequest(owner: owner, content: content);
_rawPromptDispatchCount += 1;
```

- [ ] 19. unavailable listener 先比较 owner identity/generation，再检查 `client.hasActivePromptDeliveryClaim(owner)`；claim 已赢时立即返回，由 delivery finally独占投缓存 terminal、release 与 close。未 claim时才读取 `client.hasPromptDeliveryRight(owner)`：只有同 owner cleanup fatal且 pending right 已存在时进入 terminal-only；fatal先于 terminal/right时 `_handleRawUnavailable` 只返回“active unavailable首赢”布尔值，不自行投事件或关流。Task 9 terminal hook 在 owner cancel/session close/external close 已首赢时必须先发现 lifecycle 非 pending并返回，不得登记 winner或补签 right。raw success/remote error投递必须先原子 claim manager right，`_deliverRawTerminal` 返回是否真的投出 terminal；listener-first、result-error-first、user-cancel-first、terminal delivery与 finally全部调用唯一 `_finishRawOutput`，由其同步 CAS决定是否投一次 connectionClosed与关闭一次：

```dart
bool _handleRawUnavailable(
  acp.AcpClient client,
  _RawPromptOperation operation,
  acp.AcpPeerUnavailableState unavailable,
) {
  final owner = operation.owner;
  if (owner == null || operation.streamClosed) return false;
  if (client.hasActivePromptDeliveryClaim(owner)) return false;
  final cleanup = unavailable.cleanupIdentity;
  final sameOwnerCleanupFatal =
      unavailable.reason == acp.AcpPeerUnavailableReason.fatalTimeout &&
      cleanup != null &&
      identical(cleanup.ownerToken, owner) &&
      cleanup.generation == owner.generation;
  final unavailableWon = operation.handleUnavailable(
    sameOwnerCleanupFatal: sameOwnerCleanupFatal,
    deliveryRightExists: client.hasPromptDeliveryRight(owner),
  );
  if (operation.state == _RawPromptOperationState.terminalOnly) {
    unawaited(operation.enterTerminalOnly());
    return false;
  }
  return unavailableWon;
}

Future<bool> _finishRawOutput(
  _RawPromptOperation operation,
  StreamController<AgentEvent> output, {
  required bool emitConnectionClosed,
}) async {
  // This synchronous guard is the sole event+close CAS for listener-first,
  // result-error-first, user-cancel-first, terminal delivery and finally.
  if (!_tryCloseRawStream(operation)) return false;
  if (emitConnectionClosed && !output.isClosed) {
    output.add(const AgentEvent(
      type: AgentEventType.error,
      text: 'ACP connection closed.',
    ));
  }
  if (!output.isClosed) await output.close();
  return true;
}

Future<bool> _deliverRawTerminal(
  acp.AcpClient client,
  _RawPromptOperation operation,
  StreamController<AgentEvent> output,
) async {
  final owner = operation.owner;
  if (owner == null) return false;
  if (!await client.waitForPromptDeliveryBarrier(owner)) return false;
  await _waitForRawDeliveryClaimTestBarrier(owner);
  final claim = client.tryClaimPromptDeliveryRight(owner);
  if (claim == null) return false;
  _rawDeliveryClaimCounts.update(owner, (count) => count + 1,
      ifAbsent: () => 1);
  var delivered = false;
  try {
    if (!operation.tryAcceptClaimedTerminal()) return false;
    await operation.enterTerminalOnly();
    output.add(_agentEventForPromptWinner(claim.winner));
    delivered = true;
    return true;
  } finally {
    client.releasePromptDeliveryRight(claim);
    if (delivered) {
      await _finishRawOutput(
        operation,
        output,
        emitConnectionClosed: false,
      );
    }
  }
}

String _rawPromptProtocolMessage(Object error) {
  try {
    final dynamic dynamicError = error;
    final Object? message = dynamicError.message;
    if (message is String && message.trim().isNotEmpty) {
      return message;
    }
  } on Object {
    // The public projection deliberately ignores every non-message field.
  }
  return 'ACP prompt failed.';
}

AgentEvent _agentEventForPromptWinner(
  acp.JsonRpcPromptTerminalWinner winner,
) {
  switch (winner.kind) {
    case acp.JsonRpcPromptTerminalKind.response:
      final response = winner.response;
      if (response == null) {
        throw StateError('ACP prompt response winner has no response.');
      }
      return _eventFromPromptResponse(response);
    case acp.JsonRpcPromptTerminalKind.remoteError:
      final error = winner.error;
      if (error == null) {
        throw StateError('ACP prompt remote-error winner has no error.');
      }
      return AgentEvent(
        type: AgentEventType.error,
        text: _rawPromptProtocolMessage(error),
        metadata: const <String, Object?>{
          'kind': 'turn',
          'terminalKind': 'remoteError',
        },
        timestamp: DateTime.now(),
      );
    case acp.JsonRpcPromptTerminalKind.timedOut:
      const error = acp.AcpPromptTimeoutException();
      return AgentEvent(
        type: AgentEventType.error,
        text: error.toString(),
        metadata: const <String, Object?>{
          'kind': 'turn',
          'terminalKind': 'timedOut',
        },
        timestamp: DateTime.now(),
      );
  }
}
```

取消后迟到 success/error 只能供 peer/manager 后台 reap，不能通过 local bool 补投事件。manager claim/release 是 terminal delivery 唯一权威；local guard 只防 wrapper stream 自身重入。`_agentEventForPromptWinner` 是缓存 winner 到公开 raw `AgentEvent` 的唯一转换点：response复用既有 stop-reason转换；remote error只白名单协议 `message` 到 `text`，metadata固定且仅有 `kind/terminalKind`；timeout投 `AcpPromptTimeoutException` 文本与同样的两键 metadata。严禁调用 `_agentErrorDetails`、加入 `rawError`，或展开 RPC `code/data/path/payload/stackTrace`。后二者都只投一个 `AgentEventType.error`，不得再作为 stream error抛出或追加 `agentTextDone`。

- [ ] 20. 运行 `rg -n "sendRaw\\(['\"]session/prompt" lib third_party/dart_acp/lib`。Expected before migration: 唯一生产 caller 是 `_sendRawPrompt`。

- [ ] 21. 把 `_sendRawPrompt` 迁到 owner-bound API；同时给 `AcpClient.sendRaw` 与 `JsonRpcPeer.sendRaw` 加固定拒绝。迁移后的 response/unavailable/cancel/end/finally 必须闭合在同一 operation，完整主体为：

```dart
Future<void> _sendRawPrompt({
  required acp.AcpClient client,
  required _RawPromptOperation operation,
  required List<Map<String, dynamic>> content,
  required StreamController<AgentEvent> output,
}) async {
  StreamSubscription<acp.AcpUpdate>? updates;
  StreamSubscription<acp.TerminalEvent>? terminals;
  StreamSubscription<acp.AcpPeerUnavailableState>? unavailable;
  var acceptingUpdates = true;

  Future<void> enterTerminalOnly() async {
    acceptingUpdates = false;
    final currentUpdates = updates;
    final currentTerminals = terminals;
    updates = null;
    terminals = null;
    await currentUpdates?.cancel();
    await currentTerminals?.cancel();
  }

  operation.enterTerminalOnlyAction = enterTerminalOnly;
  updates = client.sessionUpdates(operation.sessionId).listen((update) {
    if (!acceptingUpdates || !operation.acceptsUpdates || output.isClosed) {
      return;
    }
    final event = _eventFromAcpUpdate(
      update,
      includeUserMessages: false,
      sessionId: operation.sessionId,
    );
    if (event != null) output.add(event);
  });
  terminals = client.terminalEvents.listen((update) {
    if (!acceptingUpdates || !operation.acceptsUpdates || output.isClosed) {
      return;
    }
    final event = _eventFromTerminalEvent(update, operation.sessionId);
    if (event != null) output.add(event);
  });
  unavailable = _peerUnavailableStates.stream.listen((state) {
    final unavailableWon = _handleRawUnavailable(client, operation, state);
    if (unavailableWon) {
      unawaited(operation.finishOutput(emitConnectionClosed: true));
    }
  });

  acp.AcpSessionInputBudgetOwner? owner;
  try {
    if (operation.cancelRequested ||
        operation.state != _RawPromptOperationState.active) {
      return;
    }
    // No await or microtask is permitted between owner creation, observation,
    // and the owner-bound request dispatch.
    owner = client.beginPromptTurn(operation.sessionId);
    _beginPromptTurnCount += 1;
    operation.owner = owner;
    onRawPromptDispatchedForTesting?.call(owner);
    final result = client.sendPromptRequest(owner: owner, content: content);
    _rawPromptDispatchCount += 1;
    final outcome = await Future.any<_RawPromptRpcOutcome>(
      <Future<_RawPromptRpcOutcome>>[
        result.then<_RawPromptRpcOutcome>(
          _RawPromptRpcOutcome.response,
          onError: (Object error, StackTrace stackTrace) =>
              _RawPromptRpcOutcome.error(error, stackTrace),
        ),
        operation.streamCancellation.future.then(
          (_) => const _RawPromptRpcOutcome.cancelled(),
        ),
      ],
    );
    if (outcome.cancelled) return;
    if (outcome.error is acp.AcpConnectionClosedException) {
      final seen = _rawConnectionResultErrorsForTesting.putIfAbsent(
        owner,
        Completer<void>.sync,
      );
      if (!seen.isCompleted) seen.complete();
    }
    // response/remote error均已由 manager terminal hook缓存为winner/right；
    // wrapper不得直接从outcome投终态。
    final delivered = await _deliverRawTerminal(client, operation, output);
    final error = outcome.error;
    if (!delivered && error is acp.AcpConnectionClosedException) {
      await operation.finishOutput(emitConnectionClosed: true);
    } else if (!delivered && error != null && operation.acceptsTerminal) {
      Error.throwWithStackTrace(error, outcome.stackTrace!);
    }
  } on Object catch (error, stackTrace) {
    if (error is acp.AcpConnectionClosedException) {
      await operation.finishOutput(emitConnectionClosed: true);
    } else if (operation.acceptsTerminal && !output.isClosed) {
      output.addError(error, stackTrace);
    }
  } finally {
    if (owner != null) client.endPromptTurn(owner);
    await unavailable?.cancel();
    // 主动进入 terminal-only；该 Future 同时等待 update/terminal
    // subscriptions 真正 cancel，不依赖别处曾经触发过。
    await operation.enterTerminalOnly();
    await operation.finishOutput(emitConnectionClosed: false);
  }
}
```

`_sendRawPrompt` 不再创建第二层 controller；它只向 Step 16 的公开 `output` 写事件，所有 cancel/unavailable/result/finally 都调用同一个 `operation.finishOutput`。`_runRawPromptOperation` 的 attachment conversion 仍在 owner创建前，并在 finally按 identity移除 `_rawPromptOperationsBySession`、关闭公开 output、最后完成 `finished`。不得保留旧 `sendRaw('session/prompt')`、旧 response直接 `_eventFromPromptResponse`、第二套 unavailable listener或另一个 close finally。再运行 `rg -n "sendRaw\\(['\"]session/prompt" lib third_party/dart_acp/lib`。Expected: 无输出。

- [ ] 22. 依次重跑本任务十三个 named tests：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw pre-owner cancel reconnect and dispose settle blocked attachment once"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cleanup fatal preserves one cached success terminal"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cleanup fatal preserves one cached remote error terminal"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw admission fatal before terminal winner cannot backfill a delivery right"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw external close and terminal claim are first wins"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cancel after dispatch closes stream while background reap continues"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw cancel or close before terminal hook cannot backfill right"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw late success and error after cancel emit zero terminals"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw fs read write and terminal allow side effects before success"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw fs read write and terminal allow side effects before remote error"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw transport request fatal explicit close and dispose before claim revoke right"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "raw connection closed and close are once across callback orders"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "raw session prompt cannot bypass owner bound api"
```

Expected: 全部 PASS。

- [ ] 23. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: PASS。

- [ ] 24. 先运行 `flutter pub get --offline`，确认只更新 `meta` 的 direct/transitive classification；再运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_session_types_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/terminal_provider_test.dart`，最后运行 `dart analyze third_party/dart_acp` 与 `flutter analyze --no-pub`。Expected: pub get exit 0且不升级版本，tests PASS，两个 analyze 均无 issue；这一步分别按 vendored package边界和根 Flutter package边界证明 Task 11 不依赖 Task 12/13 才能编译。

- [ ] 25. 运行 `dart format third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: exit 0。

- [ ] 26. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 27. 运行 `git add pubspec.yaml pubspec.lock third_party/dart_acp/lib/src/rpc/peer.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。

- [ ] 28. 运行 `git commit -m "fix: route raw ACP prompts through owners"`。Expected: commit成功。

### Task 12: 权限 invalidation 模型与 ChatController 精确清卡

**Files:**
- Modify: `lib/acp/acp_agent_client.dart`
- Modify: `lib/acp/acp_permission_request.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `lib/acp/fake_agent_client.dart`
- Modify: `lib/acp/unavailable_acp_agent_client.dart`
- Modify: `lib/state/chat_controller.dart`
- Modify: `test/acp/acp_permission_request_test.dart`
- Modify: `test/state/chat_controller_test.dart`

本任务的 UI 测试不引用新的未定义 harness：首次使用 invalidation 前，直接扩展本任务 Files 中的真实 `FakeAgentClient`，由它同步 broadcast request/invalidation，并用现有 `lastPermissionRequestId` 证明 UI 未回发。

- [ ] 1. 写 named RED `permission lifecycle identity survives copies without leaking`；完整测试体直接粘贴：

```dart
test('permission lifecycle identity survives copies without leaking', () {
  final request = AcpPermissionRequest(
    id: 'permission-1',
    lifecycleId: 'lifecycle-1',
    title: 'Read',
    rationale: 'Requested',
    sessionId: 'session-1',
    toolName: 'read_text_file',
    options: const <String>['Allow', 'Deny'],
    requestedAt: DateTime.utc(2026, 7, 14),
  );
  final generated = request.withGeneration(2);
  final audit = generated.forAudit();
  expect(generated.lifecycleId, 'lifecycle-1');
  expect(audit.lifecycleId, 'lifecycle-1');
  expect(
    generated.bindingKey,
    'permission-1:lifecycle-1:${request.contentFingerprint}:2',
  );
  expect(generated.contentFingerprint, request.contentFingerprint);

  final legacy = AcpPermissionRequest(
    id: 'legacy',
    title: '',
    rationale: '',
    sessionId: 'session-1',
    toolName: '',
    options: const <String>[],
    requestedAt: DateTime.utc(2026),
  );
  expect(legacy.lifecycleId, isEmpty);
  expect(
    legacy.bindingKey,
    'legacy:${legacy.contentFingerprint}:0',
    reason: 'empty lifecycleId must preserve the pre-migration key format',
  );
  expect(legacy.withGeneration(3).lifecycleId, isEmpty);
  expect(legacy.forAudit().lifecycleId, isEmpty);
});
```

- [ ] 2. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_permission_request_test.dart --plain-name "permission lifecycle identity survives copies without leaking"`。Expected: FAIL，旧模型缺 lifecycleId。
- [ ] 3. 写 named RED `permission invalidation clears only the matching lifecycle`。直接使用本任务扩展后的真实 `FakeAgentClient` 同步发 request/invalidation；requestId、lifecycleId、sessionId 分别单独错配都必须保留当前卡片，只有三字段全匹配才能清卡。完整测试体：

```dart
test('permission invalidation clears only the matching lifecycle', () async {
  final fake = FakeAgentClient();
  final controller = ChatController(client: fake, cwd: '/workspace');
  addTearDown(controller.dispose);
  final permissionEvents = <ChatPermissionEvent>[];
  controller.addPermissionEventObserver(permissionEvents.add);
  final request = AcpPermissionRequest(
    id: 'permission-1',
    lifecycleId: 'lifecycle-current',
    title: 'Read file',
    rationale: 'Requested by agent',
    sessionId: 'session-1',
    toolName: 'read_text_file',
    options: const <String>['Allow', 'Deny'],
    requestedAt: DateTime.utc(2026, 7, 14, 12),
  );
  fake.emitPermissionRequest(request);
  await pumpEventQueue();

  final mismatches = <AcpPermissionInvalidation>[
    AcpPermissionInvalidation(
      requestId: 'permission-other',
      lifecycleId: request.lifecycleId,
      sessionId: request.sessionId,
      reason: AcpPermissionInvalidationReason.timedOut,
      invalidatedAt: DateTime.utc(2026, 7, 14, 12, 1),
    ),
    AcpPermissionInvalidation(
      requestId: request.id,
      lifecycleId: 'lifecycle-old',
      sessionId: request.sessionId,
      reason: AcpPermissionInvalidationReason.timedOut,
      invalidatedAt: DateTime.utc(2026, 7, 14, 12, 2),
    ),
    AcpPermissionInvalidation(
      requestId: request.id,
      lifecycleId: request.lifecycleId,
      sessionId: 'session-other',
      reason: AcpPermissionInvalidationReason.timedOut,
      invalidatedAt: DateTime.utc(2026, 7, 14, 12, 3),
    ),
  ];
  for (final mismatch in mismatches) {
    fake.emitPermissionInvalidation(mismatch);
    await pumpEventQueue();
    expect(controller.pendingPermissionRequest?.bindingKey,
        request.withGeneration(1).bindingKey);
    expect(controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.pending);
    expect(fake.lastPermissionRequestId, isNull);
  }

  final matching = AcpPermissionInvalidation(
    requestId: request.id,
    lifecycleId: request.lifecycleId,
    sessionId: request.sessionId,
    reason: AcpPermissionInvalidationReason.timedOut,
    invalidatedAt: DateTime.utc(2026, 7, 14, 12, 4),
  );
  fake.emitPermissionInvalidation(matching);
  fake.emitPermissionInvalidation(matching);
  await pumpEventQueue(times: 2);

  expect(controller.pendingPermissionRequest, isNull);
  expect(controller.permissionHistory, hasLength(1));
  expect(controller.permissionHistory.single.status,
      AcpPermissionAuditStatus.cancelled);
  expect(controller.permissionHistory.single.decisionSource,
      AcpPermissionDecisionSource.system);
  expect(
    permissionEvents
        .where((event) => event.type == ChatPermissionEventType.resolved),
    hasLength(1),
  );
  expect(fake.lastPermissionRequestId, isNull,
      reason: 'invalidation is not a UI permission response');
});
```

- [ ] 4. 运行 `./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart --plain-name "permission invalidation clears only the matching lifecycle"`。Expected: FAIL；旧模型/`FakeAgentClient`/controller 尚无 invalidation 协议与订阅。失败必须来自产品行为或新增公开协议缺失，不得来自测试 harness 未定义。

- [ ] 5. 写 named RED `permission invalidation reasons and UI races settle once`。第一段让正常 UI allow/deny/cancel 先赢，再送迟到 invalidation，原 audit 与一次 response 不变；第二段让六种 invalidation reason 分别先赢，再注入迟到 manual、reviewer、重复 invalidation，并在 disposed case 立刻 dispose。完整测试体：

```dart
test('permission invalidation reasons and UI races settle once', () async {
  AcpPermissionRequest requestFor(String suffix) => AcpPermissionRequest(
        id: 'permission-$suffix',
        lifecycleId: 'lifecycle-$suffix',
        title: 'Run command',
        rationale: 'Requested by agent',
        sessionId: 'session-1',
        toolName: 'terminal',
        toolKind: 'execute',
        options: const <String>['Allow', 'Deny'],
        requestedAt: DateTime.utc(2026, 7, 14, 13),
      );

  for (final decision in AcpPermissionDecision.values) {
    final fake = FakeAgentClient();
    final controller = ChatController(client: fake, cwd: '/workspace');
    final request = requestFor('ui-${decision.name}');
    fake.emitPermissionRequest(request);
    await pumpEventQueue();

    await controller.resolvePermissionRequest(decision);
    final expectedStatus = switch (decision) {
      AcpPermissionDecision.allow => AcpPermissionAuditStatus.allowed,
      AcpPermissionDecision.deny => AcpPermissionAuditStatus.denied,
      AcpPermissionDecision.cancel => AcpPermissionAuditStatus.cancelled,
    };
    expect(fake.lastPermissionRequestId, request.id);
    expect(fake.lastPermissionDecision, decision);
    expect(controller.permissionHistory, hasLength(1));
    expect(controller.permissionHistory.single.status, expectedStatus);
    expect(controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.manual);

    fake.emitPermissionInvalidation(AcpPermissionInvalidation(
      requestId: request.id,
      lifecycleId: request.lifecycleId,
      sessionId: request.sessionId,
      reason: AcpPermissionInvalidationReason.connectionClosed,
      invalidatedAt: DateTime.utc(2026, 7, 14, 13, 1),
    ));
    await pumpEventQueue();
    expect(fake.lastPermissionRequestId, request.id);
    expect(fake.lastPermissionDecision, decision);
    expect(controller.permissionHistory, hasLength(1));
    expect(controller.permissionHistory.single.status, expectedStatus);
    controller.dispose();
    await controller.disposalComplete;
  }

  expect(AcpPermissionInvalidationReason.values, hasLength(6));
  for (final reason in AcpPermissionInvalidationReason.values) {
    final fake = FakeAgentClient();
    final reviewer = _DelayedPermissionReviewer();
    final controller = ChatController(
      client: fake,
      cwd: '/workspace',
      permissionReviewer: reviewer,
    );
    controller.setToolCallExecutionPolicy(
      AcpToolCallExecutionPolicy.autoReview,
    );
    final permissionEvents = <ChatPermissionEvent>[];
    controller.addPermissionEventObserver(permissionEvents.add);
    final request = requestFor(reason.name);
    fake.emitPermissionRequest(request);
    await pumpEventQueue();
    expect(reviewer.requests.single.id, request.id);

    final invalidation = AcpPermissionInvalidation(
      requestId: request.id,
      lifecycleId: request.lifecycleId,
      sessionId: request.sessionId,
      reason: reason,
      invalidatedAt: DateTime.utc(2026, 7, 14, 13, 2),
    );
    fake.emitPermissionInvalidation(invalidation);
    fake.emitPermissionInvalidation(invalidation);
    final lateManual = controller.resolvePermissionRequest(
      AcpPermissionDecision.deny,
    );
    if (reason == AcpPermissionInvalidationReason.disposed) {
      controller.dispose();
    }
    reviewer.complete(const AcpPermissionReviewResult(
      decision: AcpPermissionDecision.allow,
      risk: 'low',
      rationale: 'Late reviewer result.',
    ));
    await lateManual;
    await pumpEventQueue(times: 3);

    expect(controller.pendingPermissionRequest, isNull);
    expect(controller.permissionHistory, hasLength(1));
    expect(controller.permissionHistory.single.status,
        AcpPermissionAuditStatus.cancelled);
    expect(controller.permissionHistory.single.decisionSource,
        AcpPermissionDecisionSource.system);
    expect(
      permissionEvents
          .where((event) => event.type == ChatPermissionEventType.resolved),
      hasLength(1),
    );
    expect(fake.lastPermissionRequestId, isNull,
        reason: '$reason invalidation must never respond to the agent');
    expect(fake.lastPermissionDecision, isNull);
    controller.dispose();
    await controller.disposalComplete;
  }
});
```

- [ ] 6. 运行 `./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart --plain-name "permission invalidation reasons and UI races settle once"`。Expected: FAIL；旧实现没有六原因 invalidation first-wins，可能重复 audit 或让迟到 manual/reviewer 回发。命令必须只运行这个 named RED，便于把失败归因到 UI lifecycle。
- [ ] 7. 增加应用模型：

```dart
enum AcpPermissionInvalidationReason {
  timedOut,
  promptEnded,
  promptCancelled,
  sessionClosed,
  connectionClosed,
  disposed,
}

final class AcpPermissionInvalidation {
  const AcpPermissionInvalidation({
    required this.requestId,
    required this.lifecycleId,
    required this.sessionId,
    required this.reason,
    required this.invalidatedAt,
  });
  final String requestId;
  final String lifecycleId;
  final String sessionId;
  final AcpPermissionInvalidationReason reason;
  final DateTime invalidatedAt;
}
```

`AcpPermissionRequest` 公开构造增加 `this.lifecycleId = ''` 与 `final String lifecycleId`；`_retained` 增加 `required this.lifecycleId`。空 lifecycle 必须继续生成迁移前的 key，不能多出一个空 segment；非空值才加入 key。复制和 audit 方法使用以下完整方法体：

```dart
String get bindingKey => lifecycleId.isEmpty
    ? '$id:$contentFingerprint:$generation'
    : '$id:$lifecycleId:$contentFingerprint:$generation';

AcpPermissionRequest withGeneration(int value) {
  return AcpPermissionRequest._retained(
    id: id,
    lifecycleId: lifecycleId,
    title: title,
    rationale: rationale,
    sessionId: sessionId,
    toolName: toolName,
    options: options,
    requestedAt: requestedAt,
    choices: choices,
    toolKind: toolKind,
    metadata: metadata,
    transientPolicyContext: transientPolicyContext,
    generation: value,
    transientPolicyContextHash: transientPolicyContextFingerprint,
    contentFingerprintOverride: contentFingerprint,
  );
}

AcpPermissionRequest forAudit({
  Map<String, Object?>? metadata,
  String? title,
  String? rationale,
}) {
  return AcpPermissionRequest._retained(
    id: id,
    lifecycleId: lifecycleId,
    title: title ?? this.title,
    rationale: rationale ?? this.rationale,
    sessionId: sessionId,
    toolName: toolName,
    options: options,
    requestedAt: requestedAt,
    choices: choices,
    toolKind: toolKind,
    metadata: metadata ?? this.metadata,
    transientPolicyContext: const <String, Object?>{},
    generation: generation,
    transientPolicyContextHash: transientPolicyContextFingerprint,
    contentFingerprintOverride: contentFingerprint,
  );
}
```

`lifecycleId` 只参与 binding identity，不得进入 `contentFingerprint`、metadata 或 audit 展示文本；因此不会扩大敏感内容面，且旧的空值 caller 保持原 key。

- [ ] 8. 在 `AcpAgentClient` 加 `Stream<AcpPermissionInvalidation> get permissionInvalidations`。把 `FakeAgentClient` 现有 request controller 也改成同步 broadcast，并加入 invalidation controller；两个 emit 在关闭后都幂等忽略，`dispose` 必须关闭两个 controller：

```dart
final StreamController<AcpPermissionRequest> _permissionRequests =
    StreamController<AcpPermissionRequest>.broadcast(sync: true);
bool _permissionRequestsClosed = false;

final StreamController<AcpPermissionInvalidation> _permissionInvalidations =
    StreamController<AcpPermissionInvalidation>.broadcast(sync: true);
bool _permissionInvalidationsClosed = false;

void emitPermissionRequest(AcpPermissionRequest request) {
  if (_permissionRequestsClosed) return;
  _permissionRequests.add(request);
}

@override
Stream<AcpPermissionInvalidation> get permissionInvalidations =>
    _permissionInvalidations.stream;

void emitPermissionInvalidation(AcpPermissionInvalidation event) {
  if (_permissionInvalidationsClosed) return;
  _permissionInvalidations.add(event);
}

Future<void> closePermissionInvalidations() async {
  if (_permissionInvalidationsClosed) return;
  _permissionInvalidationsClosed = true;
  await _permissionInvalidations.close();
}

@override
Future<void> dispose() async {
  connected = false;
  await Future.wait<void>(<Future<void>>[
    closePermissionRequests(),
    closePermissionInvalidations(),
  ]);
}
```

- [ ] 9. `UnavailableAcpAgentClient` 返回 `const Stream<AcpPermissionInvalidation>.empty()`。`_AcpPermissionBridge` 本任务先加入同步 broadcast controller、getter 与幂等 `close`；`DartAcpAgentClient.permissionInvalidations` 完整代理 `_permissionBridge.invalidations`。Task 13 才接 first-wins reason 发射，本提交只保证接口、生命周期和编译完整。

- [ ] 10. `ChatController` 在构造函数与 request subscription 同时订阅 invalidation；字段和 dispose 链固定为：

```dart
late final StreamSubscription<AcpPermissionInvalidation>
    _permissionInvalidationSubscription;

// Constructor, immediately after _permissionSubscription:
_permissionInvalidationSubscription = client.permissionInvalidations.listen(
  _handlePermissionInvalidation,
  onError: (Object error, StackTrace stackTrace) => _setActionError(error),
);

Future<void> _disposeResources(
  StreamSubscription<AgentEvent>? promptSubscription,
) async {
  await _ignoreCleanup(() => promptSubscription?.cancel());
  await _ignoreCleanup(_permissionSubscription.cancel);
  await _ignoreCleanup(_permissionInvalidationSubscription.cancel);
  await _ignoreCleanup(client.dispose);
  await _ignoreCleanup(() => permissionReviewer?.dispose());
}
```

- [ ] 11. `ChatController` 使用完整 handler；三字段必须全部相同，且 invalidation 不得回发 permission decision：

```dart
void _handlePermissionInvalidation(AcpPermissionInvalidation event) {
  if (_isDisposed) return;
  final request = pendingPermissionRequest;
  if (request == null ||
      request.id != event.requestId ||
      request.lifecycleId != event.lifecycleId ||
      request.sessionId != event.sessionId) {
    return;
  }
  final bindingKey = request.bindingKey;
  pendingPermissionRequest = null;
  _resolvingPermissionRequestIds.remove(bindingKey);
  _reviewingPermissionRequestIds.remove(bindingKey);
  _recordPermissionDecision(
    request,
    AcpPermissionDecision.cancel,
    source: AcpPermissionDecisionSource.system,
  );
  _notifyListeners();
}
```

review/manual Future 的现有 current-binding 检查负责丢弃迟到结果。

- [ ] 12. 复核 prompt-end 现有主动 cancel：正常 UI 未结算仍走显式用户/系统取消；已由 bridge invalidation 结算的 lifecycle 不再回发，避免重复。

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_permission_request_test.dart --plain-name "permission lifecycle identity survives copies without leaking"`。Expected: PASS。

- [ ] 14. 运行 `./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart --plain-name "permission invalidation clears only the matching lifecycle"`。Expected: PASS。

- [ ] 15. 运行 `./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart --plain-name "permission invalidation reasons and UI races settle once"`。Expected: PASS。

- [ ] 16. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_permission_request_test.dart test/state/chat_controller_test.dart`。Expected: PASS。

- [ ] 17. 运行 `dart format lib/acp/acp_agent_client.dart lib/acp/acp_permission_request.dart lib/acp/dart_acp_agent_client.dart lib/acp/fake_agent_client.dart lib/acp/unavailable_acp_agent_client.dart lib/state/chat_controller.dart test/acp/acp_permission_request_test.dart test/state/chat_controller_test.dart`。Expected: exit 0。

- [ ] 18. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 19. 运行 `git add lib/acp/acp_agent_client.dart lib/acp/acp_permission_request.dart lib/acp/dart_acp_agent_client.dart lib/acp/fake_agent_client.dart lib/acp/unavailable_acp_agent_client.dart lib/state/chat_controller.dart test/acp/acp_permission_request_test.dart test/state/chat_controller_test.dart`。

- [ ] 20. 运行 `git commit -m "feat: invalidate ACP permission prompts"`。Expected: commit成功。

### Task 13: 交互权限桥、原因映射与自定义时限贯通

**Files:**
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `test/acp/acp_request_timeout_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`
- Verify: `test/state/chat_controller_test.dart`

- [ ] 1. 在同一测试文件新增独立 `_PermissionStdioFixture`，不要给 Task 11 `_RawStdioFixture` 增加第二构造器或 late/final permission 字段。下面给出 manager/invalidation/unavailable/capture 的完整方法；每个 `_PermissionWireProbe` 保存本 case 的真实 response capture `File`，fixture 使用自己的真实 stdio process、control/ack 文件、只停 client不删目录的 quiesce helper 和幂等最终 `dispose`，不得直接调用 `_AcpPermissionBridge` 私有方法。测试表与 unavailable 映射先定义：

```dart
const bridgePermissionMethods = <String>[
  'session/request_permission',
  'fs/read_text_file',
  'fs/write_text_file',
  'terminal/create',
];

const bridgeInvalidationReasons = <AcpPermissionInvalidationReason>[
  AcpPermissionInvalidationReason.timedOut,
  AcpPermissionInvalidationReason.promptEnded,
  AcpPermissionInvalidationReason.promptCancelled,
  AcpPermissionInvalidationReason.sessionClosed,
  AcpPermissionInvalidationReason.connectionClosed,
  AcpPermissionInvalidationReason.disposed,
];

enum UnavailableFirstReason {
  requestFatal,
  transportClose,
  explicitClose,
  dispose,
}

AcpPermissionInvalidationReason expectedReasonFor(
  UnavailableFirstReason reason,
) => switch (reason) {
  UnavailableFirstReason.dispose => AcpPermissionInvalidationReason.disposed,
  UnavailableFirstReason.requestFatal ||
  UnavailableFirstReason.transportClose ||
  UnavailableFirstReason.explicitClose =>
    AcpPermissionInvalidationReason.connectionClosed,
};

final class _PermissionWireProbe {
  const _PermissionWireProbe({
    required this.request,
    required this.response,
    required this.responseCapture,
    required this.agentParams,
    required this.control,
  });
  final AcpPermissionRequest request;
  final Future<_CapturedWireResponse> response;
  final File responseCapture;
  final Map<String, Object?> agentParams;
  final Map<String, Object?> control;
}

final class _CapturedWireResponse {
  const _CapturedWireResponse(this.raw);
  final Map<String, Object?> raw;

  Map<String, Object?>? get _error {
    final value = raw['error'];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }
  Map<String, Object?>? get _result {
    final value = raw['result'];
    return value is Map ? Map<String, Object?>.from(value) : null;
  }
  bool get hasErrorData => _error?.containsKey('data') ?? false;
  bool get hasError => _error != null;
  int? get errorCode => _error?['code'] as int?;
  String? get errorText => _error?['message'] as String?;
  String? get terminalId => _result?['terminalId'] as String?;
  String? get selectedOutcome {
    final outcome = _result?['outcome'];
    if (outcome is String) return outcome;
    if (outcome is Map<String, Object?>) {
      return outcome['outcome'] as String?;
    }
    return null;
  }
  String? get selectedOptionId {
    final outcome = _result?['outcome'];
    if (outcome is Map<String, Object?>) {
      return outcome['optionId'] as String?;
    }
    return null;
  }
}

enum _PermissionFileWaitSignal { retry, disposed, unavailable }

final class _CanaryCancellationToken {
  const _CanaryCancellationToken(this.canary);

  final String canary;

  @override
  String toString() => 'ACP cancellation token <$canary>';
}

final class _PermissionStdioFixture {
_PermissionStdioFixture._({
  required this.tempDir,
  required this.workspaceDirectory,
  required this.client,
  required this.acpClient,
  required this.session,
  required this.controlFile,
  required this.controlAckDirectory,
  required this.responseDirectory,
  required this.markerDirectory,
  required this.transportClosedFile,
  required this.transientMetadata,
  required this._unavailable,
});

final Directory tempDir;
final Directory workspaceDirectory;
final DartAcpAgentClient client;
final acp.AcpClient acpClient;
final AgentSession session;
final File controlFile;
final Directory controlAckDirectory;
final Directory responseDirectory;
final Directory markerDirectory;
final File transportClosedFile;
final Map<String, Object?> transientMetadata;
Future<acp.AcpPeerUnavailableState> _unavailable;
late final StreamSubscription<acp.AcpPeerUnavailableState>
    _peerUnavailableSubscription;
late final StreamSubscription<AcpPermissionInvalidation>
    _permissionInvalidationSubscription;
int _controlSequence = 0;
int _responseSequence = 0;
final List<Object> cancellationTokensCreatedForTesting = <Object>[];
_CanaryCancellationToken? _injectedCancellationToken;
Future<void>? _clientDisposeFuture;
Future<void>? _disposeFuture;
final Completer<void> _stopFileWaits = Completer<void>.sync();
Future<void>? _ownerPromptStarted;
StreamSubscription<AgentEvent>? _ownerPromptSubscription;

static Future<_PermissionStdioFixture> startPermissionScenario({
  acp.AcpTimeouts timeouts = const acp.AcpTimeouts(
    request: Duration(milliseconds: 75),
    permission: Duration(milliseconds: 750),
    promptCancelGrace: Duration(milliseconds: 750),
  ),
  Map<String, Object?> transientMetadata = const <String, Object?>{},
}) async {
  final tempDir = await Directory.systemTemp.createTemp('permission-stdio-');
  File path(String name) => File('${tempDir.path}/$name');
  final ackDirectory = Directory('${tempDir.path}/acks');
  final responseDirectory = Directory('${tempDir.path}/responses');
  final markerDirectory = Directory('${tempDir.path}/markers');
  final workspaceDirectory = Directory('${tempDir.path}/workspace');
  await Future.wait<Directory>(<Future<Directory>>[
    ackDirectory.create(),
    responseDirectory.create(),
    markerDirectory.create(),
    workspaceDirectory.create(),
  ]);
  final script = path('permission_agent.dart');
  final control = path('control.json');
  final transportClosed = path('transport-closed');
  await script.writeAsString(_permissionAgentSource);
  final client = DartAcpAgentClient(
    agentCommand: _dartExecutable(),
    agentArgs: <String>[
      script.path,
      control.path,
      ackDirectory.path,
      responseDirectory.path,
      transportClosed.path,
      markerDirectory.path,
      workspaceDirectory.path,
    ],
    timeouts: timeouts,
    enableFilesystemReadTextFile: true,
    enableFilesystemWriteTextFile: true,
    enableTerminalProvider: true,
  );
  await client.connect().timeout(const Duration(seconds: 2));
  final session = await client.createSession(cwd: workspaceDirectory.path);
  final unavailable = client.peerUnavailableForTesting.first;
  final fixture = _PermissionStdioFixture._(
    tempDir: tempDir,
    workspaceDirectory: workspaceDirectory,
    client: client,
    acpClient: client.acpClientForTesting,
    session: session,
    controlFile: control,
    controlAckDirectory: ackDirectory,
    responseDirectory: responseDirectory,
    markerDirectory: markerDirectory,
    transportClosedFile: transportClosed,
    transientMetadata:
        Map<String, Object?>.unmodifiable(transientMetadata),
    unavailable: unavailable,
  );
  fixture._peerUnavailableSubscription =
      client.peerUnavailableForTesting.listen((state) {
    fixture._peerCloseCount += 1;
  });
  fixture._permissionInvalidationSubscription =
      client.permissionInvalidations.listen((event) {
    if (event.reason == AcpPermissionInvalidationReason.timedOut) {
      unawaited(fixture.permissionTimedOutFile.writeAsString('seen'));
      unawaited(
        fixture
            .permissionTimedOutFileFor(event.lifecycleId)
            .writeAsString('seen'),
      );
    }
  });
  return fixture;
}

File controlAck(int sequence) =>
    File('${controlAckDirectory.path}/$sequence.ack');
File responseFile(String method, int sequence) => File(
      '${responseDirectory.path}/'
      '${method.replaceAll('/', '_')}-$sequence.json',
    );
File responseLogFile(int sequence) =>
    File('${responseDirectory.path}/wire-$sequence.jsonl');
File agentParamsFile(int sequence) =>
    File('${responseDirectory.path}/request-$sequence.json');
File get requestFatalSeenFile =>
    File('${markerDirectory.path}/request-fatal-seen');
File get permissionTimedOutFile =>
    File('${markerDirectory.path}/permission-timed-out');
File permissionTimedOutFileFor(String lifecycleId) =>
    File('${markerDirectory.path}/permission-timed-out-$lifecycleId');
File bridgeSettledFile(String lifecycleId) =>
    File('${markerDirectory.path}/bridge-settled-$lifecycleId');
File get ownerPromptSeenFile =>
    File('${markerDirectory.path}/owner-prompt-seen');

// All observations below are populated by peer/invalidation callbacks or by
// JSON actually captured from the fake agent's stdin. Absence of a response
// is never inferred from these asynchronous counters; the stopped-agent check
// reads `_PermissionWireProbe.responseCapture` directly.
final Map<String, File> responseLogsByLifecycle = <String, File>{};
int _peerCloseCount = 0;

void injectCancellationTokenCanary(String canary) {
  if (_injectedCancellationToken != null ||
      cancellationTokensCreatedForTesting.isNotEmpty) {
    throw StateError('A cancellation-token canary is already installed.');
  }
  final token = _CanaryCancellationToken(canary);
  _injectedCancellationToken = token;
  acpClient.replacePermissionCancellationTokenFactoryForTesting(() {
    cancellationTokensCreatedForTesting.add(token);
    return token;
  });
}

_CanaryCancellationToken get injectedCancellationTokenForTesting =>
    _injectedCancellationToken ??
    (throw StateError('No cancellation-token canary is installed.'));

Future<void> _waitForScenarioFile(File file) async {
  while (!await file.exists()) {
    final signal = await Future.any<_PermissionFileWaitSignal>([
      Future<_PermissionFileWaitSignal>.delayed(
        const Duration(milliseconds: 5),
        () => _PermissionFileWaitSignal.retry,
      ),
      _stopFileWaits.future.then(
        (_) => _PermissionFileWaitSignal.disposed,
      ),
      _unavailable.then(
        (_) => _PermissionFileWaitSignal.unavailable,
      ),
    ]);
    switch (signal) {
      case _PermissionFileWaitSignal.retry:
        break;
      case _PermissionFileWaitSignal.disposed:
        // The agent may write the real marker and exit in the same turn.
        // Re-read that file; never synthesize or complete an acknowledgement.
        if (await file.exists()) return;
        throw StateError(
          'Permission fixture disposed while waiting for ${file.path}.',
        );
      case _PermissionFileWaitSignal.unavailable:
        // Accept only the marker actually written by the agent before exit.
        if (await file.exists()) return;
        throw StateError(
          'ACP peer became unavailable while waiting for ${file.path}.',
        );
    }
  }
}

Future<int> _sendAgentControl(
  String action, [
  Map<String, Object?> fields = const <String, Object?>{},
]) async {
  final sequence = ++_controlSequence;
  final staged = File('${controlFile.path}.$sequence.tmp');
  await staged.writeAsString(jsonEncode(<String, Object?>{
    'sequence': sequence,
    'action': action,
    ...fields,
  }), flush: true);
  await staged.rename(controlFile.path);
  final ack = controlAck(sequence);
  await _waitForScenarioFile(ack);
  final acknowledged = await ack.readAsString();
  if (acknowledged != '$sequence') {
    throw StateError('Unexpected control acknowledgement $acknowledged.');
  }
  return sequence;
}

Future<int> sendNoopControlForTesting() => _sendAgentControl('noop');

Future<_CapturedWireResponse> nextWireResponse(File file) async {
  await _waitForScenarioFile(file);
  return _CapturedWireResponse(
    Map<String, Object?>.from(
      jsonDecode(await file.readAsString()) as Map,
    ),
  );
}

Future<void> get requestFatalSeen =>
    _waitForScenarioFile(requestFatalSeenFile);
Future<void> get permissionTimedOut =>
    _waitForScenarioFile(permissionTimedOutFile);
Future<void> permissionTimedOutFor(AcpPermissionRequest request) =>
    _waitForScenarioFile(permissionTimedOutFileFor(request.lifecycleId));
Future<void> bridgeSettledFor(AcpPermissionRequest request) =>
    _waitForScenarioFile(bridgeSettledFile(request.lifecycleId));
Future<void> get peerUnavailable => _unavailable.then<void>((_) {});

void refreshUnavailableWatcherAfterReconnect() {
  _unavailable = client.peerUnavailableForTesting.first;
}

Future<_PermissionWireProbe> sendPermission({
  required String method,
  String canary = '',
  bool ownerScoped = false,
  String? sessionId,
  String? workspacePath,
}) async {
  if (ownerScoped) await ensureOwnerPromptStarted();
  final effectiveWorkspace = workspacePath ?? workspaceDirectory.path;
  if (method == 'fs/read_text_file') {
    await File('$effectiveWorkspace/input-$canary.txt')
        .writeAsString('fixed input', flush: true);
  }
  final requestSeen = client.permissionRequests.first;
  final responseSequence = ++_responseSequence;
  final responseCapture = responseFile(method, responseSequence);
  final responseLog = responseLogFile(responseSequence);
  final response = nextWireResponse(responseCapture);
  unawaited(response.then<void>(
    (_) {},
    onError: (Object _, StackTrace _) {
      // Install the error consumer before any awaited control-file work.
    },
  ));
  final controlFields = <String, Object?>{
    'method': method,
    'canary': canary,
    'transientMetadata': transientMetadata,
    'ownerScoped': ownerScoped,
    'responseSequence': responseSequence,
    'workspacePath': effectiveWorkspace,
    'sessionId': ?sessionId,
  };
  final controlSequence =
      await _sendAgentControl('permission', controlFields);
  final control = Map<String, Object?>.unmodifiable(<String, Object?>{
    'sequence': controlSequence,
    'action': 'permission',
    ...controlFields,
  });
  final agentParams = Map<String, Object?>.unmodifiable(
    Map<String, Object?>.from(
      jsonDecode(await agentParamsFile(responseSequence).readAsString())
          as Map,
    ),
  );
  final request = await requestSeen.timeout(const Duration(seconds: 2));
  responseLogsByLifecycle[request.lifecycleId] = responseLog;
  unawaited(response.then<void>(
    (captured) async {
      await bridgeSettledFile(request.lifecycleId).writeAsString('seen');
    },
    onError: (Object _, StackTrace _) {
      // A peer-unavailable/dispose race intentionally aborts file polling.
      // Consume that branch here; tests that need the response still await
      // probe.response and assert its concrete result/error themselves.
    },
  ));
  return _PermissionWireProbe(
    request: request,
    response: response,
    responseCapture: responseCapture,
    agentParams: agentParams,
    control: control,
  );
}

Future<void> cancelFromManager(
  AcpPermissionRequest request,
  acp.PermissionCancellationReason reason,
) async {
  switch (reason) {
    case acp.PermissionCancellationReason.promptEnded:
      await _sendAgentControl('finish-prompt');
      break;
    case acp.PermissionCancellationReason.promptCancelled:
      await client.cancel();
      break;
    case acp.PermissionCancellationReason.sessionClosed:
      await client.closeSession(sessionId: request.sessionId);
      break;
    case acp.PermissionCancellationReason.connectionClosed:
      await client.closePeerExplicitlyForTesting();
      break;
    case acp.PermissionCancellationReason.disposed:
      await quiesceForResponseCaptureCheck();
      break;
    case acp.PermissionCancellationReason.timedOut:
      await permissionTimedOut.timeout(const Duration(seconds: 2));
      break;
  }
}

Future<void> deliverLateCancellation(
  AcpPermissionRequest request,
  acp.PermissionCancellationReason reason,
) => cancelFromManager(request, reason);

Future<int> responseCommitCountFor(AcpPermissionRequest request) async {
  final log = responseLogsByLifecycle[request.lifecycleId];
  if (log == null || !await log.exists()) return 0;
  return const LineSplitter()
      .convert(await log.readAsString())
      .where((line) => line.trim().isNotEmpty)
      .length;
}

int get peerCloseCount => _peerCloseCount;

Future<Map<String, Object?>> sendExtensionEcho() =>
    client.sendExtensionRequest(
      method: '_permission_fixture_echo',
      params: const <String, Object?>{'value': 'ok'},
    );

Future<void> triggerAppInvalidation(
  AcpPermissionRequest request,
  AcpPermissionInvalidationReason reason,
) async {
  switch (reason) {
    case AcpPermissionInvalidationReason.timedOut:
      await permissionTimedOut.timeout(const Duration(seconds: 2));
      break;
    case AcpPermissionInvalidationReason.promptEnded:
      await cancelFromManager(
        request,
        acp.PermissionCancellationReason.promptEnded,
      );
      break;
    case AcpPermissionInvalidationReason.promptCancelled:
      await cancelFromManager(
        request,
        acp.PermissionCancellationReason.promptCancelled,
      );
      break;
    case AcpPermissionInvalidationReason.sessionClosed:
      await cancelFromManager(
        request,
        acp.PermissionCancellationReason.sessionClosed,
      );
      break;
    case AcpPermissionInvalidationReason.connectionClosed:
      await cancelFromManager(
        request,
        acp.PermissionCancellationReason.connectionClosed,
      );
      break;
    case AcpPermissionInvalidationReason.disposed:
      await cancelFromManager(
        request,
        acp.PermissionCancellationReason.disposed,
      );
      break;
  }
}

Future<void> winUnavailable(UnavailableFirstReason reason) async {
  final invalidated = client.permissionInvalidations.first;
  switch (reason) {
    case UnavailableFirstReason.requestFatal:
      unawaited(client
          .sendExtensionRequest(
            method: '_permission_fixture_timeout',
            params: const <String, Object?>{},
          )
          .catchError((Object _) => <String, Object?>{}));
      await requestFatalSeen.timeout(const Duration(seconds: 2));
      break;
    case UnavailableFirstReason.transportClose:
      await _sendAgentControl('transport-close');
      await peerUnavailable.timeout(const Duration(seconds: 2));
      break;
    case UnavailableFirstReason.explicitClose:
      await client.closePeerExplicitlyForTesting().timeout(
        const Duration(seconds: 2),
      );
      break;
    case UnavailableFirstReason.dispose:
      await quiesceForResponseCaptureCheck().timeout(
        const Duration(seconds: 2),
      );
      break;
  }
  await invalidated.timeout(const Duration(seconds: 2));
}

Future<void> deliverLateUnavailable(UnavailableFirstReason reason) async {
  try {
    switch (reason) {
      case UnavailableFirstReason.requestFatal:
        await client.sendExtensionRequest(
          method: '_permission_fixture_timeout',
          params: const <String, Object?>{},
        );
        break;
      case UnavailableFirstReason.transportClose:
        await requestTransportCloseIfRunning();
        break;
      case UnavailableFirstReason.explicitClose:
        await client.closePeerExplicitlyForTesting();
        break;
      case UnavailableFirstReason.dispose:
        await quiesceForResponseCaptureCheck();
        break;
    }
  } on Object {
    // A late unavailable action is allowed to observe the first closed state.
  }
}

Future<void> requestTransportCloseIfRunning() async {
  if (await transportClosedFile.exists()) return;
  try {
    await _sendAgentControl('transport-close').timeout(
      const Duration(milliseconds: 500),
    );
    await _waitForScenarioFile(transportClosedFile).timeout(
      const Duration(milliseconds: 500),
    );
  } on TimeoutException {
    // A previously disposed transport has no remaining agent control loop.
  }
}

Future<void> ensureOwnerPromptStarted() {
  return _ownerPromptStarted ??= () async {
    _ownerPromptSubscription = client
        .sendPrompt(
          sessionId: session.id,
          prompt: 'permission owner scope',
        )
        .listen((_) {}, onError: (Object _, StackTrace _) {});
    await _waitForScenarioFile(ownerPromptSeenFile).timeout(
      const Duration(seconds: 2),
    );
  }();
}

// This is the only quiescence proof used by zero-wire assertions. Await the
// real wrapper dispose so its stdio transport has stopped and the agent cannot
// write a late response, but deliberately keep tempDir for direct inspection.
Future<void> quiesceForResponseCaptureCheck() =>
    _clientDisposeFuture ??= client.dispose();

Future<void> dispose() => _disposeFuture ??= _dispose();

Future<void> _dispose() async {
  if (!_stopFileWaits.isCompleted) _stopFileWaits.complete();
  try {
    await _ownerPromptSubscription?.cancel();
  } finally {
    try {
      await _permissionInvalidationSubscription.cancel();
    } finally {
      try {
        await _peerUnavailableSubscription.cancel();
      } finally {
        try {
          // Reuses the exact Future if a zero-wire branch already quiesced.
          await quiesceForResponseCaptureCheck();
        } finally {
          // Deletion is last: responseCapture must remain inspectable until
          // every assertion and client/agent shutdown has completed.
          if (await tempDir.exists()) await tempDir.delete(recursive: true);
        }
      }
    }
  }
}
}
```

permission-mode factory 使用的 agent source 也在首次引用前完整定义。fixture 先把完整 JSON 写入同目录临时文件并 `flush`，再原子 rename 为 control 文件；agent 轮询读取若恰逢外部非原子写入，只捕获 `FormatException`/`FileSystemException` 并在不推进 sequence 的前提下重试。control loop 只在动作真正写入 wire（或 transport-close marker 已写入）后写精确 sequence ack；action/delete/ack 的写失败不得捕获或伪装成功。每条 permission control 在写 wire 前把 agent 实际生成的 `params` 原样写入 `request-$responseSequence.json`，fixture 只读回这一真实 capture；stdin response capture 直接保存 client 实际写出的 JSON。control/params capture 只服务于证明本地 cancellation token 没有进入 JSON，不得给 agent 增加 `cancellationToken`、`tokenCanary` 或 token `toString()` 字段：

```dart
const _permissionAgentSource = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final controlFile = File(args[0]);
  final ackDirectory = Directory(args[1]);
  final responseDirectory = Directory(args[2]);
  final transportClosedFile = File(args[3]);
  final markerDirectory = Directory(args[4]);
  final defaultWorkspacePath = args[5];
  var handledControlSequence = 0;
  var nextPermissionId = 1000;
  var nextSessionId = 1;
  Object? activePromptId;
  var controlBusy = false;
  final responseTargets = <Object?, File>{};
  final responseLogs = <Object?, File>{};

  void send(Map<String, Object?> message) {
    stdout.writeln(jsonEncode(message));
  }

  Map<String, Object?> permissionParams(
    String method,
    Map<String, Object?> control,
  ) {
    final sessionId = control['sessionId'] as String? ?? 'session-1';
    final canary = control['canary'] as String? ?? '';
    final workspacePath =
        control['workspacePath'] as String? ?? defaultWorkspacePath;
    final transient = control['transientMetadata'];
    return switch (method) {
      'session/request_permission' => <String, Object?>{
        'sessionId': sessionId,
        'options': <Map<String, Object?>>[
          <String, Object?>{'optionId': 'allow', 'name': 'Allow'},
          <String, Object?>{'optionId': 'deny', 'name': 'Deny'},
        ],
        'toolCall': <String, Object?>{
          'title': 'Permission request',
          'kind': 'read',
          if (transient is Map) 'transientPolicyContext': transient,
        },
      },
      'fs/read_text_file' => <String, Object?>{
        'sessionId': sessionId,
        'path': '$workspacePath/input-$canary.txt',
      },
      'fs/write_text_file' => <String, Object?>{
        'sessionId': sessionId,
        'path': '$workspacePath/output-$canary.txt',
        'content': 'fixed',
      },
      'terminal/create' => <String, Object?>{
        'sessionId': sessionId,
        'command': '/usr/bin/true',
        'args': <String>[],
      },
      _ => <String, Object?>{'sessionId': sessionId},
    };
  }

  Future<void> handleControl() async {
    if (controlBusy || !await controlFile.exists()) return;
    controlBusy = true;
    try {
      final Object? decoded;
      try {
        decoded = jsonDecode(await controlFile.readAsString());
      } on FormatException {
        // A polling read may race a non-atomic publisher. Do not consume the
        // sequence; the next timer turn retries the same control file.
        return;
      } on FileSystemException {
        // Rename/delete races are also retryable and do not consume sequence.
        return;
      }
      if (decoded is! Map) return;
      final control = Map<String, Object?>.from(decoded);
      final sequence = control['sequence'];
      if (sequence is! int || sequence <= handledControlSequence) return;
      final action = control['action'];
      if (action == 'permission') {
        final method = control['method'] as String;
        final id = nextPermissionId++;
        final responseSequence = control['responseSequence'] as int;
        final params = permissionParams(method, control);
        await File('${responseDirectory.path}/request-$responseSequence.json')
            .writeAsString(jsonEncode(params), flush: true);
        responseTargets[id] = File(
          '${responseDirectory.path}/'
          '${method.replaceAll('/', '_')}-$responseSequence.json',
        );
        responseLogs[id] = File(
          '${responseDirectory.path}/wire-$responseSequence.jsonl',
        );
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        });
      } else if (action == 'finish-prompt' && activePromptId != null) {
        send(<String, Object?>{
          'jsonrpc': '2.0',
          'id': activePromptId,
          'result': <String, Object?>{'stopReason': 'end_turn'},
        });
        activePromptId = null;
      } else if (action == 'transport-close') {
        await transportClosedFile.writeAsString('closed');
      }
      handledControlSequence = sequence;
      // Remove the consumed publication before acknowledging it, so the next
      // atomic rename never overwrites an unread control. Delete/ack failures
      // intentionally escape handleControl and are never swallowed.
      await controlFile.delete();
      await File('${ackDirectory.path}/$sequence.ack')
          .writeAsString('$sequence', flush: true);
      if (action == 'transport-close') exit(0);
    } finally {
      controlBusy = false;
    }
  }

  final controlTimer = Timer.periodic(
    const Duration(milliseconds: 5),
    // Deliberately leave the Future error visible to the process zone: an ack
    // or action write failure must fail the fixture, never look successful.
    (_) => unawaited(handleControl()),
  );

  try {
    await for (final line in stdin
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
    final decoded = jsonDecode(line);
    if (decoded is! Map) continue;
    final message = Map<String, Object?>.from(decoded);
    final method = message['method'];
    if (method == 'initialize') {
      send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, Object?>{
          'protocolVersion': 1,
          'agentCapabilities': <String, Object?>{
            'auth': <String, Object?>{'logout': true},
            'sessionCapabilities': <String, Object?>{'close': true},
          },
          'authMethods': <Map<String, Object?>>[],
        },
      });
    } else if (method == 'session/new') {
      final sessionId = 'session-${nextSessionId++}';
      send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': <String, Object?>{'sessionId': sessionId},
      });
    } else if (method == 'session/prompt') {
      activePromptId = message['id'];
      await File('${markerDirectory.path}/owner-prompt-seen')
          .writeAsString('seen');
    } else if (method == 'logout' ||
        method == 'authenticate/logout' ||
        method == '_permission_fixture_echo' ||
        method == 'session/close') {
      send(<String, Object?>{
        'jsonrpc': '2.0',
        'id': message['id'],
        'result': method == '_permission_fixture_echo'
            ? <String, Object?>{'value': 'ok'}
            : <String, Object?>{},
      });
    } else if (method == '_permission_fixture_timeout') {
      await File('${markerDirectory.path}/request-fatal-seen')
          .writeAsString('seen');
      // Intentionally no response: the real request deadline closes the peer.
    } else if (!message.containsKey('method') &&
        message.containsKey('id')) {
      final target = responseTargets[message['id']];
      final log = responseLogs[message['id']];
      if (target != null && log != null) {
        await log.writeAsString(
          '${jsonEncode(message)}\n',
          mode: FileMode.append,
          flush: true,
        );
        if (!await target.exists()) {
          await target.writeAsString(jsonEncode(message), flush: true);
        }
      }
    }
    }
  } finally {
    controlTimer.cancel();
  }
}
''';
```

`ownerScoped: true` 先经 `ensureOwnerPromptStarted()` 等真实 `session/prompt` marker，再发送同 session permission。fixture 初始 session 与所有 `ChatController` 使用同一个 `workspaceDirectory.path`；每次 fs read 在 control 发布前写好该真实 workspace 下的输入文件，fs write 也只指向该目录。额外真实 session 的 fs control 必须显式传它自己的 `workspacePath`。response/timeout/peer marker 全由真实 wire 或公开 invalidation/unavailable stream 写入。`quiesceForResponseCaptureCheck` 只幂等 await 真实 `client.dispose()`，证明 stdio transport/agent 已完全停止，但绝不删除 tempDir；`_PermissionStdioFixture.dispose` 也幂等复用同一 client-dispose Future，依次取消 owner prompt、invalidation与peer subscription，最后才删除临时目录。这样 controller、zero-wire 分支与 fixture cleanup 多次触发 dispose 时不会重复停 client或提前删掉 capture；不接触 Task 11 raw fixture。manager deadline/order 的测试继续扩展 Task 6 `_PermissionAdmissionHarness`，不得另造 bridge 状态或由测试直接 complete production barrier。

fixture 不声明无法从 `DartAcpAgentClient` 取得的 `agentProcess`；transport-close 完全由上述真实 agent control loop 写 marker、ack 后 `exit(0)`。同理，不保留没有真实 callback 来源的 provider error/UI response/log/pending-set 计数，相关断言只使用 agent 捕获 response、公开 invalidation/unavailable 与 ChatController audit。

`_PermissionStdioFixture` 的 bridge 断言统一使用上面已定义的异步 `responseCommitCountFor(request)`；处理完迟到动作后必须先 await 幂等的 `quiesceForResponseCaptureCheck()`，再读取 agent 侧 append-only JSONL 的真实行数，不能用单个 response Future 的回调次数代替 wire 次数。`_PermissionAdmissionHarness` 对应提供同名真实观察 API，并把 permit 释放动作放在 harness，而不是虚构 probe 方法：

```dart
int responseCommitCountFor(_PermissionRequestProbe probe) =>
    probe.responseCommitCount;

void releasePermit(_PermissionRequestProbe probe) {
  if (probe.admission == null) {
    throw StateError('Cannot release a permit before admission is observed.');
  }
  releaseOrdinaryPermits();
}
```

这两个方法只读取 `_ObservedAdmission.bindResponseCommitted` 的真实计数、释放 `occupyAllOrdinaryPermits` 建立的真实 blocker；测试不得直接递增计数或 complete response-commit completer。

- [ ] 2. 先写 fixture 自验 named RED `permission fixture commits consecutive controls and exact acknowledgements`。它必须在应用上面原子 publish/精确 ack 方法体前对旧 fixture 运行：旧实现没有返回 sequence 的 helper，且 ack 内容只有 `ok`，因此先观察编译或精确 ack 失败；随后用上面同一真实 agent 连续发布 12 个 noop control，逐个等待且读取真实 ack，证明没有丢 sequence、重复消费或把旧 ack 当成新 ack：

```dart
test('permission fixture commits consecutive controls and exact acknowledgements',
    () async {
  final fixture = await _PermissionStdioFixture.startPermissionScenario();
  try {
    final sequences = <int>[];
    for (var index = 0; index < 12; index += 1) {
      sequences.add(await fixture.sendNoopControlForTesting().timeout(
        const Duration(seconds: 2),
      ));
    }
    expect(sequences, List<int>.generate(12, (index) => index + 1));
    for (final sequence in sequences) {
      expect(await fixture.controlAck(sequence).readAsString(), '$sequence');
    }
  } finally {
    await fixture.dispose();
  }
});
```

同一步再写 named RED `permission bridge shares lifecycle identity and first timeout winner`；真实 stdio agent 发一个 permission request，关键 body 为：

```dart
final fixture = await _PermissionStdioFixture.startPermissionScenario(
  timeouts: const acp.AcpTimeouts(
    permission: Duration(milliseconds: 75),
    promptCancelGrace: Duration(milliseconds: 75),
  ),
);
final invalidations = <AcpPermissionInvalidation>[];
final subscription = fixture.client.permissionInvalidations.listen(
  invalidations.add,
);
try {
  final probe = await fixture.sendPermission(
    method: 'session/request_permission',
  );
  final response = await probe.response.timeout(const Duration(seconds: 2));
  expect(probe.request.lifecycleId, isNotEmpty);
  expect(invalidations, hasLength(1));
  expect(invalidations.single.lifecycleId, probe.request.lifecycleId);
  expect(
    invalidations.single.reason,
    AcpPermissionInvalidationReason.timedOut,
  );
  expect(response.selectedOutcome, 'cancelled');
  await fixture.quiesceForResponseCaptureCheck();
  expect(await fixture.responseCommitCountFor(probe.request), 1);
} finally {
  await subscription.cancel();
  await fixture.dispose();
}
```

- [ ] 3. 分别运行：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission fixture commits consecutive controls and exact acknowledgements"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission bridge shares lifecycle identity and first timeout winner"
```

Expected: 第一条在换入可靠 fixture 前因旧 control helper/ack 契约失败，换入后 PASS；第二条仍 FAIL，因为旧 bridge 缺 identity token 与 first-wins 索引。

- [ ] 4. 分别写两个 named RED，避免跨测试文件引用 private harness。`permission bridge-first settlement stays first wins` 放在 `dart_acp_agent_client_test.dart`：

```dart
final fixture = await _PermissionStdioFixture.startPermissionScenario();
final invalidations = <AcpPermissionInvalidation>[];
final sub = fixture.client.permissionInvalidations.listen(invalidations.add);
try {
  final probe = await fixture.sendPermission(
    method: 'session/request_permission',
  );
  await fixture.client.respondToPermissionRequest(
    id: probe.request.id,
    decision: AcpPermissionDecision.allow,
  );
  await fixture.bridgeSettledFor(probe.request).timeout(
    const Duration(seconds: 2),
  );
  await fixture.cancelFromManager(
    probe.request,
    acp.PermissionCancellationReason.sessionClosed,
  );
  final response = await probe.response.timeout(const Duration(seconds: 2));
  expect(response.selectedOutcome, 'selected');
  expect(response.selectedOptionId, 'allow');
  expect(invalidations, isEmpty);
  await fixture.quiesceForResponseCaptureCheck();
  expect(await fixture.responseCommitCountFor(probe.request), 1);
} finally {
  await sub.cancel();
  await fixture.dispose();
}
```

`permission manager-first settlement stays first wins` 放在 `acp_request_timeout_test.dart`，复用 Task 6 真实 harness：

```dart
final core = await _PermissionAdmissionHarness.start(
  timeouts: const AcpTimeouts(permission: Duration(milliseconds: 75)),
);
try {
  await core.occupyAllOrdinaryPermits();
  final admission = await core.admit('session/request_permission');
  await admission.admissionSeen.future.timeout(const Duration(seconds: 2));
  final response = await admission.response.timeout(const Duration(seconds: 2));
  expect(core.permissions.requests, isEmpty);
  expect(core.permissions.cancellations, isEmpty,
      reason: 'provider never received a token before admission timed out');
  expect(core.responseCommitCountFor(admission), 1);
  core.releasePermit(admission);
  await admission.settled.timeout(const Duration(seconds: 2));
  expect(core.permissions.requests, isEmpty);
  expect(core.permissions.cancellations, isEmpty);
  expect(core.responseCommitCountFor(admission), 1);
  expect(response.result, <String, Object?>{
    'outcome': <String, Object?>{'outcome': 'cancelled'},
  });
} finally {
  await core.dispose();
}
```

- [ ] 5. 运行两个精确 RED：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission bridge-first settlement stays first wins"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission manager-first settlement stays first wins"
```

Expected: FAIL，旧 bridge/manager 各自结算，可能重复完成。

- [ ] 6. 写 named RED `custom ACP timeouts reach every logical deadline consumer`；每个 consumer 必须新建并在 `finally` 销毁自己的 harness。五个时限使用明显分离的值，probe 不保存或回填 expected deadline；测试只从真实 outbound wire、admission、operation value/error/done 与 peer unavailable 得出终态。下界检查只对 production completion Future 使用 `Future.timeout`，不得用 `Future.delayed` 猜测回调。完整 probe 与 harness 方法为：

```dart
final class _LogicalDeadlineProbe {
  final Completer<void> started = Completer<void>.sync();
  final Completer<void> completed = Completer<void>.sync();
  final List<Object?> terminalValues = <Object?>[];
  Map<String, dynamic>? outboundRequest;
  AcpSessionInputBudgetOwner? owner;
  Map<String, Object?>? responseResult;
  Object? terminalError;
  StreamSubscription<Map<String, dynamic>>? wireSubscription;

  void observeWire(Map<String, dynamic> request) {
    outboundRequest = request;
    if (!started.isCompleted) started.complete();
  }

  void bindFuture(Future<Object?> operation) {
    unawaited(operation.then<void>(
      (value) {
        terminalValues.add(value);
        if (!completed.isCompleted) completed.complete();
      },
      onError: (Object error, StackTrace stackTrace) {
        terminalError = error;
        if (!completed.isCompleted) completed.complete();
      },
    ));
  }

  void bindStream(Stream<Object?> operation) {
    late final StreamSubscription<Object?> subscription;
    subscription = operation.listen(
      terminalValues.add,
      onError: (Object error, StackTrace stackTrace) {
        terminalError = error;
      },
      onDone: () {
        if (!completed.isCompleted) completed.complete();
      },
      cancelOnError: false,
    );
    unawaited(completed.future.whenComplete(subscription.cancel));
  }
}

final class _PromptDeadlineProbe {
  const _PromptDeadlineProbe({
    required this.prompt,
    required this.cancelSeen,
  });
  final _LogicalDeadlineProbe prompt;
  final Future<Map<String, dynamic>> cancelSeen;
}

final class _PromptCleanupGraceProbe {
  const _PromptCleanupGraceProbe({
    required this.deadline,
    required this.unavailable,
    required this.unavailableStates,
  });

  final _PromptDeadlineProbe deadline;
  final Future<AcpPeerUnavailableState> unavailable;
  final List<AcpPeerUnavailableState> unavailableStates;
}

_LogicalDeadlineProbe _outboundDeadlineProbe({
  required String method,
}) {
  final probe = _LogicalDeadlineProbe();
  late final StreamSubscription<Map<String, dynamic>> subscription;
  subscription = wireRequests.stream.listen((request) {
    if (request['method'] != method) return;
    probe.observeWire(request);
    unawaited(subscription.cancel());
  });
  probe.wireSubscription = subscription;
  return probe;
}

_LogicalDeadlineProbe startInitializeWithoutResponse() {
  final probe = _outboundDeadlineProbe(
    method: 'initialize',
  );
  probe.bindFuture(peer.initialize(<String, dynamic>{}));
  return probe;
}

_LogicalDeadlineProbe startOrdinaryRequestWithoutResponse() {
  final probe = _outboundDeadlineProbe(
    method: '_deadline_probe',
  );
  probe.bindFuture(peer.sendRaw(
    '_deadline_probe',
    const <String, dynamic>{},
  ));
  return probe;
}

Future<Map<String, dynamic>> _nextWireRequest(String method) {
  final seen = Completer<Map<String, dynamic>>.sync();
  late final StreamSubscription<Map<String, dynamic>> subscription;
  subscription = wireRequests.stream.listen((request) {
    if (request['method'] != method) return;
    if (!seen.isCompleted) seen.complete(request);
    unawaited(subscription.cancel());
  });
  return seen.future;
}

_PromptDeadlineProbe startTypedPromptWithoutResponse() {
  final cancelSeen = _nextWireRequest('session/cancel');
  final probe = _outboundDeadlineProbe(
    method: 'session/prompt',
  );
  probe.bindStream(manager.prompt(
    sessionId: sessionId,
    content: const <Map<String, dynamic>>[
      <String, dynamic>{'type': 'text', 'text': 'typed deadline'},
    ],
  ));
  return _PromptDeadlineProbe(prompt: probe, cancelSeen: cancelSeen);
}

_PromptDeadlineProbe startRawPromptWithoutResponse() {
  final cancelSeen = _nextWireRequest('session/cancel');
  final probe = _outboundDeadlineProbe(
    method: 'session/prompt',
  );
  final owner = manager.beginPromptTurn(sessionId);
  probe.owner = owner;
  probe.bindFuture(() async {
    try {
      return await manager.sendPromptRequest(
        owner: owner,
        content: const <Map<String, dynamic>>[
          <String, dynamic>{'type': 'text', 'text': 'raw deadline'},
        ],
      );
    } finally {
      manager.endPromptTurn(owner);
    }
  }());
  return _PromptDeadlineProbe(prompt: probe, cancelSeen: cancelSeen);
}

Future<_LogicalDeadlineProbe> startManagerAdmissionWithoutResponse() async {
  final probe = _LogicalDeadlineProbe();
  final admission = await admit('session/request_permission');
  await admission.admissionSeen.future;
  probe.started.complete();
  unawaited(admission.response.then<void>(
    (response) {
      probe.responseResult = Map<String, Object?>.from(response.result);
      if (!probe.completed.isCompleted) probe.completed.complete();
    },
    onError: (Object error, StackTrace stackTrace) {
      probe.terminalError = error;
      if (!probe.completed.isCompleted) probe.completed.complete();
    },
  ));
  return probe;
}

_PromptCleanupGraceProbe startPromptCleanupGraceProbe() {
  final unavailableStates = <AcpPeerUnavailableState>[];
  final unavailableSeen = Completer<AcpPeerUnavailableState>.sync();
  void unavailable(AcpPeerUnavailableState state) {
    unavailableStates.add(state);
    if (!unavailableSeen.isCompleted) unavailableSeen.complete(state);
  }
  peer.addUnavailableListener(unavailable);
  final deadline = startTypedPromptWithoutResponse();
  return _PromptCleanupGraceProbe(
    deadline: deadline,
    unavailable: unavailableSeen.future,
    unavailableStates: unavailableStates,
  );
}

void completeOriginalPromptSuccess(_PromptDeadlineProbe probe) {
  sendAgentMessage(<String, dynamic>{
    'jsonrpc': '2.0',
    'id': probe.prompt.outboundRequest!['id'],
    'result': <String, dynamic>{'stopReason': 'end_turn'},
  });
}

Future<void> expectStillPending(
  Future<void> completion,
  Duration lowerBound,
) => expectLater(
  completion.timeout(lowerBound),
  throwsA(isA<TimeoutException>()),
);
```

`_LogicalDeadlineProbe`、`_PromptCleanupGraceProbe` 与 `expectStillPending` 放在测试文件顶层；其余方法放入 `_PermissionAdmissionHarness`。outbound 的 `started` 只能由 `_acceptWireMap` 已写入的 `wireRequests` 完成，manager permission 的 `started` 只能由真实 `admissionSeen` 完成；probe 不接收 `Duration`，也不允许测试 complete production Future。使用同一个公开 `AcpTimeouts` 实例执行以下测试体：

```dart
enum _DeadlineConsumer {
  initialize,
  ordinaryRequest,
  typedPrompt,
  rawPrompt,
  managerAdmission,
  promptCleanupGrace,
}

const timeouts = AcpTimeouts(
  initialize: Duration(milliseconds: 180),
  request: Duration(milliseconds: 480),
  prompt: Duration(milliseconds: 520),
  permission: Duration(milliseconds: 900),
  promptCancelGrace: Duration(milliseconds: 1500),
);
for (final consumer in _DeadlineConsumer.values) {
  final fresh = await _PermissionAdmissionHarness.start(timeouts: timeouts);
  try {
    expect(identical(fresh.config.timeouts, timeouts), isTrue);
    expect(
      identical(fresh.acpClient.peerTimeoutsForTesting, fresh.config.timeouts),
      isTrue,
    );
    expect(
      identical(fresh.acpClient.sessionManagerConfigForTesting, fresh.config),
      isTrue,
    );
    switch (consumer) {
      case _DeadlineConsumer.initialize:
        final probe = fresh.startInitializeWithoutResponse();
        await probe.started.future.timeout(const Duration(seconds: 2));
        await expectStillPending(
          probe.completed.future,
          const Duration(milliseconds: 75),
        );
        await probe.completed.future.timeout(
          const Duration(milliseconds: 180),
        );
        expect(probe.terminalError, isA<AcpRequestTimeoutException>());
        break;
      case _DeadlineConsumer.ordinaryRequest:
        final probe = fresh.startOrdinaryRequestWithoutResponse();
        await probe.started.future.timeout(const Duration(seconds: 2));
        await expectStillPending(
          probe.completed.future,
          const Duration(milliseconds: 320),
        );
        await probe.completed.future.timeout(
          const Duration(milliseconds: 260),
        );
        expect(probe.terminalError, isA<AcpRequestTimeoutException>());
        break;
      case _DeadlineConsumer.typedPrompt:
        final probe = fresh.startTypedPromptWithoutResponse();
        await probe.prompt.started.future.timeout(const Duration(seconds: 2));
        await expectStillPending(
          probe.prompt.completed.future,
          const Duration(milliseconds: 400),
        );
        await probe.cancelSeen.timeout(const Duration(milliseconds: 250));
        expect(fresh.peer.isAvailable, isTrue);
        completeOriginalPromptSuccess(probe);
        await probe.prompt.completed.future.timeout(const Duration(seconds: 1));
        expect(probe.prompt.terminalError, isA<AcpPromptTimeoutException>());
        expect(
          probe.prompt.terminalValues.whereType<TurnEnded>(),
          hasLength(1),
        );
        expect(fresh.peer.isAvailable, isTrue,
            reason: 'late original response reaps cleanup without changing timeout');
        break;
      case _DeadlineConsumer.rawPrompt:
        final probe = fresh.startRawPromptWithoutResponse();
        await probe.prompt.started.future.timeout(const Duration(seconds: 2));
        expect(probe.prompt.owner, isNotNull);
        await expectStillPending(
          probe.prompt.completed.future,
          const Duration(milliseconds: 400),
        );
        await probe.cancelSeen.timeout(const Duration(milliseconds: 250));
        expect(fresh.peer.isAvailable, isTrue);
        completeOriginalPromptSuccess(probe);
        await probe.prompt.completed.future.timeout(const Duration(seconds: 1));
        expect(probe.prompt.terminalError, isA<AcpPromptTimeoutException>());
        expect(fresh.peer.isAvailable, isTrue);
        break;
      case _DeadlineConsumer.managerAdmission:
        final probe = await fresh.startManagerAdmissionWithoutResponse();
        await probe.started.future.timeout(const Duration(seconds: 2));
        await expectStillPending(
          probe.completed.future,
          const Duration(milliseconds: 750),
        );
        await probe.completed.future.timeout(
          const Duration(milliseconds: 300),
        );
        expect(probe.terminalError, isNull);
        expect(probe.responseResult, <String, Object?>{
          'outcome': <String, Object?>{'outcome': 'cancelled'},
        });
        break;
      case _DeadlineConsumer.promptCleanupGrace:
        final probe = fresh.startPromptCleanupGraceProbe();
        await probe.deadline.prompt.started.future.timeout(
          const Duration(seconds: 2),
        );
        await expectStillPending(
          probe.deadline.prompt.completed.future,
          const Duration(milliseconds: 400),
        );
        await probe.deadline.cancelSeen.timeout(
          const Duration(milliseconds: 250),
        );
        await expectStillPending(
          probe.deadline.prompt.completed.future,
          const Duration(milliseconds: 100),
        );
        expect(fresh.peer.isAvailable, isTrue,
            reason: 'caller remains pending throughout cleanup grace');
        await expectStillPending(
          probe.unavailable.then<void>((_) {}),
          const Duration(milliseconds: 900),
        );
        final unavailable =
            await probe.unavailable.timeout(
              const Duration(milliseconds: 800),
            );
        expect(unavailable.reason, AcpPeerUnavailableReason.fatalTimeout);
        await probe.deadline.prompt.completed.future.timeout(
          const Duration(milliseconds: 250),
        );
        expect(
          probe.deadline.prompt.terminalError,
          isA<AcpPromptTimeoutException>(),
        );
        expect(probe.unavailableStates, hasLength(1));
        expect(fresh.peer.isAvailable, isFalse);
        break;
    }
  } finally {
    await fresh.dispose();
  }
}
```

bridge consumer 位于 `dart_acp_agent_client_test.dart`，必须使用真实 `DartAcpAgentClient → _InteractivePermissionProvider → _AcpPermissionBridge`，不能用 `_PermissionAdmissionHarness` 代替：

```dart
test('custom ACP permission timeout reaches real interactive bridge', () async {
  const timeouts = acp.AcpTimeouts(
    initialize: Duration(milliseconds: 180),
    request: Duration(milliseconds: 240),
    prompt: Duration(milliseconds: 520),
    permission: Duration(milliseconds: 900),
    promptCancelGrace: Duration(milliseconds: 1500),
  );
  final fixture = await _PermissionStdioFixture.startPermissionScenario(
    timeouts: timeouts,
  );
  final invalidations = <AcpPermissionInvalidation>[];
  final subscription = fixture.client.permissionInvalidations.listen(
    invalidations.add,
  );
  try {
    expect(identical(fixture.client.timeouts, timeouts), isTrue);
    final probe = await fixture.sendPermission(
      method: 'session/request_permission',
    );
    await expectLater(
      probe.response.timeout(const Duration(milliseconds: 750)),
      throwsA(isA<TimeoutException>()),
    );
    final response = await probe.response.timeout(
      const Duration(milliseconds: 300),
    );
    expect(response.selectedOutcome, 'cancelled');
    expect(invalidations, hasLength(1));
    expect(
      invalidations.single.reason,
      AcpPermissionInvalidationReason.timedOut,
    );
    await fixture.quiesceForResponseCaptureCheck();
    expect(await fixture.responseCommitCountFor(probe.request), 1);
  } finally {
    await subscription.cancel();
    await fixture.dispose();
  }
});
```

- [ ] 7. 运行两个精确 RED：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "custom ACP timeouts reach every logical deadline consumer"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "custom ACP permission timeout reaches real interactive bridge"
```

Expected: FAIL，至少一个入口回退默认值、复制配置，或 wrapper 没有把 `timeouts.permission` 传入真实 interactive provider。

- [ ] 8. 写跨层 named RED `unavailable first winner invalidates bridge and UI once across layers`。使用独立 `_PermissionStdioFixture` 与真实 `DartAcpAgentClient + ChatController`，跑完整 4×3 矩阵：首因依次为 request fatal、transport close、explicit close、dispose；每个首因后再依次注入其余三个迟到原因。前三种首因映射 `connectionClosed`，dispose 映射 `disposed`（复用 Task 10 已固定的 wrapper-dispose first-wins映射，Task 13 不再重定义）。每个 case 在检查零 wire 前必须 await `quiesceForResponseCaptureCheck()`，再直接读取该 probe 保存的真实 response capture 文件并断言不存在；不得用 callback 尚未更新的 map/count推断 agent 永远不会迟写。关键循环与断言为：

```dart
for (final first in UnavailableFirstReason.values) {
  for (final late in UnavailableFirstReason.values.where((v) => v != first)) {
    final fixture = await _PermissionStdioFixture.startPermissionScenario();
    final invalidations = <AcpPermissionInvalidation>[];
    final subscription = fixture.client.permissionInvalidations.listen(
      invalidations.add,
    );
    final controller = ChatController(
      client: fixture.client,
      cwd: fixture.workspaceDirectory.path,
    );
    try {
      final probe = await fixture.sendPermission(
        method: 'session/request_permission',
      );
      expect(controller.pendingPermissionRequest?.id, probe.request.id);
      await fixture.winUnavailable(first);
      await fixture.deliverLateUnavailable(late);
      await pumpEventQueue(times: 2);
      await fixture.quiesceForResponseCaptureCheck().timeout(
        const Duration(seconds: 2),
      );
      expect(controller.pendingPermissionRequest, isNull);
      expect(invalidations, hasLength(1));
      expect(invalidations.single.reason, expectedReasonFor(first));
      expect(controller.permissionHistory.single.status,
          AcpPermissionAuditStatus.cancelled);
      expect(controller.permissionHistory.single.decisionSource,
          AcpPermissionDecisionSource.system);
      expect(await probe.responseCapture.exists(), isFalse,
          reason: 'the stopped stdio agent cannot write a late response');
    } finally {
      await subscription.cancel();
      controller.dispose();
      await controller.disposalComplete;
      await fixture.dispose();
    }
  }
}
```

同一步另写 named RED `logout invalidates pending permission once without closing peer`，把 logout 与 explicit peer close 分开：fake agent 对真实 `logout` request 回 success；pending lifecycle 得到一次 `connectionClosed` invalidation与一次 provider cancellation，但 `peerCloseCount == 0`。随后同一 client 的 extension echo 成功，证明 logout 不是 explicit peer close。

```dart
final fixture = await _PermissionStdioFixture.startPermissionScenario();
final invalidations = <AcpPermissionInvalidation>[];
final sub = fixture.client.permissionInvalidations.listen(invalidations.add);
try {
  final probe = await fixture.sendPermission(
    method: 'session/request_permission',
  );
  await fixture.client.logout().timeout(const Duration(seconds: 2));
  await pumpEventQueue(times: 2);
  expect(invalidations, hasLength(1));
  expect(invalidations.single.lifecycleId, probe.request.lifecycleId);
  expect(
    invalidations.single.reason,
    AcpPermissionInvalidationReason.connectionClosed,
  );
  expect(fixture.peerCloseCount, 0);
  final response = await probe.response.timeout(const Duration(seconds: 2));
  expect(response.hasError, isFalse);
  expect(response.selectedOutcome, 'cancelled');
  expect(await fixture.sendExtensionEcho(), <String, Object?>{'value': 'ok'});
  await fixture.quiesceForResponseCaptureCheck();
  expect(await fixture.responseCommitCountFor(probe.request), 1);
} finally {
  await sub.cancel();
  await fixture.dispose();
}
```

- [ ] 9. 运行两个精确 RED：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "unavailable first winner invalidates bridge and UI once across layers"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "logout invalidates pending permission once without closing peer"
```

Expected: FAIL，旧路径会被迟到原因覆盖、重复清卡、把 logout 错当 peer close，或只因异步 response map 尚未更新便误报零 wire；新断言必须在 stdio agent 停止后仍看到真实 capture 文件不存在。

- [ ] 10. 写 named RED `concurrent permission tokens settle independently`；第一轮同 session 并发两个真实 stdio token，A timeout、B UI response；第二轮 A/B 使用不同真实 session，A session close、B UI response。两轮都再注入迟到 cancel，断言 lifecycleId/token/response/invalidation 互不串线。第一轮关键 body：

```dart
final fixture = await _PermissionStdioFixture.startPermissionScenario(
  timeouts: const acp.AcpTimeouts(
    permission: Duration(milliseconds: 500),
    promptCancelGrace: Duration(milliseconds: 500),
  ),
);
final invalidations = <AcpPermissionInvalidation>[];
final sub = fixture.client.permissionInvalidations.listen(invalidations.add);
try {
  final a = await fixture.sendPermission(method: 'fs/read_text_file');
  final b = await fixture.sendPermission(method: 'terminal/create');
  expect(a.request.lifecycleId, isNot(b.request.lifecycleId));
  expect(a.request.id, isNot(b.request.id));

  await fixture.client.respondToPermissionRequest(
    id: b.request.id,
    decision: AcpPermissionDecision.allow,
  );
  // The awaited public call returns only after bridge userResolved first-wins
  // has synchronously committed the allow decision.
  await fixture.bridgeSettledFor(b.request).timeout(
    const Duration(seconds: 2),
  );
  final responseB = await b.response.timeout(const Duration(seconds: 2));
  expect(responseB.hasError, isFalse);
  expect(responseB.terminalId, isNotNull);
  expect(responseB.terminalId, isNotEmpty);
  // Read the append-only wire count only after the late action and quiesce.
  expect(invalidations, isEmpty,
      reason: 'B must settle before A reaches its short permission deadline');
  await fixture.permissionTimedOutFor(a.request).timeout(
    const Duration(seconds: 2),
  );
  await fixture.deliverLateCancellation(
    a.request,
    acp.PermissionCancellationReason.timedOut,
  );
  await fixture.deliverLateCancellation(
    b.request,
    acp.PermissionCancellationReason.connectionClosed,
  );

  final responseA = await a.response.timeout(const Duration(seconds: 2));
  expect(responseA.errorCode, -32002);
  expect(responseA.errorText, 'Permission request timed out.');
  expect(invalidations.map((e) => e.lifecycleId),
      <String>[a.request.lifecycleId]);
  await fixture.quiesceForResponseCaptureCheck();
  expect(await fixture.responseCommitCountFor(a.request), 1);
  expect(await fixture.responseCommitCountFor(b.request), 1);
} finally {
  await sub.cancel();
  await fixture.dispose();
}
```

第二轮必须使用 fresh fixture 与 agent 递增返回的两个真实 session id，完整 body 与 finally 为：

```dart
final second = await _PermissionStdioFixture.startPermissionScenario();
final secondInvalidations = <AcpPermissionInvalidation>[];
final secondSub = second.client.permissionInvalidations.listen(
  secondInvalidations.add,
);
try {
  final workspaceA = Directory('${second.tempDir.path}/workspace-a');
  final workspaceB = Directory('${second.tempDir.path}/workspace-b');
  await Future.wait<Directory>(<Future<Directory>>[
    workspaceA.create(),
    workspaceB.create(),
  ]);
  final sessionA = await second.client.createSession(cwd: workspaceA.path);
  final sessionB = await second.client.createSession(cwd: workspaceB.path);
  expect(sessionA.id, isNot(sessionB.id));
  final a = await second.sendPermission(
    method: 'fs/read_text_file',
    sessionId: sessionA.id,
    workspacePath: workspaceA.path,
  );
  final b = await second.sendPermission(
    method: 'terminal/create',
    sessionId: sessionB.id,
  );
  await second.client.respondToPermissionRequest(
    id: b.request.id,
    decision: AcpPermissionDecision.allow,
  );
  // Completion of respondToPermissionRequest is the bridge userResolved
  // first-wins commit evidence. The next wait observes its single wire commit;
  // terminal/create's provider result has no outcome field.
  await second.bridgeSettledFor(b.request).timeout(
    const Duration(seconds: 2),
  );
  await second.client.closeSession(sessionId: sessionA.id);
  final responseA = await a.response.timeout(const Duration(seconds: 2));
  final responseB = await b.response.timeout(const Duration(seconds: 2));
  expect(responseB.hasError, isFalse);
  expect(responseB.terminalId, isNotNull);
  expect(responseB.terminalId, isNotEmpty);
  expect(responseA.hasError, isTrue);
  expect(responseA.errorCode, -32003);
  expect(responseA.errorText, 'Permission request cancelled.');
  expect(responseA.hasErrorData, isFalse);
  expect(
    secondInvalidations
        .where((event) => event.lifecycleId == a.request.lifecycleId)
        .single
        .reason,
    AcpPermissionInvalidationReason.sessionClosed,
  );
  expect(
    secondInvalidations.any(
      (event) => event.lifecycleId == b.request.lifecycleId,
    ),
    isFalse,
  );
  await second.deliverLateCancellation(
    a.request,
    acp.PermissionCancellationReason.connectionClosed,
  );
  await second.quiesceForResponseCaptureCheck();
  expect(await second.responseCommitCountFor(a.request), 1);
  expect(await second.responseCommitCountFor(b.request), 1);
} finally {
  await secondSub.cancel();
  await second.dispose();
}
```

- [ ] 11. 运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "concurrent permission tokens settle independently"`。Expected: FAIL，旧 id/session 索引会误结算。

- [ ] 12. 写 named RED `permission invalidation canaries never reach wire or audit events`；用 `bridgePermissionMethods × bridgeInvalidationReasons` 的 4×6 表，将 canary 放进真实 `_CanaryCancellationToken`、transient metadata 与 fixture 临时 workspace 下的真实内部 path。每个 case 都在发布真实 permission request **之前** 调 `injectCancellationTokenCanary(canary)`；factory 必须恰调用一次，返回的对象与 fixture 注入对象 `identical`。随后靠真实 admission 构造、`PermissionOptions` copy、interactive bridge identity map 与 provider cancel 完成整条结算；不得由 fixture 直接调用 bridge/cancel或补写 invalidation。触发 invalidation 前，controller 当前卡片的 lifecycleId 与 bindingKey 必须精确来自 probe；触发后 audit 必须恰一条、仍是同 lifecycle/binding、状态 cancelled、来源 system，再对这条已证明非空的 audit map 序列化并检查 canary。每个可写 wire 的 case 都按 method+reason 精确断言：`session/request_permission` 是 fixed cancelled result；其余三入口在 `timedOut` 时为 `-32002 / Permission request timed out.`，在 `promptEnded/promptCancelled/sessionClosed` 时为 `-32003 / Permission request cancelled.`；全部无 `error.data`。`connectionClosed/disposed` 两列必须先 await 真实 client/stdio quiesce，再直接断言 probe 保存的 response capture 文件不存在，不能用异步 map/count 假证零 wire。control 与 agent 实际 params capture 不得出现 token 的完整 `toString()`，也不得出现 `cancellationToken`/`tokenCanary` 键；真实 wire response、invalidation 与 audit event 的稳定序列化均不含 canary，且 invalidation 恰一次；未接入真实 logger 前不增加日志观察量。

```dart
for (final method in bridgePermissionMethods) {
  for (final reason in bridgeInvalidationReasons) {
    final canary =
        'secret-${method.replaceAll('/', '_')}-${reason.name}';
    final fixture = await _PermissionStdioFixture.startPermissionScenario(
      transientMetadata: <String, Object?>{
        'path': '/private/$canary',
        'payload': canary,
      },
    );
    final invalidations = <AcpPermissionInvalidation>[];
    final sub = fixture.client.permissionInvalidations.listen(
      invalidations.add,
    );
    final controller = ChatController(
      client: fixture.client,
      cwd: fixture.workspaceDirectory.path,
    );
    try {
      fixture.injectCancellationTokenCanary(canary);
      final probe = await fixture.sendPermission(
        method: method,
        canary: canary,
        ownerScoped:
            reason == AcpPermissionInvalidationReason.promptEnded ||
            reason == AcpPermissionInvalidationReason.promptCancelled,
      );
      expect(fixture.cancellationTokensCreatedForTesting, hasLength(1));
      expect(
        identical(
          fixture.cancellationTokensCreatedForTesting.single,
          fixture.injectedCancellationTokenForTesting,
        ),
        isTrue,
      );
      final tokenText = fixture.injectedCancellationTokenForTesting.toString();
      for (final captured in <Map<String, Object?>>[
        probe.control,
        probe.agentParams,
      ]) {
        final encoded = jsonEncode(captured);
        expect(encoded, isNot(contains(tokenText)));
        expect(encoded, isNot(contains('"cancellationToken"')));
        expect(encoded, isNot(contains('"tokenCanary"')));
      }
      final pending = controller.pendingPermissionRequest;
      if (pending == null) {
        fail('controller did not bind the real permission lifecycle');
      }
      expect(pending.lifecycleId, probe.request.lifecycleId);
      expect(
        pending.bindingKey,
        probe.request.withGeneration(pending.generation).bindingKey,
      );
      await fixture.triggerAppInvalidation(probe.request, reason);
      final closesPeer =
          reason == AcpPermissionInvalidationReason.connectionClosed ||
          reason == AcpPermissionInvalidationReason.disposed;
      if (closesPeer) {
        await fixture.peerUnavailable.timeout(const Duration(seconds: 2));
        await fixture.quiesceForResponseCaptureCheck().timeout(
          const Duration(seconds: 2),
        );
        expect(await probe.responseCapture.exists(), isFalse,
            reason: 'the stopped stdio agent cannot write a late response');
      } else {
        final response =
            await probe.response.timeout(const Duration(seconds: 2));
        if (method == 'session/request_permission') {
          expect(response.hasError, isFalse);
          expect(response.selectedOutcome, 'cancelled');
        } else {
          expect(response.hasError, isTrue);
          switch (reason) {
            case AcpPermissionInvalidationReason.timedOut:
              expect(response.errorCode, -32002);
              expect(response.errorText, 'Permission request timed out.');
              break;
            case AcpPermissionInvalidationReason.promptEnded:
            case AcpPermissionInvalidationReason.promptCancelled:
            case AcpPermissionInvalidationReason.sessionClosed:
              expect(response.errorCode, -32003);
              expect(response.errorText, 'Permission request cancelled.');
              break;
            case AcpPermissionInvalidationReason.connectionClosed:
            case AcpPermissionInvalidationReason.disposed:
              fail('peer-closing reasons must not produce a wire response');
          }
        }
        expect(response.hasErrorData, isFalse);
        expect(jsonEncode(response.raw), isNot(contains(canary)));
      }
      expect(invalidations, hasLength(1));
      final invalidation = invalidations.single;
      expect(invalidation.requestId, probe.request.id);
      expect(invalidation.lifecycleId, probe.request.lifecycleId);
      expect(invalidation.sessionId, probe.request.sessionId);
      expect(invalidation.reason, reason);
      expect(jsonEncode(invalidations.map((e) => <String, Object?>{
        'requestId': e.requestId,
        'lifecycleId': e.lifecycleId,
        'sessionId': e.sessionId,
        'reason': e.reason.name,
      }).toList()), isNot(contains(canary)));
      expect(controller.permissionHistory, hasLength(1));
      final audit = controller.permissionHistory.single;
      expect(audit.request.lifecycleId, probe.request.lifecycleId);
      expect(audit.request.bindingKey, pending.bindingKey);
      expect(audit.status, AcpPermissionAuditStatus.cancelled);
      expect(audit.decisionSource, AcpPermissionDecisionSource.system);
      final auditMap = audit.toJson();
      expect(auditMap, isNotEmpty);
      expect(jsonEncode(auditMap), isNot(contains(canary)));
      expect(fixture.cancellationTokensCreatedForTesting, hasLength(1));
    } finally {
      await sub.cancel();
      controller.dispose();
      await controller.disposalComplete;
      await fixture.dispose();
    }
  }
}
```

- [ ] 13. 运行 `./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission invalidation canaries never reach wire or audit events"`。Expected: FAIL；旧零-wire断言可能在 agent 仍能迟写时因异步 map 为空而假通过，旧 audit 断言也可能对空/错 lifecycle 列表做无效序列化；新测试必须等 quiesce 后直接检查 capture，并证明唯一 audit 与 probe lifecycle/binding一致。

- [ ] 14. 把 Task 6 admission 内部硬编码的 `Object()` 改成正常运行默认 `Object.new`、仅测试可替换的 factory。`third_party/dart_acp/lib/src/session/session_manager.dart` 与 `third_party/dart_acp/lib/src/acp_client.dart` 必须保留 Task 11 已加入的 `import 'package:meta/meta.dart';`；若执行时该 import 尚未落地，就在本 Task 的这两个既有 Files 中补齐，不能移除注解或改成公开生产配置。完整形状为：

```dart
// session_manager.dart
Object Function() _permissionCancellationTokenFactory = Object.new;

@visibleForTesting
void replacePermissionCancellationTokenFactoryForTesting(
  Object Function() factory,
) {
  _permissionCancellationTokenFactory = factory;
}

// `_InboundPermissionAdmission` constructor/field:
required this.cancellationToken,
final Object cancellationToken;

// `_admitInboundPermission`：每条真实 admission 只调用一次。
final admission = _InboundPermissionAdmission(
  manager: this,
  method: method,
  correlationIdentity: correlationIdentity,
  sessionId: sessionId,
  sessionGeneration: generation,
  promptOwner: owner,
  peerEpoch: _peerEpoch,
  cancellationToken: _permissionCancellationTokenFactory(),
);

// acp_client.dart；只代理 factory replacement，不暴露 manager 本体。
@visibleForTesting
void replacePermissionCancellationTokenFactoryForTesting(
  Object Function() factory,
) {
  _sessionManager.replacePermissionCancellationTokenFactoryForTesting(factory);
}
```

删除 `_InboundPermissionAdmission` 上的 `final Object cancellationToken = Object();`。factory 只能在 admission 构造点调用一次，不能在 `PermissionOptions` copy、provider request、bridge request或 provider cancel 时再次调用。正常 client 从不替换 factory，行为仍是每条 admission 一个新 `Object`。`_permissionProviderDecision` 继续把 `admission.cancellationToken` 原对象放入 `PermissionOptions`；`_InteractivePermissionProvider.request`、`_AcpPermissionBridge.request` 的 identity map 与 `_notifyPermissionProviderCancellation → cancelPendingPermission` 继续传同一对象，严禁 `toString()`、JSON encode、wrapper、record或重新构造 token。

- [ ] 15. `_InteractivePermissionProvider implements acp.CancellablePermissionProvider`；构造接收 `Duration permissionTimeout`，`request` 调 `bridge.request(options, timeout: permissionTimeout)`，`cancelPendingPermission` 原样转发 token/reason。

- [ ] 16. bridge 使用 `_pendingById` 与 `HashMap<Object, _PendingPermissionRequest>.identity()`；pending 状态至少包含以下可直接落地的字段，first-wins 方法体固定为：

```dart
enum _PendingPermissionState { pending, userResolved, invalidated }

int _nextId = 0;
int _nextLifecycleId = 0;
final Map<String, _PendingPermissionRequest> _pendingById =
    <String, _PendingPermissionRequest>{};
final Map<Object, _PendingPermissionRequest> _pendingByToken =
    HashMap<Object, _PendingPermissionRequest>.identity();
Future<void> _invalidationCommitTail = Future<void>.value();
bool _invalidationsClosed = false;
bool _requestsClosed = false;

void _emitInvalidation(AcpPermissionInvalidation event) {
  if (_invalidationsClosed) {
    throw StateError('Permission invalidation stream is closed.');
  }
  final previous = _invalidationCommitTail;
  final committed = Completer<void>.sync();
  _invalidationCommitTail = Future.wait<void>(<Future<void>>[
    previous,
    committed.future,
  ]);
  try {
    // Task 12 created this as a sync broadcast controller. Therefore every
    // current listener has accepted the event when add returns.
    _invalidations.add(event);
    committed.complete();
  } on Object catch (error, stackTrace) {
    committed.completeError(error, stackTrace);
    rethrow;
  }
}

Future<void> closeInvalidations() async {
  if (_invalidationsClosed) return;
  await _invalidationCommitTail;
  _invalidationsClosed = true;
  await _invalidations.close();
}

Future<void> closeRequests() async {
  if (_requestsClosed) return;
  _isClosed = true;
  _requestsClosed = true;
  await _requests.close();
}

final class _PendingPermissionRequest {
  _PendingPermissionRequest({
    required this.id,
    required this.lifecycleId,
    required this.sessionId,
    required this.token,
    required this.choices,
    required this.completer,
  });

  final String id;
  final String lifecycleId;
  final String sessionId;
  final Object token;
  final List<acp.PermissionChoice> choices;
  final Completer<acp.PermissionDecision> completer;
  Timer? timer;
  _PendingPermissionState state = _PendingPermissionState.pending;
}

Future<acp.PermissionDecision> request(
  acp.PermissionOptions options, {
  required Duration timeout,
}) async {
  if (_isClosed || !_requests.hasListener) {
    return const acp.PermissionDecision.cancelled();
  }
  final token = options.cancellationToken;
  if (token == null) {
    return const acp.PermissionDecision.cancelled();
  }
  final id = 'permission-${++_nextId}';
  final lifecycleId = 'permission-lifecycle-${++_nextLifecycleId}';
  if (_pendingById.containsKey(id) || _pendingByToken.containsKey(token)) {
    throw StateError('Duplicate ACP permission identity.');
  }
  final pending = _PendingPermissionRequest(
    id: id,
    lifecycleId: lifecycleId,
    sessionId: options.sessionId,
    token: token,
    choices: List<acp.PermissionChoice>.unmodifiable(options.choices),
    completer: Completer<acp.PermissionDecision>.sync(),
  );
  _pendingById[id] = pending;
  _pendingByToken[token] = pending;
  pending.timer = Timer(timeout, () {
    _invalidatePending(
      pending,
      acp.PermissionCancellationReason.timedOut,
    );
  });
  _requests.add(AcpPermissionRequest(
    id: id,
    lifecycleId: lifecycleId,
    title: options.title,
    rationale: options.rationale,
    sessionId: options.sessionId,
    toolName: options.toolName,
    toolKind: options.toolKind,
    options: List<String>.unmodifiable(options.options),
    choices: List<AcpPermissionChoice>.unmodifiable(
      options.choices.map((choice) => AcpPermissionChoice(
        optionId: choice.optionId,
        name: choice.name,
        kind: choice.kind,
      )),
    ),
    requestedAt: DateTime.now(),
    metadata: Map<String, Object?>.unmodifiable(options.metadata),
    transientPolicyContext: Map<String, Object?>.unmodifiable(
      options.transientPolicyContext,
    ),
  ));
  try {
    return await pending.completer.future;
  } finally {
    pending.timer?.cancel();
    if (identical(_pendingById[id], pending)) _pendingById.remove(id);
    if (identical(_pendingByToken[token], pending)) {
      _pendingByToken.remove(token);
    }
  }
}

void respond({
  required String id,
  required AcpPermissionDecision decision,
  String? selectedOptionId,
}) {
  final pending = _pendingById[id];
  if (pending == null || pending.state != _PendingPermissionState.pending) {
    return;
  }
  final optionId = selectedOptionId?.trim();
  if (optionId != null && optionId.isNotEmpty) {
    acp.PermissionChoice? choice;
    for (final candidate in pending.choices) {
      if (candidate.optionId == optionId) {
        choice = candidate;
        break;
      }
    }
    if (choice == null || _decisionForChoice(choice) != decision) {
      pending.state = _PendingPermissionState.userResolved;
      pending.timer?.cancel();
      pending.completer.complete(const acp.PermissionDecision.cancelled());
      return;
    }
    pending.state = _PendingPermissionState.userResolved;
    pending.timer?.cancel();
    pending.completer.complete(acp.PermissionDecision(
      _outcomeForDecision(decision),
      optionId: choice.optionId,
    ));
    return;
  }
  pending.state = _PendingPermissionState.userResolved;
  pending.timer?.cancel();
  pending.completer.complete(
    acp.PermissionDecision(_outcomeForDecision(decision)),
  );
}

void cancelPendingPermission({
  required Object cancellationToken,
  required acp.PermissionCancellationReason reason,
}) {
  final pending = _pendingByToken[cancellationToken];
  if (pending == null) return;
  _invalidatePending(pending, reason);
  _completeDeferredProviderDecision(pending);
}

AcpPermissionInvalidation _invalidationFor(
  _PendingPermissionRequest pending,
  acp.PermissionCancellationReason reason,
) {
  final appReason = switch (reason) {
    acp.PermissionCancellationReason.timedOut =>
      AcpPermissionInvalidationReason.timedOut,
    acp.PermissionCancellationReason.promptEnded =>
      AcpPermissionInvalidationReason.promptEnded,
    acp.PermissionCancellationReason.promptCancelled =>
      AcpPermissionInvalidationReason.promptCancelled,
    acp.PermissionCancellationReason.sessionClosed =>
      AcpPermissionInvalidationReason.sessionClosed,
    acp.PermissionCancellationReason.connectionClosed =>
      AcpPermissionInvalidationReason.connectionClosed,
    acp.PermissionCancellationReason.disposed =>
      AcpPermissionInvalidationReason.disposed,
  };
  return AcpPermissionInvalidation(
    requestId: pending.id,
    lifecycleId: pending.lifecycleId,
    sessionId: pending.sessionId,
    reason: appReason,
    invalidatedAt: DateTime.now(),
  );
}

bool _invalidatePending(
  _PendingPermissionRequest pending,
  acp.PermissionCancellationReason reason, {
  bool deferProviderCompletion = false,
}) {
  if (pending.state != _PendingPermissionState.pending) return false;
  pending.state = _PendingPermissionState.invalidated;
  pending.timer?.cancel();
  _emitInvalidation(_invalidationFor(pending, reason));
  if (reason == acp.PermissionCancellationReason.timedOut) {
    pending.completer.completeError(
      const acp.PermissionRequestTimeoutException(),
    );
  } else if (!deferProviderCompletion) {
    pending.completer.complete(const acp.PermissionDecision.cancelled());
  }
  return true;
}

void _completeDeferredProviderDecision(_PendingPermissionRequest pending) {
  if (pending.state != _PendingPermissionState.invalidated ||
      pending.completer.isCompleted) {
    return;
  }
  pending.completer.complete(const acp.PermissionDecision.cancelled());
}
```

pending 保存 id/lifecycleId/sessionId/token/choices/completer/timer/state；`finally` 只在 identity 仍相同时删除两个索引。UI respond 走 `userResolved` 且不发 invalidation。manager 的 cancellation callback 必须先捕获 token 对应的 pending，再对全部 reason 统一尝试 `_invalidatePending`，最后调用 `_completeDeferredProviderDecision`；因此 reconnect/dispose 预先只抢占 invalidation CAS 时，后到的真实 provider callback 仍能完成原 provider Future，而重复 callback 不会改写首因或重复完成。

- [ ] 17. 正常 prompt terminal 与用户 cancel 都沿 manager 的 `CancellablePermissionProvider.cancelPendingPermission` 传入同一个 token，reason 分别为 `promptEnded`、`promptCancelled`；bridge 不再另建 `cancelForPromptTerminal`/`cancelForUser` 入口。`cancelPendingPermission` 对全部 reason 都执行“捕获 pending → invalidate first-wins → complete deferred provider decision”，同 token 的后到 timeout/cancel 只能幂等完成 deferred Future，不能改写首因。

- [ ] 18. session close 同时保留 wrapper 的 session 快照入口；它按 pending identity 逐个调用 first-wins，不得按 sessionId 覆盖其他 token 的先前 winner。manager 后到的 `sessionClosed` callback 仍走 Step 17 的 token 入口：

```dart
void cancelForSession(String sessionId) {
  final snapshot = _pendingByToken.values
      .where((pending) => pending.sessionId == sessionId)
      .toList(growable: false);
  for (final pending in snapshot) {
    _invalidatePending(
      pending,
      acp.PermissionCancellationReason.sessionClosed,
    );
  }
}
```

- [ ] 19. 接 unavailable 调用点：reconnect/request fatal/transport/真实 explicit peer close 传 `connectionClosed`；只有 wrapper 自身 `_disposed == true` 时，core 的 `disposed` publication 才映射为 bridge `disposed`，reconnect 触发的旧 core dispose 仍映射 `connectionClosed`。logout 单独在 logout success 后以 `connectionClosed` 结算 bridge，但不得触发 peer-close bookkeeping。`cancelAllForUnavailable` 的同步段先用 CAS 抢占全部 pending，返回的 Future 表示这些 invalidation 已被同步 broadcast listener 接收；reconnect 与 public dispose 使用 `deferProviderCompletion: true`，只预先固定首因，等待 manager 的真实 cancellation callback 完成 provider Future。public dispose 必须等待 invalidation commit 后才能关闭 invalidation stream；reconnect 不关闭共享 bridge 的 request/invalidation stream，也不得抑制旧 core 的公共 unavailable publication。完整 bridge 方法体为：

```dart
Future<void> cancelAllForUnavailable({
  required bool disposed,
  bool deferProviderCompletion = false,
}) async {
  if (disposed) _isClosed = true;
  final reason = disposed
      ? acp.PermissionCancellationReason.disposed
      : acp.PermissionCancellationReason.connectionClosed;
  final snapshot = _pendingByToken.values.toList(growable: false);
  for (final pending in snapshot) {
    _invalidatePending(
      pending,
      reason,
      deferProviderCompletion: deferProviderCompletion,
    );
  }
  await _invalidationCommitTail;
}

// request fatal/transport/explicit peer close/logout:
await cancelAllForUnavailable(disposed: false);
// reconnect:
await cancelAllForUnavailable(
  disposed: false,
  deferProviderCompletion: true,
);
// DartAcpAgentClient.dispose:
await cancelAllForUnavailable(
  disposed: true,
  deferProviderCompletion: true,
);
```

第三方 `AcpClient.closePeerExplicitlyForTesting` 与 wrapper 代理均沿用 Task 11 已有定义，Task 13 不再重复声明。Task 13 也不首次声明、安装或替换 listener；这里只替换 Task 11 已定义且由原 listener 调用的 `_handleTask11PeerUnavailable(source, state)` body。固定顺序是 permission bridge first-wins/commit → Task 11 publication gate → Task 11 现有 `_publishPeerUnavailable(state)`；不得调用或新增任何 `ForTesting` publish 方法：

```dart
void _handleTask11PeerUnavailable(
  acp.AcpClient source,
  acp.AcpPeerUnavailableState state,
) {
  if (!_isCurrentPeerSource(source)) return;
  final disposed = switch (state.reason) {
    acp.AcpPeerUnavailableReason.disposed => _disposed,
    acp.AcpPeerUnavailableReason.fatalTimeout ||
    acp.AcpPeerUnavailableReason.transportClosed ||
    acp.AcpPeerUnavailableReason.explicitClose => false,
  };
  final committed = _permissionBridge.cancelAllForUnavailable(
    disposed: disposed,
  );
  unawaited(committed.then<void>((_) {
    final gate = _rawUnavailablePublicationGateForTesting;
    if (gate == null) {
      if (_isCurrentPeerSource(source)) _publishPeerUnavailable(state);
      return;
    }
    if (!_rawUnavailablePublicationPausedForTesting.isCompleted) {
      _rawUnavailablePublicationPausedForTesting.complete();
    }
    unawaited(gate.future.then<void>((_) {
      if (identical(_rawUnavailablePublicationGateForTesting, gate)) {
        _rawUnavailablePublicationGateForTesting = null;
      }
      if (_isCurrentPeerSource(source)) _publishPeerUnavailable(state);
    }));
  }));
}

Future<void> _finishLogout() async {
  // Run only after the real logout RPC succeeds.
  await _permissionBridge.cancelAllForUnavailable(disposed: false);
  _clearSessionScopedCaches();
}

@override
Future<void> dispose() {
  final existing = _disposeFuture;
  if (existing != null) return existing;
  _acceptingRawPromptOperations = false;
  _disposed = true;
  _invalidateAllConfigMutationQueues();

  // cancelAll performs every pending CAS synchronously before returning.
  // Keep this before clearing either connecting or active client identity.
  final invalidationsCommitted = _permissionBridge.cancelAllForUnavailable(
    disposed: true,
    deferProviderCompletion: true,
  );

  final connectingClient = _connectingClient;
  final connectingTransport = _connectingTransport;
  final connectingObservationListener =
      _connectingBoundedObservationListener;
  final connectingPeerUnavailableListener =
      _listenerFor(connectingClient);
  if (connectingClient != null) _disposingPeerSources.add(connectingClient);
  _connectingClient = null;
  _connectingTransport = null;
  _connectingBoundedObservationListener = null;
  return _disposeFuture = _disposeAll(
    connectingClient,
    connectingTransport,
    connectingObservationListener,
    connectingPeerUnavailableListener,
    invalidationsCommitted,
  );
}

Future<void> _disposeAll(
  acp.AcpClient? connectingClient,
  acp.AcpTransport? connectingTransport,
  acp.AcpBoundedObservationListener? connectingObservationListener,
  void Function(acp.AcpPeerUnavailableState)?
      connectingPeerUnavailableListener,
  Future<void> invalidationsCommitted,
) async {
  try {
    await invalidationsCommitted;
    await _permissionBridge.closeInvalidations();
  } finally {
    try {
      await _disposeClient(
        connectingClient,
        connectingTransport,
        connectingObservationListener,
        connectingPeerUnavailableListener,
      );
    } finally {
      try {
        await _disposeActiveClient(closePermissionStream: true);
      } finally {
        if (!_peerUnavailableStates.isClosed) {
          await _peerUnavailableStates.close();
        }
      }
    }
  }
}

Future<void> _disposeActiveClient({
  required bool closePermissionStream,
}) async {
  if (closePermissionStream) {
    // Bridge disposed already won in public dispose. Raw output settles as
    // unavailable and must not run through the user-cancel invalidator.
    await _finishAllRawOutputsForUnavailable();
  } else {
    // reconnect waits old raw done/owner release without sending cancel.
    await _invalidateAllRawPromptOperations(sendCancel: false);
  }
  _invalidateAllConfigMutationQueues();
  final client = _client;
  final transport = _transport;
  final observationListener = _boundedObservationListener;
  final peerUnavailableListener = _listenerFor(client);
  if (client != null) _disposingPeerSources.add(client);
  _client = null;
  _transport = null;
  _boundedObservationListener = null;
  _capabilities = null;
  _supportsLoadSession = false;
  _supportsListSessions = false;
  _supportsResumeSession = false;
  _activeSessionId = null;
  _rawPromptOperationsBySession.clear();
  _modesBySession.clear();
  _cwdBySession.clear();
  _additionalDirectoriesBySession.clear();
  _modeOverridesBySession.clear();
  _configOptionsBySession.clear();
  _configUpdateOmissionsBySession.clear();
  _settingsOmissionsBySession.clear();
  _boundedModesBySession.clear();
  if (closePermissionStream) {
    // Public dispose already committed disposed invalidations and closed the
    // invalidation stream in _disposeAll. Preserve the existing bridge-close
    // position here by closing only its request stream.
    await _permissionBridge.closeRequests();
  } else {
    // reconnect: fix connectionClosed first, keep both bridge streams reusable,
    // then let the manager callback complete each deferred provider Future.
    await _permissionBridge.cancelAllForUnavailable(
      disposed: false,
      deferProviderCompletion: true,
    );
  }
  await _disposeClient(
    client,
    transport,
    observationListener,
    peerUnavailableListener,
  );
}

Future<void> _disposeClient(
  acp.AcpClient? client,
  acp.AcpTransport? transport, [
  acp.AcpBoundedObservationListener? observationListener,
  void Function(acp.AcpPeerUnavailableState)? peerUnavailableListener,
]) async {
  if (client != null && observationListener != null) {
    client.removeBoundedObservationListener(observationListener);
  }
  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await transport?.stop();
  } on Object catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await client?.dispose().timeout(const Duration(milliseconds: 500));
  } on TimeoutException {
    // Preserve the existing bounded core-dispose behavior.
  } on Object catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  } finally {
    // Removal is deliberately after the core dispose attempt. The source stays
    // in _disposingPeerSources until then, so its public unavailable event is
    // not suppressed; wrapper dispose has already won bridge disposed, while
    // reconnect keeps the mapping connectionClosed.
    if (client != null && peerUnavailableListener != null) {
      _removePeerUnavailableListenerAfterCoreDispose(
        client,
        peerUnavailableListener,
      );
    }
    if (client != null) _disposingPeerSources.remove(client);
  }
  final cleanupError = firstError;
  if (cleanupError != null) {
    Error.throwWithStackTrace(cleanupError, firstStackTrace!);
  }
}
```

Task 11 既有 listener closure 调 `_handleTask11PeerUnavailable(source, state)`，不得在 Task 13 再加安装点或第二个 listener；connect 异常清理仍把 Task 11 的 `_listenerFor(client)` 传给 `_disposeClient`。这保持现有 `dispose → _disposeAll → _disposeActiveClient`、同步 `_disposed = true`、connecting client/transport 捕获、config queue 失效和全部 session cache 清理不变。public dispose 先以 `disposed + deferProviderCompletion` 同步固定 bridge 首因；随后 `_disposeActiveClient(true)` 的首个 await 是 `_finishAllRawOutputsForUnavailable()`，每个 operation 都调用 Task 11 已安装的 `_finishRawOutput(..., emitConnectionClosed: true)` action并等待 `finished`，绝不走 cancel-style invalidate。reconnect 的 `_disposeActiveClient(false)` 首个 await 才是 `_invalidateAllRawPromptOperations(sendCancel: false)`，并在 `_client = null`、raw map clear、任一 core/transport dispose 前等待旧 raw done/owner脱离；之后以 `connectionClosed + deferProviderCompletion` 结算旧权限，但不关闭共享 bridge stream。active/connecting source 均在清字段前加入 `_disposingPeerSources`，`_disposeClient` finally 只在 core dispose尝试完成后移除 listener 与 source，因此旧 core 的公共 unavailable publication 仍会发出；`_disposed` 为 false 的 reconnect core-disposed 映射 `connectionClosed`，只有 wrapper public dispose 才映射 `disposed`。迟到原因不能改写 permission 首因。

- [ ] 20. 固定唯一传递链为公开 `final timeouts → AcpConfig → AcpClient.start`。wrapper 构造器校验后保存现有公开字段 `final acp.AcpTimeouts timeouts;`；connect 必须是：

```dart
final config = acp.AcpConfig(
  timeouts: timeouts,
  permissionProvider: _InteractivePermissionProvider(
    _permissionBridge,
    permissionTimeout: timeouts.permission,
  ),
  // Preserve all existing config arguments.
);
final client = await acp.AcpClient.start(
  config: config,
  transport: transport,
);
```

不得新增私有 timeout 镜像字段、第二个 timeout 参数或复制 `AcpTimeouts`。

- [ ] 21. `AcpClient.start` 只把 `config.timeouts` 传给 `JsonRpcPeer`，并把同一个 `config` 实例传给 `SessionManager(config: config, peer: peer, ...)`。`SessionManager` 构造函数不得增加 `AcpTimeouts` 参数，permission/grace deadline 只读 `config.timeouts.permission` 与 `config.timeouts.promptCancelGrace`。为上面的真实实例 identity 断言增加只读测试观察口，不得暴露 manager/peer 本体：

```dart
@visibleForTesting
AcpTimeouts get peerTimeoutsForTesting => _peer.timeouts;

@visibleForTesting
AcpConfig get sessionManagerConfigForTesting => _sessionManager.config;
```

- [ ] 22. 复核 Step 12 的 4×6 canary 精确表仍完整保留，不得在实现后退化成只检查 `hasErrorData`/canary：24 个 case 的 factory 都恰调用一次并返回注入 token identity；permission 方法的四个非断连原因均为 cancelled result；fs read/write 与 terminal 的 timedOut 为 `-32002` 固定文本，三个本地取消原因为 `-32003` 固定文本；上述全部无 data；connectionClosed/disposed 两列都先完全 quiesce真实 client/stdio agent，再对各自 `probe.responseCapture.exists()` 直接断言 false，异步 response map/count不参与零-wire证据。触发前 controller binding/lifecycle 匹配 probe；触发后 invalidation恰一次，且 `requestId/lifecycleId/sessionId/reason` 分别精确等于 probe 与当前矩阵格；唯一 audit 与同 lifecycle/binding一致、cancelled/system，且非空 audit map序列化不含 canary。control/agent params 也没有 token marker或 token key。

- [ ] 22a. 增加两条生产复审回归：`permission provider never started receives no cancellation callback` 用 admission harness 遍历全部 `PermissionCancellationReason`，在 provider 尚未开始时断言零 request、零 cancellation callback、零 retained admission 与一次 response commit；`deferred reconnect and dispose complete owner permission futures` 用真实 owner-scoped stdio permission，断言 reconnect/dispose 均有界完成，reconnect 成功后先把 fixture 的 `_unavailable` watcher 刷新为新一轮 `client.peerUnavailableForTesting.first`，再证明新 lifecycle 可正常响应且旧索引不阻塞，dispose 后零 wire。旧 peer 的 unavailable publication 必须保留，不能靠生产代码抑制来让 fixture 通过。

- [ ] 23. 依次重跑本任务十二个 named tests：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission fixture commits consecutive controls and exact acknowledgements"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission bridge shares lifecycle identity and first timeout winner"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission bridge-first settlement stays first wins"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission manager-first settlement stays first wins"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "custom ACP timeouts reach every logical deadline consumer"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "custom ACP permission timeout reaches real interactive bridge"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "unavailable first winner invalidates bridge and UI once across layers"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "logout invalidates pending permission once without closing peer"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "concurrent permission tokens settle independently"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "permission invalidation canaries never reach wire or audit events"
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart --plain-name "permission provider never started receives no cancellation callback"
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart --plain-name "deferred reconnect and dispose complete owner permission futures"
```

Expected: 全部 PASS。

- [ ] 24. 运行 `./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart test/state/chat_controller_test.dart`。Expected: PASS。

- [ ] 25. 运行 `dart format third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/src/session/session_manager.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Expected: exit 0；factory/annotation/test canary 类型与 capture 代码均已格式化。

- [ ] 26. 运行 `git diff --check`。Expected: exit 0且无输出。

- [ ] 27. 运行 `git add third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/src/session/session_manager.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_request_timeout_test.dart test/acp/dart_acp_agent_client_test.dart`。Task 13 Files 已覆盖 factory、testing proxy、fixture/token 类型与真实 params capture，不得漏加 `acp_client.dart` 或 `session_manager.dart`。

- [ ] 28. 运行 `git commit -m "fix: propagate ACP permission deadlines"`。Expected: commit成功。

### Task 14: Streamable HTTP 心跳不绕过逻辑超时

**Files:**
- Create: `test/acp/acp_http_logical_timeout_test.dart`

本任务只增加跨层 HTTP/SSE 验收测试；Task 1–13 应使它直接通过。不得修改 transport/wrapper、增加第二套 timer或自动重连。named test 失败即证明前序实现未完成，必须回到对应任务补具体 RED/GREEN 后再重新执行本任务。

- [ ] 1. 新建 `_LogicalTimeoutHttpHarness`，粘贴以下关键实现；imports 固定为 `dart:async`、`dart:convert`、`dart:io`、dart_acp alias、`flutter_test`、`AgentEvent` 与 `DartAcpAgentClient`。这是本任务首次使用且完整定义的 HTTP harness，不再引用其他未定义 fixture：

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_acp/dart_acp.dart' as acp;
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/agent_event.dart';
import 'package:ianvs_acp/acp/dart_acp_agent_client.dart';

final class _LogicalTimeoutHttpHarness {
  _LogicalTimeoutHttpHarness._(this.server, this.subscription)
      : endpoint = Uri.parse('http://127.0.0.1:${server.port}/acp');
  final HttpServer server;
  final StreamSubscription<HttpRequest> subscription;
  final Uri endpoint;
  final List<HttpResponse> sse = <HttpResponse>[];
  final StreamController<Map<String, dynamic>> prompts =
      StreamController<Map<String, dynamic>>.broadcast(sync: true);
  final StreamController<void> cancels =
      StreamController<void>.broadcast(sync: true);
  final StreamController<void> deletes =
      StreamController<void>.broadcast(sync: true);
  Timer? heartbeat;
  int initializeCount = 0;
  int cancelCount = 0;
  int deleteCount = 0;
  int promptCount = 0;
  int nextSession = 0;

  static Future<_LogicalTimeoutHttpHarness> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    late _LogicalTimeoutHttpHarness harness;
    final subscription = server.listen((request) => harness.handle(request));
    harness = _LogicalTimeoutHttpHarness._(server, subscription);
    harness.heartbeat = Timer.periodic(
      const Duration(milliseconds: 15),
      (_) => harness.writeHeartbeats(),
    );
    return harness;
  }

  Future<void> handle(HttpRequest request) async {
    if (request.method == 'DELETE') {
      deleteCount += 1;
      deletes.add(null);
      for (final response in List<HttpResponse>.of(sse)) {
        try { await response.close(); } on Object {}
      }
      sse.clear();
      request.response.statusCode = HttpStatus.accepted;
      await request.response.close();
      return;
    }
    if (request.method == 'GET') {
      request.response.bufferOutput = false;
      request.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.write(': connected\n\n');
      await request.response.flush();
      sse.add(request.response);
      return;
    }
    final message = jsonDecode(await utf8.decoder.bind(request).join())
        as Map<String, dynamic>;
    final method = message['method'];
    request.response.headers.contentType = ContentType.json;
    if (method == 'initialize') {
      initializeCount += 1;
      request.response
        ..headers.set('Acp-Connection-Id', 'connection-$initializeCount')
        ..write(jsonEncode(<String, dynamic>{
          'jsonrpc': '2.0', 'id': message['id'],
          'result': <String, dynamic>{
            'connectionId': 'connection-$initializeCount',
            'protocolVersion': 1,
            'agentCapabilities': <String, dynamic>{},
            'authMethods': <Map<String, dynamic>>[],
          },
        }));
    } else if (method == 'session/new') {
      request.response.write(jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0', 'id': message['id'],
        'result': <String, dynamic>{'sessionId': 'session-${++nextSession}'},
      }));
    } else if (method == 'session/prompt') {
      promptCount += 1;
      prompts.add(message);
      request.response.statusCode = HttpStatus.accepted;
    } else if (method == 'session/cancel') {
      cancelCount += 1;
      cancels.add(null);
      request.response.statusCode = HttpStatus.accepted;
    }
    await request.response.close();
  }

  void writeHeartbeats() {
    for (final response in List<HttpResponse>.of(sse)) {
      try {
        response.write(': heartbeat\n\n');
        unawaited(response.flush().catchError((Object _) {}));
      } on Object {
        sse.remove(response);
      }
    }
  }

  Future<void> completePrompt(Object? id) async {
    final data = jsonEncode(<String, dynamic>{
      'jsonrpc': '2.0', 'id': id,
      'result': <String, dynamic>{'stopReason': 'end_turn'},
    });
    for (final response in sse) {
      response.write('event: message\ndata: $data\n\n');
      await response.flush();
    }
  }

  Future<void> dispose() async {
    heartbeat?.cancel();
    await prompts.close();
    await cancels.close();
    await deletes.close();
    for (final response in List<HttpResponse>.of(sse)) {
      try { await response.close(); } on Object {}
    }
    await subscription.cancel();
    await server.close(force: true);
  }
}
```

- [ ] 2. 写测试 `heartbeat does not extend raw prompt logical deadline`。wrapper 契约是把 typed exception 投影成一个 error event并正常结束 stream，不能断言 `.toList()` 抛异常。关键 body 固定为：

```dart
test('heartbeat does not extend raw prompt logical deadline', () async {
  final harness = await _LogicalTimeoutHttpHarness.start();
  final client = DartAcpAgentClient(
    agentHttpUrl: harness.endpoint,
    timeouts: const acp.AcpTimeouts(
      initialize: Duration(seconds: 1),
      request: Duration(seconds: 1),
      prompt: Duration(milliseconds: 75),
      permission: Duration(seconds: 1),
      promptCancelGrace: Duration(milliseconds: 75),
    ),
  );
  const canary = 'prompt-tool-token-path-payload-stack-canary';
  try {
    await client.connect();
    final session = await client.createSession(cwd: '/workspace');
    final promptSeen = harness.prompts.stream.first;
    final streamDone = client
        .sendPrompt(sessionId: session.id, prompt: canary)
        .toList();
    await promptSeen.timeout(const Duration(seconds: 2));
    final events = await streamDone.timeout(const Duration(seconds: 2));
    final errors = events
        .where((event) => event.type == AgentEventType.error)
        .toList(growable: false);
    expect(errors, hasLength(1));
    expect(errors.single.text, 'ACP prompt timed out.');
    expect(jsonEncode(errors.single.metadata), isNot(contains(canary)));
    expect(events.where((event) => event.type == AgentEventType.error),
        hasLength(1));
    expect(harness.cancelCount, 1);
  } finally {
    await client.dispose();
    await harness.dispose();
  }
});
```

`streamDone` 成功返回即是 stream done 的证据；不得改成 `throwsA`。
- [ ] 3. 运行：`./tool/flutter_test_isolated.sh test/acp/acp_http_logical_timeout_test.dart --plain-name "heartbeat does not extend raw prompt logical deadline"`。Expected: PASS。
- [ ] 4. 写独立测试 `prompt response inside grace keeps the HTTP peer reusable`；必须自行创建 harness/client/session 并在 `finally` 清理，不能依赖上一测试的局部变量。每个 broadcast barrier 都先订阅再启动对应 request：

```dart
test('prompt response inside grace keeps the HTTP peer reusable', () async {
  final harness = await _LogicalTimeoutHttpHarness.start();
  final client = DartAcpAgentClient(
    agentHttpUrl: harness.endpoint,
    timeouts: const acp.AcpTimeouts(
      initialize: Duration(seconds: 1),
      request: Duration(seconds: 1),
      prompt: Duration(milliseconds: 75),
      permission: Duration(seconds: 1),
      promptCancelGrace: Duration(milliseconds: 200),
    ),
  );
  try {
    await client.connect();
    final session = await client.createSession(cwd: '/workspace');

    final firstPromptSeen = harness.prompts.stream.first;
    final firstCancelSeen = harness.cancels.stream.first;
    final firstDone = client
        .sendPrompt(sessionId: session.id, prompt: 'first')
        .toList();
    final firstRequest =
        await firstPromptSeen.timeout(const Duration(seconds: 2));
    await firstCancelSeen.timeout(const Duration(seconds: 2));
    await harness.completePrompt(firstRequest['id']);
    final firstEvents =
        await firstDone.timeout(const Duration(seconds: 2));
    final firstErrors = firstEvents
        .where((event) => event.type == AgentEventType.error)
        .toList(growable: false);
    expect(firstErrors, hasLength(1));
    expect(firstErrors.single.text, 'ACP prompt timed out.');
    expect(harness.deleteCount, 0);

    final secondPromptSeen = harness.prompts.stream.first;
    final secondDone = client
        .sendPrompt(sessionId: session.id, prompt: 'second')
        .toList();
    final secondRequest =
        await secondPromptSeen.timeout(const Duration(seconds: 2));
    await harness.completePrompt(secondRequest['id']);
    final secondEvents =
        await secondDone.timeout(const Duration(seconds: 2));
    expect(
      secondEvents.where((event) => event.type == AgentEventType.error),
      isEmpty,
    );
    expect(secondEvents.last.metadata['stopReason'], 'endTurn');
    expect(harness.cancelCount, 1);
    expect(harness.promptCount, 2);
    expect(harness.initializeCount, 1);
  } finally {
    await client.dispose();
    await harness.dispose();
  }
});
```

第二轮同连接成功同时证明上一轮 owner、prompt operation与 update subscription 已清理。
- [ ] 5. 运行：`./tool/flutter_test_isolated.sh test/acp/acp_http_logical_timeout_test.dart --plain-name "prompt response inside grace keeps the HTTP peer reusable"`。Expected: PASS。
- [ ] 6. 写测试 `prompt missing past grace requires explicit HTTP reconnect`。fatal cleanup 不应自动发送 HTTP DELETE：首轮 timeout 后，用旧 client retry 得到 fixed connection-closed 且 `promptCount` 不变，作为 fatal 已安装 unavailable 的同步证据。只有在显式 `oldClient.dispose()` 前才订阅 `deletes.first`，dispose 返回后断言 DELETE 恰一次，再建立 replacement。完整 body 必须包含旧/新两个真实 `DartAcpAgentClient` 的独立构造与清理：

```dart
test('prompt missing past grace requires explicit HTTP reconnect', () async {
  final harness = await _LogicalTimeoutHttpHarness.start();
  final oldClient = DartAcpAgentClient(
    agentHttpUrl: harness.endpoint,
    timeouts: const acp.AcpTimeouts(
      initialize: Duration(seconds: 1),
      request: Duration(seconds: 1),
      prompt: Duration(milliseconds: 75),
      permission: Duration(seconds: 1),
      promptCancelGrace: Duration(milliseconds: 75),
    ),
  );
  DartAcpAgentClient? replacementClient;
  var oldClientDisposed = false;
  try {
    await oldClient.connect();
    final oldSession = await oldClient.createSession(cwd: '/workspace');
    final firstPromptSeen = harness.prompts.stream.first;
    final firstDone = oldClient
        .sendPrompt(sessionId: oldSession.id, prompt: 'missing-response')
        .toList();
    await firstPromptSeen.timeout(const Duration(seconds: 2));
    expect(harness.promptCount, 1);

    final firstEvents = await firstDone.timeout(const Duration(seconds: 2));
    final firstErrors = firstEvents
        .where((event) => event.type == AgentEventType.error)
        .toList(growable: false);
    expect(firstErrors, hasLength(1));
    expect(firstErrors.single.text, 'ACP prompt timed out.');

    final oldPromptCount = harness.promptCount;
    final oldRetryEvents = await oldClient
        .sendPrompt(sessionId: oldSession.id, prompt: 'must-not-reach-http')
        .toList()
        .timeout(const Duration(seconds: 2));
    final oldRetryErrors = oldRetryEvents
        .where((event) => event.type == AgentEventType.error)
        .toList(growable: false);
    expect(oldRetryErrors, hasLength(1));
    expect(oldRetryErrors.single.text, 'ACP connection closed.');
    expect(harness.promptCount, oldPromptCount,
        reason: 'an unavailable old client must not send another prompt');
    expect(harness.deleteCount, 0,
        reason: 'fatal logical timeout must not dispose HTTP transport');

    final deleteSeen = harness.deletes.stream.first;
    await oldClient.dispose();
    await deleteSeen.timeout(const Duration(seconds: 2));
    oldClientDisposed = true;
    expect(harness.deleteCount, 1);
    final replacement = DartAcpAgentClient(
      agentHttpUrl: harness.endpoint,
      timeouts: const acp.AcpTimeouts(
        initialize: Duration(seconds: 1),
        request: Duration(seconds: 1),
        prompt: Duration(milliseconds: 75),
        permission: Duration(seconds: 1),
        promptCancelGrace: Duration(milliseconds: 75),
      ),
    );
    replacementClient = replacement;
    await replacement.connect();
    final replacementSession =
        await replacement.createSession(cwd: '/workspace');
    final replacementPromptSeen = harness.prompts.stream.first;
    final replacementDone = replacement
        .sendPrompt(
          sessionId: replacementSession.id,
          prompt: 'replacement-success',
        )
        .toList();
    final replacementRequest =
        await replacementPromptSeen.timeout(const Duration(seconds: 2));
    await harness.completePrompt(replacementRequest['id']);
    final replacementEvents =
        await replacementDone.timeout(const Duration(seconds: 2));
    expect(
      replacementEvents.where(
        (event) => event.type == AgentEventType.error,
      ),
      isEmpty,
    );
    expect(replacementEvents.last.metadata['stopReason'], 'endTurn');
    expect(harness.promptCount, 2);
    expect(harness.initializeCount, 2);
  } finally {
    try {
      final currentReplacement = replacementClient;
      if (currentReplacement != null) {
        await currentReplacement.dispose();
      }
    } finally {
      try {
        if (!oldClientDisposed) await oldClient.dispose();
      } finally {
        await harness.dispose();
      }
    }
  }
});
```

这里旧 client retry 的 connection-closed error event才是 fatal unavailable 的确定性同步点；fatal 前后 `promptCount` 不变且 `deleteCount == 0`。`deleteSeen` 只证明显式 dispose 关闭旧 HTTP transport，必须在 dispose 前订阅并在 replacement 构造前确认恰一次。
- [ ] 7. 运行：`./tool/flutter_test_isolated.sh test/acp/acp_http_logical_timeout_test.dart --plain-name "prompt missing past grace requires explicit HTTP reconnect"`。Expected: PASS。
- [ ] 8. 运行回归：`./tool/flutter_test_isolated.sh test/acp/acp_http_logical_timeout_test.dart test/acp/streamable_http_acp_transport_test.dart test/acp/acp_request_timeout_test.dart`。Expected: PASS。
- [ ] 9. 运行：`dart format test/acp/acp_http_logical_timeout_test.dart`。Expected: exit 0。
- [ ] 10. 运行：`git diff --check`。Expected: exit 0。
- [ ] 11. 运行：`git add test/acp/acp_http_logical_timeout_test.dart`。
- [ ] 12. 运行：`git commit -m "test: cover ACP HTTP logical timeouts"`。Expected: commit成功。

### Task 15: 纯验证、全项目检查与两轮独立审查

**Files:**
- Verify: `third_party/dart_acp/lib`
- Verify: `lib/acp`
- Verify: `lib/state/chat_controller.dart`
- Verify: `test/acp`
- Verify: `test/state/chat_controller_test.dart`

本任务不授权修改、格式化写回、暂存或提交任何文件。任一测试失败或 reviewer finding 必须停止 Task 15，记录证据，并回到最早引入该行为的 Task 1–14：在所属 Task 补 named RED，执行该 Task 的 GREEN、回归与提交步骤，再从 Task 15 Step 1 重新开始。不得在验证阶段动态修改代码或扩大 Files。

进入本任务前，Task 1 前置的批准规格/计划文档提交必须早已在历史中，Task 1–14 的每个实现提交也必须完成，因此 clean status是可达前提而不是 Task 15 的清理工作。不能用一次带两个 path 的 `git log` 推断它们来自同一 revision；先只读逐项执行：

```bash
spec_path=docs/superpowers/specs/2026-07-14-acp-logical-timeouts-design.md
plan_path=docs/superpowers/plans/2026-07-14-acp-logical-timeouts.md
spec_rev="$(git log -1 --format='%H' -- "$spec_path")"
plan_rev="$(git log -1 --format='%H' -- "$plan_path")"
test -n "$spec_rev"
test -n "$plan_rev"
test "$spec_rev" = "$plan_rev"
git cat-file -e "HEAD:$spec_path"
git cat-file -e "HEAD:$plan_path"
document_commit_paths="$(git diff-tree --root --no-commit-id --name-only -r "$spec_rev" | LC_ALL=C sort)"
expected_document_paths="$(printf '%s\n%s\n' "$plan_path" "$spec_path" | LC_ALL=C sort)"
test "$document_commit_paths" = "$expected_document_paths"
git diff --exit-code HEAD -- "$spec_path" "$plan_path"
git status --short
```

Expected: `spec_rev` 与 `plan_rev` 都是非空完整 hash且精确相等；两个 `git cat-file -e` 均 exit 0，证明当前 `HEAD` 分别包含批准规格与计划；`diff-tree` 证明该共同 revision 的提交范围精确只有这两份文档；`git diff` exit 0；`git status --short` 无输出。任一条件不满足都停止并交回任务编排者；Task 15 不写文档、不暂存、不提交，也不负责把 dirty tree变 clean。

- [ ] 1. 运行 Task25 精确回归集合：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_request_timeout_test.dart test/acp/acp_http_logical_timeout_test.dart test/acp/acp_permission_request_test.dart test/acp/inbound_gate_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart test/acp/acp_client_inbound_gate_lifecycle_test.dart test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart test/acp/dart_acp_session_types_test.dart test/acp/streamable_http_acp_transport_test.dart test/acp/terminal_provider_test.dart test/state/chat_controller_test.dart
```

预期：全部通过，无 watchdog、未处理异步错误、open handle 或重复 response。
- [ ] 2. 运行全部 ACP 与状态回归：

```bash
./tool/flutter_test_isolated.sh test/acp test/state/chat_controller_test.dart
```

- [ ] 3. 派发 Round 1 规格 reviewer，要求逐条映射批准规格并返回 P0–P3 或 PASS及交接摘要。
- [ ] 4. 收取并记录 Round 1 规格 reviewer 的 PASS；任何 finding 都使本步骤失败并停止 Task 15，回所属 Task 修订。
- [ ] 5. 派发 Round 1 质量 reviewer，要求审查竞态、first-wins、资源清理、敏感信息和可维护性。
- [ ] 6. 收取并记录 Round 1 质量 reviewer 的 PASS；任何 finding 都使本步骤失败并停止 Task 15，回所属 Task 修订。
- [ ] 7. 派发 fresh Round 2 规格 reviewer，不提供 Round 1 结论；收取无 P0–P3 的 PASS交接摘要，否则停止并回所属 Task。
- [ ] 8. 派发 fresh Round 2 质量 reviewer，不提供 Round 1 结论；收取无 P0–P3 的 PASS交接摘要，否则停止并回所属 Task。
- [ ] 9. 运行：`dart format --output=none --set-exit-if-changed lib test third_party/dart_acp/lib`。Expected: exit 0。
- [ ] 10. 运行：`flutter analyze --no-pub`。Expected: exit 0。
- [ ] 11. 运行：`dart analyze third_party/dart_acp`。Expected: exit 0。
- [ ] 12. 运行：`./tool/flutter_test_isolated.sh`。Expected: 全项目测试PASS。
- [ ] 13. 运行：`git diff --check`。Expected: exit 0。
- [ ] 14. 运行：`git status --short`。Expected: 工作树为空；若非空，只记录路径并停止，不在 Task 15 处理。
- [ ] 15. 只有以上测试证据与四份 reviewer PASS 交接摘要齐全，才把 Task25标为完成。
