**Findings**
- 无 P0/P1/P2 阻断项。

**Open Questions**
- 源图里的 `Run summary` 是更激进的信息压缩方向；本次实现保留现有 `Tool`、`Implementation plan` 和 `Available Commands` 卡片结构，只调整 shell 布局归属，避免改动 ACP 事件渲染语义。
- 源图右侧 `Providers` 在 Overview 下直接可见；当前实现仍通过 `Context` tab 查看 provider 详情。本次不新增信息源，只保留现有 inspector 数据边界。

**Implementation Checklist**
- 已将 prompt composer 从全窗口底部移动到中间 conversation column。
- 已将 status strip 移入中间 conversation column，并把 live status、idle、latency 放在长路径之前。
- 已给 workspace sidebar 增加搜索框，支持按 workspace 名称、路径、session 标题和 agent 名过滤。
- 已进一步收紧可见入口：桌面只保留一个显性的 `New Session` 文本入口；workspace 新建收进行内动作菜单；空状态不再重复放按钮。
- 已压缩 shell 外边距、workspace header、sidebar 行距、status bar 高度和左右信息栏宽度，让主对话区占比更高。
- 已移除 status bar 里不可用的 `Theme` 占位入口，只保留实际可用的 session settings 和 ACP compatibility。
- 已将 workspace header 从拼接副标题改为两个并列状态块：左侧项目，右侧当前会话；窄屏自动堆叠。
- 已将 sidebar 里的当前 workspace 改为项目条呈现，用左侧色条、项目名、路径和数量建立层级。
- 已将当前 session 改为独立 active 条，历史 session 压缩为单行记录，保留 hover 菜单和右键菜单。
- 已移除 active workspace 的整块背景色和外框，只保留左侧色条、文字权重和当前 session 条表达状态。
- 已固定 session 行的 hover 菜单槽位，hover 只改变菜单可见性，不改变行高。
- 已保留左侧 workspace 树、右侧 inspector、顶部 agent 操作和窄屏单列行为。

**Follow-up Polish**
- [P3] 把单个/多个 tool call 和 plan 进一步汇总为可展开的 `Run summary`，减少长对话里的过程卡片重量。
- [P3] 在 Workspace Overview 顶层补一个 provider 摘要，让连接状态不用切到 `Context` tab 才能看到。
- [P3] 对 prompt dock 内部按钮做更接近源图的分组：附件、命令、模型、推理、发送按钮形成更清楚的控制带。

source visual truth path: `/Users/robinfai/.codex/generated_images/019f3fbe-897c-70d3-bb64-947568a02c8a/ig_0fc399e54a4f60aa016a4dc65181b48199938eb0a1223fa468.png`

implementation screenshot path: `/private/tmp/ianvs-acp-conversation-dock/current/03-active-conversation.png`

viewport: `1440 x 900` screenshot-test viewport, plus `390 x 844` narrow state.

state: active conversation, permission request state, empty state, and narrow conversation state.

full-view comparison evidence: `/private/tmp/ianvs-acp-conversation-dock/source-vs-implementation.png`

focused region comparison evidence: checked `/private/tmp/ianvs-acp-conversation-dock/current/08-permission-request.png` for permission dock behavior and `/private/tmp/ianvs-acp-conversation-dock/current/10-narrow-width.png` for narrow layout. Extra cropped regions were not needed because the relevant prompt/status/sidebar/inspector areas are readable in the full captures.

required fidelity surfaces:
- Fonts and typography: implementation keeps the existing Flutter theme and 0 letter spacing; text hierarchy remains compact and readable. Small labels in the status strip are still dense but no longer put long paths before live state.
- Spacing and layout rhythm: center column now owns header, transcript, prompt, and status as one vertical dock. Left and right rails extend cleanly to the bottom of the app frame.
- Colors and visual tokens: implementation keeps existing `AppColors` purple, green, amber, red, border, and surface tokens instead of adding a new palette.
- Image quality and asset fidelity: no new raster or fake decorative assets were introduced; UI continues to use Material icons and existing Flutter-rendered components.
- Copy and content: app copy stays product-specific and avoids explanatory design text in the UI.

patches made since previous QA pass:
- Restored status/settings/ACP compatibility actions after a first pass hid them at the new center-column width.
- Reordered status strip content so live state appears before long paths.
- Updated repository screenshot baselines for the redesigned shell states.
- Removed repeated visible `New Session` controls from workspace header, timeline empty state, and sidebar empty state; moved workspace-scoped creation into the workspace actions menu.
- Tightened desktop and narrow screenshot baselines after reducing shell/sidebar/status density.
- Split current workspace and current session into separate header surfaces; updated sidebar active session and compact history rows.
- Removed the active workspace filled frame and kept session hover height stable.

final result: passed
