# ACP Client

A Flutter macOS desktop client for local Agent Client Protocol agents.

The app can launch stdio ACP agents, create and resume sessions, stream prompt
turns, display tool calls, render ACP plan and command updates, switch exposed
session modes/models, close active sessions, and log out when the agent
advertises those capabilities. It can also pass configured additional
directories to agents that advertise ACP `additionalDirectories`, fork active
sessions when the agent supports `session/fork`, and suggest advertised slash
commands in the prompt input. When an agent advertises authentication methods,
the Agent menu can start the agent-handled ACP `authenticate` flow. The same
menu includes Protocol Coverage, which reviews implemented ACP areas against the
official docs and points each area to its visible configuration and interaction
surface.

Starting a new session prompts for the session working directory and offers
local directory path completions while typing.

## Memory

The repo includes a local Rust `memory-core` daemon for four reviewed memory
kinds: user preferences, project rules, architecture decisions, and session
summaries. Memory is local-first and defaults off in the Flutter app until a
daemon endpoint is configured.

To enable prompt injection, set `memory.enabled=true`, provide
`memory.daemon_base_url`, and expose the bearer token through
`memory.daemon_token_env` (default: `MEMORY_DAEMON_TOKEN`). When those are
present, Flutter queries the daemon search API and adds returned memories as
background context before the normal ACP `session/prompt`; the daemon does not
proxy ACP traffic.

The daemon owns storage, search, audit history, local embedding support,
OpenAI-compatible embedding calls, and its stdio MCP bridge. The current MCP
bridge exposes callable `memory.search`, `memory.list`, and `memory.remember`
tools. Review and explorer UI surfaces are present, with destructive or
approval actions disabled until a backend callback is connected.

## Configuration

Use `Agents` -> `Agent Configuration` to manage the saved configuration:
agent servers, the default agent, MCP servers, additional directories,
filesystem/terminal provider switches, permission trust rules, the review
agent, and memory settings. The app persists those GUI choices to:

```text
~/.config/ianvs-acp/settings.json
```

On startup, the app can detect missing local ACP agents and ask whether to add
them to `agent_servers`. The first built-in detector covers Codex through a
local `npx` command running `@zed-industries/codex-acp`.

Saved shape example for automation and debugging:

```json
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "cwd": "/Users/example/project",
      "args": ["@zed-industries/codex-acp"]
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
      ],
      "env": []
    }
  ],
  "client_providers": {
    "permissions": {
      "review_agent": {
        "mcp_server": {
          "name": "permission-reviewer",
          "command": "/opt/homebrew/bin/npx",
          "args": ["-y", "@example/permission-reviewer-mcp"],
          "env": []
        },
        "tool_name": "review_permission",
        "model": "gpt-5-mini"
      }
    }
  }
}
```

Remote MCP servers can use `type: "http"` or `"sse"` with `url` and optional
`headers`; headers may be either an object or a `name`/`value` list. ACP
transport MCP servers use `type: "acp"` with an `id` provided by the component
that owns the MCP server.

Stdio `agent_servers` can set `cwd` to choose the working directory used when
launching the agent process. The aliases `working_directory` and
`workingDirectory` are also accepted.

`additional_directories` may list extra absolute workspace roots. They are sent
only to agents that advertise `sessionCapabilities.additionalDirectories`, and
filesystem/terminal provider jail checks treat those roots as part of the
session workspace.

`client_providers.permissions.review_agent` can point at a sidecar MCP server
used by the prompt composer’s `自动审查` policy. If no review agent is configured,
`自动审查` starts a sidecar session with the same active ACP agent and passes the
current model. An individual `agent_servers.<name>.review_agent.model` can
override the sidecar review model for that agent. The app sends command
execution context, local workspace/risk analysis, and the selected review model
to the reviewer, records the review opinion, and auto-applies allow/deny
decisions returned by that sidecar. If the sidecar cannot decide or fails, the
request remains available for manual approval.

Supported environment overrides:

- `ACP_CONFIG_PATH`
- `IANVS_ACP_CONFIG`
- `ACP_WORKSPACE_CWD`
- `IANVS_ACP_WORKSPACE_CWD`
- `XDG_CONFIG_HOME`

## Development

```sh
flutter analyze
flutter test
flutter build macos --release
```

The ACP integration is hidden behind `AcpAgentClient`, so widget and state tests
use `FakeAgentClient` instead of launching a real agent.
