# macOS 设置与表单重新验收

> 此记录保留当轮视觉基线。主题、通用控件与等宽字体已由 [9 月 10 日 Ianvs Design 接入](../ianvs-design-integration-2026-09-10/README.md) 更新。


> 阶段验收记录，随 `997b246` 提交（2026-09-09）。这是最近一次设置视觉验收，不证明后续提交已重新进行原生操作；当前功能与配置行为见[文档导航](../README.md)。

日期：2026-09-09。修改基线：`b343a77`。用户要求以**主应用窗口实际字号与间距**为准，重新阅读 macOS 规范后调整。此前第 3 张生成稿的放大字号与留白不再是本轮尺寸标准。

当前状态：调整、原生复验和工作区回归验证已完成。最终结果：passed。

## 本轮重新捕获的基准

使用当前源码构建的 macOS 主应用隔离入口 `docs/settings-redesign-2026-09-09/harness.dart`，FakeAgentClient 和内存配置 writer。通过 CUA 逐步导航、捕获并检查真实窗口；没有使用上一轮截图代替本轮证据。

| 步骤 | 检查对象 | 初始发现与证据 |
| --- | --- | --- |
| 1 | 主窗口 | [800×600](screenshots/before/01-main-800.jpg)、[宽窗口](screenshots/before/08-main-wide.jpg)：导航约 13.5 pt、标题栏 52 pt，侧栏默认 260 pt。作为字体与间距的首要参照。 |
| 2 | 设置 Agent | [800×600](screenshots/before/02-settings-800.jpg)、[宽窗口](screenshots/before/03-settings-wide.jpg)：28 pt 页标题、23 pt 连接标题、15 pt 导航明显大于主窗口；800 下头部约196 pt、底栏约98 pt，正文仅306 pt；返回入口与原生窗口控制区域重叠。 |
| 3 | 权限、助手、存储 | [权限](screenshots/before/04-permissions-wide.jpg)、[助手](screenshots/before/05-assistant-wide.jpg)、[存储](screenshots/before/06-storage-wide.jpg)：区块标题21 pt、说明行距1.6、组间26/28 pt等另立尺度；开关标题和状态普遍加粗。 |
| 4 | 工具与目录 | [工具页](screenshots/before/07-tools-wide.jpg)：连接列336 pt，与主侧栏不一致；通用表单输入与 Agent 输入字号/间距不一致。 |
| 5 | 新建 | [800×600](screenshots/before/09-new-session-800.jpg)：表单可用，但 Current/Startup 标记只有9.5 pt，部分模板说明10.5 pt。 |
| 6 | 当前会话参数 | [800×600](screenshots/before/10-session-parameters-800.jpg)、[宽窗口](screenshots/before/11-session-parameters-wide.jpg)：少量参数仍固定撑满0.62窗高，宽窗口出现大面积无用空白。 |
| 7 | 恢复 | [宽窗口](screenshots/before/12-resume-wide.jpg)：双栏任务关系清楚；与其他表单不同的额外向上偏移、按钮高度与细小标记需要统一。 |

截图中的紫色胶囊与指针光晕来自系统屏幕控制提示，不属于应用；没有在应用内复制或重绘。宽窗口图由 CUA 等比缩放，不能直接把显示后的像素当作逻辑 pt；精确尺寸由布局源码与固定视口 Flutter 截图互证。

## 阅读的 Apple 官方规范与适用判断

- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography?changes=_5)：macOS 默认文本13 pt、最小10 pt，系统字体为SF Pro。此轮以主应用 .AppleSystemUIFont / PingFang SC 字体链和已有字号层级为准，不把最小字号当作常用字号。
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)：macOS 控件默认28×28 pt、最小20×20 pt，控件间距与大小同样影响使用。设置主操作采用32 pt，与主工具栏一致；不套用触屏44 pt的统一尺寸。
- [Layout](https://developer.apple.com/design/human-interface-guidelines/layout?changes=_____7&language=objc)：保留熟悉的相对关系，适应窗口尺寸与文字变化，避开系统安全区域。此轮具体8/12/16/24 pt间距来自项目既有token，非声称Apple强制所有控件采用这些值。
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)：合理使用显示空间、保持舒适的信息密度并支持键盘。
- [Settings](https://developer.apple.com/design/human-interface-guidelines/settings)：应用设置与任务内参数分开，提供App菜单Settings和标准⌘,入口。保留用户已选定的工作区内设置页，本轮不新增独立NSWindow或改成自动保存；这是明确的产品架构选择，而不是声称完全复刻原生Settings窗口。
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows?changes=_7)：避免将关键动作只放在可能被窗口位置遮住的底栏。唯一保存与放弃移至顶部工具栏，底部仅显示状态与保存影响。
- [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons?changes=latest_1__8)：用样式表达主要动作，同组按钮保持相同尺寸；使用现有主色按钮和普通按钮，保持已保存、禁用、保存中状态。

## 调整标准

| 对象 | 本轮标准 | 主窗口/源码依据 |
| --- | --- | --- |
| 窗口顶部 | 52 pt，窄窗左侧给原生窗口控制区留88 pt；设置标题14 pt | AppShell 品牌行与 AgentToolbar |
| 设置导航 | 260 pt宽；行最小35 pt，13.5 pt文字，18 pt图标 | MacosWorkspaceLayout、AppShell侧栏 |
| 连接列表 | 260 pt宽，两行信息；名称13 pt、说明12 pt、图标18 pt | 同一侧栏宽度与label/metadata层级 |
| 表单 | 标签与输入13 pt；字段间12/16 pt，组间24 pt | AppTypography.label、AppSpacing |
| 区块 | 14 pt/600标题；说明12–12.5 pt常规字重 | AppTypography.sectionTitle、bodySmall |
| 主操作 | 顶部唯一保存与放弃，13 pt文字、32 pt控件 | 主工具栏32/34 pt控件；AppTheme按钮 |
| 窄窗口 | 分类/连接选择器，正文独立滚动；文字扩大后仍可提交或返回 | 已有响应式结构与本轮布局复验 |
| 其他表单 | 18 pt弹窗标题、12 pt说明；小数据参数窗口收紧，长列表保留懒构建 | AppTypography.dialogTitle、metadata及已有性能契约 |

## 最终对照与逐项结论

三张组合图均已打开检查：[主窗口与紧凑设置前后](screenshots/comparison/main-settings-800.png)、[主窗口与宽屏设置](screenshots/comparison/main-settings-wide.png)、[会话参数前后](screenshots/comparison/session-parameters.png)。设置前后都是 Codex、已保存、高级设置展开；主窗口是字体和密度参照，页面内容自然不同。原生紧凑源图800×600、最终799×600，组合板按800×600等比容纳，宽度差1 px不用于像素级结论。宽图统一1225×768，是CUA对最大化原生窗口的缩放结果。固定逻辑800×600、480×860和1440×1024另有DPR 1的Flutter截图。

| 范围 | 最终结论与证据 |
| --- | --- |
| Agent 设置 | [紧凑](screenshots/after/02-settings-800.jpg)、[宽屏](screenshots/after/01-settings-wide.jpg)：顶部返回不再落在原生控制区域；名称、命令、参数、工作目录同屏可见，保存始终位于顶部。 |
| 权限 | [原生](screenshots/after/03-permissions-wide.jpg)：14 pt区块、13 pt开关标题、12 pt状态和说明；指定审查来源的条件字段由[完整路径截图](screenshots/widget/08-review-source.png)和回归测试验证。 |
| AI 辅助 | [原生](screenshots/after/04-assistant-wide.jpg)：开关与备用标题关系清楚；[启用后条件字段](screenshots/widget/10-assistant-enabled.png)沿用同一尺度。 |
| 本地存储 | [原生](screenshots/after/05-storage-wide.jpg)：上限、保留期、作用范围与配置路径可读，保持已有清理语义。 |
| 工具与目录 | [目录](screenshots/after/06-tools-wide.jpg)、[MCP](screenshots/after/07-mcp-wide.jpg)：连接列统一260 pt，MCP输入与Agent表单字号一致。 |
| 新建会话 | [原生紧凑](screenshots/after/09-new-session-800.jpg)：说明12 pt、标记11 pt，目录和Start可见；点击Start创建隔离会话成功。 |
| 当前会话参数 | [紧凑](screenshots/after/10-session-parameters-800.jpg)、[宽屏](screenshots/after/11-session-parameters-wide.jpg)：少量参数按实际内容收紧，能力卡完整显示；超过4个动态参数保留有界sliver视口，1024项懒构建测试通过。 |
| 恢复会话 | [原生](screenshots/after/12-resume-wide.jpg)：取消和打开会话同组32 pt，保留Agent/会话双栏；无结果时打开禁用并说明范围。 |
| 文字扩大 | [480×860、160%文字](screenshots/widget/13b-larger-text.png)：控件按文字增长，保存/返回可操作，正文滚动；800×600和480×700/160%的几何及实际保存测试通过。 |
| 原生入口 | App菜单Settings…已连接到设置页，显示⌘,；原生实际点击成功。快捷键、重复进入和布局重建后不叠加页面的Flutter测试通过，Swift菜单目标测试通过。 |

## 验证记录

- `./tool/flutter_workspace.sh test all --reporter expanded`：应用1,390通过；共享聊天包283通过、2项既有跳过；示例2通过。
- 三个相关弹窗专项测试40通过；菜单/快捷键相关4通过；其中均包含在本轮全量结果内。
- `dart analyze .` 无问题；相关Dart文件格式检查通过；`git diff --check`通过。
- `./tool/flutter_workspace.sh test app docs/macos-settings-refinement-2026-09-09/capture_test.dart --update-goldens --reporter expanded`：1通过，输出17种状态；同目录`comparison_test.dart`：1通过。
- `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/ianvs-acp-settings-menu-derived CODE_SIGNING_ALLOWED=NO`：RunnerTests 17通过，`TEST SUCCEEDED`。本机结果包位于`/tmp/ianvs-acp-settings-menu-derived/Logs/Test/Test-Runner-2026.09.09_12-51-12-+0800.xcresult`。
- 最终Dart/Swift/XIB重新编译启动成功：`flutter run -d macos --no-pub -t docs/settings-redesign-2026-09-09/harness.dart`。CUA操作与截图来自此构建。

全量验证日志保存在本机`artifacts/macos-settings-refinement-2026-09-09/{workspace-tests,analyze,capture,comparison}.log`（按仓库规则不提交日志）。本文件保留命令与结果，截图和复现脚本随代码提交。

## 边界与迭代

第一次收紧参数弹窗时发现像素估算裁掉能力卡，见[中间态](screenshots/iteration-1/session-parameters-clipped.png)。改为少量参数在窗高上限内按真实内容shrinkWrap，最终截图完整，并断言无额外滚动距离；长列表继续懒构建。设置按钮从[中间态紧凑主题高度](screenshots/iteration-1/settings-800.jpg)改为显式32 pt，最终重新截图。

本轮原生预览使用隔离演示数据，没有真实Agent网络、凭据写入或历史会话服务端恢复的验收结论。Flutter截图替换字体为Arial Unicode以完整显示汉字，并为无窗口测试桩接AppKit材质通道，因此系统字体与材质以原生图为准。160%是Flutter测试文字缩放，不宣称macOS Dynamic Type。系统屏幕控制提示和指针光晕不属于应用。完整VoiceOver和暗色模式未在本轮人工验收。

最新设计QA见[项目根报告](../../design-qa.md)。旧生成稿验收另存为[历史报告](../settings-redesign-2026-09-09/design-qa-imagegen.md)，其大字号和底部保存栏已被本轮用户要求替代。
