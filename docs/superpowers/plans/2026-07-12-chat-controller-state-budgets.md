# ChatController 状态预算实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 防御 Fake/第三方 client 绕过协议预算，并将 active turn、timeline、inactive snapshots 和已签发 archive 全部纳入单个 controller 的确定性账本。

**Architecture:** `ChatMessage` 用 buffer、materialized cache 和 revision 实现摊销 O(1) 追加；freeze/thaw 消除状态别名。controller 执行内容专项上限、turn 根预算、完整 turn 淘汰和 UI-state LRU；archive lease 在 active/snapshot 与撤销窗口间转移字节所有权。

**Tech Stack:** Flutter ChangeNotifier、Dart immutable snapshots、unit/widget tests。

---

### Task 1: ChatMessage buffer、revision 与不可变 metadata

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `test/state/chat_controller_test.dart`

- [ ] 1. 写 RED：100,000 微 chunk 顺序正确并在时限内完成；`text` getter/setter 兼容；append/setter 单调增加 revision；每个通知批次最多 materialize 一次。加入代理对跨 chunk 与 CRLF 跨 chunk，覆盖 text 与 `metadata.kind=thought` 的独立 ChatMessage。
- [ ] 2. 写 RED：metadata 在构造时重新 guard Fake client 并深拷贝；外部后续修改不影响 message；omission 按 resource+reason 去重且数量受限。
- [ ] 3. `ChatMessage` 只拥有一个 text buffer/materialized cache/revision，不拥有 turn counter，也不建立第二套 thought buffer。controller 的 `_TurnBudgetState` 分别持有 text/thought `AcpUtf8LineBudgetCounter`，其结果写入当前目标 ChatMessage 的同一个 text buffer：

```dart
void _appendTextToMessage(ChatMessage target, String chunk) {
  final accepted = _turnBudget.text.append(chunk);
  target.appendAcceptedText(
    accepted.safePrefix,
    acceptedUtf8Bytes: accepted.acceptedBytes,
  );
}

void _appendThoughtToMessage(ChatMessage target, String chunk) {
  final accepted = _turnBudget.thought.append(chunk);
  target.appendAcceptedText(
    accepted.safePrefix,
    acceptedUtf8Bytes: accepted.acceptedBytes,
  );
}
```

- [ ] 4. 写 RED：text → tool/status → text 之间拆分代理对/CRLF 仍按一个 turn 正确累计；创建新的 text/thought ChatMessage 不重置 aggregate counter。
- [ ] 5. controller 使用 append API；通知按 microtask/frame 合并。tool/status boundary 只强制 materialize/notify flush，不调用 counter `finish()`。仅 turn done/cancel/fail、session close/switch、controller dispose 等流终态调用 `finish()`，把尾部 safePrefix 写回相应目标后释放 counter。
- [ ] 6. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart
dart format lib/state/chat_controller.dart test/state/chat_controller_test.dart
git add lib/state/chat_controller.dart test/state/chat_controller_test.dart
git commit -m "perf: append chat chunks with revisions"
```

### Task 2: freeze/thaw 与 snapshot 无别名

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `test/state/chat_controller_test.dart`

- [ ] 1. 写 RED：inactive/archive 内 message、metadata、omissions、commands/settings 均不可变；恢复后 append 不反向修改 snapshot/archive。
- [ ] 2. `freeze()` 物化并深拷贝；`thaw()` 创建新 buffer 和 active 副本；snapshot 只接受 frozen messages、immutable commands/settings 与预计算 retained bytes。
- [ ] 3. 运行多 session 测试并提交：

```bash
./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart
dart format lib/state/chat_controller.dart test/state/chat_controller_test.dart
git add lib/state/chat_controller.dart test/state/chat_controller_test.dart
git commit -m "fix: isolate chat session snapshots"
```

### Task 3: turn 专项预算与根账本

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `test/state/chat_controller_test.dart`

- [ ] 1. 写 RED：Fake client text/thought/media/metadata exact/+1；UTF-8 和 CR/LF/CRLF；同 resource marker 一次且后续 chunk 被 drain。
- [ ] 2. 写 RED：`maxTurnItems/maxTurnRetainedBytes` exact/+1；普通可用额度为 `max(0, maxTurnItems - 1)` 和 `max(0, maxTurnRetainedBytes - 1024)`；tool/status 原位更新重算 byte delta、不重复计 item。
- [ ] 3. 写 RED：plan、diff、commands、settings 和其 marker 均消费 item+retained bytes；commands/settings 行为字段失败关闭时清除旧状态，不显示 partial/旧列表。
- [ ] 4. `ChatController` 增 optional named `inputBudget` 并立即 validate；turn start 创建专用 counter 与根账本，所有终态释放。
- [ ] 5. display-only 超限丢 delta 并仅加一个 overflow omission；行为字段 fail-closed。tool/status 终态优先合并同 ID，无目标时只用固定 payload-free lifecycle marker；marker 自身必须计入总 budget，放不下时只保留 controller 的 typed overflow 状态而不越界。
- [ ] 6. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart
dart format lib/state/chat_controller.dart test/state/chat_controller_test.dart
git add lib/state/chat_controller.dart test/state/chat_controller_test.dart
git commit -m "fix: bound active chat turns"
```

### Task 4: timeline、turn 边界、LRU 与签名

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/ui/components/chat_timeline.dart`
- Modify: `lib/ui/shell/app_shell.dart`
- Modify: `test/state/chat_controller_test.dart`
- Modify: `test/ui/chat_timeline_test.dart`

- [ ] 1. 为每个 message 保存本地 turn generation/turnId；写 RED：items/bytes +1 时只淘汰最旧完整 turn，不淘汰当前 streaming turn；首部至多一个 history marker。
- [ ] 2. 写 RED：inactive snapshot LRU touch 改变淘汰顺序；active + snapshots 始终不超过 `maxUiStateBytes`；`reconnect()` 同时清 active messages、snapshots 和对应账本，不能留下未计量旧消息。
- [ ] 3. 将 `messages` 改为私有 `_messages` 与 `UnmodifiableListView<ChatMessage> get messages`；迁移现有直接 `.add` 测试到公开测试 helper/事件驱动路径。所有 add/remove/replace/reorder 只走统一 mutation helper并递增 `messagesRevision`，外部/Fake 无法绕过预算。实现完整 turn group eviction。
- [ ] 4. 将 commands 改为私有不可变 backing；保留 source-compatible getter/setter，setter 深拷贝后调用统一 replace/clear helper并递增 `availableCommandsRevision`。LRU touch 使用 remove+reinsert或显式序号，active 不整体淘汰。
- [ ] 5. `ChatTimeline` 增 source-compatible optional `messageListRevision = 0`；`AppShell` 传 `controller.messagesRevision`。`_timelineMessagesSignature` 只组合 list revision、message identity/revision 与 loading 状态，不递归 metadata；同长度 replace/reorder 必须刷新。
- [ ] 6. 运行并提交：

```bash
./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart test/ui/chat_timeline_test.dart
dart format lib/state/chat_controller.dart lib/ui/components/chat_timeline.dart lib/ui/shell/app_shell.dart test/state/chat_controller_test.dart test/ui/chat_timeline_test.dart
git add lib/state/chat_controller.dart lib/ui/components/chat_timeline.dart lib/ui/shell/app_shell.dart test/state/chat_controller_test.dart test/ui/chat_timeline_test.dart
git commit -m "fix: bound chat timelines and snapshots"
```

### Task 5: archive snapshot lease

**Files:**
- Modify: `lib/state/chat_controller.dart`
- Modify: `lib/app.dart`
- Modify: `test/state/chat_controller_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`

- [ ] 1. 写 RED：archive 将 bytes 从 active/snapshot 转到 lease；restore 只消费一次；Snackbar action restore；dismiss/过期 discard；controller dispose 释放未决 lease。
- [ ] 2. `ArchivedSessionSnapshot` 持有私有 exactly-once release callback；restore 先验证 owner/lease，再原子消费。额度满时拒绝继续 archive，不增长。
- [ ] 3. `_showUndoableSnackBar` 保存 `ScaffoldFeatureController.closed`：Undo callback 先 consume/restore；`closed.whenComplete(snapshot.discard)` 对 timeout、swipe、hide、remove、replacement 和 app dispose 幂等释放。批量 archive 对每个 snapshot 执行相同流程，不依赖 GC/finalizer。
- [ ] 4. 运行、分析并提交：

```bash
./tool/flutter_test_isolated.sh test/state/chat_controller_test.dart test/ui/acp_client_app_test.dart
dart format lib/state/chat_controller.dart lib/app.dart test/state/chat_controller_test.dart test/ui/acp_client_app_test.dart
flutter analyze --no-pub
git diff --check
git add lib/state/chat_controller.dart lib/app.dart test/state/chat_controller_test.dart test/ui/acp_client_app_test.dart
git commit -m "fix: account for archived chat snapshots"
```
