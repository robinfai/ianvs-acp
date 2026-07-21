# 会话工作区绑定保护设计

日期：2026-07-15
状态：方案 A 与书面规格已批准

## 背景

全目录测试在 `AppShell rejects changed roots for the active session id` 停滞。最初的停滞来自控件测试在 Flutter 假时钟中、首次 `pump` 前直接等待 `ChatController.resumeSession`；改用真实异步边界后，测试进一步暴露了生产问题：AppShell 自动加载 session catalog 时，同 ID 的远端条目会覆盖当前会话的 `cwd`、`additionalDirectories` 和 `agentName`。用户随后从 Resume 对话框选择该远端条目时，冲突检查看到的已经是被覆盖后的工作区，因此不会再提示冲突。

只保护 `currentSession` 仍不完整。已经切到后台的会话保存在 `_sessionViewSnapshots` 中；目录若覆盖其侧栏记录，稍后 `_activateSessionViewSnapshot` 会以新工作区本地激活旧快照，不发起远端 resume。本地创建但尚未开始 prompt 的会话也可以免远端激活，必须保持相同绑定规则。

## 目标

- 同一控制器内，已经建立运行态绑定的 session ID 不得被目录刷新静默换到其他工作区。
- 已绑定范围包括当前会话、后台会话快照和本地创建但尚未开始 prompt 的会话。
- `cwd` 和 `additionalDirectories` 构成控制器内的工作区绑定；非空 `agentName` 是必须保持的控制器路由信息。空的附加目录列表是有效绑定，不表示缺失。
- 同 ID、不同工作区的直接 resume 在消费快照或改变本地状态前失败。
- AppShell 与 AcpClientApp 在展示工作区确认框前报告同一冲突，避免用户确认后才失败。
- 纯目录候选仍可随远端 refresh 更新工作区信息，不把首次目录结果永久冻结。
- 目录仍可刷新标题和更新时间，同时保持本地标题覆盖、归档、置顶、未读和快照信息。

## 非目标

- 不实现同一 session ID 的显式工作区重绑。
- 不在本任务中设计“丢弃旧快照后重新远端加载”的迁移流程。
- 不改变不同 session ID 之间的正常切换、工作区确认或远端 resume 行为。
- 不改变 ACP session catalog 的协议结构，也不把本地绑定信息写回远端。
- 不修改此前已批准的逻辑超时、权限、文件系统或 terminal 生命周期规则。

## 方案比较

### 方案 A：已建立绑定不可静默更换（采用）

控制器统一识别当前会话、后台快照和本地未启动会话。目录刷新保留这些会话的绑定信息；直接 resume 和 UI 入口都在改变状态前拒绝同 ID 的不同工作区。

优点是不会把旧消息、权限上下文或本地快照放进新的工作区，也能保持纯目录候选正常刷新。代价是用户不能直接把一个已绑定 ID 迁移到新工作区。

### 方案 B：允许显式重绑

用户确认后，控制器丢弃或隔离旧快照，清理旧权限和资源，再进行真实远端 resume，成功后建立新绑定。

该方案支持迁移，但需要新的失败回滚、快照处置和权限上下文设计，超出当前缺陷修复范围。

### 方案 C：只保护当前会话

改动最小，但后台快照与本地未启动会话仍能被目录刷新改绑，不能满足目标。

## 已绑定会话的判定

`ChatController` 增加私有查询 `_boundSessionWithId`，按 session ID 返回绑定来源，优先级固定为：

1. ID 相同的 `currentSession`；
2. `_sessionViewSnapshots[sessionId]?.session`；
3. 当 `_localUnstartedSessionIds` 包含该 ID 时，返回 `_sessionWithId(sessionId)`；
4. 其他情况返回 `null`，表示该记录只是目录或侧栏候选，尚无运行态绑定。

查询必须使用 trim 后的 ID 比较。它只读取状态，不消费快照、不删除本地未启动标记，也不通知监听器。

控制器同时提供只读公开方法 `hasBoundSessionWorkspaceConflict(AgentSession candidate)`，判断已经路由到本控制器的候选是否与既有绑定冲突。AppShell、AcpClientApp 和控制器自身使用同一方法，避免三处对“已绑定”的定义发生偏差。该方法不把纯目录 existing 记录视为绑定。

session ID 只在一个 agent/controller 命名空间内唯一；不同代理可以合法拥有相同 ID。因此 UI 不得仅按 ID 扫描所有控制器并把另一个代理的同名会话当作冲突。AppShell 聚合 Resume 目录时必须继续用产生该目录的 `controller.agentName` 覆盖远端 entry metadata 作为可信来源；AcpClientApp 对已绑定侧栏记录使用受保护的本地 `agentName`。选定目标控制器后才调用该控制器的冲突判断。外部 deep link 显式提供的代理名仍表示调用方选择的 agent 命名空间。

## 目录合并规则

`_mergeSessionCatalog` 先取得普通 existing 记录和可空的绑定来源，再按下表生成合并结果：

| 字段 | 已绑定记录 | 纯目录候选 |
| --- | --- | --- |
| `id` | 保留同一 ID | 使用目录 ID |
| `cwd` | 使用绑定来源 | 使用最新目录值 |
| `additionalDirectories` | 使用绑定来源，包括有效空列表 | 使用最新目录值 |
| `agentName` | 绑定来源的非空值优先；仅缺失时用目录值补齐 | 使用最新非空目录值，缺失时保留 existing |
| `createdAt` | 绑定来源优先，其次 existing | 首次使用目录更新时间或当前时间 |
| `title` | 使用最新目录标题 | 使用最新目录标题 |
| `updatedAt` | 目录非空值优先；目录缺失时保留 existing | 同左 |
| `titleOverride`、`initialEvents`、`pinned`、`archived`、`unread` | 保留 existing 本地值 | 保留 existing 本地值 |

绑定来源存在时，catalog 不能删除 `_localUnstartedSessionIds` 中的对应标记。纯目录候选本来不在该集合中，不需要额外删除。当前会话仍同步指向合并后的展示记录，但其工作区和代理归属保持不变。

`loadSessionCatalog` 继续返回原始远端 projects。Resume 对话框使用 `listResumableSessions` 返回的原始目录数据，因此仍能展示远端新的 roots；本地 `controller.sessions` 的绑定保护不会隐藏远端候选。

## Resume 与 UI 预检

`ChatController.resumeSession` 在开始 session operation、取得快照或改变会话、快照、权限或资源状态前执行统一预检：

1. 查找相同 ID 的已绑定会话。
2. 未显式传入 `cwd` 或附加目录时，使用既有绑定值作为请求值。
3. 请求 roots 与绑定 roots 不同时，允许只更新现有错误展示状态，设置固定错误 `sessionWorkspaceConflictMessage(sessionId)` 并返回；不得改变会话绑定或资源状态。
4. 当前会话且绑定相同时保持现有幂等返回。
5. 后台快照或本地未启动会话且绑定相同时，继续走既有本地激活路径。

冲突检查必须发生在 `_takeSessionViewSnapshot` 前。失败不能消费快照、移除本地未启动标记、切换 `currentSession`、发送远端 resume 或改变权限/资源归属。

AppShell 和 AcpClientApp 在处理 Resume 选择时，先从可信的代理来源确定目标控制器，再调用该控制器的公开冲突判断。命中后显示现有 `different workspace` SnackBar 并返回，不展示 `Review Session Workspace`，也不切换或创建代理控制器。下层 `resumeSession` 仍保留同样检查，覆盖 UI 外调用和竞态。

`agentName` 不加入跨控制器的 workspace 比较：双方非空但不同表示不同 agent 命名空间，不能只因 session ID 相同就互相冲突。绑定记录自己的非空 `agentName` 仍不得被同一控制器的 catalog metadata 改写；它为空时允许由可信的控制器/目录来源补齐。

## 错误与兼容性

- 继续使用现有固定消息：`Session <id> is already bound to a different workspace.`
- 不增加远端请求、异常正文或路径日志。
- 对不同 ID、未绑定候选和相同绑定，行为保持不变。
- 目录中缺失 `updatedAt` 时不清空本地已有时间。
- 既有非空 `agentName` 是控制器路由归属，冲突目录 metadata 不能覆盖；既有值为空时允许目录补齐。

## 测试规格

按 RED→GREEN 顺序覆盖：

1. **当前会话**：先 resume 到受信任 roots，再加载同 ID、不同 `cwd`/附加目录/agent 的目录；断言当前会话和侧栏条目保持绑定，标题与非空更新时间刷新，远端 resume 次数不增加。
2. **空附加目录**：已有绑定为 `[]`、目录返回非空列表；断言仍保持 `[]`，不能把空列表当缺失。
3. **后台快照**：resume A，再 resume B 使 A 进入快照；对 A 加载不同 roots 后，显式按新 roots resume A 必须失败，B 保持当前，快照未消费，远端 resume 次数不增加；随后按原绑定 resume A 应本地恢复。
4. **本地未启动会话**：创建无初始事件的 A，归档当前 A 以移除 current/普通快照但保留本地未启动标记，再加载不同 roots；新 roots resume 必须失败，原 roots resume 仍走本地激活且不调用远端 resume。测试必须释放归档快照租约。
5. **纯目录候选**：连续两次目录刷新同一未绑定 ID；第二次的 `cwd`、附加目录和 agent 可以更新，防止过度冻结。
6. **AppShell**：自动目录加载不能覆盖当前绑定；选择同 ID 新 roots 时显示冲突，不显示确认框，不再次远端 resume。
7. **AcpClientApp/后台代理**：非当前代理控制器中的已绑定会话也在确认前报告冲突，不创建新 client、不切换活动代理。
8. **跨代理同 ID**：两个代理拥有相同 session ID 时仍能分别显示和选择；不能因全局 ID 扫描产生假冲突。绑定控制器中的远端 agent metadata 变化不能把该记录路由到另一个代理。
9. 运行新增命名测试、完整 `chat_controller_test.dart`、`app_shell_test.dart`、相关 `acp_client_app_test.dart`，再恢复全目录单并发测试清单。

## 完成条件

- 所有三类已绑定会话都不能通过 catalog、直接调用或 UI 选择静默换 roots。
- 冲突失败不消费快照、不改变当前会话、不发远端 resume。
- 纯目录候选仍可刷新工作区和代理信息。
- 目录展示元数据更新与本地侧栏元数据保持规则有回归测试。
- 相关测试、静态分析、格式检查和独立代码评审全部通过。
