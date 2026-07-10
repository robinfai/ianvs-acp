# 第一批：协议与权限安全整改实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复权限反转、取消状态污染、Workspace 越界、同源自动审查、Terminal 资源泄漏和 transport 永久挂起。

**Architecture:** 权限桥改为携带结构化 option 和精确选择结果；prompt 取消状态绑定到单轮生命周期；文件路径通过最深已存在祖先验证；terminal 与 transport 都以有限资源和明确终态为基本约束。

**Tech Stack:** Dart 3.12、Flutter、内置 `dart_acp`、`dart:io`、JSON-RPC、Flutter Test。

---

### Task 1: 权限选项和选择结果端到端保真

**Files:**
- Modify: `third_party/dart_acp/lib/src/providers/permission_provider.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `lib/acp/acp_permission_request.dart`
- Modify: `lib/acp/acp_agent_client.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Modify: `lib/acp/fake_agent_client.dart`
- Modify: `lib/acp/unavailable_acp_agent_client.dart`
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/ui/components/prompt_input.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/acp/acp_permission_request_test.dart`
- Test: `test/acp/dart_acp_agent_client_test.dart`
- Test: `test/state/chat_controller_test.dart`
- Test: `test/ui/prompt_input_test.dart`

- [ ] **Step 1: 写入单选项反转的失败测试**

在 `test/acp/dart_acp_agent_client_test.dart` 的 permission tests 中增加 allow-only 和 reject-only 两个 fake agent 场景，核心断言如下：

```dart
expect(request.choices.single.optionId, 'allow-once');
await client.respondToPermissionRequest(
  id: request.id,
  decision: AcpPermissionDecision.deny,
);
expect(
  permissionResponse['result'],
  containsPair('outcome', containsPair('outcome', 'cancelled')),
);
expect(jsonEncode(permissionResponse), isNot(contains('allow-once')));
```

反向场景只提供 `reject_once`，用户选择 allow，同样必须返回 `cancelled`。

- [ ] **Step 2: 运行测试并确认正确失败**

Run: `flutter test --no-pub test/acp/dart_acp_agent_client_test.dart --plain-name 'does not turn deny into the only allow option'`

Expected: FAIL；响应当前包含 `selected/allow-once`。

- [ ] **Step 3: 增加结构化权限类型**

在 `permission_provider.dart` 中用以下类型替代纯字符串 option 和纯 outcome 返回值：

```dart
class PermissionChoice {
  const PermissionChoice({
    required this.optionId,
    required this.name,
    this.kind,
  });

  final String optionId;
  final String name;
  final String? kind;
}

class PermissionDecision {
  const PermissionDecision(this.outcome, {this.optionId});

  const PermissionDecision.cancelled()
    : outcome = PermissionOutcome.cancelled,
      optionId = null;

  final PermissionOutcome outcome;
  final String? optionId;
}
```

`PermissionOptions.options` 改为 `List<PermissionChoice>`，`PermissionProvider.request` 改为 `Future<PermissionDecision>`。本地读写和 terminal 请求构造明确的 allow/reject choice。

- [ ] **Step 4: 让 UI 返回精确 optionId**

在 `AcpPermissionRequest` 中保存 `List<AcpPermissionChoice>`：

```dart
class AcpPermissionChoice {
  const AcpPermissionChoice({
    required this.optionId,
    required this.name,
    this.kind,
  });

  final String optionId;
  final String name;
  final String? kind;
}
```

AgentClient 接口的人工响应改为精确选择：

```dart
Future<void> respondToPermissionRequest({
  required String id,
  String? selectedOptionId,
  bool cancel = false,
});
```

PromptInput 为每个 `request.choices` 渲染一个按钮，点击时经 AppShell 和 ChatController 原样传递 `selectedOptionId`。自动 trust/reviewer decision 只能选择同类的 `allow_once` 或 `reject_once`；没有 once 选项或存在歧义时保持 pending。`_AcpPermissionBridge.respond` 验证 optionId 确实属于该请求后返回 `PermissionDecision`；取消返回 `const PermissionDecision.cancelled()`。删除 `_permissionOptionIdForOutcome` 的 `choices.length == 1` 回退。

- [ ] **Step 5: 运行权限定向测试**

Run: `flutter test --no-pub test/acp/acp_permission_request_test.dart test/acp/dart_acp_agent_client_test.dart test/ui/prompt_input_test.dart`

Expected: PASS。

- [ ] **Step 6: 提交权限修复**

```bash
git add third_party/dart_acp/lib/src/providers/permission_provider.dart third_party/dart_acp/lib/src/session/session_manager.dart lib/acp/acp_permission_request.dart lib/acp/acp_agent_client.dart lib/acp/dart_acp_agent_client.dart lib/acp/fake_agent_client.dart lib/acp/unavailable_acp_agent_client.dart lib/state/chat_controller.dart lib/ui/components/prompt_input.dart lib/ui/shell/app_shell.dart test/acp/acp_permission_request_test.dart test/acp/dart_acp_agent_client_test.dart test/state/chat_controller_test.dart test/ui/prompt_input_test.dart
git commit -m "fix: preserve ACP permission choices"
```

### Task 2: 把取消状态限制在当前 prompt turn

**Files:**
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Modify: `lib/acp/dart_acp_agent_client.dart`
- Test: `test/acp/dart_acp_agent_client_test.dart`

- [ ] **Step 1: 写入“第一轮取消、第二轮仍能授权”的失败测试**

```dart
await firstPromptStarted.future;
await client.cancel();
await firstPromptFinished.future;

final secondPermission = Completer<AcpPermissionRequest>();
final sub = client.permissionRequests.listen(secondPermission.complete);
unawaited(client.prompt('second turn'));
final request = await secondPermission.future.timeout(
  const Duration(seconds: 5),
);
expect(request.sessionId, 'session-1');
```

- [ ] **Step 2: 运行测试并确认超时失败**

Run: `flutter test --no-pub test/acp/dart_acp_agent_client_test.dart --plain-name 'cancelled turn does not cancel permissions in the next turn'`

Expected: FAIL；第二轮权限请求被 `_cancellingSessions` 直接取消。

- [ ] **Step 3: 建立统一 turn 生命周期**

在 `SessionManager` 中增加：

```dart
final Set<String> _activePromptSessions = <String>{};
final Set<String> _cancelledPromptSessions = <String>{};

void beginPromptTurn(String sessionId) {
  _activePromptSessions.add(sessionId);
  _cancelledPromptSessions.remove(sessionId);
}

void endPromptTurn(String sessionId) {
  _activePromptSessions.remove(sessionId);
  _cancelledPromptSessions.remove(sessionId);
}
```

typed 和 raw prompt 都在请求前调用 `beginPromptTurn`，在 `finally` 调用 `endPromptTurn`。`cancel()` 仅在 session 有 active turn 时加入 cancelled set；permission handler 只读取该 set。

- [ ] **Step 4: 运行取消与权限测试**

Run: `flutter test --no-pub test/acp/dart_acp_agent_client_test.dart test/acp/dart_acp_session_types_test.dart`

Expected: PASS。

- [ ] **Step 5: 提交 turn 生命周期修复**

```bash
git add third_party/dart_acp/lib/src/session/session_manager.dart lib/acp/dart_acp_agent_client.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: scope cancellation to one prompt turn"
```

### Task 3: 默认人工确认并禁止同源 reviewer 自动批准

**Files:**
- Modify: `lib/acp/acp_permission_reviewer.dart`
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/app.dart`
- Test: `test/state/chat_controller_test.dart`

- [ ] **Step 1: 写入默认策略和 reviewer 信任边界测试**

```dart
expect(controller.toolCallExecutionPolicy, AcpToolCallExecutionPolicy.defaultPermissions);

final reviewer = _FakePermissionReviewer(
  result: const AcpPermissionReviewResult(
    decision: AcpPermissionDecision.allow,
    risk: 'low',
  ),
  canAutoApprove: false,
);
await fake.emitPermissionRequest(request);
await pumpEventQueue();
expect(controller.pendingPermissionRequest, same(request));
expect(fake.lastPermissionDecision, isNull);
```

- [ ] **Step 2: 运行测试并确认当前自动批准**

Run: `flutter test --no-pub test/state/chat_controller_test.dart --plain-name 'same-agent reviewer cannot auto approve'`

Expected: FAIL；当前 reviewer 的 allow 被直接执行。

- [ ] **Step 3: 标记 reviewer 是否独立**

```dart
abstract class AcpPermissionReviewer {
  bool get canAutoApprove => false;

  Future<AcpPermissionReviewResult?> review(
    AcpPermissionRequest request, {
    required String workspacePath,
  });
}
```

只有显式配置的 MCP reviewer 覆盖为 `true`。`AcpAgentPermissionReviewer` 保持 `false`。`ChatController` 默认 policy 改为 `defaultPermissions`，自动批准条件同时要求 `reviewer.canAutoApprove`、`risk == low` 和 decision allow。

- [ ] **Step 4: 运行权限策略测试**

Run: `flutter test --no-pub test/state/chat_controller_test.dart test/acp/acp_permission_reviewer_test.dart`

Expected: PASS。

- [ ] **Step 5: 提交默认策略修复**

```bash
git add lib/acp/acp_permission_reviewer.dart lib/state/chat_controller.dart lib/app.dart test/state/chat_controller_test.dart
git commit -m "fix: require independent permission approval"
```

### Task 4: 修复 Workspace 符号链接后的缺失路径越界

**Files:**
- Modify: `third_party/dart_acp/lib/src/security/workspace_jail.dart`
- Modify: `third_party/dart_acp/lib/src/providers/fs_provider.dart`
- Create: `test/acp/workspace_jail_test.dart`

- [ ] **Step 1: 写入真实文件系统失败测试**

```dart
test('rejects missing descendants below an external symlink', () async {
  final root = await Directory.systemTemp.createTemp('jail-root-');
  final outside = await Directory.systemTemp.createTemp('jail-outside-');
  addTearDown(() => root.delete(recursive: true));
  addTearDown(() => outside.delete(recursive: true));
  await Link('${root.path}/link').create(outside.path);

  final provider = DefaultFsProvider(workspaceRoot: root.path);
  await expectLater(
    provider.writeTextFile('${root.path}/link/new/file.txt', 'blocked'),
    throwsA(isA<FileSystemException>()),
  );
  expect(File('${outside.path}/new/file.txt').existsSync(), isFalse);
});
```

- [ ] **Step 2: 运行测试并确认外部文件被创建**

Run: `flutter test --no-pub test/acp/workspace_jail_test.dart`

Expected: FAIL；当前实现跟随 symlink 写到 outside。

- [ ] **Step 3: 实现最深已存在祖先解析**

`WorkspaceJail` 增加 `resolveForWrite`：从目标向父目录回溯到第一个存在项，调用 `resolveSymbolicLinks()`，再只拼接经过 `basename` 校验的缺失段。若已存在祖先不在允许根内，立即拒绝。`DefaultFsProvider.writeTextFile` 在创建父目录后再次调用该方法并比较结果。

```dart
Future<String> resolveForWrite(String path) async {
  final missing = <String>[];
  var cursor = p.normalize(p.absolute(path));
  while (FileSystemEntity.typeSync(cursor, followLinks: false) ==
      FileSystemEntityType.notFound) {
    missing.add(p.basename(cursor));
    final parent = p.dirname(cursor);
    if (parent == cursor) throw FileSystemException('No existing ancestor', path);
    cursor = parent;
  }
  var resolved = await File(cursor).resolveSymbolicLinks();
  for (final segment in missing.reversed) {
    resolved = p.join(resolved, segment);
  }
  return p.normalize(resolved);
}
```

- [ ] **Step 4: 运行路径测试**

Run: `flutter test --no-pub test/acp/workspace_jail_test.dart test/acp/dart_acp_agent_client_test.dart`

Expected: PASS。

- [ ] **Step 5: 提交路径修复**

```bash
git add third_party/dart_acp/lib/src/security/workspace_jail.dart third_party/dart_acp/lib/src/providers/fs_provider.dart test/acp/workspace_jail_test.dart
git commit -m "fix: contain writes through workspace symlinks"
```

### Task 5: 使 Terminal 响应符合 ACP v1 并释放全部资源

**Files:**
- Modify: `third_party/dart_acp/lib/src/providers/terminal_provider.dart`
- Modify: `third_party/dart_acp/lib/src/session/session_manager.dart`
- Test: `test/acp/dart_acp_agent_client_test.dart`
- Create: `test/acp/terminal_provider_test.dart`

- [ ] **Step 1: 写入输出截断和 release-kill 失败测试**

```dart
final handle = await provider.create(
  sessionId: 'session-1',
  command: '/bin/sh',
  args: ['-c', "printf '1234567890'; sleep 30"],
  outputByteLimit: 5,
);
await _waitUntil(() => handle.currentOutput().isNotEmpty);
expect(handle.currentOutput(), '67890');
expect(handle.truncated, isTrue);
await provider.release(handle);
expect(await handle.process.exitCode.timeout(const Duration(seconds: 2)), isNotNull);
expect(provider.activeHandleCount, 0);
```

- [ ] **Step 2: 运行测试并确认失败**

Run: `flutter test --no-pub test/acp/terminal_provider_test.dart`

Expected: FAIL；当前输出不截断，release 不终止进程且 handle 仍保留。

- [ ] **Step 3: 实现有界 UTF-8 输出和幂等释放**

给 `TerminalProcessHandle` 增加 `outputByteLimit`、`truncated` 和 `ListQueue<int> _outputBytes`；每次写入后从头移除超限字节，再继续移除 UTF-8 continuation byte，保证缓冲区从字符边界开始。`release` 先 SIGTERM，2 秒后仍未退出则 SIGKILL，然后取消订阅。provider release 必须 `_handles.remove(handle.terminalId)`。

- [ ] **Step 4: 修正 wire response**

`session_manager.dart` 返回：

```dart
return <String, Object?>{
  'output': handle.currentOutput(),
  'truncated': handle.truncated,
  'exitStatus': exitCode == null ? null : <String, Object?>{'exitCode': exitCode},
};
```

create 读取 `outputByteLimit`，缺省 1 MiB；SessionManager dispose 遍历并 release 所有 terminal。

- [ ] **Step 5: 运行 terminal 协议测试**

Run: `flutter test --no-pub test/acp/terminal_provider_test.dart test/acp/dart_acp_agent_client_test.dart`

Expected: PASS。

- [ ] **Step 6: 提交 terminal 修复**

```bash
git add third_party/dart_acp/lib/src/providers/terminal_provider.dart third_party/dart_acp/lib/src/session/session_manager.dart test/acp/terminal_provider_test.dart test/acp/dart_acp_agent_client_test.dart
git commit -m "fix: bound and release ACP terminals"
```

### Task 6: 让 stdio/HTTP 断流在有限时间内结束请求

**Files:**
- Modify: `third_party/dart_acp/lib/src/rpc/line_channel.dart`
- Modify: `third_party/dart_acp/lib/src/transport/stdio_transport.dart`
- Modify: `lib/acp/streamable_http_acp_transport.dart`
- Modify: `lib/tasks/task_runner.dart`
- Test: `test/acp/dart_acp_agent_client_test.dart`
- Test: `test/acp/streamable_http_acp_transport_test.dart`
- Test: `test/tasks/task_runner_test.dart`

- [ ] **Step 1: 写入进程退出、SSE onDone 和 prompt deadline 测试**

```dart
final events = await client
    .sendPrompt(sessionId: 'session-1', prompt: 'crash now')
    .toList()
    .timeout(const Duration(seconds: 2));
expect(events.any((event) => event.type == AgentEventType.error), isTrue);
```

HTTP 测试在返回 202 后关闭 session SSE，断言 transport inbound stream 报错；TaskRunner 测试注入 50ms deadline，断言任务进入 failed 且 worker 槽释放。

- [ ] **Step 2: 运行三个新测试并确认超时失败**

Run: `flutter test --no-pub test/acp/dart_acp_agent_client_test.dart test/acp/streamable_http_acp_transport_test.dart test/tasks/task_runner_test.dart`

Expected: 新测试 FAIL；当前 pending 请求或 `isStreaming` 不结束。

- [ ] **Step 3: 关闭正确的入站流**

`LineJsonChannel` 的 stdout listener 增加 `onDone` 和错误传播：

```dart
onError: (Object error, StackTrace stackTrace) {
  _controller.local.sink.addError(error, stackTrace);
},
onDone: () {
  unawaited(_controller.local.sink.close());
},
```

`StdioTransport` 对任意 exit code 调用 channel 的 `closeInbound`，不能向 exposed outgoing sink 写错误。

- [ ] **Step 4: 增加 HTTP 和任务 deadline**

transport 构造器增加 `requestTimeout`、`firstByteTimeout`、`sseIdleTimeout`，所有 `request.close()`、body join 和 SSE 等待使用 `.timeout()`。非主动 stop 的 SSE `onDone` 向入站流发送 `StateError('ACP SSE stream closed')`。

TaskRunner 构造器增加 `promptDeadline`，等待 controller 时使用：

```dart
await _waitForPromptTurn(controller).timeout(
  promptDeadline,
  onTimeout: () {
    unawaited(controller.cancelPrompt());
    throw TimeoutException('Task prompt exceeded $promptDeadline');
  },
);
```

- [ ] **Step 5: 运行第一批全部定向测试**

Run: `flutter test --no-pub test/acp test/state/chat_controller_test.dart test/tasks/task_runner_test.dart`

Expected: PASS。

- [ ] **Step 6: 运行全量守门并提交**

Run: `flutter analyze --no-pub`

Expected: `No issues found!`

Run: `flutter test --no-pub`

Expected: 全部通过。

```bash
git add third_party/dart_acp/lib/src/rpc/line_channel.dart third_party/dart_acp/lib/src/transport/stdio_transport.dart lib/acp/streamable_http_acp_transport.dart lib/tasks/task_runner.dart test/acp/dart_acp_agent_client_test.dart test/acp/streamable_http_acp_transport_test.dart test/tasks/task_runner_test.dart
git commit -m "fix: terminate stalled ACP requests"
```
