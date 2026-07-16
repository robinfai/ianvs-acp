# ACP 内容与界面资源预算执行索引

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 按已批准规格关闭 ACP 普通内容、媒体、会话状态和 UI 渲染的资源放大路径。

**Architecture:** 严格按“基础预算与 owning models → SessionManager/client → ChatController → UI”串行实施。每层在首次拥有语义的边界限制资源，并只向下一层传递不可变 typed model 或固定 omission。

**Tech Stack:** Dart 3、Flutter、内嵌 `third_party/dart_acp`、`flutter_test`。

---

## 执行顺序

- [ ] 1. 执行 [模型与基础预算计划](2026-07-12-acp-content-model-budgets.md)。
- [ ] 2. 第 1 份计划测试通过并提交后，执行 [会话与客户端预算计划](2026-07-12-acp-session-client-budgets.md)。
- [ ] 3. 第 2 份计划测试通过并提交后，执行 [控制器状态预算计划](2026-07-12-chat-controller-state-budgets.md)。
- [ ] 4. 第 3 份计划测试通过并提交后，执行 [UI 渲染与图片预算计划](2026-07-12-acp-ui-render-budgets.md)。
- [ ] 5. 运行跨层和 Task4 回归：

```bash
./tool/flutter_test_isolated.sh test/acp test/state/chat_controller_test.dart test/ui/chat_timeline_test.dart test/ui/prompt_input_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart test/ui/acp_client_app_test.dart
./tool/flutter_test_isolated.sh test/acp/line_channel_budget_test.dart test/acp/stdio_transport_budget_test.dart test/acp/streamable_http_acp_transport_test.dart test/acp/web_socket_acp_transport_test.dart test/acp/dart_acp_agent_client_test.dart test/tasks/task_runner_test.dart
flutter analyze --no-pub
dart analyze third_party/dart_acp
git diff --check
```

- [ ] 6. 委派独立子代理做规格符合性评审，逐条核对批准规格 A/B/C/D/E、exact/+1、payload-free 和生命周期验收项。
- [ ] 7. 委派另一独立子代理做代码质量评审，检查重复 guard、异步释放、状态别名、兼容性和复杂度。
- [ ] 8. 每个可复现发现先补 RED 测试，再修复并重跑所属层与跨层门禁；循环到两个评审均无可报告问题。
- [ ] 9. 对与初始安全扫描相同的整个仓库范围执行标准安全复扫，比较原 38 项发现；如仍有同范围发现，继续 RED/GREEN。
- [ ] 10. 运行最终门禁并保存证据：

```bash
./tool/flutter_test_isolated.sh
flutter analyze --no-pub
dart analyze third_party/dart_acp
git diff --check
git status --short
```

## 并行与交接规则

- 四份主计划不并行；它们修改共享公共 API。
- C 由单一集成负责人完成；D 与 E 因共享 `lib/app.dart` 也不并行。
- 子代理必须交付修改摘要、测试命令与结果、未解决风险、提交哈希。
- 主代理在每个任务后复查实际 diff，不只依赖交接结论。

## 每个 checkbox 的 TDD 节奏

- “写 RED”列出的每个边界先落成一个有明确名称的单测；立即用 `--plain-name` 只运行该测试并确认因缺失行为失败。
- 只写让该单测变绿的最小实现，再重跑同一测试；随后才进入同一 checkbox 的下一个边界。
- 每个 Task 末尾列出的整文件命令是回归门禁，不能替代逐测试 RED/GREEN。
- 新增测试名称必须描述资源、exact 或第一个拒绝值；不得使用计划中不存在的笼统 `--plain-name`。
