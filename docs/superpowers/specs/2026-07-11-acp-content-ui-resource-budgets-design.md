# ACP 内容、媒体与界面资源预算设计

日期：2026-07-11

## 背景与目标

项目已经为 ACP transport、会话回放、tool call、初始化 capabilities/auth/agentInfo 建立了字节、数量、深度和生命周期上限，但普通 `session/update` 内容仍会在多个层级被重复复制和无界保留：

- text/thought chunk 在 `ChatController` 中通过 `+=` 反复复制，单轮累计没有上限。
- image/audio/resource blob 在 Base64 解码前没有压缩大小预算；图片没有尺寸、像素和实际预览解码预算。
- content、plan、diff、commands、config options、choices、modes 和 metadata 会在 parser、client、controller 与 UI 之间多次 `map/toList/jsonEncode`。
- diff、plan、commands、配置和会话 metadata 的子列表会被一次性构建；折叠状态也可能先完整编码数据。
- 时间线虽然只显示末尾消息，仍会在内存中保留全部消息和 session snapshots，并在 build 时递归扫描 metadata。

本设计关闭初始安全复审中的远端命令目录、Markdown/消息总量、session metadata 渲染、plan、diff、session settings 和远端图片解码等资源放大路径。正常范围内的 ACP 消息保持原有行为；超限输入必须在最早拥有语义的边界处理，不能等到完整复制、解码或布局以后再截断。

Mermaid/SVG normalizer、权限历史、任务事件、artifact、skill、terminal 和 FS provider 不属于本设计，分别使用后续独立设计。

## 方案比较

### 方案一：所有 update 使用统一 JSON guard，任一超限终止整轮

优点是规则简单、实现集中。缺点是一张坏图片或一段过长 thought 会终止整个 prompt，无法区分展示内容与可操作状态，也会把可恢复的显示问题扩大为协议失败。

### 方案二：协议语义预算、controller 累计预算和 UI 解码预算分层实施

这是选定方案。

- owning parser 在任何 `cast/map/toList/base64Decode/split` 前限制单字段结构、集合和媒体。
- `SessionManager` 与 `ChatController` 分别限制受信 transport 路径和 Fake/第三方 client 路径的每 turn、每 session 与全局驻留状态。
- UI 只接收已经有界的数据，图片异步读取 header、按目标像素降采样，嵌套列表按 viewport 惰性构建。

优点是在最早语义边界阻断资源放大，同时允许 display-only 内容带明确标记继续。代价是需要统一的截断/省略状态和跨层累计计数。

### 方案三：只在 ChatController 或 UI 截断

改动最少，但 parser、replay、raw protocol capture 和 observer 已经完成分配；图片 decode bomb 和后台 client 也能绕过 UI，因此不能满足目标。

## 总体架构

数据按以下顺序处理：

1. transport 已有 frame/body/line 字节上限。
2. `JsonRpcPeer` 将原始 update 交给 `SessionManager`，不做无界预复制。
3. owning model parser 使用 `AcpInputBudget` 检查集合、metadata、字符串和 Base64；结果是有界 typed model 或固定本地 omission 状态。
4. `SessionManager` 对同一 session 的当前 turn 累计 text、thought 和 decoded media bytes，并在 replay/raw capture 前应用预算。
5. `DartAcpAgentClient` 只映射有界 typed model，不再保存重复的无界 raw payload；行为字段以原子方式更新缓存。
6. `ChatController` 对所有 `AcpAgentClient` 实现再次应用 turn、timeline 和 snapshots 预算，防止 Fake/注入 client 绕过协议层。
7. UI 不再同步解码未验证图片或完整编码 metadata；所有子列表使用有界、惰性的 builder。

任何安全关键或可操作字段都不能静默保留前缀。只有纯展示内容允许带明确状态的截断或省略。

## 统一预算

在现有 `AcpInputBudget` 上增加以下可选命名字段，并由 `validate()` 在 debug/release 中统一校验正数和相互关系：

| 字段 | 默认值 | 作用域 |
|---|---:|---|
| `maxCollectionItems` | 1024 | 单个 content/diff/plan/command/config/options/modes 集合 |
| `maxMessageTextBytes` | 1 MiB | 每 session、每 turn 的展示文本与 resource text |
| `maxMessageTextLines` | 10,000 | 每 session、每 turn 的 Markdown/resource text 换行布局预算 |
| `maxThoughtTextBytes` | 512 KiB | 每 session、每 turn 的 thought |
| `maxEmbeddedMediaBytes` | 8 MiB | 每 session、每 turn 的 image/audio/resource blob decoded bytes 总和 |
| `maxImageDimension` | 8192 | 图片宽或高的单边上限 |
| `maxImagePixels` | 16,777,216 | 图片源像素上限 |
| `maxImagePreviewPixels` | 2,097,152 | UI 实际解码目标像素上限 |
| `maxTimelineItems` | 2000 | 每 session 保留的消息数 |
| `maxTimelineBytes` | 16 MiB | 每 session 保留的 text 与有界 metadata 估算总量 |
| `maxUiStateBytes` | 64 MiB | active session 与所有 inactive snapshots 的总量 |

现有 metadata 默认保持：深度 16、节点 8192、单容器 entries 1024、累计 UTF-8 bytes 512 KiB。集合中的所有 item 共用同一个 metadata guard，不能为每个 item 重新获得一份预算。

所有动态传入的预算必须在启动 transport、注册 handler 或创建 UI 状态前完成运行时校验。错误只包含资源名、limit 和 observedAtLeast，不包含被拒绝数据。

运行时校验还必须保证：`maxImagePreviewPixels <= maxImagePixels`、`maxTimelineBytes <= maxUiStateBytes`，并且所有数值都能安全参与加法、除法和 Base64 上限推导，不能通过整数溢出绕过限制。

### 保留状态字节估算

timeline 与 snapshots 使用同一个确定性的 `AcpRetainedSizeEstimator`，计算实际保留表示的逻辑字节，而不是依赖 VM 对象布局：

- String 计实际增量 UTF-8 bytes。
- Base64 media 计被保留的 encoded String bytes；decoded bytes 由独立的 turn media 和 image preview budgets 约束，不在 controller state 中重复计数。
- int/double/bool/null 计其 JSON 表示 bytes。
- 每个 message/model/container 节点额外计 64 bytes，每个 list item 或 map entry 额外计 32 bytes。
- omitted/truncated marker 也按相同规则计入。
- estimator 与 guard 共用 cycle、depth、nodes 和字符串上限；不能为了估算先 `jsonEncode` 整个对象。

上述值是保守、跨平台且可精确测试的 retained-state 指标。UI 中短生命周期的 decoded image memory 由 `maxImagePreviewPixels` 和 widget dispose 约束，不算入 session snapshot bytes。

### 统一 omission 类型

`input_budget.dart` 增加不可变 `AcpInputOmission` 和固定枚举 `AcpInputOmissionReason`。typed models、`AgentEvent`、`ChatMessage` 和 UI 只传递这一种本地状态：

```text
reason: inputLimit | invalidEncoding | invalidImage | invalidStructure
resource: 固定资源名
limit/observedAtLeast: 只在容量失败时成对出现的数值
truncated: true 表示保留了安全前缀，false 表示整字段/整块省略
```

容量失败必须同时提供 `limit` 与 `observedAtLeast`；编码、图片或结构错误不伪造无意义数值。其 `toString()`/`toJson()` 只能包含上述固定字段。`UnknownContent` 需要 wire map 时由该类型生成，不允许各层自行拼接 marker key。外部 payload 即使包含相同字段，也必须先作为普通 untrusted input 经过 owning parser，不能直接构造受信 omission。

## 内容和状态语义

### text、thought 与 resource text

- 使用增量 UTF-8 计数器处理 chunk，按 UTF-8 边界保留可接受前缀。
- 同一遍扫描累计换行，达到 `maxMessageTextLines + 1` 时停止；不能先对完整文本调用 `split`。
- 空文本计 0 行；非空文本从 1 行开始，CR、LF、CRLF 均按一个逻辑换行计数，跨 chunk 的 CRLF 不能重复计数。
- 截断状态作为 typed marker/metadata 保存，不拼进 Markdown 正文，避免半截代码围栏改变渲染语义。
- 同一 turn、同一资源达到上限后继续 drain 后续 chunk，但丢弃其内容，只发布一次固定 marker。
- marker 使用 `AcpInputOmission(inputLimit, ..., truncated: true)`，只包含固定资源名和容量数值。
- turn 完成、取消、失败或 session close 时必须释放计数器。

### image、audio、resource blob 和未知内容块

- Base64 字符数、alphabet、padding 和 decoded bytes 在任何 decode 前检查。
- 非法 Base64、单块超限或 turn media aggregate 超限时，整块替换为本地 `UnknownContent` omitted marker；其他合法 content blocks 继续处理。
- omitted marker 不保存原始 Base64、MIME 参数、异常文本或 payload hash。
- audio 当前不做媒体解码，但其字符串仍按 decoded bytes 和 turn aggregate 计量。
- unknown content 的递归字段必须经过 metadata guard；不能原样保留未知 map。

本地 omitted marker 使用 `AcpInputOmission` 的固定结构：

```text
type: omitted
reason: input_limit | invalid_encoding | invalid_image
resource: 固定资源名
limit: 数值
observedAtLeast: 数值
```

该结构只由本地 parser 生成；外部输入中的同名字段仍作为普通 unknown content 重新经过 guard。

### diff

diff 是安全审阅数据，不能展示 partial changes。任一变化数量、行数、文本或 metadata 超限时：

- 保留经过单字符串预算的 id、uri 和 status。
- `changes` 整字段置空。
- typed model 设置 `truncated=true` 和固定 omission 数据。
- UI 显示“details omitted”状态，不显示部分 diff，也不沿用旧 diff。

字符串 diff 在 `split` 前按 UTF-8 bytes 和最大行数预检；扫描到第一个超限分隔符后停止，不能先产生完整行列表。

### plan

plan 是展示型状态，可保留预算内前缀，但必须在 typed model 上设置 `truncated=true` 和 observedAtLeast。UI 使用独立提示，不注入伪造的 plan entry。

### commands、config options、choices 和 modes

这些字段影响用户可执行操作，超限、非法类型或 metadata 超限时必须整字段 fail-closed：

- 新状态原子替换为空/不可用，并带固定 omission 状态。
- 不能保留前 N 项。
- 不能继续显示上一次的旧可操作列表。
- `DartAcpAgentClient` 只有在整个字段验证成功后才更新缓存和发布事件。

纯展示 `_meta` 超限时可整字段丢弃并标记；tool/raw 行为 metadata 超限时整 event/raw snapshot 拒绝，不保存部分值。

## Base64 和图片处理

Base64 parser 单遍扫描 code units：

- 只接受协议允许的标准 alphabet 和合法末尾 padding。
- 拒绝内部空白、非法字符和错误 padding。
- 通过 encoded length 与 padding 计算 exact decoded bytes。
- encoded 上限由 decoded 上限推导，达到 `limit + 1` 时立即停止。
- 单块和 turn aggregate 都通过后才调用 `base64Decode`。

图片 UI 改为持有明确生命周期的 stateful preview：

1. 从已验证且有界的 bytes 创建 `ui.ImmutableBuffer`。
2. 使用 `ui.ImageDescriptor.encoded` 读取 header。
3. 验证 width/height 大于零、单边不超过 8192；像素判断使用 `width > maxPixels ~/ height`，避免乘法溢出。
4. 超过 preview pixels 时按比例计算 target width/height，并用 target size 创建 codec。
5. 只解码首帧；generation token 防止旧异步结果回写新 widget。
6. widget 更新或销毁时释放 `ui.Image`、codec、descriptor 和 buffer。

header/codec 失败、源像素超限或状态过期时只显示固定 placeholder，不显示异常文本或 Base64。Widget `build()` 不允许执行 Base64 解码或图片解码；同一内容重建不得重复解码。

## SessionManager 与客户端接线

`SessionManager` 在 `_routeSessionUpdate` 的任何 `cast/map/toList/split` 前选择对应 owning parser，并维护 `_SessionTurnInputBudgetState`：

- text、thought、media 使用独立累计值。
- 计数状态只属于当前 active prompt turn。
- prompt 新建时原子替换，prompt 终态、cancel、close 和 dispose 全路径清理。
- replay 只保存已经有界的 typed update/marker，不保存被拒绝 payload。

`DartAcpAgentClient`：

- typed update 到 `AgentEvent` 的转换不再调用无界 `toJson/map/toList`。
- raw protocol capture 只读取明确需要且经过同一 guard 的字段；删除重复持有完整 session/tool metadata 的路径。
- commands/config/modes 缓存使用“验证临时副本 -> 成功后原子替换”模式。
- typed/raw 入口产生相同 marker 和失败语义。

所有 callback、日志和异常不得包含被拒绝 content、Base64、diff、command 或 metadata。

## ChatController 状态预算

协议层之外仍要防御其他 `AcpAgentClient` 实现。`ChatController` 增加可选命名 `inputBudget`，默认使用 `const AcpInputBudget()`。

### O(1) chunk 追加

`ChatMessage` 保留现有 `String text` getter/setter 兼容性，内部增加：

- chunk segments 或 `StringBuffer`。
- 已物化字符串缓存。
- UTF-8 byte count。
- monotonic revision。

controller 使用 `appendText`/`appendThought`，不再逐 chunk `+=`。通知按 microtask/frame 合并；turn done、status/tool boundary、session 切换和 dispose 前强制 flush。每批最多物化一次字符串，因此追加为摊销 O(1)，不会因微小 chunk 形成 O(n²) 复制。

### 时间线与 snapshots

- 每个 session 同时满足 `maxTimelineItems` 和 `maxTimelineBytes`。
- 超限时只淘汰最旧的完整 turn；当前 streaming turn 不淘汰。
- 首部最多保留一个本地 `history truncated` marker。
- inactive session snapshots 按 LRU 淘汰，直到 active + snapshots 不超过 `maxUiStateBytes`。
- active session 不整体淘汰；其单 turn 已受 text/thought/media 上限保护。
- Fake/注入 client 发出的 unbounded metadata 在进入 messages/snapshots 前重新 guard。

`_timelineMessagesSignature` 改为基于 message identity/revision 和列表 revision，不再递归排序、编码全部 metadata。

## UI 渲染

- 外层 `ChatTimeline` 保留现有 `ListView.separated`。
- content、plan、diff 和 command details 使用固定最大高度的 `ListView.separated(itemBuilder)`；禁止 `shrinkWrap:true` 迫使全量 layout。
- command/config choice chips 只直接展示小型首屏和“N more”；完整内容进入可搜索的 lazy panel。
- `SessionSettingsDialog` 使用 `CustomScrollView/SliverList`，Dropdown/Choice 数据只来自已验证集合。
- resume/session 列表使用可搜索 modal 与 `ListView.builder`，不为全部 session 构建 dropdown items。
- metadata preview 使用迭代 bounded writer，在字符和 UTF-8 预算处停止；禁止先完整 `JsonEncoder.withIndent` 再 substring。
- folded/collapsed 状态不得触发完整 metadata 编码。

## 错误处理与原子性

- display-only text/plan 可以明确截断；媒体 block 可以整块省略。
- diff details、commands、config/options/modes 和行为 metadata 只能整字段拒绝。
- 结构非法、cycle、非字符串 key、非有限数值和资源超限均使用固定 payload-free 错误/marker。
- 缓存、session settings 和 UI 状态只有在完整 guard 成功后原子替换。
- 失败不得保留 partial typed model、partial list、旧可操作状态或 rejected raw payload。
- 正常 update 不能因另一个独立 display block 被省略而中断整轮 prompt。

## 公共 API 与兼容性

- `AcpInputBudget`、factory、`DartAcpAgentClient` 和 `ChatController` 只增加 optional named 参数/字段。
- 不新增 `ContentBlock` 或 `AcpUpdate` sealed subtype；omitted content 使用现有 `UnknownContent`，避免外部 exhaustive switch 编译失败。
- `ChatMessage.text` 保持 String getter/setter 行为；buffer 和 revision 为内部实现。
- diff、plan、commands/settings 的 `truncated/omitted` 均为 optional、默认 false。
- 正常输入和已有默认 UI 行为不变。
- 明确行为变化仅发生在超限或非法远端输入：展示内容被标记截断/省略，可操作字段变为空并禁用。

## 实施边界与顺序

### A. 预算与基础原语

修改：

- `third_party/dart_acp/lib/src/input_budget.dart`
- `third_party/dart_acp/lib/dart_acp.dart`
- `test/acp/acp_agent_capabilities_test.dart`
- 新增 `test/acp/acp_input_budget_test.dart`

冻结预算字段、增量 UTF-8、Base64 scanner、collection/metadata guard 和固定 marker schema。

### B. Owning models

修改：

- `third_party/dart_acp/lib/src/models/content_types.dart`
- `third_party/dart_acp/lib/src/models/updates.dart`
- `third_party/dart_acp/lib/src/models/diff_types.dart`
- `third_party/dart_acp/lib/src/models/command_types.dart`
- `third_party/dart_acp/lib/src/models/session_types.dart`
- `third_party/dart_acp/lib/src/models/tool_types.dart`
- `test/acp/dart_acp_session_types_test.dart`

B 依赖 A 的预算和 marker 契约。

### C. 协议与客户端集成

修改：

- `third_party/dart_acp/lib/src/session/session_manager.dart`
- `lib/acp/dart_acp_agent_client.dart`
- `lib/acp/acp_session_settings.dart`
- `test/acp/dart_acp_agent_client_test.dart`

C 由单一 integration owner 完成，避免与其他 slice 同时修改 SessionManager/client。

### D. Controller 状态

修改：

- `lib/state/chat_controller.dart`
- `test/state/chat_controller_test.dart`

D 在 A 的 `AgentEvent` marker 契约冻结后可与 B 并行，最后由 C 接线。

### E. UI

修改：

- `lib/ui/components/chat_timeline.dart`
- `lib/ui/components/session_settings_dialog.dart`
- `lib/ui/components/resume_session_dialog.dart`
- `test/ui/chat_timeline_test.dart`
- `test/ui/session_settings_dialog_test.dart`
- `test/ui/resume_session_dialog_test.dart`

E 依赖 B 的 typed flags 和 D 的 message revision；三个 UI 文件可分别实施，但最终进行一轮跨层 widget 验证。

## 测试与验收

所有实现使用 RED -> GREEN -> REFACTOR，并覆盖 exact boundary 与第一个 rejected 值。

### 预算原语

- UTF-8 ASCII、2/3/4-byte、代理对和孤立 surrogate。
- Base64 alphabet、padding、decoded exact/+1、非法输入不调用 decoder。
- collection/metadata 跨 item 共享预算、cycle、非字符串 key、NaN/Infinity。
- marker/error `toString()` 不含 canary payload。

### Models 与协议

- 每种 content block 的单项和 aggregate 边界。
- diff changes/lines/bytes 超限时无 partial details。
- plan 截断明确；commands/config/modes 超限时整字段为空且旧状态被清除。
- SessionManager guard 发生在 `cast/map/toList/split` 前。
- per-turn counter 在 done/cancel/error/close/dispose 清理。
- raw/typed 入口语义一致，raw capture 不保留 secret canary。

### Controller

- 100,000 个微小 chunk 在定时上限内完成，结果顺序正确。
- UTF-8 和 Markdown lines exact/+1、marker 只出现一次、boundary 前强制 flush。
- FakeAgentClient 绕过时仍被限制。
- timeline item/bytes、inactive snapshot LRU、active turn 保留。
- message revision 替代递归 metadata signature。

### UI

- invalid/oversize Base64 不调用 decode。
- 图片 dimensions/pixels exact/+1、target downsample、首帧、generation race 和资源 dispose。
- rebuild 不重复解码。
- content/plan/diff/commands/settings/session 列表只构建 viewport 范围。
- bounded metadata preview 不调用 rejected payload 的 `toString()`，折叠状态不完整编码。
- omitted/truncated/disabled 状态可见，不能误显示为完整数据。

### 集成门禁

- 运行所有新增/受影响 tests、`dart analyze` 和 `git diff --check`。
- Task5 B 合并后重跑 Task4 transport/session 联合测试，确认预算接线没有破坏关闭、回放和 raw transport。
- 使用独立规范复审和独立代码质量复审；任一复审发现新问题时继续 RED/GREEN 迭代。

## 完成标准

Task5 B 只有同时满足以下条件才完成：

- 本设计列出的远端内容、媒体、集合、controller state 和 UI 渲染路径均在首次可能放大的边界应用预算。
- 安全关键列表没有 partial/旧状态回退；display-only 截断具有明确本地标记。
- rejected payload 不进入 replay、raw capture、messages、snapshots、缓存、日志或异常。
- 定向、跨层和回归测试通过，静态分析无问题。
- 独立规范复审与独立质量复审均批准，且没有新发现的同范围问题。
