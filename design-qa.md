# Codex detail-alignment design QA

## Evidence

- Latest combined reference/current screenshot supplied by the user: `/var/folders/k2/8qbf3nrs7t1749d198rw0df40000gn/T/codex-clipboard-c218da74-655f-4bec-a186-12235e1d87b7.png`
- Codex reference crop: `/private/tmp/codex-detail-reference.png`
- Running implementation screenshot: `/private/tmp/ianvs-acp-codex-detail-after.png`
- Same-viewport side-by-side comparison: `/private/tmp/ianvs-acp-codex-detail-side-by-side.png`
- Sidebar and turn-navigation focused comparison: `/private/tmp/ianvs-acp-codex-detail-sidebar-focused.png`
- Conversation-outline active/default state: `/private/tmp/conversation-outline-active-idle.png`
- Conversation-outline hover state: `/private/tmp/conversation-outline-hover.png`
- Focused active/hover comparison: `/private/tmp/conversation-outline-states-comparison.png`
- Animated-hover idle state: `/private/tmp/conversation-outline-hover-animation-idle.png`
- Animated-hover expanded state: `/private/tmp/conversation-outline-hover-animation-expanded.png`
- Animated-hover adjacent-marker state: `/private/tmp/conversation-outline-hover-animation-adjacent.png`
- Same-viewport before/after hover comparison: `/private/tmp/conversation-outline-hover-animation-comparison.png`
- Smooth-navigation initial state: `/private/tmp/conversation-outline-smooth-scroll-start.png`
- Far historical-turn navigation result: `/private/tmp/conversation-outline-smooth-scroll-top.jpeg`
- Rapid retarget result: `/private/tmp/conversation-outline-smooth-scroll-retarget.jpeg`
- Repeated-click stable result: `/private/tmp/conversation-outline-smooth-scroll-repeat.jpeg`
- Direct virtual-window navigation result: `/private/tmp/conversation-outline-direct-virtual-jump.jpeg`
- Tool activity expanded state: `/private/tmp/tool-activity-expanded-current.png`
- Tool activity focused comparison: `/private/tmp/tool-activity-focused-comparison.png`

The Codex reference was normalized to the same 1225 × 768 viewport as the running macOS Debug application before comparison. The implementation screenshot was captured from the restored `拉取最新代码并运行` session, not from a generated mockup.

## Acceptance criteria

| Area | Expected | Result |
| --- | --- | --- |
| Background | Cool neutral sidebar and white conversation surface match the Codex hierarchy | passed |
| Typography | Apple system font, neutral text colors, and restrained weights across sidebar and conversation | passed |
| Density | Conversation width, paragraph line height, turn spacing, and sidebar row rhythm align with the reference | passed |
| Session list | Sessions remain grouped by workspace; selected and hovered sessions use full-row neutral fills without a nested tree border | passed |
| Turn outline | Compact 16 px rhythm, short neutral markers, one emphasized active marker, and clickable history navigation | passed |
| Outline alignment | Short outlines are vertically centered while every marker keeps the 16 px pitch | passed |
| Outline states | Active remains 7 px long; hover expands to 34 px and affects three neighboring levels with distance falloff | passed |
| Outline motion | Adjacent hover changes interpolate directly without collapsing through the idle state; previews fade and slide between turns | passed |
| Outline selection | Clicking a marker directly replaces the virtual-list center anchor, renders only the target neighborhood, and remains stable on repeated clicks | passed |
| Outline retargeting | Consecutive marker clicks synchronously replace the anchor; only the final selected neighborhood is retained | passed |
| User messages | User prompts use a subtle neutral bubble and preserve clear separation from execution and response content | passed |
| Tool activity | Completed tool/process groups remain collapsed by default | passed |
| Tool disclosure states | Default is quiet with no chevron; hover darkens and reveals a right chevron; expanded returns to secondary color and rotates the chevron downward | passed |
| Tool summaries | Tool names are projected into deterministic natural-language activity phrases, with flat read/edit/run/control detail rows after expansion | passed |
| Product identity | ACP Client keeps its own branding and information architecture | passed |

## Automated desktop acceptance

Computer Use launched and inspected:

`/Users/robinfai/flutter_projects/ianvs-acp/build/macos/Build/Products/Debug/ACP Client.app`

Verified on the restored real session:

1. The session loaded without a loading/error state and exposed 21 meaningful user-turn outline controls.
2. No raw attachment transport syntax was rendered in the visible conversation.
3. The workspace session list rendered as one grouped list, with the active session using the full-row selected fill.
4. Clicking a turn marker moved the conversation from the latest turn to the corresponding historical turn.
5. Completed tool calls rendered as compact collapsed rows in the inspected historical turn.
6. Hovering a historical marker expanded that marker and progressively shortened its neighbors without changing vertical spacing.
7. Moving away restored the selected marker to its compact active length while retaining the selected historical turn.
8. Repeating the same marker click kept the same user prompt positioned at the top of the conversation viewport.
9. Moving between adjacent outline markers kept the preview present and switched directly to the neighboring prompt without a blank intermediate state.
10. A far historical marker replaced the list center immediately without displaying intermediate conversation positions.
11. Consecutive marker clicks retained only the final selected neighborhood; clicking that marker again left the rendered conversation unchanged.

Automated regression checks:

- `flutter test --no-pub`: 1749 tests passed.
- `flutter analyze --no-pub`: no issues found.
- `git diff --check`: passed.
- macOS Debug build: succeeded.

## Iterations

1. Measured the supplied comparison and replaced the warmer/lighter sidebar tokens with the Codex neutral hierarchy: `#f4f5f5` background, `#e7e8e9` selection, `#eceeef` hover, `#f3f3f4` user message surface, and `#27292c` primary text.
2. Tightened the conversation content width, paragraph line height, inter-turn spacing, processed-row density, and outline geometry.
3. Removed the nested session tree border, extended selected/hover fills across the session row, and aligned session indentation and type rhythm with the reference.
4. Rebuilt and replayed the real desktop session. The first full regression run found one stale selected-color assertion and one unused import; both were corrected before the final clean run.
5. Replaced proportional turn seeking with a bounded rendered-index search followed by `ensureVisible`, and locked explicit selection until the user manually scrolls. Widget coverage uses 220 variable-height turns to exercise virtual-list skew and repeated selection.
6. Moved hover exit ownership from each 16 px marker row to the whole outline rail so crossing row boundaries no longer emits a transient empty hover. Marker geometry/color now uses a 220 ms ease-out-quart interpolation; the preview uses a 180 ms fade/slide transition. Frame-level widget coverage verifies both adjacent markers remain expanded during the handoff and that the preview fades out only after leaving the rail.
7. Removed offset estimation and animated traversal entirely. The conversation is now a two-sided `CustomScrollView`: earlier turns lazily grow above a center sliver and later turns lazily grow below it. An outline click changes that center to the selected turn and resets the local offset in the same frame.
8. Added coverage for a 220-turn mixed-height history that verifies the selected turn and its immediate neighbors are rendered after one frame while distant turns are absent. A separate 140-turn scenario verifies consecutive direct retargets and repeated-click stability.
9. Replaced the card-like multi-tool header with the supplied three-state disclosure: quiet gray default without a visible chevron, dark hover with a right chevron, and gray expanded state with a downward chevron and details. Mixed calls now produce a compact activity summary such as loading tools, editing files, reading files, and running commands.
10. Replaced separator-based and count-only tool labels with deterministic natural-language templates such as `Loaded tools, edited files, read files, and ran commands`, `Controlled the app`, and `Waited for background work`. Expanded groups now use compact icon-and-text action rows with filenames, commands, diff totals, and failure state instead of numbered cards and completed pills.

## Final result

passed
