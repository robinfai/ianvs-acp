# 全项目安全复审后续整改 Implementation Plan

> For agentic workers: REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox syntax for tracking.

Goal: 修复固定扫描中保留的 38 个安全问题，并完成同范围复审。

Architecture: 先用定向失败测试固定每个攻击路径，再以最小局部修复关闭；同批共享请求身份、会话绑定或资源预算时抽取小型公共原语。

Tech Stack: Dart 3.12、Flutter 3.44、vendored dart_acp、Flutter Test、macOS XCTest、GitHub Actions。

---

### Task 1: 权限、会话和工作区身份绑定

Files:
- Modify: lib/acp/acp_permission_request.dart
- Modify: lib/state/chat_controller.dart
- Modify: lib/ui/components/prompt_input.dart
- Modify: lib/ui/components/resume_session_dialog.dart
- Modify: lib/ui/components/workspace_sidebar.dart
- Modify: lib/ui/shell/app_shell.dart
- Modify: third_party/dart_acp/lib/src/session/session_manager.dart
- Test: test/state/chat_controller_test.dart
- Test: test/ui/prompt_input_test.dart
- Test: test/acp/dart_acp_agent_client_test.dart

- [ ] Step 1: 写失败测试，证明相同 permission id 不同 metadata 会复用旧 review、空 session id 会被接受、A/B 工作区会回退到 A、恢复页隐藏 additionalDirectories。
- [ ] Step 2: 运行 ./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart test/ui/prompt_input_test.dart test/acp/dart_acp_agent_client_test.dart，确认新测试按预期失败。
- [ ] Step 3: 为请求增加 session、tool、command、args、cwd、path、options 和 metadata 的规范化指纹及 generation；所有 pending/reviewing/resolving 状态绑定三元组。
- [ ] Step 4: SessionManager 要求非空且命中未关闭 session；删除 values.firstOrNull 回退；恢复和侧栏选择展示 cwd 与所有额外根并确认。
- [ ] Step 5: 重跑定向测试并提交 fix: bind permissions and workspace roots to sessions。

### Task 2: Keychain 引用所有权和目标变更

Files:
- Modify: lib/config/secret_store.dart
- Modify: lib/config/acp_secret_repository.dart
- Modify: lib/config/acp_client_config.dart
- Modify: lib/config/acp_config_store.dart
- Modify: lib/acp/acp_permission_reviewer.dart
- Modify: lib/app.dart
- Test: test/config/acp_secret_repository_test.dart
- Test: test/config/acp_config_store_test.dart
- Test: test/acp/acp_permission_reviewer_test.dart

- [ ] Step 1: 写跨配置 ref 读取、伪造旧 ref 删除、伪造 cleanup sidecar 删除、同名 target 变化仍携带 secret 的失败测试。
- [ ] Step 2: 运行 ./tool/flutter_test_isolated.sh test/config/acp_secret_repository_test.dart test/config/acp_config_store_test.dart test/acp/acp_permission_reviewer_test.dart，确认 RED。
- [ ] Step 3: 定义 SecretOwner(configIdentity, targetKind, targetIdentity, fieldPath)，ref 由 owner 和随机 generation 生成并精确校验。
- [ ] Step 4: cleanup 只处理本事务新建或当前配置可证明拥有且无引用的 ref；目标 URL、command、args 或认证域变化时不复用旧 secret。
- [ ] Step 5: 重跑测试并提交 fix: bind Keychain references to config targets。

### Task 3: Egress 最终语义与 Markdown 无环境 I/O

Files:
- Modify: lib/tasks/egress_policy.dart
- Modify: third_party/dart_acp/lib/src/session/session_manager.dart
- Modify: lib/ui/components/chat_timeline.dart
- Test: test/tasks/egress_policy_test.dart
- Test: test/state/chat_controller_test.dart
- Test: test/ui/chat_timeline_test.dart

- [ ] Step 1: 写 env URL、env curl wrapper、HTTP/file Markdown 图片均触发当前错误行为的失败测试。
- [ ] Step 2: 运行 ./tool/flutter_test_isolated.sh test/tasks/egress_policy_test.dart test/state/chat_controller_test.dart test/ui/chat_timeline_test.dart，确认 RED。
- [ ] Step 3: egress policy 接受仅在内存使用的 env map，安全解析 env 赋值和已知 wrapper，无法确定最终 executable 时强制人工确认。
- [ ] Step 4: MarkdownBody 使用自定义 imageBuilder，返回无 I/O 占位并允许复制链接。
- [ ] Step 5: 重跑测试并提交 fix: classify final egress and block automatic markdown I/O。

### Task 4: ACP/MCP transport 帧与 session 生命周期预算

Files:
- Modify: lib/acp/no_redirect_mcp_http_transport.dart
- Modify: lib/acp/streamable_http_acp_transport.dart
- Modify: lib/acp/web_socket_acp_transport.dart
- Modify: third_party/dart_acp/lib/src/rpc/line_channel.dart
- Modify: third_party/dart_acp/lib/src/session/session_manager.dart
- Modify: third_party/dart_acp/lib/src/transport/stdio_transport.dart
- Test: 对应 transport tests 和 test/acp/dart_acp_agent_client_test.dart

- [ ] Step 1: 用小阈值写 JSON body、SSE event、WebSocket frame/queue、stdio 无换行行、无限 cursor、未知 session update、session close 清理的失败测试。
- [ ] Step 2: 运行 transport 定向测试并确认 RED。
- [ ] Step 3: 按原始 bytes 限 body/event/frame/line；queue 使用条数和字节双限；session list 限页数、总条目和 cursor。
- [ ] Step 4: 只接受已登记 session update；replay/tool calls 使用环形预算；closeSession 释放 stream、root、tool 和 terminal。
- [ ] Step 5: 重跑测试并提交 fix: bound ACP transports and session state。

### Task 5: 远端模型、Markdown、Mermaid 和图片预算

Files:
- Modify: lib/acp/acp_agent_capabilities.dart
- Modify: lib/acp/dart_acp_agent_client.dart
- Modify: lib/state/chat_controller.dart
- Modify: lib/ui/components/chat_timeline.dart
- Modify: lib/ui/components/resume_session_dialog.dart
- Modify: lib/ui/components/session_settings_dialog.dart
- Modify: lib/mermaid/mermaid_svg_normalizer.dart
- Modify: third_party/dart_acp/lib/src/models 下的 owning parsers
- Test: owning ACP、state、UI、Mermaid tests

- [ ] Step 1: 写递归 capabilities、图片 base64/pixel、Markdown bytes、diff 行数、commands/plan/options/meta 数量和 Mermaid work budget 的失败测试。
- [ ] Step 2: 运行 ./tool/flutter_test_isolated.sh test/acp test/state/chat_controller_test.dart test/ui test/mermaid，确认 RED。
- [ ] Step 3: 引入可注入 AcpInputBudget，模型转换迭代计数 depth/node/byte；图片限 base64 bytes、dimensions 和 pixels；UI 使用惰性列表和有界预览；Mermaid 使用 work counter。
- [ ] Step 4: 重跑测试并提交 fix: bound remote models and rendering。

### Task 6: 任务、artifact、skill、FS 与 terminal 预算

Files:
- Modify: lib/tasks/task_data_sanitizer.dart
- Modify: lib/tasks/task_event_buffer.dart
- Modify: lib/tasks 中 artifact、outbox、git 和 local skill owning files
- Modify: third_party/dart_acp/lib/src/providers/fs_provider.dart
- Modify: third_party/dart_acp/lib/src/providers/terminal_provider.dart
- Modify: third_party/dart_acp/lib/src/session/session_manager.dart
- Test: owning task、artifact、skill 和 provider tests

- [ ] Step 1: 写 sanitizer 预复制、event/write queue bytes、hash/git/outbox 前置限额、skill symlink/size、FS regular-file/streaming bytes、terminal handle 数量和 close release 的失败测试。
- [ ] Step 2: 运行 ./tool/flutter_test_isolated.sh test/tasks test/acp，确认 RED。
- [ ] Step 3: reader 统一执行 stat、canonicalize、regular-file、bounded stream；队列和 outbox 同时限制 items、bytes、time；Git 流式输出；terminal 限全局和每 session handle 并统一释放。
- [ ] Step 4: 重跑测试并提交 fix: bound task and provider resources。

### Task 7: CI、格式、全量验证和复审

Files:
- Modify: .github/workflows/macos.yml
- Modify: tool/release_scripts_test.sh
- Modify: formatter 报告的 Dart 文件
- Create: docs/reviews/2026-07-11-security-remediation-verification.md

- [ ] Step 1: 增加 workflow 必须使用 flutter pub get --enforce-lockfile --no-example 的失败契约测试。
- [ ] Step 2: 实现并运行 ./tool/release_scripts_test.sh。
- [ ] Step 3: 运行 dart format、flutter analyze、./tool/flutter_test_isolated.sh 和 native xcodebuild tests。
- [ ] Step 4: 运行 flutter build macos --release --no-pub 与 verify_macos_bundle.sh。
- [ ] Step 5: 对新 HEAD 重新执行同范围独立子代理复审；新候选重复 RED/GREEN/验证，直到清单为空。
- [ ] Step 6: 写验证报告并提交 docs: record security remediation verification。

