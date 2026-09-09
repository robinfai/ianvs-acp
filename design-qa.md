# macOS 设置与表单设计验收

2026-09-09。本轮以用户指定的**主应用窗口实际字号、间距**为准，结合已阅读的 Apple macOS 规范调整。此前第3张生成稿仅保留信息架构方向，其放大字号和底部保存栏已被新要求替代。原生复验与回归验证完成，没有未解决的 P0/P1/P2 问题。

## 对照输入与归一化

- source visual truth：[主窗口紧凑](docs/macos-settings-refinement-2026-09-09/screenshots/before/01-main-800.jpg)、[主窗口宽屏](docs/macos-settings-refinement-2026-09-09/screenshots/before/08-main-wide.jpg)。本轮修改前重新捕获，配合现有AppTypography/AppSpacing和侧栏、工具栏组件确定尺度。
- implementation screenshot：[最终紧凑设置](docs/macos-settings-refinement-2026-09-09/screenshots/after/02-settings-800.jpg)、[最终宽屏设置](docs/macos-settings-refinement-2026-09-09/screenshots/after/01-settings-wide.jpg)。两侧均是原生macOS隔离预览，设置前后均为Codex、已保存、高级设置展开。
- 同一比较输入：[主窗口与设置前后](docs/macos-settings-refinement-2026-09-09/screenshots/comparison/main-settings-800.png)、[宽屏主窗口与设置](docs/macos-settings-refinement-2026-09-09/screenshots/comparison/main-settings-wide.png)、[会话参数前后](docs/macos-settings-refinement-2026-09-09/screenshots/comparison/session-parameters.png)。三张组合图均已实际打开、检查；不是仅分别看图。
- 紧凑源图800×600，最终原生图799×600，组合板用800×600等比容纳，保留1 px宽差、不做拉伸。宽屏源图和实现图均1225×768，由CUA等比缩放；不能把缩放图像素当作逻辑pt。精确逻辑尺寸由布局源码、DPR 1的Flutter固定800×600截图与几何断言互证。原生应用没有CSS视口。
- 主窗口与设置是不同页面，比较字体、工具栏和侧栏尺度；不要求正文内容相同。参数前后均为Codex/GPT-5 Codex/Medium及相同能力卡；背景遮罩深浅不作为前景布局结论。
- 紧凑组合板已按原始尺寸打开，标题、标签、输入文字和按钮可读，因此不另裁切放大该板。宽屏板用于整体比例，较小文字再由已打开的原生紧凑图和固定视口Flutter图核对，不据缩略图宣称像素完全一致。

## 发现、修复与复核历史

| 发现 | 修复 | 最终证据 |
| --- | --- | --- |
| P2：设置28 pt页标题、23 pt连接标题、15 pt导航比主窗口明显偏大；窄窗头部与底部占用过多 | 顶部52 pt，标题/区块14 pt、导航13.5 pt、字段13 pt；保存/放弃移入顶部，底部仅状态 | 紧凑组合图：命令、参数、工作目录同屏可见，正文空间明显恢复 |
| P2：窄窗返回与原生窗口控制区域重叠 | 无全局侧栏时为原生控制区留88 pt | 最终紧凑原生图及800×600的返回位置断言 |
| P2：连接列336 pt、全局导航268 pt与主窗口默认260 pt不一致 | 两列统一260 pt；保留小窗口选择器和正文独立滚动 | 宽屏组合图与799×600原生图 |
| P2：初次按钮仍受紧凑主题影响，实际高度偏小 | 显式32 pt、standard density，文字扩大时允许增长 | [初次设置截图](docs/macos-settings-refinement-2026-09-09/screenshots/iteration-1/settings-800.jpg)与最终原生图；160%文字布局测试 |
| P2：少量会话参数固定占满窗高；首轮按像素估算收紧又裁掉能力卡 | 不超过4个动态参数时在窗高上限内按实际内容shrinkWrap；长列表保留有界sliver | [裁切中间态](docs/macos-settings-refinement-2026-09-09/screenshots/iteration-1/session-parameters-clipped.png)、最终参数组合图；能力卡零滚动距离和1024项懒构建测试 |
| P2：新建/恢复弹窗的小标记、间距和偏移不统一 | 标题18 pt、说明12 pt、标记11 pt，采用8/12/16/24间距；恢复窗口取消额外上移，操作控件32 pt | [新建紧凑图](docs/macos-settings-refinement-2026-09-09/screenshots/after/09-new-session-800.jpg)、[恢复图](docs/macos-settings-refinement-2026-09-09/screenshots/after/12-resume-wide.jpg)及短窗口测试 |
| P2：原生应用菜单Settings入口未接通 | Swift菜单目标、Flutter通道和⌘,统一进入设置，跨入口及重建防重复打开 | 最终原生菜单点击成功；4项菜单/快捷键测试和17项RunnerTests通过 |

## 五项视觉检查

| 检查面 | 最终结论 |
| --- | --- |
| 字体与层级 | 原生系统字体链保持不变；导航与主窗口一致，设置标签13 pt、说明12–12.5 pt，标题14/18 pt。设置不再使用展示型大标题。中文、输入与状态完整可读。 |
| 间距与布局 | 52 pt工具栏、260 pt两列及8/12/16/24 pt间距来自既有组件；连接区、内容区和高级字段对齐。480 px宽和160%文字时正文可滚动、保存/返回可用；少量参数没有大块空白或被裁能力卡。 |
| 颜色与状态 | 沿用浅灰面板、分隔、蓝色主操作/焦点和橙色草稿状态。禁用保存、编辑草稿、放弃确认、保存后状态分别有截图及测试；未新增颜色体系。 |
| 图标与资产质量 | 使用现有Material图标与原生窗口控件，无新生成资产、缺失图标或图片占位。CUA导出JPEG有压缩及缩放，截图不是产品内资产；系统控制提示和指针光晕不属于应用。 |
| 文案与作用域 | 保留启动默认、当前Agent、进程工作目录、会话目录和附加目录的区别；唯一显式保存准确说明连接重载影响。当前会话参数仍即时应用，恢复空状态说明Agent返回范围。 |

## 功能与验证

原生最终构建实际操作了App菜单Settings、返回、五分类、MCP、创建隔离会话、当前参数和恢复空状态。快捷键、重复进入、保存/放弃、草稿跨分类保留、只读、忙碌保护、失败重试、字段语义和引用更新均由实际Flutter测试覆盖。

工作区测试：应用1,390通过，共享聊天包283通过且2项既有跳过，示例2通过。RunnerTests 17通过。全仓静态分析无问题，格式检查及`git diff --check`通过。截图脚本输出17种状态，组合脚本通过。命令、原生证据、Apple来源及复现说明见[完整验收记录](docs/macos-settings-refinement-2026-09-09/README.md)。

## 有意保留的差异与测试边界

- 保留工作区内设置页和显式保存机制，没有改为独立NSWindow/自动保存；Apple Settings建议的原生菜单与快捷键已接通。不声称完全复制原生系统设置窗口。
- 测试截图使用Unicode替代字体，并桩接无窗口环境缺失的AppKit材质通道；实际系统字体、材质和窗口区域以原生截图为准。160%是Flutter文字缩放测试，不是macOS Dynamic Type。
- 原生预览使用FakeAgentClient和内存writer；本轮没有验证真实网络、凭据写入或服务端历史恢复。没有声称完成VoiceOver、暗色模式、任意系统字体设置或强制退出保护的人工验收。
- 旧生成稿验收归档于[历史报告](docs/settings-redesign-2026-09-09/design-qa-imagegen.md)。本文件是最新标准及最终结论。

final result: passed
