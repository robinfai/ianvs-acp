# Runtime 技术能力与产品成本评估

> 历史评估，基线 `322cc03`（2026-09-07）。后续包抽离与清理已改变文件位置和部分结论；执行结果见[清理验收](../cleanup-acceptance-2026-09-09.md)，现状见[产品能力](../product_capabilities.md)。文中行号及“当前”只指原基线，候选不等于待执行清单。

日期：2026-09-07
范围：`lib/acp`、`lib/config`、`lib/storage`、`lib/terminal`、`rust/crates/ianvs-acp-core`，以及相关测试和 runtime 文档。
方法：静态阅读当前工作区代码；本次未运行测试，因此“存在测试文件”只表示有验证意图，不代表测试当前通过。

## 结论

当前生产代码链路较完整、也最贴近本地项目任务的主链路是：本地 stdio ACP agent、会话创建/恢复/提示词、稳定 MCP 配置、人工优先的权限处理、受限文件系统与 agent 请求的 terminal provider，以及进程重启后的会话恢复。这条链路有明确的资源边界、失败回收和持久化设计，应该作为产品核心继续收敛。

当前产品说明和自检 UI 已经超过生产实现。生产 Rust 客户端没有 fork 命令；usage 与 ACP `session_info_update` 通知没有投影到 Dart；远程 ACP agent 和 MCP-over-ACP 虽能被配置模型解析，却会在启动时被拒绝；若干 ACP 1.2 experimental 能力只存在于 Dart 类型或说明文案，没有可调用的 Rust 命令。相反，slash command 和会话目录信息已经跨 FFI 并被 UI 使用，旧文档仍说它们没有消费者。这些不是细节差异，会直接影响用户对功能可用性的判断。

精简方向应先收回不真实的入口和文案，再验证高成本可选层的价值。assistant enhancer、AI permission reviewer、语义不稳定的 trust rule、模板叠加、供应商式 agent discovery 都会扩大配置与故障组合；它们不应与核心 runtime 享受同等产品承诺。精简时不能删除 workspace 边界、权限 fail-closed、进程和 terminal 回收、协议输入预算、密钥存储、会话所有权以及恢复数据库等基础保障。

## 功能评估

状态含义：**已实现**指当前生产路径存在完整调用链；**部分实现**指类型、UI 或单一路径存在，但生产能力有关键缺口；**未实现**指当前生产客户端没有对应命令或主动拒绝；**待验证价值**指技术存在，但没有从代码中看到足以支撑其持续复杂度的产品证据。

### 1. 本地 ACP runtime 与基础会话

**状态：已实现，核心能力。**

- 应用只为本地 stdio agent 创建 `RustAcpAgentClient`；缺少 server、非 stdio agent，以及含 `type: acp` 的 MCP 配置都会返回 unavailable，而不是进入半可用状态（`lib/app.dart:2695-2748`）。
- Rust 命令面覆盖进程启动、会话创建/恢复/列举/关闭/删除、认证、prompt、cancel、permission、mode、config 和 dispose（`rust/crates/ianvs-acp-core/src/model.rs:317-335`）。本地 agent 使用直接 executable + arguments 启动，没有拼接 shell 字符串；stdio 被管道化并设置 `kill_on_drop`（`rust/crates/ianvs-acp-core/src/runtime.rs:4903-4919`）。
- `SessionScopedAcpAgentClient` 负责共享 runtime 上的会话所有权、事件过滤和单会话取消（`lib/acp/session_scoped_agent_client.dart:1258-1315`）。这是多会话正确性的基础，不应为了减少文件数量而移除。

**成本与建议：** Rust runtime 文件已超过 5,700 行，Dart client、session scope、permission context 和 input budget 也各自很大。复杂度主要来自边界与恢复，不宜用重写换取表面简洁。后续应把新增协议能力保持为 typed command/event，并按会话生命周期拆分内部模块；产品范围先固定在本地 stdio 主链路。

### 2. Agent discovery

**状态：已实现本地启发式发现；生态发现未实现。**

- discovery 只检查本机命令并生成固定 adapter 配置，覆盖 Codex、Pi、Cursor 和 CodeBuddy 等候选（`lib/config/acp_agent_discovery.dart:42-133`）。搜索路径为 `$HOME/.local/bin`、Homebrew、`/usr/local/bin` 和 `PATH`，只检查文件存在，不验证 executable bit、版本、签名、兼容握手或来源可信度（`lib/config/acp_agent_discovery.dart:332-364`）。
- Pi 的候选需要同时发现 `npx` 和 `pi`，实际启动却是 `npx -y <package>`；本机 `pi` 检查只是门槛，不能证明 npm adapter 可运行（`lib/config/acp_agent_discovery.dart:42-133`）。
- 选中候选后的配置写入有同步、原子替换和 secret migration 保护（`lib/config/acp_agent_discovery.dart:136-221`）。ACP Registry 仍未接入；产品自检也把它列为缺失（`lib/ui/components/protocol_feature_review_dialog.dart:462-472`）。

**成本与建议：** 这是供应商名称、安装方式和包名驱动的维护面，每个 adapter 变化都可能导致静默失效。保留“快速发现”作为便利功能，但将结果标成未经验证，首次使用做握手；只有在实际采用率证明价值后再扩大供应商矩阵。不要删除原子写入和 secret migration。

### 3. 会话目录、恢复、prompt 与认证

**状态：已实现，核心能力。**

- Rust runtime 对会话目录做有界分页，并将 title、cwd、additional directories、metadata 等 `SessionInfo` 投影给 Dart（`rust/crates/ianvs-acp-core/src/runtime.rs:3748-3882`；`lib/acp/rust_acp_agent_client.dart:1117-1150`）。
- prompt、cancel、认证、mode/config 变更都有 typed command；会话关闭、删除及 runtime dispose 有明确入口（`rust/crates/ianvs-acp-core/src/model.rs:317-335`）。
- session scope 的租约和所有权避免一个 UI 会话消费另一个会话的事件或取消其请求（`lib/acp/session_scoped_agent_client.dart:1258-1315`）。

**成本与建议：** 保持为核心。优化目标应是减少重复的 Dart/Rust 映射代码，而不是弱化 typed ABI、会话所有权或取消语义。

### 4. Fork

**状态：生产未实现；Fake 和控制器流程存在。**

- `RustAcpAgentClient.forkSession` 明确返回 unsupported（`lib/acp/rust_acp_agent_client.dart:589-595`），Rust `CommandKind` 也没有 fork（`rust/crates/ianvs-acp-core/src/model.rs:317-335`）。
- controller 有完整 fork 工作流，并以 agent advertised capability 为条件（`lib/state/chat_controller.dart:4789-4870`）；Dart capabilities 能解析 `session.fork`（`lib/acp/acp_agent_capabilities.dart:151-190`）。
- Fake client 实现了 fork（`lib/acp/fake_agent_client.dart:415-438`），因此基于 Fake 的 UI/controller 测试不能证明生产 Rust 路径可用。

**成本与建议：** 当前属于“接口和演示支架”，不能作为已交付功能。先隐藏生产入口并修正文档；只有在 Rust 增加 typed fork command、结果映射、取消/恢复/持久化语义和真实 agent 验证后再发布。若近期没有路线图，可保留小型接口兼容层，但应删除误导性的“已完成”表述。

### 5. 稳定 MCP

**状态：已实现 stdio/HTTP/SSE 会话配置；主 runtime 将 server 配置交给 ACP agent。**

- Dart 配置支持 MCP server 校验、环境变量和 headers（`lib/config/acp_client_config.dart:1614-1846`）。应用把 stdio、HTTP、SSE 转为 Rust typed projection；`acp` 类型直接抛错（`lib/app.dart:69-92`）。
- Rust launch config 只定义 stdio、HTTP、SSE，并对数量、字符串和 headers 做预算校验（`rust/crates/ianvs-acp-core/src/model.rs:194-283`）。HTTP/SSE 是否传给 agent 还受 agent capabilities 约束（`rust/crates/ianvs-acp-core/src/runtime.rs:3962-4015`）。
- 这里的主 runtime 不自己成为 MCP client，而是把配置放入 ACP session setup。另一组自定义 MCP transport 服务于 permission-review sidecar：stdio transport 直接启动进程并限制输出（`lib/acp/bounded_mcp_stdio_transport.dart:25-31,90-118`）；HTTP transport 禁止 redirect 并限制响应（`lib/acp/no_redirect_mcp_http_transport.dart:10-14`）。

**成本与建议：** 稳定 MCP 是核心集成面，可以保留。文档应区分“传给 ACP agent 的 MCP server”与“应用直接调用的 reviewer MCP server”，避免把两套故障域混在一起。对 HTTP/SSE 的不可用应在保存配置时就基于 agent capability 提示。

### 6. MCP-over-ACP

**状态：配置可表达，生产主动拒绝。**

- `McpServerConfig` 的类型集合包含 `acp`（`lib/config/acp_client_config.dart:1725-1781,1952-1957`）。
- 只要选中的 MCP 集合含 `acp`，应用就把整个 agent runtime 标为 unavailable（`lib/app.dart:2712-2717`）；permission-review sidecar 也明确拒绝该类型（`lib/acp/acp_permission_reviewer.dart:698-716`）。

**成本与建议：** 这是典型的配置模型领先于执行能力。UI 应隐藏或标记为实验占位，避免用户得到一个可保存但无法启动的 recipe。若无近期实现计划，先停止新增围绕该类型的配置功能；保留解析兼容性可用于读取旧配置。

### 7. Slash commands / available commands

**状态：已实现并有 UI 消费；旧文档错误。**

- Rust 将 ACP `AvailableCommandsUpdate` 转成 `commands_changed` 控制事件，并在进入 Dart 前做数量和字符串预算（`rust/crates/ianvs-acp-core/src/runtime.rs:4457-4581`）。
- Dart client 解析、缓存并广播命令列表（`lib/acp/rust_acp_agent_client.dart:995-1042`），controller 在加载会话及实时事件时更新它（`lib/state/chat_controller.dart:7519-7548,8343-8360`）。
- prompt input 对 `/` 查询做搜索与选择（`lib/ui/components/prompt_input.dart:255-298`）。

**成本与建议：** 保留，这是低认知负担的原生 ACP 能力。修正 `docs/conversation_loading_architecture.md:52-61` 中“available-commands 没有 UI 消费者且不跨 FFI”的陈述。

### 8. Session info、usage 与 title

**状态：三者不能合并判断。目录 SessionInfo 已实现；实时 session-info 通知与生产 usage 投影缺失；title 有目录值和本地/assistant 生成链路。**

- 会话目录的 `SessionInfo` 已跨 FFI，并被用于 sidebar title、更新时间和会话元数据（`rust/crates/ianvs-acp-core/src/runtime.rs:3748-3882`；`lib/acp/rust_acp_agent_client.dart:1117-1150`）。
- controller 有实时 `session_info_update` 消费逻辑（`lib/state/chat_controller.dart:7445-7464`），但 Rust update projector 在已列举分支之外直接丢弃未知通知（`rust/crates/ianvs-acp-core/src/runtime.rs:4457-4579`），没有 session-info update 分支。
- controller 和当前 inspector 详情有 usage 消费与展示支架（`lib/state/chat_controller.dart:7466-7513`；`lib/ui/components/workspace_inspector.dart:729`）；旧 StatusBar 组件已无生产接线，但 Rust projector 没有 usage update 分支；prompt 完成事件只携带 stop reason/request id 等，不含 token usage（`rust/crates/ianvs-acp-core/src/runtime.rs:3276-3304`）。因此当前生产 Rust 路径不能据此显示 ACP token usage。
- 新会话先生成确定性的本地 fallback title，再由已启用的 assistant 可选替换（`lib/state/chat_controller.dart:3766-3799`）。目录返回的 agent title 也是独立来源。

**成本与建议：** 把旧文档的聚合结论拆开。`docs/conversation_loading_architecture.md:52-61` 对 available commands 和目录 SessionInfo 已滞后，但对 usage/实时 session-info notification 的生产缺口仍基本成立。产品 UI 应只在实际收到 usage 时展示，不应宣称“回合 token 用量已完整保留”。若该指标确有用户价值，再补 Rust typed projection 与真实 runtime 测试。

### 9. 三种权限策略

**状态：已实现；默认人工确认，安全边界合理。**

- 策略为 `defaultPermissions`、`autoReview`、`fullAccess`，并区分 agent、filesystem、terminal 等请求来源（`lib/acp/acp_permission_request.dart:33-43`）。默认值是 `defaultPermissions`（`lib/state/chat_controller.dart:2762-2764`）。
- 默认策略保留 pending；auto-review 先查 trust rule，再调用 reviewer；full access 自动选择允许选项（`lib/state/chat_controller.dart:5796-5823`）。任何自动结果仍只能选择 agent 本次给出的、匹配的单次 option（`lib/state/chat_controller.dart:5826-5855`）。
- Rust 在 prompt/session/connection 生命周期结束时会撤销 pending provider request，超时也会拒绝，而不是把未决请求遗留为隐式允许（`rust/crates/ianvs-acp-core/src/runtime.rs:3526-3575,3599-3608`）。

**成本与建议：** 保持人工确认为默认，并把 full access 做成显式会话级状态。精简 UI 时不能合并三种策略的语义，也不能绕过 agent 提供的 permission options。权限审计目前是有界内存记录而非持久审计（`lib/state/chat_controller.dart:6021-6052`），文案应明确这一点。

### 10. Trust rules 与 sidecar permission review

**状态：已实现，但 trust rule 的匹配标识不稳定；AI reviewer 属于待验证价值的高成本模块。**

- 配置可选择 MCP reviewer 或 agent reviewer，带模型、超时和 trust rules（`lib/config/acp_client_config.dart:702-907`；`lib/app.dart:2751-2798`）。
- reviewer agent 使用独立、受限的本地 stdio client，不获得 persistence、MCP、filesystem、terminal 或 additional directory 能力（`lib/app.dart:2817-2830`）。队列有界、调用超时，清理不完整时会 quarantine；失败返回“不知道”，不会隐式批准（`lib/acp/acp_permission_reviewer.dart:33-246`）。
- MCP reviewer 同样在失败时返回未知；即使 reviewer 可以批准，controller 也只自动批准恰好为 low risk 的请求，其他情况回到人工确认（`lib/acp/acp_permission_reviewer.dart:567-637,757-807`；`lib/state/chat_controller.dart:5901-5918`）。
- 当前 Rust permission projection 主要提供 `toolCallId`（`rust/crates/ianvs-acp-core/src/runtime.rs:4354-4412`），Dart 把它填入名为 `toolName` 的字段（`lib/acp/rust_acp_agent_client.dart:1243-1257`）。trust rule 又对 `toolName`/kind 做精确匹配（`lib/acp/acp_permission_request.dart:121-137`）。很多 agent 的 call id 是逐次生成的，terminal 也生成 `terminal:<approvalId>`，所以“按工具名信任”很可能不能稳定复用。

**成本与建议：** 在协议中建立稳定的 semantic tool key 之前，不扩大 trust rule 的产品承诺。保留 fail-closed、low-risk floor、受限 sidecar 和 quarantine；它们是可选 AI 判断层的必要安全条件。对 reviewer 的采用率、自动决策率、人工覆盖率、延迟和额外 token 成本做埋点，未证明收益前可把 AI reviewer 留在高级设置，而不是默认流程。

### 11. Assistant enhancer

**状态：已实现、默认关闭；子开关默认开启并不代表功能已启用。待验证价值。**

- 总开关 `enabled` 默认 `false`；`generateSessionTitles`、`summarizeTurns`、`collapseExecutionProcess` 默认 `true`，但只有 `enabled && agentName` 时才算 configured（`lib/config/assistant_agent_config.dart:1-26`）。因此不能把 `summarizeTurns: true` 解读为默认会调用 assistant。
- title 与 summary 都会新建临时 ACP session，串行执行、带 30 秒级超时，结束后关闭；如配置了模型还会额外设置 model（`lib/acp/assistant_agent_enhancer.dart:53-137,185-213`）。应用为它创建受限 runtime，不提供持久化、MCP、额外目录、filesystem 或 terminal（`lib/app.dart:2695-2748`）。
- title 有即时本地 fallback，因此 assistant 失败不会阻止会话命名（`lib/state/chat_controller.dart:3766-3799`）。每回合总结及折叠执行消息由 controller 触发（`lib/state/chat_controller.dart:8128-8161`）。

**成本与建议：** 打开后，每次 title 和每个完成回合都会增加 agent session、prompt、模型延迟和 token 成本，并与主 agent 的失败模式叠加。保留确定性本地 title；把 AI title 和 turn summary 作为一个可测量的实验包，避免多个默认为 true 的子开关造成配置误解。若采用率或阅读收益不足，优先移除逐回合 summary，而不是移除受限 runtime 和失败隔离。

### 12. Session templates 与模型参数

**状态：已实现，但应用是 best-effort，且模板不能收窄全局目录权限。**

- 模板包含 agent、mode、model、reasoning、additional directories、MCP、权限策略和 assistant；`mcpServerNames: null` 表示继承全部，空集合表示不启用（`lib/config/acp_client_config.dart:476-506`）。
- recipe 解析会把全局 additional directories 与模板目录取并集，再叠加权限和 assistant 配置（`lib/config/acp_client_config.dart:152-214`）。因此模板不能用来移除全局已授予目录，不能把它宣传成安全隔离 profile。
- 会话创建后才设置 mode/model/reasoning。model/reasoning 依赖 option id/label 的启发式分类；不支持或设置失败只产生 warning，会话仍继续（`lib/state/chat_controller.dart:3052-3230`；`lib/acp/acp_session_settings.dart:22-39,158-213`）。

**成本与建议：** 模板同时跨 agent、MCP、权限、assistant、模型和目录，组合测试成本很高。把安全范围与展示/模型默认值拆开：目录授权应在显式安全配置中管理，模板只引用它。UI 需要显示最终解析后的 recipe，并明确哪些 model/reasoning 设置未生效。若用户没有明显的重复配置行为，先减少模板编辑项，不要再增加推断式模型参数。

### 13. 持久化、恢复与 transcript cache

**状态：已实现，核心可靠性能力；默认存储额度值得收紧。**

- Rust session store 只持久化恢复所需的 agent/session/cwd/directories，并重新验证 workspace 范围；单 agent 最多保留 512 个活动会话（`rust/crates/ianvs-acp-core/src/session_persistence.rs:15-84,149-232`）。数据库使用受限路径、WAL、retention 和私有权限（`rust/crates/ianvs-acp-core/src/session_persistence.rs:103-130,340-395`）。
- agent 进程退出后，runtime 以退避策略重启并逐个恢复持久会话；单个恢复失败不会阻断其他会话，UI transcript 仍是 replay 的权威来源（`rust/crates/ianvs-acp-core/src/runtime.rs:1380-1467,2168-2235`）。
- transcript cache 只在配置 storage path 后启用，以 agent/session/cwd/directories/updatedAt 的精确 identity 判定命中；内容、条数和文件都有预算，写入使用 isolate 编码、原子替换和维护锁（`lib/storage/session_transcript_cache.dart:11-129,132-253,330-397`）。controller 仍把 ACP agent 当 canonical source（`lib/state/chat_controller.dart:3702-3704`）。
- SQLite 默认目录预算为 50 GB、保留 30 天（`lib/storage/sqlite_storage_config.dart:1-17`）。这对会话注册表和有界 transcript cache 偏大，容易让“有上限”等同于实际无感知增长。

**成本与建议：** 保留 registry、恢复、精确 revision/identity 校验和原子 cache；它们直接降低长会话重载及 agent crash 的损失。将默认 50 GB 调低到符合真实消息体量的额度，并提供当前占用和清理入口。不要把 UI 状态、恢复 registry 和 transcript cache 粗暴合并为同一种数据：三者的 canonical owner 和失效条件不同。

### 14. Agent-requested ACP terminal provider

**状态：已实现为受权限控制的回调 provider；当前主要投影为 timeline 状态。**

- terminal provider 是显式 opt-in，并有 handles、输出和时间预算（`rust/crates/ianvs-acp-core/src/model.rs:53-73`）。disabled 时 callback 返回 method-not-found；create 进入 permission pending，批准后才真正启动（`rust/crates/ianvs-acp-core/src/runtime.rs:1804-1945,3599-3608`）。
- manager 默认限制全局 16 个、每会话 4 个 handle，cwd 必须在 workspace roots 中；支持 output、wait、kill、release、close session，Drop 时杀死进程，并只保留有界尾部输出（`rust/crates/ianvs-acp-core/src/terminal.rs:31-43,205-374,478-502,566-567,633-651`）。
- terminal 状态被投影到对话 timeline，controller 合并 handle 生命周期（`rust/crates/ianvs-acp-core/src/runtime.rs:3673-3711`；`lib/state/chat_controller.dart:7515-7624`）。

**成本与建议：** 这是 agent 发起命令的安全执行面，不是普通终端窗口。即使产品不增加完整 viewport，也不能删除 permission、workspace cwd 校验、quota、kill/release 和 drop cleanup。

### 15. 用户打开的本地 terminal region

**状态：已实现当前会话内的交互面板；切换会话会释放，不能理解为跨会话或重启持久终端。与 ACP callback terminal 是两套生命周期。**

- `AcpSessionTerminalRegion` 使用 `TerminalRuntimeController.native`，按当前 ACP session 懒创建 panel，并在切换或关闭 session 时释放 tabs（`lib/terminal/acp_session_terminal_region.dart:20-44,210-219`）。
- 用户打开面板时，它按 session cwd 和 session id 创建默认本地 terminal tab（`lib/terminal/acp_session_terminal_region.dart:54-130`）。代码没有把该 tab 绑定到 Rust `TerminalManager` handle，也不经过 agent callback permission settlement。

**成本与建议：** 文档统一使用两个名称：**Agent-requested ACP terminal** 和 **user-opened workspace terminal**。前者由 agent 请求、逐次授权、handle 有 quota；后者由用户主动打开、tab 跟随 UI session。两者都应保留各自的回收边界。后续需要决定两类命令是否共享审计展示和工作区策略，但不能因为已有本地终端面板就删除 ACP terminal 的安全机制。

### 16. 远程 ACP、providers、NES 与 experimental surfaces

**状态：大多为类型或文案占位，生产未实现。**

- 配置可以解析非 stdio ACP server，但应用明确拒绝远程 agent（`lib/app.dart:2705-2710`）。
- Dart capability model 能表达 provider、NES、position encoding、auth terminal、elicitation 等字段（`lib/acp/acp_agent_capabilities.dart:3-83,193-262`），Rust `CapabilityProjection` 只包含稳定子集（`rust/crates/ianvs-acp-core/src/model.rs:337-364`；`rust/crates/ianvs-acp-core/src/runtime.rs:3932-3959`）。
- Rust command enum 没有 extension、experimental、provider 调用、NES document 或 elicitation 命令（`rust/crates/ianvs-acp-core/src/model.rs:317-335`）。因此仅凭 capability 类型和 UI 说明不能认定这些功能可用。

**成本与建议：** 收回 `protocol_feature_review_dialog` 中关于手动 extension、provider APIs、NES/document/elicitation、任意 JSON result 等“已完成”描述。没有 typed command、FFI projection、生产 client 和真实 agent 验证时，不应呈现为功能。远程 ACP 还涉及认证、网络信任、重连与 secret 边界，应在有明确用户场景后单独设计，而不是从现有配置 parser 推导为已支持。

## 高维护成本、产品价值待证的模块

| 模块 | 维护成本来源 | 当前价值判断 | 精简建议 |
| --- | --- | --- | --- |
| AI permission reviewer | 第二套 agent/MCP runtime、队列、超时、风险解析、quarantine、额外模型成本 | 安全设计谨慎，但采用率和节省人工次数未知 | 保留为高级实验；先测自动决策率、人工覆盖率、延迟、误判和 token 成本 |
| Trust rules | UI 规则、匹配器、权限上下文、跨 agent 标识语义 | `toolCallId` 被当作 `toolName`，复用价值存疑 | 先定义稳定 semantic key；此前不扩展规则维度 |
| Assistant enhancer | 每次 title/turn 的临时会话、模型配置、超时、额外 token | 默认关闭；本地 title 已可用，逐回合 summary 价值待证 | 优先验证或移除 turn summary；保留 fallback 和受限 sidecar |
| Session templates | 跨 agent/MCP/权限/目录/model/reasoning/assistant 的组合 | 对重复工作可能有用，但失败是 best-effort，目录还会与全局取并集 | 缩成常用 recipe；把安全 scope 与模板分离，展示最终解析结果 |
| Agent discovery | 供应商命令、npm adapter、PATH 差异和版本兼容 | 首次启动便利，但未做握手且易随外部变化 | 减少硬编码矩阵，发现后验证；按使用量维护 |
| 双 terminal 产品面 | 两套进程、生命周期、权限和 UI 心智模型 | 两者场景不同，但文档混淆会造成安全误解 | 统一术语和审计呈现，不合并底层生命周期 |
| Experimental capability/UI | Dart 类型、说明文案与生产 Rust 命令不一致 | 当前主要制造错误预期 | 隐藏未实现入口；有 typed end-to-end 路径后再开放 |
| 超大配置/迁移层 | config store、secret migrator、模板和兼容 schema 交织 | 已保护真实用户配置和密钥，但继续扩张成本高 | 冻结新 schema 分支，先清理无执行能力的 UI；迁移和 rollback 不可删除 |

## 不可误删的基础保障

精简产品功能时，以下代码可能看起来“复杂”，但承担的是正确性或安全边界：

1. **Rust typed command/event 与有界 FFI。** 协议消息在进入 UI 前有数量、字符串、metadata 和输出预算；不能退回无界 raw JSON 直通（`rust/crates/ianvs-acp-core/src/model.rs:317-364`；`rust/crates/ianvs-acp-core/src/runtime.rs:4457-4581,4704-4835,4933-4955`）。
2. **Session scope 所有权与取消。** 共享 agent runtime 时必须保留租约、事件过滤和 session-specific cancel（`lib/acp/session_scoped_agent_client.dart:1258-1315`）。
3. **Workspace 路径边界。** canonical roots、现有路径与创建路径的 symlink ancestor 校验、写入前重验和原子替换防止越界与 TOCTOU（`rust/crates/ianvs-acp-core/src/workspace.rs:18-116`；`rust/crates/ianvs-acp-core/src/filesystem.rs:175-231,350-439,628-651`）。
4. **权限 fail-closed。** timeout、取消、断线、会话关闭时必须拒绝或撤销 pending 请求；auto-review 的 low-risk floor 和 agent option 校验不能因减少点击而绕开（`rust/crates/ianvs-acp-core/src/runtime.rs:3526-3608`；`lib/state/chat_controller.dart:5826-5855,5901-5918`）。
5. **进程、terminal handle 与输出预算。** `kill_on_drop`、每会话 quota、bounded tail、kill/release/close cleanup 防止资源泄漏和内存增长（`rust/crates/ianvs-acp-core/src/runtime.rs:4903-4919`；`rust/crates/ianvs-acp-core/src/terminal.rs:282-374,478-502,566-567,633-651`）。
6. **密钥与配置迁移。** macOS Keychain 引用、受保护字段识别、原子配置写和 migration rollback 避免把 secret 降级为明文或丢失（`lib/config/macos_keychain_secret_store.dart:5-89`；`lib/config/secret_field_policy.dart:1-120`；`lib/config/acp_agent_discovery.dart:136-221`）。
7. **会话恢复与 cache identity。** 私有 SQLite、retention、逐会话隔离恢复、精确 updatedAt/目录 identity 和原子 cache 写入防止陈旧 transcript 冒充 agent 真值（`rust/crates/ianvs-acp-core/src/session_persistence.rs:103-232,340-395`；`lib/storage/session_transcript_cache.dart:22-89,209-253,330-397`）。
8. **辅助 agent 隔离。** reviewer/enhancer 不获得 filesystem、terminal、MCP 或持久化能力；失败、超时和清理异常回到人工或 fallback（`lib/app.dart:2695-2748,2817-2830`；`lib/acp/acp_permission_reviewer.dart:33-246`）。

## 旧文档与自检 UI 的滞后项

| 位置 | 当前说法/暗示 | 代码事实 | 建议修正 |
| --- | --- | --- | --- |
| `docs/conversation_loading_architecture.md:52-61` | available-commands、session-info、usage 都没有 UI 消费者且不跨 FFI | available commands 已跨 FFI 并驱动 slash UI；目录 SessionInfo 已跨 FFI；实时 session-info update 和 usage 仍未跨生产 Rust projector | 拆成三项陈述，注明目录信息与通知不是同一通道 |
| `docs/runtime_architecture.md:49-50` | fork 被列入 production session 能力 | Rust client 明确 unsupported，CommandKind 无 fork | 改为“Dart/Fake scaffolding，生产不可用” |
| `docs/product_capabilities.md:13` | fork 等被列为产品能力 | 同上 | 从已交付列表移除 |
| `docs/manual_followups.md` fork 段 | unstable fork 隐藏 | 与当前生产事实一致 | 保留并补充 Rust typed command 前置条件 |
| `docs/manual_followups.md` terminal 段 | runtime 完成，但持久 live panel 仍是后续决定 | 已有 `AcpSessionTerminalRegion` 本地交互面板；但它不是 ACP callback terminal viewport | 改为双 terminal 架构，分别说明 UI 与权限生命周期 |
| `lib/ui/components/protocol_feature_review_dialog.dart:205-237` | fork 和 end-turn token usage 已完成 | fork unsupported；usage 未从 Rust 投影 | 降级为缺失/部分实现 |
| `lib/ui/components/protocol_feature_review_dialog.dart:308-326` | persistent terminal panel 缺失 | 用户打开的本地 panel 已存在；ACP callback 仍以 timeline 为主 | 拆成两项，避免混称 |
| `lib/ui/components/protocol_feature_review_dialog.dart:398-440` | extension/provider/NES/document/elicitation 等 experimental surfaces 已完成 | Dart 有部分类型，Rust 无对应 command/projection | 从“已完成”移除，按真实 typed path 逐项恢复 |

## 测试证据的边界

仓库包含 Dart unit/widget 测试，以及 Rust core、FFI 和 e2e 测试。例如 runtime e2e 覆盖空闲进程重启、已有会话重启与部分恢复失败隔离（`rust/crates/ianvs-acp-core/tests/runtime_e2e.rs:735-1020`），Rust client 测试也记录 fork 为 unsupported。另一方面，fork、usage 和 session-info 的部分 controller/UI 测试依赖 `FakeAgentClient`；Fake 的 fork 实现不能替代生产 Rust 调用链（`lib/acp/fake_agent_client.dart:415-438`）。

本次按要求没有运行任何测试，所以上述内容只能证明代码中存在这些路径和测试意图，不能声称当前分支的测试通过、真实 agent 兼容或运行时行为已验证。

## 建议的收敛顺序

### P0：先让产品表面与生产事实一致

1. 修正上述四份文档和 `protocol_feature_review_dialog`：隐藏 fork、远程 ACP、MCP-over-ACP 与未投影 experimental 功能；把 slash command 标为已实现；把 usage 和实时 session-info notification 标为缺失。
2. 将两类 terminal 改用固定术语并分别说明启动者、权限、handle/tab 和释放时机。
3. 修正 permission context 的语义字段：不要把 `toolCallId` 命名或展示为 `toolName`；在稳定 key 可用前限制 trust rule 的承诺。
4. 把 50 GB 默认 storage budget 调整为可解释的量级，并在 UI 显示占用与清理结果。

### P1：围绕可靠本地 ACP 主链路做产品验证

1. 核心组合固定为本地 stdio、会话创建/恢复、slash commands、稳定 MCP、默认人工权限、opt-in filesystem/terminal provider 和 crash recovery。
2. 为 assistant、AI reviewer、templates 和 discovery 分别记录采用率、成功率、额外延迟、token 成本和用户撤销/覆盖行为；不要用“代码已存在”代替价值验证。
3. 收敛配置 UI：只展示当前 agent/runtime 能执行的选项，并在创建前展示最终 recipe、目录范围和继承来源。

### P2：有明确需求后补齐协议能力

1. fork 需要 Rust typed command、FFI、恢复/持久化语义和真实 agent e2e，再恢复入口。
2. usage 和实时 session-info update 需要 Rust projection、预算、Dart event 与真实生产测试，再更新产品承诺。
3. ACP Registry、远程 ACP、providers、NES、elicitation 和 MCP-over-ACP 应分别立项，不从配置 parser 或 capability 类型推断可用性。
