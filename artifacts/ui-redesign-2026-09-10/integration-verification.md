# 主线整合验证 — 2026-09-11

整合基线：`8a7f53f`（Ianvs Design 与公共聊天包迁移）。原始 UI 工作保留在本地备份分支 `codex/ui-refinement-pre-integration`。

- 应用 UI：`./tool/flutter_test_isolated.sh test/ui --reporter expanded`，368 个通过。
- 公共聊天包 UI：在 `packages/ianvs_agent_chat` 运行 `../../tool/flutter_test_isolated.sh test/ui --reporter expanded`，213 个通过，1 个已有金图差异。
- 该金图用例为 `ChatTimeline markdown links and code block match accepted visuals`，差异 4.17% / 25,049 像素。用远端原版 `8a7f53f` 的 ChatTimeline 在同一环境重跑，得到相同差异。本次未更新金图掩盖差异。
- 完整工作区 `flutter analyze --no-pub`：无问题。
- 验证期间未修改版本锁文件；示例工程离线依赖恢复产生的锁文件差异已还原。

最新整合没有重新运行 macOS 构建；README 中的构建成功记录属于整合前版本。旧设计截图与录制脚本保留为历史材料。
