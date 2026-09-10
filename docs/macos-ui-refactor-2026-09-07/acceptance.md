# macOS UI 重构与验收

> 历史阶段验收（2026-09-07）。此后设置和表单已重做，见[macOS 设置调整](../macos-settings-refinement-2026-09-09/README.md)。下文测试数量和通过结论仅属于当轮范围。

日期：2026-09-07

## 设计依据

- [Apple：Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple：Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Apple：Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)

沿用 Flutter 应用架构、系统字体和原生 NSWindow，以 macOS 的工具栏、侧栏、检查器和菜单交互组织现有功能。

## 已实现

- 52 点工具栏统一放置侧栏开关、会话标题、代理菜单、终端、上下文开关和新会话操作。
- 导航侧栏默认 260 点，可拖动至 220–320 点，双击分隔条恢复默认宽度；移除重复的当前会话区。
- View 菜单增加 Toggle Sidebar（⌃⌘S）与 Toggle Context（⌥⌘I），经原生通道交给当前窗口执行。保留原有应用、Edit、Window 菜单。
- 小于 780 点宽时侧栏入口打开居中对话框；小于 1280 点时上下文入口打开对话框。宽窗口可直接切换检查器。
- 保持会话子树的身份，避免侧栏切换或窗口尺寸变化销毁输入草稿。布局偏好在当前窗口组件生命周期内保留。
- 侧栏选中行、默认操作和焦点使用蓝色强调；统一紧凑控件圆角、弹出层阴影和工具栏按钮语义标签。
- 会话正文使用完整内容平面，检查器以细分隔线区分；移除检查器内部卡片边框与多余留白，缩小输入区底部留白。

## computer-use 验收

使用 CUA 操作实际编译的 macOS 应用；会话操作使用项目已有 FakeAgentClient 验收入口，不发送真实代理请求。

| 操作 | 结果 |
| --- | --- |
| 工具栏收起/恢复侧栏 | 正常；输入草稿保留 |
| 从 View 菜单切换侧栏 | 正常 |
| 原生输入焦点下按 ⌃⌘S | 正常恢复侧栏；草稿保留 |
| 最大化窗口 | 会话与上下文三栏正常显示 |
| 按 ⌥⌘I | 检查器正常收起 |
| 调整窗口大小 | 内容重新布局，工具栏切换紧凑操作 |
| 800×600 初始窗口打开上下文 | 居中对话框正常显示；Escape 可关闭 |
| 打开/关闭终端面板 | 正常；输入区域与终端无重叠 |
| 打开代理设置 | 表单可滚动；Close 可关闭 |

验收发现并修正了仅使用 Flutter 快捷键时原生输入焦点下命令失效的问题，因此增加原生 View 菜单桥接。截图和实时 AX 状态保留在本任务的 computer-use 工具结果中。

## 自动验证

- `flutter analyze --no-pub`：无问题。
- `flutter test --no-pub test/ui`：560 个测试中 559 个通过，剩余一项是检查器新增分隔线后旧样式断言失配。更新对应断言后重跑 `file_preview_workspace_test.dart` 与 `app_shell_test.dart`，60 个测试全部通过。
- 新增布局回归测试覆盖草稿保留、侧栏快捷键、拖动调整及 760×560 窗口；既有测试继续覆盖 390 点窄布局、会话切换和文件预览。
- macOS 原生菜单已通过本机编译及实际操作验证。

复现模拟会话验收：

```sh
flutter run -d macos -t docs/design-audit-2026-06-05/audit_harness.dart --dart-define=AUDIT_SCENARIO=active
```

正常应用构建：

```sh
flutter build macos --debug --no-pub
```

最终交付检查：正常 `lib/main.dart` 入口的 macOS Debug 构建成功，并通过 computer-use 启动确认空会话界面、已有工作区列表和工具栏正常显示。正常应用窗口已保留打开。
