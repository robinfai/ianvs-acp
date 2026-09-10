# 配置项证据清单

> 改版前历史基线（2026-09-09）。下文入口、行号、缺口和建议描述设置重设计之前；完成情况见[当轮验收](acceptance.md)，后续尺寸调整见[macOS 设置验收](../macos-settings-refinement-2026-09-09/README.md)。当前字段作用和生效语义以[配置指南](../configuration.md)为准。

日期：2026-09-09
范围：`AcpClientConfig`、Agent/MCP 编辑器、Assistant、权限/reviewer、本地存储、会话模板、当前会话设置与 Independent LLM chat。本文保留改版前的源码盘点，作为设置重设计的历史输入。

2026-09-10 文档校准注（`b9297f5`）：原表将 `filesystem.allow_read_outside_workspace` 的配置/UI 含义直接写成运行时能力，证据不足。当时 Rust 仅接收 read/write 开关，所有读取仍受工作区根约束。随后 ABI v11 已接入显式越界读取策略，详见[配置指南](../configuration.md)和[兼容维护](../compatibility-maintenance.md)。保存晚到操作的延迟应用、模板权限按对象替换、权限历史的连接范围也以现行说明为准。

## 先区分五种作用域

| 作用域 | 当前真值与生命周期 | 典型配置 | 设计时必须表达的含义 |
| --- | --- | --- | --- |
| 应用默认 | `settings.json`；应用启动读取，Agent Configuration 主 Save 持久化后立即重载 controller，当前 live controller 会被 dispose，已有索引会话可能需要后续恢复 | 默认 Agent、全局 MCP、provider、权限、Assistant、storage、模板 | 既是以后创建/恢复连接使用的默认配方，也会在主 Save 时重建当前运行时；不能统一标成“下次启动生效”。证据：[`_replaceOwnedControllerConfiguration`](../../lib/app.dart#L1100-L1157) |
| Agent | `agent_servers.<name>`；随应用配置持久化 | transport、command/URL、env/header、每 Agent reviewer 覆盖 | 定义一个可复用连接配置；Agent 名称同时参与引用，稳定身份另由 `persistence_id` 保证 |
| 工作区 | 当前没有独立的 workspace settings 对象；工作区由 session `cwd` 聚合，UI 状态另存 `workspace_ui_state.json` | 新会话 cwd、session 记录的 additional directories、侧栏 pin/expand/hide | 不应把全局 `additional_directories` 误称为某个工作区设置；侧栏状态也不受 storage 策略管理 |
| 当前会话 | ACP Agent 返回的 session modes/config options；Controller 只保留当前运行状态 | model、reasoning effort、mode、Agent 自定义 option、composer 执行策略 | 修改会立即调用 Agent；不是修改应用默认，也没有写入 `settings.json` |
| 临时连接 | Widget/Client 内存，页面移除即释放 | Independent LLM endpoint/model/API key/image flag | 当前不是 ACP Agent 配置，也没有配置文件或 Keychain 持久化 |

证据：顶层字段定义见 [`AcpClientConfig`](../../lib/config/acp_client_config.dart#L14-L48)；工作区从 session cwd 聚合见 [`AppShell`](../../lib/ui/shell/app_shell.dart#L178-L204)；LLM 面板明确声明只驻留内存见 [`LlmChatPanel`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L5-L27)。

## 配置文件与应用级选择

| 字段/状态 | 真实作用与默认值 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `configPath` | 运行时来源信息，不写入 JSON。优先级：Dart define `ACP_CONFIG_PATH` → 环境变量 `ACP_CONFIG_PATH`/`IANVS_ACP_CONFIG` → `$XDG_CONFIG_HOME/ianvs-acp/settings.json` → `$HOME/.config/ianvs-acp/settings.json`；文件上限 4 MiB | 启动加载；Agent Configuration 顶部只读显示。路径不可解析或启动加载失败时 Save 不可用 | 自定义路径还决定本地状态目录和 Keychain secret ownership；放到“Advanced / Configuration file”，只读展示来源与状态。证据：[`resolveConfigPath`](../../lib/config/acp_client_config.dart#L422-L446)、[`_canSave`](../../lib/ui/components/agent_config_dialog.dart#L136-L140)、[bootstrap 失败降级](../../lib/startup/acp_client_bootstrap.dart#L121-L128) |
| `default_agent_server` | 启动默认 Agent；缺省时解析后的第一个 Agent 成为 active，但 `defaultAgentServerName` 仍为 null。引用未知名称会拒绝整个配置 | Agent Configuration 的 Agent 卡片 “Set Default”，统一 Save 后持久化；保存时也把所选默认项设为 `activeAgentServer` 并立即替换 controller | 与顶部 Agents 菜单的“当前 Agent”不同：菜单切换只改内存 active config，不保存默认；但保存默认又会切换/重建当前 runtime。目标放“General / Startup defaults”，明确提示这一即时副作用。证据：[`fromJson`](../../lib/config/acp_client_config.dart#L389-L418)、[菜单选择](../../lib/app.dart#L1409-L1421)、[保存时选择 active Agent](../../lib/ui/components/agent_config_dialog.dart#L311-L324)、[Set Default](../../lib/ui/components/agent_config_dialog.dart#L2867-L2900) |
| 当前 active Agent | `activeAgentServer` 是派生运行状态；没有 Agent 时 `agentName` 文案回退为 `Codex`，但 runtime 实际不可用 | Agents 菜单立即切换 controller，不写文件 | “Codex”回退标签不能呈现成已配置连接。目标只出现在全局导航/运行状态，不进入持久化表单。证据：[`agentName`](../../lib/config/acp_client_config.dart#L50-L58)、[无 Agent runtime](../../lib/app.dart#L2695-L2703) |
| `additional_directories` | 应用级额外根目录列表，默认空；必须是绝对路径，trim、去重。创建 session 时传给 Agent；模板目录在其上做集合并集 | Agent Configuration “Additional Directories”增删，统一 Save 后重建 runtime；Inspector 只读显示 | 名称没有说明这是“所有新会话的默认额外根”；还会扩大 filesystem/terminal jail 的允许范围。目标放“Workspace access / Default roots”，附作用域与安全提示。证据：[`_additionalDirectories`](../../lib/config/acp_client_config.dart#L2271-L2293)、[模板合并](../../lib/config/acp_client_config.dart#L177-L194)、[传入 session](../../lib/state/chat_controller.dart#L3057-L3062) |
| 启动 workspace cwd | 不在 `settings.json`。优先 Dart define/environment 的 `ACP_WORKSPACE_CWD`/`IANVS_ACP_WORKSPACE_CWD`，再当前目录、`PWD`、`HOME` | 作为新会话 cwd 初值；New Session 可选择另一个绝对路径 | 与 Agent process `cwd`、session cwd、additional directories 是三种不同概念。目标在 New Session 中叫“Session working directory”；启动来源仅放 Advanced diagnostics。证据：[`resolveWorkspaceCwd`](../../lib/config/acp_client_config.dart#L448-L473)、[New Session 校验](../../lib/ui/components/new_session_agent_dialog.dart#L141-L170) |

## Agent connections

| 字段 | 真实作用与默认/约束 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `agent_servers` / 名称 | JSON object 的 key 是显示名和大多数引用名；列表顺序影响无显式默认时选择 | Agent Configuration → Agents → Add/Edit/Delete；不能删除当前 active Agent；保存时整张列表持久化 | 重命名会影响 default、template、Assistant、reviewer 的名称引用。目标用“Connections / Agents”主列表，并在重命名时列出受影响引用。证据：[`fromJson`](../../lib/config/acp_client_config.dart#L344-L418)、[编辑操作](../../lib/ui/components/agent_config_dialog.dart#L1153-L1206) |
| `type` | parser 支持 local `custom`/`stdio` 及 `websocket`/`ws`/`http`/`https`/`sse`/`streamable_http` 别名；缺省为 `custom` | 新建 UI 只提供 `custom`、`stdio`；已有 remote 类型只读为 unavailable，仍可打开并保留 | production runtime 当前拒绝所有 remote ACP Agent。目标按“Local process / Remote (unavailable)”分型，禁止给人可连接错觉，仍须保留已有值。证据：[`AgentServerConfig` transport 解析](../../lib/config/acp_client_config.dart#L1122-L1265)、[编辑器选项](../../lib/ui/components/agent_config_dialog.dart#L1692-L1737)、[runtime gate](../../lib/app.dart#L2705-L2710) |
| local `command`, `cwd`, `args`, `env` | local 必须有 command；Agent process `cwd` 可空，否则必须绝对路径；args 默认空；env 默认空并覆盖启动环境 | Agent editor → Advanced settings；选择 preset 会填充这些字段；主 Save 后应用 | process cwd 只影响启动 Agent 进程，不是 session workspace。`PATH` 未显式覆盖时 runtime 会补常见 macOS CLI 路径。目标在 Agent detail 的“Launch”区。证据：[`AgentServerConfig` local 解析](../../lib/config/acp_client_config.dart#L1267-L1316)、[`AgentProcessEnvironment`](../../lib/platform/agent_process_environment.dart#L15-L71) |
| remote `url`, `headers` | WebSocket 要求 ws/wss，HTTP 系要求 http/https；必须有 host、禁止 URL userinfo；非 loopback 明文 http/ws 被拒 | 已有 remote Agent editor 展示 URL/headers但类型不可重新选择为 remote；保存仍能保留 | headers 可能含凭证；当前 runtime 不生效。目标在 disabled Remote 区显示“saved for compatibility”。证据：[`_ensureRemoteAgentUrl`](../../lib/config/acp_client_config.dart#L2210-L2226)、[`validateAcpEndpoint`](../../lib/acp/acp_endpoint_validator.dart#L20-L40) |
| `persistence_id`, `persistence_aliases` | 稳定的 session persistence namespace；未提供时由名称、连接配方、env/header key 和未知属性哈希生成；aliases 最多 64，且当前名称总被加入 | UI 不可编辑；读入/保存时规范化并持久化 | 不能在重设计中漏掉或重算为纯名称；否则旧 session 索引无法匹配。两个 Agent 不得共享 identity/canonical token，歧义 alias 会过滤。目标作为 Agent Advanced 的只读 identity/migration 信息。证据：[`persistenceIdentity`](../../lib/config/acp_client_config.dart#L1106-L1120)、[namespace 校验](../../lib/config/acp_client_config.dart#L1421-L1471)、[identity 生成](../../lib/config/acp_client_config.dart#L1562-L1598) |
| `env_refs`, `header_refs` 与 secret 状态 | JSON 仅保存 Keychain 引用；runtime 对象同时持有解析后的值。编辑器值字段遮挡；dirty key 用于判断用户是否重输 | 主 Save 才执行 secret prepare、原子配置写入、旧 secret 清理；失败可能“配置已提交但旧 Keychain 项清理失败” | 引用绑定 config identity/target，不能复制到另一配置或在 rename/target change 时盲目复用。目标统一用 Secret field 组件，显示来源、替换/删除意图。证据：[`toJson`/`toRuntimeJson`](../../lib/config/acp_client_config.dart#L1319-L1360)、[masked value](../../lib/ui/components/agent_config_dialog.dart#L2498-L2555)、[事务写入](../../lib/config/acp_config_store.dart#L29-L110) |
| `additionalProperties` | parser 保存所有未识别 Agent 字段，writer 与 editor 尽量透传 | 配置文件专属，UI 无法查看/编辑；Agent editor 从原对象带回未知字段 | 这是 forward compatibility 契约。重设计的结构化表单不能用重建对象的方式丢弃。目标在 Advanced 显示“additional config present”，必要时提供原始只读预览。证据：[`additionalProperties`](../../lib/config/acp_client_config.dart#L1154-L1157)、[editor 保留](../../lib/ui/components/agent_config_dialog.dart#L1866-L1889) |
| Agent 级 `review_agent` | 对全局 reviewer 做覆盖：有显式 target 才替换 target；`enabled` 用 OR 合并；tool/model/timeout 仅在偏离各自默认时覆盖 | 当前 Agent 卡片会显示 target/model，但 Agent editor没有 reviewer 控件，只会保留已有配置；实际是配置文件专属 | Agent 覆盖无法关闭全局 reviewer；“覆盖”不是完整 replace。目标放 Agent detail → Permission review override，并以继承/覆盖状态展示。证据：[`effectivePermissionConfig`](../../lib/config/acp_client_config.dart#L217-L227)、[`_mergedPermissionReviewAgent`](../../lib/config/acp_client_config.dart#L1976-L1997)、[卡片只读展示](../../lib/ui/components/agent_config_dialog.dart#L2931-L2941) |

## MCP connections

| 字段 | 真实作用与默认/约束 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `mcp_servers[].name` | 必填、trim 后全局唯一；模板和 reviewer 用名称引用 | Agent Configuration → MCP Servers → Add/Edit/Delete；主 Save 后进入新 runtime | rename/delete 可使模板/reviewer 无法解析，当前列表编辑没有依赖提示。目标“Connections / MCP”列表，删除前做引用检查。证据：[`_mcpServerList`](../../lib/config/acp_client_config.dart#L2248-L2268) |
| `type` | 支持 `stdio`、`http`、`sse`、`acp`；缺 type 时由是否有 URL 推断。stdio 用 command，HTTP/SSE 用 URL，acp 用 `serverId` | UI 可新建 stdio/http/sse；已有 acp 仅保留且标 unavailable | MCP HTTP/SSE 是经 local ACP session 传入的 MCP，并不代表 remote ACP Agent；`acp` transport production runtime 整体拒绝。目标按 transport 分表单并把能力状态置顶。证据：[`McpServerConfig.fromJson`](../../lib/config/acp_client_config.dart#L1725-L1846)、[MCP editor](../../lib/ui/components/agent_config_dialog.dart#L2115-L2228)、[runtime gate](../../lib/app.dart#L2712-L2717) |
| stdio `command`, `args`, `env` | command 必填；args/env 默认空 | MCP editor；env value 遮挡；主 Save 后生效 | MCP env 只有符合 secret policy 的键会要求 Keychain；Agent env 则全部按 secret 处理，不能假设两者完全同一规则。目标 detail → Launch/Environment。证据：[`McpServerConfig` validation](../../lib/config/acp_client_config.dart#L1783-L1823)、[`_containsUnreferencedSecrets`](../../lib/config/acp_config_store.dart#L384-L414) |
| remote `url`, `headers` | URL 必须 http/https，远程非 loopback 同样要求 TLS；header name/value 校验并按大小写去重 | MCP editor；主 Save 后随 Agent runtime 重建 | endpoint 禁止内嵌 credentials；header secrets 走 Keychain。目标 detail → Endpoint/Authentication。证据：[`_ensureHttpUrl`](../../lib/config/acp_client_config.dart#L2460-L2477)、[header validation](../../lib/config/acp_client_config.dart#L2228-L2245) |
| `env_refs`, `header_refs`, raw unknown fields | secret refs 与 Agent 相同地分离持久/运行表示；`raw` 还保留未识别 MCP 字段 | editor 排除自身管理字段后透传其余 raw；统一 Save | 不能将 MCP 配置压缩成 UI 当前显示的 name/type/target，否则 provider-specific 扩展丢失。目标 Advanced compatibility 区。证据：[`McpServerConfig.toJson`](../../lib/config/acp_client_config.dart#L1679-L1723)、[editor managed keys](../../lib/ui/components/agent_config_dialog.dart#L2247-L2323) |

## Client providers、权限和 reviewer

| 字段/状态 | 真实作用与默认 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `filesystem.read_text_file` | 是否把 client filesystem read provider 暴露给 Agent；默认 false | Agent Configuration → Client Providers → “FS read”；主 Save | 不是 Agent 自身文件能力，也不是 permission policy。目标“Capabilities / Filesystem”，用完整动作名称。证据：[`AcpFilesystemProviderConfig`](../../lib/config/acp_client_config.dart#L997-L1040)、[runtime wiring](../../lib/app.dart#L2737-L2745) |
| `filesystem.write_text_file` | 暴露 client filesystem write provider；默认 false | 同上，“FS write” | 高影响能力，当前只有短标签无范围说明。目标与 read 分开解释写入边界。证据同上 |
| `filesystem.allow_read_outside_workspace` | read provider 是否允许工作区根之外；默认 false | 同上，“Outside” | “Outside”没有说明只影响 read；workspace roots 还包含 session cwd/additional dirs。目标作为 read 的从属高级开关。证据：[`fromJson`](../../lib/config/acp_client_config.dart#L1017-L1030)、[当前 UI](../../lib/ui/components/agent_config_dialog.dart#L785-L807) |
| `terminal.enabled` | 暴露 client terminal provider；默认 false | Client Providers → “Terminal”；主 Save | 独立于界面中的 native terminal panel，也独立于 Agent 通过自己工具执行命令。目标“Capabilities / Terminal provider”。证据：[`AcpTerminalProviderConfig`](../../lib/config/acp_client_config.dart#L971-L995)、[runtime wiring](../../lib/app.dart#L2746-L2747) |
| `permissions.trust_rules[]` | 精确匹配 `tool_name`，可选精确 `tool_kind`；decision 仅 allow/deny；默认空 | Client Providers → Add Trust Rule/Delete；没有 Edit，只能删后重加；主 Save | 规则只有在 composer 选择“自动审查”时查询，默认权限模式不会自动套用。目标“Permissions / Automation rules”，说明触发策略和精确匹配。证据：[`matches`](../../packages/ianvs_agent_chat/lib/models/chat_permission_request.dart#L121-L137)、[策略分派](../../lib/state/chat_controller.dart#L5772-L5805)、[当前编辑器](../../lib/ui/components/agent_config_dialog.dart#L1415-L1511) |
| global `review_agent.enabled` | typed default false；若 JSON 出现 review_agent object 且未写 enabled，parser 默认 true | Client Providers → “Review agent”；主 Save | **当前 runtime 并未用 disabled 表示“没有 reviewer”**：只要 active Agent 存在，未启用/无目标时仍构造 active Agent sidecar reviewer。因此开关实际更像“是否启用显式 reviewer 配方”，文案误导。目标把“Use current Agent / Select Agent / Select MCP / Disabled”做成明确模式，并与 runtime 语义一同修正或如实解释。证据：[`fromJson`](../../lib/config/acp_client_config.dart#L805-L824)、[`_permissionReviewer`](../../lib/app.dart#L2751-L2798) |
| reviewer target | 三选一：inline `mcp_server`、`mcp_server_name`、`agent_server_name`；不能同时配置。无显式 target 时 runtime 回退 active Agent | UI 只输入 ACP Agent 名/MCP 名；inline MCP 只能保留旧值，不能创建；两者同时输入到最终主 Save 才报错 | 名称是自由文本而不是可校验 picker。模板禁止 inline MCP，并要求被选择 MCP 在模板 MCP 集合内。目标使用 discriminated selector，并即时显示依赖。证据：[`AcpPermissionReviewAgentConfig`](../../lib/config/acp_client_config.dart#L825-L883)、[UI 构造](../../lib/ui/components/agent_config_dialog.dart#L1074-L1095)、[模板限制](../../lib/config/acp_client_config.dart#L172-L213) |
| reviewer `tool_name` | MCP reviewer 调用的工具名，默认 `review_permission` | 自由文本 “Review tool”；主 Save | ACP Agent reviewer路径不使用该字段，当前表单却始终显示。目标只在 MCP target 时显示。证据：[`AcpPermissionReviewAgentConfig`](../../lib/config/acp_client_config.dart#L760-L777)、[`McpPermissionReviewAgent`](../../lib/acp/acp_permission_reviewer.dart#L567-L625) |
| reviewer `model` | sidecar reviewer model override；空时 Agent reviewer收到当前主 session model，MCP reviewer由其配置/调用参数决定 | 自由文本 “Review model”；主 Save | 与 Assistant model、session model、template model、LLM model同名不同作用域。目标字段名“Reviewer model override”。证据：[review 调用传 current model](../../lib/state/chat_controller.dart#L5863-L5875)、[Agent model override](../../lib/acp/acp_permission_reviewer.dart#L86-L98) |
| reviewer `timeout_ms` | 正整数，默认 10,000 ms | 空输入表示默认；主 Save | 与 Assistant timeout 和 LLM request timeout不同；没有上限。目标 reviewer Advanced。证据：[`fromJson`](../../lib/config/acp_client_config.dart#L866-L882)、[UI validation](../../lib/ui/components/agent_config_dialog.dart#L1098-L1107) |
| composer execution policy | `defaultPermissions`（默认：逐次确认）、`autoReview`（先 trust rule，再 reviewer）、`fullAccess`（自动 allow） | Prompt composer 菜单，立即改变当前 `ChatController` 内存；不写配置文件；新 controller 重置默认 | 它是实际决定请求如何处理的运行开关，却与静态 rules/reviewer 放在不同入口。`fullAccess`绕过 reviewer。目标保留在 composer，但链接到 Permissions 设置，并明确“this connection/session runtime”。证据：[`toolCallExecutionPolicy`](../../lib/state/chat_controller.dart#L2746-L2748)、[composer labels](../../packages/ianvs_agent_chat/lib/ui/components/prompt_input.dart#L3618-L3635)、[policy implementation](../../lib/state/chat_controller.dart#L5779-L5805) |

## Assistant Agent

| 字段 | 真实作用与默认 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `enabled`, `agent` | enabled 默认 false；只有 `enabled && agentName` 才 configured。选定已配置 Agent作为独立 helper | Agent Configuration → Assistant Agent；可加载 model 并“Validate configuration”；主 Save | Assistant 与当前聊天 Agent、permission reviewer 是三类角色。目标独立“Assistant automation”，首行显示使用目的和选中的 connection。证据：[`AssistantAgentConfig`](../../lib/config/assistant_agent_config.dart#L1-L26)、[当前 UI](../../lib/ui/components/agent_config_dialog.dart#L424-L494) |
| `model` | 可选 helper model；空表示 Agent 默认。UI 通过临时 ACP session发现 choices，配置值不在 choices 中仍保留显示 | dropdown 选择；Validate 会要求 model 确实匹配；主 Save | model discovery/validate 都会建立临时 Agent连接，可能触发 auth/耗时，不只是本地表单校验。目标在字段旁区分“Load models”“Test connection”。证据：[`_loadAssistantAgentModels`](../../lib/ui/components/agent_config_dialog.dart#L636-L775)、[runtime validate](../../lib/acp/assistant_agent_enhancer.dart#L144-L213) |
| `generate_session_titles` | 默认 true，但总开关默认 off，故默认不会调用 helper。首条 prompt先产生 fallback title，helper成功后替换 | “Smart session titles”；主 Save，对之后 controller 行为生效 | 当前说明“Without an assistant”不精确：fallback 总会先写入；helper失败则保留。目标“Generated titles”附 fallback 行为。证据：[`_applyFallbackSessionTitle`](../../lib/state/chat_controller.dart#L3749-L3759)、[`_scheduleAssistantSessionTitle`](../../lib/state/chat_controller.dart#L3762-L3782) |
| `fallback_title_characters` | 默认 24，范围 8–128；控制本地首 prompt fallback title长度，与 helper 返回标题的 64 字符上限不同 | “Characters”字段；主 Save | 当前布局让它看起来从属于 smart titles，但即使 Assistant off 仍用于 fallback。目标移到“Fallback title”从属说明。证据：[`AssistantAgentConfig`](../../lib/config/assistant_agent_config.dart#L9-L23)、[controller fallback](../../lib/state/chat_controller.dart#L3749-L3753) |
| `summarize_turns` | 默认 true但受总开关约束；完成 turn 后把 prompt和完整 turn transcript发给 helper，生成最多约 900 字符摘要 | “Completed turn summaries”；主 Save | 会产生额外模型调用并传递 turn 内容。目标“Turn summaries”，明确数据流、成本和失败降级。证据：[`summarizeTurn`](../../lib/acp/assistant_agent_enhancer.dart#L70-L85)、[调度](../../lib/state/chat_controller.dart#L8111-L8144) |
| `collapse_execution_process` | 默认 true；仅当 summary 成功插入时控制原执行过程是否默认折叠 | “Collapse execution process by default”，summarize off 时禁用；主 Save | 这是呈现偏好，却被放在模型自动化配置且依赖总结结果。目标置于 Turn summaries 的 presentation 子项。证据：[`_scheduleAssistantTurnSummary`](../../lib/state/chat_controller.dart#L8133-L8143) |
| `timeout_ms` | 默认 30,000 ms；控制 helper 队列任务、model discovery/validation外层等待 | 当前 UI 不显示也不能改；主 Save会原样保留旧值 | 配置文件专属，不能在重建表单时回落默认覆盖。目标 Assistant Advanced。证据：[`AssistantAgentConfig.fromJson`](../../lib/config/assistant_agent_config.dart#L74-L99)、[UI 保留](../../lib/ui/components/agent_config_dialog.dart#L1014-L1023) |
| restricted helper runtime | helper 不使用 session store、MCP、additional dirs、filesystem、terminal；每次 title/summary建临时 session并关闭 | 无独立 UI；Assistant 区有说明 | “read-only”是应用构造出来的限制，不代表所选 Agent配置本身只读；helper仍接收 prompt/turn文本。目标安全说明必须写具体可见数据和禁用能力。证据：[`_defaultAgentClient`](../../lib/app.dart#L2726-L2747)、[helper session lifecycle](../../lib/acp/assistant_agent_enhancer.dart#L108-L136) |

## Local recovery storage 与 Workspace UI state

| 字段/存储 | 真实作用与默认 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `storage.max_size_gb` | 默认 50，合法 1–8192；分别作为 ACP session registry 和整个 transcript cache directory 的上限，不是二者共享 50 GB | Agent Configuration → Local Recovery Storage → “Per-store limit”；主 Save 后新 runtime/cache采用 | 50 GB 是每 store，潜在合计约 100 GB；当前 UI不显示已用空间。目标“Data & Recovery”，显示两类 store 和实际占用。证据：[`SqliteStorageConfig`](../../lib/storage/sqlite_storage_config.dart#L1-L40)、[runtime wiring](../../lib/app.dart#L918-L927)、[Rust store wiring](../../lib/app.dart#L2726-L2730) |
| `storage.retention_days` | 默认 30，合法 1–3650；registry初始化/更新时维护，transcript读取/写后维护 | 同区 “Per-store retention”；主 Save | 同一值由两种维护时机实现，不是定时立即清理。目标逐 store 解释何时清理。证据：[`sqlite_storage.md`](../sqlite_storage.md#L14-L20) |
| ACP session registry | `acp_sessions.sqlite3`；保存 Agent/session恢复所需元数据，不存 prompt全文 | 无直接设置入口，仅受上述两字段控制 | 不要与 agent canonical history 或 transcript cache 合并成一个含糊的“history”。目标 Data inventory 子卡。证据：[`sqlite_storage.md`](../sqlite_storage.md#L5-L20) |
| transcript cache | `session_transcripts/*.transcript.json`；精确 agent/session/cwd/additional dirs/updatedAt identity，单文件另限 48 MiB/2000 messages | configPath缺失时完全关闭；受上述两字段控制 | 含重建后的消息和工具元数据；只在 identity精确匹配时命中。目标 Data inventory 子卡。证据：[`resolveSessionTranscriptCacheDirectoryPath`](../../lib/storage/session_transcript_cache.dart#L11-L20)、[`FileSessionTranscriptCache`](../../lib/storage/session_transcript_cache.dart#L109-L129) |
| `workspace_ui_state.json` | 保存侧栏工作区偏好和本地 session index，包括模板 id/version等；没有容量/保留期设置 | 随侧栏/session状态原子写入；不在 Agent Configuration | **不受** `storage.max_size_gb` / `retention_days` 管理，条目随 UI 状态变化才更新/删除。目标 Data inventory 单列，避免暗示现有 storage字段覆盖全部本地数据。证据：[`sqlite_storage.md`](../sqlite_storage.md#L22-L49) |

## Session templates

| 字段 | 真实作用与默认/继承 | 保存、生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| `session_templates.<id>`、`name`, `version`, `description` | id 必须非空且唯一；name 默认 id；version 默认 1且必须正整数；description可空。identity 是 `id@version` | **仅配置文件可编辑**；Agent Configuration把整个列表原样带回；New Session展示名称、描述/简要字段和版本 | id/version写入 session index，用于恢复时检测缺失或 drift。后续候选可在“Session defaults / Templates”提供完整 CRUD，version改变需明确迁移含义；本轮不据此承诺新增管理系统。证据：[`SessionTemplateConfig`](../../lib/config/acp_client_config.dart#L476-L508)、[解析](../../lib/config/acp_client_config.dart#L510-L586)、[UI 只传回](../../lib/ui/components/agent_config_dialog.dart#L319-L332) |
| `default_session_template` | 可空；非空必须引用现有 id | 配置文件专属；New Session打开时预选，用户仍可选 Custom | 这是“新会话弹窗默认配方”，不是默认 Agent的别名。目标 General → New session default，并链接 template。证据：[`_validateDefaultSessionTemplate`](../../lib/config/acp_client_config.dart#L647-L655)、[预选逻辑](../../lib/ui/components/new_session_agent_dialog.dart#L141-L149) |
| `agent_server` | 可空；空则继承当前/基础 active Agent | 配置文件专属；选择 template 创建新 session时解析 | 必须引用已配置 Agent；重命名 Agent 会破坏模板。目标 template → Runtime connection picker。证据：[`forSessionTemplate`](../../lib/config/acp_client_config.dart#L152-L159) |
| `mcp_servers` | `null`（字段省略）=继承所有全局 MCP；空数组=选择 none；非空=严格按名称和顺序选择 | 配置文件专属；创建 template session前解析 | null 与 empty 语义不能被普通多选控件抹平；reviewer引用的 MCP也必须包含。目标三态“inherit all / none / selected”。证据：[`mcpServerNames`](../../lib/config/acp_client_config.dart#L503-L505)、[`forSessionTemplate`](../../lib/config/acp_client_config.dart#L160-L175) |
| `additional_directories` | 默认空，但应用时与全局 additional directories并集，不是替换 | 配置文件专属 | UI 需显示 inherited + added 的结果，避免用户以为模板能收窄全局访问范围。目标 template → Workspace access additions。证据：[`forSessionTemplate`](../../lib/config/acp_client_config.dart#L177-L180) |
| `permissions` | 可空时继承全局；存在时**整体替换全局 permission config**，之后仍会合并 active Agent 的 reviewer override | 配置文件专属 | template写一个 reviewer可能同时把全局 trust rules清空；模板禁止 inline MCP reviewer。目标提供“Inherit/Override”，预览最终 effective权限。证据：[`forSessionTemplate`](../../lib/config/acp_client_config.dart#L181-L188)、[`effectivePermissionConfig`](../../lib/config/acp_client_config.dart#L217-L227) |
| `assistant_agent` | 可空时继承全局；存在时整体替换 Assistant config | 配置文件专属 | 这是按模板选择的自动化配方，不是当前 session动态 option。目标 template → Assistant override（inherit/override）。证据：[`forSessionTemplate`](../../lib/config/acp_client_config.dart#L189-L202) |
| `mode`, `model`, `reasoning_effort` | 可空；session创建并加载 Agent settings后逐项尝试应用。Agent不暴露、值不在choices、调用失败都会产生 warning而非回滚 session | 配置文件专属；New Session卡片只摘要部分字段；创建时生效一次 | Agent config options存在时 legacy mode明确不应用；template可能成功创建但部分设置失效。目标编辑时连接 Agent做能力校验，同时保留“unvalidated value”。证据：[`_applySessionTemplateSettings`](../../lib/state/chat_controller.dart#L3137-L3213) |

## 当前会话设置

| 字段/动作 | 真实作用与默认 | 生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| Agent `configOptions` | 完全由当前 ACP session动态返回：id/name/type/currentValue/options/description/category/group；无应用侧固定字段清单 | Session Settings dialog、右侧 Inspector、composer快捷选择三处可修改；每次选择立即 `session/set_config_option` | 三处重复入口；不能保存成全局默认。目标保留 composer常用快捷项，Inspector只读摘要，完整编辑集中到“Current session settings”。证据：[`ChatConfigOption`](../../packages/ianvs_agent_chat/lib/models/chat_session_settings.dart#L122-L154)、[`setConfigOption`](../../lib/state/chat_controller.dart#L4710-L4739)、[Inspector](../../lib/ui/components/workspace_inspector.dart#L493-L498) |
| model / reasoning effort projection | 应用通过 id/name/category/group 文本启发式，从 configOptions中各取第一个匹配项 | dialog和composer把它们提升为专用选择器，仍调用同一 set_config_option | heuristic可能误判或漏判，多项匹配也只取第一项；不是 schema保证。目标仍展示 Agent提供的原始 group/category，并将提升项标成动态能力。证据：[`isModelOption`](../../packages/ianvs_agent_chat/lib/models/chat_session_settings.dart#L160-L182)、[`isReasoningEffortOption`](../../packages/ianvs_agent_chat/lib/models/chat_session_settings.dart#L184-L215)、[projection](../../lib/ui/components/session_settings_dialog.dart#L343-L369) |
| legacy mode | 只有 configOptions为空时 `shouldUseModeFallback=true` 才显示/允许 mode | Session Settings dialog；立即 `session/set_mode` | 只要任何 config option存在，所有 legacy mode都隐藏并禁止，即使 option与mode无关。目标作为 compatibility fallback呈现并保留这一协议优先级。证据：[`shouldUseModeFallback`](../../packages/ianvs_agent_chat/lib/models/chat_session_settings.dart#L16-L21)、[`setSessionMode`](../../lib/state/chat_controller.dart#L4680-L4707) |
| Refresh | 重新向当前 Agent请求 settings；创建/恢复 session也会加载 | Session Settings → Refresh；streaming/session operation期间禁用 | load失败会把设置清空，UI不显示具体错误。目标显示来源、last refreshed和失败状态。证据：[`_loadSessionSettings`](../../lib/state/chat_controller.dart#L8291-L8318)、[dialog action](../../lib/ui/components/session_settings_dialog.dart#L67-L80) |
| mutation lifecycle | setting变更只在当前 active session且非 streaming/operation时允许；Agent返回空 option列表时本地仅覆写已知项；Agent event也可异步更新 | 立即生效，无 Save/Cancel transaction，不写 `settings.json` | AlertDialog形态容易让人期待“Close前未保存”；实际点击即提交。目标改用明确即时控件/状态反馈。证据：[`setConfigOption`](../../lib/state/chat_controller.dart#L4710-L4739)、[event update](../../lib/state/chat_controller.dart#L7398-L7425) |
| execution policy | 见权限表；Controller初始为 default，每个 controller实例独立 | composer即时修改，不在 Session Settings dialog | 虽影响当前交互，却不跟 Agent session settings来自同一协议。目标在 Current session页单列“Permission handling (local runtime)”。证据：[`AcpChatSession` bridge](../../lib/chat/acp_chat_session.dart#L96-L100) |

## Independent LLM connection

| 字段/能力 | 真实作用与默认 | 生效与当前入口 | 风险/依赖；目标分组 |
| --- | --- | --- | --- |
| completion endpoint | 完整 OpenAI-compatible Chat Completions URL；必须 http/https、有 authority、无 userinfo/fragment；默认空 | Agents menu → Advanced → Independent LLM chat → Start conversation；构造 client时生效 | 与 ACP Agent endpoint是不同协议；这里允许任意 remote plain HTTP。目标移出 Agent Configuration，作为“New independent LLM conversation”连接页。证据：[`AgentToolbar`](../../lib/ui/components/agent_toolbar.dart#L277-L289)、[`LlmChatPanel`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L108-L124)、[`OpenAiChatClient`](../../packages/ianvs_agent_chat/lib/llm/openai_chat_client.dart#L42-L66) |
| model | 必填自由文本，无 discovery；默认空 | 同一临时表单；Start时固定到 client | 与 ACP session model完全无共享状态。目标字段加“OpenAI model id”，不要复用 Agent动态 model组件。证据：[`LlmChatPanel`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L127-L134) |
| API key | 可空；请求时作为 Bearer header。连接建立后输入框立即清空，但值留在 `OpenAiChatClient`直到 session dispose | 只在当前 connection内存，New connection或关闭页面释放；不进Keychain/JSON | “清空输入框”不等于立即清除内存。若未来保存profile必须另做 secret设计，不能接入当前 Agent/MCP引用而不迁移。证据：[`_connect`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L38-L54)、[request header](../../packages/ianvs_agent_chat/lib/llm/openai_chat_client.dart#L119-L133) |
| Model supports images | 用户手动布尔声明，默认 false；控制附件能力 | 临时表单，connection lifetime | 没有服务能力探测，误选会在请求时失败。目标叫“Enable image input for this model”，标明manual。证据：[`LlmChatPanel`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L149-L154)、[`LlmChatSession` capability](../../packages/ianvs_agent_chat/lib/llm/llm_chat_session.dart#L91-L113) |
| advanced client options | Client API还支持 headers、extraBody、requestTimeout（2 min）、event/response byte limits；panel未暴露；tools由host传入但当前 app用默认空列表 | 代码 API专属 | 不是现有设置重设计的“丢失字段”，但若引入可保存 LLM profiles需明确是否纳入。证据：[`OpenAiChatClient` constructor](../../packages/ianvs_agent_chat/lib/llm/openai_chat_client.dart#L42-L99)、[`LlmChatPanel.tools`](../../packages/ianvs_agent_chat/lib/llm_chat_panel.dart#L8-L16) |

## 重复、冲突与误导证据

| 问题 | 当前证据 | 重设计判断 |
| --- | --- | --- |
| 一个名为 “Agent Configuration”的 640px 弹窗承载整个应用设置 | 内容顺序实际是 Config path → Additional Directories → MCP → Assistant → Client Providers → Storage → Agents，[`build`](../../lib/ui/components/agent_config_dialog.dart#L166-L307) | 改为有稳定左侧/顶部分类的 Settings surface；标题使用“Settings”，Agent/MCP是其中两页 |
| Agent connection、Assistant agent、permission review agent混用“Agent” | 三者生命周期分别是主连接、受限 helper、permission sidecar | 所有 selector显示角色前缀和作用域；不要只写“Agent” |
| 五种 model字段同名 | Assistant model、reviewer model、template model、当前 session model、Independent LLM model都有独立读写链 | 文案必须带 owner；只有当前 session model是Agent动态设置 |
| “Review agent”开关与实际 runtime不一致 | disabled配置下仍回退 active Agent构造 reviewer；只有 composer选Auto Review才会启动review | 先确定产品语义，再让 runtime/UI一致；实现对比必须专门验这一项 |
| 权限默认、自动化配方、运行模式分散 | provider switches/rules/reviewer在全局大弹窗，execution policy在composer | 全局页配置能力与自动化；composer只选当前运行策略，并显示最终 reviewer/rule摘要 |
| “Additional Directories”看似工作区设置 | 它是应用全局列表，template只能追加，session记录自己的最终目录 | 明确 Default roots / Template additions / Current session roots三层，不提供伪 workspace scope |
| Current与Default Agent并列但行为不同 | Agent卡片同时显示 Current/Default；菜单切 current 不持久化，但主 Save 会用 default 重建 active controller | Current使用运行状态样式，Default是可编辑设置；保存默认必须明确提示会切换/重建当前运行时 |
| 嵌套的 Save 不是持久化 | Agent/MCP 子编辑器的 `Save Agent` / `Save MCP Server` 只 `Navigator.pop` 返回对象，父弹窗再把对象写入本地 draft；只有父弹窗最外层 Save 才调用 `onSaveConfig`。证据：[父弹窗提交](../../lib/ui/components/agent_config_dialog.dart#L290-L324)、[Agent 子编辑器提交](../../lib/ui/components/agent_config_dialog.dart#L1866-L1936)、[MCP 子编辑器提交](../../lib/ui/components/agent_config_dialog.dart#L2247-L2303) | 完成子弹窗后若直接关闭父弹窗，修改会丢失；生产入口确实存在最外层 Save，但两层按钮都叫 Save 容易误判 | 子弹窗改为 Add/Apply；父弹窗显示未保存状态并保留唯一的 Save settings |
| Session settings三处写入口且“关闭弹窗”无提交含义 | composer、Inspector、Session Settings均直接调用 `setConfigOption` | 常用项只保留一个主要快速入口；所有即时提交控件显示pending/error，不用表单Save心智 |
| Config-only字段在统一Save中隐形存续 | templates、Assistant timeout、per-Agent reviewer、persistence identity、unknown fields都未完整可编辑 | 每类至少显示“configured outside UI/advanced values retained”，实现时加入round-trip fixture防丢失 |
| 保存不是温和的下次启动生效 | `_saveConfig`写入后立即调用 `_replaceOwnedControllerConfiguration`，清空controller cache、创建新controller并dispose旧controller；相同exact runtime pool可能复用 | Save前按字段计算“立即重建连接/仅影响新会话/仅更新默认”；对有active session的重建给清晰提示。证据：[`_saveConfig`](../../lib/app.dart#L1423-L1450)、[`_replaceOwnedControllerConfiguration`](../../lib/app.dart#L1100-L1157) |

## 不能丢失的兼容约束

1. writer必须继续读取现有JSON再合并：保留未知顶层、provider、storage、Assistant、template、Agent/MCP raw字段，并把管理字段规范成snake_case；不能把表单序列化结果直接覆盖整文件。证据：[`_persistEditedConfig`](../../lib/config/acp_config_store.dart#L490-L639)、[`_mergeConfigMapPreservingUnknown`](../../lib/config/acp_config_store.dart#L446-L473)。
2. 已接受snake_case/camelCase及历史别名，但同一语义同时出现多个alias时会报错；新UI写canonical key，也要能读取旧文件。典型别名包括根级 `agentServers`、`mcpServers`、`clientProviders`、`sqliteStorage`、`assistantAgent`、`sessionTemplates`，以及 filesystem `fs`、permission `approval_agent`。
3. Agent `persistence_id` / `persistence_aliases`、session记录中的template id/version和agent association必须跨重命名与表单round trip保持；这些字段决定旧session能否重新归属。证据：[`configForSessionIndexAgent`](../../lib/config/acp_client_config.dart#L230-L269)、[`Workspace state serialization`](../../lib/workspace/workspace_sidebar_state_store.dart#L580-L603)。
4. Secret value与reference必须分离；保存要维持prepare → atomic write → commit → retire cleanup的顺序，失败后的cleanup queue也必须保留。配置路径/target变化时不能复用不属于新owner的引用。证据：[`AcpConfigStore.writeConfig`](../../lib/config/acp_config_store.dart#L17-L111)。
5. remote ACP Agent和MCP-over-ACP即使当前不可运行，也必须可读取、展示并无损保存；不能因新表单只提供可用transport就删除旧条目。
6. `session_templates[].mcp_servers`的missing/null与empty array必须继续区分；template permissions/Assistant的inherit与override也必须是显式三态/二态模型，不能用“空表单”等价。
7. 绝对路径、URL scheme/TLS/userinfo、HTTP header、唯一名称、正整数与容量上限应在字段级即时校验，最终保存仍必须走canonical parse与每个template runtime resolution。证据：[`_validateConfigForPersistence`](../../lib/config/acp_config_store.dart#L417-L440)。
8. 保存后的生效矩阵不能统一写成“已保存”：配置文件持久化与controller replacement当前发生在同一操作；session dynamic settings和composer policy不写文件；Independent LLM只驻留内存。
9. `workspace_ui_state.json`必须继续与两类bounded recovery payload分开管理；storage设置不能误删或限额侧栏/session index状态。
10. Agent/MCP editor中的unknown/raw和secret refs是forward compatibility与安全数据，不应直接暴露为可复制的完整JSON，也不能在改名、换transport时静默带到不相同target。

## 建议的目标分组与入口

| 目标入口 | 内容 | 范围标识与生效提示 |
| --- | --- | --- |
| Settings → General | startup default Agent、default session template、config file位置/状态 | `Application default`；明确当前实现中修改 startup default 并 Save 也会立即切换/重建活动 controller |
| Settings → Connections → Agents | Agent列表、launch/endpoint/auth、stable identity、Agent reviewer override | `Agent connection`；保存前提示是否重建当前runtime；unavailable transport保留兼容态 |
| Settings → Connections → MCP | MCP列表、transport、auth、被template/reviewer引用情况 | `Application default`；显示哪些template/runtime会受影响 |
| Settings → Workspace access | 默认additional roots、filesystem read/write/outside、terminal provider | `New sessions by default`；预览最终允许roots，解释client provider含义 |
| Settings → Permissions | trust rules、reviewer mode/target/tool/model/timeout | `Application default`或`Agent override`；展示与composer current policy组合后的effective结果 |
| Settings → Assistant | helper connection/model、title、fallback、summary、collapse、timeout、test | `Application default`；明确会发送的数据、额外调用与restricted runtime |
| Settings → Sessions & Data | 本轮整理现有 template/storage 字段；完整 template CRUD、数据 inventory/usage/clear actions 仅作为后续候选 | template字段逐项显示inherit/override；storage逐store解释维护时机，不把候选能力列为本轮实现承诺 |
| Current session settings | Agent动态model/reasoning/mode/其它config options；local permission policy摘要 | `Current session · applies immediately`；无Save按钮，显示mutation状态 |
| New Session | template、Agent（custom时）、session cwd；展开预览effective MCP/roots/permissions/Assistant | `This new session`；模板应用warning在Start前尽量验证，Start后仍逐项报告 |
| Independent LLM chat | endpoint、model、API key、image flag；未来若需要另建可保存profile | `Temporary connection`；不与ACP Agent/MCP配置混排 |

这套分组的核心验收标准是：每个控件同时回答“改谁、存哪里、何时生效”，并且实现对比能证明所有隐藏兼容字段仍被无损round trip。
