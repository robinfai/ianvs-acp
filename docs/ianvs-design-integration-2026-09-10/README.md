# Ianvs Design 接入记录

记录日期：2026-09-10。主应用、`ianvs_agent_chat` 和独立 example 已统一使用
pub.dev 的 `ianvs_design: ^0.2.0`，Flutter 最低版本为 3.44.0。
旧的 `AppTheme`、`AppColors` 等通用主题实现已移除；本轮完成整体主题接入。

## 上游需求与发布

设计库项目自行评审后，将平台等宽字体和受控面板分隔手柄纳入公共 API：

- `IanvsTypography.code`：共享代码字体、回退字体和样式配置。
- `IanvsResizeHandle`：拖动、键盘与语义操作，支持范围限制及重置；尺寸状态由宿主持有。
- 原生输入代理和工作区状态继续由 ACP 管理，设计库提供通用组件与接入边界说明。

上游主线提交为 `96b94031e35d103c128838780d24d6c185319d5c`，标签为
[`v0.2.0`](https://github.com/robinfai/ianvs-design/tree/v0.2.0)，
已发布到 [pub.dev](https://pub.dev/packages/ianvs_design/versions/0.2.0)。
详见上游的[接入指南](https://github.com/robinfai/ianvs-design/blob/v0.2.0/docs/integration.md)
与[发布记录](https://github.com/robinfai/ianvs-design/blob/v0.2.0/docs/releases/0.2.0.md)。

ACP 最终验证使用正式 hosted 包，三个工作区均无本地 dependency override。
发布归档 SHA-256 为
`93116383a192a73da0ccbe2be2ce3eef9f5440195cc111ed3574461be2e1ff26`；
发布包的 20 个 Dart 库源文件与上游本地验证版本逐一比对一致。

## 接入范围

- 启动页、主窗口、工作区、设置、对话框及聊天视图从环境主题读取颜色和排版，跟随系统深浅色切换。
- 设置页使用共享表单分区、字段行、输入框、设置行及按钮；其他 Material 控件继承同一主题。
- 侧栏使用共享分隔手柄，ACP 继续持有宽度、显示状态和快捷键。
- 聊天保留 `ChatThemeData` 的局部覆盖能力；未覆盖颜色随宿主主题更新，正文默认 15 px。
- 代码块使用共享等宽字体，语法高亮和 Mermaid 跟随深浅色。终端 ANSI 调色板仍由终端渲染器管理。
- macOS 窗口背景使用系统颜色，原生输入代理及其语义桥接保持在宿主中。

本次提交基于包含 Agent 启动恢复修复的主线 `43a64dc`；最终 UI 测试和
macOS Release 构建均在合入该修复后执行。

## 验证结果

环境：macOS，Flutter 3.44.2 / Dart 3.12.2。

| 检查 | 结果 |
| --- | --- |
| 主应用、聊天包、example 静态分析和格式检查 | 全部通过 |
| 主应用 UI 测试 | 368 项通过 |
| 聊天包测试 | 283 项通过；2 项真实服务测试按既有配置跳过 |
| 独立 example 测试 | 2 项通过 |
| 本轮截图测试 | 2 项通过，生成 10 张截图 |
| macOS Release 构建 | 通过，产物约 111.9 MB |
| `make verify-macos` | Bundle、动态库与签名闭包校验通过 |

主题回归覆盖系统深浅色切换、局部聊天颜色覆盖、发送/停止按钮对比度、缓存代码高亮随主题切换，
并更新了经检查的聊天金图。构建和 Bundle 校验不等同于公证或实际安装验收；
本轮未执行真实模型服务测试或人工 VoiceOver 验收。

在仓库根目录复现：

```sh
./tool/flutter_workspace.sh bootstrap all
./tool/flutter_workspace.sh analyze all
./tool/flutter_workspace.sh format-check all
./tool/flutter_workspace.sh test app --reporter expanded test/ui
./tool/flutter_workspace.sh test chat --reporter expanded
./tool/flutter_workspace.sh test example --reporter expanded
./tool/flutter_workspace.sh test app --reporter expanded docs/ianvs-design-integration-2026-09-10/capture_test.dart
flutter build macos --release --no-pub
make verify-macos
```

## 截图证据

截图由 [capture_test.dart](capture_test.dart) 使用离线设置 fixture 生成，
覆盖 1440 × 1024 桌面窗口、600 × 850 窄窗口及窄窗口下 200% 文字缩放。
测试显式加载替代字体以保证中文可读，因此截图用于检查布局与主题，不能证明原生字体和 AppKit 行为。

| 场景 | 浅色 | 深色 |
| --- | --- | --- |
| 工作区 | [截图](screenshots/light-workspace.png) | [截图](screenshots/dark-workspace.png) |
| Agent 设置 | [截图](screenshots/light-settings.png) | [截图](screenshots/dark-settings.png) |
| 权限设置 | [截图](screenshots/light-permissions.png) | [截图](screenshots/dark-permissions.png) |
| 窄窗口 | [截图](screenshots/light-narrow.png) | [截图](screenshots/dark-narrow.png) |
| 200% 文字缩放 | [截图](screenshots/light-large-text.png) | [截图](screenshots/dark-large-text.png) |
