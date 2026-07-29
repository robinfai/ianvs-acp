# Non-Blocking Manual Follow-Ups

Date: 2026-05-31

This document keeps product, security, and environment-dependent work visible
without treating those items as release blockers for the current ACP client
implementation. Each item records the strongest automated acceptance that exists
today, plus the manual decision or validation still needed before implementation.

## Acceptance Policy

- Every item must explain why it is non-blocking.
- Every item must list automated acceptance evidence, or explicitly say why no
  useful automation exists before a product/security decision is made.
- Referenced source, test, and documentation paths must exist.
- When an item becomes implementation-ready, add or update automated tests before
  removing it from this list.

## Checklist

### local-memory-engine

Status: real local daemon validation, extraction-quality validation, and UX
policy refinement needed.

Non-blocking because: the Rust daemon, storage/search/review APIs, callable MCP
search/list/remember bridge, Flutter config, prompt middleware, Memory
Review/Explorer UI, ACP sidecar extraction, OpenAI-compatible LLM extraction,
and pending-candidate posting are implemented behind local-first settings.
Memory now defaults off in the app. When enabled, Flutter starts an app-owned
`memory-core` daemon on a dynamic local port, uses an internal token, and stops
that child process when Memory is disabled or the app exits. Daemon
search/extraction timeouts are non-fatal. Memory Explorer now has real active
memory and pending-candidate loading, and pending candidates can be approved,
edited before approval, or rejected. Candidate handling defaults to
high-confidence auto-approval, while review-band stable memories
(`session_summary/session`, `user_preference/global`, and repo/workspace project
rules or architecture decisions) are auto-approved so people mainly review
below-threshold or unknown candidates after a run. The post-turn auto-approval
pass only touches `pending` candidate rows, leaving already approved or rejected
history as read-only review context instead of retrying it. Review-band stable
approvals do not automatically enter the pinned profile layer. The daemon list APIs support
workspace/repo/agent/session/kind filters plus pagination, and prompt injection
records keep injected memory ids and a text hash without storing the raw
prompt. Candidate creation skips same-scope duplicates that already exist as
active memory or pending candidates, writes `candidate.skip_duplicate` audit
events, auto-supersedes high-confidence same-topic corrections through the
change request path, and keeps repeated or clearly updated extractor/MCP output
out of the human review queue.
Main ACP sessions receive the app-owned daemon's stdio MCP bridge for
memory search/list/remember/update/forget tools, while sidecar extraction
sessions skip that bridge. Search responses include retrieval diagnostics for
lexical/vector/entity/scope/feedback/reinforcement scoring and `semanticHit`.
Returned memories with lexical, entity, or vector hits are recorded as access
events, while pinned-only profile injections stay audited but do not reinforce
access counts. Explicit helpful/not-relevant/stale feedback can adjust
search-time ranking, stable memories marked helpful are promoted into the small
profile layer, and stable memories with three successful retrievals and no
negative feedback are promoted automatically; those successful retrievals must
have a lexical, entity, or vector hit. Pinned memories marked not-relevant are
removed from that layer, repeated not-relevant feedback with no helpful
correction disables the memory without physically deleting it, stale memories
are disabled and stop participating in retrieval, recent semantic access gives a
small recency boost, long-unused
memories receive a low-impact `decayScore` while staying searchable, and Audit
log cards show compact retrieval diagnostics plus readable automatic
layer-change and disable reasons. The chat
timeline shows a per-turn `Memory used` panel for
injected memories, including kind/scope/score/text and direct helpful,
not-relevant, or stale feedback actions. Memory Explorer exposes the same
feedback actions on active memory cards for post-run review, so people can
correct memory quality without waiting for that memory to be retrieved again.
Memory items support optional
observed/valid-from/valid-until/
supersedes metadata, and search defaults to the current time while still
allowing an explicit reference time for historical lookup. Reviewed or
high-confidence automatic `supersede` change requests create a replacement
memory, set `supersedes_memory_id`, and mark the old active memory with
`valid_until` instead of deleting it. Memory items also
support lightweight entities/tags stored in `memory_entities`; extracted
candidates can carry entities, and approved candidates index those entities for
normalized entity matching during search. Memory items can also be marked
`pinned`, and high-confidence stable candidates such as global user preferences
plus workspace/repo project rules and architecture decisions are auto-pinned on
approval so they remain available as a small profile layer even when the next
query has no lexical/vector/entity overlap. Repeated successful retrieval can
also promote the same stable kinds
into this layer when no not-relevant/stale feedback exists; pinned-only returns
without lexical/vector/entity overlap do not count toward that promotion.
Prompt context now separates up to 4 pinned memories into
`<profile_memory>` before ordinary `<retrieved_memory>` results and balances
that small budget across profile blocks before filling remaining slots by rank,
while search balances pinned profile blocks before applying the response limit
when one block would otherwise crowd another block out, so durable
identity/preferences/project rules are stable without flooding the turn. When
Memory is enabled but no old memory matches the current turn, Flutter still
prepends a small capability notice so the main agent knows durable memory can be
captured after the turn instead of telling the user that cross-session memory is
unavailable. Audit diagnostics label these retrievals as `pinned`, and feedback-driven
`memory.promote` / `memory.unpin` / `memory.expire` events show when that layer
or a stale memory changes. Explicit user `记住`/`remember` prompts, clear
preferred-name patterns such as `以后叫我 ...` / `call me ...`, direct
self-introductions such as `我叫 ...` / `my name is ...`, and clear durable
preference statements such as `我偏好中文回复` / `请始终用中文回复` /
`I prefer concise answers` / `Please reply in Chinese from now on` now have a
local fallback candidate path when the configured extractor returns no
candidates or fails. Clear project directives such as `本项目禁止使用 nc` /
`以后这个项目不要用 nc` / `In this repo, never use netcat` and explicit
architecture decisions such as `架构决定...` also use local fallback into
repo-scoped project rule or architecture-decision candidates. Fallback candidates are merged with extractor
output, same preferred-name/name/preference duplicates and same-scope project
rule or architecture-decision duplicates with a shared rule entity stay as one
candidate, and the fallback can raise confidence or add entities when the
extractor caught the same fact cautiously. Obvious API keys, tokens, passwords,
and private keys are still skipped. Extractor output
and fallback candidates are normalized before review: one-off explicit remembers
and preferred-name/name/preference/project overrides are not written, while
current-session remembers, name overrides, preference overrides, and project
directives are kept as session summaries instead of global/repo long-term
memories. Local fallback also recognizes project passphrases and verification phrases as
repo-scoped project rules, extracts their short identifiers, and backend search
adds short CJK lexical tokens so Chinese question-style recall does not depend
only on embedding similarity.
Clear durable preferences, repo directives, and architecture decisions from
local fallback use high-confidence scores so approved user intent and hard
project context can enter the pinned profile layer without waiting for feedback.
Maintenance also uses entity overlap
as a local prefilter before creating review-band suggestions or calling the
configured LLM extractor, and successful high-confidence candidate auto-approval,
daemon auto-applied change requests, or a turn that retrieved memory can trigger
one bounded low-cost maintenance pass after a turn. Conservative idle
maintenance is configurable and enabled by default; quiet successful turns can
trigger the same bounded pass only after the configured turn interval and while
pending reviews stay under the configured limit. Already approved or rejected
candidate history does not block that idle pass. Memory Explorer also loads
pending/approved/rejected candidates and pending/reviewed change requests from
the daemon, shows candidate/change-request source for post-run inspection,
supports approve/edit/reject for pending requests plus bulk
approve/reject over the currently visible filtered pending items, keeps reviewed
items visible as read-only history, lets users edit or disable active memory after
automatic approval, see whether an active memory came from manual input,
extractor, MCP, or maintenance, restore disabled memory after post-run review,
refreshes memory and audit views after review, filter All memory/Candidates/Change requests/Audit
locally through the Explorer search box, narrow Audit log by retrieval, memory
change, candidate, change request, maintenance, or clear event type, submit helpful/not-relevant/stale
feedback for active memory, and still
exposes a manual All memory `Organize`
action for on-demand scoped maintenance over the latest configured batch. Change
request loading uses the current workspace/repo/agent/session scope while still
including broader workspace/repo requests, and cards show source so users can
distinguish MCP requests from
maintenance suggestions while reviewing. Manual
or automatic duplicate change requests with the same scoped action, targets, and
proposed change are reused and audited as `change_request.skip_duplicate`, so
repeated maintenance/MCP runs do not create extra review cards. Manual
disables keep the record visible and auditable while removing it from retrieval
and write `memory.disable` audit events; restores write `memory.restore` audit events.
Automatic approvals preserve their source in
audit: post-turn extraction uses `extractor`, MCP `memory.remember` uses `mcp`,
and maintenance auto-approval uses `maintenance` on both the approval event and
the resulting memory change events; approved candidates keep their source on the
resulting active memory. When
pending reviews increase or a turn auto-applies memory changes, the app shows a
bottom review prompt with a direct Memory Explorer action;
`memory.review.auto_open = "never"` disables that prompt for quieter workflows. High-confidence
maintenance requests can be auto-applied through the same change request path
when the configured maintenance mode and manual-only action list allow it, while
destructive requests remain manual. Maintenance also auto-expires active memory
whose `validUntil` timestamp has already passed, keeping the change auditable
without requiring the user to find stale records by hand. Clear same-topic
profile conflicts, such as an older and newer preferred-name memory, are
auto-superseded during maintenance so the newer active memory links back to the
old record instead of creating an ambiguous merge. The maintenance pass only calls the
configured LLM extractor after local text-similarity or entity-overlap
prefiltering finds nearby active memories, and sends memory candidates rather
than complete transcripts/prompts. LLM maintenance proposals cannot retarget
memory outside the prefiltered pair; invalid target ids fall back to the local
proposal. Extractor configuration also supports
global/workspace/repo memory instructions, which are included in both ACP
sidecar and OpenAI-compatible extraction prompts before candidate review; matched
instruction scopes are preserved on candidates for review. Clear data now soft-clears the selected
scope, including the current session, and rejects pending reviews in that scope;
the daemon also has a confirmation-protected destroy endpoint for
support/development use.

Automated acceptance:

- `cargo test --manifest-path memory-core/Cargo.toml` verifies the daemon
  schema, manual CRUD, manual secret redaction, candidate review, change request
  create/list/approve/reject behavior, soft delete and restore audit behavior, manual maintenance
  merge behavior, scoped clear behavior, destroy confirmation behavior, hybrid
  vector/keyword scope-filtered search behavior including session isolation,
  same-session-id isolation across agents, older relevant matches, full-scope
  memory/candidate list filtering and pagination, candidate duplicate skipping,
  high-confidence candidate auto-supersede,
  fixed memory eval cases for bilingual recall, repo/session isolation, pinned
  profile recall, entity alias recall, current/historical temporal ranking, and
  maintenance duplicate-merge/expiry regressions,
  search injection id/hash
  records, retrieval diagnostics including pinned-only non-semantic hits,
  semantic access recording, feedback-based ranking
  demotion, search-time recency decay, reference-time temporal demotion,
  supersede-chain approval, explicit and candidate-derived entity/tag matching,
  pinned profile-layer retrieval, high-confidence candidate auto-pinning,
  entity-overlap maintenance prefiltering, profile-conflict maintenance
  auto-supersede, expired active-memory auto-expiry,
  post-turn automatic maintenance,
  search formatting, embedding provider paths, vector
  rebuild/index rows, daemon API routes, and MCP stdio tool listing/calls including
  `memory.remember` high-confidence and review-band stable-memory
  auto-approval without auto-pinning review-band stable memory, `memory.update`
  high-confidence non-destructive auto-approval,
  forgiving MCP review-policy and maintenance mode parsing, automatic approval
  actor attribution, and `memory.forget` remaining pending for destructive review.
- `test/memory` verifies Flutter memory config, daemon client search metadata,
  feedback posting, candidate/change-request/maintenance API behavior,
  forgiving review and maintenance mode parsing so hand-written config keeps
  automatic defaults,
  memory MCP review-policy environment wiring,
  prompt context formatting,
  explicit remember and preferred-name fallback candidate generation,
  extractor/fallback candidate lifecycle normalization and merging, and secret
  skipping,
  review-band stable-memory auto-approval while leaving unknown review-band
  candidates pending,
  daemon HTTP search context building and timeout handling, prompt middleware,
  ACP sidecar extraction, and OpenAI-compatible LLM extraction.
- `test/config/acp_client_config_test.dart` verifies persisted memory config
  parsing with the rest of the user settings.
- `test/config/acp_config_store_test.dart` verifies memory config serialization
  preserves future nested fields while dropping deprecated daemon endpoint/token
  fields.
- `test/state/chat_controller_test.dart` verifies prompt sending keeps working
  when memory middleware is present or fails, records used memories on the user
  turn, and delegates memory feedback.
- `test/ui/memory_review_panel_test.dart` and
  `test/ui/memory_explorer_page_test.dart` verify the review and explorer UI
  surfaces, including pending-candidate approve/edit/reject wiring, visible
  pending candidate/change-request bulk actions, pending change request approval,
  reviewed candidate/change-request history,
  active-memory edit/disable/feedback actions, disabled-memory read-only history,
  the All memory Organize action summary, session clear selection, and scoped clear
  confirmation.
- `test/ui/agent_config_dialog_test.dart` and
  `test/ui/acp_client_app_test.dart` verify memory settings are visible,
  editable, saved, and passed from app config into the shell, including the
  memory approval mode, review prompt setting,
  maintenance mode/threshold/batch/action settings, and without exposing daemon
  endpoint/token fields.
- `test/ui/app_shell_test.dart` verifies pending memory reviews surface as a
  bottom prompt with a direct Memory Explorer action, and that `auto_open =
  never` suppresses the prompt.
- `test/ui/chat_timeline_test.dart` verifies the per-turn `Memory used` panel
  and feedback actions.

Manual decision:

- Validate a real macOS app session with the local `memory-core` daemon and a
  real ACP sidecar or OpenAI-compatible LLM extractor, including extraction
  quality, custom memory instruction behavior, approval flow, prompt injection,
  and search relevance.
- Decide final product policy for daemon bundling, data directory visibility,
  retention/audit wording, and whether memory should stay opt-in for all agents
  or auto-enable only for trusted local agents.

### remote-transports

Status: remote interoperability and HTTP/2 hardening needed.

Non-blocking because: local stdio remains supported, WebSocket remote agents can
be configured with `agent_servers[].type = "websocket"` plus a `ws` or `wss`
URL, and draft Streamable HTTP/SSE agents can be configured with
`agent_servers[].type = "http"` or `"sse"` plus an `http` or `https` URL. The
new HTTP transport covers long-lived connection/session SSE streams, POST/202
response routing, `Acp-Connection-Id`, `Acp-Session-Id`, headers, and cookies,
`Acp-Protocol-Version`, one-shot session routing for server-request responses,
plus best-effort `DELETE` teardown, but the draft profile still needs HTTP/2
enforcement and real-agent interoperability testing.

Automated acceptance:

- `test/config/acp_client_config_test.dart` verifies WebSocket and Streamable
  HTTP/SSE agent server config parsing plus invalid config rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies the client connects to a
  local WebSocket ACP agent, forwards custom headers, initializes, creates a
  session, receives session updates, and completes a prompt turn. It also
  verifies a local Streamable HTTP/SSE ACP agent path, including headers,
  cookies, connection/session stream routing, forked session streams, prompt
  completion, and best-effort `DELETE` teardown.
- `lib/acp/web_socket_acp_transport.dart` implements the JSON-RPC
  `StreamChannel` adapter used by `dart_acp`.
- `lib/acp/streamable_http_acp_transport.dart` implements the draft HTTP/SSE
  `StreamChannel` adapter used by `dart_acp`.
- `test/acp/streamable_http_acp_transport_test.dart` verifies session-scoped
  server-request response headers are not reused after the response is sent.

Manual decision:

- Decide whether to enforce HTTP/2 at connection time before the RFD stabilizes,
  and whether WebSocket fallback should be preferred or user-selectable.
- Validate WebSocket and Streamable HTTP/SSE against real remote ACP agents that
  implement the draft endpoint.

### fs-terminal-providers

Status: policy refinement needed.

Non-blocking because: filesystem and terminal providers are now available only
when explicitly enabled through Agent Configuration, remain off by default, use
prompt-side permission approval, and record decisions in exportable bounded
in-process Permission History. Agent Configuration also covers additional
directories, explicit permission trust rules, and review-agent settings.
Trust rules and the runtime tool-call execution policy can auto-allow or
auto-deny matching requests. Terminal support emits lifecycle and output
snapshots into the timeline, but deliberately does not yet provide a persistent
live terminal panel.

Automated acceptance:

- `test/ui/capabilities_dialog_test.dart` verifies filesystem and terminal
  capability visibility.
- `test/config/acp_client_config_test.dart` verifies filesystem and terminal
  provider config parsing, permission trust rule parsing, and invalid config
  rejection.
- `test/acp/dart_acp_agent_client_test.dart` verifies configured filesystem
  capabilities are advertised and that approved read requests are served from a
  workspace-jailed provider. It also verifies configured terminal capabilities
  are advertised and that approved terminal requests emit created/exited/output
  lifecycle events.
- `test/state/chat_controller_test.dart` verifies terminal lifecycle updates for
  the same terminal id merge into one timeline status row, matching permission
  trust rules auto-resolve requests, and Permission History keeps a bounded
  in-process audit window.
- `test/ui/chat_timeline_test.dart` verifies terminal status output renders in
  the timeline.
- `test/ui/agent_config_dialog_test.dart` verifies Agent Configuration can show
  and edit filesystem, terminal, additional directory, permission trust rule,
  review agent, agent server, and MCP server config.
- `lib/acp/dart_acp_agent_client.dart` still defaults ACP filesystem and
  terminal capabilities to disabled unless the user opts in.

Manual decision:

- Decide whether filesystem and terminal provider defaults or warning copy need
  further hardening, and whether long-term audit retention is needed.
- Decide whether terminal support should grow beyond timeline snapshots into a
  live terminal panel with kill/release controls and richer cwd/environment
  visibility.

### spark-attachments

Status: manual integration validation needed.

Non-blocking because: small text attachments are embedded when the agent
advertises embedded context support, image attachments are embedded when the
agent advertises image prompt support, audio attachments are embedded when the
agent advertises audio prompt support, generic binary attachments are embedded
when embedded context is advertised, and unsupported or oversized attachments
are still forwarded as ACP resource links. A specific agent/model can still
decline, ignore, or reinterpret attachment context.

Automated acceptance:

- `test/ui/prompt_input_test.dart` verifies file attachments can be selected,
  removed, and sent without text.
- `test/state/chat_controller_test.dart` verifies attachments are forwarded as
  resource link content metadata.
- `test/acp/dart_acp_agent_client_test.dart` verifies text attachments become
  embedded resources when `embeddedContext` is advertised, image attachments
  become image content when `image` is advertised, audio attachments become
  audio content when `audio` is advertised, generic binary attachments become
  embedded resource blobs when `embeddedContext` is advertised, prompt-side
  `@file` mentions remain resource links when attachments are present, and all
  attachments fall back to resource links otherwise.
- `test/ui/chat_timeline_test.dart` verifies non-text/resource-link content
  renders in the timeline.

Manual validation:

- Run a real Spark-backed session and confirm whether embedded
  text/image/audio/binary attachments and file resource links are accepted,
  ignored, or rejected.
- Record any agent-specific limitations in user-facing docs if Spark behavior is
  intentionally narrower than ACP's representation.

### tool-permission-ui

Status: audit refinement needed.

Non-blocking because: tool calls are visible and grouped, permission requests
surface an in-app per-request approval card inside the prompt composer with
Allow Once, Deny, and Cancel actions, using agent-provided allow/deny labels
when they are more specific. The prompt composer also exposes `默认权限`,
`自动审查`, and `完全访问权限` execution modes. Handled requests are visible in
the Agents menu Permission History with JSON export of the newest bounded
in-process audit entries. Resolved entries record whether the decision came
from a manual action, trust rule, runtime policy, or system cancellation.
Explicit permission trust rules can auto-allow or auto-deny matching requests
and are editable through Agent Configuration.
Requests still fall back to `cancelled` when no UI listener is active, and
pending requests are system-cancelled when the permission stream closes or
session teardown completes through close/logout.

Automated acceptance:

- `test/ui/chat_timeline_test.dart` verifies tool calls render as compact,
  expandable cards and grouped cards.
- `test/acp/dart_acp_agent_client_test.dart` verifies agent permission requests
  receive a `cancelled` outcome when no interactive UI is listening, receive a
  selected allow option when approved through the interactive response path,
  close the permission request stream on client disposal, and are cancelled when
  session close/logout completes.
- `test/ui/prompt_input_test.dart` verifies the prompt-side permission approval
  card, execution-policy selector, and model selector.
- `test/ui/acp_client_app_test.dart` verifies prompt-side policy/model changes,
  approval back to the agent client, and the completed request in Permission
  History.
- `test/ui/permission_history_dialog_test.dart` verifies Permission History
  exports a JSON audit file payload with decision source metadata and disables
  export when no entries exist.
- `test/state/chat_controller_test.dart` verifies permission requests are
  recorded as pending, resolved to the selected decision, cancelled when a newer
  pending request supersedes them, system-cancelled when the permission stream
  closes, and trimmed to a bounded in-process audit window. It also verifies
  matching trust rules auto-resolve requests, default-permission policy keeps
  trusted requests manual, full-access policy auto-allows requests, and policy
  changes resolve the current pending request.
- `test/config/acp_client_config_test.dart` verifies permission trust rule
  parsing and invalid config rejection.
- `test/ui/app_shell_test.dart` verifies the Agents menu exposes Permission
  History when permission audit entries exist.

Manual decision:

- Decide whether to add request grouping, long-term persisted audit retention,
  or stronger streaming interruption behavior beyond the current per-request
  Allow Once/Deny/Cancel model and runtime execution policy selector.

### vendor-extension-workflows

Status: agent-specific product decision needed.

Non-blocking because: raw `_meta` capability data is visible and the Agents menu
now includes a generic Extension Request dialog for underscore-prefixed custom
JSON-RPC requests. A polished workflow for any single vendor extension should
wait until a real agent contract is known.

Automated acceptance:

- `test/acp/dart_acp_agent_client_test.dart` verifies custom extension requests
  are sent over the ACP client and return raw JSON results.
- `test/ui/extension_request_dialog_test.dart` verifies the dialog sends
  extension method/params JSON and rejects non-object params JSON.
- `test/ui/acp_client_app_test.dart` verifies the app opens the Extension
  Request dialog from the Agents menu.
- `test/ui/app_shell_test.dart` verifies the Agents menu exposes Extension
  Request when available.

Manual decision:

- Decide which advertised `_meta` contracts deserve first-class controls,
  labels, result rendering, or notification flows beyond the generic JSON
  request dialog.

### prompt-content-gates

Status: future content-source decision needed.

Non-blocking because: text, file resource-link prompts, embedded text-file
prompts, image prompts, audio prompts, and generic binary embedded resource
prompts work. The file attachment UI now marks selected files with the same
capability-aware send mode used by the ACP client: Image, Audio, Embed, or Link.
Future generated or non-file prompt content should still be gated by advertised
agent capabilities and picker support.

Automated acceptance:

- `test/acp/prompt_attachment_test.dart` verifies prompt attachment mode
  classification for media, embedded resources, and resource-link fallbacks.
- `test/ui/prompt_input_test.dart` covers the current file attachment UX and
  verifies attachment chips display capability-aware send modes.
- `test/state/chat_controller_test.dart` verifies prompt attachment forwarding.
- `test/acp/dart_acp_agent_client_test.dart` verifies embedded text, image,
  audio, and generic binary attachment capability gating.
- `test/ui/chat_timeline_test.dart` verifies output content block rendering.

Manual decision:

- Decide whether to add generated/non-file prompt content sources beyond the
  current file attachment picker, and how to disable or explain unavailable
  types when the agent does not advertise support.

### acp-registry

Status: stable official feature, product integration not started.

Non-blocking because: local Codex ACP discovery can add a missing
`@zed-industries/codex-acp` entry to the saved user config, agent discovery can
still be configured explicitly through Agent Configuration, the active config is
editable and inspectable in the app, and this protocol-compatibility pass
intentionally avoids ACP Registry browsing, importing, or installing flows until
product decisions are made.

Automated acceptance:

- `test/config/acp_client_config_test.dart` verifies explicit local and remote
  agent server config parsing, including MCP and additional workspace settings.
- `test/config/acp_agent_discovery_test.dart` verifies local Codex ACP discovery
  and saved config writes for selected discovered agents.
- `test/ui/agent_config_dialog_test.dart` verifies the active explicit config is
  editable and inspectable in Agent Configuration.
- `test/ui/acp_client_app_test.dart` verifies startup discovery prompts and
  adding selected agents into the active app config.
- `test/ui/protocol_feature_review_dialog_test.dart` verifies the Protocol
  Coverage GUI identifies ACP Registry as a follow-up while still mapping the
  explicit config flow to Agent Configuration.
- `test/ui/acp_client_app_test.dart` verifies the Protocol Coverage dialog is
  reachable from the Agents menu.
- `README.md` documents the supported explicit config shape.

Manual decision:

- Decide whether Registry support should import entries into `settings.json`,
  keep a separate registry cache, or launch agents directly from discovered
  metadata.

### desktop-manual-qa

Status: environment validation needed.

Non-blocking because: automated widget tests and release builds pass; direct
desktop interaction validation was limited by local accessibility/window capture
failures.

Automated acceptance:

- `flutter analyze`
- `flutter test`
- `flutter build macos --release`

Manual validation:

- Once local window capture works, verify text-field focus, attachment picker,
  real agent connection, resume selection, logout, and close-session flows in
  the built macOS app.
