# 第四批：发布、测试隔离与最终复审实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 隔离测试用户数据、消除墙钟偶发失败、建立可失败的 macOS 制品检查和正式签名公证流程，并重新完整评审直到问题清单为空。

**Architecture:** 测试统一使用临时 HOME 和显式注入 repository；scheduler timer 由可控接口驱动；macOS 本地 ad-hoc build 与正式分发脚本分开，所有二进制处理和验证失败都会终止流程；最终按原评审范围重新审计。

**Tech Stack:** Flutter 3.44、Dart 3.12、XCTest、Xcode build tools、codesign、notarytool、GitHub Actions、shell。

---

### Task 1: 隔离所有 Flutter 测试的 HOME 和任务 repository

**Files:**
- Create: `tool/flutter_test_isolated.sh`
- Modify: `test/support/memory_task_repository.dart`
- Modify: `test/ui/acp_client_app_test.dart`
- Modify: `README.md`

- [ ] **Step 1: 写入默认路径未访问真实 HOME 的失败测试**

```dart
testWidgets('AcpClientApp uses only the injected task repository', (tester) async {
  final repository = RecordingTaskRepository();
  await tester.pumpWidget(AcpClientApp(
    config: const AcpClientConfig(),
    autoLoadWorkspaceSessions: false,
    taskInboxController: TaskInboxController(repository: repository),
  ));
  await tester.pumpAndSettle();
  expect(repository.loadCount, 1);
  expect(repository.pathsOpened, isEmpty);
});
```

检查 `acp_client_app_test.dart` 的每个 `AcpClientApp` 构造都通过统一 helper 注入内存 controller。

- [ ] **Step 2: 运行测试并用临时 queued fixture 证明旧路径会被触发**

Run: `flutter test --no-pub test/ui/acp_client_app_test.dart --plain-name 'AcpClientApp uses only the injected task repository'`

Expected: FAIL；当前未注入场景创建真实默认 store。

- [ ] **Step 3: 创建测试 helper 并改造所有 App widget tests**

```dart
class TestTaskHarness {
  TestTaskHarness();
  final MemoryTaskRepository repository = MemoryTaskRepository();
  late final TaskInboxController controller =
      TaskInboxController(repository: repository);

  Future<void> initialize() => controller.load();
  void dispose() => controller.dispose();
}
```

`test/ui/acp_client_app_test.dart` 的 `setUp` 创建并初始化 harness，`tearDown` dispose；所有 App 实例显式传 `taskInboxController`。

- [ ] **Step 4: 创建隔离测试脚本**

`tool/flutter_test_isolated.sh` 内容：

```sh
#!/bin/sh
set -eu

TEST_HOME="$(mktemp -d "${TMPDIR:-/tmp}/ianvs-acp-test-home.XXXXXX")"
cleanup() { rm -rf "${TEST_HOME}"; }
trap cleanup EXIT INT TERM

export HOME="${TEST_HOME}"
export XDG_CONFIG_HOME="${TEST_HOME}/.config"
export FLUTTER_SUPPRESS_ANALYTICS=true
exec flutter test --no-pub "$@"
```

README 把全量测试命令改为 `./tool/flutter_test_isolated.sh`。

- [ ] **Step 5: 运行隔离测试并提交**

Run: `./tool/flutter_test_isolated.sh test/ui/acp_client_app_test.dart`

Expected: PASS；临时 HOME 中允许生成测试文件，真实 `~/.config/ianvs-acp` mtime 不变。

```bash
git add tool/flutter_test_isolated.sh test/support/memory_task_repository.dart test/ui/acp_client_app_test.dart README.md
git commit -m "test: isolate app state from user home"
```

### Task 2: 用可控 timer 替换 retry 墙钟测试

**Files:**
- Create: `lib/tasks/task_wake_timer.dart`
- Modify: `lib/tasks/task_scheduler.dart`
- Modify: `test/tasks/task_scheduler_test.dart`

- [ ] **Step 1: 写入不经过真实延时的 retry 顺序测试**

```dart
final timers = FakeTaskWakeTimerFactory(clock: clock);
final scheduler = TaskScheduler(
  taskController: controller,
  worker: worker,
  clock: clock.now,
  wakeTimerFactory: timers.call,
);
await scheduler.start();
timers.elapse(const Duration(milliseconds: 50));
await pumpEventQueue();
expect(worker.startedTaskIds, ['task-early']);
```

- [ ] **Step 2: 运行测试并确认构造器缺少 timer 注入**

Run: `flutter test --no-pub test/tasks/task_scheduler_test.dart --plain-name 'TaskScheduler moves retry wake earlier for newly queued task'`

Expected: FAIL；`wakeTimerFactory` 尚不存在。

- [ ] **Step 3: 增加最小 timer 抽象**

```dart
abstract class TaskWakeTimer {
  bool get isActive;
  void cancel();
}

typedef TaskWakeTimerFactory = TaskWakeTimer Function(
  Duration delay,
  void Function() callback,
);

class DartTaskWakeTimer implements TaskWakeTimer {
  DartTaskWakeTimer(Duration delay, void Function() callback)
    : _timer = Timer(delay, callback);
  final Timer _timer;
  @override bool get isActive => _timer.isActive;
  @override void cancel() => _timer.cancel();
}
```

Scheduler 默认 factory 包装 Dart Timer；测试 fake 只在 `elapse` 达到 deadline 时同步触发。

- [ ] **Step 4: 删除所有 50ms/200ms 轮询并提交**

Run: `flutter test --no-pub test/tasks/task_scheduler_test.dart`

Expected: PASS，测试中不再包含 `DateTime.now()` 或小于 1 秒的真实 retry wait。

```bash
git add lib/tasks/task_wake_timer.dart lib/tasks/task_scheduler.dart test/tasks/task_scheduler_test.dart
git commit -m "test: make scheduler retries deterministic"
```

### Task 3: 修正 macOS 身份并让二进制处理失败即停止

**Files:**
- Modify: `macos/Runner/Configs/AppInfo.xcconfig`
- Modify: `macos/Runner.xcodeproj/project.pbxproj`
- Modify: `macos/Runner/Release.entitlements`
- Create: `macos/scripts/normalize_merman.sh`
- Create: `tool/verify_macos_bundle.sh`
- Test: `macos/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: 写入原生配置测试**

```swift
func testBundleIdentifierIsProductionIdentifier() {
  XCTAssertEqual(Bundle.main.bundleIdentifier, "com.ianvs.acp")
}

func testRegisteredDeepLinkScheme() {
  let urlTypes = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
  let schemes = urlTypes?.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
  XCTAssertTrue(schemes?.contains("ianvs-acp") == true)
}
```

- [ ] **Step 2: 运行原生测试并确认旧 bundle ID 失败**

Run: `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: FAIL；当前 bundle ID 是 `com.example.ianvsAcp`。

- [ ] **Step 3: 更新 bundle 和 Hardened Runtime**

`AppInfo.xcconfig`：

```xcconfig
PRODUCT_BUNDLE_IDENTIFIER = com.ianvs.acp
PRODUCT_COPYRIGHT = Copyright © 2026 Ianvs. All rights reserved.
```

Release target 增加 `ENABLE_HARDENED_RUNTIME = YES`。App Sandbox 保持 false，因为本产品必须启动本地 agent；不要把无效 entitlement 当作边界。

- [ ] **Step 4: 提取严格的 merman 脚本**

`normalize_merman.sh` 使用 `set -euf`，删除所有 `|| true`。每个候选 Mach-O 修改失败立即退出。签名仅在 `CODE_SIGNING_ALLOWED != NO` 时执行；ad-hoc 使用 `--timestamp=none`，Developer ID 使用默认 secure timestamp。PBX phase 只调用：

```sh
"${SRCROOT}/scripts/normalize_merman.sh"
```

- [ ] **Step 5: 创建制品验证脚本**

```sh
#!/bin/sh
set -eu
APP="${1:?usage: verify_macos_bundle.sh /path/to/App.app}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${APP}/Contents/Info.plist")" = "com.ianvs.acp"
file "${APP}/Contents/MacOS/ACP Client" | grep -q 'x86_64'
file "${APP}/Contents/MacOS/ACP Client" | grep -q 'arm64'
codesign --verify --deep --strict --verbose=2 "${APP}"
otool -L "${APP}/Contents/MacOS/ACP Client" | grep -q '@rpath/libmerman_ffi.dylib'
```

- [ ] **Step 6: 构建、验证并提交**

Run: `flutter build macos --release`

Expected: PASS。

Run: `./tool/verify_macos_bundle.sh 'build/macos/Build/Products/Release/ACP Client.app'`

Expected: PASS。

```bash
git add macos/Runner/Configs/AppInfo.xcconfig macos/Runner.xcodeproj/project.pbxproj macos/Runner/Release.entitlements macos/scripts/normalize_merman.sh tool/verify_macos_bundle.sh macos/RunnerTests/RunnerTests.swift
git commit -m "build: verify macOS release artifacts"
```

### Task 4: 增加正式签名、公证脚本和 macOS CI

**Files:**
- Create: `tool/package_macos_release.sh`
- Create: `tool/sign_macos_bundle.sh`
- Create: `.github/workflows/macos.yml`
- Create: `.github/dependabot.yml`
- Modify: `README.md`

- [ ] **Step 1: 创建必须具备凭据的正式分发脚本**

```sh
#!/bin/sh
set -eu
: "${IANVS_DEVELOPER_ID:?set IANVS_DEVELOPER_ID}"
: "${IANVS_NOTARY_PROFILE:?set IANVS_NOTARY_PROFILE}"

flutter build macos --release
APP='build/macos/Build/Products/Release/ACP Client.app'
./tool/sign_macos_bundle.sh "${APP}" "${IANVS_DEVELOPER_ID}"
./tool/verify_macos_bundle.sh "${APP}"
ditto -c -k --keepParent "${APP}" build/ACP-Client.zip
xcrun notarytool submit build/ACP-Client.zip \
  --keychain-profile "${IANVS_NOTARY_PROFILE}" --wait
xcrun stapler staple "${APP}"
xcrun stapler validate "${APP}"
spctl --assess --type execute --verbose=4 "${APP}"
```

脚本不得为缺少凭据提供静默 ad-hoc fallback。

`tool/sign_macos_bundle.sh` 先按路径深度从内到外签署 `Contents/Frameworks` 中的 dylib、framework 和 helper，再签主 app；每次调用均使用 `--options runtime --timestamp`，禁止使用 `codesign --deep` 代替正确的嵌套签名顺序。

- [ ] **Step 2: 创建 CI 守门**

`.github/workflows/macos.yml` 在 `macos-15` 固定 Flutter `3.44.0`，依次运行：

```yaml
name: macOS verification
on:
  pull_request:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  verify:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.44.0'
          channel: stable
          cache: true
      - run: flutter pub get
      - run: flutter analyze --no-pub
      - run: ./tool/flutter_test_isolated.sh
      - run: xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
      - run: flutter build macos --release
      - run: ./tool/verify_macos_bundle.sh 'build/macos/Build/Products/Release/ACP Client.app'
```

签名公证由受保护的 release environment 或维护者的安全构建机调用 `package_macos_release.sh`；普通 PR workflow 不接触签名和公证秘密。

- [ ] **Step 3: 增加依赖更新监控和文档**

Dependabot 配置使用：

```yaml
version: 2
updates:
  - package-ecosystem: pub
    directory: /
    schedule:
      interval: weekly
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
```

README 区分本地 release、可验证 ad-hoc 制品和正式签名公证，不再把单条 `flutter build` 描述为对外发布流程。

- [ ] **Step 4: 校验 workflow 和脚本并提交**

Run: `sh -n tool/package_macos_release.sh tool/sign_macos_bundle.sh tool/verify_macos_bundle.sh tool/flutter_test_isolated.sh macos/scripts/normalize_merman.sh`

Expected: exit 0。

Run: `rg -n '\|\| true|com\.example|timestamp=none' macos tool .github README.md`

Expected: 只允许 ad-hoc 分支中有明确注释的 `timestamp=none`；其余无匹配。

```bash
git add tool/package_macos_release.sh tool/sign_macos_bundle.sh .github/workflows/macos.yml .github/dependabot.yml README.md
git commit -m "ci: add macOS release gates"
```

### Task 5: 全量验证、依赖公告检查和第一次复审

**Files:**
- Modify only if review finds a new issue; each modification requires its own failing test and commit.

- [ ] **Step 1: 运行格式、静态分析和隔离全量测试**

Run: `dart format --output=none --set-exit-if-changed lib test third_party/dart_acp/lib`

Expected: exit 0。

Run: `flutter analyze --no-pub`

Expected: `No issues found!`

Run: `./tool/flutter_test_isolated.sh`

Expected: 全部测试通过。

- [ ] **Step 2: 运行原生测试和 release build**

Run: `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`

Expected: 全部 RunnerTests 通过。

Run: `flutter build macos --release`

Expected: PASS。

Run: `./tool/verify_macos_bundle.sh 'build/macos/Build/Products/Release/ACP Client.app'`

Expected: PASS。

- [ ] **Step 3: 检查依赖和官方安全公告**

Run: `flutter pub outdated`

Expected: 输出被逐项审阅；安全修复版本必须升级或在最终报告中给出官方公告证明当前锁定版本不受影响。

检查 `pubspec.lock`、`macos/Podfile.lock` 和 npm adapter 精确版本对应的 pub.dev、GitHub Security Advisory、OSV 或 npm 官方 advisory。记录查询日期、包名、锁定版本和结果；不得用“没有搜索结果”代替版本影响判断。

- [ ] **Step 4: 按原范围重新做架构、可靠性、安全和发布评审**

逐项检查设计文档中的 21 个验收项，并重新扫描 `lib/`、`third_party/dart_acp/`、`test/`、`macos/` 和 CI。每个新发现先建立稳定复现和失败测试，再修复并重复 Step 1–4。

- [ ] **Step 5: 只有问题清单为空时提交最终验证记录**

把最终命令、版本、测试数、构建和复审结果写入 `docs/reviews/2026-07-10-remediation-verification.md`，不得写入任何 token、用户 prompt 或本地秘密。

```bash
git add docs/reviews/2026-07-10-remediation-verification.md
git commit -m "docs: record remediation verification"
```
