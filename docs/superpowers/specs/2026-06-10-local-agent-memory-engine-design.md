# 本地 Agent Memory Engine 设计

日期：2026-06-10

## 背景

当前项目是 Flutter macOS Desktop ACP 客户端，已经直接实现并运行 ACP，不需要 Rust sidecar 代理 ACP。新的目标是在本地增加一个可审计、默认开启、用户可审批的长期记忆系统，用于四类 memory：

- `user_preference`：用户偏好，例如回复语言、解释风格、工具偏好。
- `project_rule`：项目规则，例如禁用命令、包管理器、目录约定、代码风格。
- `architecture_decision`：架构决策，例如 Flutter 负责 ACP，Rust 只负责 memory。
- `session_summary`：会话摘要，例如当前目标、已完成步骤、待继续上下文。

不做 codebase RAG、文档 RAG、图谱记忆、多模态记忆。Rust 不代理 ACP，不启动或管理 ACP agent。

## 已确认选择

- 设计范围覆盖完整 P0-P6；实施计划再分阶段拆。
- 采用 Rust memory-core 作为 memory 事实来源，Flutter 负责 ACP 编排和审批 UI。
- 默认开启完整闭环，但任何长期写入都必须经过用户 Review approve。
- embedding 默认本地优先，推荐 `intfloat/multilingual-e5-small`，模型懒下载到 app data；测试使用 mock embedder。
- extractor 支持 `acp-sidecar` 和 OpenAI-compatible API。ACP 模式使用单独 sidecar ACP session，不复用当前用户 session。
- `extractor.agent` 指定 ACP agent，`extractor.model` 指定该 extractor sidecar 的模型或 config option 值。
- Memory Review UI 同时提供右侧 panel 和独立 Memory Explorer。
- MCP `memory.update` / `memory.forget` 使用完整 change request，不直接绕过审计修改 memory；高置信 `memory.update` 可按 Review 策略自动批准，`memory.forget` 始终等待人工核查。
- 清理支持当前 session / repo / workspace / 全部，默认软删除；高级入口支持彻底清空数据库。

## 总体架构

系统分三层：

1. Flutter ACP Client
   - 启动并管理 `memory-core --mode=daemon`。
   - 生成 `MEMORY_DAEMON_TOKEN`，通过 env 传给 daemon 和 MCP bridge。
   - 每轮 prompt 前调用 memory search，构造独立 memory context block 注入 ACP prompt。
   - turn 结束后收集 transcript，并通过单独 ACP sidecar extractor session 生成候选。
   - 展示 Review panel 和 Memory Explorer，让用户 approve、edit、reject、清理 memory。

2. Rust memory-core daemon
   - 只负责 memory，不代理 ACP。
   - 提供本地 HTTP API、SQLite 事实库、sqlite-vec 检索索引、embedding、policy、redaction、audit log。
   - 执行 candidate/change request 的审批状态机。
   - 只有 approve 后才写入或修改长期 memory。

3. Rust MCP stdio bridge
   - `--mode=mcp-stdio` 读取 env token，通过 HTTP 调用 daemon。
   - stdout 只写 MCP JSON-RPC，日志只写 stderr。
   - MCP 工具读 memory 可以直接返回；写入和非破坏性更新可按 Review 策略自动批准，低置信或删除类操作保留 pending review。

主流程：

```text
用户 prompt
→ Flutter 调用 /v1/memory/search
→ Flutter 注入 agent_memory_context text block
→ ACP agent 正常处理 prompt
→ turn 结束
→ Flutter 用 sidecar ACP extractor 生成候选
→ daemon 做 redaction、policy、dedupe、conflict/supersede
→ pending candidates / change requests
→ Review UI approve/edit/reject
→ daemon 写 memory_items、vec_memory_items、audit log
→ 后续 prompt 可检索
```

错误处理：

- daemon 未启动或 search 失败：不中断 prompt，跳过 memory 注入并显示状态。
- extractor 失败：不中断对话，显示候选生成失败，可稍后重试。
- approve 写入失败：候选保留 pending，UI 显示错误。
- memory 与当前 prompt 冲突：当前 prompt 永远优先。

## Rust 项目结构

新增 `memory-core/`：

```text
memory-core/
  Cargo.toml
  src/
    main.rs
    config.rs
    app_state.rs
    error.rs
    http/
      mod.rs
      routes_health.rs
      routes_memory.rs
      routes_candidates.rs
      routes_change_requests.rs
      routes_clear.rs
    mcp/
      mod.rs
      stdio_server.rs
      tools.rs
      daemon_client.rs
    memory/
      mod.rs
      engine.rs
      types.rs
      scope.rs
      policy.rs
      redactor.rs
      formatter.rs
      ranker.rs
    db/
      mod.rs
      sqlite.rs
      migrations.rs
      schema.sql
    vector/
      mod.rs
      sqlite_vec_store.rs
    embedding/
      mod.rs
      embedder.rs
      fastembed_local.rs
      openai_compatible.rs
      mock_embedder.rs
    llm/
      mod.rs
      extractor_client.rs
      openai_compatible.rs
      prompts.rs
```

Flutter 不直接写 SQLite，只通过 HTTP API 调 daemon。

## Daemon 启动

命令：

```sh
memory-core --mode=daemon --host=127.0.0.1 --port=0 --data-dir=/path/to/app-data
```

行为：

- 创建 data dir。
- 打开 `<data-dir>/memory.sqlite`。
- 启用 WAL。
- 加载 sqlite-vec extension。
- 执行 migrations。
- 绑定 `127.0.0.1`。
- `port=0` 时由系统分配端口。
- stdout 输出一行 ready JSON：

```json
{"type":"ready","port":43129}
```

daemon 日志只能写 stderr。HTTP API token 从 `MEMORY_DAEMON_TOKEN` 环境变量读取。

## 数据模型

### MemoryKind

序列化为 snake case：

- `user_preference`
- `project_rule`
- `architecture_decision`
- `session_summary`

### MemoryScope

```text
user_id: String
workspace_id: Option<String>
repo_id: Option<String>
agent_id: Option<String>
session_id: Option<String>
```

默认 scope：

- `user_preference`：`global`
- `project_rule`：`repo`
- `architecture_decision`：`repo` 或 `workspace`
- `session_summary`：`session`

Review UI 允许用户逐条修改 scope。

### SQLite 表

`memory_items` 是事实来源，只保存已审批 memory。`status=active` 才参与检索，`disabled` 和 `deleted` 不参与检索。`pinned=true` 表示小型 profile/block 层：即使 query 没有词面、向量或实体命中，也会参与 search 排序和 prompt 注入，并在 diagnostics 里标记 `pinnedLayer`；如果只是因为 pinned 被注入而没有词面、向量或实体命中，diagnostics 同时标记 `semanticHit=false`。用户事后反馈和使用信号会调整这个层级：稳定的 `global/user_preference`、`repo/project_rule`、`repo/architecture_decision` 收到 `helpful` 后自动提升到 pinned；这些稳定记忆被成功语义检索 3 次且没有 `not_relevant`/`stale` 反馈时，也会自动提升到 pinned；已 pinned 记忆收到 `not_relevant` 后自动取消 pinned；同一记忆累计多次 `not_relevant` 且没有 `helpful` 修正时自动设为 `disabled`；记忆收到 `stale` 后自动设为 `disabled` 并记录过期时间，不再参与检索。

`memory_candidates` 只表示新增 memory 候选，来源包括 extractor 和 MCP `memory.remember`。Extractor 输出进入 review 前先归一化生命周期：一次性当前回答/本轮提示丢弃，本次会话/当前对话提示降为 `session_summary/session`。显式 `记住`/`remember`、清晰称呼偏好、直接自我介绍、清晰偏好表达、自然项目规则和架构决策兜底也走同一套归一化；项目验证短语、暗号、passphrase 会归为 `project_rule/repo`，并把短标识提取为 entity，便于后续检索和维护预筛。写入前会按 user/kind/scope/归一化文本检查同 scope 的 active memory、pending candidate 和同批候选；重复项只写 `candidate.skip_duplicate` 审计，不进入 pending 队列。Review 列表按 candidate 自身语义 scope 判断可见性：`global` 对同 user 可见，`workspace`/`repo` 在对应范围内跨 session 可见，`session` 只在当前 agent/session 可见，避免旧会话短期候选污染当前核查队列。高置信稳定候选如果明显更新同作用域同主题 active memory，会直接创建并批准 `supersede` change request，旧 memory 写入 `validUntil`，新 memory 写入 `supersedesMemoryId`，并记录 `candidate.auto_supersede` 审计。其余候选状态为 `pending`、`approved`、`rejected`。高置信稳定候选，例如 `global/user_preference`、`repo/project_rule`、`repo/architecture_decision`，批准后自动进入 pinned 层；低置信和 session summary 不自动 pinned。

新增 `memory_change_requests` 表，用于 update/delete/disable/restore 等需要审批的变更：

```sql
create table if not exists memory_change_requests (
  id text primary key,
  user_id text not null,
  workspace_id text,
  repo_id text,
  agent_id text,
  session_id text,
  action text not null,
  source text not null default 'user',
  target_memory_id text,
  target_memory_ids_json text,
  proposed_kind text,
  proposed_scope text,
  proposed_text text,
  reason text,
  confidence real,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);
```

创建 change request 前会按 user/workspace/repo/agent/session、action、目标 memory ids、proposed kind/scope/text 检查同作用域 pending request；重复请求复用已有记录并写 `change_request.skip_duplicate`，避免 maintenance 或 MCP 重复运行制造重复审核。Change request 保存 source，区分 `user`、`mcp`、`maintenance`、`extractor`、`system`。

`memory_audit_log` 记录 candidate create/skip duplicate/auto supersede/approve/reject、change request create/skip duplicate/update/approve/reject、maintenance run/auto approve、memory create/update/delete/disable/restore/expire/merge/summarize/supersede/clear。自动批准必须保留来源 actor：post-turn extractor 自动批准写 `extractor`，MCP `memory.remember` 自动批准写 `mcp`，maintenance 自动批准 change request 和由它触发的 memory change 都写 `maintenance`，用户手动审批写 `user`。

`prompt_injections` 记录本轮注入的 memory id 和注入文本 hash，不保存完整 prompt。

`vec_memory_items` 是 sqlite-vec 虚拟表，只作为检索索引。SQLite `memory_items` 是事实来源。更新 text 时重新 embedding，软删除或禁用时删除向量索引对应行。

embedding 维度由模型配置决定，不写死 768。

## Embedding

provider 支持：

- `fastembed-local`
- `openai-compatible`
- `mock`

默认：

```json
{
  "provider": "fastembed-local",
  "model": "intfloat/multilingual-e5-small",
  "variant": "onnx-qint8",
  "dimension": 384,
  "download_policy": "lazy"
}
```

`intfloat/multilingual-e5-small` 适合中英混合 memory。模型懒下载到 app data，不随 App 首包打包。测试默认使用 mock embedder。

## Extractor

extractor 只生成候选，不直接写长期 memory。

provider 支持：

- `acp-sidecar`
- `openai-compatible`
- `rules`
- `disabled`

默认使用 `acp-sidecar`，失败时 fallback 到 `rules`。ACP 模式由 Flutter 编排，使用单独 sidecar session，不污染当前用户 session。OpenAI-compatible 和 rules 模式由 daemon 执行；Flutter 把 transcript 发给 daemon，daemon 负责 redaction、调用 extractor、policy 和持久化 pending candidate。Flutter 本地还会在 extractor 空结果或失败时补显式记忆、清晰称呼偏好、自我介绍、清晰偏好表达、项目规则和架构决策兜底候选，并与 extractor 输出合并去重，避免用户明确表达“记住我/我叫/我偏好/本项目禁止...”后因为 extractor 漏掉而只停留在当前会话。

配置：

```json
{
  "extractor": {
    "provider": "acp-sidecar",
    "agent": "Codex",
    "model": "gpt-5-mini",
    "fallback_provider": "rules",
    "global_instructions": "Remember durable user preferences only.",
    "workspace_instructions": "Ignore one-off workspace chatter.",
    "repo_instructions": "Prioritize project rules and architecture decisions."
  }
}
```

OpenAI-compatible extractor 使用 `llm` 配置段：

```json
{
  "llm": {
    "provider": "openai-compatible",
    "base_url": "http://127.0.0.1:11434/v1",
    "model": "qwen2.5:7b",
    "api_key_env": "OLLAMA_API_KEY"
  }
}
```

API key 只通过 env 名称引用，不写入配置文件。

Flutter 启动 daemon 时把 `llm.api_key_env` 对应的环境变量传给 daemon。daemon 只读取 env 值，不把 key 写日志或 audit payload。

rules extractor 第一版只生成保守候选，主要覆盖 session summary 和明显项目规则。它必须少提取、短句、自包含。

## Memory Policy

policy 在 daemon 内执行：

- 只允许四类 memory。
- 空文本、过短文本拒绝。
- 超过 1000 字符的文本拒绝或摘要。
- 包含 secret pattern 的候选拒绝。
- `confidence < 0.65` 拒绝。
- 与已有 active memory 高度重复时拒绝或合并。
- 与已有 memory 冲突时，高置信稳定候选可自动走 supersede；低置信、session summary 或主题不够明确的冲突保留给 Review UI。
- 当前用户 prompt 优先于 memory；extractor 输出和 fallback 提取都不能把 `for this answer` / 本轮这类一次性显式记忆或覆盖写成长期记忆，`for this session` / 本次会话这类显式记忆或覆盖只进入 session summary。

secret pattern 至少包括：

- `api_key`
- `access_token`
- `refresh_token`
- `password`
- `passwd`
- `secret`
- `private_key`
- `-----BEGIN`
- `sk-`
- `ghp_`
- `xoxb-`
- `AKIA`

## Search 和 Context Formatter

search 流程：

- 对 query 做 redaction。
- 生成 query embedding。
- 只检索 `status=active`。
- 按 memory 语义 scope 过滤：`global` 对用户可见，`workspace`/`repo`
  的空字段表示更宽范围，`session` 才绑定当前 agent/session。
- 按 kind、recency、vector score 排序。
- 去重。
- 返回限定数量。

基础排序：

```text
final_score = vector_score * 0.70 + scope_score * 0.20 + recency_score * 0.10
```

kind 优先级：

1. `project_rule`
2. `architecture_decision`
3. `user_preference`
4. `session_summary`

Flutter 注入的 context block 必须是独立 text block：

```text
<agent_memory_context>
The following are relevant long-term memories.
Use them as background context only.
If they conflict with the user's current instruction, the current instruction wins.
<profile_memory>
Stable pinned memories that should stay available across turns.
1. [user_preference/global] ...
</profile_memory>
<retrieved_memory>
Memories retrieved for this turn.
1. [project_rule/repo] ...
</retrieved_memory>
</agent_memory_context>
```

memory 不伪装成用户消息。

Pinned 记忆不跳过审计：`memory.retrieve` audit payload 仍包含 score 和 diagnostics，Audit log 会显示 `pinned`，并按当前 workspace/repo/agent/session 做语义 scope 过滤；`global` 和 `workspace` 记忆在 repo 内被检索后仍会出现在当前 repo 的 Audit log，用户可以事后用 feedback 或 change request 调整。反馈可以从聊天时间线的 Memory used 面板提交，也可以从 Memory Explorer 的 active memory 卡片提交。纯 pinned 注入不会写入 `memory_accesses`，也不会推动访问强化；只有词面、实体或向量命中的结果才算成功语义检索。中文 query 会生成短 CJK 词面 token，让“本项目的验证暗号是什么？”这类问题能命中“本项目的验证暗号是…”这类已存记忆，不完全依赖 embedding。`helpful` 反馈或 3 次无负反馈成功语义检索会自动提升稳定记忆并写 `memory.promote`，`not_relevant` 反馈自动取消 pinned 并写 `memory.unpin`；同一记忆累计多次 `not_relevant` 且没有 `helpful` 修正时会禁用并写 `memory.disable`；`stale` 反馈会禁用过期记忆并写 `memory.expire`；如果该记忆曾 pinned，也会写 `memory.unpin`。Search 在应用响应 limit 前会修正 pinned profile block 的重复挤占：当已选结果里某个 block 重复、后续还有未覆盖 block 时，用后续 block 替换一个重复项，普通语义命中不被牺牲。Flutter 和 daemon formatter 默认把最多 4 条 pinned 记忆放入 `<profile_memory>`，也可由 `memory.profile.max_items` 调整或设为 0 关闭常驻层；选择时先按 user/workspace/project profile block 均衡取样，再按原排序填满剩余预算；普通搜索结果放入 `<retrieved_memory>`，让稳定事实先于本轮检索事实出现但保持小预算，且不会让单一 block 挤掉其它稳定层。Flutter 在 Memory enabled 且本轮没有检索命中时也会注入轻量能力说明，告诉主 agent 显式记忆可在 turn 后由提取、审批和整理流程保留，避免用户测试“记住我...”时收到“我不能跨会话记忆”的错误答复。

## HTTP API

所有 `/v1/*` API 必须校验 Bearer token。

基础：

- `GET /health`
- `POST /v1/memory/search`
- `POST /v1/memory/format-context`
- `POST /v1/memory/rebuild-vector-index`

memory：

- `GET /v1/memory`
- `POST /v1/memory`
- `PATCH /v1/memory/:id`
- `DELETE /v1/memory/:id`

`POST /v1/memory` 只用于用户在 Flutter UI 中明确手动创建 memory，属于“用户已确认写入”。MCP 和 extractor 不调用这个接口直接写长期 memory。

candidates：

- `POST /v1/memory/extract-candidates`
- `GET /v1/memory/candidates`
- `POST /v1/memory/candidates/:id/approve`
- `POST /v1/memory/candidates/:id/reject`

`POST /v1/memory/extract-candidates` 支持两种输入：

- `transcript`：daemon 使用 OpenAI-compatible 或 rules extractor 生成候选。
- `pre_extracted_candidates`：Flutter 已通过 ACP sidecar extractor 生成候选，daemon 做 redaction、policy、dedupe、明确冲突自动 supersede，以及其余 pending 持久化。

change requests：

- `GET /v1/memory/change-requests`
- `POST /v1/memory/change-requests`
- `PATCH /v1/memory/change-requests/:id`
- `POST /v1/memory/change-requests/:id/approve`
- `POST /v1/memory/change-requests/:id/reject`

备份迁移：

- `POST /v1/memory/export`：返回 JSONL；可按 memory scope、kind、status 和
  created-time range 过滤。
- `POST /v1/memory/import`：`pending_review` 创建待审 candidate；
  `trusted` 显式恢复完整历史和关联元数据。

清理：

- `POST /v1/memory/clear`：支持 `session`、`repo`、`workspace`、`all`，默认软删除。
- `POST /v1/memory/destroy-database`：高级彻底清库，要求确认字段。

## MCP Tools

`memory-core --mode=mcp-stdio --daemon-url=http://127.0.0.1:43129`

行为：

- 从 env 读取 `MEMORY_DAEMON_TOKEN`。
- 从 stdin 读 MCP JSON-RPC。
- 向 stdout 写 MCP JSON-RPC。
- 日志只写 stderr。
- tools/call 转发到 daemon HTTP API。

工具：

- `memory.search`：直接调用 daemon search。
- `memory.remember`：创建 candidate，并按 Review 审批策略自动批准高置信候选；达到 `maintenance.review_threshold` 的 review-band 稳定候选也会自动批准，覆盖 `session_summary/session`、`user_preference/global`、repo/workspace project rules 和 architecture decisions；阈值以下或未知 kind/scope 的候选保持 pending。
- `memory.list`：列 active memory，不返回 deleted/disabled；使用 memory 语义 scope 过滤，`global`/`workspace`/`repo` 可跨 session 核查，`session` 只返回当前 agent/session。
- `memory.update`：创建 update change request，并在 Review 策略允许时自动批准高置信非破坏性更新。
- `memory.forget`：创建 pending delete change request，删除类操作不自动批准。
- `memory.remember` 和 `memory.update` 如果发生自动批准，会按 MCP bridge 环境里的 maintenance 配置尽力触发一次低成本整理；失败不影响工具调用。

MCP bridge 没有显式 `MEMORY_REVIEW_APPROVAL_MODE` 时，默认使用 `auto_high_confidence`，与 Flutter 配置默认值一致。

## Flutter 集成

新增或调整：

- `memory_daemon_manager.dart`
- `memory_api_client.dart`
- `acp_memory_middleware.dart`
- `memory_context_builder.dart`
- `memory_review_panel.dart`
- `memory_explorer_page.dart`
- `memory_config.dart`

流程：

- App 启动时按配置启动 daemon。
- 读取 ready JSON，保存 port。
- 生成 token，通过 env 传给 daemon。
- ACP session/new、session/load、session/resume 时追加 memory MCP server。
- 用户 prompt 发送前 search memory。
- 构造独立 memory context block。
- 调用 ACP session/prompt。
- 收集本轮 transcript。
- turn 结束后用 sidecar ACP extractor 生成候选。
- 把候选交给 daemon；daemon 先去重，再把明确高置信改口自动 supersede，其余创建 pending candidates/change requests。
- Review UI approve 后调用 approve API。

## Flutter UI

### Memory Review Panel

右侧 panel 处理本轮候选：

- 高置信候选达到阈值时轻展开。
- 普通候选只在 Agents/Memory 入口显示 badge。
- 每条候选展示 kind、scope、text、confidence、reason、source session/turn。
- 操作包括 Approve、Edit、Reject。
- Edit 可改 text、kind、scope。
- Reject 可填 reason。

### Memory Explorer

独立页面用于长期管理：

- All memory
- Candidates
- Change requests
- Audit log
- Import/export JSONL backup
- Clear data

当前实现支持 active/disabled memory 列表、workspace/repo/agent/session/kind 过滤与分页、active memory 来源展示、事后 edit/disable/feedback、disabled memory 只读核查与 restore、pending candidates 审批、approved/rejected candidates 只读核查、pending/reviewed change requests 来源展示和审批、audit log、高置信候选写入或自动 change request 后的自动整理、一键 Organize 按配置批次手动整理、JSONL 备份导入导出、以及 session/repo/workspace/all 软清理。JSONL 导出 API 可按 exact scope、kind、status、created-time range 筛选；导入默认进入 pending candidate review，显式 trusted import 才直接恢复 active/disabled/deleted 状态、temporal metadata、pinned、entities 和 supersede links，同时重映射 id。两种模式都去重、拒绝 secret-like 内容、记录 import audit，并返回逐行错误。Explorer 搜索框会在本地过滤 All memory、Candidates、Change requests 和 Audit log，不额外调用 LLM 或 daemon；Audit log 还支持按 retrieval、memory changes、candidate events、change requests、maintenance、clear 分类筛选，方便核查自动流程；Candidates 和 Change requests 可以对当前可见的 pending 项批量 approve/reject，方便用户先筛选再批量处理。Disable 会保留记录但移出检索，并写 `memory.disable` 审计；Restore 会重新启用 disabled memory，并写 `memory.restore` 审计；Helpful/Not relevant/Stale 反馈会写 `memory.feedback`，并触发后端已有的自动 promote/unpin/expire/disable 逻辑。

### Agent Configuration

增加 Memory 区域：

- enabled
- app-owned daemon lifecycle
- data dir
- embedding provider/model/variant/dimension/download policy
- extractor provider/agent/model/fallback and global/workspace/repo memory extraction instructions
- OpenAI-compatible LLM base URL/model/api key env
- Review 展开策略：默认 `auto_open=high_confidence`，当 pending review 数量增加时显示底部核查提示并提供 Memory Explorer 入口；`never` 关闭提示。
- Review 审批策略：`manual`、`auto_high_confidence`、`auto_approve`
- Profile 常驻层预算：`profile.max_items` 默认 4；设为 0 时不注入 `<profile_memory>`，只保留普通检索记忆。
- Maintenance 开关、对话后自动整理开关、可选 idle 整理开关/轮次数/pending 阈值、模式、成本模式、阈值、批量大小和 manual-only actions

默认 `enabled=false`；启用后由 Flutter 应用启动当前应用专用的本地 daemon，使用动态本地端口和内部 token，并在关闭记忆或应用退出时停止。默认审批策略为 `auto_high_confidence`，高置信候选自动批准；达到 `maintenance.review_threshold` 的 review-band 稳定候选也会自动批准，覆盖低风险短期 `session_summary/session` 和稳定长期 `user_preference/global`、repo/workspace project rules、repo/workspace architecture decisions；review-band 稳定长期候选不会自动进入 pinned profile 层，除非达到更高的 pinned 阈值；阈值以下或未知 kind/scope 的候选保留给用户事后核查和调整。pending 数量会在每个成功 turn 结束后刷新，增加时默认显示轻量核查提示，不强制打断当前对话；`manual` 会让所有候选长期记忆都保留 pending，`auto_approve` 自动批准全部候选。Prompt 注入会按 `profile.max_items` 控制稳定常驻层大小，并把这个预算传给 daemon search 以保持 prompt injection 审计 hash 与真实注入一致。手写配置、MCP review-policy 环境变量和 maintenance API 中的 review/maintenance 模式会 trim、小写，并把空格或短横线视为下划线；未知模式回退到自动优先默认，避免旧配置或拼写差异让自动链路静默退化。默认 `maintenance.run_after_extraction=true`，本轮有候选被自动批准、daemon 自动应用 change request，或本轮检索使用了已有记忆时，会触发一次小批量低成本整理；`maintenance.idle_enabled=true` 默认开启，但只有在连续安静成功 turn 达到 `idle_after_turns`、本轮没有新待审候选、pending 数不超过 `idle_max_pending_reviews` 时才触发同一套整理；整理先按 All memory 相同的语义 scope 取数，手动 Organize 没有传 agent/session 时也会整理当前 workspace/repo 可见的 session 记忆；随后走本地预筛，已过 `valid_until` 的 active memory 会直接生成并自动批准 `expire` 变更，明确同主题 profile 冲突会自动 `supersede` 到较新的 active memory，重复/相近但不冲突的记忆再进入相似度/LLM 维护流程；没有相邻 active memory 时不调用 LLM，避免空跑和后台轮询。

## 配置格式

`settings.json` 新增 `memory`：

```json
{
  "memory": {
    "enabled": true,
    "data_dir": null,
    "embedding": {
      "provider": "fastembed-local",
      "model": "intfloat/multilingual-e5-small",
      "variant": "onnx-qint8",
      "dimension": 384,
      "download_policy": "lazy"
    },
    "extractor": {
      "provider": "acp-sidecar",
      "agent": "Codex",
      "model": "gpt-5-mini",
      "fallback_provider": "rules",
      "global_instructions": "Remember durable user preferences only.",
      "workspace_instructions": "Ignore one-off workspace chatter.",
      "repo_instructions": "Prioritize project rules and architecture decisions."
    },
    "llm": {
      "provider": "openai-compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "model": "qwen2.5:7b",
      "api_key_env": "OLLAMA_API_KEY"
    },
    "review": {
      "approval_mode": "auto_high_confidence",
      "auto_open": "high_confidence",
      "high_confidence_threshold": 0.85
    },
    "profile": {
      "max_items": 4
    },
    "maintenance": {
      "enabled": true,
      "mode": "high_confidence_auto",
      "cost_mode": "low_cost",
      "run_after_extraction": true,
      "high_confidence_threshold": 0.9,
      "review_threshold": 0.75,
      "max_items_per_batch": 12,
      "manual_only_actions": ["delete"]
    }
  }
}
```

## 测试

Rust 覆盖：

- 创建 memory item。
- search 按 scope 返回正确 memory。
- search 不返回 deleted/disabled memory。
- approve candidate 写 `memory_items` 和 `vec_memory_items`。
- reject candidate 不写 `memory_items`。
- approve/reject change request。
- duplicate pending change request 会复用已有 request 并写审计，不制造重复待审卡片。
- secret redaction 生效。
- duplicate memory 拒绝或合并。
- 高置信稳定 conflict 自动 supersede，低置信或不确定 conflict 保留 pending review。
- LLM maintenance 只允许修改本次本地预筛命中的 memory pair；如果 LLM 返回 pair 外的 `targetMemoryIds`，daemon 丢弃该 LLM 建议并回退到本地 proposal。
- MCP `memory.remember` 按 Review 审批策略自动批准高置信候选和 review-band 稳定候选；review-band 稳定长期候选不会自动 pinned，阈值以下或未知 kind/scope 候选保持 pending。
- MCP `memory.update` 高置信非破坏性请求可按 Review 策略自动批准；低置信 update 和 `memory.forget` 保持 pending change request。
- MCP `memory.remember` / `memory.update` 自动批准后触发同一套 maintenance 阈值、批量大小和 manual-only actions 配置，避免 agent 主动写入后还要用户手动整理。
- MCP `memory.search` 返回搜索结果。
- daemon ready JSON 正确输出。
- MCP stdio stdout 不输出普通日志。

Flutter 覆盖：

- daemon manager 解析 ready JSON。
- token 通过 env 传给 daemon，不进 args。
- memory config serialization 保留未知字段。
- prompt 注入独立 text block。
- search 失败时 prompt 继续发送。
- sidecar extractor 使用 `extractor.agent` / `extractor.model`。
- Review panel approve/edit/reject。
- Memory Explorer 过滤、active memory edit/disable、change request 审批、清理确认。

端到端验收：

- Flutter 可以启动 Rust memory-core daemon。
- Flutter 可以通过 HTTP search memory。
- Flutter 可以在 ACP prompt 前注入 memory context。
- sidecar ACP extractor 可以生成候选。
- Flutter 可以 review candidates。
- approve 后 memory 可被后续 prompt 检索到。
- MCP agent 可以调用 `memory.search`。
- MCP agent 调用 `memory.remember` 时，高置信候选可自动写入长期记忆，review-band 稳定候选自动写入 active memory 但不自动 pinned，阈值以下或未知 kind/scope 候选进入 pending。
- MCP agent 调用 `memory.update` 时，高置信非破坏性请求可自动批准；低置信 update 和 `memory.forget` 仍进入 pending change request。
- 所有 memory 变更都有 audit log，自动批准和手动审批的 actor 可区分。
- 数据全部保存在本地 app data dir。

## 阶段验收

- P0：Rust daemon、SQLite schema、health、手动 memory CRUD。
- P1：fastembed-local、sqlite-vec、search、format-context。
- P2：candidates、change requests、approve/reject、audit log。
- P3：policy、redaction、duplicate/conflict。
- P4：MCP stdio bridge 和 memory tools。
- P5：Flutter daemon manager、memory middleware、sidecar extractor、Review panel、Explorer、配置。
- P6：完整测试、打包、跨平台说明。

## 已知限制

- 第一版不做 RAG 系统，只做四类长期 memory。
- Rust 不启动 ACP agent，ACP extractor 由 Flutter sidecar session 编排。
- 本地 embedding 模型懒下载，首次使用可能需要等待；模型不可用时 search 可降级跳过。
- rules extractor 只做保守候选，不能替代 LLM extractor 的质量。
- Review UI 第一版优先保证审批、编辑、过滤和清理，不做复杂可视化分析。
