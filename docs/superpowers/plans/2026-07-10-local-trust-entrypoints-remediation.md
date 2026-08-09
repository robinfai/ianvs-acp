# 第三批：本地隐私、远程连接与外部入口整改实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 消除凭据和敏感任务数据明文保存、状态文件并发覆盖、远程明文认证、浮动 npm adapter 以及 deep link 无确认连接问题。

**Architecture:** 所有本地 JSON 通过统一原子文件写入器和串行状态队列保存；秘密值迁移到 macOS Keychain，配置只保存引用；远程 transport 在解析阶段强制 TLS；deep link 先形成候选请求，只有用户确认后执行。

**Tech Stack:** Dart 3.12、Flutter MethodChannel、macOS Security.framework、Swift、Flutter Test、XCTest。

---

### Task 1: 统一原子文件写入、权限和侧栏状态串行化

**Files:**
- Create: `lib/platform/secure_atomic_file.dart`
- Modify: `lib/config/acp_config_store.dart`
- Modify: `lib/config/acp_agent_discovery.dart`
- Modify: `lib/workspace/workspace_sidebar_state_store.dart`
- Test: `test/platform/secure_atomic_file_test.dart`
- Test: `test/config/acp_config_store_test.dart`
- Test: `test/workspace/workspace_sidebar_state_store_test.dart`

- [ ] **Step 1: 写入文件模式、中断安全和并发字段保留测试**

```dart
test('writes private JSON atomically with 0600 mode', () async {
  final file = File('${temp.path}/config/settings.json');
  await SecureAtomicFile.writeString(file, '{"ok":true}\n');
  final mode = (await file.stat()).mode & 0x1ff;
  expect(mode, 0x180); // 0600
  expect((await file.parent.stat()).mode & 0x1ff, 0x1c0); // 0700
});
```

侧栏测试用 barrier 同时执行 expanded/workspace/session 保存，最终 JSON 必须保留三个字段的最新值；注入 rename 失败时旧文件内容不变。

- [ ] **Step 2: 运行测试并确认 mode 和并发保存失败**

Run: `flutter test --no-pub test/platform/secure_atomic_file_test.dart test/config/acp_config_store_test.dart test/workspace/workspace_sidebar_state_store_test.dart`

Expected: FAIL；当前直接覆盖且新文件通常为 0644。

- [ ] **Step 3: 实现安全原子写入器**

```dart
class SecureAtomicFile {
  static Future<void> writeString(File target, String value) async {
    await target.parent.create(recursive: true);
    await Process.run('chmod', ['0700', target.parent.path]);
    final temporary = File(
      '${target.path}.tmp-${pid}-${DateTime.now().microsecondsSinceEpoch}',
    );
    final sink = temporary.openWrite(mode: FileMode.writeOnly);
    sink.write(value);
    await sink.flush();
    await sink.close();
    await Process.run('chmod', ['0600', temporary.path]);
    await temporary.rename(target.path);
  }
}
```

实现时检查 `chmod` exit code；失败要删除临时文件并抛错。不要删除或截断原目标后再 rename。

- [ ] **Step 4: 侧栏 store 使用单一内存状态和写队列**

`WorkspaceSidebarStateStore` 保存方法统一调用：

```dart
Future<void> _mutate(
  void Function(Map<String, Object?> state) mutation,
) {
  return _writes = _writes.then((_) async {
    final state = _cachedState ?? await _readState();
    mutation(state);
    await SecureAtomicFile.writeString(file, _encode(state));
    _cachedState = state;
  });
}
```

只有写入成功后更新 session signature。

- [ ] **Step 5: 运行测试并提交**

Run: `flutter test --no-pub test/platform/secure_atomic_file_test.dart test/config/acp_config_store_test.dart test/workspace/workspace_sidebar_state_store_test.dart`

Expected: PASS。

```bash
git add lib/platform/secure_atomic_file.dart lib/config/acp_config_store.dart lib/config/acp_agent_discovery.dart lib/workspace/workspace_sidebar_state_store.dart test/platform/secure_atomic_file_test.dart test/config/acp_config_store_test.dart test/workspace/workspace_sidebar_state_store_test.dart
git commit -m "fix: atomically persist private local state"
```

### Task 2: 增加 SecretStore 和 macOS Keychain 实现

**Files:**
- Create: `lib/config/secret_store.dart`
- Create: `lib/config/macos_keychain_secret_store.dart`
- Modify: `macos/Runner/AppDelegate.swift`
- Modify: `macos/RunnerTests/RunnerTests.swift`
- Create: `test/config/secret_store_test.dart`

- [ ] **Step 1: 写入 Dart contract 和 MethodChannel 测试**

```dart
test('stores and resolves a secret by stable reference', () async {
  final reference = await store.put(
    namespace: 'agent/Codex/env',
    key: 'OPENAI_API_KEY',
    value: 'secret-value',
  );
  expect(reference, startsWith('keychain://ianvs-acp/'));
  expect(await store.get(reference), 'secret-value');
  await store.delete(reference);
  expect(await store.get(reference), isNull);
});
```

- [ ] **Step 2: 运行测试并确认类型不存在**

Run: `flutter test --no-pub test/config/secret_store_test.dart`

Expected: FAIL；尚无 SecretStore。

- [ ] **Step 3: 定义 Dart 接口和 Keychain channel**

```dart
abstract class SecretStore {
  Future<String> put({
    required String namespace,
    required String key,
    required String value,
  });
  Future<String?> get(String reference);
  Future<void> delete(String reference);
}

class MacosKeychainSecretStore implements SecretStore {
  static const MethodChannel _channel = MethodChannel('ianvs_acp/keychain');
  // put/get/delete validate keychain://ianvs-acp/<account> references.
}
```

- [ ] **Step 4: 在 Swift 中实现 Security.framework CRUD**

AppDelegate 注册 `ianvs_acp/keychain`。以 service `com.ianvs.acp.secrets`、account 为稳定 SHA-256 标识，使用 `kSecClassGenericPassword`、`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。update 先 `SecItemUpdate`，not found 时 `SecItemAdd`；read 使用 `SecItemCopyMatching`；delete 使用 `SecItemDelete`。除 item not found 外的 OSStatus 转为 FlutterError。

RunnerTests 使用独立 service suffix 验证 put/read/update/delete，并在 tearDown 删除测试项。

- [ ] **Step 5: 运行 Dart 和原生测试并提交**

Run: `flutter test --no-pub test/config/secret_store_test.dart`

Expected: PASS。

Run: `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: RunnerTests PASS。

```bash
git add lib/config/secret_store.dart lib/config/macos_keychain_secret_store.dart macos/Runner/AppDelegate.swift macos/RunnerTests/RunnerTests.swift test/config/secret_store_test.dart
git commit -m "feat: store ACP secrets in macOS Keychain"
```

### Task 3: 把 env/header 从 JSON 无损迁移为秘密引用

**Files:**
- Create: `lib/config/acp_config_secret_migrator.dart`
- Modify: `lib/config/acp_client_config.dart`
- Modify: `lib/config/acp_config_store.dart`
- Modify: `lib/main.dart`
- Modify: `lib/app.dart`
- Test: `test/config/acp_config_secret_migrator_test.dart`
- Test: `test/config/acp_config_store_test.dart`

- [ ] **Step 1: 写入 JSON 不含秘密和失败不丢值测试**

```dart
final migrated = await migrator.migrate(rawConfig);
expect(jsonEncode(migrated.json), isNot(contains('Bearer real-token')));
expect(
  migrated.json['agent_servers']['Remote']['header_refs']['Authorization'],
  startsWith('keychain://ianvs-acp/'),
);
expect(migrated.resolved.agentServers.single.headers['Authorization'], 'Bearer real-token');
```

让 fake SecretStore 在第二个 put 抛错，断言原配置文件逐字节不变，已写入的新 Keychain 项被清理。

- [ ] **Step 2: 运行测试并确认当前 JSON 含秘密**

Run: `flutter test --no-pub test/config/acp_config_secret_migrator_test.dart test/config/acp_config_store_test.dart`

Expected: FAIL。

- [ ] **Step 3: 扩展配置 schema**

Agent server 使用 `env_refs`、`header_refs`，MCP server同样支持 `env_refs/header_refs`。内存中的 `AgentServerConfig.env/headers` 仍是已解析值，另保存 refs 供写回：

```dart
final Map<String, String> envRefs;
final Map<String, String> headerRefs;
```

`toJson()` 只输出 refs，不输出 resolved 值。

- [ ] **Step 4: 实现两阶段秘密迁移**

迁移器先把全部值写入 SecretStore 并记录新 refs，再用 `SecureAtomicFile` 更新 JSON。配置写入成功后才返回 resolved config；任一步失败删除本次新建 refs，保留旧文件。加载流程先解析引用，再异步 resolve，缺失 Keychain 项必须显示具体 agent/字段错误并阻止连接。

- [ ] **Step 5: 运行配置测试并提交**

Run: `flutter test --no-pub test/config test/ui/agent_config_dialog_test.dart`

Expected: PASS。

```bash
git add lib/config/acp_config_secret_migrator.dart lib/config/acp_client_config.dart lib/config/acp_config_store.dart lib/main.dart lib/app.dart test/config/acp_config_secret_migrator_test.dart test/config/acp_config_store_test.dart test/ui/agent_config_dialog_test.dart
git commit -m "fix: remove ACP secrets from JSON"
```

### Task 4: 非 loopback 远程连接强制 TLS

**Files:**
- Modify: `lib/config/acp_client_config.dart`
- Modify: `lib/acp/acp_permission_reviewer.dart`
- Test: `test/config/acp_client_config_test.dart`
- Test: `test/acp/acp_permission_reviewer_test.dart`

- [ ] **Step 1: 写入远程明文拒绝和 loopback 允许测试**

```dart
for (final url in ['http://agent.example.com/acp', 'ws://10.0.0.5/acp']) {
  expect(() => configWithUrl(url), throwsFormatException);
}
expect(configWithUrl('http://127.0.0.1:8080/acp'), isA<AcpClientConfig>());
expect(configWithUrl('ws://[::1]:8080/acp'), isA<AcpClientConfig>());
expect(configWithUrl('https://agent.example.com/acp'), isA<AcpClientConfig>());
```

- [ ] **Step 2: 运行测试并确认远程 HTTP/WS 当前被接受**

Run: `flutter test --no-pub test/config/acp_client_config_test.dart test/acp/acp_permission_reviewer_test.dart`

Expected: FAIL。

- [ ] **Step 3: 增加统一 endpoint 校验**

```dart
bool _isLoopback(Uri uri) {
  final host = uri.host.toLowerCase();
  return host == 'localhost' || host == '127.0.0.1' || host == '::1';
}

void validateAcpEndpoint(Uri uri) {
  if ((uri.scheme == 'http' || uri.scheme == 'ws') && !_isLoopback(uri)) {
    throw FormatException('Remote ACP endpoints require TLS: $uri');
  }
}
```

Agent、MCP reviewer 和所有 remote config 共用该函数。

- [ ] **Step 4: 运行测试并提交**

Run: `flutter test --no-pub test/config/acp_client_config_test.dart test/acp/acp_permission_reviewer_test.dart`

Expected: PASS。

```bash
git add lib/config/acp_client_config.dart lib/acp/acp_permission_reviewer.dart test/config/acp_client_config_test.dart test/acp/acp_permission_reviewer_test.dart
git commit -m "fix: require TLS for remote ACP endpoints"
```

### Task 5: 固定自动发现 adapter 的精确版本

**Files:**
- Modify: `lib/config/acp_agent_discovery.dart`
- Modify: `README.md`
- Test: `test/config/acp_agent_discovery_test.dart`

- [ ] **Step 1: 写入精确版本测试**

```dart
final agents = AcpAgentDiscovery.discover(
  environment: <String, String>{'PATH': '/opt/homebrew/bin'},
  fileExists: (_) => true,
);
expect(agents.first.args.single, matches(RegExp(r'^@zed-industries/codex-acp@[0-9]+\.[0-9]+\.[0-9]+$')));
expect(agents.last.args.last, matches(RegExp(r'^pi-acp@[0-9]+\.[0-9]+\.[0-9]+$')));
```

- [ ] **Step 2: 运行测试并确认当前为浮动包名**

Run: `flutter test --no-pub test/config/acp_agent_discovery_test.dart`

Expected: FAIL。

- [ ] **Step 3: 固定维护版本并记录升级流程**

```dart
static const String codexAcpVersion = '0.16.0';
static const String piAcpVersion = '0.0.31';
static const String codexAcpPackage = '@zed-industries/codex-acp@$codexAcpVersion';
static const String piAcpPackage = 'pi-acp@$piAcpVersion';
```

版本已于 2026-07-10 通过 npm 官方 registry 的 `npm view <package> version` 核对。升级必须通过单独代码变更和测试。

- [ ] **Step 4: 运行测试并提交**

Run: `flutter test --no-pub test/config/acp_agent_discovery_test.dart`

Expected: PASS。

```bash
git add lib/config/acp_agent_discovery.dart README.md test/config/acp_agent_discovery_test.dart
git commit -m "fix: pin discovered ACP adapters"
```

### Task 6: Deep link 必须确认且 cwd 受限

**Files:**
- Create: `lib/startup/deep_link_request.dart`
- Create: `lib/ui/components/deep_link_confirmation_dialog.dart`
- Modify: `lib/startup/startup_options.dart`
- Modify: `lib/app.dart`
- Test: `test/startup/startup_options_test.dart`
- Test: `test/ui/acp_client_app_test.dart`

- [ ] **Step 1: 写入确认前不连接和危险 cwd 拒绝测试**

```dart
await deepLinkChannel.handlePlatformMessage(
  const StandardMethodCodec().encodeMethodCall(
    const MethodCall('openDeepLink', 'ianvs-acp://session?id=s1&cwd=%2F&agent=Codex'),
  ),
  (_) {},
);
await tester.pumpAndSettle();
expect(find.text('Open external session?'), findsOneWidget);
expect(fake.resumeCalls, isEmpty);
expect(find.textContaining('Workspace is too broad'), findsOneWidget);
```

- [ ] **Step 2: 运行测试并确认当前立即 resume**

Run: `flutter test --no-pub test/startup/startup_options_test.dart test/ui/acp_client_app_test.dart`

Expected: FAIL。

- [ ] **Step 3: 区分命令行可信启动与外部候选请求**

`StartupOptions.fromArgs` 保留显式 CLI flags；`fromDeepLink` 返回 `DeepLinkRequest`，包含来源、agent、session、cwd 和 validation errors。cwd 必须绝对、存在，且标准化后不等于 `/` 或当前 HOME。

- [ ] **Step 4: 增加确认对话框**

App 收到 deep link 后只加入待确认队列。对话框展示 agent/session/workspace；validation error 时禁用确认。用户点击确认后才调用 `_resumeFromStartupOptions`，取消则从 handled set 删除并不连接。

- [ ] **Step 5: 运行第三批测试与全量守门**

Run: `flutter test --no-pub test/config test/startup test/ui/acp_client_app_test.dart test/workspace/workspace_sidebar_state_store_test.dart`

Expected: PASS。

Run: `flutter analyze --no-pub`

Expected: `No issues found!`

Run: `flutter test --no-pub`

Expected: 全部通过。

- [ ] **Step 6: 提交 deep link 修复**

```bash
git add lib/startup/deep_link_request.dart lib/ui/components/deep_link_confirmation_dialog.dart lib/startup/startup_options.dart lib/app.dart test/startup/startup_options_test.dart test/ui/acp_client_app_test.dart
git commit -m "fix: confirm external session links"
```
