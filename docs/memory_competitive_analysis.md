# Local Memory competitive analysis

Date: 2026-06-10

Scope: compare the current local memory engine with mem0-style community memory
systems and identify features worth adopting for this Flutter ACP client.

Primary sources:

- Mem0 docs: https://docs.mem0.ai/llms.txt
- Mem0 advanced retrieval: https://docs.mem0.ai/platform/features/advanced-retrieval
- Mem0 temporal reasoning: https://docs.mem0.ai/platform/features/temporal-reasoning
- Mem0 memory decay: https://docs.mem0.ai/platform/features/memory-decay
- Mem0 filters: https://docs.mem0.ai/platform/features/v2-memory-filters
- Mem0 GitHub README: https://github.com/mem0ai/mem0
- Zep overview: https://help.getzep.com/overview
- Graphiti overview: https://help.getzep.com/graphiti/getting-started/overview
- Graphiti episodes: https://help.getzep.com/graphiti/core-concepts/adding-episodes
- Letta memory blocks: https://docs.letta.com/guides/core-concepts/memory/memory-blocks/
- Letta archival memory: https://docs.letta.com/guides/core-concepts/memory/archival-memory/
- LangChain memory overview: https://docs.langchain.com/oss/python/concepts/memory

## Executive read

当前实现已经覆盖了本地优先、人工审批、候选记忆、变更请求、审计、scope
隔离、混合检索、自动/手动整理和 ACP/MCP 接入。这让它比通用 SaaS 方案更适合
桌面 ACP 客户端的隐私和可解释目标。

对比 mem0、Zep/Graphiti、Letta、LangGraph/LangMem 后，最值得采纳的不是
完整平台化能力，而是五个高收益补强：

1. 记忆质量评测集和可复现回归测试。
2. 时间感知检索和搜索时衰减。
3. 实体/关键词/向量的多信号检索融合。
4. 常驻 profile/block 型记忆，用于小而稳定的用户和项目状态。
5. 记忆反馈与 provenance 视图，把“为什么召回/为什么写入”做得更透明。

知识图谱、复杂本体、多模态记忆、Webhook、企业多租户和云同步暂不建议作为
近期主线。它们会显著增加维护成本，且当前产品的核心痛点仍是“本地对话中能
可靠记住、可审、可改、跨会话可验证”。

## Current implementation baseline

已具备：

- 四类 reviewed memory：`user_preference`、`project_rule`、
  `architecture_decision`、`session_summary`。
- scope：global、workspace、repo、session，并带 user/workspace/repo/agent/session
  过滤。
- 本地 SQLite 事实库、sqlite-vec 检索索引、本地 embedding 和
  OpenAI-compatible embedding。
- 对话前检索并注入独立 memory context block；即使当前没有检索命中，也会注入轻量能力说明，避免主 agent 误答“不能跨会话记忆”。
- turn 结束后通过 ACP sidecar 或 OpenAI-compatible extractor 生成候选。
- 明确 `记住`/`remember` 指令、清晰称呼偏好、直接自我介绍、清晰偏好表达（含“始终/从现在起”这类中文长期标记，以及句尾 `from now on` / `going forward` 这类英文长期标记）、项目规则（含“以后这个项目...”这类未来式中文标记）和架构决策在 extractor 空结果或失败时有本地兜底候选，并把同一称呼/名字/偏好以及同 scope、同规则实体的 repo 规则/架构决策重复候选合并为一条；当 extractor 已捕获同一事实但分数偏保守时，fallback 会提升置信度或补充实体；清晰长期偏好、repo 规则和架构决策兜底使用高置信分数，批准后能进入 pinned profile 层；extractor 输出和 fallback 候选都会归一化生命周期，一次性显式记忆或称呼/名字/偏好/项目覆盖不写长期记忆，会话级覆盖只写 session summary。
- 默认高置信自动审批；review-band 稳定记忆达到 review 阈值后先进入 active
  memory，但不自动 pinned；阈值以下或未知类型候选留给事后核查；仍支持手动审批和全自动审批配置。
- 高置信候选自动审批后可默认触发一次小批量低成本 maintenance。
- MCP `memory.search/list/remember/update/forget`，写入进入候选，非破坏性高置信
  update 可自动批准，forget/delete 仍进入待核查变更请求。
- Memory Explorer 可看 All memory、Pending candidates、pending/reviewed Change
  requests、Audit log。
- 自动审批或自动整理后也会给出轻量 Review 提示，方便事后核查。
- All memory 里保留手动 `Organize`，可生成 merge/summarize/disable/delete 等建议。
- prompt injection 记录 turn id、memory ids 和注入文本 hash，不存 raw prompt。
- retrieval diagnostics 会随 search response 和 `memory.retrieve` audit 返回，Audit log
  能显示 score、lexical、feedback、used count 摘要。
- `memory_accesses` 记录被取回的记忆，`memory_feedback` 记录 helpful/not_relevant/stale
  反馈，并以低幅度 search-time ranking adjustment 影响后续排序。
- memory item 可带 `observedAt`、`validFrom`、`validUntil`、
  `supersedesMemoryId`，search 默认按当前时间检索，也可带 `referenceTime` 做历史
  lookup，过期或尚未生效的记忆会降权。
- `memory_entities` 提供轻量 entity/tag 存储；manual memory 和 extracted candidate
  都可带 entities，审批后用于 normalized entity matching。
- `memory_items.pinned` 提供第一版 profile/block 常驻层；高置信 global 用户偏好和
  repo 项目规则/架构决策候选批准后会自动 pinned，搜索诊断标记 `pinnedLayer`，
  并派生 `profileBlock` label/description/limit，例如 `user_profile` 和
  `project_profile`；prompt context 会用 block label 标注常驻记忆。
- `memory-core/tests/fixtures/memory_eval_cases.json` 提供固定评测样例，覆盖中英
  混合召回、repo scope 隔离、session 隔离、pinned profile 召回、实体别名召回，
  以及当前/历史时间点的偏好排序。
- 记忆启停绑定 app-owned daemon 生命周期。

主要差距：

- memory quality eval 已覆盖关键检索不变量，但还不是完整质量套件。
- 检索排序已有语义/词面、entity/tag、scope、kind、更新时间、反馈、访问强化、
  低幅度 decay/recency、轻量 temporal validity 和 supersede 链。
- active memory 仍是扁平文本项；已有 pinned profile 层，但还没有完整 block
  label/description/value/limit UI。
- Audit log 已能看到 retrieval 诊断摘要；每轮对话也能看到 `Memory used`
  面板并直接提交 helpful/not relevant/stale 反馈。
- 维护整理已处理相似文本、过期时效和明确同主题 profile 冲突；复杂事实冲突仍需要
  LLM 建议或人工事后核查。

## Competitor patterns

### Mem0

Mem0 的强项是“少调用、强检索、生产易接入”。公开文档和仓库强调：

- managed 和 OSS 共用 add/search/update/delete 心智模型。
- 新算法倾向 ADD-only extraction，减少 UPDATE/DELETE 造成的错误覆盖。
- multi-signal retrieval：semantic、BM25、entity matching 并行打分融合。
- temporal reasoning：对 last week、upcoming、right now、as-of 等时间问题做排序。
- memory decay：搜索时强化最近被用过的记忆，柔性压低长期不用的记忆。
- reranking、advanced filters、custom instructions、feedback、export、MCP/editor 集成。

对本项目的启发：

- 采纳多信号检索和时间/衰减排序，但继续保留人工审批。
- 采纳“搜索时衰减，不直接删除”的设计，避免自动过期误删。
- 采纳 custom extraction instructions，让用户按项目约束“什么该记、什么不该记”；当前已支持 global/workspace/repo 三层 extractor prompt 指令。
- 采纳 feedback API/UI，把误召回、漏召回作为维护和排序输入。

不建议照搬：

- 纯 ADD-only 不适合本项目。我们已经有 change requests 审批链，用户明确需要
  edit/merge/delete/expire，完全不更新会让 Memory Explorer 很快变脏。
- SaaS dashboard、webhook、组织/项目成员管理不是当前桌面客户端的近期重点。

### Zep / Graphiti

Zep/Graphiti 的强项是 temporal knowledge graph。官方文档强调：

- 从 chat、business data、documents、JSON 构建 temporal Context Graph。
- Graphiti 把输入作为 episode，保留 provenance。
- 图边带时间元数据，可表达关系生命周期和 point-in-time 查询。
- 检索融合 time、full-text、semantic、graph traversal，不依赖 LLM rerank。
- 支持 custom entity/edge types 和 graph namespace。

对本项目的启发：

- 采纳 episode/provenance 思路：memory item 应能回到来源 turn、候选、审批记录；已批准候选会保留 source session/turn，并在 All memory 里显示来源 turn。
- 采纳轻量实体抽取，先只做 entities/tags，不引入完整图数据库。
- 采纳 temporal validity 字段，例如 `valid_from`、`valid_until`、`observed_at`、
  `supersedes_id`，用于“当前是什么、过去是什么”的问题。

不建议近期照搬：

- 完整 temporal graph、Neo4j/FalkorDB/Neptune 级后端。桌面本地方案会被部署、
  资源和调试成本拖慢。
- 自定义本体 UI。可以先给 extractor 一个固定轻量 schema。

### Letta / MemGPT

Letta 的强项是 agent-owned state。核心启发来自 memory blocks：

- memory blocks 是长期常驻上下文，不需要检索。
- block 有 label、description、value、limit。
- block 可共享给多个 agent，也可设为 read-only。
- agent 可以通过内置工具更新 block。
- archival memory 用于较大的外部检索记忆。

对本项目的启发：

- 增加 `Memory Blocks` 或 `Pinned memory`：小而稳定、总是注入的 profile，比如
  “用户称呼”“本仓库关键规则”“当前项目暗号/验证短语”。当前已实现轻量版：
  pinned 记忆自动派生 block label/description/limit 并进入 `<profile_memory>`。
- 每个 block 有描述、字符上限、read-only 和 attached agents。
- Review UI 中把“写入长期检索库”和“写入常驻 block”区分开。

不建议近期照搬：

- 让 agent 自主覆写 block。当前产品要求可审，block 更新仍应走 change request。
- 复杂多 agent block 协同。先做用户级/项目级 pinned block 即可。

### LangGraph / LangMem

LangGraph 的强项是清晰的记忆分类和写入时机：

- short-term memory 属于 thread/checkpoint。
- long-term memory 可按 namespace 存储并跨 thread 召回。
- semantic、episodic、procedural 三类记忆应分别建模。
- 写入可在 hot path 或后台任务中进行，二者有延迟和质量权衡。
- profile 和 collection 各有取舍：profile 便于完整上下文，collection 便于高召回。

对本项目的启发：

- 当前四类 kind 可以补一层 memory mode：
  - semantic：用户偏好、项目规则、架构决策。
  - episodic：可复用的任务过程/失败教训/工具调用经验。
  - procedural：可审批的 agent instruction 或项目工作方式。
- 后台整理保留手动 `Organize`，同时默认启用保守 idle trigger；它必须继续可关闭。
- 增加 namespace/tag，让用户能按 repo、feature、agent、task 类型组织。

不建议近期照搬：

- 把 memory 直接并入 agent graph state。本项目要服务 ACP 客户端和不同 agent，
  memory-core 作为独立事实源更合适。

## Feature adoption backlog

### P0: should keep expanding

#### 1. Memory eval harness

Status: expanded first pass implemented. The fixture covers bilingual recall,
repo/session isolation, pinned profile recall without lexical overlap, entity
alias recall, temporal current/historical preference ranking, and maintenance
regressions for duplicate merge plus timeboxed expiry. It should keep growing
before retrieval ranking changes become more aggressive.

Why: 目前最缺的是可验证性。用户手动测试能发现单例问题，但不能防止回归。

Design:

- 新增 `memory-core/tests/fixtures/memory_eval_cases.json`。
- 已覆盖：
  - name/preference recall。
  - repo rule recall。
  - pinned profile 不靠词面重合也能召回。
  - entity alias recall。
  - “旧偏好被新偏好替代”的当前/历史排序。
  - session-only 不跨 session 泄露。
  - 中英混合 query。
  - duplicate merge 后旧记忆不再参与检索，合并事实仍可召回。
  - expire 后过期记忆不再参与检索。
  - prompt 注入顺序和 fallback 规则避免把当前一次性指令写成长期偏好。
- 待继续覆盖：
  - 真实模型对“当前指令覆盖旧记忆”的端到端回答质量。
- 每个 case 定义 setup memories、query、expected ids、forbidden ids；需要时也可先跑 maintenance 并断言 auto-applied、needs-review 和 active count。
- Rust 层验证 search 排名和 scope。
- Flutter 层保留少量端到端 mock extractor 流程测试。

Success:

- `cargo test --manifest-path memory-core/Cargo.toml memory_eval` 可跑固定样例。
- 任何检索策略改动必须跑 eval。

#### 2. Retrieval diagnostics in UI

Status: implemented. Search responses and audit payloads include diagnostics,
Audit log cards show a compact summary and local category filters for
retrieval, memory changes, candidate events, change requests, maintenance, and
clear events. The chat timeline shows a per-turn `Memory used` panel with direct
helpful/not relevant/stale feedback buttons.

Why: 用户已经问过“为什么审计里没看到取回过的记忆”。当前 audit 有事件，
对话内面板补上了“这轮用了什么记忆”的明确入口。

Design:

- 在每轮 agent message 或 turn footer 增加 Memory used indicator。
- 点击后显示：
  - injected memory ids/text/kind/scope/score。
  - lexical/vector/scope/recency 分数。
  - prompt injection hash 和 turn id。
  - “mark helpful / not relevant / stale”反馈按钮。
- Audit tab 分类筛选：retrieval、memory changes、candidate events、change request、
  maintenance、clear。

Success:

- 用户不用查数据库也能确认某轮到底取回了什么。

#### 3. Search-time decay and reinforcement

Status: implemented as a low-impact first pass. Returned memories are recorded
in `memory_accesses`; helpful/not_relevant/stale feedback is recorded in
`memory_feedback` and gently adjusts search ranking. A single not_relevant
feedback demotes the memory; repeated not_relevant feedback with no helpful
correction disables it from retrieval while keeping the record for audit.
Recent access gives a small recency boost, and long-unused memories receive a
low-impact `decayScore` while remaining searchable.
Chinese question-style queries use short CJK lexical tokens, improving local
recall for project passphrases and similar short facts without another LLM call.

Why: mem0 的 decay 是低成本高收益能力，尤其适合本地长期记忆。

Design:

- 新表 `memory_accesses(memory_id, accessed_at, turn_id)` 或在 item 上维护
  `last_accessed_at/access_count`，保留最近 N 次明细。
- 搜索返回时记录 reinforcement。
- 排序增加 low-impact decay/recency factor，并在 diagnostics 中暴露
  `recencyScore` 和 `decayScore`。
- 不因 decay 自动删除 memory。

Success:

- 最近常用且同等相关的 memory 排名上升。
- 长期不用但强相关的 memory 仍可出现。

#### 4. Temporal metadata

Status: first pass implemented. Memory records can store observed/valid-from/
valid-until/supersedes ids, search defaults to the current time and can pass a
reference time for historical lookup, reviewed `supersede` change requests
create a replacement memory while marking the old active memory with
`valid_until`, and high-confidence stable same-topic candidates can auto-create
and approve that supersede path. Maintenance can also link a newer active
profile memory to an older same-topic conflicting memory instead of merging both
facts together. Temporal UI and real extraction-quality validation remain open.

Why: 对“现在/之前/上周/本项目当前规则”这类问题，更新时间不足以表达真实时间。

Design:

- `memory_items` 增加 `observed_at`、`valid_from`、`valid_until`、
  `supersedes_memory_id`。
- extractor 输出可选 temporal fields。
- change request 支持 `supersede` 审批链。
- search request 支持 `reference_date`。

Success:

- 新事实替代旧事实时，旧事实不一定删除，但当前查询默认排在后面。

### P1: implement after P0

#### 5. Lightweight entity/tag extraction

Status: first pass implemented. Memory records and extracted candidates can
carry entities/tags, approved candidates index those entities into
`memory_entities`, and search uses normalized entity matching with diagnostics.
Manual maintenance uses entity overlap as a local prefilter for review-band
suggestions and LLM maintenance calls when text similarity alone is weak.

Why: Zep/Graphiti 和 mem0 都强调实体是检索质量的关键，但完整图太重。

Design:

- 新表 `memory_entities(memory_id, entity_text, entity_type, normalized_text)`。
- extractor 输出 entities/tags。
- 检索时对 query entities 做 exact/normalized boost。
- Maintenance 用 entity overlap 预筛重复/冲突。

Success:

- “43130 对什么”“Rodriguez 是谁”“这个项目的暗号”这类实体查询更稳。

#### 6. Pinned memory blocks

Status: first pass implemented. `memory_items.pinned` now gives stable profile
facts a non-probabilistic retrieval path, high-confidence stable candidates are
auto-pinned on approval, and prompt context groups the top pinned memories into
`<profile_memory>` before ordinary `<retrieved_memory>` hits with a small
default budget. `memory.profile.max_items` now controls that prompt budget and
can disable the always-on profile layer with `0`; Flutter passes the same budget
to daemon search so prompt-injection audit hashes match the actual injected
context. Search also balances pinned profile blocks before applying the response
limit when one block would otherwise repeat and crowd another block out.
Flutter and daemon formatting balance the prompt budget across profile blocks
before filling remaining slots by rank, so user facts do not crowd
project/workspace rules out of the stable layer. Full block editing UI is still
future work.

Why: Letta memory blocks 解决“最重要的小事实不该靠检索碰运气”的问题。

Design:

- 新增 block 类型：
  - `user_profile`
  - `repo_profile`
  - `agent_instructions`
  - `project_status`
- 字段：label、description、value、limit、scope、read_only、status。
- 默认只注入高优先级、小体积 block；当前第一版用 `pinned` memory item 表达。
- block 修改走 change request。

Success:

- 用户名、长期偏好、项目硬规则可以稳定跨会话出现。

#### 7. Custom memory instructions

Status: first pass implemented. Agent Configuration can persist
global/workspace/repo memory extraction instructions under `memory.extractor`,
and both ACP sidecar and OpenAI-compatible extractors include those instructions
in the extraction prompt. Extracted candidates can also carry
`instructionScopes`, and Memory Explorer shows the matched instruction layers so
post-hoc review explains why the candidate appeared.

Why: 不同 repo 对“该记什么”差异很大。

Design:

- Agent Configuration 增加 Memory extraction instructions。
- 可设 global/workspace/repo 层级。
- extractor prompt 合并这些规则。
- Review UI 显示 candidate 命中了哪条规则或为什么被过滤。

Success:

- 用户能说“这个仓库只记项目规则和架构决策，不记个人闲聊”。

#### 8. Import/export and backup

Why: 本地数据需要可迁移、可审查。

Design:

- JSONL export/import。
- 可按 scope、kind、status、date range 导出。
- 导入走 pending review 或 trusted import 模式。

Success:

- 用户能备份和迁移 memory，而不需要直接操作 SQLite。

### P2: later

#### 9. Episodic skill memories

Why: 对 coding agent，有价值的不只是事实，还有“怎么做成功了”。

Design:

- 新 kind 或 subtype：`task_episode`。
- 存储 goal、constraints、tools used、mistake、successful pattern。
- 检索时作为 few-shot style context，严格限量。

Success:

- Agent 能跨会话复用“这个项目测试怎么跑”“这个 UI 验证怎么做”的经验。

#### 10. Conservative idle maintenance

Why: 手动 Organize 适合调试，但长期使用后用户不会每次整理。

Status: first pass implemented. `memory.maintenance.idle_enabled` 默认开启；
Flutter 在成功 turn 结束时按 `idle_after_turns` 计数，只在本轮没有新待审候选且
pending review 数不超过 `idle_max_pending_reviews` 时触发同一套低成本 maintenance；
已 approved/rejected 的候选历史不会阻塞 idle pass。

Design:

- 默认开启，但保守触发。
- 只在 app idle、daemon healthy、pending 数低、预算满足时触发。
- 每次只处理小批量，所有 destructive action 仍 pending。

Success:

- 不影响对话延迟，也不制造不可解释的自动改动。

#### 11. Full graph memory experiment

Why: 对复杂项目关系、人员/模块/决策链可能有价值。

Design:

- 仅作为实验 flag。
- 先用 SQLite 表模拟 nodes/edges，不引入外部图数据库。
- 只对 architecture_decision/project_rule 做 entity relation。

Success:

- 多跳问题明显优于扁平检索，再考虑继续投入。

## Suggested implementation sequence

1. 先做 eval harness。没有评测，后续检索优化都是凭感觉。
2. 做 retrieval diagnostics 和 feedback UI。让用户能看见和纠正记忆行为。
3. 做 decay/reinforcement。成本低，能明显改善长期使用。
4. 做 temporal metadata/supersede。解决“当前事实 vs 旧事实”。
5. 做 entity/tag boost。先轻量实现，不上完整图。
6. 扩展 pinned blocks UI。第一版 pinned 层已把最重要的稳定事实从概率检索和普通注入区里拿出来。
7. 扩展 custom instructions 命中解释，并做 import/export、episodic memories。

## Do not adopt yet

- 云托管 dashboard、组织成员权限、Webhook：不符合当前本地优先目标。
- 完整知识图谱后端：收益未被当前产品场景证明，先做轻量 entities。
- 多模态记忆：ACP coding 客户端当前主要是文本和工具事件。
- 全自动记忆默认：与用户要求的可控、可解释目标冲突。
- 无审批的 agent 自主写 profile/block：风险高，先走 change request。
