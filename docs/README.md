# 文档导航与维护约定

校准日期：2026-09-10。文档梳理以源码 `b9297f5` 为基线，提交为 `cb1c34f`。随后配置与运行时说明已同步到越界读取修复（FFI ABI v11）；对应记录见[兼容维护](compatibility-maintenance.md)。

先按问题选择下表中的现行说明。带日期的设计、评审、计划和验收文件记录各自阶段，
其中的“当前”“已完成”和测试数量只对该阶段有效。历史截图、生成稿和 Fake 的能力
不能证明当前生产运行时具备相同能力。

应用自 2026-09-11 起使用名称 **Shift**，含义为“切换工作方式，把任务交给 Agent”。
历史记录中的 ACP Client 是当时的应用名称；命名和兼容标识见[项目 README](../README.md)。

## 现行说明

| 文档 | 负责内容 |
| --- | --- |
| [项目 README](../README.md) | 项目简介、开发、构建与发布命令 |
| [产品能力](product_capabilities.md) | 主应用当前提供的能力及不可用项 |
| [配置指南](configuration.md) | 设置入口、保存与生效、配置示例、模板继承和已知字段限制 |
| [运行时架构](runtime_architecture.md) | Rust/FFI/Flutter、并发会话、MCP、终端与恢复的责任边界 |
| [会话加载架构](conversation_loading_architecture.md) | load/resume 决策、原子可见性、缓存与传输；末尾性能数字为历史实测 |
| [本地恢复存储](sqlite_storage.md) | 数据清单、实际路径、容量、保留期及维护时机 |
| [Agent Chat 模块边界](agent_chat_module.md) | 主应用如何接入独立包；首版验收另行标明历史范围 |
| [共享设计系统](ianvs-design-integration-2026-09-10/README.md) | Ianvs Design 接入、主题边界与本轮验证 |
| [聊天包 README](../packages/ianvs_agent_chat/README.md) | 包的公开接入、LLM、Mermaid、主题、生命周期和原生集成 |
| [独立 example](../packages/ianvs_agent_chat/example/README.md) | 离线演示及临时 API 连接的运行方式 |
| [人工后续项](manual_followups.md) | 尚需产品决策、真实服务或桌面验收的事项 |
| [兼容维护](compatibility-maintenance.md) | 仍保留的兼容路径、退役条件；9 月 9 日实施/测试记录为历史证据 |
| [模型探测工具](../tool/codex_model_probe/README.md) | 本地探测脚本用法及结果含义；不是模型可用性目录 |

[ACP runtime coverage](acp_runtime_coverage.md) 只保留旧链接跳转说明，已不维护独立能力清单。

## 历史记录与后继关系

| 记录 | 状态与阅读方式 |
| --- | --- |
| [6 月设计评审](design-audit-2026-06-05/report.md) | 当时截图与问题；不直接转为今天的待办 |
| [6–7 月方案](superpowers) | specs/plans 已标明历史基线；实现现状查现行说明，不能重新执行整套旧计划 |
| [ChatGPT Desktop 参考规格](chatgpt-desktop-reference-ui-spec.md) | 早期视觉目标；布局/密度经后续 macOS 重构调整 |
| [9 月 7 日产品评估](product-review-2026-09-07/README.md)及其三个子报告 | 基线 `322cc03`；包抽离和清理前的盘点，文件位置、删除候选、完成率均为历史 |
| [9 月 7 日 macOS 重构验收](macos-ui-refactor-2026-09-07/acceptance.md) | 当轮布局、原生菜单和测试记录；设置随后重做 |
| [9 月 9 日清理方案](cleanup-plan-2026-09-09.md) → [清理验收](cleanup-acceptance-2026-09-09.md) | 已执行；保留原方案取舍，残留兼容问题由兼容维护承接 |
| [设置重设计](settings-redesign-2026-09-09/README.md) | config-inventory/navigation-audit/visual-audit/validation-matrix 为改版前基线；验收与实现对照记录所选第 3 稿 |
| [第 3 稿设计 QA](settings-redesign-2026-09-09/design-qa-imagegen.md) | 当轮结论；大字号、留白和底部保存栏已被下一轮替代 |
| [macOS 设置调整](macos-settings-refinement-2026-09-09/README.md)与[根设计 QA](../design-qa.md) | 当轮设置视觉验收，记录于 `997b246`；主题已由 9 月 10 日共享设计系统接入替代 |
| [验收材料目录](../artifacts/README.md) | 截图、金图和迭代报告；按各自日期/场景解释，保留可复现材料 |
| [本次校准记录](documentation-audit-2026-09-10.md) | 本次发现、修订、剩余问题和验证范围 |

## 维护规则

1. 每个主题维护一个详细事实来源。README 提供简介和入口，其他文件以链接引用；
   配置示例归配置指南，包 API 和 Mermaid 归包 README，存储策略归存储说明。
2. 修改行为时同步负责该主题的现行说明，标明核对日期和源码基线。以生产接线和测试
   核对“支持”，不能仅依据类型、Fake 或表单字段推断运行时能力。
3. 新增计划/评审/验收须标明状态、基线、实测与未测范围。旧记录被替代时在文件开头
   指向后继；子报告也要能独立辨认状态，不能只靠目录 README。
4. 证据链接指向同一轮记录。不要让历史报告中的“最终 QA”随根 `design-qa.md` 更新
   而变成另一轮结论。旧截图和金图不因文档整理重新生成。
5. 现行说明优先链接文件和符号名；历史行号只在记录的 Git 基线下解释。新证据使用
   仓库内相对链接，机器临时路径只能作为补充出处，不能成为唯一可访问证据。
6. 测试数量必须附阶段和范围。复用旧验收不等于重跑；文档校准不能宣称真实 Agent、
   Keychain、原生窗口或发布验收通过。
