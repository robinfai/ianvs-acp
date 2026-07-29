import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'acp/agent_session.dart';
import 'acp/dart_acp_agent_client.dart';
import 'acp/acp_permission_reviewer.dart';
import 'config/acp_agent_discovery.dart';
import 'config/acp_client_config.dart';
import 'config/acp_config_store.dart';
import 'memory/acp_memory_middleware.dart';
import 'memory/acp_sidecar_memory_extractor.dart';
import 'memory/memory_api_client.dart';
import 'memory/memory_config.dart';
import 'memory/memory_context_builder.dart';
import 'memory/memory_daemon_manager.dart';
import 'memory/memory_extraction.dart';
import 'memory/memory_mcp_server_config.dart';
import 'memory/memory_post_turn_automation.dart';
import 'memory/memory_runtime_status.dart';
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
  MemoryRuntimeStatus _memoryStatus = MemoryRuntimeStatus.disabled;
  int _memoryPendingCount = 0;
  int _memoryPendingChangeRequestCount = 0;
  int _memoryTurnsSinceMaintenance = 0;
  int _memoryAutomationNoticeSequence = 0;
  MemoryAutomationNotice? _memoryAutomationNotice;
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
    _memoryStatus = _initialMemoryStatus(_config.memory);
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
        memoryStatus: _memoryStatus,
        memoryPendingCount: _memoryPendingCount,
        memoryPendingChangeRequestCount: _memoryPendingChangeRequestCount,
        memoryAutomationNotice: _memoryAutomationNotice,
        memoryExplorerActions: _memoryExplorerActions(),
        configPath: _config.configPath,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: widget.startupError,
        canSwitchAgent: widget.controller == null,
        sessionControllers: _sessionControllers,
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
      final nextEndpoint = await _ensureMemoryEndpoint(daemonManager);
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
            turnId: context.turnId,
            pinnedProfileLimit: _config.memory.profile.maxItems,
          ),
        );
      },
      searchDetails: (context) async {
        final client = await memoryClient();
        final cwd = context.cwd?.trim().isNotEmpty == true
            ? context.cwd!.trim()
            : _cwd;
        final items = await client.search(
          MemorySearchRequest(
            query: context.prompt,
            scope: MemoryScopeData(
              userId: _memoryUserId(),
              workspaceId: cwd,
              repoId: cwd,
              agentId: config.agentName,
              sessionId: context.sessionId,
            ),
            turnId: context.turnId,
            pinnedProfileLimit: _config.memory.profile.maxItems,
          ),
        );
        final memoryContext = items.isEmpty
            ? null
            : MemoryContextBuilder.build(
                items
                    .map(
                      (item) => MemoryContextItem(
                        kind: item.kind,
                        scope: item.scope,
                        text: item.text,
                        score: item.score,
                        metadata: item.metadata,
                      ),
                    )
                    .toList(growable: false),
                pinnedProfileLimit: _config.memory.profile.maxItems,
              );
        return MemoryPromptResult(
          memoryContext: memoryContext,
          usedMemories: items
              .map(
                (item) => MemoryUsedItem(
                  id: item.id,
                  kind: item.kind,
                  scope: item.scope,
                  text: item.text,
                  score: item.score,
                  metadata: item.metadata,
                ),
              )
              .toList(growable: false),
        );
      },
      extract: (context) async {
        final client = await memoryClient();
        final cwd = context.cwd?.trim().isNotEmpty == true
            ? context.cwd!.trim()
            : _cwd;
        final candidates = await _extractMemoryCandidates(config, context, cwd);
        final scope = MemoryScopeData(
          userId: _memoryUserId(),
          workspaceId: cwd,
          repoId: cwd,
          agentId: config.agentName,
          sessionId: context.sessionId,
        );
        final extractionResult = await client.createCandidates(
          scope: scope,
          candidates: candidates,
          sourceTurnId: context.turnId,
        );
        final automationResult = await MemoryPostTurnAutomation.apply(
          memory: memory,
          candidates: extractionResult.candidates,
          autoAppliedChangeRequests: extractionResult.autoAppliedChangeRequests,
          usedMemoryCount: context.usedMemories.length,
          pendingReviewCount: _memoryPendingCount,
          turnsSinceMaintenance: _memoryTurnsSinceMaintenance + 1,
          approveCandidate: (candidate) async {
            await client.approveCandidate(candidate, actor: 'extractor');
          },
          runMaintenance: () => client.runMaintenance(
            scope: scope,
            enabled: memory.maintenance.enabled,
            mode: memory.maintenance.mode,
            costMode: memory.maintenance.costMode,
            highConfidenceThreshold: memory.maintenance.highConfidenceThreshold,
            reviewThreshold: memory.maintenance.reviewThreshold,
            maxItemsPerBatch: memory.maintenance.maxItemsPerBatch,
            manualOnlyActions: memory.maintenance.manualOnlyActions,
          ),
        );
        _recordMemoryPostTurnAutomation(automationResult);
      },
      onTurnComplete: (_) async {
        await _refreshMemoryPendingCount(daemonManager);
      },
      feedback: (context) async {
        final client = await memoryClient();
        await client.submitFeedback(
          memoryId: context.memoryId,
          rating: context.rating,
          turnId: context.turnId,
          reason: context.reason,
        );
      },
      onDispose: () => client?.close(force: true),
    );
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
      if (!memory.enabled) {
        _setMemoryStatus(MemoryRuntimeStatus.disabled);
        _setMemoryPendingCount(0);
        _memoryTurnsSinceMaintenance = 0;
        _clearMemoryAutomationNotice();
      }
    }
  }

  void _ensureMemoryDaemonIfEnabled(MemoryConfig memory) {
    if (widget.controller != null || !memory.enabled) {
      _setMemoryStatus(MemoryRuntimeStatus.disabled);
      _setMemoryPendingCount(0);
      _memoryTurnsSinceMaintenance = 0;
      _clearMemoryAutomationNotice();
      return;
    }
    final manager = _memoryDaemonManagerFor(memory);
    unawaited(
      _ensureMemoryEndpoint(
        manager,
      ).then<void>((_) => _refreshMemoryPendingCount(manager), onError: (_) {}),
    );
  }

  Future<MemoryDaemonEndpoint> _ensureMemoryEndpoint(
    MemoryDaemonManager manager,
  ) async {
    if (_memoryStatus != MemoryRuntimeStatus.running) {
      _setMemoryStatus(MemoryRuntimeStatus.starting);
    }
    try {
      final endpoint = await manager.ensureStarted();
      if (identical(_memoryDaemonManager, manager)) {
        _setMemoryStatus(MemoryRuntimeStatus.running);
      }
      return endpoint;
    } catch (_) {
      if (identical(_memoryDaemonManager, manager)) {
        _setMemoryStatus(MemoryRuntimeStatus.error);
      }
      rethrow;
    }
  }

  MemoryRuntimeStatus _initialMemoryStatus(MemoryConfig memory) {
    if (widget.controller != null || !memory.enabled) {
      return MemoryRuntimeStatus.disabled;
    }
    return MemoryRuntimeStatus.starting;
  }

  void _setMemoryStatus(MemoryRuntimeStatus status) {
    if (_memoryStatus == status) return;
    if (!mounted) {
      _memoryStatus = status;
      return;
    }
    setState(() => _memoryStatus = status);
  }

  void _setMemoryPendingCount(int count) {
    var changeRequestCount = _memoryPendingChangeRequestCount;
    if (count <= 0) {
      changeRequestCount = 0;
    } else if (changeRequestCount > count) {
      changeRequestCount = count;
    }
    if (_memoryPendingCount == count &&
        _memoryPendingChangeRequestCount == changeRequestCount) {
      return;
    }
    if (!mounted) {
      _memoryPendingCount = count;
      _memoryPendingChangeRequestCount = changeRequestCount;
      return;
    }
    setState(() {
      _memoryPendingCount = count;
      _memoryPendingChangeRequestCount = changeRequestCount;
    });
  }

  void _setMemoryPendingCounts({
    required int candidateCount,
    required int changeRequestCount,
  }) {
    final nextPendingCount = candidateCount + changeRequestCount;
    if (_memoryPendingCount == nextPendingCount &&
        _memoryPendingChangeRequestCount == changeRequestCount) {
      return;
    }
    if (!mounted) {
      _memoryPendingCount = nextPendingCount;
      _memoryPendingChangeRequestCount = changeRequestCount;
      return;
    }
    setState(() {
      _memoryPendingCount = nextPendingCount;
      _memoryPendingChangeRequestCount = changeRequestCount;
    });
  }

  void _setMemoryAutomationNotice(MemoryPostTurnAutomationResult result) {
    final maintenance = result.maintenanceResult;
    final nextSequence = _memoryAutomationNoticeSequence + 1;
    final notice = MemoryAutomationNotice(
      sequence: nextSequence,
      approvedCandidates: result.approvedCandidates,
      pendingCandidateReviews: result.pendingCandidateReviews,
      autoAppliedChangeRequests: result.autoAppliedChangeRequests,
      maintenanceAutoApplied: maintenance?.autoApplied ?? 0,
      maintenanceNeedsReview: maintenance?.needsReview ?? 0,
      maintenanceSkipped: maintenance?.skipped ?? 0,
      maintenanceAutoRejectedCandidates:
          maintenance?.autoRejectedCandidates ?? 0,
      maintenanceAutoRejectedChangeRequests:
          maintenance?.autoRejectedChangeRequests ?? 0,
    );
    if (!notice.shouldPrompt) return;
    _memoryAutomationNoticeSequence = nextSequence;
    if (!mounted) {
      _memoryAutomationNotice = notice;
      return;
    }
    setState(() => _memoryAutomationNotice = notice);
  }

  void _recordMemoryPostTurnAutomation(MemoryPostTurnAutomationResult result) {
    if (result.maintenanceTrigger != null) {
      _memoryTurnsSinceMaintenance = 0;
    } else {
      _memoryTurnsSinceMaintenance += 1;
    }
    if (result.pendingReviewDelta != 0) {
      final currentCandidateCount =
          _memoryPendingCount - _memoryPendingChangeRequestCount;
      final nextCandidateCount =
          currentCandidateCount + result.pendingCandidateReviewDelta;
      final nextChangeRequestCount =
          _memoryPendingChangeRequestCount +
          result.pendingChangeRequestReviewDelta;
      _setMemoryPendingCounts(
        candidateCount: nextCandidateCount < 0 ? 0 : nextCandidateCount,
        changeRequestCount: nextChangeRequestCount < 0
            ? 0
            : nextChangeRequestCount,
      );
    }
    _setMemoryAutomationNotice(result);
  }

  void _clearMemoryAutomationNotice() {
    if (_memoryAutomationNotice == null) return;
    if (!mounted) {
      _memoryAutomationNotice = null;
      return;
    }
    setState(() => _memoryAutomationNotice = null);
  }

  MemoryExplorerActions? _memoryExplorerActions() {
    if (widget.controller != null || !_config.memory.enabled) return null;
    return MemoryExplorerActions(
      loadMemory: _loadMemoryRecords,
      loadCandidates: _loadMemoryCandidates,
      loadChangeRequests: _loadMemoryChangeRequests,
      loadAudit: _loadMemoryAuditEvents,
      approveCandidate: _approveMemoryCandidate,
      rejectCandidate: _rejectMemoryCandidate,
      approveChangeRequest: _approveMemoryChangeRequest,
      rejectChangeRequest: _rejectMemoryChangeRequest,
      updateChangeRequest: _updateMemoryChangeRequest,
      updateMemory: _updateMemoryRecord,
      disableMemory: _disableMemoryRecord,
      restoreMemory: _restoreMemoryRecord,
      submitFeedback: _submitMemoryRecordFeedback,
      exportBackup: _exportMemoryBackup,
      importBackup: _importMemoryBackup,
      runMaintenance: _runMemoryMaintenance,
      clearData: _clearMemoryData,
      maintenanceEnabled: _config.memory.maintenance.enabled,
      maintenanceMaxItemsPerBatch: _config.memory.maintenance.maxItemsPerBatch,
    );
  }

  Future<List<MemoryRecord>> _loadMemoryRecords() async {
    return _withMemoryClient((client) {
      return Future.wait([
        client.listMemory(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          status: 'active',
        ),
        client.listMemory(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          status: 'disabled',
        ),
      ]).then(
        (groups) => [
          for (final group in groups)
            for (final record in group) record,
        ],
      );
    });
  }

  Future<List<MemoryCandidate>> _loadMemoryCandidates() async {
    return _withMemoryClient((client) {
      return client.listCandidates(
        userId: _memoryUserId(),
        workspaceId: _memoryScopeCwd(),
        repoId: _memoryScopeCwd(),
        agentId: _config.agentName,
        sessionId: _controller.currentSession?.id,
        status: null,
      );
    });
  }

  Future<List<MemoryChangeRequest>> _loadMemoryChangeRequests() async {
    return _withMemoryClient((client) {
      return client.listChangeRequests(
        userId: _memoryUserId(),
        workspaceId: _memoryScopeCwd(),
        repoId: _memoryScopeCwd(),
        agentId: _config.agentName,
        sessionId: _controller.currentSession?.id,
        status: null,
      );
    });
  }

  Future<List<MemoryAuditEvent>> _loadMemoryAuditEvents() async {
    return _withMemoryClient((client) {
      return client.listAudit(
        userId: _memoryUserId(),
        workspaceId: _memoryScopeCwd(),
        repoId: _memoryScopeCwd(),
        agentId: _config.agentName,
        sessionId: _controller.currentSession?.id,
      );
    });
  }

  Future<void> _approveMemoryCandidate(MemoryCandidate candidate) async {
    await _withMemoryClient((client) => client.approveCandidate(candidate));
    unawaited(_refreshMemoryPendingCount());
  }

  Future<void> _rejectMemoryCandidate(MemoryCandidate candidate) async {
    await _withMemoryClient((client) => client.rejectCandidate(candidate.id));
    unawaited(_refreshMemoryPendingCount());
  }

  Future<void> _updateMemoryRecord(MemoryRecord record) async {
    await _withMemoryClient((client) => client.updateMemory(record));
  }

  Future<void> _disableMemoryRecord(MemoryRecord record) async {
    await _withMemoryClient((client) => client.disableMemory(record.id));
  }

  Future<void> _restoreMemoryRecord(MemoryRecord record) async {
    await _withMemoryClient((client) => client.restoreMemory(record.id));
  }

  Future<void> _submitMemoryRecordFeedback(
    MemoryRecord record,
    String rating,
    String? reason,
  ) async {
    await _withMemoryClient(
      (client) => client.submitFeedback(
        memoryId: record.id,
        rating: rating,
        reason: reason,
      ),
    );
  }

  Future<void> _approveMemoryChangeRequest(MemoryChangeRequest request) async {
    await _withMemoryClient((client) => client.approveChangeRequest(request));
    unawaited(_refreshMemoryPendingCount());
  }

  Future<void> _rejectMemoryChangeRequest(MemoryChangeRequest request) async {
    await _withMemoryClient((client) => client.rejectChangeRequest(request.id));
    unawaited(_refreshMemoryPendingCount());
  }

  Future<MemoryChangeRequest> _updateMemoryChangeRequest(
    MemoryChangeRequest request,
  ) async {
    final updated = await _withMemoryClient(
      (client) => client.updateChangeRequest(request),
    );
    unawaited(_refreshMemoryPendingCount());
    return updated;
  }

  Future<MaintenanceRunResult> _runMemoryMaintenance() async {
    final maintenance = _config.memory.maintenance;
    final result = await _withMemoryClient(
      (client) => client.runMaintenance(
        scope: MemoryScopeData(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
        ),
        enabled: maintenance.enabled,
        mode: maintenance.mode,
        costMode: maintenance.costMode,
        highConfidenceThreshold: maintenance.highConfidenceThreshold,
        reviewThreshold: maintenance.reviewThreshold,
        maxItemsPerBatch: maintenance.maxItemsPerBatch,
        manualOnlyActions: maintenance.manualOnlyActions,
      ),
    );
    unawaited(_refreshMemoryPendingCount());
    return result;
  }

  Future<MemoryClearResult> _clearMemoryData(String level) async {
    final result = await _withMemoryClient(
      (client) => client.clearMemory(
        scope: MemoryScopeData(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          agentId: _config.agentName,
          sessionId: _controller.currentSession?.id,
        ),
        level: level,
      ),
    );
    unawaited(_refreshMemoryPendingCount());
    return result;
  }

  Future<MemoryExportResult?> _exportMemoryBackup() async {
    final result = await _withMemoryClient(
      (client) => client.exportMemory(
        scope: MemoryScopeData(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          agentId: _config.agentName,
          sessionId: _controller.currentSession?.id,
        ),
      ),
    );
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Memory Backup',
      fileName: _memoryBackupFileName(DateTime.now()),
      type: FileType.custom,
      allowedExtensions: const ['jsonl'],
      bytes: Uint8List.fromList(utf8.encode(result.jsonl)),
    );
    return path == null ? null : result;
  }

  Future<MemoryImportResult?> _importMemoryBackup(String mode) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: 'Import Memory Backup',
      type: FileType.custom,
      allowedExtensions: const ['jsonl'],
      allowMultiple: false,
      withData: true,
    );
    if (picked == null || picked.files.isEmpty) return null;
    final file = picked.files.single;
    if (file.size > 20 * 1024 * 1024) {
      throw const FormatException('Memory backup exceeds the 20 MB limit.');
    }
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) {
      throw const FileSystemException('Unable to read the selected backup.');
    }
    final result = await _withMemoryClient(
      (client) => client.importMemory(jsonl: utf8.decode(bytes), mode: mode),
    );
    unawaited(_refreshMemoryPendingCount());
    return result;
  }

  String _memoryBackupFileName(DateTime value) {
    final utc = value.toUtc();
    return 'ianvs-acp-memory-'
        '${utc.year.toString().padLeft(4, '0')}'
        '${utc.month.toString().padLeft(2, '0')}'
        '${utc.day.toString().padLeft(2, '0')}-'
        '${utc.hour.toString().padLeft(2, '0')}'
        '${utc.minute.toString().padLeft(2, '0')}'
        '${utc.second.toString().padLeft(2, '0')}.jsonl';
  }

  Future<T> _withMemoryClient<T>(
    Future<T> Function(MemoryApiClient client) action,
  ) async {
    if (!_config.memory.enabled) {
      throw StateError('Memory is disabled.');
    }
    final manager = _memoryDaemonManagerFor(_config.memory);
    final endpoint = await _ensureMemoryEndpoint(manager);
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

  Future<void> _refreshMemoryPendingCount([
    MemoryDaemonManager? expectedManager,
  ]) async {
    if (widget.controller != null || !_config.memory.enabled) {
      _setMemoryPendingCount(0);
      return;
    }
    final manager = expectedManager ?? _memoryDaemonManager;
    if (manager == null) {
      _setMemoryPendingCount(0);
      return;
    }

    try {
      final endpoint = await _ensureMemoryEndpoint(manager);
      if (!identical(_memoryDaemonManager, manager)) return;
      final client = MemoryApiClient(
        baseUrl: endpoint.baseUrl,
        token: endpoint.token,
      );
      try {
        final candidates = await client.listCandidates(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          agentId: _config.agentName,
          sessionId: _controller.currentSession?.id,
          status: 'pending',
        );
        final changeRequests = await client.listChangeRequests(
          userId: _memoryUserId(),
          workspaceId: _memoryScopeCwd(),
          repoId: _memoryScopeCwd(),
          agentId: _config.agentName,
          sessionId: _controller.currentSession?.id,
          status: 'pending',
        );
        if (identical(_memoryDaemonManager, manager)) {
          _setMemoryPendingCounts(
            candidateCount: candidates.length,
            changeRequestCount: changeRequests.length,
          );
        }
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      if (identical(_memoryDaemonManager, manager)) {
        _setMemoryPendingCount(0);
      }
    }
  }

  void _disposeMemoryDaemon() {
    final manager = _memoryDaemonManager;
    _memoryDaemonManager = null;
    _memoryDaemonSignature = null;
    _memoryTurnsSinceMaintenance = 0;
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
      'llm': memory.llm.toJson(),
      'maintenance': <String, Object?>{
        'enabled': memory.maintenance.enabled,
        'mode': memory.maintenance.mode,
        'costMode': memory.maintenance.costMode,
        'highConfidenceThreshold': memory.maintenance.highConfidenceThreshold,
        'reviewThreshold': memory.maintenance.reviewThreshold,
        'maxItemsPerBatch': memory.maintenance.maxItemsPerBatch,
        'manualOnlyActions': memory.maintenance.manualOnlyActions,
      },
      'executable': MemoryDaemonLaunch.resolveExecutable(
        currentDirectory: _cwd,
      ),
    });
  }

  Map<String, String> _memoryDaemonEnvironment(MemoryConfig memory) {
    final embedding = memory.embedding;
    final llm = memory.llm;
    final maintenance = memory.maintenance;
    return <String, String>{
      'MEMORY_EMBEDDING_PROVIDER': embedding.provider,
      'MEMORY_EMBEDDING_MODEL': embedding.model,
      'MEMORY_EMBEDDING_VARIANT': embedding.variant,
      'MEMORY_EMBEDDING_DIMENSION': embedding.dimension.toString(),
      'MEMORY_EMBEDDING_DOWNLOAD_POLICY': embedding.downloadPolicy,
      'MEMORY_LLM_PROVIDER': llm.provider,
      'MEMORY_LLM_BASE_URL': llm.baseUrl,
      'MEMORY_LLM_MODEL': llm.model,
      'MEMORY_LLM_API_KEY_ENV': llm.apiKeyEnv,
      'MEMORY_MAINTENANCE_ENABLED': maintenance.enabled.toString(),
      'MEMORY_MAINTENANCE_MODE': maintenance.mode,
      'MEMORY_MAINTENANCE_COST_MODE': maintenance.costMode,
      'MEMORY_MAINTENANCE_HIGH_CONFIDENCE_THRESHOLD': maintenance
          .highConfidenceThreshold
          .toString(),
      'MEMORY_MAINTENANCE_REVIEW_THRESHOLD': maintenance.reviewThreshold
          .toString(),
      'MEMORY_MAINTENANCE_MAX_ITEMS_PER_BATCH': maintenance.maxItemsPerBatch
          .toString(),
      'MEMORY_MAINTENANCE_MANUAL_ONLY_ACTIONS': maintenance.manualOnlyActions
          .join(','),
    };
  }

  Future<List<ExtractedMemoryCandidate>> _extractMemoryCandidates(
    AcpClientConfig config,
    MemoryTurnContext context,
    String cwd,
  ) async {
    final memory = config.memory;
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
        globalInstructions: memory.extractor.globalInstructions,
        workspaceInstructions: memory.extractor.workspaceInstructions,
        repoInstructions: memory.extractor.repoInstructions,
      );
      try {
        return await _extractWithExplicitFallback(
          context,
          () => extractor.extract(
            userPrompt: context.userPrompt,
            assistantAnswer: context.assistantAnswer,
          ),
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
      clientFactory: () => _agentClient(sidecarConfig, includeMemoryMcp: false),
    );
    return _extractWithExplicitFallback(
      context,
      () => extractor.extract(
        userPrompt: context.userPrompt,
        assistantAnswer: context.assistantAnswer,
        cwd: cwd,
        model: memory.extractor.model,
        globalInstructions: memory.extractor.globalInstructions,
        workspaceInstructions: memory.extractor.workspaceInstructions,
        repoInstructions: memory.extractor.repoInstructions,
      ),
    );
  }

  Future<List<ExtractedMemoryCandidate>> _extractWithExplicitFallback(
    MemoryTurnContext context,
    Future<List<ExtractedMemoryCandidate>> Function() extract,
  ) async {
    final fallback = localMemoryFallbackCandidates(
      userPrompt: context.userPrompt,
      assistantAnswer: context.assistantAnswer,
    );
    try {
      final extracted = await extract();
      if (extracted.isEmpty) return fallback;
      return mergeExtractedMemoryCandidates(extracted, fallback);
    } catch (_) {
      if (fallback.isNotEmpty) return fallback;
      rethrow;
    }
  }

  String _memoryScopeCwd() {
    final sessionCwd = _controller.currentSession?.cwd.trim();
    if (sessionCwd != null && sessionCwd.isNotEmpty) return sessionCwd;
    return _cwd;
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

  DartAcpAgentClient _agentClient(
    AcpClientConfig config, {
    bool includeMemoryMcp = true,
  }) {
    final server = config.activeAgentServer;
    final mcpServers = config.mcpServers
        .map((server) => server.toJson())
        .toList();
    final memoryMcpServersProvider = includeMemoryMcp && config.memory.enabled
        ? () => _memoryMcpServers(config.memory)
        : null;
    if (server == null) {
      return DartAcpAgentClient(
        mcpServers: mcpServers,
        mcpServersProvider: memoryMcpServersProvider,
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
      mcpServersProvider: memoryMcpServersProvider,
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

  Future<List<Map<String, dynamic>>> _memoryMcpServers(
    MemoryConfig memory,
  ) async {
    try {
      final manager = _memoryDaemonManagerFor(memory);
      final endpoint = await _ensureMemoryEndpoint(manager);
      return <Map<String, dynamic>>[
        buildMemoryMcpServerConfig(
          command: MemoryDaemonLaunch.resolveExecutable(currentDirectory: _cwd),
          daemonUrl: endpoint.baseUrl,
          token: endpoint.token,
          review: memory.review,
          maintenance: memory.maintenance,
        ),
      ];
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
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
