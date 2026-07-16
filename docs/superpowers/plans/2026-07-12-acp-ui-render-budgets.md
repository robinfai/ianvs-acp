# ACP UI 渲染与图片预算实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 确保 UI 不对有界 typed data 再产生同步解析、完整编码、全量布局或图片解码放大。

**Architecture:** Markdown 和 metadata 使用单遍有界 scanner/writer；command 搜索仅在列表 identity/revision 变化时建 cache；大集合用固定高度 lazy builder。图片由 application-owned ledger 管理并发、像素和保守内存 reservation，preview 在每个 await 边界检查 generation 并 exactly-once dispose。

**Tech Stack:** Flutter widgets、`dart:ui` image codec、widget tests 与 fake decoder。

---

### Task 1: Markdown scanner 与 bounded metadata writer

**Files:**
- Modify: `lib/app.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Create: `lib/ui/markdown_render_budget.dart`
- Create: `lib/ui/bounded_metadata_preview.dart`
- Modify: `lib/ui/components/chat_timeline.dart`
- Modify: `lib/ui/components/prompt_input.dart`
- Modify: `lib/ui/components/session_settings_dialog.dart`
- Modify: `lib/ui/components/resume_session_dialog.dart`
- Create: `test/ui/markdown_render_budget_test.dart`
- Modify: `test/ui/chat_timeline_test.dart`
- Modify: `test/ui/resume_session_dialog_test.dart`
- Modify: `test/ui/prompt_input_test.dart`
- Modify: `test/ui/session_settings_dialog_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`

- [ ] 1. 写 RED：Markdown block marker、每个 delimiter code unit、link/image delimiter、table separator、inline HTML opener exact/+1；到 +1 立即停且不保留 token/AST。
- [ ] 2. 写 RED：超限时绝不构造 `MarkdownBody`，改用 UTF-8 安全、最多 64 KiB plain text；typed omission 单独显示，不拼正文。
- [ ] 3. 写 RED：metadata preview 同时满足 chars/UTF-8 bytes exact/+1；cycle、非字符串 key、NaN/Infinity、恶意 `toString()` 不泄漏；collapsed 状态不编码。
- [ ] 4. 冻结动态预算注入链：`AcpClientApp(inputBudget: const AcpInputBudget())` 在创建任何 UI state 前 validate 并保存同一实例；`AppShell`、`ChatTimeline`、`PromptInput`、`SessionSettingsDialog`、`ResumeSessionDialog` 均增加 source-compatible optional `inputBudget`，AppShell 的所有直接构造点/弹窗都下传该实例。
- [ ] 5. 写非默认小预算 widget RED：Markdown token/fallback、timeline/resume metadata chars+bytes、command parameters preview 都使用注入 budget，不退回默认值。
- [ ] 6. 实现不可变 decision 和迭代 writer，禁止回溯 regex、完整 `JsonEncoder` 和先编码再 substring：

```dart
final class MarkdownRenderDecision {
  const MarkdownRenderDecision({
    required this.text,
    required this.useMarkdown,
    this.omission,
  });
  final String text;
  final bool useMarkdown;
  final AcpInputOmission? omission;
}

final class BoundedMetadataPreview {
  const BoundedMetadataPreview({
    required this.text,
    this.omission,
  });
  final String text;
  final AcpInputOmission? omission;
}

MarkdownRenderDecision scanMarkdownForRendering(
  String source, {
  required AcpInputBudget budget,
});

BoundedMetadataPreview writeBoundedMetadataPreview(
  Object? value, {
  required AcpInputBudget budget,
});
```

`scanMarkdownForRendering` 单遍返回 decision；`writeBoundedMetadataPreview` 用显式 stack 写 JSON scalar/container，并在第一个 chars/bytes 边界停止。ChatTimeline 展开后才调用 metadata writer；resume metadata 同样复用该入口。

- [ ] 7. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/ui/markdown_render_budget_test.dart test/ui/chat_timeline_test.dart test/ui/prompt_input_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart test/ui/acp_client_app_test.dart
dart format lib/app.dart lib/ui/shell/app_shell.dart lib/ui/markdown_render_budget.dart lib/ui/bounded_metadata_preview.dart lib/ui/components/chat_timeline.dart lib/ui/components/prompt_input.dart lib/ui/components/session_settings_dialog.dart lib/ui/components/resume_session_dialog.dart test/ui/markdown_render_budget_test.dart test/ui/chat_timeline_test.dart test/ui/prompt_input_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart test/ui/acp_client_app_test.dart
git add lib/app.dart lib/ui/shell/app_shell.dart lib/ui/markdown_render_budget.dart lib/ui/bounded_metadata_preview.dart lib/ui/components/chat_timeline.dart lib/ui/components/prompt_input.dart lib/ui/components/session_settings_dialog.dart lib/ui/components/resume_session_dialog.dart test/ui/markdown_render_budget_test.dart test/ui/chat_timeline_test.dart test/ui/prompt_input_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart test/ui/acp_client_app_test.dart
git commit -m "fix: bound markdown and metadata rendering"
```

### Task 2: command search cache

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/ui/components/prompt_input.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Modify: `test/state/chat_controller_test.dart`
- Modify: `test/ui/prompt_input_test.dart`

- [ ] 1. controller 的 commands 原子 add/clear/replace 时递增只读 `int get availableCommandsRevision`；写 RED 覆盖同 identity 下内容 revision 变化。
- [ ] 2. `PromptInput` 增 source-compatible optional `availableCommandsRevision = 0`，`AppShell` 传 controller revision。写 RED：同 identity+revision 连续键入不重复 lower-case/parameters preview；同 identity 但 revision 变化重建一次；最多扫描 1024、展示 5。
- [ ] 3. 引入精确 cache 类型；parameters preview 使用 Task 1 bounded writer，search entry 不进入 wire/metadata/persistence：

```dart
final class _CommandSearchEntry {
  const _CommandSearchEntry({
    required this.command,
    required this.invocation,
    required this.lowerName,
    required this.lowerDescription,
    required this.description,
  });
  final Map<String, Object?> command;
  final String invocation;
  final String lowerName;
  final String lowerDescription;
  final String description;
}
```

- [ ] 4. 在 `initState/didUpdateWidget` 比较 `identical(list, oldList)` 与 revision 后重建，键入仅扫描 cache；suggestion panel 接收 `_CommandSearchEntry` 并直接显示缓存 description，不再次读取原 map。测试使用计数型 Map getter 统计 name/description/parameters 读取次数，不增加生产 debug API。
- [ ] 5. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/ui/prompt_input_test.dart
dart format lib/state/chat_controller.dart lib/ui/components/prompt_input.dart lib/ui/shell/app_shell.dart test/state/chat_controller_test.dart test/ui/prompt_input_test.dart
git add lib/state/chat_controller.dart lib/ui/components/prompt_input.dart lib/ui/shell/app_shell.dart test/state/chat_controller_test.dart test/ui/prompt_input_test.dart
git commit -m "perf: cache bounded command search entries"
```

### Task 3: 惰性内容、设置与 resume 列表

**Files:**
- Modify: `lib/ui/components/chat_timeline.dart`
- Modify: `lib/ui/components/session_settings_dialog.dart`
- Modify: `lib/ui/components/resume_session_dialog.dart`
- Modify: `test/ui/chat_timeline_test.dart`
- Modify: `test/ui/session_settings_dialog_test.dart`
- Modify: `test/ui/resume_session_dialog_test.dart`

- [ ] 1. 写 RED：content/plan/diff/command details 在 1024 项时只 build viewport；nested list 固定最大高度、`primary:false` 且无 `shrinkWrap:true`。
- [ ] 2. 写 RED：settings 使用 `CustomScrollView/SliverList`；choices 仅首屏和 “N more”，完整集合进入 searchable lazy panel；dialog 内 metadata/parameters preview 使用注入 inputBudget。
- [ ] 3. 写 RED：resume modal 可搜索且使用 `ListView.builder`，不生成全部 Dropdown items。
- [ ] 4. 实现 builder/sliver；omitted/truncated/disabled 状态保持可见且不误示为完整。
- [ ] 5. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/ui/chat_timeline_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart
dart format lib/ui/components/chat_timeline.dart lib/ui/components/session_settings_dialog.dart lib/ui/components/resume_session_dialog.dart test/ui/chat_timeline_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart
git add lib/ui/components/chat_timeline.dart lib/ui/components/session_settings_dialog.dart lib/ui/components/resume_session_dialog.dart test/ui/chat_timeline_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart
git commit -m "perf: render ACP collections lazily"
```

### Task 4: application-owned 图片 ledger

**Files:**
- Create: `lib/ui/image_decode_budget.dart`
- Create: `test/ui/image_decode_budget_test.dart`

- [ ] 1. 写 RED：并发 2、global pixels/bytes exact 通过和第一个 +1 排队/拒绝；取消 waiter 释放；memory/pixel lease shrink-only；double release 幂等且账本不为负。
- [ ] 2. 实现 FIFO waiter。provisional reservation 同时占 concurrency、decoded bytes + `maxImagePreviewPixels * 4`、max preview pixels；header 后只能下调。

```dart
abstract interface class AcpImageDecodeReservation {
  bool get decodeFinished;
  bool get installedMemoryReleased;
  void shrinkInstalledReservation({
    required int previewPixels,
    required int reservedBytes,
  });
  void finishDecode();
  void releaseInstalledMemory();
}

abstract interface class AcpImageDecodeCancellation {
  bool get isCancelled;
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
}

final class AcpImageDecodeCancellationSource
    implements AcpImageDecodeCancellation {
  final Set<void Function()> _listeners = <void Function()>{};
  bool _cancelled = false;

  @override
  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
    _listeners.clear();
  }

  @override
  void addListener(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }

  @override
  void removeListener(void Function() listener) {
    _listeners.remove(listener);
  }
}

final class AcpImageDecodeBudgetLedger {
  AcpImageDecodeBudgetLedger({required AcpInputBudget budget})
      : _budget = budget..validate();
  final AcpInputBudget _budget;
  Future<AcpImageDecodeReservation> acquire({
    required int decodedBytes,
    required AcpImageDecodeCancellation cancellation,
  });
}
```

- [ ] 3. `acquire` 原子预占 memory/pixels；memory/pixels 不足立即固定失败，并发满则 FIFO 等待。widget 为每个 generation 创建 `AcpImageDecodeCancellationSource`，update/dispose 调用 `cancel()` 移除 waiter。`finishDecode()` 只释放并发槽；`releaseInstalledMemory()` 保持到 image 替换/dispose。两个终态分别 exactly once；幂等只作防御，测试还要断言实际每类调用一次。
- [ ] 4. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/ui/image_decode_budget_test.dart
dart format lib/ui/image_decode_budget.dart test/ui/image_decode_budget_test.dart
git add lib/ui/image_decode_budget.dart test/ui/image_decode_budget_test.dart
git commit -m "feat: add global ACP image decode ledger"
```

### Task 5: 分阶段 bounded image preview

**Files:**
- Create: `lib/ui/components/bounded_image_preview.dart`
- Modify: `lib/ui/components/chat_timeline.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Modify: `lib/app.dart`
- Modify: `test/ui/chat_timeline_test.dart`
- Modify: `test/ui/image_decode_budget_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`

- [ ] 1. 写可注入 fake `BoundedImageDecoder`，能在 buffer/descriptor/codec/frame 每阶段暂停或失败，并记录每个资源 dispose 次数。
- [ ] 2. 冻结 decoder ownership seam；每个 handle 都有 exactly-once `dispose()`，production adapter 分别封装 `ui.ImmutableBuffer`、`ui.ImageDescriptor`、`ui.Codec` 与首帧 `ui.Image`：

```dart
abstract interface class BoundedImageDecoder {
  Future<BoundedImageBuffer> createBuffer(Uint8List bytes);
  Future<BoundedImageDescriptor> createDescriptor(BoundedImageBuffer buffer);
  Future<BoundedImageCodec> createCodec(
    BoundedImageDescriptor descriptor, {
    required int targetWidth,
    required int targetHeight,
  });
  Future<BoundedImageFrame> getFirstFrame(BoundedImageCodec codec);
}

abstract interface class BoundedImageBuffer {
  void dispose();
}

abstract interface class BoundedImageDescriptor {
  int get width;
  int get height;
  void dispose();
}

abstract interface class BoundedImageCodec {
  void dispose();
}

abstract interface class BoundedImageFrame {
  ui.Image takeImage();
  void dispose();
}
```
- [ ] 3. 写 RED：invalid/oversize Base64 不调用 decoder；width/height >0、dimension/pixels exact/+1；像素判断用 `width > maxPixels ~/ height`；target 等比且至少 1；只取首帧。
- [ ] 4. 写 RED：每个 await 后切 generation；stale buffer/descriptor/codec/frame/image、waiter、两类 lease 全部 exactly once 释放；同内容 rebuild 不重 decode。
- [ ] 5. 实现 stateful preview：build 只显示 state；先 Base64 scanner 和 ledger reservation，再 `base64Decode`。descriptor 创建失败仍 dispose buffer；codec/frame 成败都 dispose codec；过期 frame 立即 dispose。
- [ ] 6. 安装新 image 前释放旧 image 和旧 installed-memory reservation；update/dispose 递增 generation、取消 waiter并清空 ownership。失败只显示固定 placeholder，不显示异常/Base64。
- [ ] 7. 复用 Task1 的 `AcpClientApp.inputBudget`；再增加 optional `imageDecodeLedger` 与 `boundedImageDecoder`。默认由已 validate 的 budget 创建一个 ledger/production decoder。`AcpClientApp state -> AppShell -> ChatTimeline -> BoundedImagePreview` 为 ledger 与 decoder 都增加 source-compatible optional 参数并下传同一实例；多个 controller/timeline 不各建账本，tests 注入独立 ledger/fake decoder。
- [ ] 8. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/ui/image_decode_budget_test.dart test/ui/chat_timeline_test.dart test/ui/acp_client_app_test.dart
dart format lib/ui/components/bounded_image_preview.dart lib/ui/components/chat_timeline.dart lib/ui/image_decode_budget.dart lib/ui/shell/app_shell.dart lib/app.dart test/ui/chat_timeline_test.dart test/ui/image_decode_budget_test.dart test/ui/acp_client_app_test.dart
git add lib/ui/components/bounded_image_preview.dart lib/ui/components/chat_timeline.dart lib/ui/image_decode_budget.dart lib/ui/shell/app_shell.dart lib/app.dart test/ui/chat_timeline_test.dart test/ui/image_decode_budget_test.dart test/ui/acp_client_app_test.dart
git commit -m "fix: decode ACP images within global budgets"
```

### Task 6: UI 层门禁

- [ ] 1. 运行全部受影响 UI tests：

```bash
./tool/flutter_test_isolated.sh test/ui/chat_timeline_test.dart test/ui/image_decode_budget_test.dart test/ui/markdown_render_budget_test.dart test/ui/prompt_input_test.dart test/ui/session_settings_dialog_test.dart test/ui/resume_session_dialog_test.dart test/ui/acp_client_app_test.dart
```

- [ ] 2. 运行 controller/client 回归、静态分析和差异检查：

```bash
./tool/flutter_test_isolated.sh test/acp/dart_acp_agent_client_test.dart test/state/chat_controller_test.dart
flutter analyze --no-pub
dart analyze third_party/dart_acp
git diff --check
git status --short
```

- [ ] 3. 若门禁修复产生新差异，单独提交实际修改文件；不要用目录级 `git add` 吞入无关改动。
