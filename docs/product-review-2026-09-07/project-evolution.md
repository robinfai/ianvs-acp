# 项目演进与产品方向复盘

日期：2026-09-07
范围：`main` 当前提交 `322cc03`，并检查 `git log --all` 的全历史、README、`docs/`、`artifacts/team-review-2026-08-09/team-review.md`。本报告只读源码和 Git 历史，不作实时竞品判断，也没有上网。

文中“事实”均附当前文件行号或 commit；“建议”单独标注。提交日期和主题来自 `git log --all --date=short`，提交本身是比提交说明更强的历史依据。

## 现在是什么产品

### 事实：当前主线能力

README 将产品定义为 macOS Flutter 桌面端的本地 ACP agent 客户端，核心动作是启动本地 stdio agent、创建/恢复会话、流式显示 prompt、plan、tool call，并处理认证、权限、文件系统和终端回调（`README.md:1-10`）。当前会话工作流包括：

- 用户从侧栏显式添加和保留 Workspace；应用启动和展开 Workspace 不会扫描全部会话，只有用户进入 `Resume Session` 后才查询会话目录（`README.md:29-33`；`docs/conversation_loading_architecture.md:29-48`）。
- 会话可以创建、列出、恢复、关闭、删除、置顶、改名、归档、跨窗口打开；多个会话可同时存在，取消和权限决定按 session 隔离。能力文档还声称 fork，但当前生产 `RustAcpAgentClient.forkSession` 明确 unsupported（`lib/acp/rust_acp_agent_client.dart:590`），故不计为交付（`docs/product_capabilities.md:9-31`；`README.md:22-27`）。
- Prompt 支持按 ACP 协商能力发送文本、文件、图片、音频和资源链接；模式、select/boolean 配置也可调整（`README.md:5-10`；`docs/product_capabilities.md:16-28`）。
- 新会话可用版本化模板选择 agent、MCP 集合、Workspace roots、权限策略、assistant enhancer、mode、model 和 reasoning effort；`Session Activity` 和 `Runtime Inventory` 提供活动轨迹、运行时配方、能力降级和模板漂移信息（`README.md:17-20,148-160`）。
- 文件系统和终端 provider 默认受配置开关控制并限制在 Workspace；MCP 支持稳定的 stdio、HTTP、SSE 配置，并可用一个配置的 MCP 工具做权限 sidecar reviewer（`docs/product_capabilities.md:33-49`）。
- 本地恢复由 ACP session registry、版本化 transcript cache 和 `workspace_ui_state.json` 组成；前两者受容量/保留期约束，Workspace UI 状态单独保存（`docs/sqlite_storage.md:5-30`；`docs/runtime_architecture.md:65-76`）。
- Rust Core 是唯一的生产协议和进程权威，Flutter 负责导航、Workspace/session projection 和交互，FFI 只暴露 typed operation/event（`docs/runtime_architecture.md:5-38`）。

当前内置 agent 发现已覆盖 Codex、Pi、Cursor 和 CodeBuddy，但仍要求本地 CLI/adapter 可用并由用户管理凭据（`README.md:55-73`；commit `4a1f2b3`, 2026-08-10）。

### 事实：明确边界

生产 ACP agent transport 只有本地 stdio；远程 WebSocket/HTTP/SSE ACP agent、unstable MCP-over-ACP、Flutter 直接发 raw JSON-RPC 以及第二条兼容 runtime 都被列为 unavailable（`docs/product_capabilities.md:51-56`；`docs/acp_runtime_coverage.md:9-22`；`README.md:311-315`）。这里的 HTTP/SSE MCP server 配置仍受支持（`README.md:179-183`），文档中应始终写清是“远程 ACP agent”还是“MCP server”，避免读者把两者混为一谈。

## 阶段时间线与方向变化

| 阶段 | 代表提交 | 从历史可确认的产品动作 | 方向含义 |
| --- | --- | --- | --- |
| 2026-05-28 | `8337f6d` | 初始 ACP client desktop app；已经包含 Dart ACP client、会话控制器和聊天时间线。 | 从“协议客户端原型”起步。 |
| 2026-05-29—05-31 | `c1ac481`, `ea735d0`, `8a2c31f`, `a5f6c72`, `367770d`, `898603b`, `cfae45a` | 加入会话恢复/fork、MCP 配置、权限审批、附件、WebSocket 与 streamable HTTP ACP transport 等协议面。 | 一度追求较宽的 ACP 兼容层和能力覆盖。 |
| 2026-06-01—06-05 | `09b62cc`, `1e1df62`, `b3b82ab`；设计评审 `docs/design-audit-2026-06-05/report.md:38-45` | 增加 cwd/usage、配置存储与 GUI 配置编辑，建立新建/恢复/设置/能力/权限/错误/窄窗口的桌面工作流。 | 从协议 demo 走向可配置的桌面工作台。 |
| 2026-06-10—06-12 | `e7e411f`, `96575ed`, `ef01583`, `5452608`, `a4161e6`, `d6d349e` | 设计并实现 local memory engine：SQLite/vector search、抽取、候选 review、MCP/sidecar、scope 与维护流程均进入历史。 | 曾试图把产品扩展成带长期记忆的 agent 工作空间。 |
| 2026-06-16—06-18 | `b162a14`, `ac3fbc2`, `229d7d9` | 加入 local task center、MCP host、任务 board 和 restricted task-center agents。 | 又向任务管理/多 agent 协作平台扩展。 |
| 2026-06-24—07-09 | `34cdfed`, `53d755c`, `bb47ad1`, `c559c1b`, `265dbb9`, `41e222c` | 增加 Pi 发现、Mermaid、Workspace sidebar/session index、task inbox、workspace-aware merging 和 local workflow runtime。 | Workspace 壳层成为统一入口，但任务自动化仍在产品边界内。 |
| 2026-07-10—07-22 | `ff707a4`, `e00c34e`, `570a151`, `3b8c9fc`, `9fd7175` | 对 task persistence、调度、权限、egress、输入/输出预算、超时和 session/workspace binding 做大批 remediation；最终移除旧 Dart ACP runtime，Rust Core/FFI 成为唯一生产实现。 | 研发重心从“扩功能”转为安全、边界、可恢复性和单一 runtime 权威。 |
| 2026-07-26（旁支） | `e36d212` | `origin/agent/linux-workflow-automation` 增加 Linux runner、Linux secret service 和 workflow automation。该提交不在当前 `main` 的祖先链，当前树也没有 `linux/` 或 `linux.yml`。 | 多平台/Workflow 曾有独立方向，但没有落入当前主线；当前 README 只承诺 macOS（`README.md:1-3`）。 |
| 2026-07-29 | `042cb3f`, `03b9ab8`, `15a04cf`, `9685543` | reviewed local memory engine 合入主线，并继续补 episodic memory、backup transfer、quality workflow。 | 记忆方向曾达到“实现完成”的阶段。 |
| 2026-08-07—08-09 | `6a96a56`, `b490fa2`, `ffa2c92`, `6663443` | 删除 local memory；删除 Inbox/Task runtime；转为 Workspace-only runtime/recovery；重做 ACP conversation UI 和 permission flow。 | 发生明确的产品收缩：回到本地 ACP 会话客户端。 |
| 2026-08-10—08-12 | `4a1f2b3`, `1b6389f`, `9001e98`, `437a534`, `bcbe280`, `a890c51`, `4c3b9b2` | 接入 Cursor/CodeBuddy 发现，优化恢复加载，统一主题，加入 session-scoped bottom terminal，重做 macOS shell/window chrome，并继续修 runtime/file preview。 | 在收缩后的核心上强化多 agent 接入、恢复体验、终端和桌面质感。 |
| 2026-08-20—08-21 | `c306214`, `e9a7b2d`, `fe166cf` | 大量 session-scoped client、持久化/隐私稳定性、`Session Activity`、`Runtime Inventory` 和恢复对话框重构；随后修复恢复 transition key。 | 核心价值变成“可恢复、可解释、可控的工作区会话”。 |
| 2026-09-02—09-07 | `b329d7b`, `994ea3e`, `d2bebb5`, `a2c18a5`, `322cc03` | 加入 Makefile/验证入口，改为显式 Workspace/session discovery，改进 agent config/resume，按 Codex 风格重排 shell，增加原生 macOS View 菜单、侧栏调整、Context/terminal 入口。 | 近期集中做 macOS 工作台收敛和可交付验收。 |

## 曾新增、后来删除或收回的功能

### Local memory：实现规模大，后来整层移除

事实是，6 月 10 日起连续提交把记忆做成独立产品层：设计和实施计划分别由 `e7e411f`、`96575ed` 建立，`ef01583` 建 daemon，`3890bed` 做手工 CRUD，`5452608` 做候选 review，`a4161e6` 接入抽取和 vector search；`042cb3f`（2026-07-29）把 reviewed engine 合入主线。随后 `6a96a56`（2026-08-07，`Remove local memory subsystem`）删除 `memory-core`、`lib/memory`、memory explorer/review UI 及相应测试，提交统计为 110 个文件、删除 41,673 行；同时 README、配置和存储说明被改回 ACP recovery 语义。

结论是“曾经实现过”而非“当前能力”：当前产品能力清单只列 Workspace/session、human decisions、providers/MCP，未列 memory（`docs/product_capabilities.md:9-56`）；当前仓库主线也不存在 `memory-core/` 和 `lib/memory/`。不应在现行产品介绍或路线中把 memory 当作隐含承诺。

### Inbox/Task/Workflow：从任务平台收缩回会话客户端

事实是，`b162a14`/`ac3fbc2`/`229d7d9` 加入 task center 和受限 task agents，`265dbb9` 加入 task inbox，`41e222c` 加入 local workflow runtime；`bd80884`（2026-07-19）还把 ACP、Inbox automation、Rust scheduler、durable workflow 和 `ianvs-acpd` 扩大到 125 个文件、增加 30,381 行。`570a151`（2026-07-22）继续实现 runtime roadmap PR1–PR8。

`b490fa2`（2026-08-09，`Remove Inbox and Task runtime`）删除 `lib/tasks`、task editor/sidebar、Rust workflow/task inbox、`ianvs-acpd` daemon 及 Inbox 原型/评审材料；提交统计为 107 个文件、约删除 59,881 行（以 `git diff --numstat b490fa2^ b490fa2` 汇总为准）。之后的当前能力文档不再宣称持久任务调度、任务重试或后台 workflow；普通会话内仍有待发 prompt 队列与停止后优先发送的 Guide（`lib/state/chat_controller.dart:4422-4476`），两者应区别（`docs/product_capabilities.md:9-56`），README 也只描述 ACP 会话（`README.md:1-33`）。

这次不是单个入口隐藏，而是执行模型的删除。收缩后的架构明确“一个 Rust ACP authority”，并把 Flutter 限定为交互和 projection（`docs/runtime_architecture.md:27-38`）。因此后续路线若再次引入后台任务，必须先说明它是否会重新引入第二个产品模型、持久调度器和独立运维成本。

### ACP transport/runtime：从广泛兼容回到单一 Rust 本地路径

5 月 31 日历史上曾加入 WebSocket ACP transport（`367770d`）和 streamable HTTP ACP transport（`898603b`），并在 UI/配置中支持远程 agent URL。`9fd7175`（2026-07-19，`Remove legacy Dart ACP runtime`）删除 Dart ACP runtime、WebSocket/HTTP ACP transport、第三方 `dart_acp` 和大量协议/预算测试，改为 Rust Core；随后现行文档将远程 agent 明确列为 unavailable（`docs/acp_runtime_coverage.md:9-22`；`docs/manual_followups.md:9-23`）。

这与“稳定 HTTP/SSE MCP server 可配置”并不矛盾：前者是 agent transport，后者是会话所用的 MCP provider（`README.md:179-183`）。但产品文案应保持区分，否则用户会以为已支持远程 ACP agent。

### Workspace discovery：从合并/扫描倾向改为显式用户选择

`265dbb9` 的主题是“task inbox and workspace-aware session merging”，历史实现曾把 Workspace 与会话目录合并处理。`994ea3e`（2026-09-04）删除启动/配置变更/侧栏展开时的自动 session catalog discovery，并把规则写入 README 与三份运行时文档；当前语义是只保留用户显式添加的 Workspace，恢复时由用户在 Resume 流程选择会话（`README.md:29-33`；`docs/conversation_loading_architecture.md:37-48`）。

这是从“自动帮用户发现一切”转向“可预测、隐私和边界优先”的收敛，应作为当前产品原则，而不是实现细节。

## 近期建设重心

### 事实：主线最近的投入

1. Rust 单一权威、生命周期和安全边界：`c306214` 大幅增加 session-scoped client、配置/隐私稳定性、runtime inventory/activity 及测试；当前架构文档确认 Rust 负责 protocol、process、permission、workspace boundary 和 recovery（`docs/runtime_architecture.md:5-38`）。
2. 恢复和加载性能：`35c1ff5` 把 conversation loading projection 移到 Rust，`1b6389f` 优化无缓存 replay；架构文档记录首次完整可见约 36.7 秒、同版本缓存约 2.2 秒，缓存命中可见时间约缩短 94%（`docs/conversation_loading_architecture.md:165-178`）。
3. macOS 原生工作台：`bcbe280`、`a2c18a5`、`322cc03` 逐步重做 shell、侧栏、Context inspector、工具栏、终端和 native View menu。9 月 7 日验收记录确认侧栏切换、原生菜单快捷键、窗口调整、Context 对话框、终端面板、Agent 设置可操作（`docs/macos-ui-refactor-2026-09-07/acceptance.md:13-39`）。
4. 可见信息架构和恢复入口：`e9a7b2d` 重构 Resume dialog，`d2bebb5` 继续调整 config/resume，`994ea3e` 收掉自动 discovery；这使 Workspace、会话恢复、模板和运行时上下文成为主要产品叙事。
5. 交付与验证：`b329d7b` 引入 Makefile；当前 README 将 `make verify`、`verify-macos`、签名/公证和 Rust/Flutter 边界验证写成开发路径（`README.md:246-309`）。

### 历史记录：设计评审曾提出的体验问题

8 月团队评审给出约 7.0/10、有条件通过（`artifacts/team-review-2026-08-09/team-review.md:19-25`）。证据中最重要的体验问题是：空态缺少显式主行动（R2，`team-review.md:53-59`）、启动错误缺少直接恢复动作（R3，`team-review.md:61-67`）、窄窗口侧栏和 Context 缺少明确替代入口（R4，`team-review.md:69-76`）、模态密度不统一（R5，`team-review.md:78-85`）、权限决策控件拥挤（R6，`team-review.md:87-94`），以及主对话仍偏卡片化（R8，`team-review.md:104-110`）。

9 月验收已经直接覆盖了侧栏/Context 的响应式入口、原生菜单和终端，说明 R4 的实现方向已有落地证据（`docs/macos-ui-refactor-2026-09-07/acceptance.md:15-39`）。当前源码也已给错误横幅接入 Open config、Retry、Copy diagnostics（`lib/ui/shell/app_shell.dart:273-296`；`lib/ui/components/error_banner.dart:112-151`），因此不能继续把 R3 表述为“没有恢复按钮”。不过本轮没有重做真实交互，不能证明 R2、R3、R6、R8 已全部完成体验验收；团队评审本身也强调截图不能证明完整无障碍，需要真实 macOS 键盘、VoiceOver、缩放和长文案测试（`team-review.md:122-133`）。

## 文档之间的矛盾、时效和解释

### 事实：版本日期滞后

`docs/product_capabilities.md`、`docs/runtime_architecture.md`、`docs/acp_runtime_coverage.md` 和 `docs/manual_followups.md` 都标为 2026-08-19 左右（各文件头部），而 `docs/sqlite_storage.md` 已到 2026-09-02，macOS 验收是 2026-09-07。截至 9 月当前主线已经有 Cursor/CodeBuddy、模板、Activity/Inventory、显式 discovery 和 macOS native navigation 等变化（`README.md:55-73,128-160,289-315`；commits `4a1f2b3`, `c306214`, `994ea3e`, `322cc03`），但这些变化没有统一回写所有文档。建议逐条按当前实现修正文档；仅统一日期不能解决内容滞后，仍作为现状规范使用的文件不应简单标成历史而失去维护。

### 事实：Workflow 语义已从当前能力文档消失，但旧历史仍可见

7 月版 `docs/product_capabilities.md` 曾明确写 Task Inbox 的 scheduling、priority、retry、quota、workspace lease（可由 `git show 9fd7175^:docs/product_capabilities.md:22-35` 复核）；当前文件的 human decisions 只有权限、文件系统和终端（`docs/product_capabilities.md:33-40`）。这不是当前实现与当前文档的冲突，而是历史文档/当前文档容易被并读造成的冲突。建议在旧计划和评审材料顶部写“已删除，勿视为当前能力”。

### 事实：不同评审对空态的判断不同，原因是时间点/证据不同

6 月设计审计称空状态“给出清楚的启动动作”（`docs/design-audit-2026-06-05/report.md:47-53`），8 月三方评审则指出中心文案附近没有显式 `New session`/`Start session` 按钮（`team-review.md:53-59`）。两者不能直接取其一作为现状结论：前者评的是早期截图和实现，后者评的是 8 月联系表；9 月验收没有对空态主按钮作专项结论。建议补一次以当前 `main` 构建、真实字体和真实 macOS 窗口为基线的空态验收。

### 事实：6 月/8 月评审问题与 9 月修复记录没有闭环表

团队评审明确要求重新验证字体/图标截图链路（`team-review.md:44-51`），并提出错误恢复、权限视觉、对话卡片层级等建议（`team-review.md:61-110`）；9 月验收记录主要证明 shell、导航、Context、终端和设置操作（`acceptance.md:23-46`）。因此不能仅凭“最新 UI 已验收”推断全部评审问题关闭。建议增加 issue-to-commit-to-evidence 表，逐项标记“已修复/部分覆盖/未复验”。

### 事实：当前边界与历史远程实现需要更强的术语区分

当前文档同时出现“Remote MCP servers 可用”（`README.md:179-183`）和“Remote ACP transports unavailable”（`README.md:311-314`）。技术上前者是 MCP server provider、后者是 ACP agent transport；建议在 README 首次出现时改成“远程 MCP provider 可用；远程 ACP agent 连接不可用”，减少产品承诺误读。

## 三种产品定位选择与取舍

以下是基于提交轨迹和当前能力的产品选择，不是市场份额或竞品结论。每个选项都需要真实用户验证；提交数量只能说明研发投入，不能说明用户需求。

### 选择 A：Workspace-first 的本地 ACP 桌面客户端（推荐作为近期主定位）

定位句：让开发者在本机按项目组织多个 ACP agent 会话，快速恢复、查看执行过程、审慎处理权限，并保持工作区边界清楚。

事实基础：当前 README、能力清单和 Runtime architecture 都围绕 Workspace/session、Rust Core、权限、附件、恢复与本地 stdio 展开（`README.md:1-33,289-315`；`docs/product_capabilities.md:9-49`；`docs/runtime_architecture.md:40-76`）；近期提交集中在恢复性能、显式 discovery 和 macOS shell（`35c1ff5`, `1b6389f`, `994ea3e`, `322cc03`）。

取舍：

- 得到清晰的 MVP 边界，可复用现有 Rust authority、缓存、Workspace 和 macOS 验收资产。
- 能把最有辨识度的价值放在“多会话、可恢复、可解释、权限透明”，而不是继续堆叠后台系统。
- 放弃 Inbox、长期 memory、远程 ACP agent 和跨平台承诺；高级自动化交给 agent/MCP provider，产品本身保持桌面会话客户端。

### 选择 B：本地 Agent 控制台/安全运行面

定位句：为本地 agent 提供可审计的权限、Workspace jail、终端、附件和 runtime inventory 控制面。

事实基础：Rust 负责 workspace boundaries、filesystem/terminal callbacks、permission settlement、budgets 和 recovery（`docs/runtime_architecture.md:27-38`；`docs/acp_runtime_coverage.md:24-42`）；README 已有 Keychain、review agent、Session Activity 和 Runtime Inventory（`README.md:47-53,157-161,194-200`）。

取舍：

- 可把已有安全/可恢复工程优势变成核心价值，减少与一般聊天窗口比较阅读体验的压力。
- 需要补齐 durable permission audit、组织策略、策略导出、失败诊断和真实 agent interoperability；这些在 `docs/manual_followups.md:33-39,57-67` 仍是未决或环境验证项。
- 产品叙事会更偏“控制面/安全工具”，上手门槛和配置负担高于选择 A；必须验证用户是否愿意为可审计性付出设置成本。

### 选择 C：多 agent 工作流/自动化平台

定位句：把 ACP agent 组合成可排队、可重试、可后台运行的项目任务系统，并用 memory 持续积累上下文。

事实基础：该方向确实有完整历史投入：local memory 从 `e7e411f` 到 `042cb3f`，Task/Inbox/Workflow 从 `b162a14` 到 `570a151`/`bd80884`；但 `6a96a56` 和 `b490fa2` 分别删除 memory 与 Inbox/Task，当前能力清单不再包含它们（`docs/product_capabilities.md:9-56`）。

取舍：

- 若用户确实需要无人值守任务、队列、重试和跨会话记忆，长期上限最高，也能复用历史设计资产。
- 代价是重新引入已删除的第二产品模型、scheduler/daemon/persistence、权限与恢复复杂度；必须重新定义任务与会话的所有权，避免回到 7 月的大范围 remediation。
- 在没有遥测、留存、任务完成率、后台运行频率或用户访谈证据时，不能证明这是需求；不建议现在以 C 作为默认定位。

建议的决策顺序是先以 A 作为公开产品叙事，同时把 B 的审计/权限能力作为可验证差异化层；只有获得明确的真实使用证据后，才重新启动 C 的最小任务试验，且先验证一个任务队列场景，不恢复整套 memory + Workflow。

## 精简与后续调整建议

以下为建议，不是当前事实：

1. 把一句产品承诺固定为“本地 Workspace + ACP sessions”；README、Product capabilities、Runtime architecture 和 Manual follow-ups 同步这句，并显式标注删除的 Inbox/Task/Memory 只存在于历史。
2. 用一张“当前能力 / 计划 / 明确不支持 / 已删除”表替代跨文件重复清单。当前能力至少保留 Workspace/session、local stdio agents、MCP providers、权限、终端、恢复和 macOS shell；远程 ACP、MCP-over-ACP、后台 Workflow 和长期 memory 放入边界或历史。
3. 先完成评审闭环再扩面：为 R2/R3/R4/R6/R8 各绑定一个当前 commit、一个真实 macOS 验收动作和一个截图/AX 证据；未覆盖的不要标记为 done。依据 `team-review.md:44-110` 和 `docs/macos-ui-refactor-2026-09-07/acceptance.md:23-46`。
4. 优先把“恢复可靠性”和“权限可解释性”做成两条可度量的质量线：缓存命中可见时间、恢复失败回滚、权限请求决策时间/误操作、错误恢复成功率。当前代码已有 session load metrics（`docs/conversation_loading_architecture.md:140-151`），但这些是内部技术指标，不能当作用户需求证据。
5. 暂缓新增产品面：远程 ACP、长期 memory、任务队列、多平台打包、复杂 Registry 发现都应等待产品选择和真实证据；`docs/manual_followups.md:9-55` 已列出远程 transport、unstable features、Registry 和 terminal 的决策边界。
6. 保留 MCP 和多 agent adapter 的开放性，但把“可接入”与“产品主流程”分开：Cursor/CodeBuddy/Pi 是接入覆盖，主流程仍是 Workspace/session/permission/recovery（`README.md:55-73`；`docs/product_capabilities.md:9-40`）。

## 证据限制与需求结论

本次检查没有发现用户遥测、留存、激活、任务完成率或真实用户反馈数据；搜索到的 `retention_days` 是本地恢复数据的保留策略，不是用户留存指标（`README.md:163-175`；`docs/sqlite_storage.md:14-30`）。因此：

- Git 中大量提交只能证明某段时间的研发投入和方向尝试，不能证明对应功能有需求、被使用或应该恢复。
- 设计评审和 macOS 验收能证明截图/交互在给定场景下的可见行为，不能证明真实用户能发现、理解并持续使用。
- 三种定位的取舍需要用真实用户访谈、首个成功会话、恢复成功率、权限决策和重复使用数据验证；在没有这些数据前，不应把产品定位写成市场事实。
