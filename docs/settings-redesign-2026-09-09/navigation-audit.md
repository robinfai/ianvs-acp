# 配置与操作入口导航审计

日期：2026-09-09

## 1. 范围与结论

本审计只依据当前代码，不复用旧报告的结论。阅读范围包括 `app_shell`、`agent_toolbar`、`workspace_sidebar`、`workspace_inspector`、新建/恢复会话、Agent 配置、会话设置、活动诊断和独立 LLM 入口。

本文的扩展建议用于记录候选方向，不代表本轮交付承诺；最终实施范围以同目录 [`README.md`](README.md) 的“本轮实施边界”为准。特别是完整模板 CRUD、新建会话高级 override、独立 workspace overview、手动 Agent discovery 和把独立 LLM 改造成新产品入口，均属于候选，不应从本文推断为本轮必做项。

当前功能基本完整，主要问题不是缺功能，而是对象边界不清：

1. `Agent Configuration` 实际是整个应用的持久化设置，包含 Agent、MCP、额外目录、权限、Assistant Agent 和本地存储，却以 Agent 命名，并同时从侧栏和 Agent 菜单进入。
2. Agent 菜单混合了运行时切换、认证、持久化配置、诊断和一个完全独立的 LLM 客户端。
3. 会话设置既可在 Inspector 直接改，也可进入 `Session Settings` 改；后者又混入 Fork、Close、Delete 等会话操作。
4. 新建会话只让用户选择模板/Agent 和工作目录。模板内部实际还会决定 model、reasoning、mode、MCP、额外目录、权限和 Assistant Agent，但表单不展示最终生效配置，也没有编辑模板的 GUI。
5. 同一会话操作在顶部标题菜单与侧栏会话菜单重复，名称和分组不一致；例如 `Continue in New Session` 与 `Fork Locally` 是同一动作。
6. 活动诊断有三个入口；Inspector 将 `Session settings` 放在 `Diagnostics` 折叠区，进一步模糊“可修改参数”和“只读诊断”的区别。

推荐建立六个稳定归属：**应用设置、Agent 切换与认证、新建/当前会话参数、会话操作、工作区操作、活动与诊断**。所有现有能力都保留，但每项能力只设一个完整入口；高频动作可保留快捷入口，快捷入口必须跳向或调用同一份状态与动作定义。

## 2. 当前信息架构

```text
AppShell
├─ 左侧栏顶部
│  ├─ 新对话 ───────────────┐
│  ├─ 代理设置 ─────────────┼─ 重复入口
│  └─ 活动与诊断 ───────────┼─ 重复入口
├─ 工作区列表                │
│  ├─ 添加工作区             │
│  ├─ 工作区菜单             │
│  │  ├─ New / Resume Session
│  │  └─ 固定、Finder、Worktree、重命名、归档、隐藏
│  └─ 会话菜单 ─────────────┼─ 与顶部会话菜单大量重复
├─ 顶部工具栏                │
│  ├─ 当前会话菜单 ─────────┘
│  ├─ Agents 菜单
│  │  ├─ 切换 Agent
│  │  ├─ Agent Configuration
│  │  ├─ Authenticate / Log Out
│  │  ├─ Activity & Diagnostics
│  │  └─ Advanced / Independent LLM chat
│  ├─ Reconnect
│  ├─ Terminal
│  ├─ Context Inspector
│  └─ 新会话
└─ Context Inspector
   ├─ 会话设置快捷按钮
   ├─ 会话动态配置快捷修改
   ├─ Workspace / Session / Paths / MCP / Providers 信息
   └─ Diagnostics
      ├─ Session settings
      └─ Runtime diagnostics
```

代码证据：`lib/ui/shell/app_shell.dart:248-323,379-466` 负责组合入口；`lib/ui/components/agent_toolbar.dart:231-295` 定义 Agent 菜单；`lib/ui/components/workspace_sidebar.dart:1249-1369,1947-2026` 定义工作区和会话菜单；`lib/ui/components/workspace_inspector.dart:480-543,755-813` 定义 Inspector 中的参数和诊断入口。

## 3. 入口逐项盘点

### 3.1 应用设置

| 当前路径 | 动作 | 生效对象与持久化 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 左侧栏 → `代理设置` | 打开 `AgentConfigDialog` | 整份 `AcpClientConfig`，保存到用户配置文件 | 名称只指向 Agent，实际覆盖全局配置；与顶部 Agent 菜单重复 | 改名为 `设置`，作为唯一完整设置中心；侧栏保留此入口 |
| 顶部 → Agents → `Agent Configuration` | 打开同一对话框 | 同上 | 与侧栏完全重复 | 改为 `管理 Agents…` 深链，直接打开设置中心的 Agents 页；不再打开另一份完整表单 |
| `Agent Configuration` → User Config | 只读显示配置文件路径 | 无修改 | 启动错误 Banner 可以外部打开配置文件，此处只能选择/复制文本 | 移到设置 → Advanced → Configuration file，提供“在文件管理器显示/打开”一致动作 |
| 启动错误 Banner → Open | 外部打开配置文件 | 文件本身 | 只有发生启动错误时出现；与设置中的只读路径能力不一致 | 保留为故障恢复快捷入口，并复用 Advanced 页的同一打开动作 |
| 应用启动 → `Discovered ACP Agents` | 自动检测缺失的本地 Agent，勾选后写入配置 | `agent_servers` | 不是可重复访问的用户入口；添加 Agent 与设置内 `Add Agent` 分离 | 保留首次/变更检测；在设置 → Agents 增加 `Discover local agents…` 手动入口，复用同一选择表单 |

当前全局表单是一张长滚动表单（`lib/ui/components/agent_config_dialog.dart:167-308`），按顺序混排：

| 当前区块 | 字段/动作 | 实际作用域 | 推荐归属 |
|---|---|---|---|
| User Config | 配置文件路径 | 应用 | Advanced |
| Additional Directories | 添加/删除全局额外目录 | 所有从该配置创建的运行时/会话 | Session Defaults → Context |
| MCP Servers | 添加、编辑、删除；stdio/http/sse，保留不可用 acp 配置 | 应用资源，模板可筛选 | Tools & MCP |
| Assistant Agent | 启用、Agent、Model、校验、智能标题、完成回合摘要、默认折叠过程、标题回退字数 | 应用默认，也可被会话模板覆盖 | Assistant |
| Client Providers | FS read/write/outside、Terminal、Trust rules、Review agent 及目标/model/timeout | 应用默认权限与客户端能力，模板可覆盖 permissions | Permissions；文件系统/终端能力放在同页的 Client capabilities 子区 |
| Local Recovery Storage | 每个 store 的 GB 上限、保留天数 | 应用本地存储 | Storage |
| Agents | 添加/编辑/删除、设置默认 Agent | 应用 Agent 注册表与默认值 | Agents |
| Agent Server 子表单 | 预设/自定义；name、type、command、cwd、args、env，或 URL、headers | 单个 Agent 连接定义 | Agents → Agent detail；默认先显示基本信息，连接字段放 Advanced |
| MCP Server 子表单 | name、type、command/URL/server id、args/env/headers | 单个 MCP 连接定义 | Tools & MCP → Server detail |
| Trust Rule 子表单 | tool name、tool kind、allow/deny | 应用默认权限规则 | Permissions → Trust rules |

表单当前用一个全局 Save 提交所有草稿，但关闭时没有脏状态提示；保存又会重建相关运行时配置。改版后仍应维持一次性、原子保存语义，并补上：页面级脏状态、`Cancel`/关闭丢弃确认、字段内校验、保存错误定位到具体页。不要把即时生效的会话参数纳入这个 Save。

一个显著缺口是：`sessionTemplates` 与 `defaultSessionTemplateId` 在保存时原样传回（`agent_config_dialog.dart:319-332`），没有编辑控件。设置中心应增加 `Session Profiles` 页，否则用户能选择模板却只能手改 JSON。

### 3.2 Agent 切换与认证

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 顶部 → Agents → Agent 名称 | 切换前台 Agent/Controller | 当前应用前台运行时；不等同于修改默认 Agent | 与设置中的“Set as default”、新建会话中的 Agent 选择语义相近但不同 | 保留为高频 Agent switcher；明确标注 `Current agent`，不放全局设置和诊断 |
| 顶部 → Agents → Authenticate | 选择 Agent 暴露的认证方法并认证 | 当前 Agent 连接 | Resume 内也能对需要认证的 Agent 发起认证 | 保留在 Agent switcher；Resume 中的认证属于就地解阻，也保留，并复用认证流程 |
| 顶部 → Agents → Log Out | 退出当前 Agent，并清除本地 session state | 当前 Agent Controller | 与应用账户页脚的头像/Agent 名视觉上可能被理解为应用账户 | 保留在 Agent switcher 的当前 Agent 区；确认文案继续明确影响当前 Agent 和本地状态 |
| 顶部 → Reconnect | 重连当前 Agent | 当前 Agent 连接 | Agent 状态与连接动作被拆在菜单外；仅错误/断开时出现 | 保留为错误态快捷按钮，同时在 Agent switcher 当前项提供状态与重连 |
| 新建会话 → Custom → Agent | 为新会话选择 Agent | 新会话，创建后会切换前台 Controller | 与全局切换不同，但当前表单未解释 | 保留；标注 `Agent for this session`，默认继承当前 Agent |
| 恢复会话 → Select Agent | 选择从哪个 Agent 加载目录；必要时认证 | 恢复目标与对应 Agent | 是恢复流程必要的作用域选择 | 保留在 Resume 表单，不转移到全局 switcher |
| 设置 → Agents → Set default | 修改 `default_agent_server` | 应用启动及新窗口使用的默认 Agent；持久化 | 当前 Agent 与 Default Agent 同屏用 `Current`/`Default` 徽标，但入口叫 Agent Configuration；普通新建会话通常继承当前 Agent | 保留在 Agents 设置页；明确 `Default for app launch and new windows`，保存后才生效，不宣称它统一控制所有新建会话 |

认证是 Agent 的运行状态；凭据配置若由 Agent 自身流程提供，应继续通过 Authenticate 进入，不应伪装成普通文本设置。设置页只展示连接是否需要认证、最后状态和认证动作，不复制认证表单。

### 3.3 新建、恢复与当前会话参数

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 左侧栏 → 新对话 | 打开 `NewSessionAgentDialog` | 新会话 | 与顶部 `新会话`、工作区菜单 `New Session` 重复 | 保留为全局主入口；默认工作目录取当前会话/应用 cwd |
| 顶部 → 新会话 | 打开同一表单 | 新会话 | 与左侧栏相同 | 保留为紧凑窗口和工作流中的快捷入口，复用同一表单 |
| 工作区菜单 → New Session | 打开同一表单并预填工作区路径 | 该工作区的新会话 | 有明确上下文价值 | 保留；按钮命名统一为 `New session here` 或保持 `New Session` 并显示目标工作区 |
| 工作区菜单 → Resume Session | 打开 Resume，并把目录严格限制到该工作区 | 选定 Agent 的持久会话 | 只能从工作区菜单发现；侧栏直接点已有会话也会恢复 | 保留上下文快捷入口；在全局新建按钮旁提供 `Resume…` 次操作，支持跨工作区 |
| 新建表单 → Session template | 选择声明式模板 | 新会话运行时与初始化参数 | 卡片只显示部分摘要；实际还可改变 MCP、额外目录、权限、Assistant | 重命名为 `Session profile`，提供可展开的“最终配置摘要” |
| 新建表单 → Custom → Agent | 仅选择 Agent | 新会话 | 无 model/mode/reasoning/MCP/权限覆盖；用户无法在表单完成“自定义” | 在 Agent 建立连接并暴露能力后显示 Model、Reasoning、Mode、Other options；MCP/权限/目录从 defaults 继承，可在 Advanced 覆盖 |
| 新建表单 → Working Directory | 输入绝对路径并提供本地路径补全 | 新会话 workspace cwd | 工作区入口已经知道路径，仍显示可改字段 | 保留；从工作区进入时预填并在顶部显示目标，允许修改 |
| Resume → Agent 列表 → Session 搜索/选择 → Open | 按 Agent 懒加载目录，按 workspace 限定，搜索 title/id/path，恢复会话 | 选中的持久会话 | Footer 与搜索行各有 Refresh；认证 Banner可能指向另一个需要认证的 Agent | 保留单一 Refresh（建议搜索行）；认证提示绑定当前选中 Agent，其他 Agent 的状态放左侧行内 |
| Inspector 顶部调节按钮 | 打开 Session Settings | 当前会话 | Inspector Diagnostics 内还有一次相同入口 | 保留顶部快捷按钮，删除 Diagnostics 内重复项 |
| Inspector → Session 动态 config rows | 直接调用 `setConfigOption` | 当前远端会话，即时生效 | 与 Session Settings 完整重复；没有等待/失败反馈；所有选项平铺在窄栏 | Inspector 仅保留 1–2 个被产品明确指定的高频参数（建议 Model、Reasoning）；点击 `All session settings…` 进入完整页。若无法保证反馈，则全部改为只读摘要 |
| Session Settings → Active model / Reasoning effort / Mode / Config Options | 直接调用 Agent 的 `setConfigOption`/`setSessionMode` | 当前远端会话，即时生效，不写应用设置 | 叫 Settings 但没有 Save；与应用设置保存语义不同 | 改名 `Current Session` 或显示 `Changes apply immediately`；分为 Model、Reasoning、Mode、Advanced options，保留 Refresh |

当前新建表单字段仅为模板、Custom Agent 和 Working Directory（`new_session_agent_dialog.dart:65-130`）。模板在创建会话时先解析运行时级配置，再在远端会话建立后应用 mode/model/reasoning；不支持或被拒绝的字段会形成 warning（`lib/config/acp_client_config.dart:154-207`、`lib/state/chat_controller.dart:3093-3220`）。改版的最终配置摘要应区分：

- **创建前可确定**：Agent、cwd、额外目录、MCP 集合、permission profile、Assistant profile。
- **连接后才能确认**：Agent 暴露的 model、reasoning、mode 和任意动态 config options。
- **应用失败但会话仍可建立**：模板请求值未暴露、未提供或被 Agent 拒绝；需要在表单结束或会话顶部给出逐项结果。

### 3.4 会话操作

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 顶部标题 → `…` | Pin、Rename、Read/Unread、Archive、Open Side Session、Copy 子菜单、Continue in…、Open New Window | 当前会话 | 与侧栏会话菜单大部分重复；缺 `Show in Finder`；Fork 文案不同 | 保留为当前会话快捷菜单；使用与侧栏完全相同的 action descriptor、顺序和文案 |
| 侧栏会话 → 右键/菜单 | 同上，另含 Show in Finder | 指定会话（可非当前） | 与顶部重复是合理的上下文入口，但分组/文案不同 | 保留；同一动作注册表根据上下文决定 enabled/visible |
| 侧栏会话 hover | Pin、Archive | 指定会话 | 是高频快捷操作，但与菜单重复 | 保留；hover 只放低风险高频动作，Archive 保持 Undo |
| Session Settings footer → Fork | fork 当前会话 | 当前会话 | 参数表单混入会话操作；与两个会话菜单重复 | 移除，统一到会话操作菜单 |
| Session Settings footer → Close | 释放 Agent 资源，保留持久历史 | 当前远端会话 | 只有设置表单能发现；容易与关闭弹窗混淆 | 加入统一会话菜单的 `Close remote session`，明确“保留历史”；从设置表单移除 |
| Session Settings footer → Delete | 永久删除 Agent 侧会话历史 | 当前远端会话 | 只有设置表单能发现；与本地 Archive 的差异不易察觉 | 加入统一会话菜单的 Danger 区，命名 `Delete from agent…` 并二次确认；从设置表单移除 |

统一会话菜单建议顺序：

1. **Organize**：Pin/Unpin、Rename、Mark Read/Unread、Archive（本地，可撤销）。
2. **Open**：Open Side Session、Open in New Window、Show in Finder。
3. **Continue**：Continue in New Session、Continue in New Worktree。
4. **Copy**：Working Directory、Session ID、Deep Link、Markdown。
5. **Remote lifecycle**：Close remote session（保留历史）、Delete from agent（不可恢复）。仅当 capability 暴露时显示。

`Archive` 是应用内本地索引操作，`Close` 是释放 Agent 资源，`Delete` 是删除 Agent 侧历史，不能合并为一个“删除”入口。

### 3.5 工作区操作

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 项目标题 → Add workspace | 选择目录并加入侧栏状态 | 侧栏工作区集合 | 与新建会话的 cwd 输入功能相邻但目的不同 | 保留；命名统一使用 `Workspace` 或 `项目`，当前中英文混用应统一 |
| 点击工作区 | 有会话时选中第一条会话；无会话时展开/折叠 | 工作区/会话 | 点击名称的结果依赖是否有会话，不可预期 | 点击名称只选择工作区并展示 overview；Disclosure 只展开；会话由用户显式选择 |
| 工作区菜单 → Pin/Unpin | 固定侧栏排序 | 工作区侧栏状态 | 与会话 Pin 同名但对象不同 | 保留，文案始终带 Workspace/Project 对象名 |
| 工作区菜单 → Show in Finder | 打开工作区目录 | 工作区路径 | 会话菜单也有 Finder，目标可能相同 | 两处都保留上下文快捷入口；提示中显示对象和路径 |
| 工作区菜单 → Create Permanent Worktree | 创建永久 worktree | Git 工作区 | 仅 Git workspace 显示，合理 | 保留在工作区菜单，放到 `Worktree` 分组 |
| 工作区菜单 → Rename Project | 只修改侧栏显示名 | 本地侧栏状态，不改磁盘目录 | 文案可能让人理解为重命名目录 | 改为 `Rename in sidebar…` |
| 工作区菜单 → Archive Conversations | 批量本地归档该工作区会话 | 工作区下会话索引 | 与单会话 Archive 一致但影响批量 | 保留并确认影响数量，成功后继续支持 Undo |
| 工作区菜单 → Hide from Sidebar | 从侧栏隐藏，可 Undo | 本地侧栏状态 | 使用 danger 色但并不删除数据 | 保留，但不要用删除语义；成功提示继续提供 Undo |

### 3.6 活动与诊断

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 左侧栏 → 活动与诊断 | 打开默认 Events tab | 当前 Agent 连接与当前会话 | 与 Agent 菜单重复 | 保留为唯一完整入口；可放到侧栏底部 utility 区 |
| 顶部 → Agents → Activity & Diagnostics | 打开同一弹窗 | 同上 | 诊断不属于 Agent switcher，且与侧栏重复 | 从 Agent 菜单移除；当状态错误时提供直达 Runtime 的状态快捷入口 |
| Inspector details → Diagnostics → Runtime diagnostics | 打开诊断并定位 Runtime tab | 当前运行时 | 深链有上下文价值 | 保留，改名 `Open runtime diagnostics…`；不在 Inspector 再放完整 Events 入口 |
| Inspector details → Diagnostics → Latency | 展示最近延迟 | 当前会话 | Diagnostics 中同时出现 Session settings | 保留只读诊断数据；移走 Session settings |
| Activity & Diagnostics → Events | 会话事件时间线、工具/权限/延迟/模板摘要 | 当前会话 | 无 | 保留 |
| Activity & Diagnostics → Permissions | 当前连接保留的权限历史，可导出 JSON | 当前连接，可能包含其他会话，不含其他连接 | 弹窗副标题只强调当前会话，容易低估 tab 范围 | 保留；tab 顶部继续明确连接作用域，并显示 Agent/connection identity |
| Activity & Diagnostics → Runtime | Agent runtime、session recipe、MCP/providers、capabilities、credential inventory | 当前运行时和当前会话 recipe | 与 Inspector 的 Paths/MCP/Providers 只读信息重复 | Inspector 保留短摘要；Runtime 作为完整来源，并提供 `Open settings at…` 深链而非直接编辑 |
| Error Banner → Copy diagnostics / Retry | 复制错误与 config path；重试启动或重连 | 应用启动或当前 Agent | 与诊断弹窗相邻但属于故障就地恢复 | 保留；增加 `Open diagnostics`（若 controller 可用），复用 Runtime tab |

诊断界面应保持只读。唯一写操作 `Export JSON` 是导出快照，不应与运行时配置 Save 混在一起。

### 3.7 独立 LLM

| 当前路径 | 动作 | 生效对象 | 重复/冲突 | 改版建议 |
|---|---|---|---|---|
| 顶部 → Agents → Advanced → Independent LLM chat | 推入独立页面；输入 completion endpoint、model、临时 API key、images capability，创建内存 Chat Completions 会话 | 与 ACP workspace/session 完全独立；离开 widget 后 dispose；API key 仅当前连接 | 放在 Agents 菜单会让用户误以为它是 Agent 类型或会切换当前 ACP Agent；其 Model 与当前会话/Assistant/Review model 又是第四种 model 字段 | 移到独立 `Tools`/`Playground` 入口；名称改为 `LLM Playground`，副标题明确 `Temporary OpenAI-compatible connection`。保留所有字段和临时、不持久化语义 |

独立 LLM 不应并入 Agent 注册表：它没有 ACP session 恢复、工作区、MCP/权限或持久化配置语义。可以在设置 → Advanced 仅提供入口说明，不保存 API key，也不把它作为默认 Agent。

## 4. 推荐导航图

```text
左侧栏
├─ New session                         全局主动作，保留
│  └─ 下拉/次动作：Resume session…      新增全局恢复入口
├─ Workspaces                           现有列表
│  ├─ Workspace context menu            工作区操作
│  └─ Session context menu              指定会话操作
├─ Activity & Diagnostics               唯一完整诊断入口，保留
├─ LLM Playground                       独立工具入口（可放 More/Tools）
└─ Settings                             唯一完整持久设置入口
   ├─ Agents
   ├─ Session Profiles
   ├─ Tools & MCP
   ├─ Permissions
   ├─ Assistant
   ├─ Storage
   └─ Advanced

顶部工具栏
├─ 当前会话标题 + Session actions        当前会话快捷菜单
├─ Current Agent                         只含切换、认证、退出、状态/重连
├─ Terminal                              保留
├─ Context                               保留
└─ New session                           保留紧凑快捷入口

Context Inspector
├─ Session summary                       Agent、Model、Reasoning、Mode、usage
├─ All session settings…                 唯一完整当前会话参数页
├─ Workspace/context/resource 摘要        只读
└─ Open runtime diagnostics…             Runtime 深链
```

## 5. 当前入口到推荐入口映射

| 当前入口/能力 | 推荐入口 | 处理方式 |
|---|---|---|
| 侧栏 `代理设置` | 侧栏 `Settings` | 保留位置，改名并重做分栏 |
| Agents → Agent Configuration | Current Agent → `Manage agents…` | 保留深链，统一到 Settings/Agents |
| Agent 列表切换 | Current Agent | 原位保留 |
| Authenticate / Log Out / Reconnect | Current Agent | 统一到同一状态菜单；错误态可保留 Reconnect 按钮 |
| Activity & Diagnostics 三处入口 | 侧栏完整入口 + Inspector Runtime 深链 | 删除 Agent 菜单重复入口 |
| Independent LLM chat | Tools/LLM Playground | 移出 Agent 菜单，能力保留 |
| 侧栏、顶部、工作区三个 New Session | 同一 New Session command | 侧栏/顶部保留快捷；工作区入口负责预填上下文 |
| 工作区 Resume Session | 全局 Resume + 工作区快捷 | 增加全局入口，不移除工作区限定入口 |
| Inspector 参数行 + Session Settings | Inspector 摘要/少量快捷 + Current Session 完整页 | 统一状态与反馈，不再两套表单 |
| Session Settings 的 Fork/Close/Delete | Session actions | 从参数表单移走，能力保留并补齐菜单 |
| 顶部与侧栏 Session actions | 共用一份动作定义 | 两个上下文入口都保留，统一文案/分组/可用性 |
| 自动 Agent Discovery | Settings/Agents → Discover + 自动提示 | 增加可重复入口，复用现有流程 |
| 只能从 JSON 编辑 Session Templates | Settings/Session Profiles | 增加 GUI；New Session 只负责选择和临时覆盖 |

## 6. 表单重设计要求

### 6.1 Settings

- 使用左侧分类导航，右侧单页表单；每次只展示一个设置域。
- 顶部显示作用域 `Application settings` 和配置文件路径/只读状态。
- 底部固定 `Cancel` 与 `Save changes`；仅草稿变更后启用 Save。
- 关闭有未保存变更时提示；保存失败定位到含错误字段的分类。
- Agent/MCP 列表使用 master-detail：列表负责选择、默认状态与连接状态，详情负责字段；添加/编辑不再层层嵌套长弹窗。
- `Session Profiles` 展示每个 profile 的解析摘要：Agent、Model、Reasoning、Mode、Directories、MCP、Permissions、Assistant；明确 inherit/all/none 三态，尤其 MCP 的 `null` 与空列表不能合并。

### 6.2 New Session

- 顶部固定显示 Workspace/working directory。
- 主选择改为 `Session profile`，默认 profile 明确标记；`Custom` 是一个真正可编辑的 profile 草稿。
- 基本区：Agent、Model、Reasoning、Mode。字段按 Agent capability 动态出现。
- Advanced 区：additional directories、MCP selection、permission profile、Assistant behavior；默认折叠但显示摘要。
- Start 前显示 `Will create with…` 摘要；创建后逐项显示模板应用 warning，不用一条笼统 snackbar 吞掉字段归因。
- 从工作区入口打开时保留上下文预填，从顶部/侧栏进入时继承当前 workspace；三处调用同一 command 和同一表单。

### 6.3 Current Session

- 标题包含会话名、Agent、短 ID；显示 `Changes apply immediately`。
- Model、Reasoning、Mode 提升到基本区；其他 Agent 动态 option 按 category/group 分组。
- 修改控件显示 pending/success/error，失败后回到 Agent 确认值；流式输出或 session operation 时展示禁用原因。
- Refresh 是唯一 footer utility；Fork/Close/Delete 归入 Session actions。
- Inspector 若保留快捷选择器，必须调用同一 action/state presenter，并显示相同 pending/error；否则只读展示当前值。

### 6.4 Resume Session

- 维持 Agent → workspace/session 的结构和惰性加载。
- 全局入口显示所有 workspace；从 workspace 进入时显示固定 scope chip，并提供“查看所有工作区”。
- 只保留搜索行的 Refresh；Footer 只保留 Cancel/Open Session。
- 认证提示绑定所选 Agent；其他 Agent 的 auth/error/busy 状态在列表行显示。
- 选择项预览继续展示 title、id、Agent、main/additional directories、更新时间和按需 metadata。

## 7. 快捷入口保留与统一原则

应保留的快捷入口：

- 顶部与侧栏 `New session`；工作区菜单 `New session here`。
- 工作区限定 `Resume session`，并新增一个全局 Resume。
- 顶部 Current Agent switcher，以及认证/退出/错误态重连。
- 顶部当前会话菜单与侧栏指定会话菜单。
- 会话行 hover 的 Pin 与 Archive。
- Terminal、Context Inspector 开关及 macOS 现有快捷键。
- Inspector 的 `All session settings…` 与 `Open runtime diagnostics…` 深链。
- 错误 Banner 的 Retry、Copy diagnostics、Open config。

必须统一的入口：

- 所有持久化配置统一进入 Settings；Agent 菜单只保留 `Manage agents…` 深链。
- 顶部/侧栏会话菜单共享动作表、标签、分组和 capability gating。
- Inspector 与 Current Session 共用参数状态、提交和错误反馈。
- 全局/顶部/工作区新建调用同一 New Session command，只改变预填上下文。
- 所有诊断入口打开同一 Activity & Diagnostics 容器，并通过 `initialTab` 深链。
- Agent Discovery 的自动提示和手动 Discover 使用同一选择与写入流程。

## 8. 验收流程

后续实现与标注对比应覆盖下列完整流程。每个流程至少记录：入口截图、表单作用域标签、提交前后状态、返回主界面后的可见结果。

### A. 应用设置与脏状态

验收基线必须让 `AcpClientApp` 自持 Controller，并提供可写配置路径/写入回调。注入外部 Controller 时，`lib/app.dart:813-818` 会有意隐藏配置保存能力；不能把这种测试装配状态当成生产界面的 Save 缺失。

1. 从侧栏 Settings 打开；确认默认落在最近页或 Agents 页，顶部显示 Application settings 与配置路径。
2. 修改 Additional Directory、MCP、权限、Assistant、Storage、默认 Agent，各页出现同一全局 dirty 状态。
3. 关闭并验证丢弃确认；取消关闭后改动仍在。
4. 保存后重新打开，所有字段回读一致；当前 Agent 与默认 Agent 标签不混淆。
5. 在只读/缺失 config path 情况下，Save 禁用并给出原因，仍可查看设置。

### B. Agent 管理、切换与认证

1. 从 Current Agent → Manage agents… 深链到 Settings/Agents，不出现第二套设置表单。
2. 添加预设 Agent、编辑自定义 stdio Agent、保留不可用 remote 配置；保存并回读。
3. 用 Current Agent 切换器切换前台 Agent；确认不会暗中改默认 Agent。
4. 对需要认证的 Agent 执行 Authenticate；成功后状态和 Resume 能力同步更新。
5. 断开时 Reconnect 在菜单和错误态快捷按钮调用同一动作；流式/忙碌时显示禁用原因。
6. 从 Settings/Agents 手动 Discover；与自动发现结果一致且不重复添加。

### C. 新建会话

1. 分别从侧栏、顶部、工作区菜单进入；确认表单相同，只有 workspace/cwd 预填不同。
2. 选择默认 Session Profile，展开最终配置摘要并核对 Agent、model、reasoning、mode、MCP、directories、permissions、Assistant。
3. 选择 Custom，切换 Agent；仅展示该 Agent 暴露的动态字段。
4. 输入非绝对路径时阻止 Start；输入有效绝对路径后创建成功。
5. 模拟模板字段未暴露/被拒绝；会话仍创建，逐项 warning 可见且指明字段。
6. 流式状态下按并发能力验证 New Session 的 enabled/disabled 行为。

### D. 当前会话参数

1. 从 Inspector 的 All session settings 打开 Current Session；确认短 ID、Agent、立即生效提示。
2. 修改 model、reasoning、mode、布尔和枚举 config；验证 pending、成功值和失败回滚/错误。
3. Inspector 摘要同步更新，不出现两套不同值。
4. 流式输出、session operation、refresh loading 三种状态下控件禁用并解释原因。
5. Refresh 后 Agent 返回值覆盖本地显示；表单不出现 Save 按钮。

### E. 会话操作

1. 在顶部当前会话菜单和侧栏同一会话菜单逐项对比：标签、顺序、分组和 enabled 状态一致。
2. Pin、Rename、Read/Unread 在两个入口与列表状态同步。
3. Archive 可 Undo；确认它不删除 Agent 历史。
4. Continue in New Session 与 Continue in New Worktree 使用统一文案，按 capability/Git 条件显示。
5. Close remote session 后历史仍可恢复；Delete from agent 二次确认并确实从 Agent history 移除。
6. Copy、Finder、Side Session、New Window 保持现有能力。

### F. 工作区

1. Add workspace 后出现在侧栏；Rename in sidebar 不改变磁盘路径。
2. 点击工作区只改变工作区选择/overview，Disclosure 只负责展开。
3. Pin、Finder、Permanent Worktree 按对象和 Git capability 正确工作。
4. Archive Conversations 显示数量并可 Undo；Hide from Sidebar 可 Undo，不丢失会话。
5. Workspace Resume 默认只列该路径会话；切换“所有工作区”后范围扩大且有明确 scope。

### G. 活动诊断与独立 LLM

1. 从侧栏打开 Events；从 Inspector 深链直接打开 Runtime，容器与数据源相同。
2. Permissions 明确“当前连接，可能包含其他会话”的范围，Export JSON 可用。
3. Runtime 展示 Agent、session recipe、MCP/providers、capabilities 和 credential inventory；只读信息不直接变更配置。
4. Agent 菜单不再出现完整 diagnostics 和 Independent LLM。
5. 从 Tools 打开 LLM Playground；验证 endpoint、model、可选 API key、images 字段全部保留。
6. 返回 ACP 会话后原会话不变；重新进入 Playground 不保留 API key 或内存会话。

## 9. 实现约束

- 不删除任何当前 capability；入口迁移前先建立共享 command/action descriptor，再替换各表面调用。
- 持久化应用设置与即时会话设置必须有不同的作用域标题和提交模型。
- capability gating 继续由 Controller/Agent advertised capabilities 驱动，不能仅靠视觉隐藏。
- 工作区、会话、Agent 的 identity 继续包含各自现有的路径、session id、persistence identity；导航重构不改变恢复匹配语义。
- 窄窗口继续用现有 compact sheet 承载 Workspaces/Context；重构后同一入口在宽窄布局中名称、内容和作用域一致。
- 截图和 widget 验收 fixture 使用应用自持 Controller 覆盖完整生产配置路径；注入 Controller 的只读模式另列为受限状态用例。
- 中英文术语统一。建议产品界面统一使用中文或英文；若暂时保持双语，至少统一 `Workspace/项目`、`Session/会话/Conversation`、`Agent/代理` 三组核心对象，不在同一菜单交替使用。

## 10. 本次审计读取的主要代码

- `lib/ui/shell/app_shell.dart`
- `lib/ui/shell/macos_workspace_layout.dart`
- `lib/ui/components/agent_toolbar.dart`
- `lib/ui/components/workspace_sidebar.dart`
- `lib/ui/components/workspace_inspector.dart`
- `lib/ui/components/new_session_agent_dialog.dart`
- `lib/ui/components/resume_session_dialog.dart`
- `lib/ui/components/session_settings_dialog.dart`
- `lib/ui/components/agent_config_dialog.dart`
- `lib/ui/components/agent_discovery_dialog.dart`
- `lib/ui/components/activity_diagnostics_dialog.dart`
- `lib/ui/components/session_activity_view.dart`
- `lib/ui/components/permission_history_view.dart`
- `lib/ui/components/runtime_inventory_view.dart`
- `lib/config/acp_client_config.dart`
- `lib/state/chat_controller.dart`
- `lib/app.dart`
- `packages/ianvs_agent_chat/lib/llm_chat_panel.dart`
