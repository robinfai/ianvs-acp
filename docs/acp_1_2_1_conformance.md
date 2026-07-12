# ACP 1.2.1 conformance

This repository tracks `@agentclientprotocol/sdk` **1.2.1**, source commit
`76da0322243549ee6122ddf62cb1392537991c43`. ACP protocol version remains `1`;
non-breaking additions are negotiated through capabilities.

The authoritative local marker is
`third_party/dart_acp/lib/src/schema_version.dart`.

## Stable request and notification coverage

| Direction | Methods | Implementation |
| --- | --- | --- |
| Client → Agent | `initialize`, `authenticate`, `logout` | `AcpClient` / `SessionManager` |
| Client → Agent | `session/new`, `session/load`, `session/list`, `session/delete`, `session/resume`, `session/close`, `session/prompt`, `session/set_mode`, `session/set_config_option` | Typed `AcpClient` methods |
| Client → Agent notifications | `session/cancel`, `$/cancel_request` | Typed cancellation methods |
| Agent → Client | `fs/read_text_file`, `fs/write_text_file` | Workspace-jailed filesystem provider |
| Agent → Client | `session/request_permission` | Interactive permission provider and structured ACP outcome |
| Agent → Client | `terminal/create`, `terminal/output`, `terminal/wait_for_exit`, `terminal/kill`, `terminal/release` | Terminal provider using ACP 1.2.1 response fields and UTF-8 byte-limit truncation |
| Agent → Client notification | `session/update` | Typed update stream with forward-compatible unknown fallback |

`session/fork` is also implemented, but remains marked unstable by SDK 1.2.1.

## Session updates

The client consumes all SDK 1.2.1 variants:

- user, agent, and thought content chunks, including `messageId`;
- tool call creation and partial updates;
- stable complete plan snapshots;
- unstable `plan_update` and `plan_removed` without discarding new plan variants;
- available command, current mode, config option, session info, and usage updates;
- unknown future update variants as raw payloads.

Prompt responses preserve stop reason, cumulative end-turn token usage, and
top-level `_meta`.

## Session configuration options

- `select` and `boolean` wire values are preserved with their native types.
- Boolean writes include the required `type: "boolean"` discriminator.
- `category` is distinct from grouped select choices.
- grouped select options are flattened for current Flutter controls while
  preserving `groupId` and `groupName` for display and round-trip encoding.
- the client advertises `session.configOptions.boolean: {}`.
- unsupported future config option types are retained only through raw protocol
  access and are not rendered as editable controls.

## Content and tool results

Text, image, audio, resource-link, and embedded text/blob resources preserve
ACP annotations and `_meta`. Resource links always emit the required `name`.
Unknown future content blocks remain round-trippable.

Tool calls preserve raw input/output, locations, `_meta`, all current tool
kinds (including `switch_mode`), and raw tool-call content collections.

## SDK 1.2.1 unstable surfaces

The wire layer exposes:

- `providers/list`, `providers/set`, and `providers/disable`;
- `nes/start`, `nes/suggest`, `nes/close`, document lifecycle notifications,
  and NES accept/reject notifications;
- provider-driven `elicitation/create` handling and
  `elicitation/complete` notifications;
- provider-driven `mcp/connect`, `mcp/message`, and `mcp/disconnect` handling;
- arbitrary JSON request results via `sendRawValue`.

These capabilities are not advertised unless the embedding client supplies the
corresponding handler. In particular, ACP-transport MCP servers are forwarded
only when all MCP-over-ACP handlers are installed. This prevents an agent from
calling a method the Flutter application cannot fulfill.

## Codex adapter

The default adapter is `@agentclientprotocol/codex-acp`, which uses the current
Codex App Server and `model/list`. Exact legacy configurations using
`@zed-industries/codex-acp` are offered an in-place migration that preserves
the configured name, environment, and default-agent selection.

The E2E harness prints all session config options. It has been verified against
Codex ACP 1.1.2 / Codex 0.144.1 with GPT-5.6 model variants, `max` and `ultra`
reasoning effort, and boolean Fast mode.

## Verification

Run:

```sh
flutter analyze
flutter test
dart run tool/e2e_codex_acp.dart
```

The final E2E command requires a locally authenticated Codex installation.
