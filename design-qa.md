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
