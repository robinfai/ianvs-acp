# Config GUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build GUI editing and saving for every `settings.json` configuration field currently supported by the ACP client.

**Architecture:** Add a focused config store that turns `AcpClientConfig` into the canonical `settings.json` shape, merges it with any existing unknown top-level fields, writes the file, and reparses it. Keep GUI state in `AgentConfigDialog`, then pass a saved `AcpClientConfig` back through `AppShell` to `AcpClientApp` so controllers refresh from the new config.

**Tech Stack:** Dart, Flutter Material, `flutter_test`, existing ACP config classes.

---

## File Structure

- Create `lib/config/acp_config_store.dart`: config JSON serialization, unknown-field preserving writes, and save validation.
- Modify `lib/config/acp_client_config.dart`: add `toJson` methods for provider config classes and trust-rule serialization helpers.
- Modify `lib/app.dart`: pass `onSaveConfig` into the shell and write config through the new store.
- Modify `lib/ui/shell/app_shell.dart`: accept `onSaveConfig` and forward it to the config dialog.
- Modify `lib/ui/components/agent_config_dialog.dart`: convert the existing read-only dialog into a stateful editor with sections and edit subdialogs.
- Add `test/config/acp_config_store_test.dart`: test write/merge/create behavior.
- Update `test/ui/agent_config_dialog_test.dart`: test editable controls and validation.
- Update `test/ui/acp_client_app_test.dart`: test saving through the app refreshes visible config.
- Update `README.md` and feature audit docs only after code proves the GUI path works.

## Task 1: Config Serialization And Store

**Files:**
- Create: `lib/config/acp_config_store.dart`
- Modify: `lib/config/acp_client_config.dart`
- Test: `test/config/acp_config_store_test.dart`

- [x] **Step 1: Write the failing store tests**

Add tests that call `AcpConfigStore.writeConfig` with a temp file and assert:

```dart
final next = await AcpConfigStore.writeConfig(
  config: editedConfig,
  configPath: file.path,
);
expect(next.agentName, 'Codex');
expect(decoded['unknown_top_level'], 'kept');
expect(decoded['default_agent_server'], 'Codex');
expect(decoded['agent_servers']['Codex']['command'], '/usr/local/bin/npx');
expect(decoded['client_providers']['filesystem']['read_text_file'], true);
```

Also test a missing file path is created, and an empty `configPath` throws `FormatException`.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/config/acp_config_store_test.dart`

Expected: fail because `AcpConfigStore` does not exist.

- [x] **Step 3: Implement provider serialization and store**

Add `toJson()` methods for filesystem, terminal, permission provider, and client provider classes. Add `AcpConfigStore.toSettingsJson(config)` and `AcpConfigStore.writeConfig(...)` using `JsonEncoder.withIndent('  ')`.

- [x] **Step 4: Run test to verify it passes**

Run: `flutter test test/config/acp_config_store_test.dart`

Expected: pass.

## Task 2: App Save Wiring

**Files:**
- Modify: `lib/app.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Test: `test/ui/acp_client_app_test.dart`

- [x] **Step 1: Write the failing app save test**

Add a widget test that opens `Agent Configuration`, edits the default agent, saves, then opens `New Session` and sees the updated default/current agent ordering:

```dart
await tester.tap(find.byTooltip('Agents'));
await tester.tap(find.text('Agent Configuration'));
await tester.tap(find.byTooltip('Set Codex as default'));
await tester.tap(find.widgetWithText(FilledButton, 'Save'));
expect(savedConfig.defaultAgentServerName, 'Codex');
```

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/acp_client_app_test.dart --plain-name "AcpClientApp saves edited agent config"`

Expected: fail because the dialog has no save path.

- [x] **Step 3: Add save callback wiring**

Add an `AcpConfigSaver` typedef, pass `onSaveConfig` through `AppShell`, and in `AcpClientApp` call `AcpConfigStore.writeConfig`, reconcile controller cache, activate the returned config, and show a short saved message.

- [x] **Step 4: Run the focused app test**

Run: `flutter test test/ui/acp_client_app_test.dart --plain-name "AcpClientApp saves edited agent config"`

Expected: pass.

## Task 3: Editable Agent Dialog Shell

**Files:**
- Modify: `lib/ui/components/agent_config_dialog.dart`
- Test: `test/ui/agent_config_dialog_test.dart`

- [x] **Step 1: Write failing dialog tests for basic editing**

Assert the dialog renders Add Agent, Save, Set Default, Edit, and Delete controls, can set default agent, and blocks save when `configPath` is missing.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: fail because the controls are absent.

- [x] **Step 3: Convert dialog to stateful editor**

Keep existing visual panels, add local editable lists, dirty state, Save button, error banner, and section action buttons. Keep read-only detail rows visible so existing tests still pass.

- [x] **Step 4: Run dialog tests**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: pass for existing rendering plus new basic editing tests.

## Task 4: Agent And MCP Edit Subdialogs

**Files:**
- Modify: `lib/ui/components/agent_config_dialog.dart`
- Test: `test/ui/agent_config_dialog_test.dart`

- [x] **Step 1: Write failing tests for agent and MCP CRUD**

Cover adding a stdio agent with command/args/env, adding an HTTP agent with headers, deleting an agent, adding a stdio MCP server, adding an ACP MCP server, and deleting an MCP server.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: fail because edit subdialogs are not implemented.

- [x] **Step 3: Implement subdialogs**

Add compact `AlertDialog` forms with type dropdowns, text fields, add/remove row controls for args/env/headers, and validation before returning an `AgentServerConfig` or `McpServerConfig`.

- [x] **Step 4: Run dialog tests**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: pass.

## Task 5: Directories And Provider Editors

**Files:**
- Modify: `lib/ui/components/agent_config_dialog.dart`
- Test: `test/ui/agent_config_dialog_test.dart`

- [x] **Step 1: Write failing tests for remaining config fields**

Cover adding/removing additional directories, toggling filesystem/terminal providers, adding/removing trust rules, and configuring global review agent fields.

- [x] **Step 2: Run test to verify it fails**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: fail because these controls are absent or incomplete.

- [x] **Step 3: Implement remaining editors**

Use switches for provider booleans, path text fields for directories, row forms for trust rules, and a small review-agent form with enabled, target, tool, model, and timeout fields.

- [x] **Step 4: Run dialog tests**

Run: `flutter test test/ui/agent_config_dialog_test.dart`

Expected: pass.

## Task 6: Full Verification And Docs

**Files:**
- Modify: `README.md`
- Modify: `docs/acp_feature_audit.md`
- Modify: `docs/manual_followups.md`

- [x] **Step 1: Run focused tests**

Run:

```sh
flutter test test/config/acp_config_store_test.dart test/ui/agent_config_dialog_test.dart test/ui/acp_client_app_test.dart
```

Expected: pass.

- [x] **Step 2: Run static analysis**

Run: `flutter analyze`

Expected: no analyzer errors.

- [x] **Step 3: Update docs**

Change docs that say these fields are config-only or follow-ups so they now point to Agent Configuration as the GUI editing surface.

- [x] **Step 4: Run doc tests if needed**

Run: `flutter test test/docs/manual_followups_test.dart`

Expected: pass.

## Self-Review

- Spec coverage: all listed config fields have a task covering GUI editing and save behavior.
- Placeholder scan: no unresolved placeholder language or deferred behavior remains in this plan.
- Type consistency: the plan uses existing `AcpClientConfig`, `AgentServerConfig`, `McpServerConfig`, and `AcpPermissionReviewAgentConfig` names.
