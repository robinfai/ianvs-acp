# Design QA — Inbox Autopilot

source visual truth path: `/Users/robinfai/.codex/generated_images/019f7045-ad01-73a1-bf05-56f9e30c8884/exec-afcc4f09-5ed0-4085-9c74-824b2b776bb0.png`

implementation screenshot path: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-paused-pass-8.png`

viewport: `1411 × 1115`

state: Inbox selected; automatic queue visible; `Update authentication flow` paused at an expanded Human checkpoint; recommended preset selected; background and evidence expanded.

full-view comparison evidence: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/comparison-pass-8.png`

focused region comparison evidence: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/comparison-checkpoint-pass-8.png` — used because the checkpoint typography, radio controls, action icons, evidence columns, and border rhythm needed readable close inspection.

additional state evidence:

- resuming transition: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-resuming-pass-2.png`
- synchronized running state: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-running-pass-3.png`
- custom-answer propagation: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-running-pass-2.png`
- new-task dialog: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-new-task-modal-pass-2.png`
- 900 px viewport: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-tablet-900-pass-2.png`
- 720 px viewport: `/Users/robinfai/flutter_projects/ianvs-acp/prototypes/inbox-autopilot/qa/implementation-compact-720-pass-1.png`

## Findings

- No actionable P0, P1, or P2 differences remain.
- Fonts and typography: the Inter/system stack, hierarchy, weights, wrapping, and dense small-label treatment visually match the reference. No truncation occurs in the reference viewport.
- Spacing and layout rhythm: the two-pane proportions, top bars, queue density, timeline alignment, checkpoint padding, controls, evidence grid, and footer match the source composition.
- Colors and visual tokens: purple primary/action states, amber pause state, green completion states, muted borders, and surface hierarchy remain faithful. Automated token checks verify normal-text contrast from `4.87:1` to `6.69:1` across the principal surfaces.
- Image quality and asset fidelity: the target contains no photographic or illustrative raster assets. Visible product and action symbols are implemented with one consistent Material icon library; no handcrafted SVG or placeholder imagery is used.
- Copy and content: task states, checkpoint rationale, preset answers, custom-answer affordance, automatic-resume messaging, and evidence context are coherent and match the intended standalone flow.
- Icons: toolbar, queue, checkpoint, evidence, and action icons are complete, aligned, and optically balanced after the comparison iterations.
- Accessibility: semantic buttons, tabs, radio controls, labels, a modal dialog with keyboard focus containment, explicit focus-visible treatment, and reduced-motion handling are present. Axe semantic scans pass for the Inbox and dialog states.
- Viewport resilience: the `900 × 900` pass produced `scrollWidth = clientWidth = 900`; the `720 × 800` minimum-desktop pass produced `scrollWidth = clientWidth = 720`. Neither state overlaps or clips horizontally, and the detail pane remains independently scrollable. The visual target is a desktop client, so phone layout is outside this prototype's acceptance scope.

## Interaction Verification

- Selected a preset response and entered a custom response.
- Saved an answer while keeping the task paused; the confirmation remained visible.
- Collapsed and re-expanded Background & evidence.
- Submitted an answer and confirmed automatic transition from paused to running, with step 5 active and the recorded answer visible.
- Confirmed the task moved from Waiting to Running and queue counts changed from `1 waiting / 2 running` to `0 waiting / 3 running`.
- Confirmed the selected preset or custom answer is preserved in both the completed checkpoint and the active execution step after navigating away and back.
- Created a new automatic task and confirmed it entered the Running queue immediately.
- Confirmed new-task instructions are preserved in the selected task summary, Escape closes the dialog, and keyboard focus remains contained inside it.
- Expanded additional source files and the linked-session context, then collapsed the evidence section.
- Browser console warnings/errors checked after the final render: none.
- Repeatable command: `npm run acceptance`.
- Automated acceptance: 9/9 interaction and semantic tests passed; all six contrast pairs passed; production build passed with Vite.

## Comparison History

1. Pass 1 — P2 icon fidelity: titlebar and toolbar actions used less faithful glyphs. Fixed by switching to closer Material desktop, agent-management, and outlined run icons. Post-fix evidence: `qa/comparison-pass-2.png`.
2. Pass 2 — P2 accessibility state coverage: focus visibility and reduced-motion behavior were not explicit. Added shared `:focus-visible` styling and a reduced-motion override. Post-fix evidence: `qa/comparison-pass-3.png`; tablet evidence: `qa/implementation-tablet-900.png`.
3. Pass 3 — P2 primary-action icon fidelity: the resume action used a solid play triangle instead of the source's outlined send glyph. Replaced it with the matching outlined send icon. Post-fix evidence: `qa/comparison-checkpoint-pass-4.png`.
4. Pass 4 — P2 action-icon scale: checkpoint action icons were visibly smaller than the source. Normalized them to 18 px. Post-fix evidence: `qa/comparison-checkpoint-pass-5.png`.
5. Pass 5 — no actionable P0/P1/P2 findings remained; full-view and focused-region comparisons passed.
6. Pass 6 — P1 state integrity: after answering, the right detail pane resumed but the left queue still reported the task as waiting; the active-step copy also assumed Keychain regardless of the chosen answer. Lifted checkpoint state into the task model, synchronized queue group/status/progress, persisted the answer across navigation, and made execution copy answer-aware. Post-fix evidence: `qa/implementation-running-pass-2.png`; automated regression: `src/App.test.jsx`.
7. Pass 6 — P2 transition clarity: the resuming action used generic disabled opacity and appeared cancelled. Added a full-contrast busy treatment, spinner, disabled duplicate actions, and reduced-motion handling. Post-fix evidence: `qa/implementation-resuming-pass-2.png`.
8. Pass 6 — P2 dialog accessibility: the modal did not contain keyboard focus and its header/footer semantics created duplicate landmarks. Added a focus loop, Escape handling, valid dialog structure, and semantic Axe coverage. Post-fix evidence: `qa/implementation-new-task-modal-pass-2.png`.
9. Pass 6 — P2 text contrast: waiting, paused, window chrome, footer, and pending-state text used sub-4.5:1 colors. Adjusted semantic text tokens while preserving the amber/green/purple hierarchy, then added a contrast gate. Post-fix evidence: `qa/comparison-pass-7.png`; automated gate: `scripts/check-contrast.mjs`.
10. Pass 7 — P2 semantic state color: after automatic resume, the selected running task retained the amber paused-selection surface. Added group-aware selected styling so waiting remains amber and running becomes purple. Post-fix evidence: `qa/implementation-running-pass-3.png`.
11. Pass 8 — no actionable P0/P1/P2 findings remained. Full-view, focused checkpoint, resuming, running, modal, 900 px, and 720 px reviews passed.

## Open Questions

- None blocking. The prototype intentionally validates the desktop Inbox flow before production Flutter integration.

## Implementation Checklist

- [x] Match the selected visual direction at the source viewport.
- [x] Support automatic queue and new-task execution behavior.
- [x] Pause at a human checkpoint with preset and custom responses.
- [x] Support save-and-stay-paused and answer-and-auto-resume paths.
- [x] Present rationale, constraints, source files, and next-step context.
- [x] Verify a narrower desktop/tablet viewport and console health.
- [x] Keep queue counts and detail state synchronized through automatic resume.
- [x] Preserve the actual human answer in downstream execution copy.
- [x] Cover the core journey, dialog semantics, keyboard behavior, and contrast with repeatable automation.

## Follow-up Polish

- P3: native font rasterization and the small titlebar glyph may differ slightly across macOS/browser builds; this does not affect hierarchy or usability.

final result: passed
