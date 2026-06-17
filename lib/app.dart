import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'acp/agent_session.dart';
import 'acp/dart_acp_agent_client.dart';
import 'acp/acp_permission_reviewer.dart';
import 'config/acp_agent_discovery.dart';
import 'config/acp_client_config.dart';
import 'config/acp_config_store.dart';
import 'state/chat_controller.dart';
import 'task_center/task_center_controller.dart';
import 'task_center/task_center_mcp_host.dart';
import 'task_center/task_center_models.dart';
import 'task_center/task_center_store.dart';
import 'ui/components/agent_discovery_dialog.dart';
import 'ui/components/new_session_agent_dialog.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_design_tokens.dart';

typedef AgentServerDiscoverer =
    FutureOr<List<AgentServerConfig>> Function(AcpClientConfig config);
typedef DiscoveredAgentServerWriter =
    Future<AcpClientConfig> Function(
      AcpClientConfig config,
      List<AgentServerConfig> servers,
    );
typedef AcpConfigWriter =
    Future<AcpClientConfig> Function(AcpClientConfig config);

class AcpClientApp extends StatefulWidget {
  const AcpClientApp({
    super.key,
    this.controller,
    this.config = const AcpClientConfig(),
    this.startupError,
    this.discoverAgentServers,
    this.writeDiscoveredAgentServers,
    this.writeConfig,
    this.taskCenterController,
    this.taskCenterMcpHost,
  });

  final ChatController? controller;
  final AcpClientConfig config;
  final String? startupError;
  final AgentServerDiscoverer? discoverAgentServers;
  final DiscoveredAgentServerWriter? writeDiscoveredAgentServers;
  final AcpConfigWriter? writeConfig;
  final TaskCenterController? taskCenterController;
  final TaskCenterMcpHost? taskCenterMcpHost;

  @override
  State<AcpClientApp> createState() => _AcpClientAppState();
}

class _AcpClientAppState extends State<AcpClientApp> {
  static const String _initialResumeSessionId = String.fromEnvironment(
    'ACP_RESUME_SESSION_ID',
  );

  late AcpClientConfig _config;
  late String _widgetConfigSignature;
  late ChatController _controller;
  late final String _cwd;
  final Map<String, ChatController> _controllersByAgent =
      <String, ChatController>{};
  final Map<String, String> _controllerSignaturesByAgent = <String, String>{};
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  late final TaskCenterStore _taskCenterStore;
  late final TaskCenterController _taskCenterController;
  late final TaskCenterMcpHost _taskCenterMcpHost;
  late final bool _ownsTaskCenterController;
  late final bool _ownsTaskCenterMcpHost;
  McpServerConfig? _taskCenterMcpServerConfig;
  bool _agentDiscoveryStarted = false;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _widgetConfigSignature = _configSignature(widget.config);
    _cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: Directory.current.path,
    );
    _taskCenterStore = widget.taskCenterController?.store ?? TaskCenterStore();
    _ownsTaskCenterController = widget.taskCenterController == null;
    _taskCenterController =
        widget.taskCenterController ??
        TaskCenterController(store: _taskCenterStore);
    _ownsTaskCenterMcpHost = widget.taskCenterMcpHost == null;
    _taskCenterMcpHost =
        widget.taskCenterMcpHost ??
        TaskCenterMcpHost(
          store: _taskCenterController.store,
          onChanged: _taskCenterController.load,
        );
    if (widget.controller == null) {
      _controller = _cachedControllerFor(_config);
    } else {
      _controller = widget.controller!;
    }
    if (_initialResumeSessionId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_controller.resumeSession(_initialResumeSessionId));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeDiscoverAgents());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_startTaskCenterMcp());
    });
  }

  @override
  void didUpdateWidget(covariant AcpClientApp oldWidget) {
    super.didUpdateWidget(oldWidget);

    final nextConfigSignature = _configSignature(widget.config);
    final configChanged = nextConfigSignature != _widgetConfigSignature;
    final controllerChanged = oldWidget.controller != widget.controller;

    if (controllerChanged) {
      if (oldWidget.controller == null) _disposeCachedControllers();
      _config = widget.config;
      _widgetConfigSignature = nextConfigSignature;
      _controller = widget.controller ?? _cachedControllerFor(_config);
      return;
    }

    if (!configChanged) {
      if (widget.controller != null) _controller = widget.controller!;
      return;
    }

    _config = widget.config;
    _widgetConfigSignature = nextConfigSignature;
    if (widget.controller != null) {
      _controller = widget.controller!;
      return;
    }

    _reconcileControllerCache(_config);
    _controller = _cachedControllerFor(_config);
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _disposeCachedControllers();
    }
    if (_ownsTaskCenterMcpHost) {
      unawaited(_taskCenterMcpHost.stop());
    }
    if (_ownsTaskCenterController) {
      _taskCenterController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ACP Client',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      scaffoldMessengerKey: _messengerKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: AppColors.bg,
        useMaterial3: true,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        fontFamily: 'SF Pro Display',
        iconButtonTheme: IconButtonThemeData(
          style: IconButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ),
        dialogTheme: DialogThemeData(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          titleTextStyle: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w800,
            letterSpacing: 0,
          ),
        ),
        textSelectionTheme: TextSelectionThemeData(
          cursorColor: AppColors.primary,
          selectionColor: AppColors.primary.withValues(alpha: 0.18),
        ),
      ),
      home: AppShell(
        controller: _controller,
        agentName: _config.agentName,
        agentServers: _config.selectableAgentServers,
        mcpServers: _effectiveMcpServers(_config),
        additionalDirectories: _config.additionalDirectories,
        clientProviders: _clientProviderConfig(_config),
        configPath: _config.configPath,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: widget.startupError,
        canSwitchAgent: widget.controller == null,
        sessionControllers: _sessionControllers,
        taskCenterController: _taskCenterController,
        onSendWorkspaceMessage: _sendWorkspaceMessageToFastAgent,
        onNewSession: (context) => unawaited(_startNewSession(context)),
        onSelectSession: (session) => unawaited(_selectSession(session)),
        onSelectAgent: widget.controller == null
            ? (agentName) => unawaited(_selectAgent(agentName))
            : null,
        onSaveConfig: widget.controller == null
            ? (config) => _saveConfig(config)
            : null,
      ),
    );
  }

  Future<void> _startTaskCenterMcp() async {
    try {
      await _taskCenterMcpHost.start();
      if (!mounted) return;
      setState(() {
        _taskCenterMcpServerConfig = _taskCenterMcpHost.mcpServerConfig;
      });
      _reconcileControllerCache(_config);
      _controller = _cachedControllerFor(_config);
    } catch (error) {
      _showSnackBar('Could not start task center MCP server: $error');
    }
  }

  Future<void> _maybeDiscoverAgents() async {
    if (_agentDiscoveryStarted || widget.controller != null) return;
    if (_config.configPath == null || _config.configPath!.trim().isEmpty) {
      return;
    }
    _agentDiscoveryStarted = true;

    final discover =
        widget.discoverAgentServers ?? AcpAgentDiscovery.discoverMissing;
    final discovered = await discover(_config);
    if (discovered.isEmpty || !mounted) return;

    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) return;
    if (!dialogContext.mounted) return;
    final selected = await showDialog<List<AgentServerConfig>>(
      context: dialogContext,
      builder: (context) => AgentDiscoveryDialog(agentServers: discovered),
    );
    if (selected == null || selected.isEmpty || !mounted) return;

    try {
      final write =
          widget.writeDiscoveredAgentServers ??
          AcpAgentDiscovery.writeSelectedAgentServers;
      final nextConfig = await write(_config, selected);
      if (!mounted) return;
      _reconcileControllerCache(nextConfig);
      _activateAgent(nextConfig);
      _showSnackBar('Added ${selected.length} discovered ACP agent(s).');
    } catch (error) {
      _showSnackBar('Could not add discovered agents: $error');
    }
  }

  ChatController _controllerFor(AcpClientConfig config) {
    final permissions = _permissionConfig(config);
    return ChatController(
      client: _agentClient(config),
      cwd: _cwd,
      additionalDirectories: config.additionalDirectories,
      agentName: config.agentName,
      defaultModel: config.activeAgentServer?.defaultModel ?? '',
      defaultReasoningEffort:
          config.activeAgentServer?.defaultReasoningEffort ?? '',
      permissionTrustRules: permissions.trustRules,
      permissionReviewer: _permissionReviewer(config),
    );
  }

  ChatController _cachedControllerFor(AcpClientConfig config) {
    final agentName = config.agentName;
    final signature = _controllerSignature(config);
    final existing = _controllersByAgent[agentName];
    if (existing != null &&
        _controllerSignaturesByAgent[agentName] == signature) {
      return existing;
    }

    existing?.dispose();
    final controller = _controllerFor(config);
    _controllersByAgent[agentName] = controller;
    _controllerSignaturesByAgent[agentName] = signature;
    return controller;
  }

  void _reconcileControllerCache(AcpClientConfig config) {
    for (final entry in _controllersByAgent.entries.toList()) {
      final nextAgentConfig = _configForAgent(config, entry.key);
      final nextSignature = nextAgentConfig == null
          ? null
          : _controllerSignature(nextAgentConfig);
      if (nextSignature == _controllerSignaturesByAgent[entry.key]) continue;

      entry.value.dispose();
      _controllersByAgent.remove(entry.key);
      _controllerSignaturesByAgent.remove(entry.key);
    }
  }

  AcpClientConfig? _configForAgent(AcpClientConfig config, String agentName) {
    if (config.agentName == agentName) return config;
    return config.agentServerNamed(agentName) == null
        ? null
        : config.withActiveAgentServer(agentName);
  }

  void _disposeCachedControllers() {
    for (final controller in _controllersByAgent.values) {
      controller.dispose();
    }
    _controllersByAgent.clear();
    _controllerSignaturesByAgent.clear();
  }

  Future<void> _selectAgent(String agentName) async {
    if (agentName == _config.agentName) return;

    late final AcpClientConfig nextConfig;
    try {
      nextConfig = _config.withActiveAgentServer(agentName);
    } catch (error) {
      _showSnackBar('Could not select agent: $error');
      return;
    }

    _activateAgent(nextConfig);
  }

  Future<String> _sendWorkspaceMessageToFastAgent(
    TaskWorkspace workspace,
    String message,
  ) async {
    final fastAgentName = workspace.agentConfig.fastAgentName.trim();
    if (fastAgentName.isEmpty) {
      throw StateError('Fast agent is not configured for this workspace.');
    }
    final nextConfig = _configForAgent(_config, fastAgentName);
    if (nextConfig == null) {
      throw StateError('Fast agent "$fastAgentName" is not configured.');
    }

    final controller = _cachedControllerFor(nextConfig);
    final beforeCount = controller.messages.length;
    await controller.sendPrompt(_fastAgentWorkspacePrompt(workspace, message));
    await _waitForFastAgent(controller);

    final error = controller.lastError;
    if (error != null && error.trim().isNotEmpty) {
      throw StateError(error);
    }
    return controller.messages
        .skip(beforeCount)
        .where((message) => message.role == ChatMessageRole.assistant)
        .map((message) => message.text.trim())
        .where((text) => text.isNotEmpty)
        .join('\n')
        .trim();
  }

  Future<void> _waitForFastAgent(ChatController controller) async {
    const timeout = Duration(minutes: 2);
    const interval = Duration(milliseconds: 100);
    final startedAt = DateTime.now();
    while (controller.isStreaming || controller.isSessionOperationRunning) {
      if (DateTime.now().difference(startedAt) > timeout) {
        throw TimeoutException('Fast agent did not finish within 2 minutes.');
      }
      await Future<void>.delayed(interval);
    }
  }

  String _fastAgentWorkspacePrompt(TaskWorkspace workspace, String message) {
    final config = workspace.agentConfig;
    final prompt = config.fastAgentPrompt.trim();
    final thinkingAgentName = config.thinkingAgentName.trim();
    final workAgents = config.workAgentNames.join(', ');
    return [
      '你是工作区的主快速agent，负责收件箱准入和快速响应。',
      'workspace_id: ${workspace.id}',
      'workspace_title: ${workspace.title}',
      if (thinkingAgentName.isNotEmpty) 'thinking_agent: $thinkingAgentName',
      if (workAgents.isNotEmpty) 'work_agents: $workAgents',
      if (prompt.isNotEmpty) 'role_prompt: $prompt',
      '',
      'human_message:',
      message,
      '',
      '处理要求:',
      '0. 你管理收件箱准入：先判断 human_message 是新需求，还是对已有 Human Confirm / Waiting Human 任务的回答。',
      '1. 如果是对待确认问题的回答，先调用 task_center_answer_human_question 更新任务，不要重新创建任务。',
      '2. 判断新需求是否需要进入任务中心；新需求先调用 task_center_record_admission_decision 记录准入结论。',
      '3. 需要进入时，使用 task center 工具创建或更新任务，并保持任务状态最新。',
      '4. 有疑问时，先和 thinking agent 对齐：调用 task_center_request_thinking_alignment；不要停在 task_center_request_thinking_alignment，如果已经知道要向 human 确认的问题，继续调用 task_center_request_human_confirmation ask human。',
      '5. 禁止只用自然语言说需要问 human；缺口明确时，必须在同一轮调用 task_center_request_human_confirmation 生成 Human Check。',
      '6. 人工回答后，如果目标和验收条件已经清晰，继续把任务转交给 worker；worker 完成后用 task_center_deliver_work_result 把结果交付到群聊。',
      '7. 聊天面板只回复认领和结果交付；过程、验收条件、执行记录写入任务详情或任务事件。',
      '8. 最后直接回复一条简短结论，说明已准入、已打回补充信息，或暂不准入。',
    ].join('\n');
  }

  Future<AcpClientConfig> _saveConfig(AcpClientConfig config) async {
    final write = widget.writeConfig;
    final nextConfig = write == null
        ? await AcpConfigStore.writeConfig(config: config)
        : await write(config);
    if (!mounted) return nextConfig;
    _reconcileControllerCache(nextConfig);
    _activateAgent(nextConfig);
    _showSnackBar('Saved agent configuration.');
    return nextConfig;
  }

  Future<void> _startNewSession(BuildContext dialogContext) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }

    final agentServers = _config.selectableAgentServers;
    final selection = await showDialog<NewSessionSelection>(
      context: dialogContext,
      builder: (context) => NewSessionAgentDialog(
        agentServers: widget.controller == null
            ? agentServers
            : const <AgentServerConfig>[],
        currentAgentName: _config.agentName,
        initialCwd: _controller.currentSession?.cwd ?? _controller.cwd,
      ),
    );
    if (selection == null) return;

    if (widget.controller != null) {
      await _controller.newSession(cwd: selection.cwd);
      return;
    }

    final selected = selection.agentServer;
    if (selected == null) {
      await _controller.newSession(cwd: selection.cwd);
      if (mounted) setState(() {});
      return;
    }

    late final AcpClientConfig nextConfig;
    try {
      nextConfig = _config.withActiveAgentServer(selected.name);
    } catch (error) {
      _showSnackBar('Could not select agent: $error');
      return;
    }

    final controller = _activateAgent(nextConfig);
    await controller.newSession(cwd: selection.cwd);
    if (mounted) setState(() {});
  }

  Future<void> _selectSession(AgentSession session) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }

    var controller = _controller;
    if (widget.controller == null) {
      final sessionAgentName = session.agentName?.trim();
      if (sessionAgentName != null &&
          sessionAgentName.isNotEmpty &&
          sessionAgentName != _config.agentName) {
        try {
          controller = _activateAgent(
            _config.withActiveAgentServer(sessionAgentName),
          );
        } catch (error) {
          _showSnackBar('Could not select agent: $error');
          return;
        }
      }
    }

    if (controller.currentSession?.id == session.id) return;
    await controller.resumeSession(
      session.id,
      cwd: session.cwd,
      additionalDirectories: session.additionalDirectories,
      title: session.title,
      updatedAt: session.updatedAt,
    );
    if (mounted) setState(() {});
  }

  ChatController _activateAgent(AcpClientConfig nextConfig) {
    final controller = _cachedControllerFor(nextConfig);
    setState(() {
      _config = nextConfig;
      _controller = controller;
    });
    return controller;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  DartAcpAgentClient _agentClient(AcpClientConfig config) {
    final server = config.activeAgentServer;
    final mcpServers = _effectiveMcpServers(
      config,
    ).map((server) => server.toJson()).toList();
    if (server == null) {
      return DartAcpAgentClient(
        mcpServers: mcpServers,
        enableFilesystemReadTextFile:
            config.clientProviders.filesystem.readTextFile,
        enableFilesystemWriteTextFile:
            config.clientProviders.filesystem.writeTextFile,
        allowFilesystemReadOutsideWorkspace:
            config.clientProviders.filesystem.allowReadOutsideWorkspace,
        enableTerminalProvider: config.clientProviders.terminal.enabled,
        additionalDirectories: config.additionalDirectories,
      );
    }
    return DartAcpAgentClient(
      agentCommand: server.isStdio ? server.command : null,
      agentArgs: server.isStdio ? server.args : const <String>[],
      agentCwd: server.isStdio ? server.cwd : null,
      envOverrides: server.isStdio ? server.env : const <String, String>{},
      agentWebSocketUrl: server.isWebSocket ? Uri.parse(server.url) : null,
      agentHttpUrl: server.isStreamableHttp ? Uri.parse(server.url) : null,
      agentHeaders: server.headers,
      systemPrompt: server.systemPrompt,
      mcpServers: mcpServers,
      enableFilesystemReadTextFile:
          config.clientProviders.filesystem.readTextFile,
      enableFilesystemWriteTextFile:
          config.clientProviders.filesystem.writeTextFile,
      allowFilesystemReadOutsideWorkspace:
          config.clientProviders.filesystem.allowReadOutsideWorkspace,
      enableTerminalProvider: config.clientProviders.terminal.enabled,
      additionalDirectories: config.additionalDirectories,
    );
  }

  List<McpServerConfig> _effectiveMcpServers(AcpClientConfig config) {
    final builtIn = _taskCenterMcpServerConfig;
    if (builtIn == null) return config.mcpServers;
    final result = <McpServerConfig>[];
    var hasBuiltIn = false;
    for (final server in config.mcpServers) {
      if (server.name == builtIn.name) hasBuiltIn = true;
      result.add(server);
    }
    if (!hasBuiltIn) result.add(builtIn);
    return List.unmodifiable(result);
  }

  AcpPermissionReviewer? _permissionReviewer(AcpClientConfig config) {
    final activeAgent = config.activeAgentServer;
    if (activeAgent == null) return null;

    final reviewAgent = _permissionConfig(config).reviewAgent;
    if (reviewAgent.enabled && reviewAgent.hasMcpTarget) {
      final server =
          reviewAgent.mcpServer ??
          _mcpServerNamed(config.mcpServers, reviewAgent.mcpServerName);
      if (server != null) {
        return McpPermissionReviewAgent(config: reviewAgent, mcpServer: server);
      }
    }

    return AcpAgentPermissionReviewer(
      agentName: config.agentName,
      modelOverride: reviewAgent.model,
      clientFactory: () => _reviewAgentClient(activeAgent),
    );
  }

  AcpClientProviderConfig _clientProviderConfig(AcpClientConfig config) {
    final permissions = _permissionConfig(config);
    if (identical(permissions, config.clientProviders.permissions)) {
      return config.clientProviders;
    }
    return AcpClientProviderConfig(
      filesystem: config.clientProviders.filesystem,
      terminal: config.clientProviders.terminal,
      permissions: permissions,
    );
  }

  AcpPermissionProviderConfig _permissionConfig(AcpClientConfig config) {
    final global = config.clientProviders.permissions;
    final agentReview = config.activeAgentServer?.permissionReviewAgent;
    if (agentReview == null || !agentReview.isConfigured) return global;
    return AcpPermissionProviderConfig(
      trustRules: global.trustRules,
      reviewAgent: _mergedReviewAgentConfig(global.reviewAgent, agentReview),
    );
  }

  AcpPermissionReviewAgentConfig _mergedReviewAgentConfig(
    AcpPermissionReviewAgentConfig base,
    AcpPermissionReviewAgentConfig override,
  ) {
    final hasOverrideTarget = override.hasMcpTarget;
    return AcpPermissionReviewAgentConfig(
      enabled: override.enabled || base.enabled,
      mcpServer: hasOverrideTarget ? override.mcpServer : base.mcpServer,
      mcpServerName: hasOverrideTarget
          ? override.mcpServerName
          : base.mcpServerName,
      toolName: override.toolName != 'review_permission'
          ? override.toolName
          : base.toolName,
      model: override.model ?? base.model,
      timeout: override.timeout != const Duration(seconds: 10)
          ? override.timeout
          : base.timeout,
    );
  }

  DartAcpAgentClient _reviewAgentClient(AgentServerConfig server) {
    return DartAcpAgentClient(
      agentCommand: server.isStdio ? server.command : null,
      agentArgs: server.isStdio ? server.args : const <String>[],
      agentCwd: server.isStdio ? server.cwd : null,
      envOverrides: server.isStdio ? server.env : const <String, String>{},
      agentWebSocketUrl: server.isWebSocket ? Uri.parse(server.url) : null,
      agentHttpUrl: server.isStreamableHttp ? Uri.parse(server.url) : null,
      agentHeaders: server.headers,
    );
  }

  McpServerConfig? _mcpServerNamed(
    List<McpServerConfig> servers,
    String? name,
  ) {
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    for (final server in servers) {
      if (server.name == trimmed) return server;
    }
    return null;
  }

  List<ChatController> get _sessionControllers {
    if (widget.controller != null) return <ChatController>[_controller];
    return _controllersByAgent.values.toList();
  }

  String _configSignature(AcpClientConfig config) {
    return jsonEncode(<String, Object?>{
      'activeAgentServer': _agentServerSignature(config.activeAgentServer),
      'agentServers': config.agentServers
          .map(_agentServerSignature)
          .toList(growable: false),
      'mcpServers': _effectiveMcpServers(
        config,
      ).map((server) => server.toJson()).toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'configPath': config.configPath,
      'defaultAgentServerName': config.defaultAgentServerName,
    });
  }

  String _controllerSignature(AcpClientConfig config) {
    return jsonEncode(<String, Object?>{
      'agentName': config.agentName,
      'activeAgentServer': _agentServerSignature(config.activeAgentServer),
      'mcpServers': _effectiveMcpServers(
        config,
      ).map((server) => server.toJson()).toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
    });
  }

  Map<String, Object?>? _agentServerSignature(AgentServerConfig? server) {
    if (server == null) return null;
    return <String, Object?>{'name': server.name, ...server.toJson()};
  }

  Map<String, Object?> _clientProvidersSignature(
    AcpClientProviderConfig providers,
  ) {
    return <String, Object?>{
      'filesystem': <String, Object?>{
        'readTextFile': providers.filesystem.readTextFile,
        'writeTextFile': providers.filesystem.writeTextFile,
        'allowReadOutsideWorkspace':
            providers.filesystem.allowReadOutsideWorkspace,
      },
      'terminal': <String, Object?>{'enabled': providers.terminal.enabled},
      'permissions': <String, Object?>{
        'trustRules': providers.permissions.trustRules
            .map(
              (rule) => <String, Object?>{
                'toolName': rule.toolName,
                'toolKind': rule.toolKind,
                'decision': rule.decision.name,
              },
            )
            .toList(growable: false),
        'reviewAgent': _reviewAgentSignature(providers.permissions.reviewAgent),
      },
    };
  }

  Map<String, Object?> _reviewAgentSignature(
    AcpPermissionReviewAgentConfig config,
  ) {
    return <String, Object?>{
      'enabled': config.enabled,
      'mcpServer': config.mcpServer?.toJson(),
      'mcpServerName': config.mcpServerName,
      'toolName': config.toolName,
      'model': config.model,
      'timeoutMs': config.timeout.inMilliseconds,
    };
  }
}
