# 设置重设计验收结果

> 历史设计阶段记录：字体、密度和保存按钮位置已由[后续 macOS 设置调整](../macos-settings-refinement-2026-09-09/README.md)替代。本文保留当时的设计、截图与验收结果，不作为当前界面规格。

2026-09-09：第 3 版工作区设置页已实现并通过本轮验收。原生隔离预览停留在设置页；使用 FakeAgentClient 和内存 writer，不会修改用户真实连接、凭据或配置文件。

## 交付内容

- [逐项实现标注 A1–A8](implementation-comparison.md)：分类、内联连接编辑、唯一保存点、配置作用域、权限来源、AI 辅助、会话菜单、新建与恢复入口。
- [设计与实现全图并列](screenshots/comparison/full.png)、[详情区域并列](screenshots/comparison/details.png)。
- [视觉验收与修复历史](../../design-qa.md)：最终 `passed`。
- [改版前审计](visual-audit.md)、[全部配置清单](config-inventory.md)、[入口清单](navigation-audit.md)。

## 自动验证

| 检查 | 本轮结果 | 证据 |
| --- | --- | --- |
| 应用全套测试 | 1,383 通过 | [workspace-tests.log](../../artifacts/settings-redesign-2026-09-09/workspace-tests.log) |
| 共享聊天包 | 283 通过，2 项既有跳过 | 同一日志的 `[chat]` 段 |
| 独立示例 | 2 通过 | 同一日志的 `[example]` 段 |
| 静态分析 | `dart analyze .` 无问题 | [verification.txt](../../artifacts/settings-redesign-2026-09-09/verification.txt) |
| 格式 | 应用 lib/test 146 文件，无待格式化变更 | 同上 |
| 截图旅程 | 15 个实际 Flutter 状态，1440×1024 和 480×860；测试通过 | [截图日志](../../artifacts/settings-redesign-2026-09-09/screenshots.log) |
| 设计并列板 | 全图与详情已生成、打开并逐项检查 | [comparison_test.dart](comparison_test.dart) |
| macOS Debug | 隔离 harness 构建与启动成功；最新代码热重载/重启成功 | 原生运行记录见下 |
| 工作区差异 | `git diff --check` 通过；此表记录提交前验收结果 | verification.txt |

完整测试曾发现旧菜单文案、旧弹窗定位以及新增测试 fake clock/异步清理的问题，均修复后重新运行整个 app、共享包与示例得到上述结果。本地 `app-tests.log` 保留了中间失败轮次；仓库纳入最终 `workspace-tests.log` 与截图日志，最终测试结果以 `workspace-tests.log` 为准。

## T01–T08 契约结果

| 契约 | 已验证的行为 | 主要测试 |
| --- | --- | --- |
| T01 草稿流转 | Agent/MCP/分类间切换保留草稿；确认放弃与继续编辑正确；多分类一次提交 | [agent_config_dialog_test.dart](../../test/ui/agent_config_dialog_test.dart) |
| T02 无改动保存 | 无改动不提交；普通字段还原可清除 dirty；密钥显式重新输入意图保留；加载模型不自动改写已配别名 | 同上 |
| T03 保存中退出 | 设置页返回、系统路由返回和重复提交受保护；Cmd-S/ESC 遵守保存及草稿状态 | 同上及 [settings_keyboard_accessibility_test.dart](../../test/ui/settings_keyboard_accessibility_test.dart) |
| T04 保存失败 | writer 失败保留全部输入并可重试，不替换运行 controller | 同上及 [settings_save_lifecycle_test.dart](../../test/ui/settings_save_lifecycle_test.dart) |
| T05 活动操作 | 任一后台 controller streaming/恢复时禁止写入；写入等待期间才开始的操作使已提交配置延迟应用到全体闲置 | settings_save_lifecycle_test.dart |
| T06 作用域 | 全局权限不被当前 Agent override 污染；当前/启动默认区分；三种目录、新建模板继承有明确来源 | 生命周期、新建/恢复与 app 集成测试 |
| T07 参数与菜单 | 参数即时应用；保留动态长列表/选择预算；菜单共享定义；后台目标关闭/删除不会清空或切换前台 | [session_settings_dialog_test.dart](../../test/ui/session_settings_dialog_test.dart)、[chat_controller_test.dart](../../test/state/chat_controller_test.dart)、app/sidebar 测试 |
| T08 单一编辑模型 | 只有主保存持久化；旧 transport、密钥意图与 reviewer 数据保留；Agent/MCP 改名一次更新所有关联引用 | [config_reference_updates_test.dart](../../test/config/config_reference_updates_test.dart)、设置与配置存储测试 |

## 原生界面记录

使用 `flutter run -d macos --no-pub -t docs/settings-redesign-2026-09-09/harness.dart` 构建并启动当前 Flutter/macOS 应用，通过 CUA 直接操作其窗口：

- 从侧栏“设置”进入；检查初始紧凑窗口和放大后的三栏布局。
- 编辑 Agent 名称，切到工具与目录再返回，草稿仍在。
- 返回触发未保存确认；选择继续编辑仍保留草稿。
- 点击唯一保存，列表、当前 Agent 和“更改已保存”状态更新；提示明确说明已重载及会话恢复入口。
- 打开权限页，开启指定来源后才显示来源类型、Agent 名称、模型和超时字段；离开时放弃草稿并回到会话工作区。
- 打开新建会话，核对当前 Agent、启动默认和会话工作目录说明。
- 结束时热重启隔离 fixture，清除测试状态，再打开干净的设置页。

原生窗口中中文字体和成功提示显示正常。CUA 的输入字段文本替换与键盘事件不适合作为完整键盘/读屏器验收依据；Cmd-S、ESC 和输入的语义名称另由实际 Flutter widget 事件与 semantics 测试确认通过。没有声称做过完整 VoiceOver、任意系统文字缩放或真实 Agent 网络/密钥写入测试。

## 生效边界

保存会重新加载连接配置，已有会话可能需要恢复；运行中的会话阻止保存，写入等待期间晚到的会话操作会使已提交配置等待闲置后应用。设置页的返回保护不等于阻止操作系统强制退出进程。

此轮整理现有功能，不新增模板 CRUD、工作区级配置、远程 ACP 能力、清理中心或遥测。原子配置存储和密钥迁移沿用原链路并由配置测试覆盖。上一轮 Rust/FFI/Release 验证没有冒充为本轮重跑结果。

## 复现

```sh
./tool/flutter_workspace.sh test all --reporter expanded
./tool/flutter_workspace.sh test app --update-goldens docs/settings-redesign-2026-09-09/capture_after_test.dart
./tool/flutter_workspace.sh test app --update-goldens docs/settings-redesign-2026-09-09/comparison_test.dart
flutter run -d macos --no-pub -t docs/settings-redesign-2026-09-09/harness.dart
```

`capture_test.dart` 与 `screenshots/before` 是改版前的历史基线；不要用当前改版代码运行旧界面旅程来覆盖它们。
