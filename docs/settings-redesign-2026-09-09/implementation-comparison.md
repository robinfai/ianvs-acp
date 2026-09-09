# 第 3 图与实际实现对照

> 历史设计阶段记录：字体、密度和保存按钮位置已由[后续 macOS 设置调整](../macos-settings-refinement-2026-09-09/README.md)替代。本文保留当时的设计、截图与验收结果，不作为当前界面规格。

日期：2026-09-09。最终执行结果见 [验收记录](acceptance.md)。用户选择的方向是 [第 3 图：工作区内设置页](concepts/workspace.png)。本文把该布局意图与当前源码和实际 Flutter UI 截图逐项对照；截图、源码与测试文件是审阅输入，不在本文中代替最终测试结果或原生 macOS 验收。

## 对照总览

| 编号 | 第 3 图的目标 | 当前实现 | 实际界面 |
| --- | --- | --- | --- |
| A1 | 全页设置和五个稳定分类 | 设置由 `/settings` 页面承载，宽屏左侧显示 Agent、工具与目录、权限、AI 助手、本地存储五类导航；窄屏改为顶部分类选择器。 | [Agent 默认页](screenshots/after/03-agent-clean.png)、[480 px 窄页](screenshots/after/13-narrow.png) |
| A2 | 连接列表与详情同页编辑 | Agent 和 MCP 均使用主从布局：宽屏左侧列表、右侧行内详情；窄屏用连接选择器。参数仍是有序逐项输入，高级设置默认展开。 | [Agent 草稿](screenshots/after/04-agent-draft.png)、[MCP 详情](screenshots/after/06-mcp.png) |
| A3 | 一个 Save 管理完整草稿 | 页面只有底部主 Save。跨分类和跨连接保留草稿；无修改、只读、运行中和保存中状态会限制提交；返回时可继续编辑或明确放弃；失败保留输入，成功采用 writer 返回的已保存配置。 | [未保存草稿](screenshots/after/04-agent-draft.png)、[放弃确认](screenshots/after/12-discard-confirmation.png)、[保存结果](screenshots/after/14-saved.png) |
| A4 | 分开表达默认、当前和目录作用域 | “启动默认 Agent”是应用配置；“当前 Agent”属于当前连接/新建会话上下文；列表中的高亮对象只是正在编辑的连接。Agent 启动目录、会话主工作目录、应用附加目录使用不同字段和说明。 | [Agent 菜单](screenshots/after/02-agent-menu.png)、[附加目录](screenshots/after/05-directories.png)、[当前会话参数](screenshots/after/15-session-settings.png) |
| A5 | 权限来源和执行策略不混写 | 设置页管理客户端能力、信任规则和 Auto Review 的来源；输入区管理当前会话的执行策略。未指定来源时，Auto Review 回退到当前 Agent 的独立审查会话；指定来源可选择 ACP Agent、MCP 或保留已有内嵌 MCP。 | [权限设置](screenshots/after/07-permissions.png)、[指定审查来源](screenshots/after/08-review-source.png) |
| A6 | AI helper 仅在条件满足时启用 | AI 辅助默认关闭；关闭时隐藏 Agent、模型和增强项，仅保留备用标题。开启后才加载所选 Agent 的模型；连接草稿未保存、运行中、加载中或缺少相应 callback 时，模型选择或验证保持禁用并显示原因。迟到的旧 Agent 模型结果不会覆盖新选择。 | [AI 助手关闭](screenshots/after/09-assistant-disabled.png)、[AI 助手开启](screenshots/after/10-assistant-enabled.png) |
| A7 | 当前会话参数与共享会话菜单各守其责 | 参数窗口只展示 Agent 协商出的模型、推理强度、模式和其它参数，并即时调用当前会话；刷新在运行操作期间禁用。关闭、删除、归档、复制、继续等操作由工具栏和侧栏共用同一份能力过滤和标签。 | [当前会话参数](screenshots/after/15-session-settings.png)、[工作区入口](screenshots/after/01-workspace.png) |
| A8 | 新建说明继承，恢复统一搜索和刷新 | New Session 保留模板、Agent 和工作目录选择，并说明选择只影响本次会话；模板摘要展示 Agent、MCP、附加目录、权限、Assistant 及模型/模式/推理请求。Resume 只加载所选 Agent，统一搜索行与单一刷新入口，按可选工作区限定结果，认证、等待、错误和空结果都绑定所选 Agent。 | [工作区入口](screenshots/after/01-workspace.png)；当前 `after` 集合没有单独的新建/恢复弹窗截图 |

## 实现与证据

### A1：全页五分类

[app_shell.dart](../../lib/ui/shell/app_shell.dart) 使用具名 `/settings` 的 `MaterialPageRoute` 打开 [agent_config_dialog.dart](../../lib/ui/components/agent_config_dialog.dart)。页面框架和响应式导航在 [settings_page_layout.dart](../../lib/ui/components/settings_page_layout.dart)：宽度足够时保留左侧五分类，窄屏切换为 `settings-section-picker`。这延续了第 3 图的工作区内页面结构，同时没有在 Flutter 内重复绘制 macOS 窗口按钮。

[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) 包含五分类、默认入口和 480 px 无溢出的契约；这些路径只说明覆盖内容，最终执行结果由总验收记录给出。

### A2：主从内联编辑

[settings_page_layout.dart](../../lib/ui/components/settings_page_layout.dart) 的连接布局在宽屏组合可滚动列表和详情，在窄屏组合选择器和详情。[settings_connection_editors.dart](../../lib/ui/components/settings_connection_editors.dart) 保留 Agent 预设、逐项参数、进程目录、环境变量、请求头、连接类型，以及 MCP 的 stdio/HTTP/SSE 表单。远程 ACP 和 MCP-over-ACP 的旧配置仍可查看和改名，但界面不提供新建这些当前不可运行类型的入口。

[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) 覆盖跨连接草稿、Agent 预设、stdio/HTTP MCP、旧 remote 别名、MCP-over-ACP 和只读状态下切换连接、滚动查看详情。

### A3：单 Save、草稿、失败和只读

[agent_config_dialog.dart](../../lib/ui/components/agent_config_dialog.dart) 从当前各分类和连接编辑器组合一个候选 `AcpClientConfig`；只有底部 `settings-save` 调用 writer。保存成功后调用 `_adoptConfig(saved)`，即以 writer 返回的配置重新建立页面状态，而不是继续假设提交前草稿就是磁盘最终值。校验或 writer 失败只更新错误状态，保留草稿以便重试。[settings_page_layout.dart](../../lib/ui/components/settings_page_layout.dart) 实现未修改、运行中、只读、保存中、离开和放弃状态；只读时连接列表和滚动仍可用于查看，详情修改入口被锁定。

[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) 覆盖跨分类一次保存、无改动、运行中、只读可浏览、失败重试、保存中阻止返回和放弃还原。[settings_save_lifecycle_test.dart](../../test/ui/settings_save_lifecycle_test.dart) 进一步覆盖应用层 writer 失败和 controller 生命周期。

保存的真实影响有两个边界：

- 一般成功路径会重新加载 controller，当前会话可能需要从侧栏恢复；页脚直接说明这一影响。
- 如果 writer 等待期间有新的 resume 等操作开始，磁盘提交仍可完成，但 [app.dart](../../lib/app.dart) 会将该配置放入 `_configurationAwaitingApply`，等所有 controller 空闲后再替换，避免中断这次迟到操作。界面会说明“已保存，将在当前操作结束后应用”。

### A4：默认、当前和三种目录

启动默认值由设置页 Agent 操作菜单写入 `defaultAgentServerName`；当前 Agent 由工具栏和运行 controller 表达；New Session 同时标出 `Current Agent` 与 `Startup default`，并说明这次选择不会修改启动默认值。设置页连接高亮只表示正在编辑的对象。

三个目录字段保持不同含义：

- Agent 进程启动目录： [settings_connection_editors.dart](../../lib/ui/components/settings_connection_editors.dart) 的“启动工作目录”。
- 会话主工作目录： [new_session_agent_dialog.dart](../../lib/ui/components/new_session_agent_dialog.dart) 的 `Session working directory`，以及恢复目录中的会话 workspace。
- 应用附加目录： [agent_config_dialog.dart](../../lib/ui/components/agent_config_dialog.dart) 的“默认附加目录”，供后续新会话继承，模板可以追加或覆盖其会话配置。

[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart)、[new_session_agent_dialog_test.dart](../../test/ui/new_session_agent_dialog_test.dart) 和 [resume_session_dialog_test.dart](../../test/ui/resume_session_dialog_test.dart) 分别覆盖启动默认、当前/默认标签以及恢复前的主目录和附加目录复核。

### A5：权限来源与当前执行策略

[agent_config_dialog.dart](../../lib/ui/components/agent_config_dialog.dart) 明确把应用提供给 Agent 的文件、终端能力和信任规则，与当前会话是否逐次审批分开。`使用指定审查来源` 只改变 Auto Review 的 reviewer 配方；关闭它不代表关闭自动审查。开启后按来源类型显示 ACP Agent、MCP 或已有内嵌 MCP 所需字段，并保留模型和超时。

当前执行策略经 [acp_chat_session.dart](../../lib/chat/acp_chat_session.dart) 投影到共享聊天 UI，由 [prompt_input.dart](../../packages/ianvs_agent_chat/lib/ui/components/prompt_input.dart) 提供默认权限、自动审查和完全访问权限三种即时选项。[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) 覆盖权限保存、来源条件字段、无关编辑不启用旧 reviewer 配置和 reviewer 重命名数据保留。

### A6：AI 辅助启用条件

[agent_config_dialog.dart](../../lib/ui/components/agent_config_dialog.dart) 仅在开启 AI 辅助后显示 Agent、模型、标题与摘要增强项。模型读取要求已选 Agent、无未保存连接草稿、runtime 空闲且提供加载 callback；验证还要求模型加载结束并提供验证 callback。异步结果带 generation 与当前 Agent 检查，切换 Agent 后迟到结果会被忽略。备用标题字段始终保留，供功能关闭或生成失败时使用。

[agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) 覆盖开关后的条件显示、模型读取与验证、保存，以及切换 Agent 时忽略迟到结果。

### A7：会话参数与共享菜单

[session_settings_dialog.dart](../../lib/ui/components/session_settings_dialog.dart) 只处理当前会话参数和刷新；选项会通过 controller 立即提交，不进入应用配置 Save。它继续用 sliver、搜索和输入预算处理大量动态选项，并在 streaming、会话操作或加载期间禁用修改。

[session_menu_actions.dart](../../lib/ui/components/session_menu_actions.dart) 定义会话操作的顺序、分组、标签和能力过滤；[agent_toolbar.dart](../../lib/ui/components/agent_toolbar.dart) 与 [workspace_sidebar.dart](../../lib/ui/components/workspace_sidebar.dart) 共用该定义。因此参数窗口无需重复放置关闭、删除或继续按钮，而工具栏和侧栏不会各自漂移出不同菜单语义。

[session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart) 覆盖动态参数、惰性构建、搜索预算、等待/错误与操作禁用；[workspace_sidebar_test.dart](../../test/ui/workspace_sidebar_test.dart) 和 [app_shell_test.dart](../../test/ui/app_shell_test.dart) 覆盖共享菜单在两个入口的投影。

### A8：新建继承与恢复搜索/刷新

[new_session_agent_dialog.dart](../../lib/ui/components/new_session_agent_dialog.dart) 保留已有模板、Agent 和 workspace 选择。自定义会话默认选择当前 Agent；只有显式默认模板才预选模板。模板摘要依据可用的 `baseConfig` 展示 Agent/MCP/附加目录继承或 `None`、权限与 Assistant 覆盖，以及模型、模式和推理强度请求。创建前尚未完成能力协商，因此摘要只承诺“所选 Agent 暴露匹配能力时才应用”这些请求。

[resume_session_dialog.dart](../../lib/ui/components/resume_session_dialog.dart) 将 Agent 选择、统一搜索与唯一刷新按钮放在一个流程内。它按选中 Agent 分别缓存目录，只在需要时加载；切换 Agent 会清空查询并丢弃已过期 generation 的结果。可选 `workspaceCwd` 只保留规范化路径相同的项目。认证横幅、loading、error、empty 和刷新状态都取自当前选择，失败后不会继续打开旧选择。

[new_session_agent_dialog_test.dart](../../test/ui/new_session_agent_dialog_test.dart) 覆盖当前/默认 Agent、模板摘要和“模板不隐式成为默认”；[resume_session_dialog_test.dart](../../test/ui/resume_session_dialog_test.dart) 覆盖单一刷新、按 Agent 加载、workspace 限定、认证、搜索预算、失败后禁用打开和快速异步状态切换。

## 兼容与范围边界

设置保存依赖 [acp_client_config.dart](../../lib/config/acp_client_config.dart)、[acp_config_store.dart](../../lib/config/acp_config_store.dart) 和页面候选配置的合并逻辑。当前边界是：

- 已保存的旧 remote transport 别名、MCP-over-ACP 条目和当前不可用类型继续保留；它们不会因此变成可运行能力。
- Agent/MCP 的未知字段、稳定身份、旧别名和 secret refs 继续透传；密钥值在普通界面中隐藏，显式重新输入仍作为修改意图保存。
- `session_templates`、默认模板和模板中的未知/继承字段随应用配置继续保存；New Session 只选择和解释已有模板。
- 本轮没有增加模板 CRUD，也没有增加任意 runtime 覆盖表单。模型、模式和推理强度仍由模板请求或已协商的当前会话参数处理。

第 3 图仍是布局方向记录，真实界面使用现有 Flutter 组件、响应式断点和文案校正。完整设计/实现并列图见 [全页对照](screenshots/comparison/full.png) 与 [详情对照](screenshots/comparison/details.png)；最终测试、真实 Agent、凭据写入和原生交互结论应写入独立总验收记录。
