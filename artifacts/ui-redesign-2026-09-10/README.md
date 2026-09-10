# ACP Client 界面设计与实现记录

## 主线整合说明（2026-09-11）

推送前同步到远端 `8a7f53f`。期间主线已将设置改成独立页面、拆出 `ianvs_agent_chat` 公共包，并接入 Ianvs Design。本次整合保留这些更新；原六分区弹窗和侧栏实现由主线新版页面替代，不覆盖其设置保存、导航、会话启动及恢复逻辑。

仍适用的调整已迁入新架构：代理单选图标与文字层级、可折叠的协议能力信息、工作区确认按钮字体、聊天空态主按钮、中性工具日志，以及推理选项被 Model 分组误标的修复。相关测试迁移到对应包。

以下图片、截图数量和历史测试结果记录的是整合前的设计过程，不代表最新主线逐像素外观。旧截图脚本依赖已被主线移除的路径，因此以 `.dart.txt` 保存为历史源文件，不参与当前编译。最新整合验证结果见 `integration-verification.md`。

## 已实现的设计（整合前）

使用内置 ImageGen 从原生截图生成了五组设计参考：工作区、全局设置、新会话、工具详情、会话设置。原图和生成提示保存在 `design/`。参考中的示例命令仅用于视觉说明，实际程序保持运行时配置。

- **全局设置**：长表单重构为 Agents、Workspace、MCP Servers、Assistant、Permissions、Storage 六个分区；宽窗口使用侧栏，窄窗口使用选择器；标题、错误提示和操作区固定，内容独立滚动。
- **工作区**：侧栏按窗口宽度缩为 240 / 272 / 300px；明确新对话入口；空会话移除无内容的标题；空态主按钮增强对比；上下文弹层适应短窗口。
- **新会话**：明确代理和工作目录分组；单选状态统一为蓝色选中框与单选图标；固定代理场景只提示选择目录。
- **工具详情**：输出、输入等日志块使用中性背景和边框，避免将成功结果表现成警告。
- **会话设置**：兼容性信息收进可展开区域，优先呈现模型、推理强度和配置项；修正输入区推理菜单因 Model 分组而误显示为 Model 的标签。
- **工作区确认**：按钮使用统一字体 token，消除独立文字样式与主题之间的不一致。

诊断表格、权限操作、认证、恢复会话、编辑器和菜单沿用现有交互；按截图检查其层级与动作可见性，没有为视觉改造改变权限语义或 ACP 行为。

## 截图来源与覆盖

`before/` 是通过 Computer Use 获取的真实 macOS 原生截图。最早的旧安装包落后于源码，发现后重建，并刷新工作区和工作区菜单基线。`native/01–16` 是第一版原生预览中的交互证据；`native/17–21` 是新版布局核对。

`after/` 来自同一 Flutter 组件的可复现截图测试，使用 FakeAgentClient 构造活动会话、权限和错误状态。它们不是远程真实代理响应，也不能替代真实代理端到端测试。真实窗口核对没有保存用户配置、发送提示、确认权限或执行删除。

| 交互区域 | 截图证据 |
| --- | --- |
| 工作区、空态、活动对话、窄窗口 | before/01；after/workspace-*；native/17 |
| 全局设置六分区、窄屏选择器 | after/settings-*；native/18 |
| 代理、目录、MCP、信任规则编辑器 | before/04–10；after/*-editor |
| 新会话、模板/代理入口 | before/11；after/new-session；native/19 |
| 恢复会话与工作区确认 | before/12；after/resume-empty、workspace-review |
| 会话配置与兼容性展开 | after/session-settings*、session-compatibility-expanded；native/20 |
| 模型、推理、高级设置、权限策略 | native/02–06；after/composer-* |
| 会话菜单、复制、继续、重命名 | native/07–10 |
| 工作区菜单和重命名 | before/17–18 |
| 创建/分叉 worktree | after/create-worktree、fork-worktree |
| 上下文与终端 | before/13；native/11、14 |
| 工具详情、命令展开、权限请求 | native/12–13；after/tool-details、command-details、workspace-permission |
| 权限历史 | before/16；after/permission-history |
| 兼容性、活动、发现、运行时、协议 | after/compatibility、activity、discovery、runtime、protocol |
| 深链接、认证、退出、关闭会话确认 | after/deep-link、authentication、logout-confirmation、close-session-confirmation |
| Markdown、代码文件与缺失文件反馈 | after/file-* |
| 附件菜单与启动恢复 | after/attachment-menu、startup-recovery |

范围是本地客户端可呈现的界面与主要交互状态；系统文件选择器、外部浏览器认证页和任意代理自定义内容不属于本次可重构组件。没有把有限截图宣称为所有动态数据组合。

## 验证

以下结果来自本次实际运行；原始 `.log` 文件按仓库规则仅保留在本地，不纳入 Git。

- 完整 UI 回归：558 个测试通过，见 `final-ui-tests.log`。
- 截图套件：31 个测试通过，见本地 `final-capture.log`；原脚本保存为 `capture_test.dart.txt`，只能在整合前架构下配合 macOS 字体运行。
- 静态分析：无问题，见本地 `analyze.log`。
- 正式入口 macOS Debug 构建：成功，见本地 `production-build.log`。使用 `lib/main.dart`，不是审查场景入口。
- 截图测试部分回退字体与 macOS 系统字体不同，原生截图是实际桌面排版的依据。

## 逐屏文件索引

### design

- [new-session](design/new-session.png)
- [session-settings](design/session-settings.png)
- [settings](design/settings.png)
- [tool-details](design/tool-details.png)
- [workspace](design/workspace.png)

### before

- [01-workspace](before/01-workspace.png)
- [02-agents-menu](before/02-agents-menu.png)
- [03-agent-config](before/03-agent-config.png)
- [04-add-directory](before/04-add-directory.png)
- [05-mcp-editor](before/05-mcp-editor.png)
- [06-assistant-settings](before/06-assistant-settings.png)
- [07-permission-settings](before/07-permission-settings.png)
- [08-agent-list](before/08-agent-list.png)
- [09-agent-editor](before/09-agent-editor.png)
- [10-trust-rule](before/10-trust-rule.png)
- [11-new-session](before/11-new-session.png)
- [12-resume](before/12-resume.png)
- [13-context](before/13-context.png)
- [14-protocol](before/14-protocol.png)
- [15-runtime](before/15-runtime.png)
- [16-permission-history](before/16-permission-history.png)
- [17-workspace-menu](before/17-workspace-menu.png)
- [18-rename-workspace](before/18-rename-workspace.png)

### native

- [01-active](native/01-active.png)
- [02-model-menu](native/02-model-menu.png)
- [03-model-options](native/03-model-options.png)
- [04-reasoning-options](native/04-reasoning-options.png)
- [05-advanced-settings](native/05-advanced-settings.png)
- [06-policy-menu](native/06-policy-menu.png)
- [07-session-menu](native/07-session-menu.png)
- [08-copy-submenu](native/08-copy-submenu.png)
- [09-continue-submenu](native/09-continue-submenu.png)
- [10-rename-conversation](native/10-rename-conversation.png)
- [11-terminal](native/11-terminal.png)
- [12-conversation-top](native/12-conversation-top.png)
- [13-tool-details](native/13-tool-details.png)
- [14-session-context](native/14-session-context.png)
- [15-session-settings](native/15-session-settings.png)
- [16-close-confirmation](native/16-close-confirmation.png)
- [17-final-workspace](native/17-final-workspace.png)
- [18-final-settings](native/18-final-settings.png)
- [19-final-new-session](native/19-final-new-session.png)
- [20-final-session-settings](native/20-final-session-settings.png)

- [21-final-tool-details](native/21-final-tool-details.png)

### after

- [activity](after/activity.png)
- [agent-editor](after/agent-editor.png)
- [attachment-menu](after/attachment-menu.png)
- [authentication](after/authentication.png)
- [close-session-confirmation](after/close-session-confirmation.png)
- [command-details](after/command-details.png)
- [compatibility](after/compatibility.png)
- [composer-config-menu](after/composer-config-menu.png)
- [composer-reasoning-menu](after/composer-reasoning-menu.png)
- [create-worktree](after/create-worktree.png)
- [deep-link](after/deep-link.png)
- [directory-editor](after/directory-editor.png)
- [discovery](after/discovery.png)
- [file-example.dart](after/file-example.dart.png)
- [file-guide.md](after/file-guide.md.png)
- [file-missing.txt](after/file-missing.txt.png)
- [fork-worktree](after/fork-worktree.png)
- [logout-confirmation](after/logout-confirmation.png)
- [mcp-editor](after/mcp-editor.png)
- [new-session](after/new-session.png)
- [permission-history](after/permission-history.png)
- [protocol](after/protocol.png)
- [resume-empty](after/resume-empty.png)
- [runtime](after/runtime.png)
- [session-compatibility-expanded](after/session-compatibility-expanded.png)
- [session-settings-compact](after/session-settings-compact.png)
- [session-settings](after/session-settings.png)
- [settings-agents](after/settings-agents.png)
- [settings-assistant](after/settings-assistant.png)
- [settings-compact-storage](after/settings-compact-storage.png)
- [settings-compact](after/settings-compact.png)
- [settings-mcp-servers](after/settings-mcp-servers.png)
- [settings-permissions](after/settings-permissions.png)
- [settings-section-menu](after/settings-section-menu.png)
- [settings-storage](after/settings-storage.png)
- [settings-workspace](after/settings-workspace.png)
- [startup-recovery](after/startup-recovery.png)
- [tool-details](after/tool-details.png)
- [trust-rule-editor](after/trust-rule-editor.png)
- [workspace-active](after/workspace-active.png)
- [workspace-compact](after/workspace-compact.png)
- [workspace-empty](after/workspace-empty.png)
- [workspace-narrow](after/workspace-narrow.png)
- [workspace-permission](after/workspace-permission.png)
- [workspace-reference](after/workspace-reference.png)
- [workspace-review](after/workspace-review.png)
