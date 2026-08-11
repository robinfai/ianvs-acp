# Design QA — ACP timeline rendering

## Source visual truth

- Reference: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-16629970-ef0b-4ffb-b2da-cbabde60d539.png`
- Reference size: 2842 × 2166 px. The right side is the target Codex rendering; the left side shows the previous ACP rendering.
- Target state: a historical completed turn at the top of the conversation, default-collapsed process, user attachment thumbnail above a multiline prompt, and expandable grouped tool activity.

## Implementation evidence

- Default state: `design-qa-artifacts/implementation-large-default.jpg` (1225 × 768 px)
- Expanded state: `design-qa-artifacts/implementation-expanded.jpg` (800 × 632 px)
- Side-by-side comparison: `design-qa-artifacts/reference-vs-implementation.jpg` (1840 × 768 px)
- Runtime: native macOS Flutter app, ACP Client, using a real restored ACP session.

## Comparison history

### Iteration 1

Visible P1 differences:

- Ordinary assistant commentary was projected as `Thought`, producing a long stack of thought cards instead of the target paragraph hierarchy.
- The grouping algorithm depended on a fragile contiguous-message shape, so streaming replacements could remove or reshape a fold.
- Historical image markers were rendered as text and no thumbnail appeared.
- Historical turns without an explicit completion event did not receive the target default-collapsed `Processed` presentation.
- Tool metadata output used a preview cap and displayed `Content omitted` even when the complete output payload was locally available.

Corrections:

- Separated assistant commentary from genuine thought events and folded genuine thoughts only with adjacent tool activity.
- Keyed group expansion state by stable tool-call identity and inferred historical completion from turn boundaries.
- Preserved ACP content-block payloads, merged marked replay chunks, and adapted historical local-image markers into the thumbnail flow.
- Rendered full available tool output inside bounded, independently scrollable fade regions.

### Iteration 2

The native-app comparison confirmed:

- The attachment is a real source thumbnail and raw image-marker syntax is absent.
- `hover`, `展开`, and `默认` remain three separate lines.
- Historical work is shown as `Processed` and starts folded.
- Expanding the process reveals normal assistant commentary, genuine `Thought` entries, compact single-tool rows, and aggregated tool activity.
- The group chevron is absent at rest, appears on hover, and expansion occurs only on click.

## Surface review

- Typography: process commentary uses the target's stronger hierarchy; activity labels remain secondary; user line breaks are preserved.
- Spacing and layout: prompt attachment, bubble, process header, and activity stack follow the target order and density. Window chrome and sidebar width are outside this component's scope.
- Colors: neutral gray prompt bubble, dark commentary, subdued tool rows, and existing product status colors remain consistent with the app design system.
- Images: the actual local attachment is decoded and rendered; no placeholder or fabricated asset is used.
- Copy and content: dynamic ACP text is preserved, raw attachment markers are removed, and locally available output is not preview-truncated.

## Interaction and regression coverage

- Hover-only chevron visibility and click-only expansion.
- Default folding of completed and inferred-complete historical turns.
- Stable group state while tool-call chunks are replaced during streaming.
- Thought plus adjacent tools grouping, while ordinary commentary stays outside the tool group.
- Bounded command/code and metadata regions with internal scrolling and edge fades.
- ACP replay payload preservation and selective user-chunk merging.
- Clickable ACP and historical image thumbnails with a zoomable modal preview,
  explicit close control, backdrop dismissal, and Escape-key dismissal.

Verification:

- `flutter test --no-pub test/ui/chat_timeline_test.dart`: 80 tests passed.
- ACP client and controller suites: 306 tests passed.
- Static analysis of all changed production and test files: no issues found.

## Known data constraint

Old ACP replay events do not always carry the original elapsed-time metadata or an explicit completion event. The renderer can safely infer that a preceding turn is complete from the next user-turn boundary and show `Processed`, but it cannot reconstruct an exact historical duration that was never supplied. This is an expected source-data limitation, not an actionable visual defect.

## Multi-file edit card and hover diff — 2026-08-02

### Visual truth and rendered evidence

- Default reference: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-af6fb6ae-a13e-4a8d-8f4a-0e3e9eae8d3b.png` (1596 × 538 px).
- Hover reference: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-b2a8bf59-76ed-4727-9856-bb9fbf9b0c6f.png` (1788 × 1438 px).
- Default implementation: `design-qa-artifacts/file-diff-redesign-default.png` (1000 × 600 px).
- Hover implementation: `design-qa-artifacts/file-diff-redesign-hover.png` (1000 × 600 px).
- Default comparison, source above and implementation below: `design-qa-artifacts/file-diff-redesign-default-comparison.png`.
- Hover comparison, source above and implementation below: `design-qa-artifacts/file-diff-redesign-hover-comparison.png`.
- Implementation viewport: 1000 × 600 logical px at device pixel ratio 1.0. The reference component and implementation component were cropped and normalized to the same 1000 px comparison width before review.
- State: one completed tool activity containing three file diffs, first at rest and then with the middle file row hovered.
- Rendering: Flutter widget renderer with deterministic Roboto, Roboto Mono, and Material Icons test fonts. The production macOS client continues to use the system SF families.

### Full-view and focused comparison

- Full view: the implementation preserves the reference's bordered card, compact edit icon/title hierarchy, aggregate green/red counts, three immediately visible file rows, dividers, and right-aligned per-file statistics.
- Focused hover view: the hovered row changes to the neutral raised surface without shifting counts, exposes a small preview affordance, and opens one compact diff panel with its own path/count header, dual line-number gutter, deletion/addition surfaces, change bars, syntax color, border, radius, and shadow.
- The popup now starts 40 logical px inside the file row and aligns its right edge exactly with the file row's right edge. Its width is therefore derived from the active item rather than the earlier illustrative red box.
- Dynamic paths and counts intentionally reflect the fixture rather than hard-coding the reference's content.

### Comparison history

- Iteration 1 — P1: moving the preview to the root Overlay removed its Material text context, so Flutter rendered yellow fallback double underlines throughout the popup. Fixed by giving the root overlay entry a transparent `Material`; the revised hover capture contains no yellow fallback decoration.
- Iteration 1 — P2: estimated popup height could place a short panel several pixels away from its hovered row. Fixed by anchoring with the actual `top` or `bottom` edge, producing a measured attachment error no greater than 2 px.
- Iteration 1 — P2: boundary clamping moved the entire panel away from its row for tall diffs. Fixed by retaining the exact row anchor and shrinking only the internally scrollable diff region.
- Iteration 2 — P2: raw absolute paths weakened scanability and code lacked the reference's syntax hierarchy. Fixed by presenting workspace-relative paths with muted directory/strong filename treatment and highlighting rows according to file extension.
- Iteration 3 — P1: the pass-through preview could not receive the mouse, preventing scrolling or later controls. Fixed by making the panel interactive, overlapping the active row by 8 px, preserving the row's active state while the panel is hovered, and delaying closure for 100 ms after both regions are left.
- Iteration 4: regenerated default and hover comparisons show no remaining actionable P0/P1/P2 issue.

### Fidelity surfaces

- Fonts and typography: title, relative paths, tabular-looking counts, line numbers, and monospace code have distinct optical roles. Directory prefixes are secondary while filenames remain prominent; code uses syntax color where the extension is supported.
- Spacing and layout: header, 44 px file rows, dividers, fixed preview-affordance slot, right-aligned counts, a 40 px popup inset, exact right-edge alignment, 8 px item overlap, radii, and shadow preserve the reference's density while making pointer transfer continuous.
- Colors and tokens: surface, raised-surface, muted gutter, border, success, danger, and floating-shadow values all come from the existing design system. Deletion/addition rows combine a low-opacity fill with a strong 3 px semantic edge.
- Image quality and assets: no raster imagery is part of this component; the edit icon comes from the existing Material icon system.
- Copy and content: workspace paths and statistics remain dynamic. The reference's Undo/Review controls were intentionally not added because ACP exposes no corresponding callbacks; no nonfunctional controls were introduced.

### Interaction verification

- The file list appears without a secondary expansion click.
- Hovering an individual file highlights only that row, reveals one preview affordance, and opens only its diff.
- The popup receives pointer input. Crossing the 8 px shared region keeps it open and keeps the originating row highlighted; leaving both regions closes it after a 100 ms bridge without a darker color tail.
- Rows in the window's upper half open below; rows in the lower half open above. Popup direction is determined from root-window coordinates, not a nested timeline scrollable.
- The popup right edge matches the item right edge within 1 px, its left edge remains inset by 40 px within 1 px, and its vertical edge overlaps the active item by 8 ± 1 px.
- A tall diff stays inside a 360 px viewport; after the pointer enters the panel, its internal list scrolls while the preview remains open.
- Workspace-absolute paths render as relative paths and expose a semantic `Preview diff for …` label.
- Repeated edits to the same path are coalesced to one file row using the first available old text and latest available new text.

### Automated acceptance

- `flutter test --no-pub test/ui/chat_timeline_test.dart`: 80/80 passed, including default and hover golden comparisons.
- `flutter analyze --no-pub lib/ui/components/chat_timeline.dart test/ui/chat_timeline_test.dart`: no issues.
- Production macOS client: hot reload completed successfully. Historical-session UI capture remains unavailable in this debug build because of the pre-existing Keychain entitlement error; exact component states were therefore captured by the 1× Flutter widget renderer rather than inferred from code.

final result: passed

## macOS 一体化窗口顶栏 — 2026-08-11

### 视觉依据与最终证据

- Source visual: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-3cb348a0-9174-462e-8ab2-969cdd93af3b.png` (1990 × 1258 px).
- Native implementation: `artifacts/reference-replica-2026-08-11/native-macos-top-chrome-final.jpeg` (1225 × 768 px), captured from the rebuilt macOS app.
- Viewport normalization: the reference was proportionally normalized to 1225 × 768 for comparison with the native implementation; both top regions retain the same full-window coordinate system.
- Full comparison: `artifacts/reference-replica-2026-08-11/full-comparison-top-chrome-final.jpg`.
- Focused top-region comparison: `artifacts/reference-replica-2026-08-11/focused-window-chrome-final.jpg`, showing the first 150 px of both source and implementation in one input.

### 对比记录

- Pass 1 — P1 window hierarchy: the default native title row sat above the Flutter toolbar, creating a duplicate application top area. Fixed with a transparent, separator-free, full-size macOS titlebar and unified toolbar so the app toolbar starts at the window edge.
- Pass 1 — P2 sidebar alignment: the first 44 px sidebar reservation placed the product name visibly below the source relationship. Reduced the reservation to 28 px so the native window controls, product title, and first navigation item follow the reference's vertical rhythm.
- Pass 2: the source and rebuilt native app were recomposed in full-window and 150 px focused comparison inputs. No actionable P0, P1, or P2 discrepancy remains in the requested top-window region.

### 设计与行为检查

- Typography: the product title remains a restrained system semibold, aligned below the native controls without introducing a second app title.
- Spacing and layout: the traffic-light area is owned by the sidebar; the main toolbar begins at y = 0; compact macOS layouts reserve 70 px before toolbar actions to avoid collisions with the controls.
- Colors: the sidebar and transparent titlebar share one neutral surface. The native controls keep the operating system's active/inactive appearance instead of being simulated in Flutter.
- Image and asset quality: close, minimize, and full-screen are genuine `NSWindow` standard controls; no custom circles, emoji, SVG substitutes, or decorative fake controls were added.
- Copy and content: this pass only changes window chrome and spacing. It does not add navigation entries, commands, routes, or product capabilities.
- Accessibility and native behavior: close, minimize, full screen/zoom, standard titlebar dragging, and accessibility roles remain supplied by AppKit. The app does not turn blank conversation content into a global drag surface.

### 验证

- `xcodebuild ... -only-testing:RunnerTests/RunnerTests/testMainWindowUsesUnifiedFullSizeChrome`: passed.
- `flutter analyze`: no issues.
- `flutter test docs/design-audit-2026-06-05/audit_screenshots_test.dart --plain-name "11 desktop reference replica with terminal" --update-goldens`: passed.
- The same visual test in non-update mode: passed.
- Native macOS rebuild and launch: passed; the integrated top region and real window controls were inspected in the running app.

final result: passed

## ChatGPT Desktop 大框架 UI 复刻 — 2026-08-11

### Source visual truth and implementation evidence

- Source visual truth: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-3cb348a0-9174-462e-8ab2-969cdd93af3b.png` (1990 × 1258 px).
- Native implementation screenshot: `artifacts/reference-replica-2026-08-11/native-macos-final.jpeg` (1225 × 768 px), captured from the running Flutter macOS ACP Client with the terminal panel open.
- Deterministic implementation screenshot: `docs/design-audit-2026-06-05/screenshots/11-desktop-reference-replica.png` (1990 × 1258 logical px at DPR 1).
- State: light desktop window, active conversation, left workspace/session navigation, global toolbar, compact right session/context inspector, grounded composer, and bottom terminal panel.
- Viewport and density normalization: CSS pixels do not apply to the native Flutter app. For the combined native comparison, the 1990 × 1258 source was normalized to 1225 × 768 px and placed beside the native 1225 × 768 capture. The deterministic 1990 × 1258 capture independently verifies the source-sized layout constraints.
- Full-view comparison: `artifacts/reference-replica-2026-08-11/full-comparison-final.jpg`.
- Focused top comparison: `artifacts/reference-replica-2026-08-11/focused-top-final.jpg` covers toolbar, conversation measure, message surfaces, and right inspector.
- Focused bottom comparison: `artifacts/reference-replica-2026-08-11/focused-bottom-final.jpg` covers the response tail, composer, terminal tabs, prompt, and panel ownership boundary.

### Findings

No actionable P0, P1, or P2 difference remains for the requested large-framework recreation.

- Fonts and typography: native macOS rendering uses the Apple system/PingFang fallback stack with regular, medium, and semibold hierarchy; code and terminal content use SF Mono/Menlo-compatible metrics. Labels, body copy, code, and metadata retain the reference's restrained scale and line-height contrast.
- Spacing and layout rhythm: the 1990 px source-sized state keeps a 360 px sidebar, 54 px toolbar, 848 px reading/composer measure, 362 px inspector reservation, 346 px floating inspector card, 20 px composer/card radius, and a bottom terminal owned only by the main workspace. At 1280–1899 px the truthful 320 px sidebar prevents the reference proportions from becoming oversized.
- Colors and visual tokens: the shell now uses `#F7F7F7` secondary background, white reading surfaces, `#F4F4F4` muted controls, `#E9E9E9` selection, `#DEDEDE/#ECECEC` borders, graphite text, grayscale shadows, and blue only for real focus/activity semantics.
- Image quality and assets: the target contains no required product imagery. The implementation uses the project's Material icon system and a real native terminal; no custom SVG, emoji, placeholder illustration, or fabricated bitmap asset was introduced.
- Copy and content: reference-only capabilities were not copied. The visible navigation and inspector expose only the project's existing new/resume session, agent settings, permission history, current session, workspace context, capabilities, composer, and terminal behaviors. App-specific fixture titles remain dynamic rather than hard-coded to the source product.
- Icons, states, and accessibility: active selection, toolbar controls, inspector actions, composer controls, terminal toggle/tab/close states, semantic labels, and the native accessibility tree were checked. The final native tree contains no `站点`, `网页搜索`, `已安排`, or `插件` product entry.

### Comparison history

- Iteration 1 — P1 content/affordance drift: the first pass copied source-only entries such as sites, scheduled items, plugins, web search, and site creation. These would imply capabilities the ACP Client does not have. They were removed; the reference's visual row rhythm was remapped only to existing ACP actions and real session/workspace context.
- Iteration 1 — P2 responsive proportion: a 1728-logical-px native window still used the 360 px sidebar, making navigation visibly wider than the normalized source. The 360 px breakpoint was moved to 1900 px; 1280–1899 px now uses 320 px. The revised native comparison shows the corrected sidebar-to-main ratio.
- Iteration 2 — P1 false status cues: a decorative brand dropdown arrow, hard-coded schedule/unread marks, `置顶` semantics, and a nonfunctional help glyph suggested unavailable actions or status. They were removed, and the section was relabeled `当前会话` with only the actual session title.
- Iteration 3: the source and final native build were recomposed in one full-view comparison plus two focused comparisons. The shell proportions, reading axis, inspector elevation, composer, and terminal boundary align with the source while product-specific capability differences remain intentionally truthful. No actionable P0/P1/P2 finding remains.

### Interaction and regression verification

- Native macOS smoke: latest build launched, the actual terminal toggle opened the panel, and a real zsh prompt rendered in the selected workspace.
- `flutter analyze`: no issues.
- `flutter test test/ui/app_shell_test.dart test/ui/workspace_inspector_test.dart`: 26/26 passed.
- `flutter test test/ui/chat_timeline_test.dart --update-goldens`: 81/81 passed; the refreshed accepted visual baselines subsequently passed in the focused UI suite.
- `flutter test docs/design-audit-2026-06-05/audit_screenshots_test.dart --plain-name "11 desktop reference replica with terminal"`: passed at 1990 × 1258.
- `git diff --check`: passed.

final result: passed

## ACP bottom terminal integration — 2026-08-10

### Visual truth and native evidence

- Source reference: `/Users/luobinghui/.codex/attachments/01281bee-8ece-4966-b0cd-796ff4965293/image-2.png` (3456 × 2158 px).
- Native implementation: `artifacts/terminal-integration-2026-08-10/native-two-tabs.png` (800 × 628 px), captured from the rebuilt macOS ACP Client with two live local terminal sessions.
- Required same-input comparison: `artifacts/terminal-integration-2026-08-10/reference-vs-native.png` (2400 × 942 px). Both full-window states were normalized to the same width and padded rather than cropped.
- Runtime evidence: the app bundle contains a signed arm64 `ianvs_core.framework`; the terminal opened from that packaged framework and rendered the actual zsh prompt in the ACP workspace.

### Fidelity and behavior review

- The terminal drawer starts after the workspace sidebar and spans the complete remaining content width, matching the reference's ownership boundary.
- The upper-right terminal icon is compact, uses the existing toolbar language, exposes selected/disabled semantics, and highlights only while the panel is open.
- Terminal tabs are in one restrained header strip. Each tab has its own close action, the `+` sits immediately after the tabs, and the panel-level close action remains at the far right.
- The drawer uses the existing ACP neutral surfaces and border tokens for its chrome, while the viewport keeps the terminal's native dark palette. The composer placeholder remains secondary and visually quieter than active content.
- The panel height remains useful at the compact 800 px window without hiding the active ACP session controls. Wider layouts retain the inspector above the same full-width terminal drawer.
- Native interaction confirmed that the first toggle lazily creates a shell in the ACP session working directory and the adjacent `+` creates and activates a second local shell.

### Automated and packaging acceptance

- `flutter test test/ui/app_shell_test.dart`: 24/24 passed, including session-switch and host-disposal cleanup for all terminal tabs.
- `flutter test packages/ianvs_terminal/test/terminal_bottom_panel_test.dart`: 4/4 passed.
- `dart test packages/ianvs_pty/test/native_pty_backend_test.dart`: 46/46 passed, including packaged code-asset framework resolution.
- `flutter analyze` in ACP and package analysis for `ianvs_terminal` / `ianvs_pty`: no issues.
- `flutter build macos --debug`: passed. Deep code-sign verification passed for the app and bundled terminal framework.
- Same-input visual review found no remaining actionable P0, P1, or P2 layout, typography, color, image-quality, responsiveness, or interaction issue.

final result: passed

## Conversation Canvas full-flow redesign — 2026-08-09

### Visual truth and evidence

- Selected ImageGen reference: `artifacts/design-reference/conversation-canvas-option-2.png` (1487 × 1058 px).
- Reference direction: a native macOS ACP client influenced by Codex and ChatGPT, with a quiet workspace sidebar, dominant conversation canvas, full-height Context inspector, restrained teal interaction states, and one grounded multiline composer.
- Native implementation capture: `artifacts/ui-redesign-2026-08-09/active-conversation-native.png` (1224 × 768 px), captured from the running macOS Flutter app with a deterministic active ACP session.
- Deterministic implementation capture: `docs/design-audit-2026-06-05/screenshots/03-active-conversation.png` (1440 × 900 logical px at DPR 1).
- Required combined comparisons: `artifacts/ui-redesign-2026-08-09/reference-vs-native.png` and `artifacts/ui-redesign-2026-08-09/reference-vs-active-conversation.png`. The two panels were normalized to the same comparison width and padded rather than cropped, preserving the full reference and implementation states.
- Full-flow evidence: `artifacts/ui-redesign-2026-08-09/full-flow-contact-sheet.png`, backed by ten individual screenshots under `docs/design-audit-2026-06-05/screenshots/`.

### Comparison history

- Iteration 1 — P1 typography: process commentary inherited a semibold treatment and had no visible agent identity, making the response feel heavier and less conversational than the selected design. Fixed by rendering assistant prose at regular weight and adding a compact teal sparkle plus dynamic agent-name label.
- Iteration 1 — P2 structure: the previous empty-preview layout treated the inspector as a floating card and allowed the conversation to blend into the surrounding shell. Fixed by introducing one bounded conversation canvas and a flat, full-height 320 px inspector separated by a single divider.
- Iteration 2 — P2 flow coverage: the visual audit still attempted to open settings from removed toolbar affordances. Fixed by following the redesigned Context → Diagnostics flow, then capturing the actual Session settings and ACP compatibility dialogs.
- Iteration 2 — P2 test typography: the audit renderer loaded a different family from the production theme, so layout screenshots used fallback block glyphs for normal text. Fixed by loading the deterministic audit font under `AppTypography.family`; the production native capture continues to use the macOS system and Chinese fallbacks.
- Iteration 3: the selected reference and implementation were recomposed in one comparison input. No actionable P0, P1, or P2 layout, typography, color, image-quality, interaction, or responsiveness issue remained.

### Fidelity surfaces

- Fonts and typography: the app now uses `.AppleSystemUIFont` with SF Pro Text, PingFang SC, Helvetica Neue, and Arial fallbacks; code uses SF Mono with Menlo/Monaco fallbacks. Product text is limited to regular, medium, and semibold hierarchy, with no `w800` or `w900` production usage.
- Spacing and layout: the desktop shell preserves the reference's three-column rhythm, 320 px navigation and inspector panes, a 744 px reading measure, quiet 52 px toolbar, 760 px composer, generous turn spacing, and restrained radii, borders, and shadows. At narrower widths the inspector and then sidebar collapse without overlapping the conversation.
- Colors and tokens: warm neutral backgrounds, pure reading surfaces, soft gray borders, charcoal copy, and a reserved teal accent map directly to selection, focus, agent identity, and inspector tabs. Safety, warning, success, and destructive states retain semantic colors.
- Image quality and icons: the selected ImageGen bitmap is preserved as the visual source rather than embedded as product UI. The implementation uses the existing Material icon system; no placeholder illustration, custom SVG, CSS art, or fabricated asset was introduced.
- Copy, behavior, accessibility, and responsiveness: dynamic ACP copy remains intact; workspace search, session selection, agent menu, resume/new-session flows, Context diagnostics, dialogs, permission review, errors, composer controls, focus states, labels, and keyboard semantics remain operational. The 390 × 844 scenario has no clipping or overflow.

### Automated verification before independent acceptance

- `flutter analyze --no-pub`: no issues.
- `./tool/flutter_test_isolated.sh`: 1303 tests passed.
- `./tool/flutter_test_isolated.sh --update-goldens docs/design-audit-2026-06-05/audit_screenshots_test.dart`: ten full-flow states passed and their accepted images were regenerated.
- Native macOS build and launch: passed; the active conversation, system-font rendering, three-column layout, composer, and accessibility tree were inspected directly.
- `git diff --check`: passed; production code contains no `FontWeight.w800` or `FontWeight.w900` usage.

### Independent subagent acceptance

- Re-inspected the selected ImageGen reference and the native/deterministic comparison inputs together, then reviewed the active conversation, permission request, error, dialog, and 390 × 844 narrow-window evidence. No actionable P0, P1, or P2 visual issue remained.
- `flutter analyze --no-pub`: no issues.
- `./tool/flutter_test_isolated.sh`: 1303 tests passed.
- `./tool/flutter_test_isolated.sh docs/design-audit-2026-06-05/audit_screenshots_test.dart` (non-update mode): all ten full-flow screenshots passed against the accepted baselines.
- `git diff --check`: passed.
- Production typography scan: 16 `w400`, 28 `w500`, and 235 `w600` declarations; zero `w700`, `w800`, or `w900` declarations and no hard-coded `fontFamily: 'monospace'` or `fontFamily: 'SF Mono'` usage.

### Feedback-driven final acceptance

- Final ten-state contact sheet: `artifacts/ui-iteration-2026-08-09/full-flow-contact-sheet-final.png`.
- Final same-input comparison against the selected ImageGen direction: `artifacts/ui-iteration-2026-08-09/reference-vs-active-final.png`.
- R1–R8 are closed: deterministic fonts and icons render without block-glyph evidence; empty state has a primary New Session action; startup failure exposes Open config, Retry, and copy diagnostics; compact mode preserves labeled Workspaces and Context panels; dialogs use a quiet one-pixel border with no heavy shadow; permission review uses a restrained warm surface and 44 px decisions; active sessions default to Context; plans and commands remain inline in the conversation canvas.
- Final visual refinement removed the remaining heavy PopupMenu/Dialog outline, restored readable compact-navigation labels, and replaced the mixed-language permission heading with `Tool call approval required`.
- Three independent read-only subagent reviews covered visual fidelity, flow/accessibility, and Codex/ChatGPT style consistency. Their final current-run conclusion was unanimous: no remaining P0, P1, or P2 issue.
- `flutter analyze --no-pub`: no issues.
- `./tool/flutter_test_isolated.sh`: 1303/1303 passed after correcting two title-first resume-dialog test finders and the permission-heading expectation.
- `./tool/flutter_test_isolated.sh docs/design-audit-2026-06-05/audit_screenshots_test.dart` in non-update mode: 10/10 passed.
- `git diff --check`: passed. Production code contains only regular, medium, and semibold weights; no `w700`, `w800`, or `w900` declarations and no hard-coded monospace family remain.

### Native four-choice ACP permission smoke — 2026-08-09

- A real Codex ACP session was launched in the rebuilt macOS client at 800 × 632 px. The request `touch /etc/ianvs-acp-permission-smoke-2` produced the runtime's actual four structured choices: Reject, Allow Once, Allow for Session, and Allow Commands Starting With.
- The first native run exposed a 93 px bottom overflow because all four choices, the close action, the permission-policy chip, and model controls competed for one compact composer. The permission surface now keeps the safest high-frequency decisions—Reject and Allow Once—in the primary row, moves persistent grants into a labeled More menu, hides unrelated model/session configuration while the request is pending, and removes the duplicated service chip.
- An independent post-smoke subagent review found that the first fix only collapsed requests with more than three choices, leaving a three-choice `Allow once / Always allow / Reject` payload able to feature the persistent grant. The final implementation groups by choice semantics instead of choice count: one safe denial and one single-use allow may be featured, while every remaining choice—including persistent grants—stays in More.
- Final native evidence: `artifacts/ui-iteration-2026-08-09/native-permission-final.png`; persistent-choice menu evidence: `artifacts/ui-iteration-2026-08-09/native-permission-more-menu-final.png`. Both were captured from the rebuilt production macOS app, not the deterministic test renderer.
- The live request was rejected through the UI. `/etc/ianvs-acp-permission-smoke-2` remained absent, confirming the denial path reached the ACP runtime without executing the command.
- Permission-policy descriptions now state the actual behavior: manual requests are confirmed by the user, auto-review requests fall back to confirmation when unresolved, and full access automatically approves agent requests.
- `./tool/flutter_test_isolated.sh test/ui/prompt_input_test.dart`: 61/61 passed, including a 480 × 535 regression using the real four-choice payload and model options plus a three-choice regression that keeps `Always allow` in More and returns its exact ACP option id.
- `./tool/flutter_test_isolated.sh`: 1304/1304 passed.
- `flutter analyze --no-pub`: no issues.
- `./tool/flutter_test_isolated.sh docs/design-audit-2026-06-05/audit_screenshots_test.dart` in non-update mode: 10/10 passed after accepting the intentional permission-composer change.
- `git diff --check`: passed. The refreshed ten-state sheet is `artifacts/ui-iteration-2026-08-09/full-flow-contact-sheet-final.png`.

final result: passed

## Markdown file references and code blocks — 2026-08-02

### Visual truth and rendered evidence

- Source visual truth: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-10e9100f-d13d-44fd-83ef-0dabc3553a99.png` (1790 × 1403 px).
- Implementation screenshot: `design-qa-artifacts/markdown-rendering-polish.png` (1000 × 600 px).
- Implementation viewport: 1000 × 600 logical px at device pixel ratio 1.0.
- State: an assistant response containing two local Dart-file links followed by a fenced Dart code block.
- Rendering: Flutter widget renderer with deterministic ACP test fonts and Material icons. The Chinese fixture copy appears as fallback squares in the golden because the deterministic test font intentionally covers Latin glyphs only; the production macOS capture confirms normal Chinese fallback rendering.

### Full-view and focused comparison

- Full view: the implementation preserves the source hierarchy and content width while removing the heavy underline treatment and the code block's nested frame.
- Focused file-link view: each local file is now a compact neutral reference with a real Material file icon, 6 px radius, light border, restrained weight, and hover fill. Ordinary web links retain a lighter one-pixel underline.
- Focused code-block view: the language, wrap, and copy actions remain in one 38 px toolbar; the body and toolbar now share one 10 px card, one foreground border, and no clipped shadow or secondary Markdown frame.

### Comparison history

- Iteration 1 — P2: local file links used bold text, a gray text background, and a heavy underline, making punctuation and adjacent links visually run together. Fixed by introducing a dedicated inline file-reference component with explicit spacing, border, radius, icon, tooltip, and hover state.
- Iteration 1 — P2: the Markdown library's default code-block wrapper surrounded the shared code card, creating a double edge; the inner shadow could also be clipped by that wrapper. Fixed by making the library wrapper visually empty, moving the card border to the foreground, and removing the inner shadow.
- Iteration 2: the accepted 1000 × 600 golden shows no remaining actionable P0/P1/P2 issue.

### Fidelity surfaces

- Fonts and typography: file labels use a compact 12.5 px semibold treatment; code remains 12.5 px SF Mono/Menlo/Monaco with 1.5 line height; toolbar labels retain clear uppercase hierarchy.
- Spacing and layout rhythm: file references use 5/7 px horizontal padding and 2 px vertical padding; the code toolbar is 38 px high, the body retains 14 px horizontal padding, and the card uses the shared 10 px radius.
- Colors and visual tokens: links and code cards use the existing raised, hover, border, secondary-text, and tertiary-text tokens. No new accent color was introduced.
- Image quality and assets: no raster assets are required. File, terminal, wrap, and copy affordances use the existing Material icon library at native vector quality.
- Copy and content: link labels, destinations, code source, language label, copy action, wrap action, and long-code expansion behavior remain dynamic and unchanged.

### Interaction and regression coverage

- Local file links remain semantically links, expose their destination in a tooltip, preserve the existing link callback, and gain pointer hover feedback.
- Ordinary external links continue through the same callback with a restrained underline treatment.
- Copy, copied confirmation, wrap toggle, syntax highlighting, long-code collapse/expand, and Markdown file preview behavior remain covered.
- `flutter test --no-pub test/ui/chat_timeline_test.dart test/ui/markdown_code_block_test.dart test/ui/file_preview_workspace_test.dart`: 93 tests passed before the visual golden was added.
- The dedicated visual golden test passes at 1000 × 600 and will catch future regressions to nested borders or heavy file-link styling.

final result: passed

## ACP hosted terminal core and theme system — 2026-08-11

### Visual truth and native evidence

- Source visual truth: `artifacts/design-reference/conversation-canvas-option-2.png`.
- Implementation screenshot: `artifacts/theme-system-2026-08-11/native-theme-terminal-pubdev-0.1.0.jpeg`.
- Viewport and density: native macOS full-window captures. The source is 1487 × 1058 px; the implementation is 1230 × 768 px. CSS pixels and device density do not apply. The comparison was normalized by pane proportions, role-based color use, type hierarchy, component density, and shape rhythm; it is not a pixel-for-pixel clone review.
- State: the source shows an active conversation with the Context inspector; the implementation shows the same three-pane workspace in an empty session, with Context visible and a two-tab terminal panel open. Conversation content differs intentionally because this pass validates the shared design language and the newly integrated terminal state.
- Full-view evidence: both original-resolution images were provided together in the same comparison input on 2026-08-11.
- Focused-region evidence: no separate crop was required; the original captures keep the sidebar, toolbar, composer, inspector, terminal header, active tab, cursor, and scrollbar legible in the same comparison input.

### Findings

No P0, P1, or P2 discrepancies remain for the selected light Conversation Canvas direction.

- Typography: the implementation uses the macOS system font stack, restrained 12–20 pt hierarchy, compact labels, and SF Mono-compatible terminal text.
- Spacing and layout: the three-pane hierarchy, compact macOS toolbar density, 8 pt spacing rhythm, restrained radii, and content separation match the source direction. The terminal remains subordinate to the conversation and preserves the existing resizable workspace layout.
- Colors and tokens: warm neutral surfaces, graphite text, teal active/focus roles, semantic borders, and low-shadow elevation are consistent across the shell. Terminal foreground, cursor, selection, scrollbar, tab chrome, and warm-charcoal viewport are provided through the same ThemeData extension; normal text and terminal foreground/cursor pairs meet WCAG AA contrast.
- Image and asset quality: this product surface uses native icons and controls; no placeholder imagery, custom SVG substitute, or generated visual asset was introduced.
- Copy and content: session, workspace, context, and terminal labels remain coherent in the standalone empty-session state.
- States and accessibility: active/inactive terminal tabs, disabled/open toggle states, semantic labels, keyboard toggle (Control+backquote), smart cursor contrast, narrow-window coverage, and text scaling/overflow regression paths are covered by the application tests.

### Comparison history

- Pass 1: the initial native implementation was compared with the source and retained ACP's established three-column information architecture while adopting the warm-neutral and restrained-teal direction.
- Pass 2: the published-package build was compared again with two live terminal tabs. Terminal chrome was verified as part of the app hierarchy rather than a pure-black visual island. No P0/P1/P2 follow-up remained.

The source is explicitly a light-appearance reference. System dark appearance is not claimed by this QA result and was not used to judge this light-theme delivery.

final result: passed
