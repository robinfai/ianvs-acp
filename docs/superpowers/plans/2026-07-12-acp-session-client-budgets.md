# ACP 会话与客户端预算实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 SessionManager 成为 turn phase、response/update owning parse 和有界 observation 的唯一协议 owner，并删除应用层 raw JSON 业务重解析。

**Architecture:** 不可伪造 token 绑定 prompt/load/resume/setup；new/fork 在 sessionId 未知时使用 request-scoped guard。owning parser 生成 immutable typed model，并通过同步、无 replay listener registry 发布同一对象。应用 client 只做 typed projection，行为 cache 临时验证后原子替换。

**Tech Stack:** Dart ACP client、JSON-RPC session routing、Flutter 单元测试。

---

### Task 1: Phase owner token 与生命周期

**Files:**
- Modify: `third_party/dart_acp/lib/src/input_budget.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] 1. 写 RED：动态 budget 非法时，SessionManager/AcpClient 在注册 RPC handler、phase、observation listener 前构造失败，且没有部分状态。
- [ ] 2. 写 RED：同 session 已有 prompt/load/resume/setup 时新 prompt 明确拒绝；不同 session prompt 可并行；load/resume 继续遵守既有串行/rollback 语义，不新增全面互斥。
- [ ] 3. 写 RED：stale token 不能清新 phase；done/cancel/error 释放相同 owner；`close(sessionId)` 只失效该 session，manager/client dispose 才失效全部；late callback 不重建 phase。显式覆盖 resume 重叠。
- [ ] 4. 将现有 sessionId-only Set 替换为公开不可构造的 opaque identity token；冻结 source migration：

```dart
final class AcpSessionInputBudgetOwner {
  const AcpSessionInputBudgetOwner._(this.sessionId, this.generation);
  final String sessionId;
  final int generation;
}

final class _SessionInputBudgetPhase {
  _SessionInputBudgetPhase({
    required this.owner,
    required this.structuredGuard,
    required this.text,
    required this.thought,
  });
  final AcpSessionInputBudgetOwner owner;
  final AcpStructuredUpdateGuard structuredGuard;
  final AcpUtf8LineBudgetCounter text;
  final AcpUtf8LineBudgetCounter thought;
  int mediaBytes = 0;
  int items = 0;
  int retainedBytes = 0;
  bool invalidated = false;
}

AcpSessionInputBudgetOwner beginPromptTurn(String sessionId);
void endPromptTurn(AcpSessionInputBudgetOwner owner);
Future<void> cancelPromptTurn(AcpSessionInputBudgetOwner owner);
```

- [ ] 5. token 定义在 `session_manager.dart`，由同一 Dart library 的 private constructor 创建；`dart_acp.dart` 的 `show` 列表显式导出 `AcpSessionInputBudgetOwner`。SessionManager 与 AcpClient 都采用上述签名。
- [ ] 6. 迁移 `DartAcpAgentClient` raw prompt call site 保存 token并在 `finally` 传回；raw cancel 也必须传相同 token。普通 `SessionManager.prompt` 的内部 onCancel 闭包捕获自己的 token。删除 sessionId-only end/cancel API；stale cancel 最多发送固定拒绝，不能清除或取消新 generation。
- [ ] 7. load/resume 在 RPC 前取得 owner并在 `finally` 清理；close 仅按 session 清理，dispose 清全部。构造器最先 `budget.validate()`，之后才创建 handler/listener registry。
- [ ] 8. 运行完整 client test、格式化并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart
dart format third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/dart_acp_agent_client_test.dart
git add third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart lib/acp/dart_acp_agent_client.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: own ACP input budget phases"
```

### Task 2: request/update owning guard 接线

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] 1. 写 RED：unknown-session 抢先 update 拒绝；new/fork response 在登记 sessionId 前受 request guard；load/replay/setup immediate fields 与普通 update 共用 phase/root。
- [ ] 2. 写 RED：同 turn text/thought/media/items/retained exact/+1；结束、取消、失败、close/dispose 后计数器释放。
- [ ] 3. `_routeSessionUpdate` 在任何 `as Map/cast/map/toList/split/jsonEncode` 前选择 owning parser，并传当前 phase 的共享 root guard。
- [ ] 4. new/fork 只解析 request-scoped bounded response projection；登记 sessionId 后才能创建 session phase。load/resume 的 setup immediate fields 与 replay/update 消费同一 guard。replay 只保存 typed update/omission，tool state 不再对 raw 做 `jsonEncode`。
- [ ] 5. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart test/acp/dart_acp_session_types_test.dart
dart format third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/dart_acp_agent_client_test.dart
git add third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: guard ACP session updates at ownership boundary"
```

### Task 3: 有界 observation family

**Files:**
- Create: `third_party/dart_acp/lib/src/models/bounded_observation.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `third_party/dart_acp/lib/src/acp_client.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] 1. 写 RED：observation 只有 operation/sessionId/typed result 或 update；没有 raw/Object/toJson 后的 map；无 listener 立即丢弃；无 replay/StreamController；listener 异常隔离。
- [ ] 2. 新建独立 sealed family，不修改 `AcpUpdate`：

```dart
enum AcpBoundedSessionOperation {
  newSession,
  loadSession,
  resumeSession,
  forkSession,
}

sealed class AcpBoundedObservation {
  const AcpBoundedObservation();
}

final class AcpBoundedSessionResultObservation
    extends AcpBoundedObservation {
  const AcpBoundedSessionResultObservation({
    required this.operation,
    required this.sessionId,
    required this.result,
  });
  final AcpBoundedSessionOperation operation;
  final String sessionId;
  final SessionResult result;
}

final class AcpBoundedUpdateObservation extends AcpBoundedObservation {
  const AcpBoundedUpdateObservation({
    required this.sessionId,
    required this.update,
  });
  final String sessionId;
  final AcpUpdate update;
}

typedef AcpBoundedObservationListener =
    void Function(AcpBoundedObservation observation);

abstract interface class AcpBoundedObservationSource {
  void addBoundedObservationListener(AcpBoundedObservationListener listener);
  void removeBoundedObservationListener(
    AcpBoundedObservationListener listener,
  );
}
```

- [ ] 3. SessionManager 用同步 listener Set，遍历快照并逐 listener try/catch；日志只含固定类别。AcpClient 只代理 add/remove。
- [ ] 4. owning parser 在同一 guard 内完成 immutable copy 后发布同一实例；没有 listener 时不生成第二份数据。
- [ ] 5. 导出、运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart
dart format third_party/dart_acp/lib/src/models/bounded_observation.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart test/acp/dart_acp_agent_client_test.dart
git add third_party/dart_acp/lib/src/models/bounded_observation.dart third_party/dart_acp/lib/src/session/session_manager.dart third_party/dart_acp/lib/src/acp_client.dart third_party/dart_acp/lib/dart_acp.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "feat: publish bounded ACP observations"
```

### Task 4: typed carriers 与原子 cache

**Files:**
- Modify: `lib/acp/agent_event.dart`
- Modify: `lib/acp/acp_session_catalog.dart`
- Modify: `lib/acp/acp_session_settings.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `test/acp/dart_acp_agent_client_test.dart`

- [ ] 1. 写 RED：`AgentEvent.omissions`、`AcpSessionEntry.metaOmission`、`AcpSessionSettings.omissions/truncated` 默认兼容且不可变；远端同名 map 不能伪造 typed trust。
- [ ] 2. 写 RED：commands/config/modes 超限或非法后旧 cache 被清空；新 cache 仅全字段验证成功才替换。
- [ ] 3. 在 initialize/session request 前注册 observation listener，dispose 注销；删除 `_RawProtocolRequest`、pending/result/tool raw maps、`_rawSessionResultCapture` 及 `_captureProtocolIn/Out` 的业务用途。
- [ ] 4. 保留 `onProtocolIn` 仅作受信诊断；Ianvs 内部不解析、不 replay、不 cache。typed update 映射不调用整对象 `toJson/map/toList`。
- [ ] 5. 将既有 raw-capture tests 改为 bounded observation 断言；用 canary 证明 rejected payload 不进入 replay/capture/cache/message/log/异常。
- [ ] 6. 运行层级门禁并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart test/acp/dart_acp_session_types_test.dart test/acp/acp_permission_request_test.dart
dart format lib/acp/agent_event.dart lib/acp/acp_session_catalog.dart lib/acp/acp_session_settings.dart lib/acp/dart_acp_agent_client.dart test/acp/dart_acp_agent_client_test.dart
flutter analyze --no-pub
dart analyze third_party/dart_acp
git diff --check
git add lib/acp/agent_event.dart lib/acp/acp_session_catalog.dart lib/acp/acp_session_settings.dart lib/acp/dart_acp_agent_client.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: consume bounded ACP observations"
```
