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
import 'memory/acp_memory_middleware.dart';
import 'memory/acp_sidecar_memory_extractor.dart';
import 'memory/automatic_memory_maintenance.dart';
import 'memory/memory_api_client.dart';
import 'memory/memory_config.dart';
import 'memory/memory_daemon_manager.dart';
import 'memory/memory_extraction.dart';
import 'memory/memory_maintenance_extraction.dart';
import 'memory/memory_mcp_server.dart';
import 'memory/memory_pending_review_summary.dart';
import 'memory/memory_scope_visibility.dart';
import 'memory/openai_compatible_memory_extractor.dart';
import 'state/chat_controller.dart';
import 'ui/components/agent_discovery_dialog.dart';
import 'ui/components/memory_explorer_page.dart';
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
  });

  final ChatController? controller;
  final AcpClientConfig config;
  final String? startupError;
  final AgentServerDiscoverer? discoverAgentServers;
  final DiscoveredAgentServerWriter? writeDiscoveredAgentServers;
  final AcpConfigWriter? writeConfig;

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
  MemoryDaemonManager? _memoryDaemonManager;
  String? _memoryDaemonSignature;
  MemoryPendingReviewSummary? _memoryPendingReview;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  bool _agentDiscoveryStarted = false;

  @override
  void initState() {
    super.initState();
    _config = widget.config;
    _widgetConfigSignature = _configSignature(widget.config);
    _cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: Directory.current.path,
    );
    if (widget.controller == null) {
      _controller = _cachedControllerFor(_config);
    } else {
      _controller = widget.controller!;
    }
    _ensureMemoryDaemonIfEnabled(_config.memory);
    if (_initialResumeSessionId.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_controller.resumeSession(_initialResumeSessionId));
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeDiscoverAgents());
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
      _reconcileMemoryDaemon(_config.memory);
      _ensureMemoryDaemonIfEnabled(_config.memory);
      return;
    }

    if (!configChanged) {
      if (widget.controller != null) _controller = widget.controller!;
      return;
    }

    _config = widget.config;
    _widgetConfigSignature = nextConfigSignature;
    _reconcileMemoryDaemon(_config.memory);
    _ensureMemoryDaemonIfEnabled(_config.memory);
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
    _disposeMemoryDaemon();
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
        mcpServers: _config.mcpServers,
        additionalDirectories: _config.additionalDirectories,
        clientProviders: _clientProviderConfig(_config),
        memory: _config.memory,
        configPath: _config.configPath,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: widget.startupError,
        canSwitchAgent: widget.controller == null,
        sessionControllers: _sessionControllers,
        memoryExplorerActions: _memoryExplorerActions(),
        memoryPendingReview: _memoryPendingReview,
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
      permissionTrustRules: permissions.trustRules,
      permissionReviewer: _permissionReviewer(config),
      memoryMiddleware: _memoryMiddleware(config),
    );
  }

  AcpMemoryMiddleware? _memoryMiddleware(AcpClientConfig config) {
    final memory = config.memory;
    if (!memory.enabled) return null;

    final daemonManager = _memoryDaemonManagerFor(memory);
    MemoryApiClient? client;
    MemoryDaemonEndpoint? endpoint;
    Future<MemoryApiClient> memoryClient() async {
      final nextEndpoint = await daemonManager.ensureStarted();
      if (client == null ||
          endpoint?.baseUrl != nextEndpoint.baseUrl ||
          endpoint?.token != nextEndpoint.token) {
        client?.close(force: true);
        endpoint = nextEndpoint;
        client = MemoryApiClient(
          baseUrl: nextEndpoint.baseUrl,
          token: nextEndpoint.token,
        );
      }
      return client!;
    }

    return AcpMemoryMiddleware(
      search: (context) async {
        final client = await memoryClient();
        final cwd = context.cwd?.trim().isNotEmpty == true
            ? context.cwd!.trim()
            : _cwd;
        return client.searchContext(
          MemorySearchRequest(
            query: context.prompt,
            scope: MemoryScopeData(
              userId: _memoryUserId(),
              workspaceId: cwd,
              repoId: cwd,
              agentId: config.agentName,
              sessionId: context.sessionId,
            ),
          ),
        );
      },
      extract: (context) async {
        final client = await memoryClient();
        final cwd = context.cwd?.trim().isNotEmpty == true
            ? context.cwd!.trim()
            : _cwd;
        final candidates = await _extractMemoryCandidates(config, context, cwd);
        final result = await client.createCandidates(
          scope: MemoryScopeData(
            userId: _memoryUserId(),
            workspaceId: cwd,
            repoId: cwd,
            agentId: config.agentName,
            sessionId: context.sessionId,
          ),
          candidates: candidates,
          autoApproveThreshold: candidateAutoApproveThreshold(
            config.memory.review,
          ),
        );
        if (shouldRunMaintenanceAfterCandidateExtraction(
          maintenance: config.memory.maintenance,
          result: result,
        )) {
          await _runAutomaticMemoryMaintenance(
            config,
            client,
            cwd,
            MemoryScopeData(
              userId: _memoryUserId(),
              workspaceId: cwd,
              repoId: cwd,
              agentId: config.agentName,
              sessionId: context.sessionId,
            ),
          );
        }
        await _refreshMemoryPendingReviewCount(client: client, cwd: cwd);
      },
      onDispose: () => client?.close(force: true),
    );
  }

  MemoryExplorerActions? _memoryExplorerActions() {
    if (widget.controller != null || !_config.memory.enabled) return null;
    return MemoryExplorerActions(
      loadMemory: () => _withMemoryClient((client) {
        return client.listVisibleMemory(scope: _currentVisibleMemoryScope());
      }),
      updateMemory: (record) => _withMemoryClient((client) async {
        await client.updateMemory(record);
      }),
      deleteMemory: (record) => _withMemoryClient((client) async {
        await client.deleteMemory(record.id);
      }),
      loadCandidates: () => _withMemoryClient(
        (client) => client.listCandidates(
          visibleScope: _currentVisibleMemoryScope(),
          status: 'pending',
        ),
      ),
      approveCandidate: (candidate) => _withMemoryClient((client) async {
        await client.approveCandidate(candidate);
        if (shouldRunMaintenanceAfterCandidateApproval(
          maintenance: _config.memory.maintenance,
        )) {
          await _runAutomaticMemoryMaintenance(
            _config,
            client,
            _currentVisibleMemoryCwd(),
            _currentVisibleMemoryScope(),
          );
        }
        await _refreshMemoryPendingReviewCount(client: client);
      }),
      rejectCandidate: (candidate) => _withMemoryClient((client) async {
        await client.rejectCandidate(candidate.id);
        await _refreshMemoryPendingReviewCount(client: client);
      }),
      loadChangeRequests: () => _withMemoryClient(
        (client) => client.listChangeRequests(
          visibleScope: _currentVisibleMemoryScope(),
          status: null,
        ),
      ),
      approveChangeRequest: (request) => _withMemoryClient((client) async {
        await client.approveChangeRequest(request);
        await _refreshMemoryPendingReviewCount(client: client);
      }),
      rejectChangeRequest: (request) => _withMemoryClient((client) async {
        await client.rejectChangeRequest(request.id);
        await _refreshMemoryPendingReviewCount(client: client);
      }),
      runMaintenance: () => _withMemoryClient((client) async {
        final maintenance = _config.memory.maintenance;
        final scope = _currentVisibleMemoryScope();
        final cwd = _currentVisibleMemoryCwd();
        final suggestions = await _extractMaintenanceChangeRequests(
          _config,
          client,
          cwd,
          scope,
        );
        final result = await client.runMaintenance(
          scope: scope,
          enabled: maintenance.enabled,
          mode: maintenance.mode,
          costMode: maintenance.costMode,
          highConfidenceThreshold: maintenance.highConfidenceThreshold,
          reviewThreshold: maintenance.reviewThreshold,
          maxItemsPerBatch: maintenance.maxItemsPerBatch,
          manualOnlyActions: maintenance.manualOnlyActions,
          preExtractedChangeRequests: suggestions,
        );
        await _refreshMemoryPendingReviewCount(client: client);
        return result;
      }),
      loadAuditLog: () => _withMemoryClient(
        (client) =>
            client.listAudit(visibleScope: _currentVisibleMemoryScope()),
      ),
    );
  }

  Future<List<MaintenanceChangeRequestSuggestion>>
  _extractMaintenanceChangeRequests(
    AcpClientConfig config,
    MemoryApiClient client,
    String cwd,
    MemoryScopeData scope,
  ) async {
    final memory = config.memory;
    final maintenance = memory.maintenance;
    if (!maintenance.enabled) {
      return const <MaintenanceChangeRequestSuggestion>[];
    }
    final records = await client.listVisibleMemory(scope: scope);
    final memories = prefilterMaintenanceMemories(
      memories: records
          .map((record) => record.toMaintenanceItem())
          .toList(growable: false),
      maxItems: maintenance.maxItemsPerBatch,
    );
    if (memories.length < 2) {
      return const <MaintenanceChangeRequestSuggestion>[];
    }

    try {
      final provider = memory.extractor.provider.trim();
      if (provider == 'openai-compatible' || provider == 'llm') {
        final apiKeyEnv = memory.llm.apiKeyEnv.trim();
        final apiKey = apiKeyEnv.isEmpty
            ? null
            : Platform.environment[apiKeyEnv]?.trim();
        final extractor = OpenAiCompatibleMemoryExtractor(
          baseUrl: memory.llm.baseUrl,
          model: memory.llm.model,
          apiKey: apiKey,
        );
        try {
          return await extractor.extractMaintenance(memories: memories);
        } finally {
          extractor.close();
        }
      }

      final agentName = memory.extractor.agent.trim().isEmpty
          ? config.agentName
          : memory.extractor.agent.trim();
      final sidecarConfig = _configForAgent(config, agentName) ?? config;
      final extractor = AcpSidecarMemoryMaintenanceExtractor(
        clientFactory: () => _agentClient(sidecarConfig),
      );
      return await extractor.extract(
        memories: memories,
        cwd: cwd,
        model: memory.extractor.model,
      );
    } catch (error) {
      debugPrint('Memory maintenance extractor failed: $error');
      return const <MaintenanceChangeRequestSuggestion>[];
    }
  }

  Future<void> _runAutomaticMemoryMaintenance(
    AcpClientConfig config,
    MemoryApiClient client,
    String cwd,
    MemoryScopeData scope,
  ) async {
    final maintenance = config.memory.maintenance;
    final suggestions = await _extractMaintenanceChangeRequests(
      config,
      client,
      cwd,
      scope,
    );
    if (suggestions.isEmpty) return;
    await client.runMaintenance(
      scope: scope,
      enabled: maintenance.enabled,
      mode: maintenance.mode,
      costMode: maintenance.costMode,
      highConfidenceThreshold: maintenance.highConfidenceThreshold,
      reviewThreshold: maintenance.reviewThreshold,
      maxItemsPerBatch: maintenance.maxItemsPerBatch,
      manualOnlyActions: maintenance.manualOnlyActions,
      preExtractedChangeRequests: suggestions,
    );
  }

  MemoryScopeData _currentVisibleMemoryScope() {
    final session = _controller.currentSession;
    return visibleMemoryScope(
      userId: _memoryUserId(),
      fallbackCwd: _cwd,
      agentName: _config.agentName,
      sessionCwd: session?.cwd,
      sessionId: session?.id,
    );
  }

  String _currentVisibleMemoryCwd() {
    return visibleMemoryCwd(
      fallbackCwd: _cwd,
      sessionCwd: _controller.currentSession?.cwd,
    );
  }

  Future<T> _withMemoryClient<T>(
    Future<T> Function(MemoryApiClient client) action,
  ) async {
    if (!_config.memory.enabled) {
      throw StateError('Memory is disabled.');
    }
    final manager = _memoryDaemonManagerFor(_config.memory);
    final endpoint = await manager.ensureStarted();
    final client = MemoryApiClient(
      baseUrl: endpoint.baseUrl,
      token: endpoint.token,
    );
    try {
      return await action(client);
    } finally {
      client.close(force: true);
    }
  }

  MemoryDaemonManager _memoryDaemonManagerFor(MemoryConfig memory) {
    final signature = _memoryDaemonSignatureFor(memory);
    final existing = _memoryDaemonManager;
    if (existing != null && _memoryDaemonSignature == signature) {
      return existing;
    }
    _disposeMemoryDaemon();
    final manager = MemoryDaemonManager(launch: _memoryDaemonLaunch(memory));
    _memoryDaemonManager = manager;
    _memoryDaemonSignature = signature;
    return manager;
  }

  void _reconcileMemoryDaemon(MemoryConfig memory) {
    if (!memory.enabled ||
        _memoryDaemonSignature != _memoryDaemonSignatureFor(memory)) {
      _disposeMemoryDaemon();
    }
    if (!memory.enabled && _memoryPendingReview != null) {
      setState(() => _memoryPendingReview = null);
    }
  }

  void _ensureMemoryDaemonIfEnabled(MemoryConfig memory) {
    if (widget.controller != null || !memory.enabled) return;
    final manager = _memoryDaemonManagerFor(memory);
    unawaited(
      manager.ensureStarted().then<void>(
        (_) => _refreshMemoryPendingReviewCount(),
        onError: (_) {},
      ),
    );
  }

  void _disposeMemoryDaemon() {
    final manager = _memoryDaemonManager;
    _memoryDaemonManager = null;
    _memoryDaemonSignature = null;
    if (manager != null) unawaited(manager.dispose());
  }

  MemoryDaemonLaunch _memoryDaemonLaunch(MemoryConfig memory) {
    final dataDir = memory.dataDir?.trim();
    return MemoryDaemonLaunch(
      executable: MemoryDaemonLaunch.resolveExecutable(currentDirectory: _cwd),
      dataDir: dataDir == null || dataDir.isEmpty
          ? MemoryDaemonLaunch.defaultDataDir()
          : dataDir,
      token: MemoryDaemonLaunch.generateToken(),
      extraEnv: _memoryDaemonEnvironment(memory),
    );
  }

  String _memoryDaemonSignatureFor(MemoryConfig memory) {
    return jsonEncode(<String, Object?>{
      'dataDir': memory.dataDir?.trim(),
      'embedding': memory.embedding.toJson(),
      'executable': MemoryDaemonLaunch.resolveExecutable(
        currentDirectory: _cwd,
      ),
    });
  }

  Map<String, String> _memoryDaemonEnvironment(MemoryConfig memory) {
    final embedding = memory.embedding;
    return <String, String>{
      'MEMORY_EMBEDDING_PROVIDER': embedding.provider,
      'MEMORY_EMBEDDING_MODEL': embedding.model,
      'MEMORY_EMBEDDING_VARIANT': embedding.variant,
      'MEMORY_EMBEDDING_DIMENSION': embedding.dimension.toString(),
      'MEMORY_EMBEDDING_DOWNLOAD_POLICY': embedding.downloadPolicy,
    };
  }

  Future<void> _refreshMemoryPendingReviewCount({
    MemoryApiClient? client,
    String? cwd,
  }) async {
    if (widget.controller != null || !_config.memory.enabled) {
      if (mounted && _memoryPendingReview != null) {
        setState(() => _memoryPendingReview = null);
      }
      return;
    }
    final repoId = cwd?.trim().isNotEmpty == true ? cwd!.trim() : _cwd;
    final scope = visibleMemoryScope(
      userId: _memoryUserId(),
      fallbackCwd: repoId,
      agentName: _config.agentName,
      sessionCwd: repoId,
      sessionId: _controller.currentSession?.id,
    );
    try {
      Future<MemoryPendingReviewSummary> loadSummary(
        MemoryApiClient client,
      ) async {
        final candidates = await client.listCandidates(
          visibleScope: scope,
          status: 'pending',
        );
        final changeRequests = await client.listChangeRequests(
          visibleScope: scope,
          status: 'pending',
        );
        return MemoryPendingReviewSummary(
          candidateCount: candidates.length,
          changeRequestCount: changeRequests.length,
        );
      }

      final summary = client == null
          ? await _withMemoryClient(loadSummary)
          : await loadSummary(client);
      if (!mounted) return;
      final current = _memoryPendingReview;
      if (current?.candidateCount != summary.candidateCount ||
          current?.changeRequestCount != summary.changeRequestCount) {
        setState(() => _memoryPendingReview = summary);
      }
    } catch (_) {
      // Review counts are best-effort; memory search/extraction remains usable.
    }
  }

  Future<List<ExtractedMemoryCandidate>> _extractMemoryCandidates(
    AcpClientConfig config,
    MemoryTurnContext context,
    String cwd,
  ) async {
    final memory = config.memory;
    final provider = memory.extractor.provider.trim();
    try {
      final primary = await () async {
        if (provider == 'openai-compatible' || provider == 'llm') {
          final apiKeyEnv = memory.llm.apiKeyEnv.trim();
          final apiKey = apiKeyEnv.isEmpty
              ? null
              : Platform.environment[apiKeyEnv]?.trim();
          final extractor = OpenAiCompatibleMemoryExtractor(
            baseUrl: memory.llm.baseUrl,
            model: memory.llm.model,
            apiKey: apiKey,
          );
          try {
            return await extractor.extract(
              userPrompt: context.userPrompt,
              assistantAnswer: context.assistantAnswer,
            );
          } finally {
            extractor.close();
          }
        }

        final agentName = memory.extractor.agent.trim().isEmpty
            ? config.agentName
            : memory.extractor.agent.trim();
        final sidecarConfig = _configForAgent(config, agentName) ?? config;
        final extractor = AcpSidecarMemoryExtractor(
          clientFactory: () => _agentClient(sidecarConfig),
        );
        return extractor.extract(
          userPrompt: context.userPrompt,
          assistantAnswer: context.assistantAnswer,
          cwd: cwd,
          model: memory.extractor.model,
        );
      }();
      return _mergeRuleBasedMemoryCandidates(memory, context, primary);
    } catch (error) {
      final fallback = _ruleBasedMemoryCandidates(memory, context);
      if (_usesRuleBasedMemoryFallback(memory)) {
        debugPrint('Memory extractor failed; using rules fallback: $error');
        return fallback;
      }
      rethrow;
    }
  }

  List<ExtractedMemoryCandidate> _mergeRuleBasedMemoryCandidates(
    MemoryConfig memory,
    MemoryTurnContext context,
    List<ExtractedMemoryCandidate> primary,
  ) {
    if (!_usesRuleBasedMemoryFallback(memory)) return primary;
    return mergeExtractedMemoryCandidates(
      primary,
      _ruleBasedMemoryCandidates(memory, context),
    );
  }

  List<ExtractedMemoryCandidate> _ruleBasedMemoryCandidates(
    MemoryConfig memory,
    MemoryTurnContext context,
  ) {
    if (!_usesRuleBasedMemoryFallback(memory)) {
      return const <ExtractedMemoryCandidate>[];
    }
    return extractRuleBasedMemoryCandidates(
      userPrompt: context.userPrompt,
      assistantAnswer: context.assistantAnswer,
    );
  }

  bool _usesRuleBasedMemoryFallback(MemoryConfig memory) {
    final provider = memory.extractor.fallbackProvider.trim().toLowerCase();
    return provider == 'rules' ||
        provider == 'rule' ||
        provider == 'rule-based';
  }

  String _memoryUserId() {
    final user = Platform.environment['USER']?.trim();
    return user == null || user.isEmpty ? 'local-user' : user;
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
    _reconcileMemoryDaemon(nextConfig.memory);
    final controller = _cachedControllerFor(nextConfig);
    setState(() {
      _config = nextConfig;
      _controller = controller;
    });
    _ensureMemoryDaemonIfEnabled(nextConfig.memory);
    return controller;
  }

  void _showSnackBar(String message) {
    if (!mounted) return;
    _messengerKey.currentState?.showSnackBar(SnackBar(content: Text(message)));
  }

  DartAcpAgentClient _agentClient(AcpClientConfig config) {
    final server = config.activeAgentServer;
    final mcpServers = config.mcpServers
        .map((server) => server.toJson())
        .toList();
    if (server == null) {
      return DartAcpAgentClient(
        mcpServers: mcpServers,
        dynamicMcpServers: _memoryMcpServersProvider(config),
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
      mcpServers: mcpServers,
      dynamicMcpServers: _memoryMcpServersProvider(config),
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

  DynamicMcpServersProvider? _memoryMcpServersProvider(AcpClientConfig config) {
    final memory = config.memory;
    if (!memory.enabled) return null;
    if (config.mcpServers.any((server) => server.name == memoryMcpServerName)) {
      return null;
    }
    return () async {
      try {
        final manager = _memoryDaemonManagerFor(memory);
        final endpoint = await manager.ensureStarted();
        return <Map<String, dynamic>>[
          buildMemoryMcpServerConfig(
            executable: MemoryDaemonLaunch.resolveExecutable(
              currentDirectory: _cwd,
            ),
            endpoint: endpoint,
            memory: memory,
          ),
        ];
      } catch (error) {
        debugPrint('Memory MCP server unavailable: $error');
        return const <Map<String, dynamic>>[];
      }
    };
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
      'mcpServers': config.mcpServers
          .map((server) => server.toJson())
          .toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'memory': config.memory.toJson(),
      'configPath': config.configPath,
      'defaultAgentServerName': config.defaultAgentServerName,
    });
  }

  String _controllerSignature(AcpClientConfig config) {
    return jsonEncode(<String, Object?>{
      'agentName': config.agentName,
      'activeAgentServer': _agentServerSignature(config.activeAgentServer),
      'mcpServers': config.mcpServers
          .map((server) => server.toJson())
          .toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'memory': config.memory.toJson(),
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
