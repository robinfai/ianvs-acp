# Agent chat 0.3.1: Markdown consumer patch

## Scope and authorization

The user explicitly authorized publishing `ianvs_markdown 0.3.2` and, after
integration verification, `ianvs_agent_chat 0.3.1` on 2026-10-30. The related
source changes are authorized for commit, push and mainline merge.

Chat raises its minimum Markdown requirement from `^0.3.1` to `^0.3.2`.
No chat public API, core or ACP runtime behavior changes. Markdown 0.3.2 is the
compatible M05/M18 backport, not the broader unpublished Markdown mainline.
Its published archive SHA256 is
`8b092b459d06c63de151de82227ecb0331854dc7a94a150d571056bd7fcf6ed1`.

## Verification plan

The new real `ChatTimeline` consumer regressions reproduce short table words
wrapping on 320/390px layouts and insufficient ordered-marker width with
Markdown 0.3.1. They check selectable-text geometry, horizontal touch scrolling
and measured marker widths with Markdown 0.3.2.

Before publication: resolve hosted Markdown without overrides; run the chat
suite and static analysis, application tests, the example checks and a macOS
consumer build; review golden changes if the intentional marker-width fix affects
them. Run the isolated release candidate's zero-override publication dry-run.

Prepare only this package with:

```sh
python3 tool/prepare_shared_agent_release.py --package ianvs_agent_chat --output /absolute/new/directory
```

The workspace retains local core development paths and `publish_to: none`.
The publication copy substitutes hosted core `^0.1.0`; other packages are not
published. After upload, verify official archive hashes and exact file contents,
then resolve a fresh consumer using only hosted chat 0.3.1 and Markdown 0.3.2.
Terminal can then remove its old Markdown Git override and update its workspace
root lockfile. Existing unrelated `.gitignore` and Mermaid preparation changes
are excluded from this release.

## Pre-publication results

- The three new layout tests fail on hosted Markdown 0.3.1 and pass on 0.3.2.
- Chat: 307 passed, two opt-in provider tests skipped; analysis passed.
- ACP application: 1,386 passed; analysis passed.
- Standalone example: two tests passed, analysis passed, macOS Debug build passed.
- Isolated chat publication candidate: zero-warning dry-run with hosted core and
  Markdown dependencies, no overrides. No existing visual baselines changed.
- Tracked root/example lockfiles changed only for chat 0.3.1 and hosted Markdown
  0.3.2 with the official archive hash above.
