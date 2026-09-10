# Configuration

Updated: 2026-09-10. Source baseline: `b9297f5`.

This is the current configuration guide. The dated settings audits preserve
pre-redesign observations; they are not the current field or navigation guide.
See the [documentation index](README.md) for their status and successors.

## Settings, scope, and saving

Open **设置** in the sidebar, **Agents → 管理 Agent…**, or press **⌘,**
to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, the review
agent, assistant-agent settings, and local recovery storage settings. By default,
the app persists those GUI choices to:

```text
~/.config/ianvs-acp/settings.json
```

Settings has five sections: **Agent**, **工具与目录**, **权限**,
**AI 助手**, and **本地存储**. Agent/MCP editors edit the same application draft;
only the page's Save action persists it. Switching sections preserves the draft.
An unchanged draft cannot be saved; leaving a changed draft offers to keep
editing or discard it. Save failure keeps the input available for retry.

Saving normally reloads the configuration and replaces the owned controllers;
indexed sessions may need to be restored. Any controller streaming or running a
session operation blocks saving. If an operation starts while the file write
is awaiting I/O, the committed configuration waits until all controllers are
idle before being applied. "Saved" can therefore precede runtime replacement.

| Control | Scope and effect |
| --- | --- |
| Settings → startup default Agent | Saved application default; applying settings also selects/reloads the configured Agent |
| Agents menu → select Agent | Changes the current connection in memory; does not save a new startup default |
| Current session parameters / composer model and reasoning | Applies negotiated Agent settings immediately; no application Save |
| Composer execution policy | Controller-local permission handling; does not write `settings.json` |
| New Session → working directory / template | Defines the new session; does not create a workspace settings file |
| Independent LLM chat | Separate in-memory connection; no ACP recovery or Keychain persistence |

## Credentials and discovery

On macOS, Agent and MCP `env`/`headers` values entered in Settings
are stored in the login Keychain. The JSON file stores only opaque
`env_refs`/`header_refs`; do not edit or copy those references between config
files. Existing plaintext values are migrated to Keychain before the JSON is
atomically replaced. If a referenced Keychain item is missing, startup reports
the exact field and keeps configuration editing disabled until the credential
is restored or re-entered.

On startup, the app can detect missing local ACP agents and ask whether to add
them to `agent_servers`. The built-in detectors cover:

- Codex through a local `npx` command running
  `@agentclientprotocol/codex-acp`.
- Pi through the `pi-acp` adapter when both `npx` and the `pi` command are
  available.
- Cursor through its separately installed CLI (`agent acp`), including the
  `cursor-agent` executable alias. Discovery also checks the local
  `~/.local/bin` directory.
- CodeBuddy through an installed `codebuddy --acp` command, with
  `npx -y @tencent-ai/codebuddy-code --acp` as a fallback.

Equivalent direct commands, aliases, and npx packages are treated as the same
agent so discovery does not add duplicate profiles. Provider credentials remain
user-managed through each CLI or the agent server `env` fields in Settings.
Install and authenticate the Cursor CLI before using its ACP
profile; installing the Cursor desktop editor alone does not guarantee that the
separate CLI is available.

## Saved configuration example

The paths, model and mode below are placeholders; use values present on your
machine and advertised by the selected Agent. The discovery recipes come from
[adapter constants](../lib/acp/acp_adapter_packages.dart); they do not certify
an upstream CLI version or an account's model entitlement.

Saved shape example for automation and debugging:

```json
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["@agentclientprotocol/codex-acp"]
    },
    "Pi": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["-y", "pi-acp@0.0.31"]
    },
    "Cursor": {
      "type": "custom",
      "command": "/Users/example/.local/bin/agent",
      "cwd": "/Users/example/project",
      "args": ["acp"]
    },
    "CodeBuddy": {
      "type": "custom",
      "command": "/opt/homebrew/bin/codebuddy",
      "cwd": "/Users/example/project",
      "args": ["--acp"]
    }
  },
  "additional_directories": [
    "/Users/example/related-project"
  ],
  "mcp_servers": [
    {
      "name": "filesystem",
      "command": "/opt/homebrew/bin/npx",
      "args": [
        "-y",
        "@modelcontextprotocol/server-filesystem",
        "/Users/example/project"
      ]
    }
  ],
  "client_providers": {
    "permissions": {
      "review_agent": {
        "agent_server_name": "Codex",
        "model": "review-model"
      }
    }
  },
  "default_session_template": "review",
  "session_templates": {
    "review": {
      "name": "Code review",
      "version": 1,
      "agent_server": "Codex",
      "mcp_servers": ["filesystem"],
      "additional_directories": ["/Users/example/related-project"],
      "mode": "plan",
      "model": "review-model",
      "reasoning_effort": "high"
    }
  },
  "storage": {
    "max_size_gb": 50,
    "retention_days": 30
  }
}
```

## Session templates

`session_templates` are declarative, versioned recipes shown in the New
Session dialog. Omitting `mcp_servers` inherits every configured MCP server;
an empty array selects none. An omitted template `permissions` object inherits
the global policy;
a supplied object replaces that policy and uses parser defaults for its omitted
fields. Template additional directories are added to the global roots, so an
empty template directory list does not remove global access. The assistant
configuration follows the same whole-object inherit-or-replace rule. Templates
are currently edited in `settings.json`; Settings preserves them during unrelated
GUI edits. The selected
template ID and version are retained in the local session index, so resumed
sessions can report missing definitions or version drift.

## Diagnostics and storage

Open **活动与诊断** in the sidebar for the active session. Its
`Events` page shows the chronological prompt/response, tool, status, permission,
and error trajectory; `Permissions` shows and exports the current
controller/connection's retained permission history, which may include its other sessions but excludes other
connections; and `Runtime` reports the exact recipe, MCP/providers, negotiated ACP
capabilities, compatibility degradations, and credential-reference counts.
Credential values and URL credentials/query strings are never displayed.

Storage settings apply independently to the session registry and transcript cache.
The sidebar/session index has a separate lifecycle. See the
[local recovery storage policy](sqlite_storage.md) for default paths, per-store
capacity, retention, and data contents.

## Transports, directories, and permissions

Remote MCP servers can use `type: "http"` or `"sse"` with `url` and optional
`headers`; enter secret header values through Settings so they are
stored in Keychain rather than plaintext JSON. This is MCP configuration sent
through a local stdio ACP session. It does not make the ACP agent transport
remote. Existing `type: "acp"` MCP entries can still be read from configuration,
but the production runtime rejects them because MCP-over-ACP is unavailable.

Stdio `agent_servers` can set `cwd` to choose the working directory used when
launching the agent process. The aliases `working_directory` and
`workingDirectory` are also accepted.

`additional_directories` may list extra absolute workspace roots. They are sent
only to agents that advertise `sessionCapabilities.additionalDirectories`, and
filesystem/terminal provider jail checks treat those roots as part of the
session workspace.

Filesystem read/write and ACP terminal providers default to disabled. When
explicitly enabled, the production Rust providers enforce the session roots.
`client_providers.filesystem.allow_read_outside_workspace` is still parsed,
saved and shown in Settings, but is not passed into the Rust provider: enabling
it does not permit out-of-workspace reads. Add an explicit allowed root for
supported access; the unresolved field/implementation mismatch is tracked in
[Manual follow-ups](manual_followups.md).

`client_providers.permissions.review_agent` can select a configured ACP agent
with `agent_server_name`, or point at a sidecar MCP server, for the prompt
composer's `自动审查` policy. ACP reviewers run in an isolated sidecar client and
session, so they can automatically approve a low-risk `allow` decision even
when they use the same agent or model as the main session. An individual
`agent_servers.<name>.review_agent.model` can override the review model for that
agent. High-risk or inconclusive results remain available for manual approval.
The Settings switch **使用指定审查来源** selects an explicit reviewer recipe;
turning it off does not disable the composer's Auto Review policy, which can
use an isolated session of the current Agent. AI assistant title/summary
augmentation has its own switch, disabled by default.

## Configuration and workspace path selection

Configuration loading uses this order, from highest priority:

1. Build-time `--dart-define=ACP_CONFIG_PATH=...`.
2. Environment `ACP_CONFIG_PATH`, or `IANVS_ACP_CONFIG` when the first is unset.
3. `$XDG_CONFIG_HOME/ianvs-acp/settings.json`.
4. `$HOME/.config/ianvs-acp/settings.json`.

The startup workspace uses `--dart-define=ACP_WORKSPACE_CWD=...`, then environment
`ACP_WORKSPACE_CWD` or `IANVS_ACP_WORKSPACE_CWD`, then the current directory,
`PWD`, and `HOME` fallbacks. The config parser resolves the config file path to
an absolute path; session workspace roots are subsequently validated by Rust.
Leave an unused primary environment variable unset: an empty primary variable
masks its alias and falls through to the next source.

## Source and verification

- [Configuration parser and template resolution](../lib/config/acp_client_config.dart).
- [Atomic configuration and secret-reference persistence](../lib/config/acp_config_store.dart).
- [Settings form](../lib/ui/components/agent_config_dialog.dart) and
  [save/application lifecycle](../lib/app.dart).
- [Configuration regression tests](../test/config) and
  [settings save lifecycle tests](../test/ui/settings_save_lifecycle_test.dart).
