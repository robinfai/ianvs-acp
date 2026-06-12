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
- 默认开启完整闭环；高置信、非破坏性长期写入和整理可自动处理，用户主要做事后核查、编辑，以及 delete/forget 等清理类变更确认。
- embedding 默认本地优先，推荐 `intfloat/multilingual-e5-small`，模型懒下载到 app data；测试使用 mock embedder。
- extractor 支持 `acp-sidecar` 和 OpenAI-compatible API。ACP 模式使用单独 sidecar ACP session，不复用当前用户 session。
- `extractor.agent` 指定 ACP agent，`extractor.model` 指定该 extractor sidecar 的模型或 config option 值。
- Memory Review UI 同时提供右侧 panel 和独立 Memory Explorer。
- MCP `memory.update` / `memory.forget` 无阈值时使用 pending change request；
  带 `autoApproveThreshold` 或 MCP 进程
  `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD` 时接入 maintenance 策略，
  高置信 update 自动应用，低置信或缺置信 update/forget 跳过，高置信
  forget/delete 保留人工确认。
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
   - MCP 工具读 memory 可以直接返回；写入/修改/遗忘按策略进入自动审批、跳过或 pending cleanup review。

主流程：

```text
用户 prompt
→ Flutter 调用 /v1/memory/search
→ Flutter 注入 agent_memory_context text block
→ ACP agent 正常处理 prompt
→ turn 结束
→ Flutter 用 sidecar ACP extractor 生成候选
→ daemon 做 redaction、policy、dedupe、conflict
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

`memory_items` 是事实来源，只保存已审批 memory。`status=active` 才参与检索，`disabled` 和 `deleted` 不参与检索。

`memory_candidates` 只表示新增 memory 候选，来源包括 extractor 和 MCP `memory.remember`。状态为 `pending`、`approved`、`rejected`。

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
  target_memory_id text,
  proposed_kind text,
  proposed_scope text,
  proposed_text text,
  reason text,
  status text not null default 'pending',
  created_at integer not null,
  reviewed_at integer
);
```

`memory_audit_log` 记录 candidate create/approve/reject、change request create/approve/reject、memory create/update/delete/clear。

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

默认使用 `acp-sidecar`，失败时 fallback 到 `rules`。ACP 模式由 Flutter 编排，使用单独 sidecar session，不污染当前用户 session。OpenAI-compatible 和 rules 模式由 daemon 执行；Flutter 把 transcript 发给 daemon，daemon 负责 redaction、调用 extractor、policy 和持久化 pending candidate。

配置：

```json
{
  "extractor": {
    "provider": "acp-sidecar",
    "agent": "Codex",
    "model": "gpt-5-mini",
    "fallback_provider": "rules"
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
- 与已有 active memory 或 pending candidate 完全规范化重复时跳过写入，
  并记录 `candidate.skip_duplicate` 审计事件。
- 带 `autoApproveThreshold` 的候选提取只写入达阈值候选；低于阈值或缺少
  confidence 的候选自动跳过并记录 `candidate.skip_below_auto_threshold`，
  不进入 pending review。
- AGENTS.md、系统/开发者/agent 运行约束、工具使用规则不进入长期记忆；
  Flutter extraction/maintenance prompt 会明确禁止提取或提议，daemon
  candidate/maintenance policy 也会兜底拒收。
- 维护整理同时检查 active memory 和可清理/可整理的 disabled memory；disabled
  与 active 高置信重复时生成清理建议，delete/disable/expire 仍保留人工确认；disabled
  与 active 有相似但不完全重复的内容时，可以进入有方向的 merge 建议。
- Flutter maintenance extractor 输入包含 active/disabled 状态；即使收到
  LLM/ACP sidecar 的预提取建议，daemon 仍会继续运行内置低成本扫描，避免
  extractor 遮住 disabled cleanup 或方向合并机会。
- 与已有 active memory 高度重叠但不完全相同的内容进入维护整理；
  auto-approved candidate 和 daemon approve endpoint 批准的 candidate
  都触发自动维护：daemon 先做高置信低成本扫描，Flutter 再把当前可见
  active/disabled memory 按疑似相关度排序并截取较大批次，调用配置的 LLM/ACP
  maintenance extractor；明显重复或 active/disabled 可合并重叠会按
  `session -> repo -> global` 方向合并。同一窄层级重复才逐级上推：
  session 重复提升到 repo，repo 重复提升到 global；如果已有 global 参与，
  不会降级回 repo。workspace scope 只作为兼容旧数据的同层 scope，不作为
  提升链路中的停靠层。
- `high_confidence_auto` maintenance 只处理高置信建议；中置信建议自动跳过，
  不再堆到人工 review 队列。
- MCP `memory.update` / `memory.forget` 带自动阈值或
  `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD` 时复用同一套 maintenance
  策略；缺置信度按低置信跳过，没有阈值时保留 pending change request 兼容路径。
- 与已有 memory 冲突时不自动覆盖，标记 conflict 后交给 Review UI。
- 当前用户 prompt 优先于 memory。

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
- 按 scope、kind、recency、vector score 排序。
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
1. [project_rule] ...
</agent_memory_context>
```

memory 不伪装成用户消息。

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
- `pre_extracted_candidates`：Flutter 已通过 ACP sidecar extractor 生成候选，daemon 只做 redaction、policy、dedupe、conflict，并根据阈值自动 approve、跳过或 pending 持久化。

change requests：

- `GET /v1/memory/change-requests`
- `POST /v1/memory/change-requests`
- `POST /v1/memory/change-requests/:id/approve`
- `POST /v1/memory/change-requests/:id/reject`
- `POST /v1/memory/maintenance/run`

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
- `memory.remember`：创建 candidate；带 `autoApproveThreshold` 或 MCP 进程
  `MEMORY_AUTO_APPROVE_THRESHOLD` 默认阈值时，达阈值自动 approve，低于阈值自动跳过；没有阈值时创建 pending candidate。
- `memory.list`：列 active memory，不返回 deleted/disabled。
- `memory.update`：无自动阈值时创建 pending update change request；带
  `autoApproveThreshold` 或 MCP 进程
  `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD` 默认阈值时，高置信自动应用，
  低置信或缺置信跳过。该阈值独立于 `memory.remember` 使用的
  `MEMORY_AUTO_APPROVE_THRESHOLD`。
- `memory.forget`：无自动阈值时创建 pending delete change request；带
  自动阈值时，高置信 delete 保留 pending cleanup review，低置信或缺置信跳过。

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
- 把候选交给 daemon 创建 pending candidates/change requests。
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
- Clear data

All memory 展示 active 和 disabled 记录，不展示 soft-deleted 记录；顶部提供 `Organize` 手动整理入口。Flutter 将当前可见 active/disabled memory 按疑似相关度排序并截取较大批次后调用配置的 ACP sidecar 或 OpenAI-compatible LLM extractor 生成 merge/update/delete 等 change requests，输入包含 memory status，不发送完整 prompt 历史。daemon 先处理 extractor 建议，再继续运行内置 active/disabled 扫描，统一套用高置信非清理自动执行、中低置信跳过、delete/disable/expire 永远人工的策略。支持搜索、过滤、编辑、disable、restore、soft delete、清理当前 session/repo/workspace/all。
`manual_only_actions` 只能增加需要人工核查的维护 action，不能把 delete/disable/expire
从 cleanup 人工基线中移除；旧配置只有 `["delete"]` 时会自动补齐 disable/expire。

### Agent Configuration

增加 Memory 区域：

- enabled
- app-owned daemon lifecycle
- data dir
- embedding provider/model/variant/dimension/download policy
- extractor provider/agent/model/fallback
- OpenAI-compatible LLM base URL/model/api key env
- Review 展开策略

默认 `enabled=false`；启用后由 Flutter 应用启动当前应用专用的本地 daemon，使用动态本地端口和内部 token，并在关闭记忆或应用退出时停止。默认策略是高置信、非清理类写入自动处理，低置信或缺置信跳过，delete/forget 等清理类变更保留人工确认。

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
      "fallback_provider": "rules"
    },
    "llm": {
      "provider": "openai-compatible",
      "base_url": "http://127.0.0.1:11434/v1",
      "model": "qwen2.5:7b",
      "api_key_env": "OLLAMA_API_KEY"
    },
    "review": {
      "mode": "high_confidence_auto",
      "high_confidence_threshold": 0.85
    },
    "maintenance": {
      "enabled": true,
      "mode": "high_confidence_auto",
      "cost_mode": "low_cost",
      "high_confidence_threshold": 0.90,
      "review_threshold": 0.75,
      "max_items_per_batch": 50,
      "manual_only_actions": ["delete", "disable", "expire"]
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
- daemon approve candidate 后触发高置信低成本维护；Flutter 会把当前可见
  active/disabled memory 按疑似相关度排序并截取较大批次，继续调用 LLM/ACP
  maintenance extractor 做自动整理建议。
- reject candidate 不写 `memory_items`。
- approve/reject change request。
- secret redaction 生效。
- duplicate candidate 在进入人工 review 前自动跳过并写审计。
- high-confidence automatic candidate extraction 跳过中置信或缺置信候选，不生成 pending review 噪声。
- disabled duplicate memory 进入清理建议。
- overlapping duplicate memory 按 session -> repo -> global 方向进入维护合并；
  同一窄层级重复逐级上推，已有 global 参与时不会降级回 repo；workspace
  兼容数据不会作为中间提升层，auto-approved/manual-approved candidate 都会
  触发高置信维护。
  merge 会新建合并后的 active memory，并把旧 target 软删除，避免 All memory
  继续显示 disabled 重复项。
- pre-extracted LLM/ACP sidecar maintenance 建议不会阻止 daemon 的内置
  active/disabled cleanup 和方向合并扫描。
- high-confidence automatic maintenance 跳过中置信建议，不生成 pending review 噪声。
- conflict 标记但不自动覆盖。
- MCP `memory.remember` 可按阈值自动 approve 或跳过；未设置阈值时创建 pending candidate。
- MCP `memory.update` / `memory.forget` 无阈值时创建 pending change request；
  带 `autoApproveThreshold` 或 `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD`
  时按 high-confidence maintenance 策略自动应用、跳过或保留 cleanup review；缺置信度按跳过处理。
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
- Memory Explorer 过滤、change request 审批、清理确认。

端到端验收：

- Flutter 可以启动 Rust memory-core daemon。
- Flutter 可以通过 HTTP search memory。
- Flutter 可以在 ACP prompt 前注入 memory context。
- sidecar ACP extractor 可以生成候选。
- Flutter 可以 review candidates。
- approve 后 memory 可被后续 prompt 检索到。
- MCP agent 可以调用 `memory.search`。
- MCP agent 调用 `memory.remember` 时可按阈值自动 approve 或跳过；未设置阈值时创建 pending candidate。
- MCP agent 调用 `memory.update` / `memory.forget` 时，无阈值保留 pending
  change request；带 `autoApproveThreshold` 或
  `MEMORY_CHANGE_REQUEST_AUTO_APPROVE_THRESHOLD` 时按 high-confidence
  maintenance 策略自动应用、跳过或保留 cleanup review；缺置信度按跳过处理。
- 所有 memory 变更都有 audit log。
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
