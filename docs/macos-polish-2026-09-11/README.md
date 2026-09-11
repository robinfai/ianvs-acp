# macOS UI 细节打磨 · 2026-09-11

基线为 ACP `8a7f53f`。本轮使用真实 macOS 截图，将初始 19 个界面和 1 个补拍界面分成 6 组交给内置 ImageGen，结合 Apple HIG 和现有 Ianvs Design 组件进行调整。生成图只用于设计参考；最终判断来自源码、原生窗口和交互测试。

## 主要调整与归属

| 发现 | 落地调整 | 归属 |
| --- | --- | --- |
| 连续开关行拥挤 | `IanvsSettingsRow` 按密度提供内边距和最小行高，文字可自然增高 | UI 库独立评审、实现并推送 |
| 开关下重复“已开启／已关闭” | 删除重复状态文案，保留必要说明和开关语义 | 应用 |
| 设置中标签、控件和说明文字对齐不一致 | Agent、MCP、辅助模型与审查来源使用共享标签行；说明对齐字段，环境变量入口对齐控件列 | 应用 |
| 会话参数选择值过大、过粗 | 选择值使用 13 点正文角色；窄窗口及放大字体改为上下布局；移除空的分组标题卡片 | 应用 |
| 独立聊天返回键与窗口按钮重叠 | 页面宿主为 macOS 窗口按钮保留 88 点区域；聊天包只负责连接表单与内容 | 应用及其聊天包 |
| 详情正文偏小，左右边距不齐 | 12 点标签、13 点值；正文 24 点侧边距；显式关闭入口、长文本自适应布局、单层分隔线 | 应用 |
| 诊断标题与其他弹窗不一致 | 使用共享标题角色，统一 24 点内容边距、紧凑标签栏；运行信息改善字号和列间距 | 应用 |
| 工具详情四个同级边框过重 | Input／Output 保留可选中代码；Kind／Call ID 合并为次级行；普通详情使用中性边框 | 聊天包 |
| 空输入区占用偏高 | 最小高度由 152 改为 112 点，保留多行、附件、权限和模型入口的自然增高 | 聊天包 |
| 侧栏边界露出窄条背景，横向分隔线没有接上 | 将 8 点拖拽命中区覆盖在两侧面板交界处；面板直接相接，保留拖动和键盘调宽 | 应用布局 |
| 鼠标拖动后蓝色粗线一直保留 | 区分鼠标与键盘焦点反馈；拖拽结束／取消后恢复中性细线，键盘操作仍显示焦点 | UI 库 |
| 模型菜单悬停色偏重且带蓝色描边 | 菜单使用柔和背景反馈；移除应用父菜单及选项上的额外蓝色覆盖层，保留勾选标记 | UI 库与聊天包 |

保留现有主题与导航结构。聊天阅读正文仍为 15 点；没有把所有文字机械缩成同一字号。ImageGen 中添加的装饰、按钮和错误文字没有直接进入实现。

参考依据：[Apple Typography](https://developer.apple.com/design/human-interface-guidelines/typography)、[Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)、[Layout](https://developer.apple.com/design/human-interface-guidelines/layout)。采用的是桌面界面密度、窗口适配、文字层级和可操作性原则。

## 前后对照

下列图片直接来自原生窗口，不是生成稿。聊天和工具详情使用同一离线数据、相同窗口调整步骤；其余页面可能有不同配置数据或窗口尺寸，不能按截图像素推断逻辑点数。

| 修改前 | 修改后 |
| --- | --- |
| ![工具详情之前](before/18-tool-output.png) | ![工具详情之后](after/18-tool-output.png) |
| ![独立聊天之前](before/12-independent-chat.png) | ![独立聊天之后](after/12-independent-chat.png) |
| ![权限之前](before/04-permissions.png) | ![权限之后](after/04-permissions.png) |
| ![会话参数之前](before/15-session-settings.png) | ![会话参数之后](after/15-session-settings.png) |
| ![详情之前](before/16-session-details.png) | ![详情之后](after/16-session-details.png) |
| ![MCP 之前](before/20-mcp-editor.png) | ![MCP 之后](after/20-mcp-editor.png) |
| ![侧栏接缝之前](before/21-sidebar-edge.png) | ![侧栏接缝之后](after/21-sidebar-edge.png) |
| ![拖动释放后蓝线残留](before/22-resize-release.png) | ![拖动释放后恢复中性细线](after/22-resize-release.png) |
| ![菜单高亮过重且带描边](before/23-menu-hover.png) | ![菜单使用柔和无描边高亮](after/23-menu-hover.png) |

对照检查确认工具元数据不再挤占两张独立卡片，输入框在空状态腾出阅读空间，正文与标签保持不同层级。窄窗口和放大文字允许内容滚动，保存／完成／关闭入口仍可操作。

## 截图与生成稿索引

`before/01–12` 为原应用截图；`13–19` 使用生产组件和 FakeAgentClient，填充聊天、工具、计划和参数状态。`20-mcp-editor` 是复核中补拍的 MCP 字段调整前状态，此时共享 UI 库已更新。`after/` 为本轮原生复核，使用独立 bundle id `com.ianvs.acp.polish` 的离线样例。

| 编号 | 页面／状态 | ImageGen 参考 |
| --- | --- | --- |
| 01 | 工作区空状态 | [工作区](references/workspace.png) |
| 02 | Agent 设置 | [设置](references/settings.png) |
| 03 | 工具与目录 | [工作区](references/workspace.png) |
| 04–06 | 权限、AI 助手、本地存储 | [设置](references/settings.png) |
| 07–09 | Events、Permissions、Runtime | [弹窗](references/dialogs.png) |
| 10 | 新建会话选择 Agent | [弹窗](references/dialogs.png) |
| 11–12 | Agent 菜单、独立聊天 | [工作区](references/workspace.png) |
| 13–15 | 活动会话、Context、会话参数 | [聊天](references/chat.png) |
| 16–17 | 会话详情、工作区概览 | [详情](references/details.png) |
| 18–19 | 展开工具、会话菜单 | [聊天](references/chat.png) |
| 20 | MCP 编辑器 | [MCP 表单](references/mcp.png) |
| 21 | 用户反馈后的侧栏接缝修复；8 点命中区不再占据独立布局列 | 源码定位与原生截图复核 |
| 22 | 鼠标拖动释放后的焦点反馈；原版残留蓝色粗线 | 库组件状态修复与真实鼠标事件回归 |
| 23 | 模型子菜单展开；应用去除叠加色，共享菜单改为柔和无描边反馈 | 库组件状态评审与原生截图复核 |
| 24 | [输入框细边、柔和阴影与细线图标](after/24-composer.png) | 用户提供的输入区参考图 |
| 25 | [强度面板与静态刻度](after/25-strength.png) | 用户提供的强度面板参考图 |
| 26 | [诊断关闭按钮默认不显示焦点框](after/26-diagnostics-close.png) | 用户反馈与键盘回归 |
| 27 | [模型菜单字号、留白与单个细线箭头](after/27-composer-menu.png) | 原生截图复核 |

全部原始提示词见 [imagegen-prompts.md](imagegen-prompts.md)。生成图已复制到本目录，不依赖 Codex 缓存路径。

## UI 库交付状态

UI 库在自己的项目中评审并实现 SettingsRow 留白（提交 `63e6e516`）、ResizeHandle 鼠标释放后的高亮恢复（`ea4a2426`）及柔和无描边的菜单状态，本轮应用没有复制或私自改写库组件。当前接入的库主线提交为 [`e926049e`](https://github.com/robinfai/ianvs-design/commit/e926049e8bbe64b66efb61be5a4c93ed7638c211)。

公开版本仍是 0.3.1，0.4.0 尚未创建 tag／发布 pub.dev。三个工作区保留 `^0.3.1` 的公开依赖声明，并用 `dependency_overrides` 固定上述完整 Git SHA，确保当前修复可复现，同时保留聊天包的可发布依赖声明。0.4.0 正式发布后，将三个依赖同步改为 hosted 版本并移除 overrides；本轮不把主线提交描述为 pub.dev 发布完成。

最终通过 pub.dev API 核对公开最新版本为 0.3.1（发布于 2026-09-11T06:53:41Z）。库任务反馈：后续直接授权覆盖了 main 提交推送，0.4.0 的 tag／pub.dev 发布仍未获自动审批放行，需要在该任务补充直接发布授权。

## 验证

最新模型菜单调整与动画恢复见 [参考对照记录](model-picker-v2.md)：替代上一轮静态滑轨，恢复原有循环粒子动画；模型菜单改为直接列表。内置 ImageGen 目标稿、原生前后截图及提示词均已保存。

输入区与默认焦点补充：聊天包自有输入框改为 0.75 点浅边、22 点圆角和低透明度黑色阴影；模型入口使用中性底色，菜单文字及箭头减重，附件、权限、发送等图标使用 Cupertino 细线图标。强度面板显示强度与模型层级，滑轨使用静态刻度；深色面板的强度文字使用可读性更高的主题色。诊断关闭按钮移除应用显式设置的 `autofocus`，默认无蓝框，Tab 导航仍显示真实焦点，Escape 关闭及焦点返回保持有效。这些属于应用和聊天包自有实现，本次没有新增 UI 库修改。相关回归共 105 项通过（输入区 71、诊断与应用壳 33、会话操作 1）；正式入口 macOS Release、签名闭包与 bundle 检查通过。截图 24–27 来自独立离线原生预览；本次没有逐一复验所有媒体附件状态。

| 检查 | 结果 |
| --- | --- |
| 应用 UI 回归 | 370 项通过 |
| 聊天包测试 | 283 项通过，2 项既有跳过 |
| 独立 example | 2 项通过 |
| 新增重点行为 | macOS 返回键避让与返回、独立连接表单校验、2 倍文字的参数开关、详情关闭 |
| 浅／深色布局截图 | 2 组通过，26 张；1440×1024、600×850 和 2 倍文字 |
| 静态与格式检查 | 三个工作区通过 |
| macOS Release | 正式 `lib/main.dart` 入口构建通过 |
| 原生包验证 | `make verify-macos` 的签名闭包和 bundle 检查通过 |

侧栏接缝补充回归：`macos_workspace_layout_test.dart` 与 `app_shell_test.dart` 共 34 项通过。覆盖面板紧密相接、拖拽命中区两侧覆盖、边界附近拖动、方向键调宽、回车重置、隐藏／显示后草稿保留，以及终端面板左边界对齐；应用静态与格式检查通过。修复后的原生窗口确认背景、顶部工具栏横线及侧栏底部分隔线直接相接，侧栏收起和恢复正常；正式入口 Release 构建和 `make verify-macos` 再次通过。

鼠标焦点补充回归：新增真实 `PointerDeviceKind.mouse` 的应用集成测试，先确认旧库在鼠标松开后仍呈蓝色的断言失败，再接入修复使相关 35 项测试通过；新增测试另以 macOS 平台配置复核。库侧新增 9 项测试，总计 16 项分栏控件测试通过，整体 159 项组件测试和 71 项展厅测试通过。原生窗口确认鼠标调宽后立即恢复中性细线，无需点击输入框；方向键调宽仍显示焦点，再次鼠标拖动释放后恢复细线。截图只记录释放状态，未人为清除焦点。三个工作区静态检查、格式检查、正式入口 Release 构建及 `make verify-macos` 全部通过。

菜单悬停补充回归：UI 库将未选中菜单项的 hover、focus、pressed 分别调整为正文色 5%、8%、10% 的中性底色，并移除菜单项描边；hover 与 focused 同时存在时优先使用 hover 底色。真正选中项继续使用选中色。应用移除父菜单和选项上的额外蓝色 overlay，原生模型子菜单截图确认无蓝框且底色柔和。新依赖下输入区 71 项、应用壳 30 项测试通过，三个工作区静态与格式检查通过；库侧组件 163 项、展厅 71 项通过，覆盖真实鼠标展开、焦点联合状态及键盘选择，深浅色正文对比度不低于 4.5。正式入口 macOS Release 构建、签名闭包和应用包检查通过。

布局复核截图位于 `layout-checks/`。Widget test 加载的是兼容字体，适合发现溢出和布局问题；SF 字体、原生输入控件及窗口按钮以 `after/` 原生截图为准。Fake 数据只证明界面和交互，不证明真实服务支持相同能力。本轮没有发起真实 Agent／LLM 请求或修改用户配置；终端实时进程、媒体附件、所有错误状态未逐一进行原生视觉验收，相关既有交互测试照常执行。

复现布局检查：

```sh
./tool/flutter_workspace.sh bootstrap all
./tool/flutter_workspace.sh test app --reporter expanded docs/macos-polish-2026-09-11/capture_test.dart
```

更新截图时追加 `--update-goldens`。离线原生样例入口为 [harness.dart](harness.dart)，正式产物为 `build/macos/Build/Products/Release/ACP Client.app`。
