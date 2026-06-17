# Task Center Fast Agent Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let workspace chat send human messages to the configured fast agent, while adding default agent models and manual task title editing.

**Architecture:** Keep task center state local and persisted through `TaskCenterStore`. Add workspace chat records to `TaskWorkspace`, expose them through controller and MCP tools, and let the app inject a fast-agent prompt callback into the task center UI. Agent default model belongs to `AgentServerConfig` and is applied after session settings load when supported.

**Tech Stack:** Flutter, Dart, boardview, local JSON persistence, ACP client/session settings, MCP task center tools.

---

### Task 1: Agent Default Model

**Files:**
- Modify: `lib/config/acp_client_config.dart`
- Modify: `lib/ui/components/agent_config_dialog.dart`
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/app.dart`
- Test: `test/config/acp_client_config_test.dart`
- Test: `test/state/chat_controller_test.dart`

- [ ] Write failing config tests proving `default_model` is parsed and serialized for every agent type.
- [ ] Write failing controller test proving a new session applies the default model when the session exposes a model option.
- [ ] Add `defaultModel` to `AgentServerConfig`, editor UI, summary UI, controller signature, and chat controller startup.
- [ ] Run targeted tests until they pass.

### Task 2: Editable Task Title

**Files:**
- Modify: `lib/ui/components/task_center_board.dart`
- Test: `test/ui/task_center_board_test.dart`

- [ ] Write failing widget test proving the selected task title can be edited and saved.
- [ ] Add a title controller to the task protocol panel and save it through `TaskCenterController.updateTask`.
- [ ] Run the widget test until it passes.

### Task 3: Workspace Chat With Fast Agent Admission

**Files:**
- Modify: `lib/task_center/task_center_models.dart`
- Modify: `lib/task_center/task_center_store.dart`
- Modify: `lib/task_center/task_center_controller.dart`
- Modify: `lib/task_center/task_center_agent_api.dart`
- Modify: `lib/task_center/task_center_mcp_host.dart`
- Modify: `lib/ui/components/task_center_board.dart`
- Modify: `lib/app.dart`
- Test: `test/task_center/task_center_store_test.dart`
- Test: `test/task_center/task_center_agent_api_test.dart`
- Test: `test/ui/task_center_board_test.dart`

- [ ] Write failing store tests for persisted workspace chat messages.
- [ ] Write failing API tests for posting and listing workspace chat messages.
- [ ] Write failing widget test proving a human message is sent to the configured fast agent callback and persisted in the chat.
- [ ] Add `TaskWorkspaceChatMessage` and workspace `chatMessages` persistence.
- [ ] Add controller methods and MCP tools for chat message list/post.
- [ ] Add a workspace chat panel with human input, fast-agent response posting, and task/event separation.
- [ ] Wire `App` to call the configured fast agent ACP session with a task-center instruction prompt.
- [ ] Run targeted tests until they pass.

### Task 4: Verification

**Files:**
- Existing Dart files and tests touched above.

- [ ] Run `dart format` on touched Dart files.
- [ ] Run `flutter analyze`.
- [ ] Run targeted task center and config tests.
- [ ] Run full test suite.
- [ ] Build the macOS debug app if tests and analysis are clean.
