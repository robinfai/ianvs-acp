# ACP Terminal 句柄配额设计

日期：2026-07-13
状态：已批准，待实现

## 背景

ACP terminal 已具备单句柄 1 MiB 输出保留上限、UTF-8 边界截断，以及 release 时终止进程和取消输出订阅的能力。但是，`SessionManager` 和 `DefaultTerminalProvider` 都只在异步创建完成后登记 handle，没有限制等待权限、正在启动和已创建的终端总数。

恶意或失控的 agent 可以并发发起大量 `terminal/create`：所有调用在第一次 `await` 前都看到相同的空闲状态，随后创建过多进程，并按每个 handle 的输出上限占用大量内存。自定义 provider 还会绕过默认 provider 内部的任何单层限制。

本设计为 terminal 创建与释放增加两层、原子、可验证的句柄配额。

## 目标

- 默认最多管理 32 个 terminal handle。
- 默认每个 ACP session 最多管理 8 个 terminal handle。
- 等待权限、正在创建和已登记的 handle 都占用配额。
- 并发 create 不得穿透全局或每 session 上限。
- permission 拒绝、provider 创建失败、session close、manager dispose、晚到创建和 release 失败都必须只归还一次配额。
- 默认 provider 被直接调用或被多个 manager 共用时，仍有自身的全局与每 session 硬上限。
- 超限错误不包含 sessionId、command、cwd、env、provider 错误或原请求内容。
- 保持现有调用兼容；现有调用方不传新参数即可获得安全默认值。

## 非目标

- 不修改单 handle 1 MiB 输出保留上限。
- 不把配额加入持久化 Agent 配置或设置界面。
- 不修改 terminal wire response 字段。
- 不改变权限审批、workspace jail 或进程 kill 的既有策略。
- 不在本任务处理 ACP 逻辑请求 timeout；该问题属于后续 Task25。

## 方案比较

### 方案一：只在 SessionManager 限额

可覆盖默认和自定义 provider，也掌握 session close/dispose 生命周期；但直接使用 `DefaultTerminalProvider` 或多个 manager 共用 provider 时没有 provider 级保护。

### 方案二：只在 DefaultTerminalProvider 限额

改动较小，但自定义 provider 可绕过；provider 也无法可靠处理 permission、session close 和 manager dispose 的所有权语义。

### 方案三：两层配额

`SessionManager` 作为主策略层限制客户端全局和每 session 数量；`DefaultTerminalProvider` 作为进程创建兜底层再限制自身全局和每 session 数量。两层都把 pending create 计入配额。

本项目采用方案三。

## 默认值与公开 API

统一导出以下默认值：

```dart
const int defaultMaxTerminalHandles = 32;
const int defaultMaxTerminalHandlesPerSession = 8;
```

以下 API 增加可选命名参数：

```dart
DefaultTerminalProvider({
  int maxActiveHandles = defaultMaxTerminalHandles,
  int maxActiveHandlesPerSession = defaultMaxTerminalHandlesPerSession,
});

SessionManager({
  ...,
  int maxTerminalHandles = defaultMaxTerminalHandles,
  int maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
});

AcpClient.start({
  ...,
  int maxTerminalHandles = defaultMaxTerminalHandles,
  int maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
});

DartAcpAgentClient({
  ...,
  int maxTerminalHandles = defaultMaxTerminalHandles,
  int maxTerminalHandlesPerSession = defaultMaxTerminalHandlesPerSession,
});
```

`DartAcpAgentClient` 把同一组值传给 `AcpClient.start` 和 `DefaultTerminalProvider`，避免两层配置漂移。自定义 provider 可以有自己的更严格限制，但 manager 上限始终生效。

所有上限必须大于零，且每 session 上限不得大于全局上限。`DartAcpAgentClient` 构造、`AcpClient.start` 和 `SessionManager` 必须在 transport 启动或安装 RPC handler 前校验；`DefaultTerminalProvider` 必须在 `Process.start` 前校验。

本任务不修改 `AcpTerminalProviderConfig`。若以后需要让用户调节配额，必须同时实现配置存储往返和设置界面，不能只增加会被界面保存时丢失的 JSON 字段。

## 配额租约

两层都使用一次性、幂等的租约对象，不用分散的整数加减推导状态。租约状态为：

```text
reserved -> active -> released
```

manager 租约还记录 `sessionId`，并可在 session close/dispose 时标记为撤销。核心不变量：

- `reserved + active <= global limit`。
- 同一 session 的 `reserved + active <= per-session limit`。
- 每个成功登记的 terminal 恰好拥有一个 active manager 租约。
- 每个进入 `Process.start` 的默认 provider create 恰好拥有一个 provider 租约。
- 租约最多释放一次；重复 release 不会产生负计数。
- 进程自然退出不自动归还配额；只有显式 release、session close 或 dispose 才释放 handle 与输出资源。

## 创建流程

### SessionManager

1. 校验 manager 未 dispose，并取得已登记、未关闭的 `sessionId`。
2. 在任何异步权限调用之前同步申请 manager 租约。
3. 若全局或每 session 配额已满，立即抛出固定的配额异常；不发送权限请求，也不调用 provider。
4. 等待权限决定。拒绝、取消或权限 provider 抛错时在 `finally` 释放租约。
5. workspace jail 解析失败或请求参数失败时释放租约。
6. permission 返回后、调用 provider 前再次检查 manager/session 状态。已关闭或已 dispose 时释放租约并使用固定关闭错误结束。
7. 调用 `provider.create`。provider 抛错时释放 manager 租约。
8. 在 session 串行 mutation 中再次检查 session/manager 状态。
9. 若 session 已关闭，先 best-effort release 晚到 handle，再释放租约，返回固定关闭错误；provider 错误正文不能覆盖或泄漏到响应。
10. 若 provider 返回重复 `terminalId`，不得覆盖旧 handle；释放新 handle、释放新租约并失败。
11. 成功时把 handle、sessionId 和租约原子转移到一条 managed terminal 记录，再发布 `TerminalCreated`。

session close 会立即撤销仍在等待 permission 的租约，使其 permission 完成后不能启动进程。已经进入 `provider.create` 的租约继续占配额，直到晚到 handle 被 release，防止 close 与 create 竞态提前空出名额而超订。

### DefaultTerminalProvider

1. 在 `Process.start` 前同步申请 provider 租约。
2. 达到全局或每 session 上限时立即失败，不启动进程。
3. `Process.start` 失败时释放租约。
4. 创建 handle 成功后，把租约与 handle 一起登记。
5. 若 terminalId 冲突，释放新进程和新租约，不覆盖旧 handle。
6. provider release 从索引摘除所有权，只调用一次 handle.release，并在 `finally` 释放租约。

默认 provider 的 terminalId 使用 provider 实例内单调递增序号，不能只依赖同一微秒时间戳。

## 统一释放流程

`terminal/release`、公开 `releaseTerminal`、session close 和 manager dispose 共用一个私有释放入口。

第一个调用者原子取得 managed terminal 所有权并：

1. 从 terminalId、sessionId 索引摘除记录。
2. 标记 manager 租约只释放一次。
3. 调用 provider.release，且同一 handle 最多调用一次。
4. 在 `finally` 归还 manager 租约，即使 provider.release 抛错也不永久占额。
5. 只有首次入站 `terminal/release` 发布一次 `TerminalReleased`；未知或重复 release 幂等成功，不重复事件。

session close 继续按现有方式把 terminal 清理失败聚合为 `SessionCloseCleanupException`；dispose 继续尝试释放所有 handle，并只记录固定失败数量。显式 release 可以继续把释放失败返回调用方。任何日志和 wire 错误都不得包含 provider 异常正文。

## 错误模型

增加可测试的 `TerminalHandleLimitException`，内部可以用枚举区分全局或每 session 原因，但对 JSON-RPC 统一返回：

```text
code: -32001
message: Terminal handle limit exceeded.
```

错误响应不得序列化请求 payload。

其他固定语义：

- 非法配置：`ArgumentError`，发生在 transport/process 启动前。
- permission deny：保持现有权限拒绝语义，并释放租约。
- late create：`Terminal session is closing or closed.`。
- 未知 terminal release：幂等成功。
- provider release 失败：按调用入口保留现有传播、聚合或脱敏日志策略，但配额和 manager 所有权仍被回收。

## 测试设计

### Manager 必需测试

- 全局上限精确值和 `+1`；释放后可再次创建。
- 每 session 上限精确值和 `+1`；另一 session 仍可创建。
- 多个 pending create 已进入 provider 时，下一请求在进入 provider 前被拒绝。
- 等待 permission 的请求计入配额；超限请求不产生第二个权限请求。
- permission deny/cancel/error 后名额可复用。
- workspace 或 provider.create 失败后名额可复用。
- close 发生在 permission pending 时，不得在 permission 返回后启动进程。
- close/dispose 发生在 provider.create pending 时，late handle 被释放、未登记，配额仅在释放后归还。
- queued/active handle 通过 RPC release、公开 release、session close、dispose 各入口只释放一次。
- provider.release 抛错时，所有权与配额仍归还，其他 handle 继续清理。
- session A close 只释放 A 的 handle，B 的 handle 与配额状态不受影响。
- provider 返回重复 terminalId 时旧 handle 不被覆盖，新 handle 被释放。
- 参数非法时 `AcpClient.start` 不启动 transport。
- 超限响应和日志不包含 session、command、env 或 provider canary。

### Provider 必需测试

- 全局与每 session 精确上限和 `+1`。
- 同步发起多个 `create` Future 时，pending `Process.start` 也计入配额。
- `Process.start` 失败后名额可复用。
- 同一 handle 并发或重复 release 只释放一次、只归还一次。
- 进程自然退出但未 release 时仍占用 handle 名额。
- terminalId 唯一，不会覆盖活动 handle。

### 回归测试

- 现有输出截断、UTF-8 边界、release kill 测试继续通过。
- 现有 session close/dispose、late create、释放失败脱敏日志测试继续通过。
- `dart_acp_agent_client_test.dart` 与 `dart_acp_session_types_test.dart` 的 ACP 回归继续通过。

## 文件范围

生产代码：

- `third_party/dart_acp/lib/src/providers/terminal_provider.dart`
- `third_party/dart_acp/lib/src/session/session_manager.dart`
- `third_party/dart_acp/lib/src/acp_client.dart`
- `lib/acp/dart_acp_agent_client.dart`

测试：

- `test/acp/terminal_provider_test.dart`
- `test/acp/dart_acp_agent_client_test.dart`
- 新增独立 lifecycle/透传测试文件时，只覆盖 `AcpClient.start` 前置校验与参数透传。

## 验收标准

- 所有必需红灯测试在旧实现稳定失败，并在实现后通过。
- 全局与每 session 配额在并发 pending create 下不可穿透。
- 所有创建、关闭、失败和重复释放路径满足一次性租约不变量。
- 失败响应与日志不含请求或 provider payload。
- 定向测试、既有 ACP 回归、静态分析、格式和 `git diff --check` 全部通过。
- 规格审查和独立质量审查均无未解决的 P0-P3 问题。
