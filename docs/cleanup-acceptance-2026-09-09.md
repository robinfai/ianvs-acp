# 应用精简实施与验收

日期：2026-09-09。基线：`6091b82`。状态：**实施与验收完成**。

承接 [功能评估](product-review-2026-09-07/README.md) 与 [清理方案](cleanup-plan-2026-09-09.md)。本记录描述提交前完成的实施与验收结果。

## 实施结果

| 批次 | 实际变更 |
|---|---|
| C0 | `make bootstrap/format/format-check/analyze/test` 覆盖应用、聊天包、示例三个工程；CI 已配置为执行三工程离线测试并构建独立 macOS 示例 |
| C1 | 当前能力清单归一；明确 remote ACP、fork、MCP-over-ACP、实验扩展的生产限制；新配置只提供有效连接类型，已保存旧配置可继续查看、编辑和保存 |
| C2 | 删除无生产引用的 SessionSidebar、WorkspaceHeader、StatusBar 及纯旧组件测试 |
| C3 | 移除 27 个宿主纯转发文件；15 个共享测试文件、187 项测试迁入包；移除宿主直接依赖 xml/re_highlight，仍由包作为传递依赖解析 |
| C4 | 统一 Activity & Diagnostics，包含 Events、Permissions、Runtime；真实能力详情在 Runtime 展开；删除静态 Protocol Coverage；保留权限 JSON 和脱敏运行信息 |
| C5 | 独立 LLM 聊天下沉到 Agents → Advanced → Independent LLM chat；其余可选功能按方案维持现状，不新增自动调用或持久化 |

包公开文件和 barrel 导出未改变，包括 MermaidExamplePage。ACP typedef 桥接和 AcpChatSession 保留；ChatController、宿主存储及 ACP bridge 的生产差异仅为 import 迁移；Rust 源码未改变。

## 验收中发现并修复的问题

- 390×560 小窗口下 Runtime 卡片的长标题溢出：标题改为弹性布局并换行。
- 真实 macOS 权限导出失败：file_picker 在非沙箱应用中也要求用户选定文件可写 entitlement。Debug/Profile 和 Release 配置补齐该权限，发布包验证读取实际签名并检查该 entitlement。
- 旧远程配置的 `ws/https/streamable_http/streamable-http` 别名打开失败，长类型标签溢出：改为复用配置模型的 transport 判定，并使下拉列表弹性布局。canonical 类型和别名的原值、URL、headers 均有保存回归。
- 能力详情仍有 “ready / need attention” 汇总：移除计数，保留协商后的逐项状态，避免把设计上不可用的功能计为待修复。
- 权限范围说明明确为当前连接保留的历史，包含该连接的其他会话，不宣称涵盖同一 Agent 的其他并发连接。
- 包测试迁移中的宿主类型残留与可变消息 fixture 已修正，保持流式 text/revision 更新的断言意图。三张截图基线复制到包内，SHA-256 与历史文件逐一一致，未重录或放宽容差。

## 自动化与桌面证据

本地运行结果如下。Flutter 3.44.2、Dart 3.12.2；远端 CI 尚未触发，仓库保留原有 Flutter 3.44.0 固定版本。

| 检查 | 命令 | 结果 |
|---|---|---|
| 三工程依赖 | `make bootstrap` | 通过；根 lockfile 仅将两个依赖改为传递依赖 |
| 完整检查入口 | `make verify` | 退出码 0；格式、三工程 analyze、发布脚本、Rust、Flutter 顺序通过 |
| 宿主 Flutter | `make test` 的 app 阶段 | 1,368 通过 |
| 聊天包 Flutter | `make test` 的 chat 阶段 | 283 通过，2 项真实 DeepSeek API 测试按离线策略跳过 |
| 独立示例 Flutter | `make test` 的 example 阶段 | 2 通过 |
| Rust workspace | `make test-rust` | 67 项 Rust 测试通过，Clippy 无警告；另 46 项 Flutter/Rust 边界测试通过（与全量宿主测试有重叠） |
| 原生 macOS | `xcodebuild test -quiet -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' FLUTTER_TARGET=tool/cleanup_ui_harness.dart CODE_SIGNING_ALLOWED=NO` | 16 通过 |
| 正式应用构建 | `flutter build macos --release --no-pub` | 通过，入口为 `lib/main.dart` |
| 发布包验证 | `./tool/verify_macos_bundle.sh 'build/macos/Build/Products/Release/ACP Client.app'` | 通过：双架构、Rust ABI、原生依赖、签名闭包、JSON 导出 entitlement |
| 独立示例构建 | 在 `packages/ianvs_agent_chat/example` 执行 `flutter build macos --debug --no-pub` | 通过 |
| 最终差异 | `git diff --check`；包公开源码和三张 golden 对比 | 通过；包公开源码零差异，golden 字节相同 |

[检查摘要](../artifacts/cleanup-2026-09-09/verification.txt) 保存了本轮命令结果。构建出现第三方 terminal code asset 的跨架构命名警告；检查产物中 `ianvs_core.framework` 确实同时包含 x86_64 和 arm64，签名验证通过。没有在本轮改动该依赖。

真实桌面验收使用 [隔离入口](../tool/cleanup_ui_harness.dart)，运行 `flutter run -d macos --no-pub -t tool/cleanup_ui_harness.dart`。它只创建系统临时目录、FakeAgentClient 和内存侧栏状态，不启动真实 Agent、不读取用户配置、不持久化真实会话。该窗口的能力是测试 fixture 声明值，不代表真实 Rust Agent 支持范围。

在 800×600 的实际 macOS 窗口中完成并读取截图/无障碍状态确认：

1. 从侧栏打开 Events，看到提示、回复和权限事件。
2. 切换 Permissions，检查范围说明、权限决策，使用原生保存面板实际导出 JSON；重新读取 [导出样本](../artifacts/cleanup-2026-09-09/permission-history.json)，确认 schema、request ID、denied 决策与单条记录一致。
3. 切换 Runtime，看到当前连接配置；滚动并展开 Capability details，确认逐项状态可读、旧完成度计数已消失。
4. Escape 返回原会话；从 Agent 菜单进入 Advanced → Independent LLM chat，打开连接表单后返回，原会话仍在。

自动化另覆盖 390×560 小窗口的三个 tab、展开能力详情、Escape 与焦点返回；同一容器内新建/关闭会话、替换 controller、跨会话保留导出范围，以及迟到的旧导出结果不污染新视图。

## 保留的边界与后续方向

产品继续聚焦本地项目中的 Agent 会话：选项目、执行任务、理解工具与权限、恢复工作。近期优先验证会话恢复、错误提示与新用户配置流程的实际使用收益。

AI 标题、总结、自动 reviewer 维持现有默认与回退策略；MCP、模板、手动终端、worktree 保留。远程 Agent、Memory、后台 Workflow、完整 IDE 暂缓扩张。独立 LLM 会话不会混入 ACP 历史、恢复或权限模型。

未删除用户配置、Keychain、会话数据库、缓存、工作区索引或磁盘 worktree；未调整存储容量与淘汰策略；未触发真实模型计费请求。
