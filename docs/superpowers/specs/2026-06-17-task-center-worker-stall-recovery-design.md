# 任务中心 Worker 卡住恢复设计

日期：2026-06-17

## 背景

任务中心已经能把任务从 fast agent 分派给 work agent，并通过 `task_center_claim_work_task`、`task_center_record_execution_result` 和 `task_center_deliver_work_result` 记录执行与交付。当前问题是：任务进入 `In Progress` 且 owner 变成某个 worker 后，系统只知道“任务归 worker”，不知道 worker 是否真的在执行、是否等待权限、是否出错、是否失联。

这会导致任务卡在 worker agent 手里。用户在群聊里看不到明确的下一步，也不知道应该催 worker、换 worker、打回 fast agent，还是转 thinking agent 重新梳理。

本次设计目标是让任务中心拥有一套可观察、可恢复的 worker 执行机制。fast agent 负责调度和恢复，worker agent 负责执行和交付，human 可以在群聊里直接处理卡住状态。

## 范围

本次设计覆盖以下能力：

- worker 领取任务后创建可追踪的执行记录。
- worker 执行过程中可以持续上报心跳、进度和阻塞原因。
- 任务中心能识别 worker 卡住、失联、等待权限、目标不清、执行失败等状态。
- 群聊中出现可操作的卡住恢复卡片。
- fast agent 能重新接管卡住任务，并执行催办、换 worker、转 thinking、问 human、标记失败等恢复动作。
- Agents tab 能继续作为执行记录查看入口，显示 worker run 对应 session 的细节。

不做以下事情：

- 不实现复杂的全局任务调度器或优先级队列。
- 不自动终止 agent 进程。
- 不自动改写用户本地文件或回滚 worker 已做的代码改动。
- 不把 worker 心跳做成后台常驻系统服务；先在任务中心打开、群聊发送、agent API 调用、手动刷新时触发扫描。
- 不强制要求所有历史任务都有 worker run；历史任务按兼容规则展示。

## 核心设计

采用“执行租约”模型。worker 领取任务时，不只是把 owner 改成 worker，而是创建一个 `work_run`。这个 run 是 worker 对任务的临时执行租约。

任务卡片仍保留现有 `status` 和 `readiness`，但新增一个执行层：

- 任务状态回答“任务在看板哪一列”。
- readiness 回答“任务是否清晰、是否需要人、是否被阻塞”。
- owner 回答“当前由谁负责下一步”。
- work run 回答“worker 这次执行是否还活着，具体卡在哪里”。

当 worker 没有按约定更新 run，任务中心可以把任务从 worker 手里收回，交给 fast agent 重新调度。

## 数据模型

在 `TaskCenterTask` 上新增 `workRuns`，持久化到本地 JSON。

`TaskCenterWorkRun` 字段：

- `id`：本次执行记录 id。
- `task_id`：所属任务。
- `agent_name`：领取任务的 worker。
- `session_id`：对应 agent session，可为空；有值时 Agents tab 可直接定位对话。
- `state`：执行状态。
- `started_at`：开始时间。
- `last_heartbeat_at`：最后一次心跳或进度更新时间。
- `completed_at`：完成时间，可为空。
- `progress_summary`：给 human 和 fast agent 看的最新进度摘要。
- `blocker_reason`：当前阻塞原因。
- `next_check_at`：下一次建议扫描时间。
- `metadata`：保留扩展字段，例如 model、cwd、permission request id、失败次数。

`TaskCenterWorkRunState`：

- `claimed`：worker 已领取，还未上报开始执行。
- `running`：worker 正在执行。
- `waiting_permission`：worker 正在等权限或系统确认。
- `waiting_human`：worker 判断需要 human 补信息。
- `blocked`：worker 明确报告自己无法继续。
- `stale`：超过时限没有心跳。
- `failed`：worker 执行失败并放弃。
- `released`：worker 主动释放任务。
- `delivered`：worker 已交付结果。

兼容规则：

- 没有 `workRuns` 的历史任务照常显示。
- 如果任务是 `status = in_progress`、`owner = workAgent`，但没有 active run，任务中心把它识别为 `missing_run`，显示为需要恢复。

## 状态流转

正常路径：

1. fast agent 判断任务目标和验收标准清晰。
2. fast agent 调用 `task_center_start_work_run`，把任务交给 worker。
3. 任务进入 `status = in_progress`、`readiness = ready`、`owner = workAgent(agentName)`。
4. worker 执行时调用 `task_center_heartbeat_work_run` 更新进度。
5. worker 完成后调用 `task_center_deliver_work_result`。
6. 任务进入 `done` 或 `review`，work run 进入 `delivered`。

目标不清路径：

1. worker 领取后发现目标或验收条件不清。
2. worker 调用 `task_center_report_work_blocker`，原因类型为 `unclear_goal` 或 `missing_acceptance`。
3. 任务中心把任务 owner 改回 fast agent，readiness 改为 `needsInfo`。
4. fast agent 在群聊里说明已打回，并决定问 human 或转 thinking。

需要人工路径：

1. worker 确认缺少 human 判断。
2. worker 调用 `task_center_report_work_blocker`，原因类型为 `needs_human`，并给出问题。
3. 任务中心把 readiness 改为 `waitingHuman`，owner 改为 human。
4. 群聊显示 human 确认卡。

worker 失联路径：

1. active run 超过阈值没有心跳。
2. 任务中心把 run 标记为 `stale`。
3. 任务 owner 改回 fast agent，readiness 改为 `blocked`。
4. 群聊显示“Worker stalled”恢复卡。

## 卡住检测

任务中心在以下时机扫描 worker run：

- 打开 task center。
- 切换 workspace。
- workspace chat 收到 human 消息。
- agent API 对任务产生写入。
- 用户点击刷新或恢复卡片。

默认阈值：

- `claimed` 超过 2 分钟没有进入 `running`：提示 worker 未开始。
- `running` 超过 10 分钟没有 heartbeat：标记 stale。
- `waiting_permission` 超过 5 分钟：提示需要人工检查权限。
- `blocked`、`failed`、`released`：立即进入恢复队列。
- `in_progress + workAgent + no active run`：立即进入恢复队列。

阈值后续可以放进 workspace agent 配置，但第一版用固定值，避免配置膨胀。

## 群聊体验

Workspace Chat 是主工作区，所以恢复动作放在群聊，而不是要求用户去 Kanban 或 Agents tab 找按钮。

当存在卡住任务时，群聊顶部显示 `Worker stalled` 卡片。卡片内容：

- 任务标题。
- 当前 worker。
- 最近活动时间。
- 卡住原因。
- 最新进度摘要。
- 当前建议动作。

卡片动作：

- `催一下 worker`：fast agent 给原 worker 发送继续执行指令，并记录一次 retry。
- `换一个 worker`：从 workspace 配置的 worker 列表中选择另一个 worker，创建新 run。
- `交回 fast agent`：owner 改回 fast agent，fast agent 重新判断任务。
- `转 thinking agent`：owner 改为 thinking agent，readiness 改为 `needsThinking`。
- `补充信息`：human 直接输入说明，写入群聊并交给 fast agent。
- `标记失败`：任务进入 `review` 或 `blocked`，记录失败原因。

卡片不自动隐藏。只有任务产生新 active run、进入 waiting human、进入 review/done，或 human 手动标记处理后才消失。

## Kanban 体验

Kanban 卡片增加一个小型执行状态条：

- worker 名称。
- run state。
- 最近活动时间。
- stale/blocked 时显示警示色。

任务详情面板增加 `Execution` 区块：

- 当前 run 状态。
- worker session 链接。
- 心跳和进度历史。
- 失败、阻塞、释放记录。
- 手动恢复按钮。

这个区块只展示与任务相关的执行链路，详细对话仍在 Agents tab。

## Agents Tab 体验

Agents tab 继续按角色分组 session。新增联动：

- session tile 显示关联任务数量和当前 run state。
- 从任务详情点击 session，可以跳到 Agents tab 并选中该 session。
- 如果 worker run 有 `session_id`，优先用它定位对话。
- 如果没有 `session_id`，使用 agentName 和最近时间做弱关联，并提示“未绑定 session”。

## Agent API

新增工具：

### `task_center_start_work_run`

由 fast agent 或 worker 调用，创建执行 run。

参数：

- `workspace_id`
- `task_id`
- `agent_name`
- `session_id` 可选
- `progress_summary` 可选

效果：

- 任务进入 `in_progress`。
- owner 改为 `workAgent(agent_name)`。
- readiness 改为 `ready`。
- 新建 `work_run`，state 为 `claimed` 或 `running`。

### `task_center_heartbeat_work_run`

由 worker 周期调用。

参数：

- `workspace_id`
- `task_id`
- `run_id`
- `state`
- `progress_summary`
- `next_check_minutes` 可选

效果：

- 更新 `last_heartbeat_at`。
- 更新 run state 和摘要。
- 写入任务事件。

### `task_center_report_work_blocker`

由 worker 调用，说明无法继续。

参数：

- `workspace_id`
- `task_id`
- `run_id`
- `blocker_type`: `unclear_goal / missing_acceptance / needs_human / permission / tool_error / external_dependency / other`
- `blocker_reason`
- `questions` 可选

效果：

- run state 改为 `blocked`、`waiting_human` 或 `waiting_permission`。
- 根据 blocker type 调整 owner/readiness。
- 必要时创建 human questions。

### `task_center_release_work_task`

worker 主动释放任务。

参数：

- `workspace_id`
- `task_id`
- `run_id`
- `reason`

效果：

- run state 改为 `released`。
- owner 改回 fast agent。
- readiness 改为 `blocked` 或 `needsInfo`。

### `task_center_recover_stalled_task`

fast agent 或 human 操作触发。

参数：

- `workspace_id`
- `task_id`
- `action`: `nudge_worker / reassign_worker / return_to_fast / send_to_thinking / ask_human / mark_failed`
- `agent_name` 可选，新 worker 名称。
- `reason`

效果：

- 根据 action 更新任务 owner/readiness/status。
- 写入 workspace chat message 和 task event。

### `task_center_list_stalled_work`

fast agent 查询待恢复任务。

参数：

- `workspace_id`

效果：

- 返回 stale、blocked、failed、released、missing_run 的任务列表。

## Agent 提示词规则

fast agent：

- 每次处理 workspace chat 或任务分派前，必须查询 `task_center_list_stalled_work`。
- 发现 stalled work 后，不要只自然语言解释，必须调用恢复工具。
- 如果 worker 没有 heartbeat，优先恢复所有权到 fast agent。
- 只有目标和验收条件清晰时才分派 worker。

worker agent：

- 领取任务后必须调用 `task_center_start_work_run` 或确认已有 run。
- 执行中必须上报 heartbeat。
- 目标不清、验收不清、需要权限、需要 human 时，必须调用 blocker 工具。
- 不能沉默卡在任务里。
- 完成后必须调用 `task_center_deliver_work_result`。

thinking agent：

- 只负责梳理目标、风险、需要 human 判断的问题。
- 输出后把任务交回 fast agent 或 human，不直接交付执行结果。

## 错误处理

- 如果 heartbeat 指向不存在的 run，返回清晰错误，并提示 worker 先 start run。
- 如果 stale run 后又收到 heartbeat，保留事件，但不自动夺回 owner；由 fast agent 重新判断是否恢复给该 worker。
- 如果两个 worker 同时领取同一任务，只允许最新 active run 生效，旧 run 标为 `released`，并记录冲突事件。
- 如果 deliver result 来自非 active worker，记录结果但进入 review，不直接 done。
- 如果恢复动作失败，群聊卡片保留并显示失败原因。

## 持久化与迁移

本地 JSON 新增可选字段 `work_runs`。读取旧数据时默认为空列表。

迁移规则：

- 旧任务不补历史 run。
- 旧任务如果是 `in_progress + workAgent`，UI 显示为 `missing run`。
- 第一次扫描时，把 `missing run` 作为 stalled work 返回给 fast agent。

## 测试

模型和 store 测试：

- work run 可以序列化、反序列化。
- start run 会更新 owner、readiness、status。
- heartbeat 会更新 state、summary、last heartbeat。
- blocker 会按类型改 owner/readiness。
- stale 扫描能识别超时 run。
- 旧任务没有 work runs 时不崩溃。

Agent API 测试：

- 新工具 schema 和参数校验正确。
- worker deliver 非 active run 不会静默 done。
- recover action 分别产生正确任务事件和群聊消息。

UI 测试：

- 群聊出现 Worker stalled 卡片。
- 卡片动作会调用对应 controller/API。
- Kanban 卡片显示 run state 和最近活动。
- 任务详情 Execution 区块显示当前 run 和历史事件。
- Agents tab 能从 run session 定位对话。

端到端验收：

- fast agent 分派 worker 后，worker run 出现在任务详情。
- worker 心跳后，任务不被判定卡住。
- worker 超时后，群聊出现恢复卡片。
- human 点“换一个 worker”后，新 worker run 创建，旧 run 标 stale/released。
- worker 完成交付后，任务进入 done 或 review，卡片消失。

## 已确认选择

采用“执行租约 + 群聊恢复卡片”的保守方案。它直接解决 worker 卡住问题，同时保持现有 fast/thinking/work/human 分工，不引入复杂调度系统。

第一版实现重点是：work run 数据模型、worker 心跳和 blocker API、stale 扫描、群聊恢复卡片。后续再考虑 workspace 级阈值配置、自动周期扫描和更细的 worker 负载均衡。
