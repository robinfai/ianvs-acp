# ACP Terminal Handle Budgets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 ACP terminal 增加默认全局 32、每 session 8 的两层原子句柄配额，并让所有创建、失败、关闭和释放路径只回收一次资源。

**Architecture:** `SessionManager` 使用一次性租约统计等待权限、正在创建和已登记的 terminal；`DefaultTerminalProvider` 在 `Process.start` 前使用独立租约做第二层进程保护。manager 把 handle、session 和租约收拢为一条所有权记录，并让 RPC release、公开 release、session close 和 dispose 共用一个释放入口。

**Tech Stack:** Dart 3.12、Flutter 3.44、vendored `dart_acp`、`json_rpc_2`、Flutter Test、`dart:io` Process。

---

## 文件职责

- `third_party/dart_acp/lib/src/providers/terminal_provider.dart`：默认值、异常、校验、provider pending+active 配额。
- `third_party/dart_acp/lib/src/session/session_manager.dart`：manager 租约、session 撤销、所有权与统一释放。
- `third_party/dart_acp/lib/src/acp_client.dart`：transport 启动前校验并向 manager 透传。
- `lib/acp/dart_acp_agent_client.dart`：应用层参数及两层透传。
- `test/acp/terminal_provider_test.dart`：provider 边界、并发、失败回滚、重复释放。
- `test/acp/dart_acp_agent_client_test.dart`：manager admission 与 lifecycle 竞态。
- `test/acp/acp_client_terminal_limits_lifecycle_test.dart`：`AcpClient.start` 前置校验和实际透传。

---

### Task 1: DefaultTerminalProvider 原子配额

**Files:**
- Modify: `third_party/dart_acp/lib/src/providers/terminal_provider.dart`
- Modify: `test/acp/terminal_provider_test.dart`

- [ ] **Step 1: 写精确边界和 session 隔离红灯测试**

```dart
test('provider bounds pending and active handles globally and per session', () async {
  final provider = DefaultTerminalProvider(
    maxActiveHandles: 2,
    maxActiveHandlesPerSession: 1,
  );
  final handles = <TerminalProcessHandle>[];
  addTearDown(() async {
    for (final handle in handles) await provider.release(handle);
  });

  handles.add(await provider.create(
    sessionId: 'session-a',
    command: '/bin/sh',
    args: const ['-c', 'sleep 30'],
  ));
  await expectLater(
    provider.create(
      sessionId: 'session-a',
      command: '/bin/sh',
      args: const ['-c', 'sleep 30'],
    ),
    throwsA(isA<TerminalHandleLimitException>()),
  );
  handles.add(await provider.create(
    sessionId: 'session-b',
    command: '/bin/sh',
    args: const ['-c', 'sleep 30'],
  ));
  await expectLater(
    provider.create(
      sessionId: 'session-c',
      command: '/bin/sh',
      args: const ['-c', 'sleep 30'],
    ),
    throwsA(isA<TerminalHandleLimitException>()),
  );
  await provider.release(handles.removeAt(0));
  handles.add(await provider.create(
    sessionId: 'session-c',
    command: '/bin/sh',
    args: const ['-c', 'sleep 30'],
  ));
});
```

- [ ] **Step 2: 写 pending create、启动失败和参数校验红灯测试**

```dart
test('provider reserves before Process.start and rolls back failures', () async {
  final provider = DefaultTerminalProvider(
    maxActiveHandles: 1,
    maxActiveHandlesPerSession: 1,
  );
  final first = provider.create(
    sessionId: 'session-a',
    command: '/bin/sh',
    args: const ['-c', 'sleep 30'],
  );
  await expectLater(
    provider.create(
      sessionId: 'session-b',
      command: '/bin/sh',
      args: const ['-c', 'sleep 30'],
    ),
    throwsA(isA<TerminalHandleLimitException>()),
  );
  await provider.release(await first);

  await expectLater(
    provider.create(
      sessionId: 'session-a',
      command: '/definitely/missing/ianvs-terminal',
      args: const ['unused'],
    ),
    throwsA(isA<ProcessException>()),
  );
  final retried = await provider.create(
    sessionId: 'session-a',
    command: '/bin/sh',
    args: const ['-c', 'sleep 30'],
  );
  await provider.release(retried);
});

test('terminal handle limits require positive ordered values', () {
  expect(() => DefaultTerminalProvider(maxActiveHandles: 0), throwsArgumentError);
  expect(
    () => DefaultTerminalProvider(
      maxActiveHandles: 1,
      maxActiveHandlesPerSession: 2,
    ),
    throwsArgumentError,
  );
});

test('natural exit retains capacity until idempotent release', () async {
  final provider = DefaultTerminalProvider(
    maxActiveHandles: 1,
    maxActiveHandlesPerSession: 1,
  );
  final handle = await provider.create(
    sessionId: 'session-a',
    command: '/bin/sh',
    args: const ['-c', 'exit 0'],
  );
  await handle.waitForExit();
  await expectLater(
    provider.create(
      sessionId: 'session-b',
      command: '/bin/sh',
      args: const ['-c', 'sleep 30'],
    ),
    throwsA(isA<TerminalHandleLimitException>()),
  );
  final firstRelease = provider.release(handle);
  final secondRelease = provider.release(handle);
  await Future.wait<void>([firstRelease, secondRelease]);
  expect(provider.activeHandleCount, 0);
});
```

- [ ] **Step 3: 运行红灯**

Run: `flutter test test/acp/terminal_provider_test.dart`

Expected: FAIL at compile time because the new limits and exception do not exist.

- [ ] **Step 4: 增加默认值、异常和共享校验**

```dart
const int defaultMaxTerminalHandles = 32;
const int defaultMaxTerminalHandlesPerSession = 8;

enum TerminalHandleLimitReason { global, session }

class TerminalHandleLimitException implements Exception {
  const TerminalHandleLimitException({required this.reason, required this.limit});
  final TerminalHandleLimitReason reason;
  final int limit;

  @override
  String toString() => 'Terminal handle limit exceeded.';
}

void validateTerminalHandleLimits({
  required int maxTerminalHandles,
  required int maxTerminalHandlesPerSession,
}) {
  if (maxTerminalHandles <= 0) {
    throw ArgumentError.value(maxTerminalHandles, 'maxTerminalHandles');
  }
  if (maxTerminalHandlesPerSession <= 0 ||
      maxTerminalHandlesPerSession > maxTerminalHandles) {
    throw ArgumentError.value(
      maxTerminalHandlesPerSession,
      'maxTerminalHandlesPerSession',
    );
  }
}
```

- [ ] **Step 5: 实现 provider 一次性租约**

```dart
class _ProviderTerminalReservation {
  _ProviderTerminalReservation(this.owner, this.sessionId);
  final DefaultTerminalProvider owner;
  final String sessionId;
  var released = false;

  void release() {
    if (released) return;
    released = true;
    owner._releaseReservation(this);
  }
}

class _ProviderTerminalRecord {
  const _ProviderTerminalRecord(this.handle, this.reservation);
  final TerminalProcessHandle handle;
  final _ProviderTerminalReservation reservation;
}
```

provider constructor 和状态：

```dart
DefaultTerminalProvider({
  this.maxActiveHandles = defaultMaxTerminalHandles,
  this.maxActiveHandlesPerSession = defaultMaxTerminalHandlesPerSession,
}) {
  validateTerminalHandleLimits(
    maxTerminalHandles: maxActiveHandles,
    maxTerminalHandlesPerSession: maxActiveHandlesPerSession,
  );
}

final int maxActiveHandles;
final int maxActiveHandlesPerSession;
final Map<String, _ProviderTerminalRecord> _handles = {};
final Set<_ProviderTerminalReservation> _reservations = {};
final Map<String, int> _reservationCountBySession = {};
var _nextTerminalId = 0;
```

`_reserve(sessionId)` 先检查 `_reservations.length` 和 session count，超限抛 `TerminalHandleLimitException`，成功后同步递增。`create` 在第一次 `await` 前 reserve；`Process.start` 或登记失败时释放。terminalId 使用 `'$sessionId:${_nextTerminalId++}'`，成功后保存 `_ProviderTerminalRecord`。边界测试保存每次返回的 terminalId，并断言 `ids.toSet().length == ids.length`。

```dart
@override
Future<void> release(TerminalProcessHandle handle) async {
  final record = _handles[handle.terminalId];
  final owned = record != null && identical(record.handle, handle)
      ? _handles.remove(handle.terminalId)
      : null;
  try {
    await handle.release();
  } finally {
    owned?.reservation.release();
  }
}
```

- [ ] **Step 6: 运行绿灯并提交**

Run: `flutter test test/acp/terminal_provider_test.dart`

Expected: all tests PASS, including existing output truncation and release tests.

```bash
git add third_party/dart_acp/lib/src/providers/terminal_provider.dart test/acp/terminal_provider_test.dart
git commit -m "fix: bound ACP terminal provider handles"
```

---

### Task 2: SessionManager 创建租约与 admission

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] **Step 1: 扩展 recording provider 夹具**

```dart
_RecordingTerminalProvider({
  this.failReleaseIds = const <String>{},
  this.releaseErrorMessage = 'injected terminal release failure',
  this.createBarrier,
  this.createStarted,
  this.failCreateCalls = const <int>{},
  Map<int, Completer<void>>? createBarriers,
}) : createBarriers = createBarriers ?? <int, Completer<void>>{};

final Set<int> failCreateCalls;
final Map<int, Completer<void>> createBarriers;
final List<String> createSessions = <String>[];
int get createCalls => createSessions.length;
```

在 fake `create` 的任何 await 前记录 call/session；按 call 等待 barrier，命中 `failCreateCalls` 时抛固定测试错误，再用 `/bin/sh -c 'sleep 30'` 创建 handle。

- [ ] **Step 2: 写 manager 全局、每 session 和 pending 红灯**

以现有 channel/peer/server 模式构造：

```dart
final manager = SessionManager(
  config: acp.AcpConfig(
    terminalProvider: provider,
    permissionProvider: acp.DefaultPermissionProvider(
      onRequest: (_) async => const acp.PermissionDecision.allow(),
    ),
  ),
  peer: peer,
  maxTerminalHandles: 2,
  maxTerminalHandlesPerSession: 1,
);
```

依次断言 session A 第二个、全局第三个请求返回：

```dart
expect(response['error'], <String, dynamic>{
  'code': -32001,
  'message': 'Terminal handle limit exceeded.',
});
expect(response.toString(), isNot(contains('unused')));
```

pending 测试把前两个 provider call 分别挂起；第三个请求必须在 provider 前失败，`expect(provider.createCalls, 2)`。

- [ ] **Step 3: 写 permission 与 create 失败回滚红灯**

权限第一次 deny、第二次 allow，limit=1：拒绝后 `provider.createCalls == 0`，第二次成功。另用 `failCreateCalls: {1}` 证明第一次 provider 失败后第二次成功且 `createCalls == 2`。

同时增加 constructor runtime 校验：

```dart
expect(
  () => SessionManager(
    config: acp.AcpConfig(),
    peer: peer,
    maxTerminalHandles: 1,
    maxTerminalHandlesPerSession: 2,
  ),
  throwsArgumentError,
);
```

- [ ] **Step 4: 运行红灯**

Run: `flutter test test/acp/dart_acp_agent_client_test.dart --plain-name "terminal handle"`

Expected: FAIL because manager limits and leases do not exist.

- [ ] **Step 5: 增加 manager 租约状态机**

```dart
enum _TerminalLeaseState { reserved, creating, active, released }

class _TerminalQuotaLease {
  _TerminalQuotaLease(this.owner, this.sessionId);
  final SessionManager owner;
  final String sessionId;
  var state = _TerminalLeaseState.reserved;
  var revoked = false;

  bool get isActive => state == _TerminalLeaseState.active;

  void markCreating() {
    if (state != _TerminalLeaseState.reserved || revoked) {
      throw StateError('Terminal session is closing or closed.');
    }
    state = _TerminalLeaseState.creating;
  }

  void markActive() {
    if (state != _TerminalLeaseState.creating || revoked) {
      throw StateError('Terminal session is closing or closed.');
    }
    state = _TerminalLeaseState.active;
    owner._pendingTerminalLeases.remove(this);
  }

  void revoke() {
    if (state == _TerminalLeaseState.released) return;
    revoked = true;
    if (state == _TerminalLeaseState.reserved) release();
  }

  void release() {
    if (state == _TerminalLeaseState.released) return;
    state = _TerminalLeaseState.released;
    owner._releaseTerminalLease(this);
  }
}
```

constructor 增加 32/8 参数和 `validateTerminalHandleLimits`；校验必须放在 `_boundedObservationListeners` 初始化和任何 `peer` handler 安装之前。状态增加全部 leases、pending leases、每 session count。`_reserveTerminalLease` 原子检查全局/session 数并同步登记；`_releaseTerminalLease` 幂等移除并减计数。

- [ ] **Step 6: 在 permission 前 reserve 并映射固定错误**

```dart
late final _TerminalQuotaLease lease;
try {
  lease = _reserveTerminalLease(sessionId);
} on TerminalHandleLimitException {
  throw _PayloadFreeRpcException(-32001, 'Terminal handle limit exceeded.');
}

var registered = false;
try {
  final execOutcome = await config.permissionProvider.request(
    PermissionOptions(
      title: 'Create terminal',
      rationale: 'Agent requested to execute commands',
      options: const ['allow', 'deny'],
      sessionId: sessionId,
      toolName: 'terminal',
      toolKind: 'execute',
      metadata: permissionMetadata,
      transientPolicyContext: <String, Object?>{
        if (env.isNotEmpty)
          'environment': Map<String, String>.unmodifiable(env),
      },
    ),
  );
  if (execOutcome.outcome != PermissionOutcome.allow) {
    throw Exception('Permission denied');
  }
  _requireUsableTerminalLease(lease);
  lease.markCreating();
  final handle = await provider.create(
    sessionId: sessionId,
    command: cmd,
    args: args,
    cwd: cwd,
    env: env.isEmpty ? null : env,
    outputByteLimit: outputByteLimit,
  );
  return await _runSerializedSessionMutation(sessionId, () async {
    if (_disposed || lease.revoked || _isSessionClosing(sessionId) ||
        !_sessionWorkspaceRoots.containsKey(sessionId)) {
      try {
        await provider.release(handle);
      } on Object {}
      throw StateError('Terminal session is closing or closed.');
    }
    if (_terminals.containsKey(handle.terminalId)) {
      try {
        await provider.release(handle);
      } on Object {}
      throw StateError('Terminal provider returned a duplicate terminalId.');
    }
    lease.markActive();
    registered = true;
    _terminals[handle.terminalId] = handle;
    _terminalSessions[handle.terminalId] = sessionId;
    _terminalEvents.add(
      TerminalCreated(
        terminalId: handle.terminalId,
        sessionId: sessionId,
        command: cmd,
        args: args,
        cwd: cwd,
      ),
    );
    return <String, dynamic>{'terminalId': handle.terminalId};
  });
} finally {
  if (!registered) lease.release();
}
```

- [ ] **Step 7: close/dispose 撤销 pending 租约**

```dart
void _revokeTerminalLeases({String? sessionId}) {
  for (final lease in _pendingTerminalLeases.toList(growable: false)) {
    if (sessionId == null || lease.sessionId == sessionId) lease.revoke();
  }
}
```

`_beginSessionClose` 调 session 版本；`dispose` 设置 `_disposed = true` 后调用全局版本。reserved 立即释放，creating 只标记 revoked，直到 late handle release 后才释放。

- [ ] **Step 8: 运行绿灯并提交**

Run: `flutter test test/acp/dart_acp_agent_client_test.dart --plain-name "terminal handle"`

Expected: admission、permission rollback、create rollback tests PASS.

```bash
git add third_party/dart_acp/lib/src/session/session_manager.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: reserve ACP terminal session capacity"
```

---

### Task 3: 统一 terminal 所有权与释放

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] **Step 1: 写 close/create 和 dispose/create 红灯测试**

扩展现有 `late terminal create is released and never registered after close`：limit=1，session A create 已进入 provider 时，session B create 仍返回 `-32001`；放行 A 后，A 的 late handle 被 release 且原请求返回固定 closing error；随后 B 重试成功。

```dart
expect(provider.createCalls, 1);
expect((await createTerminal('session-b', 'blocked'))['error'], isNotNull);
createBarrier.complete();
expect((await lateResponse)['error'], isNotNull);
expect(provider.releaseAttempts, ['terminal-1']);
expect(await createTerminal('session-b', 'retried'), contains('result'));
```

新增 dispose 版本：create 进入 provider 后调用 `manager.dispose()`，再放行；断言 late handle 被 release、未登记、请求失败，provider secret 不出现在响应或日志。

- [ ] **Step 2: 写并发 release 和 release 失败回收红灯测试**

同一 terminal 并发触发 RPC release、`releaseTerminal` 和 `closeSession`，断言：

```dart
expect(
  provider.releaseAttempts.where((id) => id == terminalId),
  hasLength(1),
);
```

显式 release 失败后仍可复用配额：

```dart
await expectLater(
  manager.releaseTerminal('terminal-1'),
  throwsA(isA<StateError>()),
);
expect(await manager.readTerminalOutput('terminal-1'), isEmpty);
expect(await createTerminal('session-a', 'replacement'), contains('result'));
```

扩展 close/dispose cleanup failure 测试：所有 handle 各有一次 release attempt；session A close 不动 B；失败日志只含固定 count。

再增加两个所有权测试：

- fake provider 让第 2 次 create 返回与第 1 次相同的 terminalId；第 2 个 handle 必须被 release，第 1 个仍可读取/释放，配额最终可复用。
- 同一 terminal 连续发送两次 RPC release；只产生一个 `TerminalReleased`，provider 只有一次 release attempt；未知 terminal release 成功但不产生事件。

- [ ] **Step 3: 运行红灯**

Run: `flutter test test/acp/dart_acp_agent_client_test.dart --plain-name "terminal"`

Expected: concurrent release 或 quota reuse FAIL because the release paths own separate map deletion logic.

- [ ] **Step 4: 用 managed record 替换双 map**

```dart
class _ManagedTerminal {
  const _ManagedTerminal({
    required this.handle,
    required this.sessionId,
    required this.lease,
  });

  final TerminalProcessHandle handle;
  final String sessionId;
  final _TerminalQuotaLease lease;
}
```

```dart
final Map<String, _ManagedTerminal> _terminals = <String, _ManagedTerminal>{};
```

删除 `_terminalSessions`。create 成功时保存：

```dart
lease.markActive();
_terminals[handle.terminalId] = _ManagedTerminal(
  handle: handle,
  sessionId: sessionId,
  lease: lease,
);
```

output/wait/kill/read helpers 全部通过 `record?.handle` 访问；session cleanup 按 `record.sessionId` 过滤。

- [ ] **Step 5: 实现唯一释放入口**

```dart
Future<bool> _releaseManagedTerminal(String terminalId) async {
  final record = _terminals.remove(terminalId);
  if (record == null) return false;
  try {
    final provider = config.terminalProvider;
    if (provider != null) await provider.release(record.handle);
  } finally {
    record.lease.release();
  }
  return true;
}
```

RPC release：

```dart
final released = await _releaseManagedTerminal(termId);
if (released) {
  _terminalEvents.add(TerminalReleased(terminalId: termId));
}
return null;
```

公开 `releaseTerminal` 直接调用统一入口。session close 拍摄匹配 terminalId 后逐个调用并聚合失败。dispose 先撤销 pending，再拍摄全部 terminalId，逐个释放并只记录固定失败数量。

- [ ] **Step 6: 收紧 late/duplicate 清理的错误所有权**

late/duplicate handle 使用嵌套 `try/finally`：provider.release 是否抛错都执行 `lease.release()`；对外只保留：

```dart
throw StateError('Terminal session is closing or closed.');
```

或：

```dart
throw StateError('Terminal provider returned a duplicate terminalId.');
```

不得拼接 provider error。

- [ ] **Step 7: 运行绿灯并提交**

Run: `flutter test test/acp/dart_acp_agent_client_test.dart --plain-name "terminal"`

Expected: all terminal lifecycle, late create, close/dispose and release failure tests PASS.

```bash
git add third_party/dart_acp/lib/src/session/session_manager.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: unify ACP terminal ownership cleanup"
```

---

### Task 4: AcpClient 与应用包装层参数透传

**Files:**
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Create: `test/acp/acp_client_terminal_limits_lifecycle_test.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] **Step 1: 写 transport 前置校验红灯测试**

新测试文件复用 inbound-gate lifecycle 测试的 tracking transport：

```dart
test('invalid terminal handle limits fail before transport start', () async {
  final transport = _TrackingAcpTransport();
  await expectLater(
    AcpClient.start(
      config: AcpConfig(),
      transport: transport,
      maxTerminalHandles: 1,
      maxTerminalHandlesPerSession: 2,
    ),
    throwsArgumentError,
  );
  expect(transport.startCount, 0);
});
```

- [ ] **Step 2: 写 AcpClient 实际透传红灯测试**

用 1/1 启动 client。fake transport server 响应 `session/resume`；随后向 client channel 发送两个同 session 的 `terminal/create`。第一个成功，第二个固定 `-32001`，且：

```dart
expect(provider.createCalls, 1);
expect(secondResponse['error'], <String, dynamic>{
  'code': -32001,
  'message': 'Terminal handle limit exceeded.',
});
```

teardown 调 `client.dispose()`，断言 transport `stopCount == 1` 且 handle 已释放。

- [ ] **Step 3: 写 DartAcpAgentClient 构造校验红灯测试**

```dart
expect(() => DartAcpAgentClient(maxTerminalHandles: 0), throwsArgumentError);
expect(
  () => DartAcpAgentClient(
    maxTerminalHandles: 1,
    maxTerminalHandlesPerSession: 2,
  ),
  throwsArgumentError,
);
final client = DartAcpAgentClient(
  maxTerminalHandles: 4,
  maxTerminalHandlesPerSession: 2,
);
expect(client.maxTerminalHandles, 4);
expect(client.maxTerminalHandlesPerSession, 2);
```

扩展现有真实 terminal raw protocol 测试：构造 `DartAcpAgentClient(enableTerminalProvider: true, maxTerminalHandles: 1, maxTerminalHandlesPerSession: 1)`，第一个长运行 terminal/create 成功；第二个同 session create 返回固定 `-32001`；release 第一个后第三个成功。这条测试证明包装层确实同时透传到默认 provider 与 manager，而不是只保存字段。

- [ ] **Step 4: 运行红灯**

Run: `flutter test test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart --plain-name "terminal handle limits"`

Expected: FAIL at compile time because public parameters do not exist.

- [ ] **Step 5: AcpClient.start 校验并透传**

在 `acp_client.dart` 导入 provider，签名增加：

```dart
int maxTerminalHandles = defaultMaxTerminalHandles,
int maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
```

在构造 transport 前：

```dart
validateTerminalHandleLimits(
  maxTerminalHandles: maxTerminalHandles,
  maxTerminalHandlesPerSession: maxTerminalHandlesPerSession,
);
```

构造 `SessionManager` 时原样透传。

- [ ] **Step 6: DartAcpAgentClient 暴露并向两层透传**

```dart
this.maxTerminalHandles = acp.defaultMaxTerminalHandles,
this.maxTerminalHandlesPerSession = acp.defaultMaxTerminalHandlesPerSession,
```

constructor body 调 `acp.validateTerminalHandleLimits`。启用 terminal 时：

```dart
terminalProvider: enableTerminalProvider
    ? acp.DefaultTerminalProvider(
        maxActiveHandles: maxTerminalHandles,
        maxActiveHandlesPerSession: maxTerminalHandlesPerSession,
      )
    : null,
```

调用 `AcpClient.start` 时也传入同一组值。

- [ ] **Step 7: 运行绿灯并提交**

Run: `flutter test test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart --plain-name "terminal handle limits"`

Expected: public validation and pass-through tests PASS.

```bash
git add third_party/dart_acp/lib/src/acp_client.dart lib/acp/dart_acp_agent_client.dart test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: expose ACP terminal handle limits"
```

---

### Task 5: 完整验证与双重审查

**Files:**
- Verify only: all Task 1-4 files

- [ ] **Step 1: 运行 terminal 定向测试**

Run: `flutter test test/acp/terminal_provider_test.dart test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart`

Expected: all tests PASS; no process, subscription or zone error leak.

- [ ] **Step 2: 运行 ACP session/peer 回归**

Run: `flutter test test/acp/dart_acp_session_types_test.dart test/acp/json_rpc_peer_inbound_gate_test.dart`

Expected: all tests PASS; Task36 gate, reserved slots and close FIFO do not regress.

- [ ] **Step 3: 运行范围静态、格式和差异检查**

```bash
flutter analyze third_party/dart_acp/lib/src/providers/terminal_provider.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart lib/acp/dart_acp_agent_client.dart test/acp/terminal_provider_test.dart test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart
dart format --output=none --set-exit-if-changed third_party/dart_acp/lib/src/providers/terminal_provider.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart lib/acp/dart_acp_agent_client.dart test/acp/terminal_provider_test.dart test/acp/acp_client_terminal_limits_lifecycle_test.dart test/acp/dart_acp_agent_client_test.dart
git diff --check
```

Expected: analyze prints `No issues found`; format prints `0 changed`; diff check has no output.

- [ ] **Step 4: 规格审查**

独立 reviewer 对照 `docs/superpowers/specs/2026-07-13-terminal-handle-budgets-design.md` 检查默认值、两层 admission、pending 计数、session revoke、late create、duplicate ID、统一释放、payload-free error、API 透传和测试矩阵。缺口交回原实现代理修复并重新审查。

- [ ] **Step 5: 独立质量审查**

第二位 reviewer 检查并发 create/release、负计数或永久占位、release error、dispose/close 竞态、真实进程清理、日志 canary 和测试夹具泄漏。P0-P3 问题交回原实现代理修复并重新验证。

- [ ] **Step 6: 主线程 fresh 复验**

主线程重新执行 Steps 1-3，不复用代理结果；核对 `git status --short` 只出现当前任务文件，每个提交后工作区必须干净。
