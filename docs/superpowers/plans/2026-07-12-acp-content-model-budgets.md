# ACP 模型与基础预算实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 owning parser 首次可能放大输入的位置建立统一预算、固定省略类型、增量扫描器和有界 typed model。

**Architecture:** `AcpInputBudget` 是唯一配置入口；每个 structured update 只创建一个根 guard，typed fields、子集合与 metadata 共享 nodes/bytes。展示文本/plan 可保留安全前缀，媒体整块省略，diff details 和行为字段原子失败关闭。

**Tech Stack:** Dart、`third_party/dart_acp`、Flutter 单元测试。

---

### Task 1: 扩展预算并锁定运行时不变量

**Files:**
- Modify: `third_party/dart_acp/lib/src/input_budget.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Create: `test/acp/acp_input_budget_test.dart`
- Modify: `test/acp/acp_agent_capabilities_test.dart`

- [ ] 1. 写 RED：23 个新增默认值；每个值 0/-1 拒绝；preview/source/global、embedded+preview*4/global、fallback/message、turn/timeline/UI 的 exact 通过与 +1 拒绝；加法、乘四和 Base64 上限推导溢出安全。`maxTurnItems=1` 和 `maxTurnRetainedBytes=1024` 仍合法，表示普通内容可用额度为 0、额度只保留给 marker。
- [ ] 2. 运行并确认因命名参数不存在失败：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart
```

- [ ] 3. 增加规格表中的全部 immutable 字段和默认值；`validate()` 使用 release/runtime 检查，并用除法/上界比较避免先做溢出乘法。不得增加规格未批准的最小值；controller 将普通额度定义为 `max(0, limit - reserve)`，marker 自身仍必须计入总上限。

```dart
const AcpInputBudget({
  this.maxCollectionItems = 1024,
  this.maxStructuredUpdateNodes = 8192,
  this.maxStructuredUpdateBytes = 1024 * 1024,
  this.maxStructuredStringBytes = 64 * 1024,
  this.maxMessageTextBytes = 1024 * 1024,
  this.maxMessageTextLines = 10000,
  this.maxThoughtTextBytes = 512 * 1024,
  this.maxEmbeddedMediaBytes = 8 * 1024 * 1024,
  this.maxImageDimension = 8192,
  this.maxImagePixels = 16777216,
  this.maxImagePreviewPixels = 2097152,
  this.maxConcurrentImageDecodes = 2,
  this.maxImagePreviewPixelsGlobal = 4194304,
  this.maxImageDecodeBytesGlobal = 32 * 1024 * 1024,
  this.maxTurnItems = 512,
  this.maxTurnRetainedBytes = 16 * 1024 * 1024,
  this.maxTimelineItems = 2000,
  this.maxTimelineBytes = 16 * 1024 * 1024,
  this.maxUiStateBytes = 64 * 1024 * 1024,
  this.maxMarkdownSyntaxTokens = 4096,
  this.maxMarkdownFallbackBytes = 64 * 1024,
  this.maxMetadataPreviewBytes = 16 * 1024,
  this.maxMetadataPreviewChars = 4096,
});
```

- [ ] 4. 在 transport/handler/controller/UI owner 创建状态前调用 `validate()`；运行测试、格式化并提交。

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart test/acp/acp_agent_capabilities_test.dart
dart format third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/dart_acp.dart test/acp/acp_input_budget_test.dart test/acp/acp_agent_capabilities_test.dart
git add third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/dart_acp.dart test/acp/acp_input_budget_test.dart test/acp/acp_agent_capabilities_test.dart
git commit -m "feat: define ACP content resource budgets"
```

### Task 2: 固定 omission 契约

**Files:**
- Modify: `third_party/dart_acp/lib/src/input_budget.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `test/acp/acp_input_budget_test.dart`

- [ ] 1. 写 RED：四个 reason；inputLimit 必须成对含 limit/observedAtLeast；其他 reason 禁止容量值；`toString()/toJson()` 不含 canary。
- [ ] 2. 实现 runtime-validating factory 和固定 payload-free schema：

```dart
enum AcpInputOmissionReason {
  inputLimit,
  invalidEncoding,
  invalidImage,
  invalidStructure,
}

final class AcpInputOmission {
  factory AcpInputOmission({
    required AcpInputOmissionReason reason,
    required String resource,
    required bool truncated,
    int? limit,
    int? observedAtLeast,
  }) {
    if ((limit == null) != (observedAtLeast == null)) {
      throw ArgumentError('limit and observedAtLeast must be paired');
    }
    final hasCapacity = limit != null;
    if ((reason == AcpInputOmissionReason.inputLimit) != hasCapacity) {
      throw ArgumentError('invalid omission capacity fields');
    }
    return AcpInputOmission._(
      reason: reason,
      resource: resource,
      truncated: truncated,
      limit: limit,
      observedAtLeast: observedAtLeast,
    );
  }

  const AcpInputOmission._({
    required this.reason,
    required this.resource,
    required this.truncated,
    required this.limit,
    required this.observedAtLeast,
  });

  final AcpInputOmissionReason reason;
  final String resource;
  final bool truncated;
  final int? limit;
  final int? observedAtLeast;

  Map<String, Object?> toJson() => <String, Object?>{
    'reason': switch (reason) {
      AcpInputOmissionReason.inputLimit => 'input_limit',
      AcpInputOmissionReason.invalidEncoding => 'invalid_encoding',
      AcpInputOmissionReason.invalidImage => 'invalid_image',
      AcpInputOmissionReason.invalidStructure => 'invalid_structure',
    },
    'resource': resource,
    if (limit != null) 'limit': limit,
    if (observedAtLeast != null) 'observedAtLeast': observedAtLeast,
    'truncated': truncated,
  };
}
```

`toString()` 必须只格式化 `toJson()` 的固定字段。`UnknownContent.toJson()` 对本地 omission 生成 `{'type': 'omitted', ...omission.toJson()}`；远端同名 map 始终走普通 unknown guard，不能调用本地 omission constructor。

- [ ] 3. 导出类型；运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart
dart format third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/dart_acp.dart test/acp/acp_input_budget_test.dart
git add third_party/dart_acp/lib/src/input_budget.dart third_party/dart_acp/lib/dart_acp.dart test/acp/acp_input_budget_test.dart
git commit -m "feat: add typed ACP input omissions"
```

### Task 3: 增量 UTF-8/换行、Base64 和 retained estimator

**Files:**
- Modify: `third_party/dart_acp/lib/src/input_budget.dart`
- Modify: `test/acp/acp_input_budget_test.dart`

- [ ] 1. 写 RED：ASCII、2/3/4-byte、代理对/孤立 surrogate；空串 0 行、非空 1 行、CR/LF/CRLF 与跨 chunk CRLF exact/+1。
- [ ] 2. 写 RED：标准 Base64 alphabet、尾部 padding、内部空白/内部 padding、decoded exact/+1；用 fake decoder 证明非法或超限时从未 decode。
- [ ] 3. 写 RED：estimator 的 UTF-8 string、JSON scalar、node +64、entry/item +32、encoded media string、marker；cycle/depth/nodes/string 失败；证明不调用 `jsonEncode`。
- [ ] 4. 冻结并实现以下共享 API；`append` 不完整复制 chunk，`finish` 结算尾部 pending high surrogate/CR，返回的 safePrefix 永远停在 UTF-8 边界：

```dart
final class AcpTextBudgetChunk {
  const AcpTextBudgetChunk({
    required this.safePrefix,
    required this.acceptedBytes,
    required this.totalBytes,
    required this.totalLines,
    this.omission,
  });
  final String safePrefix;
  final int acceptedBytes;
  final int totalBytes;
  final int totalLines;
  final AcpInputOmission? omission;
}

final class AcpUtf8LineBudgetCounter {
  AcpUtf8LineBudgetCounter({
    required int maxBytes,
    required int maxLines,
    required String resource,
  });
  AcpTextBudgetChunk append(String chunk);
  AcpTextBudgetChunk finish();
}

final class AcpBase64ScanResult {
  const AcpBase64ScanResult(this.encodedLength, this.decodedBytes);
  final int encodedLength;
  final int decodedBytes;
}

AcpBase64ScanResult scanAcpBase64(
  String encoded, {
  required int maxDecodedBytes,
  required String resource,
});

final class AcpRetainedSizeEstimator {
  AcpRetainedSizeEstimator({required AcpInputBudget budget});
  int estimate(Object? value);
}
```

`finish()` 是 terminal 且幂等，只在输入流终态结算 pending surrogate/CR；finish 后 append 抛 payload-free `StateError`。`scanAcpBase64` 对 invalid alphabet/padding 抛 payload-free `FormatException`，容量失败抛 `AcpInputLimitExceeded`；两者都发生在 decoder 前。estimator 内部用显式 stack 和 identity visited set，不调用 `jsonEncode`。

- [ ] 5. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart
dart format third_party/dart_acp/lib/src/input_budget.dart test/acp/acp_input_budget_test.dart
git add third_party/dart_acp/lib/src/input_budget.dart test/acp/acp_input_budget_test.dart
git commit -m "feat: scan and estimate ACP input incrementally"
```

### Task 4: 单根 structured guard

**Files:**
- Modify: `third_party/dart_acp/lib/src/input_budget.dart`
- Modify: `test/acp/acp_input_budget_test.dart`

- [ ] 1. 写 RED：typed string、父子 list/map、metadata 共用 nodes/bytes；单字符串先过 64 KiB；单容器 entries、父子乘法、cycle、非字符串 key、NaN/Infinity exact/+1。
- [ ] 2. 在现有 JSON guard 之上冻结根 API；子 factory 只接收同一 `AcpStructuredUpdateGuard`，不能创建新预算：

```dart
final class AcpStructuredUpdateGuard {
  AcpStructuredUpdateGuard({
    required AcpInputBudget budget,
    required String resource,
  });
  String copyString(Object? value, {required String field});
  Object? copyScalar(Object? value, {required String field});
  int checkCollection(Object? value, {required String field});
  Map<String, Object?> copyMetadata(Object? value, {required String field});
  void consumeContainerNode({required String field});
  void consumeEntry({required String field});
}
```

`copyString` 先执行 `maxStructuredStringBytes`，再消费根 bytes/nodes；`copyScalar` 只接受 int、finite double、bool、null并计其 JSON bytes/node；`checkCollection` 在迭代/索引前检查 reported length。`copyMetadata` 复用同一根累计量并返回深层不可变副本。
- [ ] 3. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart test/acp/acp_agent_capabilities_test.dart
dart format third_party/dart_acp/lib/src/input_budget.dart test/acp/acp_input_budget_test.dart
git add third_party/dart_acp/lib/src/input_budget.dart test/acp/acp_input_budget_test.dart
git commit -m "feat: share ACP structured update budgets"
```

### Task 5: 有界 content blocks 与可信 omission

**Files:**
- Modify: `third_party/dart_acp/lib/src/models/content_types.dart`
- Modify: `third_party/dart_acp/lib/dart_acp.dart`
- Modify: `test/acp/dart_acp_session_types_test.dart`

- [ ] 1. 写 RED：text/resource text 安全 UTF-8 前缀并保留 block-level typed omission；image/audio/resource blob decode 前 exact/+1；非法 Base64；unknown map guard；远端 `type: omitted` 仍无 typed trust；一个坏 display block 不终止其他合法 blocks。
- [ ] 2. 所有 `ContentBlock/TextContent/ImageContent/AudioContent/ResourceContent/UnknownContent.fromJson` 增 optional named `inputBudget` 与 `AcpStructuredUpdateGuard? structuredGuard`；仅当外部未传 guard 时自建根。父 update/session parser 必须传同一 guard；先验类型/length 后索引，不先 `cast/map/toList/base64Decode`。
- [ ] 3. `ContentBlock` 增加默认 `AcpInputOmission? get omission => null`；`TextContent`、`ResourceContent` 和 `UnknownContent` 构造器增加 optional typed omission。远端 unknown factory 永远 omission=null，本地 named constructor 才能生成可信 marker；data 用不可变有界副本，marker 不保留 Base64、MIME 参数、异常或 hash。
- [ ] 4. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_session_types_test.dart test/acp/acp_input_budget_test.dart
dart format third_party/dart_acp/lib/src/models/content_types.dart third_party/dart_acp/lib/dart_acp.dart test/acp/dart_acp_session_types_test.dart
git add third_party/dart_acp/lib/src/models/content_types.dart third_party/dart_acp/lib/dart_acp.dart test/acp/dart_acp_session_types_test.dart
git commit -m "fix: bound ACP content blocks"
```

### Task 6: diff、plan 与行为字段原子语义

**Files:**
- Modify: `third_party/dart_acp/lib/src/models/updates.dart`
- Modify: `third_party/dart_acp/lib/src/models/diff_types.dart`
- Modify: `third_party/dart_acp/lib/src/models/command_types.dart`
- Modify: `third_party/dart_acp/lib/src/models/session_types.dart`
- Modify: `third_party/dart_acp/lib/src/models/tool_types.dart`
- Modify: `test/acp/dart_acp_session_types_test.dart`

- [ ] 1. 写 RED：diff 的 id/uri/status 先过单字符串预算；changes/line/text/meta 任一失败后 changes 整体为空、truncated+omission，不保留 partial/旧值；字符串 diff 不先 `split`。
- [ ] 2. 写 RED：plan 只保留有界前缀并带 typed truncated/observedAtLeast；commands/config/options/choices/modes/tool 行为 metadata 任一非法或超限时整字段为空/禁用，不保留前 N。
- [ ] 3. 写 RED：`MessageDelta` 聚合 text/thought/resource-text safe-prefix omissions，正文不含 marker；`SessionInfo.metaOmission` 在 meta 超限时可达 app，远端伪造同名 map 仍无 typed trust；`SessionListResult` 不二次复制/丢失 carrier。
- [ ] 4. 冻结 source-compatible typed carriers；所有集合保存不可变副本：

```dart
Plan({required List<PlanEntry> entries, String? title, String? description,
  Map<String, Object?>? metadata, bool truncated = false,
  AcpInputOmission? omission});
Diff({required String id, required DiffStatus status, String? uri,
  List<DiffChange> changes = const [], String? description,
  bool truncated = false, AcpInputOmission? omission});
AvailableCommandsUpdate(List<AvailableCommand> commands,
  {AcpInputOmission? omission});
MessageDelta({required String role, required List<ContentBlock> content,
  bool isThought = false,
  List<AcpInputOmission> omissions = const []});
ModeUpdate(String currentModeId, {AcpInputOmission? omission});
SessionResult({required String sessionId, List<ConfigOption>? configOptions,
  Map<String, Object?>? meta,
  ({String? currentModeId,
    List<({String id, String name})> availableModes})? modes,
  List<AcpInputOmission> omissions = const []});
ToolCall({required String toolCallId, required ToolCallStatus status,
  String? title, ToolKind? kind, List<Object?>? content,
  List<ToolCallLocation>? locations, Object? rawInput, Object? rawOutput,
  AcpInputOmission? omission});
UnknownUpdate(Map<String, dynamic> raw, {AcpInputOmission? omission});
SessionInfo({required String sessionId, required String cwd,
  List<String> additionalDirectories = const [], String? title,
  DateTime? updatedAt, Map<String, dynamic>? meta,
  AcpInputOmission? metaOmission});
```

`MessageDelta.fromRaw` 从每个 bounded block 的 `omission` 聚合不可变、去重后的 omissions；text/thought/resource text 保留 safe prefix，但 marker 不拼正文。`DartAcpAgentClient` 直接把该列表传到 `AgentEvent.omissions`。`SessionInfo.fromJson` 对纯展示 meta 超限时保存空 meta + typed `metaOmission`；远端同名字段不能设置 typed trust。`SessionListResult` 保存同一 immutable `SessionInfo` 实例，app 直接映射到 `AcpSessionEntry.metaOmission`。`UnknownUpdate` 保留现有公开 `raw` getter，内部只保存 guard 后的不可变 map。`SessionResult.modes` 承载 new/load/resume/fork immediate modes 的不可变 typed projection；`ModeUpdate` 只承载当前 mode 变化。应用层 `AcpSessionSettings` 统一使用 `List<AcpInputOmission> omissions = const []` 与 `bool truncated = false`，分别承载 modes/config 的固定 resource omission；`AgentEvent` 承载 update-level omissions。不得从 metadata/map 反推这些字段。
- [ ] 5. 所有 `Plan/Diff/AvailableCommand/ConfigOption/SessionInfo/SessionListResult/SessionResult/ToolCall/AcpUpdate.fromJson/fromRaw` 增 optional named `inputBudget` 与 `AcpStructuredUpdateGuard? structuredGuard`；每个顶层 update/result 只创建一个 root，子 parser 必须传入同一 guard。先完整构建临时值，成功后返回。纯展示 `_meta` 可整字段丢弃并设置 typed omission，行为 metadata 失败拒绝整个 event/raw snapshot。
- [ ] 6. 运行层级门禁并提交：

```bash
./tool/flutter_test_isolated.sh test/acp/acp_input_budget_test.dart test/acp/acp_agent_capabilities_test.dart test/acp/dart_acp_session_types_test.dart
dart format third_party/dart_acp/lib/src/models/updates.dart third_party/dart_acp/lib/src/models/diff_types.dart third_party/dart_acp/lib/src/models/command_types.dart third_party/dart_acp/lib/src/models/session_types.dart third_party/dart_acp/lib/src/models/tool_types.dart test/acp/dart_acp_session_types_test.dart
flutter analyze --no-pub
dart analyze third_party/dart_acp
git diff --check
git add third_party/dart_acp/lib/src/models/updates.dart third_party/dart_acp/lib/src/models/diff_types.dart third_party/dart_acp/lib/src/models/command_types.dart third_party/dart_acp/lib/src/models/session_types.dart third_party/dart_acp/lib/src/models/tool_types.dart test/acp/dart_acp_session_types_test.dart
git commit -m "fix: bound ACP structured update models"
```
