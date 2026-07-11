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
| `maxStructuredUpdateNodes` | 8192 | 一个 structured update 的 typed fields 与 metadata 共享节点总量 |
| `maxStructuredUpdateBytes` | 1 MiB | 一个 structured update 的 typed fields 与 metadata 共享 UTF-8 总量 |
| `maxStructuredStringBytes` | 64 KiB | structured update 中任一字符串 |
| `maxMessageTextBytes` | 1 MiB | 每 session、每 turn 的展示文本与 resource text |
| `maxMessageTextLines` | 10,000 | 每 session、每 turn 的 Markdown/resource text 换行布局预算 |
| `maxMarkdownSyntaxTokens` | 4096 | 每条 Markdown 消息进入同步 parser/layout 前的语法工作预算 |
| `maxMarkdownFallbackBytes` | 64 KiB | Markdown 语法超限后的纯文本预览上限 |
| `maxThoughtTextBytes` | 512 KiB | 每 session、每 turn 的 thought |
| `maxEmbeddedMediaBytes` | 8 MiB | 每 session、每 turn 的 image/audio/resource blob decoded bytes 总和 |
| `maxImageDimension` | 8192 | 图片宽或高的单边上限 |
| `maxImagePixels` | 16,777,216 | 图片源像素上限 |
| `maxImagePreviewPixels` | 2,097,152 | UI 实际解码目标像素上限 |
| `maxConcurrentImageDecodes` | 2 | 全应用同时进行的图片 decode 数 |
| `maxImagePreviewPixelsGlobal` | 4,194,304 | 全应用已安装 preview image 的像素总量 |
| `maxImageDecodeBytesGlobal` | 32 MiB | 全应用 decode 中/已安装图片的保守内存 reservation |
| `maxTurnItems` | 512 | 当前 turn 新增的 message/tool/status/plan/diff 等状态项 |
| `maxTurnRetainedBytes` | 16 MiB | 当前 turn 的全部逻辑保留字节 |
| `maxTimelineItems` | 2000 | 每 session 保留的消息数 |
| `maxTimelineBytes` | 16 MiB | 每 session 保留的 text 与有界 metadata 估算总量 |
| `maxUiStateBytes` | 64 MiB | active session 与所有 inactive snapshots 的总量 |
| `maxMetadataPreviewBytes` | 16 KiB | session/command/tool metadata 文本预览 UTF-8 上限 |
| `maxMetadataPreviewChars` | 4096 | metadata 预览的 Unicode scalar 上限 |

现有 metadata 默认保持：深度 16、节点 8192、单容器 entries 1024、累计 UTF-8 bytes 512 KiB。每个 plan/diff/commands/config/modes/tool structured update 只创建一个根 guard；typed fields、所有嵌套集合和 metadata 同时消费 `maxStructuredUpdateNodes/maxStructuredUpdateBytes`，不能为父项、子项或 metadata 重新获得预算。单字符串先受 `maxStructuredStringBytes` 约束，再计入根总量。

所有动态传入的预算必须在启动 transport、注册 handler 或创建 UI 状态前完成运行时校验。错误只包含资源名、limit 和 observedAtLeast，不包含被拒绝数据。

运行时校验还必须保证：`maxImagePreviewPixels <= maxImagePixels`、`maxImagePreviewPixels <= maxImagePreviewPixelsGlobal`、`maxEmbeddedMediaBytes + maxImagePreviewPixels * 4 <= maxImageDecodeBytesGlobal`、`maxMarkdownFallbackBytes <= maxMessageTextBytes`、`maxTurnRetainedBytes <= maxTimelineBytes <= maxUiStateBytes`，并且所有数值都能安全参与加法、乘四、除法和 Base64 上限推导，不能通过整数溢出绕过限制。

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

传递方式使用加法式 typed 字段，不把 Dart 对象塞入现有 JSON metadata：

- `AgentEvent` 增加 optional `List<AcpInputOmission> omissions = const []`。
- `ChatMessage` 暴露只读 omissions，并由内部 `addOmission` 按 `resource + reason` 去重；总数受 `maxCollectionItems` 限制。
- `UnknownContent` 增加只读 optional `AcpInputOmission? omission`；远端 unknown payload 只能填 `data`，只有 owning parser 能设置 omission。`toJson()` 可生成兼容 map，但 app client 必须读取 typed `omission`，不能从 map 反推可信状态。
- `Plan`、`Diff` 和 `AcpSessionSettings` 增加 optional omission/truncated 状态，默认保持空/false。
- `AcpSessionEntry` 增加 optional `metaOmission`，session list UI 不从远端同名 metadata 推断省略状态。
- TaskRunner、持久化和普通 metadata 只接收 `omission.toJson()` 的安全副本；typed trust 身份不依赖可伪造的 map key。

## 内容和状态语义

### text、thought 与 resource text

- 使用增量 UTF-8 计数器处理 chunk，按 UTF-8 边界保留可接受前缀。
- 同一遍扫描累计换行，达到 `maxMessageTextLines + 1` 时停止；不能先对完整文本调用 `split`。
- 空文本计 0 行；非空文本从 1 行开始，CR、LF、CRLF 均按一个逻辑换行计数，跨 chunk 的 CRLF 不能重复计数。
- 在交给 `MarkdownBody` 前单遍统计 block markers、每个 delimiter code unit、link/image delimiters、table separators 和 inline HTML openers；达到 `maxMarkdownSyntaxTokens + 1` 时停止并改用最多 `maxMarkdownFallbackBytes` 的纯文本预览。scanner 不构造 AST、不使用回溯正则，也不保留 token 内容。
- 截断状态通过 typed omission 字段保存，不塞入普通 metadata，也不拼进 Markdown 正文，避免半截代码围栏改变渲染语义。
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

字符串 diff 在 `split` 前按 UTF-8 bytes 和最大行数预检；raw diff 共用 `maxMetadataBytes=512 KiB`，行数共用 `maxCollectionItems=1024`。扫描到第一个超限分隔符后停止，不能先产生完整行列表。

### plan

plan 是展示型状态，可保留预算内前缀，但必须在 typed model 上设置 `truncated=true` 和 observedAtLeast。UI 使用独立提示，不注入伪造的 plan entry。

### commands、config options、choices 和 modes

这些字段影响用户可执行操作，超限、非法类型或 metadata 超限时必须整字段 fail-closed：

- 新状态原子替换为空/不可用，并带固定 omission 状态。
- 不能保留前 N 项。
- 不能继续显示上一次的旧可操作列表。
- `DartAcpAgentClient` 只有在整个字段验证成功后才更新缓存和发布事件。
- owning parser 先保证 command name/description/parameters 与总列表有界。`PromptInput` 在 commands 列表 identity/revision 变化时一次性构建内部 `_CommandSearchEntry`（原 command 引用、invocation、预小写 name/description）；每次键入只扫描最多 1024 个短 search entries，不重新 lower-case，也不编码 parameters。search entry 不进入 wire model、metadata 或持久化。
- command parameters 的预览使用迭代 bounded writer；禁止先完整 pretty-print 再 substring。

纯展示 `_meta` 超限时可整字段丢弃并标记；tool/raw 行为 metadata 超限时整 event/raw snapshot 拒绝，不保存部分值。

## Base64 和图片处理

Base64 parser 单遍扫描 code units：

- 只接受协议允许的标准 alphabet 和合法末尾 padding。
- 拒绝内部空白、非法字符和错误 padding。
- 通过 encoded length 与 padding 计算 exact decoded bytes。
- encoded 上限由 decoded 上限推导，达到 `limit + 1` 时立即停止。
- 单块和 turn aggregate 都通过后才调用 `base64Decode`。

所有 timeline 共享 application-owned `AcpImageDecodeBudgetLedger`；tests 可注入独立 ledger。开始 decode 前同时取得：

- `maxConcurrentImageDecodes` 的并发 lease。
- `decodedBytes + maxImagePreviewPixels * 4` 的 provisional memory lease，并先预留 `maxImagePreviewPixels`；header 得到实际 target 后只允许向下缩减 lease，绝不在已经分配后追加未预留额度。

排队期间 generation 失效会取消 waiter；并发 lease 在 decode 终态释放，memory lease 一直持有到已安装 image 被替换或 dispose。这样多个 controller/widget 不能分别获得一份全局图片预算。

图片 UI 改为逐阶段 ownership 明确的 stateful preview：

1. Base64 预检和 ledger reservation 全部成功后才产生 decoded bytes。
2. `ui.ImmutableBuffer.fromUint8List` 成功后由当前 generation state 持有；descriptor 创建失败仍必须 dispose buffer。
3. `ui.ImageDescriptor.encoded` 成功后读取 header，验证 width/height 大于零、单边不超过 8192；像素判断使用 `width > maxPixels ~/ height`，避免乘法溢出。
4. target width/height 按比例计算并 clamp 到至少 1；创建 codec 后在 `finally` dispose descriptor 和 buffer。
5. `getNextFrame` 只取首帧；成功或失败都 dispose codec。
6. 每个 await 后先比较 generation。过期 frame 立即 dispose 新 image；安装新 image 前先 dispose 旧 image 并归还旧 memory lease。
7. widget update/dispose 取消 waiter、递增 generation，并 exactly-once 释放当前 buffer、descriptor、codec、image、concurrency lease 和 memory lease。

header/codec 失败、源像素超限或状态过期时只显示固定 placeholder，不显示异常文本或 Base64。Widget `build()` 不允许执行 Base64 解码或图片解码；同一内容重建不得重复解码。

为验证“超限前不解码”和完整 dispose，图片组件依赖内部 `BoundedImageDecoder` 接口；生产实现使用上述 Flutter `ui` 流程，widget tests 注入能在 buffer、descriptor、codec、frame 每个阶段失败或暂停的 fake decoder。测试逐个 await 点触发 stale generation，并断言所有资源和 lease exactly once 释放。该接口和 ledger 不进入 ACP 公共模型。

## SessionManager 与客户端接线

`SessionManager` 在 `_routeSessionUpdate` 的任何 `cast/map/toList/split` 前选择对应 owning parser，并维护带 owner token 的 `_SessionInputBudgetPhase`：

- `beginPromptTurn(sessionId)` 返回不可伪造 token；同一 session 已有 prompt/load/setup phase 时明确拒绝并发 prompt，因为 update 只有 sessionId，无法安全归属两个重叠 turn。
- `endPromptTurn/cancel` 必须提供相同 token；旧 token 或先结束的另一操作不能清除新 phase。
- text、thought、media、turn items 和 retained bytes 都属于该 token。
- load/resume 对已知 session 在 RPC 前取得独立 phase token，并在成功、失败、cancel、close、dispose 的 `finally` 清理。
- new/fork 在 sessionId 尚未知时只解析受同一个 request-scoped structured guard 约束的 response projection；未知 session 的抢先 update 保持 fail-closed 拒绝。得到并登记新 sessionId 后才能创建 session phase。
- replay/setup immediate fields 与普通 update 使用同一 phase/root budget，不能各自获得独立上限。
- prompt、load、resume、fork/new response 的所有 owner 在 close/dispose 时统一失效；late callback 只能丢弃有界结果，不能重建状态。
- replay 只保存已经有界的 typed update/omission，不保存被拒绝 payload。

`SessionManager`/`AcpClient` 额外发布只包含有界 typed model 的 `AcpBoundedObservation`，用于 app 层获得 session result、commands/config/modes 和 tool projection。每个 observation 由 owning parser 在原 phase/root guard 内创建，引用同一个不可变 typed model，不能在 observer 侧重新 guard 或深拷贝 raw map。

observation 契约固定为新建的独立 sealed family，不修改现有 `AcpUpdate` family：

- `AcpBoundedSessionResultObservation(operation, sessionId, SessionResult result)`，operation 只允许 new/load/resume/fork。
- `AcpBoundedUpdateObservation(sessionId, AcpUpdate update)`。

两个 variant 的 result/update 都必须是 owning parser 已完成不可变复制的实例；不得提供 `Object? raw`、原始 JSON getter 或 `toJson` 后的第二份 map。

observation 使用同步 listener registry，不使用会因 paused subscriber 累积事件的 `StreamController`，也不提供 replay。无 listener 时立即丢弃；listener 异常被固定日志隔离，不能阻断 session routing。`DartAcpAgentClient` 在 initialize/session 请求前注册，并在 dispose 时注销。

`DartAcpAgentClient`：

- typed update 到 `AgentEvent` 的转换不再调用无界 `toJson/map/toList`。
- 删除内部 raw protocol JSON 重解析和 `_rawSessionResultCapture` 一类完整 payload retention；改为消费 `AcpBoundedObservation`。
- transport 的 `onProtocolIn` 仅保留为受信 host 可选诊断 hook；Ianvs 内部不从该 String 解析业务状态、不把它写入 replay/cache/messages。
- commands/config/modes 缓存使用“验证临时副本 -> 成功后原子替换”模式。
- typed/raw API 都由 SessionManager owning parser 产生相同 omission 和失败语义，不存在 app 层第二套 raw parser。

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

`text` 改为 source-compatible getter/setter：setter 会重置私有 buffer、重新计量并递增 revision；append 同样递增 revision。metadata 在构造时必须先 guard，再保存不可变深拷贝。`ChatMessage.freeze()` 物化 text 并返回不共享 buffer、metadata、omissions 的不可变副本；`thaw()` 为重新激活的 session 创建新的可变副本。

`_SessionViewSnapshot` 和 `ArchivedSessionSnapshot` 只能保存 frozen messages、不可变 commands/settings 和确定的 retained-size，不能使用 `List.from` 复用 active `ChatMessage` 对象。恢复 snapshot 时使用 thaw/copy，后续 active append 不能反向修改 snapshot 或 archive。

### 时间线与 snapshots

- 当前 turn 同时满足 `maxTurnItems` 和 `maxTurnRetainedBytes`；text/thought/media 的专用上限不能替代这个根总量。
- 计数包含 message、tool/status lifecycle、plan/diff/command/settings marker 和其 retained-size；对同一 tool/status 的原地更新不重复计 item，但重新计算 byte delta。
- 达界后 display-only delta 丢弃并只保留一个 turn-overflow omission；行为列表整字段 fail-closed。tool/status 终态优先合并到已有同 ID message；没有可合并项时使用预留的一个固定 lifecycle-overflow marker，不保留 payload。
- `maxTurnItems` 的最后一个槽和 retained bytes 中固定 1 KiB 只供 overflow/lifecycle marker 使用，普通内容不能消费该保留量。
- 每个 session 同时满足 `maxTimelineItems` 和 `maxTimelineBytes`。
- 超限时只淘汰最旧的完整 turn；当前 streaming turn 不淘汰。
- 首部最多保留一个本地 `history truncated` marker。
- inactive session snapshots 按 LRU 淘汰，直到 active + snapshots 不超过 `maxUiStateBytes`；touch 必须 remove+reinsert 或更新显式单调序号，不能依赖 Map 覆盖保持顺序。
- active session 不整体淘汰；其当前 turn 已受专用预算和 turn 根预算共同保护。
- Fake/注入 client 发出的 unbounded metadata 在进入 messages/snapshots 前重新 guard。

`maxUiStateBytes` 的 owner 是单个 `ChatController`，并覆盖 active state、`_SessionViewSnapshot` 以及该 controller 已签发但尚未 restore/discard 的 `ArchivedSessionSnapshot`。archive 时 bytes 从 active/snapshot 账本转移到 snapshot lease；`restoreArchivedSessionLocally` 消费 lease，Snackbar 关闭或撤销窗口失效时必须显式 `discard()` 释放 lease。lease 未释放只会占满固定额度并阻止继续 archive，不能让状态无界增长。

`_timelineMessagesSignature` 改为基于 message identity/revision 和列表 revision，不再递归排序、编码全部 metadata。

## UI 渲染

- 外层 `ChatTimeline` 保留现有 `ListView.separated`。
- content、plan、diff 和 command details 使用固定最大高度的 `ListView.separated(itemBuilder)`；禁止 `shrinkWrap:true` 迫使全量 layout。
- command/config choice chips 只直接展示小型首屏和“N more”；完整内容进入可搜索的 lazy panel。
- command autocomplete 保持现有最多 5 个匹配项；过滤只使用 `PromptInput` 缓存的 search entries。
- `SessionSettingsDialog` 使用 `CustomScrollView/SliverList`，Dropdown/Choice 数据只来自已验证集合。
- resume/session 列表使用可搜索 modal 与 `ListView.builder`，不为全部 session 构建 dropdown items。
- metadata preview 使用迭代 bounded writer，在 `maxMetadataPreviewChars` 或 `maxMetadataPreviewBytes` 第一个边界处停止并附本地 omission；禁止先完整 `JsonEncoder.withIndent` 再 substring。
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
- `third_party/dart_acp/lib/src/acp_client.dart`
- `third_party/dart_acp/lib/dart_acp.dart`
- 新增 `third_party/dart_acp/lib/src/models/bounded_observation.dart`
- `lib/acp/dart_acp_agent_client.dart`
- `lib/acp/agent_event.dart`
- `lib/acp/acp_session_catalog.dart`
- `lib/acp/acp_session_settings.dart`
- `test/acp/dart_acp_agent_client_test.dart`

C 由单一 integration owner 完成，避免与其他 slice 同时修改 SessionManager/client。

### D. Controller 状态

修改：

- `lib/state/chat_controller.dart`
- `lib/app.dart`（archive snapshot lease restore/discard）
- `test/state/chat_controller_test.dart`
- `test/ui/acp_client_app_test.dart`

D 依赖 C 完成 `AgentEvent`/catalog 的 typed carrier 和 bounded observation API；不与 C 并行修改 app carrier。

### E. UI

修改：

- `lib/ui/components/chat_timeline.dart`
- 新增 `lib/ui/components/bounded_image_preview.dart`
- 新增 `lib/ui/image_decode_budget.dart`
- 新增 `lib/ui/markdown_render_budget.dart`
- `lib/ui/components/prompt_input.dart`
- `lib/ui/components/session_settings_dialog.dart`
- `lib/ui/components/resume_session_dialog.dart`
- `lib/app.dart`（创建并向 timeline 传递 application-owned image ledger）
- `test/ui/chat_timeline_test.dart`
- 新增 `test/ui/image_decode_budget_test.dart`
- 新增 `test/ui/markdown_render_budget_test.dart`
- `test/ui/prompt_input_test.dart`
- `test/ui/session_settings_dialog_test.dart`
- `test/ui/resume_session_dialog_test.dart`

E 依赖 B 的 typed flags 和 D 的 message revision；三个 UI 文件可分别实施，但最终进行一轮跨层 widget 验证。

## 测试与验收

所有实现使用 RED -> GREEN -> REFACTOR，并覆盖 exact boundary 与第一个 rejected 值。

### 预算原语

- UTF-8 ASCII、2/3/4-byte、代理对和孤立 surrogate。
- Base64 alphabet、padding、decoded exact/+1、非法输入不调用 decoder。
- collection/metadata 跨 item 共享预算、cycle、非字符串 key、NaN/Infinity。
- structured update 的 typed fields、嵌套集合和 metadata 共享 nodes/bytes；父子集合乘法在根 exact/+1 处拒绝。
- 单 structured string、metadata preview chars/bytes 和所有新增动态 budget 的运行时验证。
- marker/error `toString()` 不含 canary payload。

### Models 与协议

- 每种 content block 的单项和 aggregate 边界。
- diff changes/lines/bytes 超限时无 partial details。
- plan 截断明确；commands/config/modes 超限时整字段为空且旧状态被清除。
- SessionManager guard 发生在 `cast/map/toList/split` 前。
- 同 session 重叠 prompt 被拒绝；stale owner 不能清理新 phase；prompt/load/resume token 在 done/cancel/error/close/dispose 清理。
- new/fork response、load/replay immediate update 与普通 update 共用 phase/root budget。
- `AcpBoundedObservation` 不携带 raw map；内部 `onProtocolIn` 不再被业务重解析，secret canary 不进入 capture/cache。
- `UnknownContent.omission`、`AgentEvent.omissions` 和 `AcpSessionEntry.metaOmission` 保留 typed trust，远端伪造同名 map 不能获得本地 omission 身份。

### Controller

- 100,000 个微小 chunk 在定时上限内完成，结果顺序正确。
- UTF-8 和 Markdown lines exact/+1、marker 只出现一次、boundary 前强制 flush。
- Markdown syntax token exact/+1；超限消息不进入 Markdown parser，而以有界纯文本展示。
- FakeAgentClient 绕过时仍被限制。
- 当前 turn items/retained bytes exact/+1；overflow marker 使用保留槽，tool/status 终态可合并且不保留 payload。
- timeline item/bytes、inactive snapshot LRU、active turn 保留。
- snapshot freeze/thaw 不共享 ChatMessage buffer/metadata；active append 不改变 inactive/archive；archive lease restore/discard 后正确归还。
- message revision 替代递归 metadata signature。

### UI

- invalid/oversize Base64 不调用 decode。
- 图片 dimensions/pixels exact/+1、target downsample、首帧、generation race 和资源 dispose。
- 两个并发 decode/全局 pixels/bytes exact 通过，第一个超限请求排队或拒绝；取消 waiter、逐阶段异常和 stale generation 全部归还 ledger。
- rebuild 不重复解码。
- content/plan/diff/commands/settings/session 列表只构建 viewport 范围。
- command 搜索不在每次键入时重新 lower-case 或 pretty-print parameters，且保持只构建前 5 个结果。
- bounded metadata preview 不调用 rejected payload 的 `toString()`，折叠状态不完整编码。
- metadata preview chars/UTF-8 bytes exact/+1，超限输出自身也不超过两个边界。
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
