# Spec: Flutter UI + dart_acp + Codex ACP Client PoC

## 目标

实现一个 Flutter Desktop ACP Client PoC，通过 `dart_acp` 启动并连接本地 `codex` agent CLI，完成：

1. Flutter 基础 UI 组件渲染正确
2. Codex ACP 初始化成功
3. 创建 session
4. 发送 prompt
5. 流式展示 agent 输出
6. 支持停止、重连、错误展示
7. 有 widget test 覆盖 UI 渲染

## 技术选型

- Flutter Desktop：macOS 优先
- Dart package：`dart_acp`
- Agent CLI：`codex`
- 状态管理：先用 `ChangeNotifier`，不要引入 Riverpod/Bloc
- UI 风格：清爽、桌面工具、Linear 风格
- 测试：
  - `flutter test`
  - widget test
  - ACP 层用 fake client，不依赖真实 codex

## 目录结构

```text
lib/
  main.dart
  app.dart

  acp/
    acp_agent_client.dart
    dart_acp_agent_client.dart
    fake_agent_client.dart
    agent_event.dart
    agent_session.dart

  state/
    chat_controller.dart
    connection_state.dart

  ui/
    shell/app_shell.dart
    components/agent_toolbar.dart
    components/session_sidebar.dart
    components/chat_timeline.dart
    components/prompt_input.dart
    components/status_bar.dart
    components/error_banner.dart

test/
  ui/
    app_shell_test.dart
    chat_timeline_test.dart
    prompt_input_test.dart
  state/
    chat_controller_test.dart
```

## 核心架构

```text
Flutter UI
  ↓
ChatController
  ↓
AcpAgentClient interface
  ↓
DartAcpAgentClient
  ↓
dart_acp
  ↓
codex ACP CLI
```

不要让 UI 直接依赖 `dart_acp` 类型。必须通过 `AcpAgentClient` 抽象隔离。

## Agent Client 抽象

```dart
abstract class AcpAgentClient {
  Future<void> connect();
  Future<AgentSession> createSession({required String cwd});
  Stream<AgentEvent> sendPrompt({
    required String sessionId,
    required String prompt,
  });
  Future<void> cancel();
  Future<void> dispose();
}
```

## Codex 配置

默认配置：

```dart
agentCommand: 'codex'
agentArgs: ['--acp']
cwd: Directory.current.path
```

如果 `codex --acp` 不可用，UI 需要展示错误，不要 crash。

## UI 页面布局

```text
┌──────────────────────────────────────────────┐
│ Toolbar: Codex ACP | Connected | New Session │
├───────────────┬──────────────────────────────┤
│ Session List  │ Chat Timeline                │
│               │                              │
│               │ Agent / User messages        │
│               │ Streaming output             │
├───────────────┴──────────────────────────────┤
│ Prompt input + Send + Stop                   │
├──────────────────────────────────────────────┤
│ Status bar: cwd / session / latency / error  │
└──────────────────────────────────────────────┘
```

## 必须实现的基础组件

### 1. AgentToolbar

显示：

- app title: `ACP Client`
- agent name: `Codex`
- connection badge:
  - disconnected
  - connecting
  - connected
  - error
- New Session button
- Reconnect button

验收：

- 初始状态显示 disconnected
- connect 中显示 connecting
- 成功后显示 connected
- 失败后显示 error

### 2. SessionSidebar

显示 session 列表。

初版只需要：

- 当前 session
- session id 简写
- cwd
- created time

没有 session 时显示 empty state。

### 3. ChatTimeline

显示消息流：

- user prompt
- agent streaming chunk
- tool call / log / error event

消息类型：

```dart
enum AgentEventType {
  userMessage,
  agentTextDelta,
  agentTextDone,
  toolCall,
  error,
  status,
}
```

验收：

- 空状态显示 `Start a session to chat with Codex`
- 发送 prompt 后立即显示 user message
- agent delta 流式 append 到同一条 assistant message
- error event 用红色 banner/card 展示

### 4. PromptInput

包含：

- 多行输入框
- Send button
- Stop button
- Enter 发送
- Shift+Enter 换行

验收：

- 空输入不能发送
- sending 状态下 Send disabled
- sending 状态下 Stop enabled
- 停止后恢复 Send

### 5. StatusBar

显示：

- cwd
- session id
- connection state
- last error
- streaming 状态

## 状态机

```text
disconnected
  -> connecting
  -> connected
  -> sessionReady
  -> streaming
  -> sessionReady

任意状态 -> error
error -> reconnecting -> connected
```

## ChatController 行为

必须包含：

```dart
class ChatController extends ChangeNotifier {
  ConnectionStatus status;
  AgentSession? currentSession;
  List<ChatMessage> messages;
  String? lastError;
  bool isStreaming;

  Future<void> connect();
  Future<void> newSession();
  Future<void> sendPrompt(String text);
  Future<void> stop();
  Future<void> reconnect();
}
```

## dart_acp 集成要求

`DartAcpAgentClient` 负责：

1. 启动 Codex ACP process
2. initialize
3. create session
4. prompt streaming
5. cancel
6. dispose process

伪代码：

```dart
final client = await AcpClient.start(
  config: AcpConfig(
    agentCommand: 'codex',
    agentArgs: ['--acp'],
  ),
);

await client.initialize();

final sessionId = await client.newSession(cwd);

final stream = client.prompt(
  sessionId: sessionId,
  content: prompt,
);
```

如果当前 `dart_acp` API 名称和伪代码不同，以 package 实际 API 为准，但架构不变。

## 测试要求

### Widget tests

必须覆盖：

1. `AgentToolbar` 初始渲染
2. `AgentToolbar` connected/error 状态
3. `PromptInput` 空输入不可发送
4. `PromptInput` 输入后可发送
5. `ChatTimeline` 空状态
6. `ChatTimeline` user + assistant 消息渲染
7. streaming delta append 正确
8. error banner 渲染

### Controller tests

用 `FakeAgentClient` 模拟：

1. connect success
2. connect failure
3. create session success
4. send prompt returns stream chunks
5. send prompt error
6. stop cancels streaming

## FakeAgentClient

必须实现固定流：

```text
Hello
,
 I am Codex
.
```

最终 UI 应显示：

```text
Hello, I am Codex.
```

## 验收命令

```bash
flutter analyze
dart format .
flutter test
flutter run -d macos
```

## Definition of Done

- `flutter analyze` 无 error
- `flutter test` 全绿
- macOS 桌面 app 能启动
- 未安装 codex 时 UI 显示错误，不崩溃
- 安装 codex 且支持 ACP 时：
  - connect 成功
  - new session 成功
  - prompt 有流式输出
- UI 基础组件布局正确：
  - toolbar
  - sidebar
  - timeline
  - input
  - status bar

## 非目标

暂不实现：

- 多 agent 切换
- Web/Mobile
- MCP server
- 文件树
- 代码 diff 视图
- tool approval
- session resume
- OAuth/auth UI

## 后续扩展点

第二阶段再加：

1. agent config 页面
2. Claude Code / Gemini CLI adapter
3. tool approval panel
4. file mention
5. terminal log panel
6. session persistence
7. remote ACP transport
