# 第二批：任务执行与事务持久化整改实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让后台任务使用独立执行上下文，以规范化 SQLite 无损保存和原子认领任务，并消除加载竞态、平方级写入、无锁任务卡住及跨重启状态丢失。

**Architecture:** 使用 `package:sqlite3` 的应用内连接替换外部进程和单行 JSON；repository 提供行级事务与条件认领，controller 只维护查询得到的只读 snapshot。调度器把 busy 当作等待状态，后台 agent 与界面对话完全隔离。

**Tech Stack:** Dart 3.12、Flutter、[`sqlite3 ^3.3.4`](https://pub.dev/packages/sqlite3)、WAL、Flutter Test、真实临时数据库多连接测试。

---

### Task 1: 引入应用内 SQLite 并建立规范化 schema

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `lib/tasks/task_repository.dart`
- Rewrite: `lib/tasks/task_inbox_sqlite_store.dart`
- Test: `test/tasks/task_inbox_sqlite_store_test.dart`

- [ ] **Step 1: 添加已核对的 SQLite 依赖**

Run: `flutter pub add sqlite3:^3.3.4`

Expected: `pubspec.yaml` 出现 `sqlite3: ^3.3.4`，锁文件固定解析版本。该官方包在 macOS arm64/x64 上使用随应用构建的 SQLite，不再依赖系统 `sqlite3` 命令。

- [ ] **Step 2: 写入 schema 失败测试**

```dart
test('creates normalized task tables with required pragmas', () async {
  final file = File('${temp.path}/task-inbox.sqlite3');
  final repository = TaskInboxSqliteStore(path: file.path);
  addTearDown(repository.close);

  await repository.initialize();

  expect(await repository.journalMode(), 'wal');
  expect(await repository.foreignKeysEnabled(), isTrue);
  expect(await repository.tableNames(), containsAll(<String>{
    'schema_migrations',
    'store_meta',
    'workspace_resources',
    'tasks',
    'task_runs',
    'task_events',
    'artifacts',
    'approval_requests',
  }));
});
```

- [ ] **Step 3: 运行测试并确认缺少新 API**

Run: `flutter test --no-pub test/tasks/task_inbox_sqlite_store_test.dart --plain-name 'creates normalized task tables with required pragmas'`

Expected: FAIL；当前 store 没有 `initialize` 和规范化表。

- [ ] **Step 4: 定义 repository 接口**

```dart
abstract class TaskRepository {
  Future<void> initialize();
  Future<TaskRepositorySnapshot> load();
  Future<TaskRecord> insertTask(TaskRecord task);
  Future<TaskRecord> updateTask(TaskRecord task);
  Future<TaskClaim?> claimTask(String taskId, TaskRunRecord run);
  Future<TaskRunRecord> updateRun(TaskRunRecord run);
  Future<void> appendEvents(List<TaskEventRecord> events);
  Future<void> replaceArtifactsForRun(List<ArtifactRecord> artifacts);
  Future<void> upsertApproval(ApprovalRequestRecord approval);
  Future<void> upsertResource(WorkspaceResource resource);
  Future<int> revision();
  Future<void> close();
}

abstract class TaskMigrationRepository {
  Future<bool> isActive();
  Future<void> importSnapshot(
    TaskInboxSnapshot snapshot, {
    required String checksum,
  });
  Future<void> rollbackImport(String checksum);
  Future<void> activateImport(String checksum);
}

class TaskRepositorySnapshot {
  const TaskRepositorySnapshot({required this.revision, required this.snapshot});
  final int revision;
  final TaskInboxSnapshot snapshot;
}

class TaskClaim {
  const TaskClaim({required this.task, required this.run});
  final TaskRecord task;
  final TaskRunRecord run;
}
```

- [ ] **Step 5: 创建 schema 和连接设置**

`TaskInboxSqliteStore.initialize()` 使用 `sqlite3.open(path)`，执行：

```sql
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;
PRAGMA foreign_keys = ON;
PRAGMA busy_timeout = 5000;
CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS store_meta (
  id INTEGER PRIMARY KEY CHECK (id = 1),
  revision INTEGER NOT NULL,
  migration_state TEXT NOT NULL,
  source_checksum TEXT
);
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  workspace_path TEXT NOT NULL,
  agent_name TEXT NOT NULL,
  status TEXT NOT NULL,
  priority TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  session_id TEXT,
  current_run_id TEXT,
  summary TEXT,
  error TEXT,
  resource_id TEXT,
  skill_ids_json TEXT NOT NULL,
  metadata_json TEXT NOT NULL
);
```

同一 migration 中创建其余表和 task/run 外键。每次写事务最后执行 `UPDATE store_meta SET revision = revision + 1 WHERE id = 1`。

- [ ] **Step 6: 运行 schema 测试并提交**

Run: `flutter test --no-pub test/tasks/task_inbox_sqlite_store_test.dart`

Expected: PASS。

```bash
git add pubspec.yaml pubspec.lock lib/tasks/task_repository.dart lib/tasks/task_inbox_sqlite_store.dart test/tasks/task_inbox_sqlite_store_test.dart
git commit -m "feat: add transactional task database"
```

### Task 2: 无损迁移旧 JSON，失败时禁止调度

**Files:**
- Modify: `lib/tasks/task_inbox_state_store.dart`
- Modify: `lib/tasks/task_inbox_snapshot.dart`
- Create: `lib/tasks/task_inbox_migrator.dart`
- Modify: `lib/tasks/task_inbox_sqlite_store.dart`
- Modify: `lib/app.dart`
- Create: `test/tasks/task_inbox_migrator_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`

- [ ] **Step 1: 写入完整迁移、损坏回滚和备份失败测试**

```dart
test('imports every record and preserves a checksummed backup', () async {
  await source.writeAsString(jsonEncode(fixtureSnapshot.toJson()));
  final result = await migrator.migrateIfNeeded();

  expect(result.status, TaskMigrationStatus.migrated);
  expect((await repository.load()).snapshot.toJson(), fixtureSnapshot.toJson());
  expect(result.backupPath, contains('task_inbox_state.migrated.'));
  expect(File(result.backupPath!).existsSync(), isTrue);
  expect(source.existsSync(), isFalse);
});

test('malformed JSON leaves source untouched and repository inactive', () async {
  await source.writeAsString('{broken');
  await expectLater(migrator.migrateIfNeeded(), throwsFormatException);
  expect(await source.readAsString(), '{broken');
  expect(await repository.isActive(), isFalse);
});
```

- [ ] **Step 2: 运行测试并确认当前 malformed 被当成空状态**

Run: `flutter test --no-pub test/tasks/task_inbox_migrator_test.dart`

Expected: FAIL；当前没有 migrator，旧 store 吞掉解析异常。

- [ ] **Step 3: 让旧 JSON 严格解析**

`TaskInboxStateStore.loadStrict()` 必须让 JSON/模型错误向上传递；保留 `load()` 只用于明确的测试兼容路径，生产迁移只调用 strict API。新增 `TaskInboxSnapshot.validateReferences()`，检查 ID 唯一性以及 run/event/artifact/approval 对 task 和 run 的引用。

- [ ] **Step 4: 实现迁移状态机**

```dart
enum TaskMigrationStatus { notNeeded, migrated, awaitingBackupFinalization }

class TaskInboxMigrator {
  Future<TaskMigrationResult> migrateIfNeeded() async {
    final bytes = await source.readAsBytes();
    final checksum = sha256.convert(bytes).toString();
    final snapshot = TaskInboxSnapshot.fromJsonStrict(jsonDecode(utf8.decode(bytes)));
    snapshot.validateReferences();
    await repository.importSnapshot(snapshot, checksum: checksum);
    final roundTrip = (await repository.load()).snapshot;
    final importedDigest = sha256.convert(
      utf8.encode(canonicalJson(roundTrip.toJson())),
    );
    final sourceDigest = sha256.convert(
      utf8.encode(canonicalJson(snapshot.toJson())),
    );
    if (importedDigest != sourceDigest) {
      await repository.rollbackImport(checksum);
      throw StateError('Task migration verification failed.');
    }
    return _finalizeBackup(checksum);
  }
}
```

`canonicalJson` 递归排序 map key 后编码，不引入额外比较依赖。数据库只在备份原子改名和 `chmod 0400` 成功后调用 `activateImport(checksum)`。

- [ ] **Step 5: App 初始化等待迁移结果**

`_configureTaskInboxController` 改为异步 `_initializeTaskInbox()`；成功后才创建 scheduler。失败时 controller 暴露 `initializationError`，界面显示错误，scheduler 保持 null。

- [ ] **Step 6: 运行迁移与 App 测试并提交**

Run: `flutter test --no-pub test/tasks/task_inbox_migrator_test.dart test/ui/acp_client_app_test.dart`

Expected: PASS。

```bash
git add lib/tasks/task_inbox_state_store.dart lib/tasks/task_inbox_snapshot.dart lib/tasks/task_inbox_migrator.dart lib/tasks/task_inbox_sqlite_store.dart lib/app.dart test/tasks/task_inbox_migrator_test.dart test/ui/acp_client_app_test.dart
git commit -m "feat: migrate task history without data loss"
```

### Task 3: 行级写入、单一 load 和跨进程 revision

**Files:**
- Modify: `lib/tasks/task_inbox_controller.dart`
- Modify: `lib/tasks/task_repository.dart`
- Modify: `lib/tasks/task_inbox_sqlite_store.dart`
- Modify: `lib/app.dart`
- Delete: `lib/tasks/task_store.dart`
- Create: `test/support/memory_task_repository.dart`
- Test: `test/tasks/task_inbox_controller_test.dart`
- Test: `test/tasks/task_inbox_sqlite_store_test.dart`
- Modify: `test/tasks/task_automation_test.dart`
- Modify: `test/tasks/task_runner_test.dart`
- Modify: `test/tasks/task_scheduler_test.dart`
- Modify: `test/tasks/task_timeline_test.dart`
- Modify: `test/tasks/task_worker_test.dart`
- Modify: `test/ui/acp_client_app_test.dart`
- Modify: `test/ui/app_shell_test.dart`
- Modify: `test/ui/task_inbox_sidebar_test.dart`

- [ ] **Step 1: 写入并发 load 和双连接无丢更新测试**

```dart
final first = controller.load();
final second = controller.load();
expect(identical(first, second), isTrue);
await Future.wait([first, second]);
expect(store.loadCount, 1);
```

双连接测试分别插入不同 task，随后两边 load 均能看到两条记录；任何旧 snapshot 都没有全量 `save` API 可调用。

- [ ] **Step 2: 运行测试并确认失败**

Run: `flutter test --no-pub test/tasks/task_inbox_controller_test.dart test/tasks/task_inbox_sqlite_store_test.dart`

Expected: 新测试 FAIL；当前 load Future 不复用，TaskStore 仍允许全量覆盖。

- [ ] **Step 3: 控制器缓存 load Future**

```dart
Future<void>? _loadFuture;
int _revision = -1;

Future<void> load() => _loadFuture ??= _loadOnce();

Future<void> _loadOnce() async {
  final loaded = await repository.load();
  _snapshot = loaded.snapshot;
  _revision = loaded.revision;
  _loaded = true;
  notifyListeners();
}
```

所有 controller 写方法改为调用对应 repository 行级方法，并使用返回记录更新 snapshot，禁止调用 `save(snapshot)`。删除旧 `TaskStore` 接口；测试统一使用实现同一 repository contract 的 `MemoryTaskRepository`，避免生产代码保留全量 snapshot 写入口。

- [ ] **Step 4: 增加 revision 刷新**

```dart
Future<bool> refreshIfChanged() async {
  final current = await repository.revision();
  if (current == _revision) return false;
  final loaded = await repository.load();
  _snapshot = loaded.snapshot;
  _revision = loaded.revision;
  notifyListeners();
  return true;
}
```

App 前台 controller 每秒检查一次；scheduler 每次 drain 前 await `refreshIfChanged()`。

- [ ] **Step 5: 运行 controller/store 测试并提交**

Run: `flutter test --no-pub test/tasks/task_inbox_controller_test.dart test/tasks/task_inbox_sqlite_store_test.dart`

Expected: PASS。

```bash
git add lib/tasks/task_inbox_controller.dart lib/tasks/task_repository.dart lib/tasks/task_inbox_sqlite_store.dart lib/tasks/task_store.dart lib/app.dart test/support/memory_task_repository.dart test/tasks/task_automation_test.dart test/tasks/task_inbox_controller_test.dart test/tasks/task_inbox_sqlite_store_test.dart test/tasks/task_runner_test.dart test/tasks/task_scheduler_test.dart test/tasks/task_timeline_test.dart test/tasks/task_worker_test.dart test/ui/acp_client_app_test.dart test/ui/app_shell_test.dart test/ui/task_inbox_sidebar_test.dart
git commit -m "refactor: use row-level task repository writes"
```

### Task 4: 原子认领任务并正确处理 busy、serial:false 和认证状态

**Files:**
- Modify: `lib/tasks/runtime_registry.dart`
- Modify: `lib/tasks/task_scheduler.dart`
- Modify: `lib/tasks/workspace_execution_gate.dart`
- Modify: `lib/tasks/task_inbox_controller.dart`
- Test: `test/tasks/task_scheduler_test.dart`
- Test: `test/tasks/task_inbox_sqlite_store_test.dart`

- [ ] **Step 1: 写入双连接认领和 busy 不耗 run 测试**

```dart
final claims = await Future.wait([
  repositoryA.claimTask('task-1', runA),
  repositoryB.claimTask('task-1', runB),
]);
expect(claims.whereType<TaskClaim>(), hasLength(1));
expect((await repositoryA.load()).snapshot.runs, hasLength(1));
```

Scheduler 测试把 runtime 设为 busy，等待超过原 90 秒的 fake time 后仍断言 `runs.isEmpty`、task queued；`serial:false` resource 的任务能启动。

- [ ] **Step 2: 运行测试并确认重复认领或 busy 失败**

Run: `flutter test --no-pub test/tasks/task_scheduler_test.dart test/tasks/task_inbox_sqlite_store_test.dart`

Expected: FAIL。

- [ ] **Step 3: 增加 busy 状态和条件认领**

`LocalRuntimeStatus` 增加 `busy`。Scheduler 在创建 run 前检查 runtime；busy 只安排下一次 drain。available 后构造 run 并调用 repository：

```sql
BEGIN IMMEDIATE;
UPDATE tasks
SET status = 'dispatched', current_run_id = ?1, updated_at = ?2
WHERE id = ?3 AND status = 'queued';
-- 仅 changes() = 1 时插入 task_runs 和 dispatch event
COMMIT;
```

`serialKey.isEmpty` 时跳过 `workspaceGate.tryAcquire/release`。恢复中断任务只处理仍引用 active run 的 running/dispatched 状态；带 `authRequired` metadata 的 blocked task 保持 blocked。

- [ ] **Step 4: 运行 scheduler 测试并提交**

Run: `flutter test --no-pub test/tasks/task_scheduler_test.dart test/tasks/workspace_execution_gate_test.dart test/tasks/task_inbox_sqlite_store_test.dart`

Expected: PASS。

```bash
git add lib/tasks/runtime_registry.dart lib/tasks/task_scheduler.dart lib/tasks/workspace_execution_gate.dart lib/tasks/task_inbox_controller.dart test/tasks/task_scheduler_test.dart test/tasks/workspace_execution_gate_test.dart test/tasks/task_inbox_sqlite_store_test.dart
git commit -m "fix: atomically claim runnable tasks"
```

### Task 5: 为后台任务创建独立 controller 和原子租约

**Files:**
- Create: `lib/tasks/task_agent_pool.dart`
- Modify: `lib/tasks/task_runner.dart`
- Modify: `lib/app.dart`
- Test: `test/tasks/task_runner_test.dart`
- Test: `test/ui/acp_client_app_test.dart`

- [ ] **Step 1: 写入 UI session 不受后台任务影响的失败测试**

```dart
final uiController = fakeUiController(sessionId: 'ui-session');
final backgroundController = fakeBackgroundController();
await runner.run(task);

expect(uiController.currentSession?.id, 'ui-session');
expect(uiController.sentPrompts, isEmpty);
expect(backgroundController.sentPrompts, [task.description]);
```

另一个测试在 probe 后让租约变 busy，断言 task 保持 queued，不进入 `needsHumanReview`。

- [ ] **Step 2: 运行测试并确认当前使用 UI controller**

Run: `flutter test --no-pub test/tasks/task_runner_test.dart test/ui/acp_client_app_test.dart`

Expected: FAIL。

- [ ] **Step 3: 实现后台 agent pool**

```dart
abstract class TaskAgentLease {
  ChatController get controller;
  Future<void> release();
}

abstract class TaskAgentPool {
  Future<TaskAgentLease?> tryAcquire(String agentName);
  Future<void> dispose();
}
```

生产 pool 按 agent 配置创建独立 `DartAcpAgentClient` 和 `ChatController`，每个 agent 同时只发一个 lease。TaskRunner 必须检查 `newSession()` 返回 true、session ID 变化且 `sendPrompt()` 返回 submitted；任一步失败都抛出明确的 busy/agent error。

- [ ] **Step 4: 运行 runner/App 测试并提交**

Run: `flutter test --no-pub test/tasks/task_runner_test.dart test/ui/acp_client_app_test.dart`

Expected: PASS。

```bash
git add lib/tasks/task_agent_pool.dart lib/tasks/task_runner.dart lib/app.dart test/tasks/task_runner_test.dart test/ui/acp_client_app_test.dart
git commit -m "fix: isolate background task agents"
```

### Task 6: 合并流式事件、限制 metadata 并生成稳定唯一 Artifact ID

**Files:**
- Create: `lib/tasks/task_event_buffer.dart`
- Create: `lib/tasks/task_data_sanitizer.dart`
- Modify: `lib/tasks/task_runner.dart`
- Modify: `lib/tasks/task_inbox_controller.dart`
- Modify: `lib/tasks/artifact_collector.dart`
- Modify: `lib/tasks/task_inbox_snapshot.dart`
- Test: `test/tasks/task_runner_test.dart`
- Test: `test/tasks/artifact_collector_test.dart`
- Create: `test/tasks/task_inbox_snapshot_test.dart`

- [ ] **Step 1: 写入 10k delta 批写和跨重启 ID 测试**

```dart
for (var index = 0; index < 10000; index += 1) {
  buffer.addAssistantDelta('x');
}
await fakeClock.elapse(const Duration(milliseconds: 200));
await buffer.flush();
expect(repository.appendEventsCallCount, lessThanOrEqualTo(2));
expect(repository.events.single.text.length, 10000);
```

两个 `ArtifactCollector` 实例对同一 task 的不同 run 收集首个产物，ID 必须不同，保存重载后两条都存在。

- [ ] **Step 2: 运行测试并确认当前产生 10k 次保存和重复 ID**

Run: `flutter test --no-pub test/tasks/task_runner_test.dart test/tasks/artifact_collector_test.dart test/tasks/task_inbox_snapshot_test.dart`

Expected: FAIL。

- [ ] **Step 3: 实现 200ms buffer 和 metadata 上限**

`TaskEventBuffer` 只合并连续 assistant delta，tool/status 等边界先 flush。metadata canonical JSON 超过 64 KiB 时替换为：

```dart
<String, Object?>{
  'truncated': true,
  'original_bytes': originalBytes,
  'sha256': digest,
}
```

turn 结束、错误、取消和 dispose 都必须 await flush。

- [ ] **Step 4: 使用 task/run scoped ID 并拒绝全局重复**

```dart
String artifactId({required String taskId, required String runId}) {
  final nonce = _randomBytes(16);
  return 'artifact-$taskId-$runId-${base64UrlEncode(nonce).replaceAll('=', '')}';
}
```

`TaskInboxSnapshot.fromJsonStrict` 对重复 ID 抛 `FormatException`，不再静默覆盖。

- [ ] **Step 5: 运行第二批全部测试与全量守门**

Run: `flutter test --no-pub test/tasks test/ui/acp_client_app_test.dart`

Expected: PASS。

Run: `flutter analyze --no-pub`

Expected: `No issues found!`

Run: `flutter test --no-pub`

Expected: 全部通过。

- [ ] **Step 6: 提交事件和产物修复**

```bash
git add lib/tasks/task_event_buffer.dart lib/tasks/task_data_sanitizer.dart lib/tasks/task_runner.dart lib/tasks/task_inbox_controller.dart lib/tasks/artifact_collector.dart lib/tasks/task_inbox_snapshot.dart test/tasks/task_runner_test.dart test/tasks/artifact_collector_test.dart test/tasks/task_inbox_snapshot_test.dart
git commit -m "fix: batch task events and preserve artifacts"
```
