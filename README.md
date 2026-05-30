# ACP Client

A Flutter macOS desktop client for local Agent Client Protocol agents.

The app can launch stdio ACP agents, create and resume sessions, stream prompt
turns, display tool calls, render ACP plan and command updates, switch exposed
session modes/models, close active sessions, and log out when the agent
advertises those capabilities. It can also fork active sessions when the agent
supports `session/fork` and suggest advertised slash commands in the prompt
input. When an agent advertises authentication methods, the Agent menu can start
the agent-handled ACP `authenticate` flow.

## Configuration

By default the app reads:

```text
~/.config/ianvs-acp/settings.json
```

Example:

```json
{
  "default_agent_server": "Codex",
  "agent_servers": {
    "Codex": {
      "type": "custom",
      "command": "/opt/homebrew/bin/npx",
      "args": ["@zed-industries/codex-acp"]
    }
  },
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
  ]
}
```

Remote MCP servers can use `type: "http"` or `"sse"` with `url` and optional
`headers`; headers may be either an object or a `name`/`value` list. ACP
transport MCP servers use `type: "acp"` with an `id` provided by the component
that owns the MCP server.

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
