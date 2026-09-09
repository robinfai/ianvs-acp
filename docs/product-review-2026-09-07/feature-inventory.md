# 当前功能逐项盘点与取舍

基线：2026-09-07，`322cc03`。这是源码、生产接线和历史记录评估，不是本轮真实 Agent、桌面交互或视觉验收。引用的 `文件:行号` 相对于仓库根目录。实现状态与产品价值分开判断；“高/中/低”价值以本地项目 Coding Agent 工作台为假设，不代表已有用户使用数据。

状态：**实现**＝生产代码有相应路径；**条件**＝还依赖 Agent 能力/配置/外部工具；**部分**＝关键生产链路缺失；**无**＝未实现、拒绝执行或仅演示支架。成本为相对维护判断，含测试组合和依赖成本，不是工时估计。

## 工作区与会话

| ID | 功能与实际边界 | 状态 | 价值 / 成本 | 建议及原因 | 证据 |
|---|---|---|---|---|---|
| F01 | 显式添加工作区，目录选择；不启动全量会话扫描 | 实现 | 高 / 中 | 保留为导航基础；维持显式发现原则 | `lib/ui/components/workspace_sidebar.dart:371`；`README.md:29` |
| F02 | 工作区搜索、展开折叠、显示更多会话 | 实现 | 高 / 低 | 保留；搜索当前本地投影，不宣称全 Agent 历史全文搜索 | `lib/ui/components/workspace_sidebar.dart:239`、`:324`、`:390`、`:423` |
| F03 | 工作区置顶、显示名重命名、移除与撤销 | 实现 | 中 / 低 | 保留在右键菜单；说明移除导航记录不删除磁盘项目 | `lib/ui/components/workspace_sidebar.dart:433`、`:486`、`:516` |
| F04 | 工作区批量归档会话 | 实现 | 中 / 中 | 下沉“更多”；保留撤销及忙碌会话处理，不与删除合并 | `lib/app.dart:1905` |
| F05 | 在 Finder 打开工作区/会话目录 | 实现 | 中 / 低 | 保留，复用一种“打开项目目录”表述 | `lib/app.dart:1875`；`lib/ui/components/workspace_sidebar.dart:453` |
| F06 | 新建会话、选 Agent、选 cwd、路径补全 | 条件 | 高 / 中 | 保留；默认当前项目和已选 Agent，把变化选项折叠 | `lib/ui/components/new_session_agent_dialog.dart:66`；`lib/state/chat_controller.dart:3052` |
| F07 | 手动 Resume：Agent 分组、目录过滤、搜索、刷新、认证恢复 | 条件 | 高 / 高 | 保留；统一为“恢复其他会话”，与侧栏已知会话切换区分 | `lib/ui/components/resume_session_dialog.dart:194`、`:403`、`:475`、`:501` |
| F08 | 恢复前工作区/附加目录审核，resume/load 回退 | 条件 | 高 / 高 | 保留；缩短呈现但不能跳过目录绑定和能力判断 | `lib/app.dart:1650`；`lib/ui/components/session_workspace_review_dialog.dart:1`；`lib/acp/rust_acp_agent_client.dart:319` |
| F09 | 多会话同时响应，切换不取消其他会话，草稿和权限按会话隔离 | 实现 | 高 / 高 | 核心投入；不以取消所有会话换取实现简单 | `lib/app.dart:1693`；`lib/acp/session_scoped_agent_client.dart:1258`；`README.md:22` |
| F10 | 会话置顶、重命名、标记已读/未读 | 实现 | 中 / 中 | 保留；低频动作留在会话右键菜单 | `lib/app.dart:1845`；`lib/state/chat_controller.dart:3972` |
| F11 | 会话归档与撤销，恢复归档会话 | 实现 | 高 / 中 | 保留为日常整理动作；明确这是本地组织状态 | `lib/app.dart:1865`、`:1648`；`lib/state/chat_controller.dart:3801` |
| F12 | 关闭会话、删除 Agent 持久会话，二次确认 | 条件 | 中 / 高 | 下沉生命周期操作；不要把“关闭/归档/删除”做成同一动作 | `lib/ui/components/session_settings_dialog.dart:123`、`:161`；`lib/acp/rust_acp_agent_client.dart:596` |
| F13 | Open Side Session：同项目新会话 | 实现 | 中 / 低 | 与“在项目中新建会话”合并命名；不包装成协作 Agent | `lib/app.dart:1873`、`:2134` |
| F14 | 会话在新窗口打开 | 实现 | 中 / 中 | 保留为高级操作；不承诺跨窗口同步同一活动进程 | `lib/app.dart:1900`、`:2568`；`macos/Runner/AppDelegate.swift:1` |
| F15 | Copy ID / cwd / Deep Link / Markdown | 实现 | 中 / 低 | 整合“复制”子菜单；Markdown 是本地可取得的消息/信息，不承诺完整历史备份 | `lib/ui/components/workspace_sidebar.dart:1947`；`lib/app.dart:1877`、`:2493` |
| F16 | 外部会话深链、启动参数、目录确认 | 条件 | 中 / 中 | 保留；显式确认、路径约束和配置身份匹配仍必要 | `lib/startup/startup_options.dart:1`；`lib/startup/deep_link_request.dart:1`；`lib/app.dart:2568` |
| F17 | 在项目中创建 Git worktree 并新建空会话，失败回滚 | 条件 | 中 / 高 | 保留在项目高级菜单，先验证真实使用；不是完整 Git 管理器 | `lib/app.dart:2234`、`:2310`；`lib/ui/components/workspace_sidebar.dart:455` |
| F18 | Fork Locally / Fork to New Worktree：复制会话上下文 | 无 | 中 / 高 | 从生产可用清单移除；前端/工作树支架不能替代 Rust fork | `lib/acp/rust_acp_agent_client.dart:590`；`lib/app.dart:2149`、`:2181`；`lib/ui/components/workspace_sidebar.dart:2007` |

## 输入、对话与结果阅读

| ID | 功能与实际边界 | 状态 | 价值 / 成本 | 建议及原因 | 证据 |
|---|---|---|---|---|---|
| F19 | 文本发送、流式回答、停止当前会话、错误/停滞状态 | 实现 | 高 / 高 | 保留，首要质量线是可发、可停、错误可恢复 | `lib/state/chat_controller.dart:4490`；`lib/ui/shell/app_shell.dart:195`；`lib/ui/components/prompt_input.dart:355` |
| F20 | 响应中追加消息排队、移除待发消息 | 实现 | 高 / 中 | 保留轻量会话队列；不恢复已删除的持久后台调度器 | `lib/state/chat_controller.dart:4422`、`:8084`；`lib/ui/components/prompt_input.dart:2030` |
| F21 | Guide：停止当前轮，再优先发送选中队列消息 | 实现 | 中 / 中 | 改用“停止并发送”清楚表达；不是在同一协议 prompt 中实时注入 | `lib/state/chat_controller.dart:4448`、`:4467`；`lib/ui/components/prompt_input.dart:2085` |
| F22 | 输入历史上下键、Enter 提交、粘贴处理、草稿保留 | 实现 | 高 / 中 | 保留；用行为回归保障，不增加设置项 | `lib/ui/components/prompt_input.dart:587`、`:622`；`lib/ui/shell/macos_workspace_layout.dart:1` |
| F23 | `/` 命令建议、搜索、参数提示 | 条件 | 高 / 低 | 保留；仅展示 Agent 当前发布的命令 | `lib/ui/components/prompt_input.dart:255`；`rust/crates/ianvs-acp-core/src/runtime.rs:4457` |
| F24 | 文件选择/拖拽、附件移除与发送方式提示 | 条件 | 高 / 中 | 保留统一附件入口；目录范围和资源预算继续校验 | `lib/ui/components/prompt_input.dart:355`；`lib/acp/prompt_attachment.dart:1`；`lib/ui/shell/app_shell.dart:195` |
| F25 | 图片附件、剪贴板图片、有限解码预览 | 条件 | 高 / 中 | 保留；按当前会话/模型能力判定，不假装所有 Agent 都支持 | `lib/platform/prompt_image_clipboard.dart:1`；`lib/acp/acp_prompt_capability_policy.dart:1`；`lib/ui/image_decode_budget.dart:1` |
| F26 | 音频及其他二进制附件，Embed/Link 回退 | 条件 | 低 / 中 | 保留通用协议路径，弱化专属宣传；当前没有录音/语音对话闭环 | `lib/acp/prompt_attachment.dart:1`；`rust/crates/ianvs-acp-core/src/prompt.rs:1` |
| F27 | 当前模型、推理强度快捷选择 | 条件 | 高 / 中 | 保留输入区快捷入口；设置页为完整选项的同源视图 | `lib/acp/acp_session_settings.dart:158`；`lib/ui/shell/app_shell.dart:219` |
| F28 | 模式切换及通用 select/boolean 参数、未知类型降级 | 条件 | 中 / 中 | 下沉会话设置；不新增每家供应商专属控制台 | `lib/ui/components/session_settings_dialog.dart:88`；`lib/acp/acp_session_settings.dart:22` |
| F29 | 回合组织、执行过程展开收起、回合导航、自动跟随滚动 | 实现 | 高 / 高 | 保留；默认突出结果，避免重复摘要模块 | `lib/ui/components/chat_timeline.dart:132`、`:404`、`:901` |
| F30 | Markdown、代码高亮/复制、富文本复制、外部链接 | 实现 | 高 / 中 | 保留；统一链接打开和复制实现 | `lib/ui/components/chat_timeline.dart:1462`；`lib/ui/components/markdown_code_block.dart:1`；`lib/ui/components/chat_markdown_copy_parser.dart:1` |
| F31 | Mermaid 原生渲染、SVG 规范化及缓存 | 实现 | 中 / 中 | 保留当前渲染器，冻结交互编辑器扩展 | `lib/mermaid/mermaid_view.dart:1`；`lib/mermaid/native_merman_renderer.dart:1`；`lib/mermaid/mermaid_svg_normalizer.dart:1` |
| F32 | 工具调用分组、状态合并、命令/结果/raw 详情、截断提示 | 实现 | 高 / 高 | 保留结果与必要证据；raw 元数据折叠到诊断详情 | `lib/ui/components/chat_timeline.dart:638`、`:2846`；`lib/ui/tool_presentation/tool_presentation_registry.dart:1` |
| F33 | 工具提供的 diff、文件位置及变更展示 | 条件 | 高 / 中 | 保留只读变更阅读；不是仓库完整 diff/暂存/提交工作流 | `lib/ui/components/chat_timeline.dart:852`；`lib/ui/tool_presentation/tool_presentation_registry.dart:1` |
| F34 | Agent plan 及进度状态 | 条件 | 高 / 低 | 保留为对话内进度，避免另立计划管理产品 | `lib/ui/components/chat_timeline.dart:4286`；`rust/crates/ianvs-acp-core/src/runtime.rs:4457` |
| F35 | 内容块：图片/资源/音频元信息、未知内容回退 | 条件 | 中 / 中 | 保留有界通用回退；音频内容卡不等于已支持播放或语音模式 | `lib/ui/components/chat_timeline.dart:3828`、`:4126` |
| F36 | 延迟与 session load 技术指标 | 实现 | 中 / 低 | 保留，放入诊断并服务性能目标 | `lib/state/chat_controller.dart:40`、`:3497`；`lib/ui/components/workspace_inspector.dart:793` |
| F37 | Token/上下文用量显示 | 部分 | 中 / 中 | 先标未知/隐藏无数据值；Rust 投影补齐后才承诺完整用量 | `lib/state/chat_controller.dart:7466`；`rust/crates/ianvs-acp-core/src/runtime.rs:3276`、`:4457` |
| F38 | 会话标题/元信息：目录值、本地 fallback、实时 Agent 更新 | 部分 | 高 / 中 | 保留目录及本地路径；单独补实时更新，不用 AI 标题掩盖缺失 | `lib/state/chat_controller.dart:3766`、`:7445`；`lib/acp/rust_acp_agent_client.dart:1117` |

## 文件与终端

| ID | 功能与实际边界 | 状态 | 价值 / 成本 | 建议及原因 | 证据 |
|---|---|---|---|---|---|
| F39 | 对话文件链接打开本地多标签只读预览 | 实现 | 高 / 中 | 保留结果阅读闭环；不扩展为编辑器/完整文件管理器 | `lib/ui/components/file_preview_workspace.dart:133`、`:222`、`:278` |
| F40 | Markdown 预览/源码切换、front matter、标题目录导航 | 实现 | 中 / 中 | 保留阅读功能；少做装饰性模式和额外渲染分支 | `lib/ui/components/file_preview_workspace.dart:896`、`:1114`、`:1239`；`lib/ui/components/markdown_front_matter_card.dart:1` |
| F41 | 文件内搜索、代码/图片预览、复制路径、Finder/外部应用打开 | 实现 | 高 / 中 | 保留统一文件工具栏；外部打开前的身份重验不可去掉 | `lib/ui/components/file_preview_workspace.dart:407`、`:490`、`:524` |
| F42 | 用户主动打开的本地 shell 面板，多 tab、复制粘贴 | 条件 | 中 / 高 | 默认收起，命名“本地终端”；按当前代码切会话会释放旧终端，勿承诺后台驻留 | `lib/terminal/acp_session_terminal_region.dart:20`、`:60`、`:81`、`:124` |
| F43 | Agent 请求的 ACP terminal create/output/wait/kill/release | 条件 | 高 / 高 | 保留 opt-in provider；它不是 F42 的 tab 后端，也不共享相同权限生命周期 | `rust/crates/ianvs-acp-core/src/runtime.rs:1804`；`rust/crates/ianvs-acp-core/src/terminal.rs:1` |
| F44 | ACP 文件读写 provider，主目录及附加根目录约束 | 条件 | 高 / 高 | 保留 opt-in；明确只约束此客户端提供的回调能力，不是整个 Agent 进程沙箱 | `rust/crates/ianvs-acp-core/src/filesystem.rs:1`；`rust/crates/ianvs-acp-core/src/workspace.rs:1` |

## Agent、配置、权限与诊断

| ID | 功能与实际边界 | 状态 | 价值 / 成本 | 建议及原因 | 证据 |
|---|---|---|---|---|---|
| F45 | 多个本地 stdio Agent 配置与选择 | 条件 | 高 / 中 | 保留开放配置接口；主菜单只留选择、认证、管理 | `lib/app.dart:2695`；`lib/ui/components/agent_toolbar.dart:230` |
| F46 | Codex/Pi/Cursor/CodeBuddy 本地命令发现与去重 | 条件 | 高 / 中 | 保留四类已知候选；发现不等于安装/认证/兼容测试完成 | `lib/config/acp_agent_discovery.dart:42`、`:136` |
| F47 | GUI 编辑 command/args/cwd/env、默认 Agent | 实现 | 高 / 高 | 保留；把“连接成功”与“配置保存”明确区分 | `lib/ui/components/agent_config_dialog.dart:1`；`lib/config/acp_config_store.dart:1` |
| F48 | Agent 认证、登出、认证错误恢复 | 条件 | 高 / 中 | 保留，就近显示；不自动接管各 CLI 的账号体系 | `lib/acp/rust_acp_agent_client.dart:690`；`lib/ui/components/resume_session_dialog.dart:501` |
| F49 | 稳定 stdio/HTTP/SSE MCP 配置及能力过滤 | 条件 | 高 / 高 | 保留高级集成；与远程 ACP 连接明确区分 | `lib/app.dart:69`；`rust/crates/ianvs-acp-core/src/runtime.rs:3962` |
| F50 | 附加目录与 filesystem/terminal provider 配置 | 条件 | 高 / 中 | 下沉“权限与目录”；创建前显示最终有效范围 | `lib/config/acp_client_config.dart:152`；`lib/ui/components/agent_config_dialog.dart:1` |
| F51 | 版本化 Session Template，MCP 子集、参数及权限/助手覆盖、漂移提示 | 条件 | 中 / 高 | 保留读取和选择，缩小编辑面；当前模板在 JSON 编辑，目录与全局取并集 | `lib/config/acp_client_config.dart:152`、`:476`；`lib/state/chat_controller.dart:3052`；`README.md:148` |
| F52 | 人工批准/拒绝/取消，Agent 提供的选项、超时和撤销 | 实现 | 高 / 高 | 核心保障；统一一个待决操作面，保留语义和上下文 | `lib/state/chat_controller.dart:5796`；`lib/ui/components/prompt_input.dart:1`；`rust/crates/ianvs-acp-core/src/runtime.rs:3526` |
| F53 | 默认权限 / 自动审查 / 完全访问三种执行策略 | 实现 | 高 / 中 | 默认人工；高级策略显式可见，不能用“自动”模糊授权范围 | `lib/acp/acp_permission_request.dart:33`；`lib/state/chat_controller.dart:2762`、`:5796` |
| F54 | 工具信任规则 | 部分 | 中 / 高 | 暂停扩张，先修 toolCallId 被用作 toolName 的复用语义 | `lib/acp/rust_acp_agent_client.dart:1243`；`lib/acp/acp_permission_request.dart:121` |
| F55 | ACP 或 MCP sidecar 自动权限 reviewer | 条件 | 中 / 高 | 下沉实验性高级设置；验证省下的人工操作是否抵消延迟/额外调用 | `lib/acp/acp_permission_reviewer.dart:33`、`:567`；`lib/app.dart:2751` |
| F56 | Permission History，有界内存审计与 JSON 导出 | 实现 | 中 / 中 | 合并“活动与诊断”的权限筛选；明确不是持久企业审计 | `lib/ui/components/permission_history_dialog.dart:1`；`lib/state/chat_controller.dart:6021` |
| F57 | AI 会话标题 | 条件 | 低 / 中 | 默认关闭保持现状；优先目录/本地标题，AI 作为独立可选增强 | `lib/config/assistant_agent_config.dart:1`；`lib/state/chat_controller.dart:3779` |
| F58 | AI 逐回合总结、总结后折叠过程 | 条件 | 低 / 高 | 优先冻结，验证后改按需生成或退役；不要把呈现折叠绑定额外模型调用 | `lib/state/chat_controller.dart:8128`；`lib/acp/assistant_agent_enhancer.dart:71` |
| F59 | Session Activity：prompt/response/tool/status/permission/error 轨迹 | 实现 | 中 / 中 | 合并到一个会话活动入口；保留排错价值 | `lib/ui/components/session_activity_dialog.dart:1`；`lib/ui/activity/session_activity_model.dart:1` |
| F60 | Runtime Inventory：真实 recipe、MCP/provider、密钥引用数量、降级 | 实现 | 中 / 中 | 作为诊断权威摘要；安全范围/未生效模板项保持可查 | `lib/ui/components/runtime_inventory_dialog.dart:27` |
| F61 | ACP Compatibility：协商能力和 raw metadata | 实现 | 中 / 中 | 并入 Runtime Inventory 的高级详情；不要重复一级入口 | `lib/ui/shell/app_shell.dart:328`、`:635`；`lib/ui/components/capabilities_dialog.dart:1` |
| F62 | Protocol Coverage：静态协议完成度说明 | 部分 | 低 / 中 | 退役独立页面，保留准确能力详情；错误静态文案先纠正 | `lib/ui/components/protocol_feature_review_dialog.dart:127`、`:210`、`:398` |
| F63 | Context inspector、会话设置、模型配置详情 | 实现 | 中 / 中 | 合并成简洁会话详情；快捷模型选择共享同一状态 | `lib/ui/components/workspace_inspector.dart:43`、`:123`；`lib/ui/shell/app_shell.dart:308` |
| F64 | “来源”标题与添加来源占位 | 无 | 低 / 低 | 移除或改名空泛分组；onAction=null 时加号不会渲染，不能算已实现来源管理 | `lib/ui/components/workspace_inspector.dart:94`、`:286` |
| F65 | 启动配置错误/运行错误：打开配置、重试、复制诊断；Keychain 交互引导 | 实现 | 高 / 中 | 保留，继续完善首次成功会话闭环；不要重复报告旧版“没有恢复按钮” | `lib/ui/shell/app_shell.dart:273`；`lib/ui/components/error_banner.dart:112`；`lib/startup/acp_client_bootstrap.dart:129` |

## 恢复、桌面和明确边界

| ID | 功能与实际边界 | 状态 | 价值 / 成本 | 建议及原因 | 证据 |
|---|---|---|---|---|---|
| F66 | Rust 进程重启、已注册会话恢复、单会话失败隔离 | 实现 | 高 / 高 | 保留；真实 Agent 回归是发布门槛 | `rust/crates/ianvs-acp-core/src/runtime.rs:1380`、`:2168` |
| F67 | 精确版本转录缓存、无缓存原子回放、加载指标 | 实现 | 高 / 高 | 保留；性能分缓存/无缓存/Agent侧测量，不再次整体重写时间线 | `lib/storage/session_transcript_cache.dart:22`；`lib/state/chat_controller.dart:3302`；`docs/conversation_loading_architecture.md:165` |
| F68 | 工作区/会话索引私有存储，多窗口字段合并 | 实现 | 高 / 高 | 保留；不同于 Agent 原始历史和转录缓存 | `lib/workspace/workspace_sidebar_state_store.dart:1`；`docs/sqlite_storage.md:20` |
| F69 | 缓存/注册表容量和保留天数设置 | 实现 | 中 / 中 | 设置只露一个“本地数据”区；说明 50GB 对两个 store 分别约束，UI 索引不受其管理 | `lib/storage/sqlite_storage_config.dart:1`；`docs/sqlite_storage.md:14` |
| F70 | Keychain 秘密存储、旧明文迁移、原子保存及恢复 | 实现 | 高 / 高 | 保留；这是配置可靠性，不是可删的附加功能 | `lib/config/acp_config_secret_migrator.dart:1`；`lib/config/macos_keychain_secret_store.dart:1` |
| F71 | macOS 工具栏、侧栏拖宽、Context 切换、窄窗口替代入口、原生快捷键 | 实现 | 高 / 中 | 固定现有壳层，后续以明确任务失败驱动修改 | `lib/ui/shell/macos_workspace_layout.dart:1`；`macos/Runner/MainFlutterWindow.swift:1`；`docs/macos-ui-refactor-2026-09-07/acceptance.md:13` |
| F72 | 共享主题、终端颜色、语义标签与键盘支持 | 实现 | 中 / 中 | 保留一致性基础；未做本轮 VoiceOver/真实缩放验收，不声称完整无障碍通过 | `lib/ui/theme/app_theme.dart:1`；`lib/ui/components/accessible_text_field.dart:1` |
| F73 | 本地构建/安装、CI 验证、签名公证发布脚本 | 条件 | 高 / 中 | 保留；脚本存在不代表正式分发已完成，签名仍需发布环境凭据 | `Makefile:1`；`.github/workflows/macos.yml:1`；`tool/package_macos_release.sh:1` |
| F74 | 远程 ACP WebSocket/HTTP/SSE | 无 | 待证 / 高 | 暂缓；配置可解析，生产明确 unavailable | `lib/app.dart:2705` |
| F75 | MCP-over-ACP、通用 Extension Request、provider/NES/elicitation 实验协议 | 无 | 待证 / 高 | 不列已交付，不为补协议覆盖率立项 | `lib/app.dart:2712`；`rust/crates/ianvs-acp-core/src/model.rs:317`；`lib/ui/components/protocol_feature_review_dialog.dart:398` |
| F76 | 长期 Memory、Inbox、持久 Task/Workflow、后台调度 | 无（已删除） | 待证 / 极高 | 近期不恢复；保留 Git 历史即可，F20 的会话排队不是这些能力 | commits `6a96a56`、`b490fa2` |
| F77 | ACP Registry 商店/安装器 | 无 | 待证 / 高 | 暂缓；先做好现有 Agent 候选检测和失败解释 | `docs/manual_followups.md:47`；`lib/ui/components/protocol_feature_review_dialog.dart:462` |
| F78 | 旧 SessionSidebar / WorkspaceHeader / StatusBar 及 MermaidExamplePage | 无生产接线 | 低 / 低 | 删除候选或移到明确 demo；全仓构造搜索仅定义/各自测试命中 | `lib/ui/components/session_sidebar.dart:8`；`lib/ui/components/workspace_header.dart:8`；`lib/ui/components/status_bar.dart:8`；`lib/mermaid/mermaid_example_page.dart:11` |

## 容易误读的边界

1. F17 的“创建 worktree + 空会话”已有实现；F18 的“复制现有会话上下文”没有生产实现。不能一概说 worktree 未实现。
2. F21 会停止当前 prompt，再发送下一条；不是不中断执行的实时 steer。
3. F42 为用户 shell，F43 为 Agent callback terminal。工作目录绑定不等于对 shell/Agent 所有命令建立进程沙箱。
4. F37/F38 的 UI/Fake 状态不证明生产事件已接通；目录标题、本地标题、实时标题、usage 要分别验收。
5. F75 的静态类型/配置 parser/完成度文案不能证明 Rust 支持；F62 正在制造这种误解。
6. 当前未建立团队协同/云同步/账号管理、完整 IDE/Git review、语音实时对话、自动更新闭环的交付证据；不要把“多会话”“文件预览”“打包脚本”升级解释成这些产品。

所有删除建议是下一阶段变更候选，本轮没有修改生产代码、配置或用户数据。按需合并入口并不意味着删除其底层校验或将不同授权语义合并。
