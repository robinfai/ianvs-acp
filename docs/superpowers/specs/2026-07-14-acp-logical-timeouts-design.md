# ACP 逻辑请求超时设计

日期：2026-07-14
状态：书面规格已批准

## 背景

ACP transport 已限制 HTTP 建连、首字节、响应体读取和 SSE 空闲时间，stdio transport 也会在子进程退出后关闭入站流。但是，transport 健康不代表某个 JSON-RPC 请求会完成：HTTP POST 可以返回 `202`，SSE 可以持续发送心跳，而 agent 永远不返回匹配请求 ID 的结果。

`AcpTimeouts` 目前只定义了 `initialize`、可空 `prompt` 和可空 `permission`，全仓没有消费这些字段。`JsonRpcPeer` 直接调用 `json_rpc_2.Peer.sendRequest`；该库把请求保存在私有 pending map 中，只有收到匹配响应或 peer 关闭时才删除。只在外层 Future 增加 `.timeout()` 会让调用方结束，却不能清除底层 pending。

typed prompt 和 raw prompt 还分别维护取消流程。取消可以结束界面 stream，但原 `session/prompt` RPC 仍可能永久挂起。交互权限桥同样会把未回答请求永久保存在 `_pending`，同时占用入站门禁名额；terminal create 等路径还会长期占用资源租约。

本设计为 ACP 出站请求、prompt 取消和入站权限请求增加统一、有限、可验证的逻辑截止时间。

## 目标

- initialize、普通请求、prompt 和权限请求都有安全、可配置的有限默认时限。
- typed 与 raw 调用必须经过同一个 JSON-RPC 超时入口，不能由包装层路径绕过。
- transport 持续收到 SSE 心跳时，缺少匹配响应的请求仍按逻辑时限结束。
- 普通请求超时后清除 `json_rpc_2` 的全部底层 pending，不保留不可恢复的半开 peer。
- prompt 超时先发送一次取消，并给 agent 一个有限宽限期；只有无法结算原请求时才关闭 peer。
- 用户主动取消 prompt 也必须在宽限期后收割未结算的底层请求。
- 同一 session 的旧 prompt、已经接纳或运行中的权限请求被完全收割前，不得启动新 owner 或新 `session/prompt`，避免旧 update、permission 或 response 污染下一轮。
- session close 必须取消并收割活动 prompt；远端 close 失败或超时时仍完成本地 session 清理。
- 权限超时释放权限桥记录、界面待处理项、入站门禁名额和对应的 terminal pending 租约；prompt owner 只由 prompt 自身的成功、失败、取消、超时、session close 或 dispose 终态清理。
- peer 进入不可用状态后，已经运行但尚未开始副作用的入站 handler 必须失效，不能在断连后启动文件访问或终端进程。
- timeout、response、close、dispose 和迟到结果并发时，每个资源只结算或清理一次。
- 所有超时错误固定且无请求 payload、prompt、tool、token、路径或底层异常正文。

## 非目标

- 不实现 HTTP/SSE 自动重连或透明重试。
- 不为 TaskRunner 增加任务总时限。
- 不 fork 或重写 `json_rpc_2`。
- 不改变 terminal、文件系统、附件或会话状态的既有预算。
- 不在本任务全面重构日志与持久化脱敏；该工作属于 Task26。
- 不让 `JsonRpcPeer` 直接拥有或停止 transport。

## 方案比较

### 方案一：统一、按方法分类的 peer 截止时间

所有 typed、raw 和扩展请求都经过 `JsonRpcPeer` 的单一发送入口。入口按方法选择 initialize、prompt 或普通请求时限。普通请求超时时关闭 peer；prompt 先取消并等待宽限。权限由 `SessionManager` 的统一 helper 和交互权限桥共同清理。

优点是覆盖完整、能真正冲刷 `json_rpc_2` 私有 pending，并能统一处理 raw prompt 和 HTTP 心跳盲区。代价是需要明确 peer 的致命状态以及 prompt 取消竞态。

### 方案二：各上层调用点分别增加 `.timeout()`

改动表面较小，但 `DartAcpAgentClient.connect`、raw prompt 和扩展 `sendRaw` 容易绕过；超时 Future 也不会从 `json_rpc_2` 内部删除 pending。

### 方案三：只依赖 transport 超时

无法区分单个 JSON-RPC 请求，也无法处理持续 SSE 心跳但没有匹配响应的情况。

本项目采用方案一。

## 默认值与公开 API

`AcpTimeouts` 改为全部有限，并增加普通请求和 prompt 取消宽限：

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
}
```

所有时限必须严格大于零。`AcpConfig` 构造时校验，`AcpClient.start` 在 `transport.start()` 前再次校验。`DartAcpAgentClient` 增加一个默认值为 `const AcpTimeouts()` 的公开字段和构造参数，并把同一个值传给 `AcpConfig`；包装层构造时也要提前校验。

现有不传超时参数的调用获得以上默认值。原先显式传入 `null` 以禁用 prompt 或 permission 超时的调用不再合法；安全边界不提供无限等待开关。

`promptCancelGrace` 是 peer 的统一收割/提交清理宽限：除等待取消后的 prompt response 外，也约束 prompt 终态后的 admission barrier，以及任何带响应的入站 permission handler 已结束、但 response 被 batch sibling 阻塞的时间。多个原因命中同一 prompt/admission 时复用最早启动的窗口，不能串联延长。

`AcpAgentClient` 增加只读的 `permissionInvalidations` stream。`AcpPermissionRequest` 增加由 client 生成且在 `withGeneration`/audit copy 中保持不变的 `lifecycleId`；为兼容 fake 和非 ACP 实现，构造默认值为空，但 `DartAcpAgentClient` 发出的请求必须非空且在 client 实例内唯一。非空 lifecycleId 纳入 `bindingKey`，不纳入权限内容指纹。事件模型 `AcpPermissionInvalidation` 只表示请求在 UI 之外失效，字段固定为 request id、lifecycleId、sessionId、失效原因和时间；原因包括 `timedOut`、`promptEnded`、`promptCancelled`、`sessionClosed`、`connectionClosed` 和 `disposed`。用户通过 UI 正常 allow/deny/cancel 不发送 invalidation，因为调用方已经拥有该结算结果。

`PermissionRequestTimeoutException` 作为 dart_acp 内部权限边界可识别的公开类型导出，其 `toString()` 固定为 `Permission request timed out.`，不保存 `PermissionOptions` 或底层 error。`PermissionOptions` 增加一个只在本地传递、不进入 metadata/JSON/toString 的 opaque `cancellationToken`。增加 `PermissionCancellationReason`（`timedOut`、`promptEnded`、`promptCancelled`、`sessionClosed`、`connectionClosed`、`disposed`）和可选的 `CancellablePermissionProvider` 接口：

```dart
abstract interface class CancellablePermissionProvider
    implements PermissionProvider {
  void cancelPendingPermission({
    required Object cancellationToken,
    required PermissionCancellationReason reason,
  });
}
```

`SessionManager` 为每次权限调用持有唯一 identity token、一次性本地 cancellation Completer 和接纳时的 session generation，并按 session 跟踪已经接纳或仍活动的 operation。来自 JSON-RPC 的四类权限门在进入 Task36 handler 队列前创建这些状态；helper 只消费接纳快照，不能在 handler 真正开始时重新绑定 owner。对所有 provider 都把 provider Future、deadline、operation cancellation 和 peer-unavailable 四个终态放入同一个竞争；只有实现该可选接口的 provider 才额外获得精确到单请求的及时取消通知。session close、peer unavailable 和 dispose 通过 manager 自己的 operation 集合逐一完成本地 cancellation 并通知 provider，不允许 provider 仅按 session 猜测并误伤其他请求。

## 统一出站请求生命周期

`JsonRpcPeer` 接收一份已校验的 `AcpTimeouts`，所有 `initialize`、`newSession`、`loadSession`、`prompt`、`setSessionMode` 和 `sendRaw` 最终调用同一个私有发送入口。`AcpClient.sendRaw` 和 `JsonRpcPeer.sendRaw` 明确拒绝 `session/prompt`；raw prompt 必须改用 `sendPromptRequest(owner:, content:)`，该 API 不接受第二份 sessionId，而是只使用 `owner.sessionId`，避免 owner/session 错配或绕过收割屏障。

方法分类固定为：

- `initialize` 使用 `initialize`。
- `session/prompt` 使用 `prompt`。
- 其他所有需要响应的请求使用 `request`。
- notification 不等待响应，不应用 request deadline。

每个出站请求只能从 pending 进入一个终态：response、remote error、timeout 或 peer closed。计时器、response、显式 close、transport error 和 dispose 通过同一个幂等结算边界竞争，迟到或重复结果不得改变首个终态。

### 普通请求与 initialize 超时

普通请求或 initialize 达到截止时间时：

1. 原子地把 peer 标记为 fatal，不再接收新出站请求。
2. 首个超时请求以固定 `AcpRequestTimeoutException` 结束，其 `toString()` 仅为 `ACP request timed out.`。
3. 复用 `_closeFuture` 幂等关闭 peer，使 `json_rpc_2` 清空全部内部 pending。
4. 同时受影响的其他请求统一映射为固定 `AcpConnectionClosedException`，其 `toString()` 仅为 `ACP connection closed.`；不得暴露底层含 method 的 `StateError`。
5. fatal 后发起的新请求立即得到同一个固定 connection-closed 错误。

关闭 peer 不直接停止 transport。`AcpClient.dispose` 和 `DartAcpAgentClient` 现有连接清理负责最终停止 transport；调用方必须显式重新连接后才能继续。

### Prompt 总时限与取消宽限

typed 与 raw prompt 都先由 `SessionManager.beginPromptTurn` 创建唯一 owner generation 和 manager 级 prompt lifecycle，再把该 owner token 传入同一个 `sendPromptRequest`。manager lifecycle 持有 peer reap Future、该 owner 下已经接纳或运行中的 permission operation 集合和一个组合 settlement Future。manager 在发送 RPC 前再次确认 owner 仍由对应 session 的 input phase 持有、session 未 closing 且组合 barrier 空闲；stale 或 mismatch owner 使用固定本地错误拒绝，且不得写出任何 RPC。peer 为每个活动 `session/prompt` 建立内部 prompt operation，记录 sessionId、owner token、单调 generation、原 request Future、取消是否已发送、宽限是否已开始和请求是否已结算。peer 同时按 sessionId 和 owner token 索引 operation；迟到 callback 只有在两个索引仍指向同一 generation 时才能移除记录或发布结果。

raw operation 在创建 owner 和 dispatch RPC 之前再次检查 `cancelRequested`。取消若发生在 RPC dispatch 前，则本地成功结束：不创建 owner、不发送 `session/prompt`、不发送 `session/cancel`、不建立 reap barrier；cancel completion 只完成一次。owner 创建与 peer operation 同步登记之间不得插入 `await`，因此 dispatch 后的取消总能用 owner token 命中已登记 operation。

同一 session 最多存在一个 pending 或 settling manager lifecycle。只有 peer prompt operation 已收割，并且该 owner 下所有已接纳或运行中的 permission operation 都已本地结算、Task36 reservation 已释放、对应 JSON-RPC response 已提交到出站 sink，组合 settlement Future 才完成。请求因 peer close 而无法提交 response 时，以 admission 的 peer-close 终态代替 response 提交；该分支仍须确认 reservation 已释放或已从关闭的 gate 逻辑脱离。完成之前：

- `SessionManager.beginPromptTurn` 在创建新 owner 前同步拒绝，固定消息为 `ACP prompt is already active or settling.`。
- peer 层也拒绝第二个 `session/prompt`，防止包内直接调用绕过 manager。
- 旧 turn 的 `session/update` 和 `session/request_permission` 没有新 owner 可以命中，只能由旧 owner 接收或按现有 stale-owner 规则丢弃。

这个组合 reap barrier 不等待锁，也不把新 prompt 排队；调用方在旧 lifecycle 完整结算后重试。它从入站接纳时就计入尚未取得 handler permit 的旧请求，因此同时避免旧响应、排队中的旧 permission 或运行中的旧 permission 恰好在新轮创建后按 sessionId 误进入新 owner。

任何 prompt 终态都不能无限等待这个 barrier。正常 response、远端 error 或逻辑 prompt timeout 获胜时，peer/manager operation 先原子缓存不可变的 terminal winner，并签发只属于该 owner generation 的一次性 delivery right；随后收割或取消 peer prompt operation、以 `promptEnded` 结算 owner admissions，再启动同一个 `promptCancelGrace` 清理宽限并等待组合 barrier。宽限内完成则 peer 保持可用。宽限结束仍有 prompt/admission 未结算时，以携带同一 owner generation 的 `fatalTimeout` cleanup cause 关闭 peer，让 gate close 与 response 的 peer-close 替代终态完成 barrier；这个 cleanup close 只能失效后续 update/permission，不能撤销 terminal delivery right。显式用户取消与 session close 不签发新的用户可见 delivery right，但也复用这一份有界 cleanup/reap Future；任何路径都不得串联出多个两秒窗口。

typed lifecycle 的 delivery right 同时持有本次调用专属 turn sink identity。cleanup fatal 时取消它对共享 session updates 的订阅并转为 terminal-only，但不关闭这个 sink，也不依赖可能已失效的 `_sessionStreams` 来投递最后事件。barrier 完成后不再用已失效的 input owner 做最终判断，而是原子 claim right：正常成功向 turn sink 直接发布一次对应 `TurnEnded` 并关闭；远端错误或固定 prompt-timeout 直接发布一次已缓存 error、再发布一次 `TurnEnded(StopReason.other)` 并关闭。replay buffer 只在相同 session generation 仍登记时追加同一份 `TurnEnded`，不能经共享 stream 再投递第二次。

raw 专用 prompt API 同样在 claim 后只返回一次原 response，或抛出一次原远端错误/固定 prompt-timeout；app wrapper 再分别生成一个 terminal `AgentEvent` 或一个 error event 并结束 raw stream。delivery 完成后才释放 right、owner 和 manager lifecycle。cleanup close 后到达的 update、permission、第二个 response/error 或 timer 都不能再投递。

`DartAcpAgentClient` 的 raw operation 状态从布尔 invalidated 扩为 `active`、`terminalOnly`、`invalidated`、`finished`。同 owner cleanup fatal 且 delivery right 已登记时只转为 `terminalOnly`：立即停止 session/terminal updates，但允许专用 prompt Future 的一个缓存终态通过；其他 unavailable cause 转为 `invalidated` 并使用 connection-closed。`terminalOnly` 不能被后续通用断连清理覆盖成丢弃终态，claim 后原子转为 `finished` 并关闭 events controller。

只有由同一 lifecycle 的 cleanup grace 触发、且 terminal winner 已先登记的 fatal close 可以跨 unavailable 保留 delivery right。transport close、普通 request fatal、显式 close 或 dispose 在 delivery claim 前获胜时不创建或释放尚未 claim 的 right，typed/raw 使用固定 connection-closed 语义并正常结束 stream；其他 owner 的 cleanup close 也不能借用本 lifecycle 的 right。close cause 与 delivery claim 都按 owner token 和 generation 做 identity 比较，不按 sessionId 猜测。

prompt 达到总时限时：

1. deadline 获得 prompt operation 的一次性结算权后，先登记固定 prompt-timeout terminal winner/delivery right；在发送取消或等待宽限之前，再以 `promptEnded` 原因同步触发该 owner 下所有 admission/permission operation 的本地 cancellation。该首因不得被后续 fatal close 覆盖。
2. 只发送一次 `session/cancel` notification。
3. 在单个 `promptCancelGrace` 窗口内同时等待原 prompt request 和组合 admission barrier；任一先完成仍继续等待另一项，不能重新开始宽限计时。
4. 若宽限内两者都完成，消费原成功或远端错误以从 `json_rpc_2` 删除 pending；调用方仍以固定 `AcpPromptTimeoutException` 结束，其 `toString()` 仅为 `ACP prompt timed out.`。peer 保持可用，下一轮可以在同一连接上开始。
5. 若宽限结束时任一项未完成，把 peer 标记为 fatal 并关闭，冲刷全部 pending、逻辑脱离 gate 中仍运行的 reservation，并以 peer-close 替代终态完成未提交 response 的 admission。调用方仍收到固定 prompt timeout；其他受影响请求收到固定 connection-closed 错误。deadline 已先结算的 owner 权限继续保持 `promptEnded`，不得改写为 `connectionClosed`。

用户主动取消 typed 或 raw prompt 时，`cancelPromptTurn(owner)` 必须用 owner token 精确命中同一个 manager lifecycle。它先以 `promptCancelled` 原因完成该 owner 下全部 permission operation 的本地 cancellation，并逐 token 通知可取消 provider；再发送至多一次 prompt cancel 并启动共享的有界 cleanup/reap。取消 API 在 notification 成功提交后即可返回，不阻塞界面两秒；组合 reap barrier 在 permission operation 与 peer operation 都结算前持续拒绝同 session 的新 owner 和新 prompt。宽限内消费原响应且旧权限全部结算后屏障解除；宽限结束时任一项未完成则关闭 peer并完成替代终态。stale owner 的取消不能按 sessionId 误取消后续 lifecycle。

prompt 正常响应或远端错误时，`sendPromptRequest` 在把结果暴露给 typed/raw 调用方之前，先登记 terminal winner/delivery right，再以 `promptEnded` 原因本地结算 owner-scoped admission/permission operation，并在有界 cleanup grace 内等待组合 barrier；总时限在 deadline 获胜的瞬间执行同一结算，显式取消使用已获胜的 `promptCancelled` 原因。typed prompt 和 raw prompt 的外层 `finally` 继续幂等请求 `endPromptTurn`，但不能绕过或提前移除组合 barrier/delivery right。超时、取消、session close 或 dispose 已使 lifecycle settling 时，迟到任务只能加入已有 settlement Future，不能发布 `TurnEnded`、error 或事件到下一轮。

### Session close 与活动 Prompt

每次 session new/load/resume 成功登记本地状态时都创建唯一 session generation token；同一 sessionId 以后重新登记会得到新 token。所有入站权限、文件和 terminal operation 在进入 Task36 队列前捕获该 token；handler 只能使用接纳快照，只有 manager 索引仍指向同一 token 时才能继续副作用。

`closeSession` 先同步登记 closing owner并使当前 session generation 失效，从而拒绝新 prompt 和其他 session mutation。它在等待 prompt 或远端 RPC 之前，立即遍历该 session 已接纳或运行中的 permission operation：完成各自 `sessionClosed` 本地 cancellation、发布交互 bridge invalidation，并按 token 通知可取消 provider。这样自定义、不可取消或永不返回的 provider 也不会无限占用 Task36 gate 或 terminal pending lease。它始终启动一个 `promptCancelGrace` cleanup 窗口来等待该 session 的 admissions barrier；若有活动或 settling prompt，再通过相同 owner operation 发送至多一次取消，并在同一个窗口内一并等待 prompt reap。宽限内全部结算后尝试 `session/close`；宽限结束导致 peer fatal、gate 逻辑脱离并完成替代终态时不再发送新的远端 close。

无论 prompt 收割、`session/close` RPC、普通 request deadline 或 transport 是否失败，本地 session 清理都必须在 `finally` 中执行：关闭 stream、清空 replay/workspace/provider/mode/tool-call/input-budget 状态、遍历该 session 的活动 cancellation token 并以 `sessionClosed` 原因精确取消可取消权限 provider，再通过 Task24 统一入口释放 terminal。清理成功后重新抛出原来的固定远端错误；若本地清理自身失败，抛出现有 `SessionCloseCleanupException`，只包含固定 stage 名，不附带远端 payload。closing owner 最后按 identity 释放。

`dispose` 继续先关闭 peer；peer 不可用通知会解除所有 prompt operation 和 owner，随后 `SessionManager.dispose` 完成 session/terminal/permission 本地清理。close、dispose、总时限和用户取消命中同一 operation 时，共享 cancel-once 和 reap Future。

## 权限请求生命周期

`SessionManager` 增加一个统一的权限 helper，以下四处都必须使用：

- `fs/read_text_file`
- `fs/write_text_file`
- `session/request_permission`
- `terminal/create`

peer 在这四类请求进入 Task36 队列前同步调用 manager admission hook。hook 只读取已解码请求中的 sessionId，捕获当时的 session generation、peer epoch 和 prompt owner/generation，并创建 `_InboundPermissionAdmission`。admission 立即挂入对应 session；存在 pending owner 时挂入该 owner lifecycle，存在 settling owner 时仍挂入旧 lifecycle 并继承其首个取消原因。它持有唯一 provider cancellation token、local cancellation Future、从接纳时开始的 permission deadline、reservation-release Future 和 response-commit Future。只有接纳时确实不存在 pending/settling lifecycle，快照才保持 ownerless；后续 handler 不得查询当前 owner并改绑新 lifecycle。malformed/unknown session 仍走既有固定协议错误，但 reservation 与 admission 必须精确释放一次。

handler 启动后把 admission 快照交给 helper。helper 不重新创建 token、timer、session generation 或 owner 归属，只消费快照，把 token 放入本地 `PermissionOptions` 后再等待 provider。若快照已被 `timedOut`、`promptEnded` 或 `promptCancelled` 本地结算，helper 不调用 provider，直接使用对应固定语义。正常等待竞争 provider Future、admission deadline、local cancellation 和 peer-unavailable；每条分支都先取得 operation 的一次性结算权。deadline 分支统一产生 `PermissionRequestTimeoutException`，并用 token 通知可取消 provider 使用 `timedOut` 原因，使 bridge 立即删除精确的 pending 并发布 timeout invalidation。prompt/session close、peer unavailable 和 dispose 分支使用各自固定取消原因。helper 在 `finally` 从运行中索引删除 operation、完成自己的 settled Future，并给 provider Future 的迟到成功或失败预先安装处理器，避免 zone 异常；owner lifecycle 上的 admission 只有在 reservation-release 与 response-commit 两个 Future 都完成后才移除。

provider 返回后以及每个后续 `await` 之后，fs read/write 与 terminal create 都必须再次验证捕获的 session generation、closing 状态和 peer epoch；任一失效都禁止开始下一个文件或进程副作用。时限结束后忽略任何迟到决定，并按入口使用固定语义：

- `session/request_permission` 对 `timedOut`、`promptEnded`、`promptCancelled` 和 `sessionClosed` 都返回协议级取消结果：`{"outcome":{"outcome":"cancelled"}}`。
- 文件和 terminal 权限门的 `timedOut` 由 RPC 边界映射为 `-32002 / Permission request timed out.`，无 `data`。
- 文件和 terminal 权限门的 `promptEnded`、`promptCancelled` 或 `sessionClosed` 由 RPC 边界映射为 `-32003 / Permission request cancelled.`，无 `data`。
- `connectionClosed` 和 `disposed` 在内部统一为固定 `AcpConnectionClosedException`；peer 已不可用时通常无法发送 wire response，但本地错误仍不得包含请求或 provider 内容。

manager helper 的超时保证 inbound handler 完成并释放 Task36 的 `InboundGateReservation`。terminal create 依靠 Task24 已有的租约 `finally` 精确回滚；permission 超时后不得调用 provider.create。

`_AcpPermissionBridge` 也使用同一 `permission` 时限管理自己的 Completer，但自身 timeout 必须抛出相同的 `PermissionRequestTimeoutException`，不能先降级为普通 cancelled。这样无论 bridge 计时器还是 manager 外层计时器先结算，`SessionManager` 都能稳定区分 timeout：`session/request_permission` 再映射为 cancelled，文件和 terminal 再映射为 `-32002`。

bridge 的每条 pending 记录持有 request id、lifecycleId、sessionId、manager cancellation token、Completer 和一次性 invalidation 状态，并同时按 request id 与 token 索引。timeout、session close、peer unavailable 或 dispose 使用同一个 reason-bearing first-wins 结算入口；获胜者在完成 pending 前发布一条 `AcpPermissionInvalidation`，再以 timeout 异常或 cancelled 决定结算 Completer。现有无原因 `cancelAll/cancelSession` 调用改为传入明确原因；迟到原因不能覆盖首因或再发事件。现有 `finally` 从两个索引删除记录。用户正常 respond 不发布 invalidation。迟到的 UI 选择只观察到未知或已结算 ID 并幂等忽略。

`_InteractivePermissionProvider` 实现 `CancellablePermissionProvider`，把 token 和原因原样转发给 bridge。bridge 对 `timedOut` 完成 `PermissionRequestTimeoutException`，对其他原因完成 cancelled decision，并映射成对应的 app invalidation reason。未知或已结算 token 幂等忽略。自定义 provider 不必实现取消接口；其无法取消的 Future 可以在外部继续运行，但 manager deadline 或 peer epoch 失效后，结果不再持有入站门禁或 terminal 租约，也不能产生响应或副作用。

`ChatController` 同时订阅 `permissionRequests` 和 `permissionInvalidations`。invalidation 仅在 request id、lifecycleId、sessionId 与当前 pending request 全部匹配时清空 `pendingPermissionRequest`、记录一次 system-cancelled audit、停止相关 review 状态并通知界面；迟到或针对旧 lifecycle 的 invalidation 被忽略。切换请求、手工响应、session close 和 controller dispose 都使旧 lifecycle 失效，不允许 timeout 事件清除新卡片。fake 与 unavailable client 提供同一 stream 契约，便于状态测试。

超时日志只记录固定类别，不记录 `PermissionOptions`、metadata、toolCall、路径或 provider 异常。非超时 provider 失败维持现有业务语义；全面错误脱敏在 Task26 处理。

## 入站接纳快照与响应提交屏障

`JsonRpcPeer` 的 decoded delivery context 为每个入站元素保留 method、合法 request id、arrival identity 和 `InboundGateReservation` 的对应关系；不保存额外 payload 副本。带 wire request id（包括显式 `null`）的入站请求在送入本地 `json_rpc_2` server channel 前，把 id 替换为 peer 生成的非敏感、本实例唯一 internal correlation id，并在 tracker 中保存 internal id、原 wire id、arrival identity 和 reservation 的对应关系。该 internal id 不离开本地 peer，也不与出站 client request id 共用命名空间。notification 没有 id，不创建 correlation tracker。

tracker 使用独立的 `correlationPendingItems` 与 `correlationPendingBytes` 预算，硬上限分别复用 `InboundGate.maxPendingItems` 和 `maxPendingBytes`，但计数不随 reservation release 提前归还。每个带 id 元素占一个 item，bytes 保守计入该元素接纳时已经计算的完整 canonical byteLength，从而覆盖原 wire id 与 tracker metadata。一个 decoded request batch 必须同步、原子地同时预留 gate 与 correlation 两份预算；任一不足都回滚另一份预留，并对整批走既有固定 capacity rejection。tracker 只在对应 response commit 或 peer close 替代终态后归还；delivery/编码失败也走同一个一次性归还入口。这样多个含永久 sibling 的 batch 不能在 reservation 已释放后无界积累 tracker。

四类权限门的注册回调取得 reservation 后、调用 `reservation.run` 进入 Task36 队列前，必须同步把已经转换为对象的 params 与 correlation identity 交给 `SessionManager` admission hook。hook 不执行 provider、文件或 terminal 副作用，也不包含 `await`，只创建上一节的 admission 快照并返回给 peer。对应 handler 签名同时接收 params 与 admission，不能只接收 params 后在运行时重新查询 owner。

params 不是对象、sessionId 缺失或 session 不存在时，peer 创建不挂入任何 prompt lifecycle 的 detached admission，并让 handler 产生既有固定协议错误；接纳阶段本身不得因强制转换抛错而遗留 reservation。session 存在但旧 owner 已 settling 时，admission 仍挂到旧 lifecycle 并继承其首个取消原因。接纳时确实没有 owner 的请求保持 ownerless；即使新 prompt 在其排队期间开始，也不得事后绑定新 owner。

peer 为每个 admission 跟踪两个只完成一次的阶段：

1. `reservationReleased`：`InboundGateReservation` 增加独立、只完成一次的 `released` Future，admission barrier 等它而不是等 handler 返回 Future。四类权限门使用 `run` 的可取消变体，把 admission 的 first-wins terminal Future 和“按 method/reason 合成固定 result 或 `RpcException`”的工厂一并交给 gate。reservation 仍为 reserved 或 queued 时，terminal 先获胜会原子地移除 waiter、释放 reservation并完成 `released`，再用工厂的 result/error 完成返回 Future，整个过程不取得 ordinary handler permit；permit 先获胜则 reservation 进入 running，gate 不再短路，helper 消费同一个已登记 terminal Future。正常成功或 handler error 仍先释放 reservation，再完成返回 Future。从未交给 `run` 的 detached/undelivered reservation 由 delivery cleanup 释放并完成 `released`。
2. `responseCommitted`：带 request id 的 handler 结果或固定错误到达 `_JsonEncodingSink.add` 时，sink adapter 按 internal correlation id 精确找到 tracker，在编码前把 id 恢复为原 wire id；批量响应逐元素恢复。只有底层 sink 的同步 `add` 成功接纳完整编码结果后，才逐 tracker 完成 response 阶段。重复 wire id、显式 `null` 和不同批次都由不同 internal id 区分，不能一次完成多个 admission。peer 自己生成的 parse/capacity 等已带 wire id 的直接错误必须走明确的 wire-response 写入口，绕过 internal-id 恢复，避免恶意 wire id 与本地 key 同值时误命中。notification 没有 response 阶段。若 peer 先关闭或 sink 拒绝写入，则以同一个 first-wins peer-close 终态完成该阶段并删除 tracker。

admission 的 settlement Future 必须同时等待适用的两个阶段。handler Future 或 queued short-circuit 已结算但 response 尚未提交时，旧 prompt 的组合 barrier 仍不解除。permit 授予、admission terminal 与 gate close 通过 reservation 状态原子竞争：queued short-circuit 获胜后 handler 永不启动；running 获胜后 short-circuit 工厂不得再完成 Future，由 helper 的一次性结算权决定结果。

gate close 对 reserved/queued reservation 沿用释放并完成固定 closed error；对 running reservation 执行逻辑 detach：立即从 gate 的 item/byte/active 计数移除、完成 `released` 并以固定 closed error 完成交给 `json_rpc_2` 的 waiter Future，但不宣称取消已经开始的第三方副作用。gate 必须继续消费实际 operation Future 的迟到 value/error；其最终 callback 看到 detached 状态时不得再次减计数、释放 reservation或完成 waiter。peer close 同时完成 response 的 peer-close 替代终态，因此 prompt barrier 不等待不可取消、永不返回的文件/terminal/provider Future。迟到 operation 仍受 session generation 与 peer epoch 校验，不能开始下一项副作用或发布结果。

`json_rpc_2.Server` 会用 `Future.wait` 等待一个 batch 的所有元素后一次写 response，因此即使权限元素已 queued short-circuit，同批另一个 handler 永不返回时也不能伪造单元素响应。该场景由 prompt cleanup grace 在到期后关闭 peer，以 reservation detach 与 response peer-close 替代终态解除 barrier；不拆分或改写 JSON-RPC batch 语义。

`_runInbound`、decoded-delivery cleanup、gate close、sink error 和 peer close 共用一次性完成入口，确保排队请求被取消、运行请求被 detach 或 delivery 被拒绝时不会泄漏 admission、waiter、correlation tracker 或预算。这个跟踪只证明本地 response 已交给出站 sink，不承诺远端已经收到。internal id 恢复测试必须证明 wire 上只出现原 id，且 tracker 与两份计数在 response 或 close 后归零。

任何带 response stage 的 admission，只要 `reservationReleased` 已完成而 `responseCommitted` 尚未完成，就立即启动统一 cleanup grace，不区分正常 selected/cancelled outcome、fs/terminal 成功或 deny、handler `RpcException`/其他 error，以及 `timedOut`、`promptEnded`、`promptCancelled`、`sessionClosed` 固定终态。owner-scoped admission 的窗口携带同一个 owner/generation，并成为该 lifecycle 的共享 cleanup；prompt terminal 稍后获胜时复用这个更早 deadline。若已有 owner prompt 或 session-close cleanup 窗口则复用较早 deadline；若 admission ownerless 则建立自己的单个窗口。prompt/session 本地终态先于 running reservation release 时，由外层 prompt/session cleanup 从终态获胜时立即计时，不能等 handler 返回后才开始。到期仍被 batch sibling 或不可取消 running operation 阻塞时以 `fatalTimeout` 关闭 peer并完成 response 替代终态。这保证 ownerless 的正常/错误结果和本地取消都不会永久悬挂，同时不拆分 batch。

response commit、peer close 或其他 settlement 解除 blocker 时，必须同步从 lifecycle 移除对应活动窗口；同 owner 仍有其他 blocker 时只保留它们的最早 deadline，全部解除时取消 timer 并清空共享窗口。后来才出现的 prompt terminal 必须获得新的完整 grace，不能复用已经完成、取消或过期的旧 deadline。timer callback 执行时还要按 blocker identity 复核仍 pending，过期 callback 不得关闭健康 peer。

## Peer 不可用与入站副作用失效

`JsonRpcPeer` 使用唯一、带原因的 unavailable 状态入口。原因枚举为 `fatalTimeout`、`transportClosed`、`explicitClose` 和 `disposed`；第一个成功设置状态的原因永久获胜，不允许后续 dispose 或 transport error 升级/覆盖。fatal、transport 和 explicit close 对权限层都映射为 `connectionClosed`，只有 `disposed` 首先获胜时映射为 `disposed`。`AcpClient.dispose` 必须显式调用带 `disposed` 原因的 close API；普通 `close()` 使用 `explicitClose`。

状态入口先同步设置 sink 不可写并只一次通知 lifecycle listener，再停止入站 admission、关闭并逻辑 detach gate、完成所有 correlation tracker 的 peer-close 替代终态，最后关闭底层 peer。sink adapter 在 unavailable 后丢弃 `json_rpc_2` 因 waiter 结算而尝试生成的响应，不得把 fixed closed error、stack 或 `data` 写到 wire。unavailable 通知内部同时携带可空的 cleanup owner/generation；manager 总是失效该 peer 的 update、permission、input phase 和 epoch，只有通知为同一 lifecycle 的 cleanup fatal 且 terminal winner 已先登记时，才保留那一个 delivery right。其他 unavailable cause 释放 right并用固定 connection-closed 终结相应 typed/raw stream。listener 注册是状态型而非瞬时事件：如果 peer 在 `SessionManager` 注册前已经 unavailable，注册调用立即同步回放已保存的原因和 cleanup identity；manager 仍通过 identity 保证只处理一次。listener 抛错不得阻止 peer close，也不得改变 first-wins 原因。`SessionManager` 维护一个只减不增的 peer epoch token。

每个可能产生副作用的入站 handler 在入口捕获当前 epoch，并在每个 `await` 之后、开始下一项文件访问或 terminal 创建之前重新校验 identity。统一权限 helper 还把 provider Future 与 peer-unavailable Future 竞争；peer 先失效时立即以固定 connection-closed 终态退出 handler 并释放 Task36 gate，不等待 provider deadline。peer 不可用时：

- epoch 立即失效，新入站 operation 不再开始。
- 所有 input/request budget phase 失效，pending terminal leases 被撤销。
- manager 遍历活动 token，让可取消权限 provider 逐项收到 `connectionClosed` 或 `disposed`；其他 provider Future 的迟到结果被 manager 丢弃。
- gate 中 running operation 的 waiter 与 reservation 已逻辑 detach；实际第三方 Future 的迟到 value/error 由 gate 消费，不改变已归零的 admission、gate 或 tracker 计数。
- 正在等待 permission 的 fs read/write 和 terminal create 在 permission 返回后不能调用文件或 terminal provider。
- 已经进入 terminal provider.create 的 late handle 尚未进入 managed-terminal 索引，必须沿用并抽取 Task24 的“未登记 handle 拒绝清理”helper，直接对该 handle 调用 `provider.release` 至多一次，不得误用只接受已登记 terminalId 的 `_releaseManagedTerminal`。release 抛错只记录固定失败类别；manager lease 仍由外层 `finally` 释放，且不得登记或发布 `TerminalCreated`。
- 已经开始且无法取消的第三方文件写 Future 允许完成，但 peer 失效后不得开始新的写入步骤，也不得把结果发送或登记到已关闭连接。

terminal release/kill 等纯清理操作可以继续完成已取得的本地所有权；它们不得重新启用 epoch。peer fatal 后必须通过新 `AcpClient`/`SessionManager` reconnect，旧实例没有恢复入口。

## 关闭与竞态不变量

- `_closeFuture` 是 peer 唯一关闭所有权；fatal timeout、transport error、显式 close 和 dispose 共用它。
- unavailable reason first-wins；listener 注册前已关闭时同步回放同一原因。peer unavailable listener 与 epoch 失效各处理一次；manager 对当时仍活动的每个 permission token 至多发送一次取消，且这些动作发生在新的入站副作用之前。
- 一个 request Future 只完成一次，一个 prompt cancel notification 最多发送一次。
- prompt 总时限和用户取消同时发生时，共用同一 prompt operation 和宽限计时器。
- 同一 session 的 prompt operation 未收割前，新 owner、新 typed prompt 和新 raw prompt 都被同一 reap barrier 拒绝。
- 旧 owner 下已经接纳但尚未取得 Task36 permit 的权限门也计入同一 barrier；handler 开始时只能消费 admission 快照，且 barrier 同时等待 reservation 释放与 response 提交或 peer-close 终态。
- 正常 response、远端 error、用户取消、prompt timeout 和 session close 都只启动一个 `promptCancelGrace` cleanup 窗口；到期仍有 prompt/admission 未结算时 fatal close，调用方已经获胜的 prompt 终态保持不变。
- 已登记的 prompt terminal winner 只有同 owner/generation cleanup fatal 可以跨 close 保留一次性 delivery right；typed/raw 投递后必定关流，外部 close/dispose、其他 owner close 和迟到终态不能复用该 right。
- gate close 对 running reservation 只执行逻辑 detach并消费迟到 operation，不假装撤销已开始的外部副作用；所有 gate 与 correlation 预算立即、只归还一次。
- batch 中其他元素阻止 response commit 时，cleanup grace 到期后的 peer-close 替代终态负责解除 admission barrier，不拆分 batch response。
- 任何带 response 的 permission handler 在 reservation 释放后若未 commit response，都启动或加入最早 cleanup grace；正常 value/error 与本地取消使用同一规则。
- response 在 deadline 前到达时取消后续超时动作；deadline 后、宽限内到达时只用于清除 pending，不改变 timeout 结果。
- response 在 peer 关闭后到达时被丢弃，不产生 zone 未处理异常。
- permission timeout、session close、peer unavailable 和 dispose 同时发生时，bridge pending、UI invalidation、入站门禁和 terminal 租约各自只释放一次；prompt owner 仅由 prompt/session 生命周期的 identity 机制清理，不由 permission helper 越权结束。
- permission timeout 的固定 response 在 cleanup grace 内提交后，同一 peer 的下一次权限请求必须可用；若 batch sibling 阻塞提交至 fatal close，则 reconnect 后可用。
- prompt 与 admissions 在 cleanup grace 内结算后，同一 peer 的下一轮必须可用；任一超出宽限则旧 peer fatal，必须 reconnect。
- session close 的远端阶段失败后，本地 session、permission 和 terminal 状态仍已清理。
- prompt 或普通请求导致 fatal close 后，只有显式 reconnect 才能开始下一轮。

## 错误与敏感信息边界

公开本地异常的 `toString()` 固定为：

```text
AcpRequestTimeoutException.toString() == 'ACP request timed out.'
AcpPromptTimeoutException.toString() == 'ACP prompt timed out.'
AcpConnectionClosedException.toString() == 'ACP connection closed.'
PermissionRequestTimeoutException.toString() == 'Permission request timed out.'
```

`toString()` 不包含类名前缀。异常对象不得保存 method、params、sessionId 或原始 error 作为可序列化字段。

权限 RPC 固定为：

```text
code: -32002
message: Permission request timed out.
data: absent

code: -32003
message: Permission request cancelled.
data: absent
```

本任务新增或重新映射的 timeout、fatal-close、prompt-cancel、permission-invalidation 路径中，本地错误、JSON-RPC error、日志和 `AgentEvent` 均不得包含测试注入的 prompt、tool、token、路径、远端 payload 或 provider stack canary。既有非超时日志与错误的全面治理仍属于 Task26。

## 测试设计

### `test/acp/acp_request_timeout_test.dart`

- `const AcpTimeouts()` 的五个默认值精确为 15 秒、60 秒、30 分钟、5 分钟和 2 秒。
- `AcpTimeouts` 的五个字段分别为零或负数时拒绝。
- 非法配置在 transport start 前失败；start 计数保持零。
- `DartAcpAgentClient` 的自定义 timeouts 同值传到 initialize、普通 request、typed/raw prompt、manager permission helper 和交互 bridge；包装层非法值在 transport 构造/启动前失败。
- initialize 无响应时按注入的短时限返回固定 request-timeout，peer 关闭一次。
- 普通 `sendRaw` 无响应时返回相同固定错误；所有并发 pending 都在 peer close 后结算。
- fatal 后新请求得到固定 connection-closed，不包含 method 或 params canary。
- deadline 前响应正常成功；计时器不再关闭 peer，下一请求成功。
- timeout 后迟到或重复响应不改变结果、不重复关闭、不产生 zone 异常。
- 显式 close/dispose 先于 deadline 时只结算一次，计时器不得再次触发 fatal close。
- typed prompt 总时限只发送一次 `session/cancel`。
- prompt 总时限获胜且同 owner 权限仍 pending 时，先以 `promptEnded` 发布一次 invalidation 并结算权限，再发送 cancel、等待宽限；即使宽限结束触发 fatal close，原因仍是 `promptEnded`，文件/terminal 精确返回 `-32003` 且无 `data`，provider 只取消一次。
- agent 在宽限内返回 prompt 终态时，第一轮固定超时、owner 被释放、同一 peer 第二轮成功。
- agent 在宽限后仍无响应时，peer 关闭一次、全部 pending 结算、迟到响应被丢弃。
- typed prompt stream cancel 与总时限并发时只发送一次取消，并按宽限收割。
- `sendRaw('session/prompt')` 固定拒绝；专用 raw API 的 stale owner 或其他 manager 签发的 owner 在写出 RPC 前拒绝，wire sessionId 只能取自已验证 owner。
- raw prompt 在 dispatch 前被取消时 prompt/cancel RPC 计数均为零，不创建 owner 或 reap barrier，cancel completion 只完成一次。
- 用户取消后立即开始同 session 新一轮时，在旧 operation 收割前得到固定 settling 错误；旧 update、permission 和 response 迟到都不进入新 owner。收割完成后新一轮成功，stale cancel 不能取消它。
- 旧 prompt RPC 已响应但同 owner 的 `session/request_permission`、fs 或 terminal permission 仍 pending 时，组合 barrier 先以 `promptEnded` 结算旧权限并释放 gate/租约，再允许新 owner；迟到 allow 和旧 update 不进入新轮。
- 用永不返回的 handler 占满 Task36 ordinary permits 后，把旧 prompt 的 `session/request_permission`、fs read、fs write 和 terminal create 分别接纳入队；旧 prompt response 或用户取消先到时，不释放任何 permit，queued short-circuit 也必须主动移除 waiter、释放 reservation 并提交对应 cancelled outcome/`-32003`，provider、文件和 terminal create 计数均为零。response 提交前新 prompt 保留 fixed settling，提交后 barrier 自动解除且新 prompt 成功；阻塞 handler 只在测试 `finally` 清理。
- permission deadline 从 admission 开始：ordinary permits 永不释放时，ownerless 与 owner-scoped 排队请求都按时主动短路，`session/request_permission` 返回 cancelled，fs/terminal 返回 `-32002`，gate 容量可复用。
- permit 授予与 `timedOut`、`promptEnded`、`promptCancelled` 或 `sessionClosed` 同时发生时，分别控制两种先后顺序：queued short-circuit 获胜则 handler 调用计数为零；running 获胜则 helper 消费同一 terminal；两种路径都只释放一次 reservation、只提交一次 response、只发布一次 invalidation。
- 一个 batch 同时包含已被 `promptEnded` 短路的权限请求和永不返回的 sibling handler 时，短路结果不能被拆成单独 response；单个 cleanup grace 到期后 peer fatal、gate 与 tracker 归零、barrier 解除，prompt 调用方仍得到已获胜的原成功/远端错误。同一 peer 后续固定 connection-closed，reconnect 后可用。
- ownerless permission 在 admission deadline 超时、同 batch sibling 永不返回时，复用单个 cleanup grace 后 fatal close；gate、admission 和 tracker 都解除，不能因没有 prompt owner 而永久悬挂。
- ownerless `session/request_permission` 正常 selected/cancelled，以及 fs/terminal 正常成功、deny、`RpcException` 和 handler error 分别与永不返回的 batch sibling 组合；reservation 释放后都启动一个 response cleanup grace，到期 fatal 且原 value/error 不写到 wire，tracker/gate 归零。
- permission 已允许且 fs/terminal provider operation 开始后永不返回时，正常 prompt response 只等待一个 cleanup grace；到期关闭 peer并逻辑 detach running reservation，prompt 调用方仍得到原结果。迟到 operation 的成功或错误被消费，不能登记 terminal、开始下一步副作用或产生第二个 response。
- typed 与 raw 分别覆盖正常 prompt success、远端 error，且同 owner admission 已进入永不返回的运行操作：cleanup grace 到期后同 owner fatal close，typed 精确发布一次对应 `TurnEnded`，或一次原 error 加一次 `TurnEnded(other)` 后 stream done；raw 精确发布一个 terminal event 或一个 error event 后 stream done。不得出现 connection-closed 覆盖、第二终态或迟到 update，旧 peer 后续不可用。
- transport close、普通 request fatal、explicit close 与 dispose 在 delivery claim 前获胜时，typed/raw 不创建或释放未 claim delivery right，使用固定 connection-closed 并结束 stream；其他 owner 的 cleanup fatal 也不能投递本轮缓存终态。
- external close 与 terminal delivery claim 分别控制两种先后：close 先赢只投递 connection-closed，claim 先赢只投递已缓存 terminal；两者都只关闭 stream 一次。
- 同 owner admission response grace 先到期并 fatal close、prompt response 后到时，即使 cleanup identity 相同也不能补签 delivery right；raw/typed 只得到 connection-closed，迟到 terminal 被丢弃。
- admission response 在 grace 内 commit 后撤销活动 blocker；后来 prompt terminal 使用新的完整 grace。已取消 timer 的迟到 callback 不得误关 peer。
- 上述排队请求在 gate/peer close 前从未启动时，admission、reservation、response-commit 替代终态和 barrier 都只结算一次，不遗留 owner；接纳时没有 owner 的请求也不会在新 prompt 开始后改绑。
- 用户取消使用 `promptCancelled` 精确结算 owner-scoped 权限；prompt RPC 宽限与权限 settlement 任一未完成时，新轮仍固定拒绝。
- `closeSession` 与活动 prompt、总时限、响应和用户取消竞态时共享一次 cancel/reap；远端 close 失败后本地 stream、owner、permission 和 terminal 仍清理。
- `closeSession` 在没有活动 prompt、但 ownerless fs/terminal admission 已运行且永不返回时也启动单个 cleanup grace；到期 fatal detach，完成本地 session/lease 清理且不发送新的远端 close。
- `_beginSessionClose` 在远端 close 永不响应前就取消本地 permission operation；non-cancellable provider 永不返回或迟到 allow 时，gate、UI 卡片和 terminal lease 立即释放，fs/terminal provider 调用计数为零。
- `session/request_permission` 超时精确返回 cancelled；迟到 provider 决定不产生第二个响应，下一权限请求可成功。
- 文件和 terminal 权限超时精确返回 `-32002`、固定 message、无 `data`。
- promptEnded、promptCancelled 和 sessionClosed 本地取消时，fs read、fs write 与 terminal create 都精确返回 `-32003 / Permission request cancelled.`、无 `data`；`session/request_permission` 精确返回 cancelled outcome。
- bridge 与 manager 的相同时限无论谁先触发都稳定归类为 timeout，不会降级为普通 deny/cancel。
- 同 session 两个并发权限请求使用不同 token；一个超时、session close 或迟到取消不误结算另一个。
- terminal permission timeout 后 provider create 计数为零，Task24 pending 租约可立即复用。
- permission timeout、session close 和 dispose 竞态只清理一次。
- 普通 request fatal close 与正在等待 permission 的 fs read/write、terminal create 竞态时，迟到 allow 不调用 provider；provider.create 已经开始时，late handle 被 release 且不登记。
- late terminal handle 的拒绝清理对成功、抛错和 close/dispose 竞态都只调用一次 `provider.release`；release 抛错时 manager lease 仍释放且无 `TerminalCreated`。
- peer 在构造与 SessionManager listener 注册之间同步关闭时，注册立即回放原因并使 epoch 失效。
- fatal timeout、transport close、explicit close 与 dispose 以可控顺序竞争时，首个 unavailable reason 永久获胜、listener/invalidation 只一次；只有 disposed 首先获胜才产生 disposed invalidation。

### `test/state/chat_controller_test.dart`

- timeout invalidation 只有在 request id、lifecycleId 和 sessionId 全匹配时清除当前权限卡片，并只记录一次 system-cancelled audit。
- 旧 lifecycle 的迟到 invalidation 不清除同 id 或同 session 的新 generation。
- promptEnded、promptCancelled、session close、connection close 和 dispose invalidation 清除对应卡片；正常 UI allow/deny/cancel 不依赖 invalidation，原审计来源保持不变。
- timeout invalidation 与 review agent 迟到结果、手工响应和 controller dispose 竞态时只结算一次、不报告幽灵错误。

### `test/acp/acp_permission_request_test.dart`

- `withGeneration` 和 audit copy 保留 lifecycleId；非空 lifecycleId 参与 bindingKey，但不改变 content fingerprint。
- 空 lifecycleId 兼容既有 fake 请求；`DartAcpAgentClient` 的真实请求和 invalidation 始终携带相同的非空唯一 lifecycleId。
- manager cancellation token 只以 identity 在 provider/bridge 内传递，不出现在 permission metadata、审计副本、JSON、日志或错误字符串中。

### `test/acp/inbound_gate_test.dart` 与 `test/acp/json_rpc_peer_inbound_gate_test.dart`

- 可取消 reservation 在 reserved、queued、running、gate close 四种状态分别验证 first-wins；只有 reserved/queued 能无 permit 短路，且 gate 先释放 reservation 再完成返回 Future。
- queued short-circuit 的 value 与 `RpcException` 都正确交给 `json_rpc_2`；running operation 不被 gate 重复完成。
- gate close 对 running reservation 立即完成独立 `released`、归还 item/byte/active 计数并以固定 closed error 完成 waiter；实际 operation 迟到 value/error 被消费且不二次减计数。
- internal correlation id 对单请求、批量、重复 wire id 和显式 `null` 都精确恢复原 id；wire 上不出现 internal id。
- handler/queued Future 已结算但 sink response 尚未提交时，独立 tracker/barrier 单测仍保持 settling；response commit 后解除。peer close 先获胜时使用替代终态并清空 tracker。
- parse/capacity 的直接 wire-response 入口不误命中与其 id 同值的 internal tracker。
- correlation item/byte 预算按 batch 原子预留；任一超限回滚 gate 与 tracker 预留并返回既有 capacity error。reservation 提前释放但 batch sibling 挂起时 tracker 预算仍占用，response/close 后两份计数只归零一次。

### `test/acp/acp_http_logical_timeout_test.dart`

- 本地 `HttpServer` 让 initialize 和 session/new 正常完成。
- `session/prompt` POST 返回空 body 的 HTTP 202。
- SSE 以明显快于 `sseIdleTimeout` 的频率持续发送注释心跳，但不发送匹配 prompt 响应。
- raw prompt 仍按逻辑总时限发送一次取消并结束，证明心跳不能无限续期。
- 若 agent 在取消后补发原 prompt 结果，第一轮仍为固定超时，底层 pending 被清除，同一连接第二轮成功。
- 若宽限期后仍无响应，连接进入 fatal；重新 connect 后下一轮成功。
- raw owner 和事件订阅均无残留。
- `AgentEvent` 错误文本和 metadata 不含 prompt、tool、token、路径、远端 payload 或 stack canary。

### 测试计时规则

- 单元测试注入 50–100 ms 逻辑时限，外层 watchdog 使用 2 秒。
- 必须先等待“请求已经发出”的 Completer，再开始断言超时结果；不得把 agent/server 启动时间混入 deadline 竞态。
- HTTP 心跳使用 10–20 ms，transport `sseIdleTimeout` 至少 1 秒。
- 不断言临界毫秒或微观任务顺序，只断言一次结算、一次取消、一次关闭、资源清理和后续可用性。
- 所有开放 stream、SSE response、Timer 和 pending Completer 必须在测试 `finally` 中关闭或完成，避免未处理异步错误和 CI 抖动。

### 回归范围

- `dart_acp_session_types_test.dart`
- `json_rpc_peer_inbound_gate_test.dart`
- `dart_acp_agent_client_test.dart`
- `streamable_http_acp_transport_test.dart`
- `terminal_provider_test.dart`
- Task24 的终端 lifecycle 测试

## 文件范围

生产代码：

- `third_party/dart_acp/lib/src/config.dart`
- `third_party/dart_acp/lib/src/providers/permission_provider.dart`
- `third_party/dart_acp/lib/src/rpc/inbound_gate.dart`
- `third_party/dart_acp/lib/src/rpc/peer.dart`
- `third_party/dart_acp/lib/src/session/session_manager.dart`
- `third_party/dart_acp/lib/src/acp_client.dart`
- `third_party/dart_acp/lib/dart_acp.dart`（导出四种公开异常及可取消权限 provider 接口）
- `lib/acp/acp_agent_client.dart`
- `lib/acp/acp_permission_request.dart`
- `lib/acp/dart_acp_agent_client.dart`
- `lib/acp/fake_agent_client.dart`
- `lib/acp/unavailable_acp_agent_client.dart`
- `lib/state/chat_controller.dart`

测试：

- `test/acp/acp_request_timeout_test.dart`
- `test/acp/acp_http_logical_timeout_test.dart`
- `test/acp/acp_permission_request_test.dart`
- `test/acp/inbound_gate_test.dart`
- `test/acp/json_rpc_peer_inbound_gate_test.dart`
- `test/acp/acp_client_inbound_gate_lifecycle_test.dart`
- `test/state/chat_controller_test.dart`

文档：

- `docs/superpowers/specs/2026-07-14-acp-logical-timeouts-design.md`
- `docs/superpowers/plans/2026-07-14-acp-logical-timeouts.md`

## 验收标准

- 所有必需红灯测试在旧实现稳定失败，并在实现后通过。
- typed、raw 和扩展 RPC 都经过统一 deadline，SSE 心跳不能绕过逻辑超时。
- 普通请求 fatal timeout 后 `json_rpc_2` 没有可继续增长的 pending；新请求稳定失败直至 reconnect。
- prompt 及其 admissions 在共享 cleanup grace 内结算时 peer 可复用；正常 response、远端 error、取消、总时限或 session close 后仍未结算时 peer 必须关闭，但调用方已经获胜的 prompt 终态不被 cleanup close 改写。
- typed/raw 的已获胜 prompt terminal 在同 lifecycle cleanup fatal 后仍各投递一次并关闭 stream；外部/其他 owner close 不得错误保留或投递该 terminal。
- 权限超时后 bridge、界面卡片、入站门禁和对应 terminal 租约均释放；response 正常提交时同一 peer 的下一权限请求可用，batch cleanup 导致 fatal 时 reconnect 后可用；prompt owner 仍严格服从 prompt/session 生命周期。
- prompt lifecycle 只有在其 RPC，以及 owner 下运行中或已接纳排队的权限请求全部结算、reservation 释放、response 提交或 peer-close 后才解除 barrier；旧权限迟到结果不能污染新轮。
- peer fatal 后 pending permission 和入站 epoch 立即失效，迟到 allow 不能启动新的文件访问或 terminal 进程。
- session close 会共享 prompt reap，并在远端失败后仍完成本地 session、permission 和 terminal 清理。
- timeout、response、close、dispose 和迟到结果的所有竞态满足一次性结算与清理不变量。
- correlation tracker 与 gate 各自受 item/byte 硬预算约束；batch、重复/null id、提前释放 reservation 和 peer close 都不会泄漏 tracker、waiter或计数。
- 本任务新增或映射的超时、关闭、取消和 invalidation 错误、日志及事件不含任何请求或 provider canary。
- 定向测试、全部相关 ACP 回归、整个项目静态分析、格式检查和 `git diff --check` 全部通过。
- 独立规格审查与独立代码质量审查均无未解决的 P0–P3 问题。
