# 文件预览 Design QA

## Findings

- 无 P0/P1/P2 阻断项。
- [P3] 参考图在 720px 左右的预览宽度下为工具栏动作同时显示图标和文字；实际应用受现有 350px 工作区侧栏约束，预览宽度约 635px，因此保留关键“用其他应用打开”文字，其余动作使用图标和 tooltip。功能完整，属于可接受的密度调整。
- [P3] 参考图示例同时打开两个文件标签；实现按真实状态显示一个或多个标签，不为视觉对齐伪造第二个文件。

## Open Questions

- 无。当前实现沿用已有工作区侧栏宽度、Flutter 字体和 Material 图标，不改变现有 shell 的信息架构。

## Implementation Checklist

- [x] Markdown 本地文件链接可点击，并在应用内打开分屏预览。
- [x] 相对路径、绝对 `file://` 路径、`#L12` 和 `:12:3` 行号可解析。
- [x] 预览路径限制在当前工作区和授权目录内，阻止 `..` 与软链接越界。
- [x] Markdown 支持渲染/源码切换、文档大纲和嵌套文件链接。
- [x] 常见代码、配置、日志、JSON、YAML、CSV 等文本文件支持行号、搜索、换行和指定行定位。
- [x] 图片支持缩放和平移；PDF、Office、iWork、音视频通过 macOS Quick Look 生成只读缩略预览。
- [x] 不支持格式、加载失败和超大文本均有明确降级状态，可复制路径、在 Finder 中显示或用其他应用打开。
- [x] 文件使用标签页复用，最多保留 6 个；分隔线可拖动，窄窗口自动切换为单面板预览。

## Follow-up Polish

- [P3] 如果后续将工作区侧栏做成可收起，可在更宽预览状态下为搜索、复制路径、Finder 等动作补齐常驻文字标签。
- [P3] PDF 若需要逐页浏览，可在 Quick Look 首屏预览之上再接专用 PDF 渲染器；当前常见文件的快速确认场景已覆盖。

## Evidence

- source visual truth path: `/Users/robinfai/.codex/generated_images/019f6ecb-7045-7f00-9feb-5bea889c0f53/exec-01a2b1d1-a9b4-4946-9221-99a42cf09169.png`
- implementation screenshot path: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-pane.png`
- viewport: `1440 x 1024`，Flutter desktop，device pixel ratio 1.0。
- state: 当前工作区存在聊天内容，用户打开一个 Markdown 文件，分屏预览处于“预览”模式。
- full-view comparison evidence: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-comparison.png`
- focused region comparison evidence: `/Users/robinfai/.codex/visualizations/2026/07/17/019f6ecb-7045-7f00-9feb-5bea889c0f53/file-preview-focused-comparison.png`

## Required Fidelity Surfaces

- Fonts and typography: 保留应用现有 Flutter 字体与字重体系；文件标题、正文、工具栏小字和状态栏层级与参考图一致，未引入额外字体依赖。窄预览中的标题与表格未发生裁切。
- Spacing and layout rhythm: 左侧工作区、聊天区、可拖动分隔线、预览区的比例接近参考图；预览标签、路径、工具栏、正文和状态栏形成稳定的垂直节奏。标准 1440px 窗口下文档大纲可见。
- Colors and visual tokens: 全部使用现有 `AppColors` 的紫色、浅紫选中态、白色表面、冷灰边框和绿色只读安全状态，没有新增渐变或不一致的卡片样式。
- Image quality and asset fidelity: 未伪造图片或图标资产；操作图标来自 Flutter Material。图片和 Quick Look 缩略图使用系统实际渲染结果，并提供缩放。
- Copy and content: 界面文案直接说明动作和状态，包括“预览 / 源码”“用其他应用打开”“只读 · 当前工作区”和超大文件截断提示；没有把设计说明泄漏进产品界面。

## Comparison History

1. 首次实现截图：整体分屏比例、标签、路径、工具栏、正文和底部状态栏已成立，但 635px 预览宽度没有显示文档大纲，和参考图存在 P2 差异。
2. 修正：将大纲展示阈值从 650px 调整为 560px，并把大纲宽度收紧到 150px；同时为聊天和预览内链接补充现有紫色体系的可识别样式。
3. 复核：全图和聚焦对比中，大纲、正文、表格、模式切换与状态栏均完整可见；未发现新的 P0/P1/P2 问题。

## Iteration 9 — adaptive session configuration

- Primary menu references:
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-4a4a8b89-d674-4fc9-8246-2ea3d57996a1.png`
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-bc1b4397-d604-4b00-8871-fda0250608e6.png`
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-66e2c66d-8e62-4fcf-8650-a60c1120f833.png`
- Advanced-state references:
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-52b54c17-119c-4a64-80cd-601a9815ac26.png`
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-4d712bb1-2f58-421a-83be-bfcc78ce3fe4.png`
  - `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-9dd5492a-51b5-461b-80fd-39dec20f3de8.png`
- Native implementation capture: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-session-config-advanced.png` at 1225 × 768 physical pixels.
- Focused combined comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-session-config-comparison.png` (reference left, implementation right).
- Density normalization: the implementation control was cropped from the native 1225 × 768 capture and scaled to the reference component height. Dynamic model, reasoning, speed, conversation, and preview content were excluded from pixel-level fidelity judgments.
- State: light theme, active Codex session, advanced control expanded, reasoning set to a high tier, standard-speed session.

- [P1] The session selector flattened Mode, Collaboration, every model, and every reasoning choice into one oversized menu.
  - Fix: restored the reference interaction hierarchy. The summary pill opens a compact Model / Reasoning / Speed / Advanced menu; the first three rows open right-side submenus containing only the choices exposed by the active ACP agent.
- [P1] Advanced was initially implemented as another submenu.
  - Fix: Advanced now closes the popup and expands a persistent control panel above the summary pill. Its static header shows Advanced plus the lightning action; the header switches to More efficient / Smarter while the thumb is held and dragged, then returns after release.
- [P2] A stock Flutter slider did not reproduce the thick active region, white raised thumb, inactive tick marks, or moving texture in the source.
  - Fix: replaced it with a custom semantic slider. Twelve deterministic particles move continuously and are clipped to the blue active region; the inactive region retains discrete gray markers. Dragging snaps in real time to the reasoning levels supplied by the active agent and commits the selected node on release.
- [P2] Fast mode needed to support both ACP boolean options and select options such as Off / On.
  - Fix: normalized Standard / Fast labels and toggle behavior while preserving the agent's original configuration ID and value type.

Required fidelity surfaces for this focused state:

- Typography and spacing: 13 px native system labels, 228 logical pixel panel/pill width, 14 px radius, 24 px track, 26 px thumb, and restrained border/shadow match the normalized source.
- Colors: neutral white/gray surfaces and `#3194F6` active blue match the reference without reintroducing the discarded purple theme.
- Interaction: model, reasoning, and speed cascade independently; Advanced expands and returns to the compact menu; drag-start, drag-update, drag-end, semantic increment/decrement, particle repaint, select-style Fast, and boolean Fast paths are implemented.
- Accessibility: the custom control exposes slider role, current value, increased/decreased values, and semantic increment/decrement actions.

Verification:

- `flutter analyze --no-pub`: passed with no issues.
- `flutter test --no-pub test/ui/file_preview_workspace_test.dart test/ui/prompt_input_test.dart test/ui/workspace_inspector_test.dart test/ui/app_shell_test.dart`: 85 tests passed.
- `git diff --check`: passed.
- Native runtime: hot reloaded successfully and remains open with the advanced particle slider visible.

No actionable P0, P1, or P2 differences remain for the requested static, dragging, and animated-particle states.

## Iteration 10 — mutually exclusive overlays

- Implementation evidence:
  - `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-session-config-mutual-exclusion.png` shows the compact 1/2/3 menu after switching away from the advanced panel.
  - `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-session-config-overlay-dismissed.png` shows the composer after an outside click dismissed the advanced panel.
- Viewport: native macOS app at 1225 × 768 physical pixels, light theme, active Codex session, composer visible.

- [P1] The inline advanced panel could remain visible while the model/reasoning/speed menu opened, allowing states 1/2/3 and 4 to overlap.
  - Fix: moved state 4 into a positioned `OverlayPortal` anchored to the summary control. Opening the standard `MenuAnchor` first closes the advanced portal; selecting Advanced first closes the standard menu before showing the portal.
- [P1] The advanced panel was part of composer layout and did not dismiss consistently when the user clicked elsewhere.
  - Fix: wrapped the positioned panel in a `TapRegion`; any pointer-down outside the panel hides the portal without consuming the underlying click. This lets the summary control dismiss state 4 and open states 1/2/3 in the same interaction.

Required fidelity surfaces remain unchanged from Iteration 9: the overlay preserves the reference typography, width, spacing, border, shadow, active blue, slider behavior, particle animation, and dynamic Agent configuration mapping.

Verification:

- Widget coverage explicitly validates outside-click dismissal and 1/2/3-versus-4 mutual exclusion.
- Native runtime confirmed both transitions: Advanced → outside click → closed, and Advanced → summary click → compact menu.
- No model, reasoning, speed, or Fast value was changed during native interaction verification.

No actionable P0, P1, or P2 differences remain for overlay dismissal or mutual-exclusion behavior.

### Iteration 11 — advanced reasoning slider node snapping

- [P2] The advanced reasoning slider previously tracked a continuous intermediate value while the ACP session configuration only exposes discrete reasoning choices. This let the thumb, active color, and particle field rest visually between valid options during a drag.
  - Fix: round every tap and drag position to the nearest agent-provided reasoning choice before painting or emitting a change. The thumb, active track, and particles now move together between exact nodes, and crossing a node produces selection haptics.
  - Interaction evidence: the held-pointer widget test moves from `High` through `Medium` to `Low` and verifies the semantic node hints `2 of 3` and `1 of 3` before release.
  - Native runtime evidence: dragging the running app from `Max` toward the center landed exactly on `High`; the original `Max` selection was restored after verification.

Required fidelity surfaces remain unchanged: the static and drag headers, blue particle treatment, compact summary pill, outside-click dismissal, and mutual exclusion with the model/reasoning/speed menus.

Verification for this iteration:

- `flutter analyze --no-pub`: passed.
- Focused prompt-input test: passed.
- Combined UI regression suite: 86 tests passed.
- `git diff --check`: passed before this QA-note-only update.

### Iteration 12 — bidirectional advanced-menu navigation

- [P2] Pressing the `Advanced` header inside the advanced overlay previously dismissed the configuration UI instead of returning to the model/reasoning/speed menu shown in the reference interaction.
  - Fix: the header now closes overlay 4 and opens menu 1/2/3 on the next frame. The two surfaces remain mutually exclusive, while tapping outside either surface still dismisses the full configuration UI.
  - Widget evidence: the adaptive configuration test now requires `Model`, `Reasoning`, `Speed`, and `Advanced` to be visible immediately after pressing the advanced-panel header.
  - Native runtime evidence: verified the complete `primary menu → advanced overlay → primary menu` interaction in the running macOS app.

Verification for this iteration:

- Focused adaptive-config interaction test: passed.
- Focused mutual-exclusion and outside-dismissal test: passed.
- Combined UI regression suite: 86 tests passed.
- `flutter analyze --no-pub`: passed.
- `git diff --check`: passed.

final result: passed

---

# Agent Context Controls — Design QA

## Comparison Target

- Source visual truth: `/Users/robinfai/.codex/generated_images/019fae43-1a8c-7f81-ae14-29901c19d1e8/call_LfRXHcVW1qlHANiEuX4I0q6N.png`
- Implementation screenshot: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-implementation-agent-context-final.jpeg`
- Normalized source: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-reference-agent-context-normalized.png`
- Full-view comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-comparison-agent-context-final.png`
- Focused inspector comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-focused-agent-context-final.png`
- Viewport: native macOS Flutter window, 1225 × 768 physical pixels.
- Source pixels: 1586 × 992, normalized to 1225 × 768.
- Implementation pixels: 1225 × 768.
- CSS size and device scale factor: not applicable to a native Flutter capture; comparison uses equal physical dimensions.
- State: light neutral theme, current workspace expanded, no active session, Context selected, Diagnostics expanded, composer visible.

The source mock combines an empty-session center state with populated session details. The running implementation deliberately does not fabricate a model, session ID, or token usage when no ACP session exists; those rows appear from real session state and are covered by widget tests.

## Findings

- No actionable P0, P1, or P2 mismatch remains.
- [P3] The implementation keeps Paths, MCP, and provider capability details below Diagnostics. They extend the mock's information set but remain visually subordinate and are useful workspace context.
- [P3] The implementation omits the mock's close icon because the inspector is a persistent desktop workspace region rather than a temporary drawer.

## Required Fidelity Surfaces

- Fonts and typography: both views use the macOS system UI family with compact 10–14 px hierarchy, semibold section labels, subdued metadata, safe wrapping, and ellipsis for long values. The implementation does not introduce display typography or purple emphasis.
- Spacing and layout rhythm: the 312 logical pixel workspace rail, centered canvas, bottom composer, and 332 logical pixel fixed right rail reproduce the source composition. The inspector now begins at the content top, reaches the bottom, and uses one left divider with no floating-card margin, radius, or shadow.
- Colors and tokens: the rendered shell uses white and cool-neutral surfaces, dark text, gray selection and borders, and semantic color only where state requires it. The earlier purple-theme capture was an old worktree application and was excluded from implementation evidence.
- Image quality and asset fidelity: no raster artwork, logo, or custom illustration is required by this screen. Flutter Material icons remain sharp and consistent; no custom SVG, emoji, CSS art, or placeholder asset was introduced.
- Copy and content: product-owned labels are concise (`Workspace`, `Session`, `Diagnostics`, `Paths`, `MCP`, `Providers`). Dynamic agent, model, reasoning, Fast, session ID, usage, latency, and memory values come from ACP runtime data rather than copied mock content.
- States and interactions: Context switching and Diagnostics expand/collapse were exercised in the native app. Agent-defined model/reasoning/Fast selectors, boolean options, config callbacks, context usage, and memory/latency rows are covered in widget tests.
- Responsiveness and accessibility: persistent inspector geometry is asserted at 1200 × 800; the inspector remains outside the composer hit area, rows use semantic Flutter controls, and narrow composer wrapping is covered separately.

## Comparison History

1. The first capture used a stale same-named application from a Codex worktree and displayed the superseded purple UI. It was rejected as invalid evidence; visual validation now targets the current build by absolute `.app` path.
2. [P2] The current build still rendered Workspace as a rounded floating card with outer margins, while the selected source uses a fixed full-height right rail.
   - Fix: removed the card padding, height cap, radius, border enclosure, and shadow; retained a single left divider and 332 logical pixel rail.
   - Post-fix evidence: `design-qa-comparison-agent-context-final.png` aligns the sidebar, center canvas, composer, right-rail boundary, top edge, and full-height surface with the normalized source.
3. Focused comparison confirms the tabs, Session hierarchy, Diagnostics disclosure, section dividers, typography, and neutral palette. The remaining data difference is intentional empty-session behavior, not design drift.

## Verification

- `flutter analyze --no-pub`: passed.
- `flutter test --no-pub test/ui/file_preview_workspace_test.dart test/ui/prompt_input_test.dart test/ui/workspace_inspector_test.dart test/ui/app_shell_test.dart`: 84 tests passed.
- `git diff --check`: passed.
- Native interactions: Context tab and Diagnostics disclosure passed; no Flutter render exception was observed.

final result: passed

---

# Design QA — Inbox Optimization

## Scope and sources

- Product surface: native macOS Flutter Inbox sidebar.
- Viewport: 800 × 640, device pixel ratio 1.
- Baseline visual sources:
  - `artifacts/product-design/inbox-audit/13-current-inbox-empty.png`
  - `artifacts/product-design/inbox-audit/16-current-task-created.png`
  - `artifacts/product-design/inbox-audit/17-current-task-run-failure.png`
- Implementation captures:
  - `artifacts/product-design/inbox-audit/18-current-inbox-empty-improved.png`
  - `artifacts/product-design/inbox-audit/19-current-new-task-accessible.png`
  - `artifacts/product-design/inbox-audit/20-current-task-created-improved.png`
  - `artifacts/product-design/inbox-audit/21-current-task-queued-improved.png`
- Combined comparison inputs:
  - `artifacts/product-design/inbox-audit/qa-empty-comparison.png`
  - `artifacts/product-design/inbox-audit/qa-created-comparison.png`
  - `artifacts/product-design/inbox-audit/qa-queued-comparison.png`
  - `artifacts/product-design/inbox-audit/qa-sidebar-focused-comparison.png`

The red Agent startup banner in all captures is an intentional isolated-harness failure and is outside the Inbox QA scope.

## Mandatory comparison pass

| Surface | Result | Evidence |
|---|---|---|
| Typography | Passed | Existing font family, weights, status hierarchy, and 11–13px sidebar scale are preserved. Added copy wraps cleanly without crowding. |
| Spacing and layout | Passed | Original 350px sidebar geometry, card radius, border, and grouping rhythm remain intact. The selected card expands vertically without clipping or overlap. |
| Viewport resilience | Passed for product scope | At the desktop minimum test viewport, empty, selected, and queued states fit. Widget coverage also exercises the sidebar at 320 × 720. Mobile/tablet layouts are not product targets. |
| Colors and tokens | Passed | New surfaces use existing `AppColors`, `AppRadius`, tonal button, border, primary, and status tokens. Error treatment uses the established danger color. |
| Image quality | Passed / not applicable | The Inbox introduces no new raster assets. Existing empty/session illustrations remain sharp and unchanged. |
| Copy and content | Passed | Empty-state purpose, task intent, state summary, and next step form a coherent sequence. Queued copy promises automatic start and no longer offers a contradictory Run action. |
| Icons | Passed | Existing Material icon family and optical sizing are retained. Header icons expose readable semantic names; task actions pair icons with text. |
| States and interactions | Passed | Empty CTA, form validation, selected task, queue waiting, failure retry, linked session, review busy, and disabled/nonexistent actions are covered. |
| Accessibility | Passed for automated/system checks | Flutter semantics tests pass; macOS AX inspection exposes `Task title`, `Task description`, and `Task workspace path` containers plus named header and action buttons. |
| AI shortcut artifacts | Passed | No new decorative blobs, fake SVGs, placeholder avatars, generic hero art, or unrelated rounded-card treatments were introduced. |

## Findings and iterations

### Pass 1

- P1 accessibility: Flutter's test semantics could find the form labels, but the macOS accessibility bridge still exposed three unnamed text fields.
  - Fix: replaced merged semantics with explicit labeled semantic containers that preserve editable child nodes.
  - Verification: a rebuilt native app exposed `Task title`, `Task description`, and `Task workspace path` in the macOS AX tree.
- P1 behavior/data flow: Queued tasks exposed Run and `TaskScheduler.enqueueTask` rewrote the queued state.
  - Fix: removed queued from the UI run guard and made scheduler enqueue idempotent for an already queued task while still scheduling drain.
  - Verification: widget and scheduler regression tests; queued native capture has no Run control.
- P2 interaction: task intent, failure context, and next action were hidden; review decisions had no in-flight lock.
  - Fix: added selected-state detail/error/next-step surfaces, labeled actions, and per-task review serialization.

### Pass 2

- The first automated task-entry capture contained a duplicated title caused by combining accessibility `set_value` with keyboard entry in the QA harness.
  - Resolution: reset only the isolated temporary database, re-entered the task through the visible controls, and replaced the capture.
  - Verification: `20-current-task-created-improved.png` shows one correct title and clean wrapping.

### Final visual comparison

- Full-view comparisons preserve the baseline shell, navigation, card alignment, and design tokens while adding only task-relevant content and actions.
- The focused sidebar comparison confirms the selected card remains scannable: metadata first, then request, next step, and primary action.
- Queued comparison confirms that the contradictory Run action is removed and waiting guidance fits inside the card.
- No P0, P1, or P2 visual, behavioral, accessibility, or data-flow finding remains in the reviewed scope.

## Verification record

- `flutter test --no-pub test/tasks/task_inbox_controller_test.dart test/tasks/task_scheduler_test.dart test/ui/task_inbox_sidebar_test.dart test/ui/app_shell_test.dart test/ui/acp_client_app_test.dart`: 190 passed in the final combined run.
- `flutter analyze --no-pub`: no issues found in the final run.
- Native macOS visual and accessibility inspection completed at 800 × 640.

final result: passed

---

# Codex-style UI Design QA

## Comparison Target

- Source visual truth: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-ccc0eb10-0007-4123-8458-c7f66d482dbe.png`
- Implementation capture: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-implementation-composer-inspector.png`
- Normalized source: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-reference-normalized.png`
- Full-view comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-comparison-composer-inspector.png`
- Focused top comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-focused-top-brand-corrected.png`
- Focused composer comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-focused-composer-inspector.png`
- Focused inspector comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-focused-inspector.png`
- Viewport: macOS desktop window at 1225 × 768 physical pixels.
- Source pixels: 3456 × 2168, downsampled to 1225 × 768 for comparison.
- Implementation pixels: 1225 × 768 native full-window capture.
- CSS size and device scale factor: not applicable to the native Flutter capture; density was normalized by comparing equal physical pixel dimensions.
- State: light theme, current workspace expanded, no active session, right inspector on Overview, composer visible.

The source shows the same shell state with different dynamic conversation content. Dynamic tool output, timestamps, repository counts, and source attachments were excluded from fidelity judgments; the app-owned shell, hierarchy, surfaces, typography, and control placement were compared. The source's `Codex` product wordmark is intentionally not copied: the implementation uses its own `ACP Client` identity while retaining Codex only where it identifies the selected agent.

## Full-view Comparison Evidence

The normalized side-by-side comparison shows matching Codex-style composition:

- a compact neutral project rail on the left;
- a full-width, low-emphasis top command bar;
- a spacious central conversation canvas;
- a floating information inspector on the right;
- a centered floating composer at the bottom;
- thin gray dividers and neutral selected states instead of purple card framing.

## Focused Region Comparison

- The 2450 × 260 top crop keeps the toolbar, sidebar hierarchy, conversation width, and inspector geometry readable. It confirms that the sidebar and inspector boundaries align with the source and that the toolbar no longer dominates the shell.
- The 1120 × 98 focused composer comparison keeps the input and controls readable. It confirms matching width, 80 px rendered height, control baseline, restrained elevation, rounded geometry, and bottom placement.
- The 470 × 340 focused inspector comparison confirms that the floating panel now matches the reference's top offset, visible width, height, corner treatment, section rhythm, and low-contrast shadow.

## Required Fidelity Surfaces

- Fonts and typography: the implementation uses the macOS system UI family, compact 10–16 px hierarchy, medium selected weights, restrained letter spacing, and truncation for long project/session labels. It matches the source's native macOS optical feel.
- Spacing and layout rhythm: the three regions, 312 px logical sidebar, 760 px timeline, 740 px composer, 332 px inspector rail, 300 px inspector card, and 444 px inspector height reproduce the measured source proportions without overlap or clipping. The current workspace exposes 12 sessions before the disclosure control, matching the reference's denser project hierarchy.
- Colors and visual tokens: gray-white surfaces, `#202020` primary text, subtle `#E3E3E3` borders, neutral gray selection, and color reserved for semantic state reproduce the source balance.
- Image quality and asset fidelity: the target shell contains no required hero or brand raster assets. Standard Flutter Material icons are used consistently; no custom SVG, painted illustration, emoji, or placeholder imagery substitutes were introduced.
- Copy and content: existing product vocabulary and dynamic workspace/session data remain intact. Reference-only conversation text was not copied into the product.
- States and interactions: project expansion, session selection, resume confirmation, loading, active-session replay, disabled composer state, and ready composer state were exercised in the running app. Widget coverage also validates sidebar modes, prompts, previews, inspector tabs, and status actions.
- Accessibility and resilience: semantic buttons and labels remain in place, selected states retain contrast, and narrow composer behavior is covered at 320 px without overflow. No Flutter render exceptions or static-analysis issues remain.

## Comparison History

### Iteration 1

- [P2] Composer was wider than the source and weakened the central whitespace.
  - Fix: reduced the composer maximum width from 860 to 760 and increased its minimum height to 96.
- [P2] Inspector extended lower than the source floating card.
  - Fix: reduced the inspector maximum height from 560 to 460 while preserving internal scrolling.

### Iteration 2

The revised capture aligns the composer and inspector proportions with the normalized source. No actionable P0, P1, or P2 differences remain. Dynamic content differences are expected product state, not visual drift.

### Iteration 3

- [P2] The 52 px toolbar, boxed ACP brand mark, heavy action labels, and two-column header gave the top region more visual weight than the source.
  - Fix: reduced the toolbar to 40 px, switched the visible brand to a plain Codex wordmark with disclosure, softened action typography, and reordered the compact session header so the active task leads.
- [P2] Thought and tool replay used yellow debug-card styling, literal Markdown emphasis markers, and an 860 px content width.
  - Fix: reduced the timeline to 760 px, made thought/turn rows borderless, converted tools to neutral gray disclosure rows, and normalized coalesced thought markers into readable ` · ` separators.
  - Post-fix evidence: `design-qa-comparison-pass4.png` shows a quieter timeline whose text and tool history no longer compete with assistant output.

### Iteration 4

- [P2] The left rail remained narrower and substantially less dense than the reference, while the inspector card began too far to the right.
  - Fix: increased the sidebar from 300 to 312 logical pixels, increased the inspector rail from 316 to 332 logical pixels, and raised the default visible-session count from 5 to 12.
  - Post-fix evidence: `design-qa-comparison-final.png` aligns the sidebar boundary near physical x=221 and the inspector boundary near physical x=999, matching the normalized source. The composer remains centered at the same visual width.

### Iteration 5

- [P2] The combined regression suite exposed a 31 px title-row overflow in AppShell states where long task titles, agent metadata, and connection status shared a constrained toolbar.
  - Fix: made the title segment consume only remaining width, truncate safely, and suppress optional agent/status metadata when the measured title area is too narrow.
  - Post-fix evidence: the refreshed `design-qa-comparison-final.png` preserves the full-size composition, while the 171-test combined UI suite covers the previously failing narrow AppShell combinations without a render overflow.

### Iteration 6

- [P2] The left-rail brand area copied the reference's `Codex` wordmark and a non-functional disclosure chevron, conflating the reference product with this ACP client.
  - Fix: replaced the copied brand treatment with the product's own `ACP Client` name and removed the false dropdown affordance. Agent identities and agent-selection behavior remain unchanged.
  - Post-fix evidence: `design-qa-comparison-brand-corrected.png` and `design-qa-focused-top-brand-corrected.png` show the scoped brand correction with the existing shell geometry preserved.

### Iteration 7

- [P2] The composer rendered about 10 px shorter than the reference, left its controls too high, and inherited an internal outline from the global input theme.
  - Fix: increased the surface minimum height to 108 logical pixels, rebalanced text-field padding so the controls sit on the reference baseline, removed the redundant control divider, tightened control sizes, and explicitly disabled the nested text-field outline.
- [P2] The Workspace card sat too close to the toolbar, rendered wider and taller than the reference panel, and used a heavy full-width tab indicator.
  - Fix: changed the floating card to a 300 logical pixel inner width, 28 px top inset, 444 px maximum height, layered low-opacity shadow, softer border, shorter inset tab indicator, and divided content sections.
  - Post-fix evidence: `design-qa-comparison-composer-inspector.png`, `design-qa-focused-composer-inspector.png`, and `design-qa-focused-inspector.png` show the two scoped regions aligned with the normalized reference.

### Iteration 8 — session row and hover preview

- Additional source visual truth: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-reference-session-preview.png` (1386 × 628 physical pixels).
- Native implementation capture: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-implementation-session-preview.png` (1225 × 768 physical pixels).
- Density and crop normalization: the source was downsampled to 492 × 223; the implementation was cropped at x=0, y=120 to the same 492 × 223 region. The source's sidebar/card boundary and the implementation's native sidebar/card boundary both land near x=218 after normalization.
- Focused combined comparison: `/Users/robinfai/flutter_projects/ianvs-acp/design-qa-comparison-session-preview.png` (source left, implementation right).
- State: light theme, expanded workspace, pointer resting on a historical session, direct row actions visible, and the delayed hover preview open.

- [P2] Session rows previously hid actions behind an ellipsis menu and did not expose the reference's compact contextual preview.
  - Fix: added direct pin/archive hover actions without changing row height, retained the full action menu on secondary click, and added a 220 ms delayed preview with a 120 ms bridge so the pointer can move into the card.
- [P2] Session metadata previously competed with the title inside the narrow row.
  - Fix: moved relative time, workspace, branch/agent identity, latest assistant summary, and CI state into the preview card. Branch and CI fields are read from real event metadata; missing values use explicit, non-fabricated fallbacks.
  - Post-fix evidence: the combined comparison shows matching sidebar width, row fill, row-to-card alignment, card width/height, rounded border, low elevation, title/time header, four 24 px metadata rows, truncation, and purple branch affordance.

Required fidelity surfaces for this focused state:

- Typography: system UI font, 12 px row title, 14 px preview title, 12 px time, and 13 px metadata preserve the reference hierarchy and ellipsis behavior.
- Spacing and layout: the 320 logical pixel card, 12/10 px padding, 24 px metadata rows, 4 px row-to-card gap, and aligned top edge match the normalized reference without shifting session-row height.
- Colors and tokens: neutral hover/selection fills, subtle border/shadow, dark text, tertiary time/icons, and a single purple branch accent match the source's restrained palette.
- Image and icon fidelity: no raster imagery is present in this target. Existing Material outlined icons are used consistently; no custom SVG, emoji, or CSS-painted substitute was introduced.
- Copy and content: session-specific data remains dynamic. The implementation does not copy the reference repository, branch, summary, or CI text; it renders the corresponding fields from the active session model.
- Interaction and accessibility: direct actions retain tooltips, secondary-click exposes the complete menu, the preview survives pointer travel into the card, and its overlay is removed before context menus and disposal. Widget coverage exercises hover timing, preview dimensions/content, stable row height, direct actions, context menu actions, and disabled fork states.

No actionable P0, P1, or P2 differences remain after the final comparison. Differences in conversation text, tool state, timestamps, and source attachments are dynamic product data and were not copied from the reference.

## Verification

- `flutter analyze`: passed.
- `flutter test --no-pub test/ui/workspace_sidebar_test.dart`: 33 tests passed, including the new hover-preview and direct-action cases.
- `flutter test --no-pub test/ui/app_shell_test.dart test/ui/chat_timeline_test.dart test/ui/workspace_sidebar_test.dart`: 108 associated UI tests passed after the focused implementation.
- Final combined UI regression suite: 171 tests passed.
- Native runtime: rebuilt successfully and remains running with the empty-session canvas, inspector, composer, and expanded workspace visible.
- Runtime note: Flutter emitted transient macOS accessibility-tree diagnostics during hot restart/capture; there were no render exceptions, broken controls, or failed interactions.

## Follow-up Polish

- [P3] The native macOS title text remains the product name `ACP Client`; embedding the active task title into native window chrome would require a separate platform-window integration pass and is intentionally outside the Flutter shell reconstruction.

final result: passed
