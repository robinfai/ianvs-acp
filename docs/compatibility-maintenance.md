# 兼容处理与清理维护方案

Updated: 2026-09-09

本记录承接[上一轮清理验收](cleanup-acceptance-2026-09-09.md)，区分本次已清理内容、仍有必要的处理，以及需要先收缩契约才能退役的分支。当前产品事实以[产品能力](product_capabilities.md)和[运行时架构](runtime_architecture.md)为准。

## 本次实施

- Rust Dart 适配器恢复会话只通过必填的 `onEvent` 投递历史，返回 `AcpSessionRestoreSummary`。删除无人使用的事件列表返回值、列表缓存、无 observer 时的缓存分支，以及跨请求共享的 `_lastRestoreReplayedHistory`。摘要在对应请求完成时生成，保留重复恢复保护、失败清理和流式计数。
- 清理 `mode_changed` 中的 `currentModeId` 字段兜底。当前 ABI v10 的 Rust 控制事件统一产生 `modeId`；会话初始化 `modes.currentModeId` 不变。
- 删除 `WorkspaceInspector.onConfigOptionSelected`、Agent 工具栏的 `onShowDiagnostics` 和不可触发的菜单分支。Inspector 继续打开完整会话参数；侧栏诊断入口保留。
- 工具栏、侧栏及 AppShell 统一使用 `SessionActionAvailability`，删除重复的 `canForkSession` 参数和 OR/fallback 拼接；宿主仍负责计算实际能力。
- 删除无引用的 `DotGridBackground`、`AcpUtf8LineBudgetCheckpoint` 和 `AcpImageDecodeReservation` 宿主别名。共享包的原类型和公开路径不变。
- 根 `desktop_drop` 直接使用仅在测试中，移到 `dev_dependencies`；锁定版本保持 0.7.1。共享包仍将它作为运行依赖。清理根 pubspec/analyzer 的初始化模板说明，保留 Merman/CocoaPods 的必要注释。
- README 按当前设置、诊断和 LLM 菜单更新入口；手工发布清单改为三工程 `make verify`；文档测试保留链接和禁止旧 Dart ACP 运行时回流的约束，删除固定日期、标题列表和整句文案断言。
- 旧设置设计文档标记后继规格；superpowers 历史方案标明原始基线，不再携带重新执行计划的 Agent 指令。历史截图、测试成绩和原计划条目作为记录保留，未冒充本次验收。

## 仍有用途，继续保留

### 1. Keychain 秘密处理与事务回滚

**原因：** [AcpConfigSecretMigrator](../lib/config/acp_config_secret_migrator.dart) 不只是旧文件升级脚本。当前 GUI 保存、配置加载和发现写入也用它解析引用、保存新秘密、更新身份和回滚失败写入；直接删除会破坏现行保存链路。旧明文配置仍可能从备份恢复。

**后续：** 先将持续使用的“秘密准备/提交”与一次性“旧格式导入”明确分层或改名，保留现有事务边界。若将来退役明文导入，应提供显式导入工具和支持版本说明；正常保存的 Keychain 写入、缺失引用报错和回滚不能一并退役。

**验收：** `test/config/acp_config_secret_migrator_test.dart`、`acp_config_store_test.dart`、`secret_store_test.dart`，再完成签名应用的真实 Keychain 保存、缺失项和失败回滚验证。迁移完成必须可从磁盘状态判断，不能依赖“运行过某版”的假设。

### 2. Agent 持久身份和旧名称映射

**原因：** [运行时启动迁移](../rust/crates/ianvs-acp-core/src/runtime.rs) 的 `migrate_agent_identity` 让旧名称下的会话归入稳定身份；[配置引用更新](../lib/config/config_reference_updates.dart) 在当前重命名操作中仍维护关联。只删除别名会让既有会话、模板或引用无法定位。

**后续：** 新写入持续使用稳定 ID。只有在设置、Rust registry、侧栏索引及可导入旧备份都具备明确版本和迁移入口后，才把旧名称查询缩到迁移边界。区分读取旧显示名的升级逻辑与当前重命名所需的引用更新。

**验收：** 配置重命名测试、workspace/sidebar 存储测试、Rust `session_persistence_core` 和 `runtime_e2e`；验证重命名后创建、恢复、关闭和多窗口读取，且没有跨 Agent 误关联。

### 3. MCP 传输限制及权限失败回人工

**原因：** [MCP reviewer](../lib/acp/acp_permission_reviewer.dart) 仍直接使用有界 stdio 和禁止重定向的 HTTP 传输。它们约束请求/响应大小、超时、进程与凭据边界，并非已移除的远程 ACP 实现。reviewer 失败回人工是当前交互语义。

**后续：** 可以统一预算配置或替换底层 MCP 实现，但替代实现必须先覆盖相同约束。不要因为主 Agent 只走本地 stdio 就删除 reviewer 的 HTTP/SSE 能力，也不要把失败回人工改为自动允许。

**验收：** `bounded_mcp_stdio_transport_test.dart`、`no_redirect_mcp_http_transport_test.dart`、`acp_permission_reviewer_test.dart`；覆盖超限、重定向、慢响应、取消和进程退出。

### 4. 协商能力与展示降级

**原因：** 模型/模式回退、附件 resource-link 回退、缺失字段显示及有界预览都有当前消费者。Agent 的可选能力不同，这些判断与旧版本兼容代码不是同一类。已有事件也不能假定总带会话无关的 stderr 身份。

**后续：** 将降级原因集中在能力解析和诊断层；只在客户端明确提高最低协议/Agent 支持要求后删除对应分支。保持 `session/list` 元数据、available commands 与实时 usage/session-info 的区别。

**验收：** capability/prompt policy 测试、会话设置及附件测试、Rust 适配器测试，以及支持的真实 Agent 创建、发送、恢复流程。

### 5. Merman 原生修正和根直接依赖

**原因：** lockfile 仍固定 Merman 0.7.0，主应用与独立 example 的 CocoaPods 和动态库修正脚本仍是现行打包方案。根 Dart 虽无直接 import，不能据此证明可以删除原生集成。

**后续：** 两个动作分开处理：先尝试仅移除根 `merman` 声明，由聊天包提供传递依赖，验证生成插件列表和 bundle 后再落地；另行评估 Merman 升级，只有新版本实际不再需要修正时才删除脚本/SPM 禁用配置。无需为了清理而升级第三方库。

**验收：** 根和 example 各自重新解析依赖、构建 macOS 应用；运行 `make verify-macos`，实际打开包含 Mermaid 的页面。检查 dylib 路径、双架构与签名闭包；仅 `flutter analyze` 通过不足以移除原生修正。

### 6. 仍有消费者的 Acp 类型桥接与包公开接口

**原因：** `AcpInputBudget`、权限和会话设置别名仍被宿主广泛使用，桥接只有一份业务实现。共享包通过公开 barrel 导出的类型和 `MermaidExamplePage` 可能被其他宿主引用，仓库内无调用不代表可删除。

**后续：** 宿主按模块逐步迁到中立 `Chat*` 类型，某个别名全仓无消费者后再删除。共享包的公开路径或导出变更需独立弃用和版本迁移，不与宿主清理混在一起。

**验收：** 应用、包和 example 的分析/测试；公开入口调整还需独立宿主导入检查。无需为删除宿主别名复制测试或更改共享类型语义。

## 需要先完成迁移或明确产品边界的候选

### 7. 配置拼写别名和未知字段保留

**原因：** [配置解析](../lib/config/acp_client_config.dart) 与[保存合并](../lib/config/acp_config_store.dart) 仍接收 snake_case/camelCase 等形式，且保护不由 GUI 管理的模板和扩展字段。旧文件来源和使用比例未知，直接收紧会让整份配置加载失败。

**后续：** 引入明确的配置格式版本和单一读取归一化层；检查别名冲突后转为规范内部形态，新保存写规范字段。迁移需要原子写入、失败回滚和导入旧备份路径。未知字段保留与已知字段别名应分开处理，不能靠删除未知字段实现规范化。

**退役条件：** 旧拼写只出现在版本化导入器，所有生产消费者只读取规范模型；旧文件、重复别名、秘密引用和未来字段的往返测试通过。保留当前版本兼容直到迁移落地。

### 8. 已保存的远程 ACP / MCP-over-ACP 配置

**原因：** 生产运行时不支持这些类型，但已有配置允许继续查看、改名和保存；直接从 parser 删类型会阻止用户修改其他有效连接。

**后续：** 继续禁止新建不可运行类型，显示不可用原因。若确定永久退役，可将旧条目导入为保留原始数据的只读记录，提供显式转换/移除操作；若未来实现，则先建立 Rust 命令、能力与测试，再开放创建入口。

**退役条件：** 不可用条目不会破坏有效配置加载和保存，原字段与秘密引用不静默丢失；通过 `acp_client_config_test.dart`、`agent_config_dialog_test.dart` 的旧类型和别名往返回归。

### 9. 非并发客户端兼容

**原因：** 生产 `RustAcpAgentClient` 支持会话并发；Fake 和注入客户端仍可只支持全局取消。`_blockedByBusyLegacyRuntime` 目前保护这些实现。直接删除保护，却保留 `cancelSession → cancel()`，可能取消其他会话。

**后续：** 先让内部客户端契约强制会话定向取消，并改造 Fake 的并发提示/取消实现；明确是否继续支持非并发注入客户端。若保留，把单会话适配限制封装在适配器中；若退役，再删除 app 中旧分支与专用 legacy 测试。

**退役条件：** 不存在可以工作但只支持全局取消的注入实现；并发会话、模板 recipe 隔离、权限路由、关闭和取消测试通过。仍然需要的忙碌保护不能按名称一并删除。

### 10. 协议 session/fork 整条实现链

**原因：** 生产 Rust 客户端不提供 fork，但接口、controller、租约池、Fake 和菜单测试仍表达该能力。删除整链是内部契约收缩，超出无引用参数删除；不能把这条链与 Git worktree 新建空会话混为一谈。

**后续：** 若明确不保留协议 fork，按“菜单动作 → controller → pool/client 接口 → Fake/测试”整组退役，保留 worktree＋空会话路径。若将来实现，必须先在 Rust 有界命令和运行时能力交集中建立支持，再恢复上层入口。

**退役条件：** 所有调用者完成迁移；新建 worktree 不复制原会话历史；普通会话创建、恢复、关闭、删除和权限隔离回归通过。不能只删除不支持的异常，让调用静默成功。

### 11. live usage/session-info 的宿主消费

**原因：** 当前 Rust 不投影这两种通知，但 controller 仍有解析、预算、快照与展示状态，测试和可能的旧缓存仍可包含相关内容。尚未逐版证明持久化输入中不存在这些事件。

**后续：** 先梳理可接受的缓存 schema、存量读取和 UI 消费；若决定退役，允许旧缓存字段被安全忽略或按现有规则失效，再删除活跃解析与状态账本。若保留能力，则先定义 Rust typed projection；不要通过保留 Fake 事件宣称生产已支持。

**退役条件：** 旧缓存可读取或可安全回放恢复；缺失 usage 保持未知，不能填零。保留 `session/list` 标题/时间、available commands、恢复事务和真正的缓存预算限制。

## 验证记录

清理前新增的并发恢复回归复现：第一个请求 `replayHistory: true`，第二个为 `false`，第一个摘要错误返回 `false`。该回归验证请求结果隔离，不依赖被删除的私有实现。

本次 `make verify` 退出码为 0：

| 检查 | 结果 |
| --- | --- |
| `flutter pub get --offline` | 通过；仅 desktop_drop 的根直接依赖归属改变，锁定版本未变；生成插件清单中仍是运行依赖 |
| 恢复适配器、工具栏/侧栏、Inspector、文档定向测试 | 102 通过，包含清理前失败的并发恢复回归 |
| 三工程 format-check / analyze | 全部通过，无分析问题 |
| 发布脚本契约测试 | 通过 |
| Rust workspace / Clippy | 67 项通过，无 Clippy 警告 |
| Flutter/Rust 边界 | 47 项通过；与宿主全量测试有重叠，不重复计入总数 |
| 宿主全量 Flutter | 1,392 通过 |
| 聊天包 Flutter | 283 通过，2 项真实 API 测试按离线策略跳过 |
| 独立 example Flutter | 2 通过 |
| 本地文档链接、无引用残留、`git diff --check` | 通过 |

本轮没有重新进行原生窗口操作、签名应用构建或真实 Agent/Keychain 验收；原生修正、生产凭据处理和协议能力范围未改变。上述保留项将来发生实质变更时，仍需执行各项所列的原生或真实服务验收。

此前文档里的测试数量仅对应各自历史基线。本次保留原工作树中已有的会话加载改动，不修改用户配置、Keychain、会话数据库或工作区数据。原有改动中除 AppShell 和 app 的已列出参数清理外，其余文件与开始时逐字节一致。
