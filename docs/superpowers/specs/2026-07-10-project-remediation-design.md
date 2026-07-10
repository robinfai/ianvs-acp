# 全项目问题整改设计

日期：2026-07-10

## 背景

本项目已完成一次覆盖 Flutter 主程序、内置 `dart_acp`、任务自动化、配置、macOS 工程和测试体系的完整评审。评审确认 21 项问题，其中包括权限拒绝被错误映射为允许、Workspace 符号链接越界、后台任务与交互会话串用、任务状态非事务保存、ACP terminal 响应不兼容、凭据明文保存和正式分发配置不完整。

本次整改不是逐项增加局部判断，而是建立能够长期阻止同类问题复发的边界：权限决定必须端到端保真，取消状态必须属于单轮请求，文件和进程能力必须受可证明的边界约束，后台任务必须独立执行且由数据库原子认领，用户数据迁移必须无损，发布制品必须可验证。

## 目标与完成标准

整改完成必须同时满足以下条件：

- 已确认的 21 项问题均有对应实现、回归测试和验证证据。
- 现有 `task_inbox_state.json` 中的任务、运行、事件、产物和审批记录可无损迁移到事务式 SQLite。
- 迁移失败时保留原始 JSON，不启动任务调度，不把损坏数据当作空状态覆盖。
- 同一个任务在多个应用窗口或进程中最多只能被一个 worker 认领。
- 权限、文件、terminal、远程连接和外部 deep link 的安全边界在默认配置下成立。
- `flutter analyze`、全量 Flutter 测试、macOS release build 和制品结构检查全部通过。
- 完成修复后重新执行全项目评审；发现新问题时继续测试先行修复，直到评审范围内没有未解决的 P0、P1、P2 或 P3 问题。

## 范围

本次覆盖：

- `lib/` 中的应用、ACP transport、任务自动化、配置、状态和界面代码。
- `third_party/dart_acp/` 中项目实际使用的 ACP provider、session 和 transport 实现。
- `test/` 中的单元、组件和集成边界测试。
- `macos/` 中的 bundle、deep link、签名和构建脚本。
- 与上述行为直接相关的 README、设计说明和 CI 配置。

缓存、构建输出、`.worktrees` 和没有源码的生成目录不属于整改对象。第三方服务运行状态不作为“代码无问题”的证明；最终复审需要另外检查锁定依赖的最新官方安全公告，并记录联网扫描证据。

## 总体方案

整改分四批完成，每批使用独立实施计划，并且都能独立运行定向测试、全量测试和静态分析。前一批保持通过后才进入下一批。

1. 协议和权限安全边界。
2. 任务执行与事务式持久化。
3. 本地隐私、远程连接和外部入口。
4. 发布、测试隔离和最终复审。

所有行为修改采用测试先行：先增加能够稳定复现问题的失败测试，确认失败原因正确，再修改生产代码并运行定向及全量验证。

## 第一批：协议和权限安全边界

### 权限选项端到端保真

权限请求不再把 ACP option 降级成纯文本列表。内部模型必须保留 `optionId`、`name` 和 `kind`，界面展示代理实际提供的选项，并把用户选中的具体 option 原样返回。

如果界面仍提供统一的“允许/拒绝”快捷操作，只能映射到同类 kind：允许只能匹配 `allow_once`、`allow_always` 等允许项，拒绝只能匹配 `reject_once`、`reject_always` 等拒绝项。没有同类选项时返回 `cancelled`，绝不能回退到唯一的相反选项。

默认权限策略改为人工确认。同源 ACP sidecar 的审查结果只能作为建议展示，不能自动批准自身提出的能力请求。只有用户显式配置的独立 reviewer，且本地规则和 reviewer 都判定为低风险允许时，才可以自动执行。未知 terminal 命令默认进入人工确认。

### 单轮取消生命周期

取消状态从“session 集合”改为“prompt turn 状态”。每次 prompt 开始时创建独立 turn 标识；取消只影响当前 turn 的 pending RPC 和权限请求，并在成功、失败、取消、transport 断开等所有终态清理。

raw prompt 和 typed prompt 必须经过同一生命周期入口，不能再由其中一条路径独占清理逻辑。第二轮 prompt 不得继承第一轮的取消状态。

### Workspace 文件边界

路径判断采用“解析最深已存在祖先，再逐段验证剩余路径”的方式。每一段使用不跟随符号链接的元数据检查；任何无法证明位于允许根目录内的路径都拒绝。

创建目录和打开文件之前再次校验已解析路径，避免校验后替换符号链接的竞态。直接的工作区外绝对路径、符号链接后的缺失子目录、`..`、额外工作区根和大小写差异均要有测试。

### Terminal 与 transport 生命周期

Terminal create 保存请求的 `outputByteLimit`，未提供时使用 1 MiB 上限。输出使用有界字节缓冲区，从开头截断并保持字符边界。output/wait 响应使用当前 ACP v1 字段；release 必须终止仍运行的进程、等待退出、取消订阅，并从 session manager 和 provider 两层索引中删除 handle。SessionManager dispose 也必须释放所有 terminal。

stdio 子进程无论以 0 或非 0 退出，都要关闭 JSON-RPC 入站流并让全部 pending 请求失败。HTTP POST、首字节、SSE 空闲和单次 prompt 增加明确超时；SSE 在 prompt 进行中断开时进入错误或受控重连，不能无限 streaming。TaskRunner 具有任务总时限和取消入口。

## 第二批：任务执行与事务式持久化

### 独立后台执行上下文

后台任务不再复用界面当前的 `ChatController`。应用按 agent 配置创建专用后台 controller/transport；同一后台 controller 通过原子租约串行使用，不能切换或污染界面 session。

运行时状态区分 `available`、`busy`、`authRequired`、`offline` 和 `misconfigured`。`busy` 只让任务保持 queued，不创建 run、不消耗 retry。`newSession` 和 `sendPrompt` 返回明确结果，TaskRunner 必须验证新 session ID 和 prompt 已实际提交后才能继续。

### SQLite 数据模型

移除“单行 JSON payload”的 SQLite 方案，采用应用内 SQLite 连接和规范化表：

- `schema_migrations`：数据库版本和迁移记录。
- `tasks`：任务主体、状态、优先级、workspace、agent、资源和 metadata。
- `task_runs`：每次执行、attempt、session、模型、终态和错误。
- `task_events`：只追加的时间线事件。
- `artifacts`：产物索引、预览和来源 run。
- `approval_requests`：审批状态和结构化元数据。

数据库启用 WAL、`busy_timeout`、foreign keys 和事务。任务认领使用带状态条件的原子更新，只有 `queued -> running` 更新成功的进程可以创建 run 和启动 worker。其他修改按行更新，不再用旧快照覆盖整个数据库。

应用内 controller 仍提供只读 snapshot 给界面，但 snapshot 由 repository 查询结果构建。写方法通过 repository 事务执行并使用事务返回的最新记录更新内存。每个事务递增数据库 revision；前台窗口每秒检查一次 revision，任务调度前也必须检查，发现变化便重新查询，不允许用本地旧 snapshot 回写数据库。

### JSON 无损迁移

首次启动时如果 SQLite 尚未初始化且旧 JSON 存在：

1. 以只读方式完整解析 JSON，并验证所有 ID、引用关系、时间和枚举。
2. 计算原文件校验和，在单个数据库事务中导入全部记录。
3. 导入后从数据库重新读取并与标准化后的原快照逐项比较。
4. 提交事务并记录 JSON 校验和、迁移时间和记录数。
5. 原子地把原 JSON 改名为 `task_inbox_state.migrated.<yyyyMMddTHHmmssZ>.<校验和前12位>.json`，权限设为 `0400`；应用不自动删除该备份。只有改名和权限收紧成功后才把数据库标记为 active；否则调度保持停止并在下次启动重试收尾。

任何步骤失败都回滚数据库、保留原文件、向界面显示具体错误并禁止 scheduler 启动。禁止“解析失败视为空状态”的行为。

### 写入量和状态一致性

assistant 文本 delta 在当前消息内合并，事件每 200ms 或在 turn 终态刷入数据库。单条结构化 metadata 编码后最多 64 KiB，超出时保存截断标记和摘要。默认只保存 diff stat 和文件名；用户显式选择保存完整 diff 时，单个产物最多 1 MiB，原始 tool payload 和完整 diff 默认保留 30 天，任务、run、摘要和文件名保留到用户删除。界面提供立即清除原始 payload 的操作。

TaskInbox 只允许一个进行中的 load Future，初始化、恢复和调度严格串行。`serial:false` 明确表示跳过 workspace gate。Artifact ID 使用包含 task/run 的持久唯一 ID。认证阻塞任务重启后保持 `blockedOnUserInput`，认证成功后才重新排队。

## 第三批：本地隐私、远程连接和外部入口

### 凭据与状态文件

引入 `SecretStore` 抽象，macOS 实现使用 Keychain。Agent 和 MCP 的 env/header 值写入 Keychain，JSON 只保存稳定引用；运行时解析引用后再构建 transport。迁移旧明文配置时先成功写入 Keychain，再原子更新 JSON；任一步失败都保留旧配置且不删除秘密。

配置目录主动收紧为 `0700`，非秘密状态文件为 `0600`，写入使用同目录临时文件、flush 和原子替换。任务事件、tool metadata、Authorization、token、env value 和 diff preview 在持久化前经过结构化清洗，并提供过期和清除机制。

### 远程连接与 adapter

非 loopback ACP/MCP 地址只允许 `https` 和 `wss`。`http`、`ws` 仅允许 loopback，并在配置界面明确标识为本机明文连接。认证头不得通过非 loopback 明文连接发送。

自动发现的 npm adapter 使用项目维护的精确版本；发现结果记录版本，升级必须由用户明确触发。启动前验证实际版本，避免 `npx` 随时间运行不同代码。

### Deep link

外部 deep link 只解析为候选启动请求，不能直接连接。应用内确认页完整展示 agent、session 和 workspace；cwd 必须是存在的绝对路径，并拒绝 `/`、HOME 等过宽默认范围。未知 session 或未登记 workspace 需要额外确认，取消时不建立任何连接。

## 第四批：发布、测试隔离和最终复审

### macOS 正式分发

bundle identifier 改为正式的 `com.ianvs.acp`，保留本地 ad-hoc 构建和正式分发两条明确路径。正式分发从 CI/本地安全环境注入 Developer ID 和 Team ID，启用 Hardened Runtime、secure timestamp、notarize 和 staple。

二进制 install name 修正、架构检查和 nested signing 任一步失败都终止构建，禁止 `|| true`。构建后运行 `otool`、架构检查、`codesign --verify --deep --strict`；具备凭据的正式流水线还运行 `spctl --assess` 和公证票据检查。

### 测试隔离与稳定性

所有 App widget 测试必须注入内存或临时 TaskStore。测试入口把 HOME 和 XDG_CONFIG_HOME 指向临时目录，并增加守卫，禁止访问真实用户配置。

scheduler 的 clock、timer 和延迟由可注入接口控制，retry 顺序测试使用 fake clock，不依赖 50ms 墙钟。新增多进程数据库认领、迁移中断、transport 断流、terminal 大输出、符号链接和权限单选项测试。

### 最终复审循环

每批完成后检查代码差异、运行定向测试、全量 `flutter test` 和 `flutter analyze`。第四批完成后构建 macOS release，并重新执行与初次评审相同范围的架构、可靠性、安全和发布审查。

新发现的问题按同一流程处理：先证明根因和稳定复现，再写失败测试、实现最小修复、全量验证并复审。只有问题清单为空且所有验证命令通过时，整个目标才完成。

## 错误处理与回滚

- 数据迁移、Keychain 迁移和配置改写均采用“新状态完整可验证后再切换”的方式。
- 迁移后的原 JSON 备份由应用永久保留，只有用户明确执行删除操作才移除；应用不自动覆盖损坏来源。
- scheduler 初始化失败时保持停止状态，界面显示可复制的错误和恢复路径。
- transport、terminal 或 task 超时必须进入明确终态并释放资源，不允许只记录日志后继续等待。
- 每批代码保持可独立回退；数据库 schema 迁移只前进，不用破坏性降级覆盖用户数据。

## 问题到验收项映射

| 已确认问题 | 验收要求 |
|---|---|
| 拒绝被映射成允许 | 单 allow + 用户拒绝时绝不返回 allow ID；反向场景同样成立 |
| 取消污染后续权限 | 第一轮取消后，第二轮权限请求可正常显示和选择 |
| Workspace 符号链接越界 | 链接后的缺失路径写入被拒绝，工作区内普通新建仍成功 |
| 同源 reviewer 自动批准 | 默认人工；同源 allow 仍保持 pending |
| UI 与任务共用 controller | UI 忙碌不消耗 run；后台 session 不改变 UI session |
| JSON 非原子和多进程覆盖 | 损坏不视为空；双进程只认领一次且无丢更新 |
| 并发 load 覆盖状态 | 多次 start/load 只发生一次物理加载，恢复状态不回退 |
| delta 全量保存 | 10k delta 的写入批次数有上界，不随事件数平方增长 |
| stdio/SSE 断流挂起 | 在途请求在限定时间内失败并释放 scheduler 槽位 |
| terminal 协议和资源问题 | ACP v1 字段正确、输出有界、release 后进程和 handle 均消失 |
| 凭据和任务敏感数据明文 | JSON 无秘密，文件模式正确，敏感 metadata 被清洗 |
| `serial:false` 不运行 | 无锁任务在并发额度内正常启动 |
| 侧栏状态并发覆盖 | 并发保存后各字段均保留最新值，失败不破坏旧文件 |
| Artifact ID 重复 | 跨重启首个 artifact ID 不同，历史记录全部保留 |
| 认证阻塞重启变失败 | 重启后仍为 blocked，认证后可重新排队 |
| 远程明文连接 | 非 loopback HTTP/WS 配置被拒绝 |
| npm adapter 未固定 | 自动发现配置包含精确版本且升级需确认 |
| deep link 自动连接和 cwd | 确认前不连接，不安全 cwd 不采用 |
| 正式发布配置不完整 | 正式 bundle/sign/notarize 流程可验证，关键脚本不吞错 |
| 测试访问真实 HOME | 测试守卫证明真实配置路径未被访问 |
| retry 测试依赖墙钟 | fake clock 下确定性通过，无真实短时限轮询 |

## 已确认选择

- 采用四批递进整改，而不是在现有共享状态上逐项打补丁，也不整体替换 ACP 和任务层。
- 现有任务数据必须无损迁移；迁移失败时保留原文件、停止调度并明确报错。
- 每批使用测试先行并独立验收，最后完整复审并继续迭代到问题清单为空。
