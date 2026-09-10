# 会话加载架构

Updated: 2026-09-10. Source baseline: `b9297f5`.

## 范围与行为基线

本文维护当前恢复链路，核对依据为 [ChatController](../lib/state/chat_controller.dart)、[Rust 适配器](../lib/acp/rust_acp_agent_client.dart) 与 [Rust Core](../rust/crates/ianvs-acp-core/src/runtime.rs)。性能诊断和文末 2026-08-04 至 2026-08-10 的数字属于历史验收，不替代当前构建的桌面实测。当前没有协议历史分页或“先显示最近消息预览”的路径。

以下描述需向 Agent 恢复连接的路径；已有内存会话视图可直接激活，不重复请求回放。恢复期间的可见状态为：

1. 无缓存加载中：旧会话已经隐藏，消息区为空，只显示会话加载状态；
2. 精确版本缓存命中：一次通知显示完整缓存转录，连接状态可继续显示 loading；
3. 无缓存完整回放完成：原子显示已验证转录并移除 loading；
4. 缓存命中后的连接完成：移除 loading，时间线不替换。

如果 Agent 只支持 resume、不支持 load，客户端可以恢复连接，但无缓存时无法取回历史，消息区保持空白。这个降级不代表原会话没有历史。

因此不会先显示最新几条，再替换为完整会话，也不会显示正在回放的半成品历史。缓存命中时显示的是同一 `updatedAt` 对应的全部消息，而不是尾部预览。

## 历史性能诊断（2026-08）

目标 Codex rollout JSONL 约 510 MB、19,961 行，其中 104 行超过 1 MiB，最大单行约 13.9 MiB。大量 `compacted` 记录重复携带 replacement history。

旧链路耗时约 28–34 秒，但 Flutter 隐藏投影 CPU 只约 0.75 秒。主耗时发生在 Codex ACP adapter：

1. `session/load` 调用 app-server `thread/read(includeTurns:true)`；
2. app-server 读取并解析完整 rollout；
3. adapter 将完整 thread history 转换成约 5,207 个 `session/update`；
4. adapter 逐条等待 update 发出；
5. 本应用通过 stdio、Rust runtime 和 FFI 接收并投影。

结论：只优化 Flutter 列表或 FFI 轮询无法消除首次完整读取的 30 秒。真正可控的优化是减少桥接固定开销，并在会话版本未变化时避免再次请求完整历史。

## ACP 协议边界

| 能力 | 语义 | 历史回放 |
| --- | --- | --- |
| `session/load` | 从持久化状态重建会话 | 是 |
| `session/resume` | 重新连接一个已经存在的会话 | 否 |
| `session/list` | 返回会话身份和目录元数据 | 否 |

`session/list` 只在用户打开 `Resume Session` 后调用，用于手动选择要恢复的会话；应用启动、agent 配置变更、workspace 展开都不会触发全量会话扫描，也不会用扫描结果自动创建 workspace。

当前仓库使用的 ACP 恢复接口没有 history cursor、offset、tail window 或 limit。`session/load` 发出的 `session/update` 是完整回放流，不是可由客户端任意分页的接口。因此本应用不能在不改变 agent/app-server 协议的前提下伪造“只拉最近 50 条”。

Rust core 接收显式的 `replay_history`：

- `true` 且 agent 支持 load：调用 `session/load`；
- `false` 且 agent 支持 resume：调用 `session/resume`；
- `true` 但 agent 不支持 load、只支持 resume：调用 `session/resume`，返回 `replayedHistory=false`，无法补取历史；
- agent 不支持 resume：回退到 `session/load`，并返回 `replayedHistory=true`；
- 两者都不支持：返回可恢复的协议错误。

最终方法语义通过 `session_restored.payload.replayedHistory` 贯穿 Rust、FFI、Dart 和指标，UI 不根据事件数量猜测是否回放了历史。Dart 的 `restoreSession` 必须提供 `onEvent` 流式消费，返回值仅为 `AcpSessionRestoreSummary(eventCount, replayedHistory)`；每个请求独立生成摘要，并发恢复不共享上一请求的回放标记，也不返回第二份完整事件列表。

## Rust 渲染投影与 FFI 有界延迟传输

FFI ABI v10 不再把 ACP `session/update` 的通用 payload 交给 Dart
解释。Rust 将协议事件分成两类：

- `session_update`：仅保留会话生命周期、模式、配置、可用命令和权限失效等小型控制状态；
- `render_update`：只包含时间线真正消费的 user、assistant、thought、tool、plan 和 turn-completed 投影。

`available_commands_update` 会由 Rust 约束为 `CommandsChanged`，Dart 按会话缓存后通过
`AcpChatSession` 交给共享 composer，作为 slash-command 建议的数据源。`session/list`
返回的 `SessionInfo` 也会投影为有界目录条目，保留 session ID、cwd、additional
directories、title、`updatedAt` 和有界 metadata。

这两条路径不能与实时通知混为一谈：当前 Rust runtime 不投影 live session-info 或
usage update。ACP `_meta`、`annotations`、这些未消费通知以及其他未接入的实验事件不会跨
FFI；缺失 usage 保持缺失，不用零值代替。Tool 投影只允许
`toolCallId/title/kind/status/content/locations/rawInput/rawOutput`；
单个 raw input/output/location 字段超过 128 KiB、content 超过 512 KiB 时由 Rust 替换为有类型的
omission，而不是先传到 Dart 再扫描丢弃。

`session/load` 的通知在 Rust 内进入 replay projector：连续 assistant text 和 thought 在约 32 KiB
处分段，user 的文本与非文本 content block 合并为一个消息，同一回合相同 tool-call id
的 update 直接覆盖到一个工具投影。新的 user 消息到达后，前一回合已经不可再被后续通知修改；
Rust 将这些已封闭回合聚合到约 64 KiB 或最多 16 个 update，并在 adapter 继续发布剩余历史时
提前组成 `render_snapshot_chunk` 跨过 FFI。Dart 只把分块投影到隐藏 staging，仍然只有随后的
`session_restored` 才原子提交整份转录，因此增量传输不是可见分页，失败也可以整体回滚。
后台进程恢复产生但没有前台消费者的历史回放仍在 Rust 内直接丢弃。

批量拉取接口保持：

```text
ianvs_acp_poll_events(runtime, max_events, max_bytes, timeout_ms)
  -> { events: [...], hasMore: bool }
```

默认每批最多 32 个事件或 2 MiB，并在批内按 4 ms 投影时间片主动归还事件循环：

- Rust queue 保持事件所有权，Dart 没有请求的事件不跨 FFI；
- 若下一事件会超过字节预算，Rust 将其留在 `pending_event`，下一批再传；
- 单个超大事件允许作为该批第一项通过，避免永远无法前进；
- `hasMore=true` 时 Dart 在下一次 event-loop turn 拉取下一批；调用方仍可显式配置更长的批间 delay；
- `hasMore=false` 时才进入正常等待，避免空轮询；
- 每批只做一次 UTF-8/JSON 边界转换，减少 FFI 调用、isolate 启动和 JSON decoder 固定成本；
- 达到 128 KiB 的批次改在后台 isolate 做 JSON decode；
- 解码后的事件保持严格 sequence 顺序同步投影，每耗尽 4 ms 时间片才 yield，避免 2 MiB 大批次形成长 UI task。

这属于“有界、按需拉取”的传输延迟优化。它控制内存峰值和桥接调度，但不会把 ACP 完整回放变成协议分页。

## 版本化权威转录缓存

完整 `session/load` 成功后，controller 将已经按输入预算校验过的 `ChatMessage` 转录异步写入本地缓存。缓存身份由以下字段共同确定：

- `sessionPersistenceIdentity`（Agent 的稳定持久身份，缺省回退为名称）；
- session id；
- cwd；
- additional directories（顺序也必须相同）；
- `session/list.updatedAt`。

用户在目录中选定会话后，controller 用已取得的 `updatedAt` 读取缓存；缓存读取可与连接准备重叠，不会为了读取缓存另发一次并行 `session/list`：

```mermaid
flowchart TD
    S["选择会话"] --> H["隐藏消息区并显示 loading"]
    S --> C["读取版本化转录缓存"]
    C --> M{"身份与 updatedAt 完全匹配？"}
    M -->|"是，且 agent 支持 resume"| R["一次通知显示完整缓存转录"]
    R --> SR["后台 ACP session/resume，不回放历史"]
    SR --> A["移除 loading，时间线不替换"]
    M -->|"否或不支持 resume"| P{"Agent 支持 load？"}
    P -->|"是"| L["ACP session/load，隐藏投影完整回放"]
    L --> W["一次通知显示并异步更新缓存"]
    P -->|"否，仅支持 resume"| O["连接恢复；无历史回放，不写回放缓存"]
    P -->|"两者均不支持"| E["恢复失败，回滚 UI 状态"]
```

缓存不是最近一屏预览，也不是部分历史。它只在目录版本精确匹配且 agent 支持 resume 时使用；`updatedAt` 改变、身份不匹配、文件损坏、字段超出输入预算或 agent 不支持 resume，都会放弃缓存路径，并在 agent 支持 load 时回退完整 `session/load`；仅支持 resume 或两者均不支持时遵循上面的降级/报错规则。内部 client 接口不保留忽略 `replayHistory` 的旧兼容路径：实现必须在宣告支持 resume 时遵守 `replayHistory=false`。若实现最终仍报告 `replayedHistory!=false`，controller 会使恢复失败而不是混合缓存与意外回放。

缓存命中后的消息重建仍要执行角色、时间、omission 和 metadata 输入预算校验。历史验收样本的目标缓存约 30.9 MB（约 29.5 MiB），若在 UI isolate 一次完成会形成长帧。重建现在使用 4 ms 时间片：每次耗尽时间片就先归还事件循环，确认 session-operation generation 仍有效后继续；只有整份转录全部校验成功才一次安装到 `_messages`。因此“完整内容原子显示”和“加载过程可响应”同时成立。

文件缓存采用 schema version、稳定会话身份的 SHA-256 文件名、私有权限、跨进程锁和原子替换；`updatedAt` 只在文件内容中做版本校验，因此同一会话的新版本会覆盖旧文件，不会逐版本堆积。默认拒绝超过 2,000 条消息或 48 MiB 的缓存文件。JSON 编解码在 isolate 中执行。缓存读取失败不影响 ACP 正常恢复。存储目录、总容量和保留期的维护规则统一见[本地恢复存储](sqlite_storage.md)。

## 显示、隐藏与生命周期

controller 保留一个权威消息容器 `_messages`。`visibleMessages` 在无缓存且 `isSessionReplayLoading=true` 时固定返回空列表，即使 FFI 回放或其他无关状态触发 widget rebuild，也不会泄露半成品消息。只有精确版本的完整缓存安装完成后，私有可见门闩才允许 loading 期间显示整份转录。

加载顺序：

1. 生成新的 session-operation generation，使旧操作失效；
2. 清空旧会话可见状态，设置 loading 并通知 UI；
3. 等待缓存结果，命中时原子安装并显示完整转录；
4. 在缓存转录保持可见的同时执行 `session/resume`，或在空态下执行 `session/load`；
5. 回放事件只更新隐藏投影，不逐条 `notifyListeners`；
6. 收到 `session_restored` 后加载 settings；
7. 清除 loading；无缓存 load 在此时一次显示完整转录，缓存命中则不替换时间线；
8. 完整 load 成功时，在 UI 获得绘制机会后按 4 ms 时间片生成缓存快照，再交给 isolate 编码并原子写入，避免完成加载后又出现一段同步停顿。

切换会话或 dispose 后，迟到事件会被 generation 丢弃。恢复失败时，session、messages、settings、commands、快照和指标作为一个事务恢复到进入前状态。controller 仍保留可选 usage 状态的事务边界，但当前本地 Rust runtime 不会产生该状态。

连续 assistant text delta、分片 user content 和 tool update 已在 Rust replay projector 中合并；Dart controller 不再包含 ACP replay projector，也不再识别 `_acpUserChunk` 或 `agent_message_delta` 等协议形态。Dart 只做 ChatMessage 的最终输入预算准入和原子可见状态切换。大工具详情当前没有按 tool-call id 重新读取内容的 resolver，因此在 Rust 侧执行字段级上限和 omission 投影，而不是无界跨 FFI。

## 可观测性

每次真实恢复记录 `SessionLoadMetrics`：

- `cacheReadMs`、`cacheHit`、`cacheMessages`；
- `restoreMs`；
- `firstEventMs`、`eventSpanMs`；
- `projectionMs`；
- `totalMs`；
- `replayedHistory`、`replayEvents`。

Debug 构建对超过 100 ms 的加载输出一条 `[session-load]`。验收重点不是只看总时间，还要确认缓存命中时 `replayedHistory=false`、`replayEvents=0`。

## 验收标准

恢复链路应覆盖以下场景。文末历史自动化使用真实会话“拉取最新代码并运行”；复验需使用当前构建和可用样本，不能沿用历史耗时作为当次结果：

1. 首次无缓存打开时只显示 loading，不显示最新消息或半成品历史；
2. 首次完整 load 后一次显示完整会话并写入版本化缓存；
3. 重启应用后再次打开，同一 `updatedAt` 命中缓存并走 `session/resume`；
4. 第二次从空态一次显示完整缓存转录，后台 resume 不替换时间线；
5. 缓存命中的恢复时间显著低于首次约 30 秒；
6. tool/status 展开收起、轮次导航与基线滚动行为正常；
7. `updatedAt` 改变后不会使用旧缓存，而会回退完整 load。

### 2026-08-04 真实会话验收

电脑自动化从重建后的 macOS Debug 包打开“拉取最新代码并运行”：

| 项目 | 首次无缓存 | 同版本缓存命中 |
| --- | ---: | ---: |
| 目标转录 | 825 条消息 | 825 条消息 |
| 缓存文件 | 不存在 | 30,939,722 bytes |
| 约 0.8 秒时 | 仅 loading | — |
| 约 20 秒时 | 仍仅 loading，无最新消息泄露 | — |
| 完整转录首次可见 | 约 36.7 秒 | 约 2.2 秒 |
| 显示方式 | 完整 load 后一次显示 | 完整缓存一次显示 |

缓存命中后的可见时间缩短约 94%。最终时间线没有“最新消息 → 完整历史”的替换；工具聚合组的展开与收起也通过自动化交互验收。

### 2026-08-05 ABI v9 防卡顿复验

在 Rust 64 KiB/16-update 快照和 Dart 128 KiB/4-event 拉取预算下，重新构建 macOS Debug 包并从空白界面恢复同一会话：

| 项目 | 实测 |
| --- | ---: |
| 完整缓存原子可见 | 2.23 秒 |
| 历史区向上滚动一页动作 | 85 ms |
| 加载后侧栏搜索输入 | 14 ms |
| 历史可见性 | 滚动立即出现更早消息 |

首屏只出现一次完整转录，没有先挂载最新消息预览；后台 `session/resume` 没有替换时间线。加载完成后滚动和输入均保持响应。工具组展开后显示 3 条独立工具行，单条工具继续可展开 Kind/Call ID 详情，显示/隐藏语义未因传输裁剪而退化。

### 2026-08-10 无缓存客户端重叠复验

从同一份 486 MiB Codex rollout 和 SQLite 索引分别创建隔离 `CODEX_HOME`，使用相同的
Codex 0.147 与 codex-acp 1.1.14 恢复会话；未配置 transcript cache。三组都投影出
3,230 个 replay event 和 1,705 条消息，加载期间 `visibleMessages` 始终为空：

| Rust replay / Dart drain | 完整可见 | adapter 完成后的客户端尾段 | 投影 CPU |
| --- | ---: | ---: | ---: |
| 完成后统一快照 / 4 events、128 KiB、4 ms | 39.04 s | 5.66 s | 380 ms |
| 完成后统一快照 / 32 events、2 MiB、4 ms time slice | 35.28 s | 2.05 s | 350 ms |
| 已封闭回合增量快照 / 新 drain | 33.31 s | 与 adapter 发布重叠 | 352 ms |

相对旧客户端端到端减少 5.73 秒（14.7%）。增量版的 `eventSpan` 为 6.74 秒，是因为首批
回放在 adapter 完成前约 6.65 秒就开始进入隐藏 staging；它不代表 UI 多等待了 6.74 秒。
最终完整可见时间与 adapter 发布结束基本重合。剩余约 33 秒主要仍属于 Codex/adapter 的
rollout 读取和事件生成，客户端在不改协议、不使用应用层缓存的约束下已不再追加显著串行尾段。

## 当前回归入口

[controller 测试](../test/state/chat_controller_test.dart)覆盖缓存命中/失效、完整显示、失败回滚与会话边界；
[Rust 适配器测试](../test/acp/rust_acp_agent_client_test.dart)覆盖流式恢复与并发请求摘要隔离；
[新会话加载测试](../test/ui/new_session_loading_test.dart)覆盖创建阶段提示和未发送会话的侧栏可见性。
这些源码与测试是当前行为依据，历史性能表只描述各自的实测环境。
