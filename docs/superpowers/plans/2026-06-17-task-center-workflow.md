# Task Center Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the v1 task center workflow where board status, task owner, readiness, acceptance, human confirmation, workspace role agents, and event history are separate product concepts.

**Architecture:** Extend the existing task center JSON model, store, controller, MCP API, and Flutter board dialog in place. Preserve old task-center JSON by defaulting newly introduced fields during deserialization.

**Tech Stack:** Flutter/Dart, boardview, local JSON persistence, mcp_dart, flutter_test.

---

### Task 1: Task Protocol Model

**Files:**
- Modify: `lib/task_center/task_center_models.dart`
- Modify: `lib/task_center/task_center_store.dart`
- Test: `test/task_center/task_center_store_test.dart`

- [ ] Write failing tests for workspace role config, task owner/readiness/acceptance/human questions, and events.
- [ ] Run `flutter test test/task_center/task_center_store_test.dart --reporter=compact` and verify the new tests fail because the fields and store methods are missing.
- [ ] Add model classes and store methods with backwards-compatible JSON defaults.
- [ ] Re-run the store test file and verify it passes.

### Task 2: Agent Intent API

**Files:**
- Modify: `lib/task_center/task_center_agent_api.dart`
- Modify: `lib/task_center/task_center_mcp_host.dart`
- Test: `test/task_center/task_center_agent_api_test.dart`
- Test: `test/task_center/task_center_mcp_host_test.dart`

- [ ] Write failing tests for role configuration, owner transfer, human confirmation, role inbox, work-agent claim, execution result, and event history tools.
- [ ] Run the task center API tests and verify they fail on missing tools.
- [ ] Implement intent-level API methods and MCP descriptions/schemas.
- [ ] Re-run task center API/MCP tests and verify they pass.

### Task 3: Board And Detail UI

**Files:**
- Modify: `lib/ui/components/task_center_board.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/ui/task_center_board_test.dart`

- [ ] Write failing source/widget tests for the persistent task detail panel, owner/readiness chips, workspace role settings, and agent server binding.
- [ ] Run `flutter test test/ui/task_center_board_test.dart --reporter=compact` and verify the new tests fail.
- [ ] Implement the board/detail split, editable protocol panel, and workspace role settings dialog.
- [ ] Re-run the UI task-center tests and verify they pass.

### Task 4: Verification

**Files:**
- All touched task center files.

- [ ] Run `dart format --output=none --set-exit-if-changed lib test docs`.
- [ ] Run `flutter analyze`.
- [ ] Run `flutter test --reporter=compact`.
- [ ] Run `git diff --check`.
