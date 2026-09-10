# 文档校准记录

日期：2026-09-10。核对源码：`b9297f5`。范围：仓库原有 49 份 Markdown/文本说明，
包括根说明、docs、包/example、工具和 artifacts 中的记录。本次修改仅涉及 Markdown，
不修改应用实现、依赖、测试、截图或用户数据。

## 发现与处理

| 编号 | 问题 | 校准结果与依据 |
| --- | --- | --- |
| D01 | 没有统一入口，现行说明、候选计划和历史验收容易混用 | 新增[文档导航](README.md)，列明主题负责人文档、阶段、后继关系和维护规则 |
| D02 | 根 README 同时承担长配置示例、运行时细节和包渲染 API；存储说明多处重复 | 配置细节迁到[配置指南](configuration.md)，Mermaid API 归[包 README](../packages/ianvs_agent_chat/README.md)，存储策略归[本地恢复存储](sqlite_storage.md)；根说明保留简介、工作流和开发发布入口 |
| D03 | README 将恢复描述为优先 resume；加载架构仍以 `6091b82` 为当前基线，遗漏仅支持 resume 的降级 | 按 [controller](../lib/state/chat_controller.dart) 与 [Rust runtime](../rust/crates/ianvs-acp-core/src/runtime.rs)修正 load/缓存/resume 决策；区分缓存可见、完整回放可见和仅重连无历史，补齐 `onEvent` 与请求独立摘要契约 |
| D04 | 能力/架构文档把诊断容器整体描述为当前会话范围 | Events 随当前会话；Permissions 读取当前 controller/connection 保留的历史，可能包含其其他会话，不汇总其他连接。依据 [诊断容器](../lib/ui/components/activity_diagnostics_dialog.dart)和[导出范围回归](../test/ui/activity_diagnostics_dialog_test.dart) |
| D05 | 当前配置说明缺少草稿与保存时序，历史盘点的“立即重载”会掩盖晚到操作 | 配置指南说明无改动不保存、失败保留草稿、忙碌阻止保存、写入期间晚到操作使已提交配置延迟应用。依据 [`_saveConfig`](../lib/app.dart)与[保存生命周期测试](../test/ui/settings_save_lifecycle_test.dart) |
| D06 | “模板遗漏字段继承”表述过宽，易误解为权限对象逐字段合并；额外目录无法靠空列表收窄未明确 | 按 [`forSessionTemplate`](../lib/config/acp_client_config.dart)说明权限/助手按对象继承或替换、MCP 未指定和空数组的区别、模板目录与全局目录取并集 |
| D07 | 最新的新会话阶段提示与未开始会话隐藏未进入现行说明 | 产品能力、README、存储说明补充创建进度和首次 prompt 前的侧栏过滤；依据[新会话测试](../test/ui/new_session_loading_test.dart)，不把 UI 隐藏误写成没有持久元数据 |
| D08 | 旧配置清单把“越界读取”字段直接当作生效能力 | 现行配置/能力/架构明确该字段未接入 Rust，旧表加校准注；[运行时工厂](../lib/app.dart)只传 read/write，[Rust 读取](../rust/crates/ianvs-acp-core/src/filesystem.rs)仍校验根目录。界面与实现的剩余差异转入[人工后续项](manual_followups.md) |
| D09 | 第 3 稿历史设计页的“视觉验收”仍指向已被下一轮覆盖的根 `design-qa.md` | 改链到同轮[生成稿 QA](settings-redesign-2026-09-09/design-qa-imagegen.md)，并保留指向[后续 macOS 调整](macos-settings-refinement-2026-09-09/README.md)的明确关系；原本文件存在，问题是证据阶段错配 |
| D10 | 产品评估子报告、改版前审计、早期参考规格和部分 artifacts 没有独立的历史标识 | 在各文件开头补阶段/替代说明；旧建议、行号、测试数和截图保留，不重写为当前待办或新验收。已标明历史的 superpowers 方案不重复改写 |
| D11 | 存储文档只列相对文件名，“50 GB”未说明二进制单位；加载文档把 30,939,722 bytes 写成约 30.9 MiB | 按[路径解析](../lib/storage/app_state_path.dart)补自定义配置的状态目录规则；容量为每个 payload store 50 GiB，UI index 不受该策略约束；历史缓存样本改为约 30.9 MB / 29.5 MiB |
| D12 | 包首版发布/测试记录和当前源码说明混排；探测工具把候选模型写成公共型号 | 包记录限定为 `6091b82` 首版历史验收，注明本地 path 消费和发布归档差别；模型文档按[脚本](../tool/codex_model_probe/probe.mjs)说明候选字符串、`unknown` 状态及“任一成功即退出 0”，不宣称当前账号可用 |
| D13 | 恢复会话 QA 的唯一原始图出处是另一台机器的绝对路径，并使用 CSS 尺寸术语描述 Flutter | 改为仓库保留的[参考裁图](../artifacts/product-design-resume-session/reference-dialog.png)与[最终对照](../artifacts/product-design-resume-session/comparison-final.png)，明确完整原始图未随仓库提供；改称 Flutter 逻辑视口 |

## 仍需后续处理的边界

- “允许越界读取”的 UI/运行时不一致仍存在。本次完成说明校准，未决定新增越界权限或删除配置；
  后续决策和验证要求只在[人工后续项](manual_followups.md)维护。
- pub.dev 首版链接未取得可读页面内容，外部发布状态没有重新核验。首版测试和发布描述作为
  历史记录保留；本轮没有调用真实 LLM 或模型探测脚本。
- 早期体验报告的未落实项不能仅凭日期判定已修复。历史标识说明证据边界，当前是否仍可复现
  需要针对现构建的桌面复验；未新增或覆盖截图。

## 本次验证

已运行以下现有定向测试，**42 项通过**，退出码 0：

```sh
./tool/flutter_test_isolated.sh \
  test/docs/runtime_documentation_test.dart \
  test/ui/activity_diagnostics_dialog_test.dart \
  test/ui/new_session_loading_test.dart \
  test/ui/settings_save_lifecycle_test.dart \
  test/acp/rust_acp_agent_client_test.dart \
  --reporter expanded
```

覆盖文档入口、已移除兼容路径约束、权限导出范围、新会话进度、设置延迟应用和并发恢复摘要。
测试使用隔离 HOME，没有调用真实 Agent 或模型服务。

文档检查覆盖整理后的 52 份说明，结果如下：

- 521 个本地链接的目标文件/目录全部存在；1 个 Markdown 标题锚点通过。
- 165 个历史源码行号链接只检查目标存在，行号含义仍以各报告原基线为准，未冒充当前行号验证。
- 1 个 JSON 配置示例语法解析通过。
- `git diff --check` 通过；工作树仅有 30 份既有 Markdown 修订和 3 份新增 Markdown。
本轮未运行全量 `make verify`、macOS 原生操作、签名发布、真实 Agent 或 Keychain 验收；
各历史记录中的通过数量不计入本次 42 项。
