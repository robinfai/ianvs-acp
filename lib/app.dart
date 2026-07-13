import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:dart_acp/dart_acp.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'acp/acp_agent_client.dart';
import 'acp/acp_endpoint_validator.dart';
import 'acp/agent_session.dart';
import 'acp/dart_acp_agent_client.dart';
import 'acp/acp_permission_reviewer.dart';
import 'acp/unavailable_acp_agent_client.dart';
import 'config/acp_agent_discovery.dart';
import 'config/acp_client_config.dart';
import 'config/acp_config_store.dart';
import 'config/macos_keychain_secret_store.dart';
import 'config/secret_store.dart';
import 'platform/file_manager.dart';
import 'startup/deep_link_request.dart';
import 'startup/startup_options.dart';
import 'state/chat_controller.dart';
import 'tasks/task_agent_pool.dart';
import 'tasks/runtime_registry.dart';
import 'tasks/retry_policy.dart';
import 'tasks/task_inbox_controller.dart';
import 'tasks/task_inbox_migrator.dart';
import 'tasks/task_inbox_sqlite_store.dart';
import 'tasks/task_inbox_state_store.dart';
import 'tasks/task_persistence_cleanup.dart';
import 'tasks/task_record.dart';
import 'tasks/task_runner.dart';
import 'tasks/task_scheduler.dart';
import 'ui/components/agent_discovery_dialog.dart';
import 'ui/components/bounded_image_preview.dart';
import 'ui/components/deep_link_confirmation_dialog.dart';
import 'ui/components/new_session_agent_dialog.dart';
import 'ui/components/session_workspace_review_dialog.dart';
import 'ui/components/workspace_sidebar.dart';
import 'ui/image_decode_budget.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_design_tokens.dart';
import 'workspace/workspace.dart';
import 'workspace/workspace_sidebar_state_store.dart';

typedef AgentServerDiscoverer =
    FutureOr<List<AgentServerConfig>> Function(AcpClientConfig config);
typedef DiscoveredAgentServerWriter =
    Future<AcpClientConfig> Function(
      AcpClientConfig config,
      List<AgentServerConfig> servers,
    );
typedef AcpConfigWriter =
    Future<AcpClientConfig> Function(AcpClientConfig config);
typedef SessionWindowOpener = Future<void> Function(List<String> args);
typedef AcpAgentClientFactory = AcpAgentClient Function(AcpClientConfig config);

const String _noAgentConfiguredMessage =
    'Add an ACP agent before starting a session.';

class _PendingDeepLinkRequest {
  const _PendingDeepLinkRequest({required this.key, required this.request});

  final String key;
  final DeepLinkRequest request;
}

class AcpClientApp extends StatefulWidget {
  const AcpClientApp({
    super.key,
    this.controller,
    this.config = const AcpClientConfig(),
    this.startupError,
    this.discoverAgentServers,
    this.writeDiscoveredAgentServers,
    this.writeConfig,
    this.secretStore = const MacosKeychainSecretStore(),
    this.configurationWritable = true,
    this.initialResumeSessionId,
    this.initialResumeCwd,
    this.initialResumeAgentName,
    this.initialTaskId,
    this.openSessionWindow,
    this.autoLoadWorkspaceSessions = true,
    this.taskInboxController,
    this.taskInboxMaintenanceInterval = const Duration(hours: 1),
    this.createAgentClient,
    this.createTaskAgentClient,
    this.agentClientFactoryKey,
    this.taskAgentClientFactoryKey,
    this.workspaceStateStore,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder,
  });

  final ChatController? controller;
  final AcpClientConfig config;
  final String? startupError;
  final AgentServerDiscoverer? discoverAgentServers;
  final DiscoveredAgentServerWriter? writeDiscoveredAgentServers;
  final AcpConfigWriter? writeConfig;
  final SecretStore secretStore;
  final bool configurationWritable;
  final String? initialResumeSessionId;
  final String? initialResumeCwd;
  final String? initialResumeAgentName;
  final String? initialTaskId;
  final SessionWindowOpener? openSessionWindow;
  final bool autoLoadWorkspaceSessions;
  final TaskInboxController? taskInboxController;

  /// Foreground check cadence. The repository persists a 24-hour throttle,
  /// so checking more often cannot purge more than once per day.
  final Duration taskInboxMaintenanceInterval;
  final AcpAgentClientFactory? createAgentClient;
  final AcpAgentClientFactory? createTaskAgentClient;

  /// Change this key when [createAgentClient] changes behavior. Keep it stable
  /// across ordinary widget rebuilds.
  final Object? agentClientFactoryKey;

  /// Change this key when [createTaskAgentClient] changes behavior. Keep it
  /// stable across ordinary widget rebuilds.
  final Object? taskAgentClientFactoryKey;
  final WorkspaceSidebarStateStore? workspaceStateStore;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder? boundedImageDecoder;

  @override
  State<AcpClientApp> createState() => _AcpClientAppState();
}

class _AcpClientAppState extends State<AcpClientApp>
    with WidgetsBindingObserver {
  static const String _initialResumeSessionId = String.fromEnvironment(
    'ACP_RESUME_SESSION_ID',
  );
  static const MethodChannel _deepLinkChannel = MethodChannel(
    'ianvs_acp/deep_links',
  );
  static const int _maxDeepLinkConfirmations = 8;

  late AcpClientConfig _config;
  late String _widgetConfigSignature;
  late ChatController _controller;
  late AcpInputBudget _inputBudget;
  late AcpImageDecodeBudgetLedger _imageDecodeLedger;
  late BoundedImageDecoder _boundedImageDecoder;
  late final String _cwd;
  final Map<String, ChatController> _controllersByAgent =
      <String, ChatController>{};
  final Map<String, String> _controllerSignaturesByAgent = <String, String>{};
  final Map<ChatController, VoidCallback> _sessionIndexListeners =
      <ChatController, VoidCallback>{};
  final Set<String> _handledDeepLinks = <String>{};
  final Queue<_PendingDeepLinkRequest> _pendingDeepLinkRequests =
      Queue<_PendingDeepLinkRequest>();
  bool _deepLinkConfirmationActive = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final Set<ArchivedSessionSnapshot> _pendingUndoSnapshots =
      HashSet<ArchivedSessionSnapshot>.identity();
  TaskInboxController? _taskInboxController;
  TaskScheduler? _taskScheduler;
  String? _selectedTaskId;
  bool _ownsTaskInboxController = false;
  String? _taskInboxStorePath;
  TaskInboxSqliteStore? _ownedTaskRepository;
  String? _taskInboxInitializationError;
  bool _taskInboxInitializationPending = false;
  int _taskInboxInitializationSerial = 0;
  TaskInboxController? _pendingTaskInboxController;
  Future<void>? _taskInboxTransition;
  Timer? _taskInboxRefreshTimer;
  Future<void>? _taskInboxRefresh;
  Timer? _taskInboxMaintenanceTimer;
  Future<void>? _taskInboxMaintenance;
  TaskPersistenceQuarantineRegistry get _taskPersistenceQuarantine =>
      TaskPersistenceQuarantineRegistry.shared;
  bool _agentDiscoveryStarted = false;
  bool _sessionIndexHydrated = false;
  bool _sessionIndexPersistScheduled = false;
  int _sessionIndexHydrationSerial = 0;
  int _sessionCatalogLoadSerial = 0;
  WorkspaceSessionIndexPersistenceQueue? _sessionIndexPersistence;

  @override
  void initState() {
    super.initState();
    widget.inputBudget.validate();
    _inputBudget = widget.inputBudget;
    _imageDecodeLedger =
        widget.imageDecodeLedger ??
        AcpImageDecodeBudgetLedger(budget: _inputBudget);
    _boundedImageDecoder =
        widget.boundedImageDecoder ?? const DartUiBoundedImageDecoder();
    _validateTaskInboxMaintenanceInterval();
    WidgetsBinding.instance.addObserver(this);
    _config = _configWithInitialAgent(widget.config);
    _widgetConfigSignature = _configSignature(_config);
    _cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: Directory.current.path,
    );
    if (widget.controller == null) {
      _controller = _cachedControllerFor(_config);
      _ensureControllersForSelectableAgents(_config);
      unawaited(_hydrateSessionIndex());
    } else {
      _controller = widget.controller!;
    }
    _configureTaskInboxController();
    final initialStartupOptions = _initialStartupOptions;
    if (initialStartupOptions.hasResumeSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_resumeFromStartupOptions(initialStartupOptions));
      });
    }
    if (initialStartupOptions.hasTaskLink) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _openTaskFromStartupOptions(initialStartupOptions);
      });
    }
    _setupDeepLinkHandling();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_maybeDiscoverAgents());
    });
  }

  @override
  void didUpdateWidget(covariant AcpClientApp oldWidget) {
    super.didUpdateWidget(oldWidget);
    widget.inputBudget.validate();
    _inputBudget = widget.inputBudget;
    if (!identical(widget.imageDecodeLedger, oldWidget.imageDecodeLedger) ||
        (!identical(widget.inputBudget, oldWidget.inputBudget) &&
            widget.imageDecodeLedger == null)) {
      _imageDecodeLedger =
          widget.imageDecodeLedger ??
          AcpImageDecodeBudgetLedger(budget: _inputBudget);
    }
    _boundedImageDecoder =
        widget.boundedImageDecoder ?? const DartUiBoundedImageDecoder();
    _validateTaskInboxMaintenanceInterval();
    if (oldWidget.taskInboxMaintenanceInterval !=
        widget.taskInboxMaintenanceInterval) {
      _taskInboxMaintenanceTimer?.cancel();
      _taskInboxMaintenanceTimer = null;
      final controller = _taskInboxController;
      if (controller != null) _startTaskInboxMaintenance(controller);
    }

    final nextWidgetConfig = _configWithInitialAgent(widget.config);
    final nextConfigSignature = _configSignature(nextWidgetConfig);
    final configChanged = nextConfigSignature != _widgetConfigSignature;
    final controllerChanged = oldWidget.controller != widget.controller;
    final foregroundAgentFactoryChanged =
        oldWidget.agentClientFactoryKey != widget.agentClientFactoryKey ||
        (oldWidget.createAgentClient == null) !=
            (widget.createAgentClient == null);
    final explicitTaskAgentFactoryChanged =
        oldWidget.taskAgentClientFactoryKey !=
            widget.taskAgentClientFactoryKey ||
        (oldWidget.createTaskAgentClient == null) !=
            (widget.createTaskAgentClient == null);
    final taskAgentFactoryChanged =
        explicitTaskAgentFactoryChanged ||
        (oldWidget.createTaskAgentClient == null &&
            widget.createTaskAgentClient == null &&
            foregroundAgentFactoryChanged);
    final taskInboxControllerChanged =
        oldWidget.taskInboxController != widget.taskInboxController;

    if (controllerChanged) {
      Future<void>? previousTaskCleanup;
      final foregroundChangesInboxAvailability =
          oldWidget.taskInboxController == null &&
          widget.taskInboxController == null &&
          (oldWidget.controller == null) != (widget.controller == null);
      final taskInputsChanged =
          configChanged ||
          taskAgentFactoryChanged ||
          taskInboxControllerChanged ||
          foregroundChangesInboxAvailability;
      if (taskInputsChanged) {
        previousTaskCleanup = _stopTaskInboxTransition();
      }
      if (oldWidget.controller == null) {
        final cachedControllers = _takeCachedControllers();
        if (previousTaskCleanup == null) {
          _disposeControllerList(cachedControllers);
        } else {
          unawaited(
            _disposeControllersAfterTaskCleanup(
              previousTaskCleanup,
              cachedControllers,
            ),
          );
        }
      }
      _config = nextWidgetConfig;
      _widgetConfigSignature = nextConfigSignature;
      if (widget.controller == null) {
        _controller = _cachedControllerFor(_config);
        _ensureControllersForSelectableAgents(_config);
        unawaited(_hydrateSessionIndex());
      } else {
        _controller = widget.controller!;
      }
      _configureTaskInboxController(previousCleanup: previousTaskCleanup);
      return;
    }

    if (!configChanged &&
        (foregroundAgentFactoryChanged || taskAgentFactoryChanged)) {
      final previousTaskCleanup = taskAgentFactoryChanged
          ? _stopTaskInboxTransition()
          : null;
      if (foregroundAgentFactoryChanged && widget.controller == null) {
        _replaceOwnedControllerFactory(
          previousTaskCleanup: previousTaskCleanup,
        );
      }
      _configureTaskInboxController(previousCleanup: previousTaskCleanup);
      if (mounted) setState(() {});
      return;
    }

    if (!configChanged) {
      if (widget.controller != null) _controller = widget.controller!;
      _configureTaskInboxController();
      return;
    }

    if (widget.controller != null) {
      final previousTaskCleanup = _stopTaskInboxTransition();
      _config = nextWidgetConfig;
      _widgetConfigSignature = nextConfigSignature;
      _controller = widget.controller!;
      _configureTaskInboxController(previousCleanup: previousTaskCleanup);
      return;
    }

    _widgetConfigSignature = nextConfigSignature;
    _replaceOwnedControllerConfiguration(nextWidgetConfig, rebuild: false);
  }

  StartupOptions get _initialStartupOptions {
    final runtime = widget.initialResumeSessionId?.trim();
    return StartupOptions(
      resumeSessionId: runtime != null && runtime.isNotEmpty
          ? runtime
          : _initialResumeSessionId,
      resumeCwd: _trimmedOrNull(widget.initialResumeCwd),
      resumeAgentName: _trimmedOrNull(widget.initialResumeAgentName),
      taskId: _trimmedOrNull(widget.initialTaskId),
    );
  }

  void _validateTaskInboxMaintenanceInterval() {
    final interval = widget.taskInboxMaintenanceInterval;
    if (interval <= Duration.zero) {
      throw ArgumentError.value(
        interval,
        'taskInboxMaintenanceInterval',
        'Must be positive.',
      );
    }
  }

  AcpClientConfig _configWithInitialAgent(AcpClientConfig config) {
    final agentName = widget.initialResumeAgentName?.trim();
    if (agentName == null || agentName.isEmpty) return config;
    try {
      return config.withActiveAgentServer(agentName);
    } catch (_) {
      return config;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final snapshot in _pendingUndoSnapshots.toList(growable: false)) {
      snapshot.discard();
    }
    _pendingUndoSnapshots.clear();
    final taskCleanup = _stopTaskInboxTransition();
    if (widget.controller == null) {
      _deepLinkChannel.setMethodCallHandler(null);
      final cachedControllers = _takeCachedControllers();
      if (taskCleanup == null) {
        _disposeControllerList(cachedControllers);
      } else {
        unawaited(
          _disposeControllersAfterTaskCleanup(taskCleanup, cachedControllers),
        );
      }
    } else {
      _ignoreTaskCleanup(taskCleanup);
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _taskInboxController;
    if (state == AppLifecycleState.resumed) {
      if (controller != null) {
        _startTaskInboxRefresh(controller);
        _startTaskInboxMaintenance(controller, runImmediately: true);
      }
      return;
    }
    _taskInboxRefreshTimer?.cancel();
    _taskInboxRefreshTimer = null;
    _taskInboxMaintenanceTimer?.cancel();
    _taskInboxMaintenanceTimer = null;
  }

  void _configureTaskInboxController({Future<void>? previousCleanup}) {
    final injected = widget.taskInboxController;
    if (injected != null) {
      if ((_taskInboxController == injected &&
              !_ownsTaskInboxController &&
              _taskScheduler != null) ||
          (_taskInboxInitializationPending &&
              _pendingTaskInboxController == injected)) {
        return;
      }
      final cleanup = _joinTaskCleanup(
        previousCleanup,
        _stopTaskInboxTransition(),
      );
      _taskInboxStorePath = null;
      _taskInboxInitializationError = null;
      _taskInboxInitializationPending = true;
      _pendingTaskInboxController = injected;
      final serial = ++_taskInboxInitializationSerial;
      final initialization = _initializeInjectedTaskInbox(
        serial: serial,
        controller: injected,
        previousCleanup: cleanup,
      );
      _taskInboxTransition = initialization;
      unawaited(initialization);
      return;
    }

    if (widget.controller != null) {
      final cleanup = _joinTaskCleanup(
        previousCleanup,
        _stopTaskInboxTransition(),
      );
      _taskInboxTransition = cleanup;
      _ignoreTaskCleanup(cleanup);
      _taskInboxStorePath = null;
      _taskInboxInitializationError = null;
      return;
    }

    final sourcePath = TaskInboxStateStore.defaultPath(
      configPath: _config.configPath,
    );
    final repositoryPath = TaskInboxSqliteStore.defaultPath(
      configPath: _config.configPath,
    );
    if (_taskInboxStorePath == repositoryPath &&
        ((_ownsTaskInboxController && _taskInboxController != null) ||
            _taskInboxInitializationPending)) {
      return;
    }

    final cleanup = _joinTaskCleanup(
      previousCleanup,
      _stopTaskInboxTransition(),
    );
    _taskInboxStorePath = repositoryPath;
    _taskInboxInitializationError = null;
    _taskInboxInitializationPending = true;
    final serial = ++_taskInboxInitializationSerial;
    final initialization = _initializeTaskInbox(
      serial: serial,
      sourcePath: sourcePath,
      repositoryPath: repositoryPath,
      previousCleanup: cleanup,
    );
    _taskInboxTransition = initialization;
    unawaited(initialization);
  }

  Future<void> _initializeTaskInbox({
    required int serial,
    required String? sourcePath,
    required String? repositoryPath,
    Future<void>? previousCleanup,
  }) async {
    TaskInboxSqliteStore? repository;
    TaskInboxController? controller;
    TaskScheduler? scheduler;
    try {
      await prepareTaskPersistenceTarget(
        registry: _taskPersistenceQuarantine,
        previousCleanup: previousCleanup,
        targetPath: repositoryPath,
      );
      if (!mounted || serial != _taskInboxInitializationSerial) return;
      repository = TaskInboxSqliteStore(path: repositoryPath);
      final migrationRepository = repository;
      final pendingMigration =
          TaskPersistencePendingOperation<TaskMigrationResult>(
            path: repositoryPath,
            operationName: 'migrateIfNeeded',
            watchdog: TaskInboxController.defaultPersistenceWatchdog,
            operation: () => TaskInboxMigrator(
              source: TaskInboxStateStore(path: sourcePath),
              repository: migrationRepository,
            ).migrateIfNeeded(),
            closeRepository: migrationRepository.close,
          );
      _taskPersistenceQuarantine.retain(pendingMigration);
      late final TaskMigrationResult migration;
      try {
        migration = await pendingMigration.result;
      } on Object {
        pendingMigration.abandon();
        repository = null;
        try {
          await _taskPersistenceQuarantine.ensurePathAvailable(
            pendingMigration.path,
          );
        } on Object {
          // The process-wide owner retains the repository until the source
          // migration Future quiesces, so cleanup must not close it here.
        }
        rethrow;
      }
      if (migration.status == TaskMigrationStatus.awaitingBackupFinalization) {
        pendingMigration.abandon();
        repository = null;
        await _taskPersistenceQuarantine.ensurePathAvailable(
          pendingMigration.path,
        );
        throw StateError('The legacy task backup could not be verified.');
      }
      pendingMigration.transfer();
      _taskPersistenceQuarantine.release(pendingMigration);
      await migrationRepository.purgeRawPayloads(now: DateTime.now());
      controller = TaskInboxController(repository: migrationRepository);
      scheduler = _createTaskScheduler(controller);
      await scheduler.start(dispatchQueuedTasks: false);
      if (!mounted || serial != _taskInboxInitializationSerial) {
        final cleanup = _startTaskPersistenceCleanup(
          scheduler: scheduler,
          controller: controller,
          repository: repository,
        );
        scheduler = null;
        controller = null;
        repository = null;
        await cleanup;
        return;
      }

      _taskInboxInitializationPending = false;
      _taskInboxInitializationError = null;
      _ownedTaskRepository = repository;
      _taskInboxController = controller;
      _ownsTaskInboxController = true;
      _taskScheduler = scheduler;
      _startTaskInboxRefresh(controller);
      _startTaskInboxMaintenance(controller);
      scheduler.startDispatching();
      setState(() {});
    } on Object catch (error) {
      var reportedError = error;
      final cleanup = _startTaskPersistenceCleanup(
        scheduler: scheduler,
        controller: controller,
        repository: repository,
      );
      scheduler = null;
      controller = null;
      repository = null;
      try {
        await cleanup;
      } on Object catch (cleanupError) {
        reportedError = cleanupError;
      }
      if (!mounted || serial != _taskInboxInitializationSerial) return;
      _taskInboxInitializationPending = false;
      _pendingTaskInboxController = null;
      _taskInboxController = null;
      _ownsTaskInboxController = false;
      _taskInboxInitializationError = _taskInboxErrorMessage(reportedError);
      setState(() {});
    }
  }

  Future<void> _initializeInjectedTaskInbox({
    required int serial,
    required TaskInboxController controller,
    Future<void>? previousCleanup,
  }) async {
    TaskScheduler? scheduler;
    try {
      await prepareTaskPersistenceTarget(
        registry: _taskPersistenceQuarantine,
        previousCleanup: previousCleanup,
        injectedController: true,
      );
      if (!mounted || serial != _taskInboxInitializationSerial) return;
      scheduler = _createTaskScheduler(controller);
      await scheduler.start(dispatchQueuedTasks: false);
      if (!mounted || serial != _taskInboxInitializationSerial) {
        await scheduler.shutdown();
        return;
      }

      _taskInboxInitializationPending = false;
      _pendingTaskInboxController = null;
      _taskInboxInitializationError = null;
      _taskInboxController = controller;
      _ownsTaskInboxController = false;
      _taskScheduler = scheduler;
      _startTaskInboxRefresh(controller);
      _startTaskInboxMaintenance(controller);
      scheduler.startDispatching();
      setState(() {});
    } on Object catch (error) {
      await scheduler?.shutdown();
      if (!mounted || serial != _taskInboxInitializationSerial) return;
      _taskInboxInitializationPending = false;
      _pendingTaskInboxController = null;
      _taskInboxController = null;
      _ownsTaskInboxController = false;
      _taskInboxInitializationError = _taskInboxErrorMessage(error);
      setState(() {});
    }
  }

  Future<void>? _disposeOwnedTaskInboxController() {
    _taskInboxInitializationSerial += 1;
    _taskInboxInitializationPending = false;
    _pendingTaskInboxController = null;
    final scheduler = _taskScheduler;
    scheduler?.stop();
    _taskScheduler = null;
    final controller = _ownsTaskInboxController ? _taskInboxController : null;
    _taskInboxController = null;
    final repository = _ownedTaskRepository;
    _ownedTaskRepository = null;
    _ownsTaskInboxController = false;
    final refreshCleanup = _stopTaskInboxRefresh();
    if (scheduler == null && controller == null && repository == null) {
      return refreshCleanup;
    }
    final persistenceCleanup = _startTaskPersistenceCleanup(
      scheduler: scheduler,
      controller: controller,
      repository: repository,
    );
    if (refreshCleanup == null) {
      return persistenceCleanup;
    }
    return () async {
      await refreshCleanup;
      await persistenceCleanup;
    }();
  }

  void _startTaskInboxRefresh(TaskInboxController controller) {
    _taskInboxRefreshTimer?.cancel();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
      _taskInboxRefreshTimer = null;
      return;
    }
    _taskInboxRefreshTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _taskInboxController != controller) return;
      if (_taskInboxRefresh != null || _taskInboxMaintenance != null) return;
      late final Future<void> refresh;
      refresh = _refreshTaskInbox(controller).whenComplete(() {
        if (identical(_taskInboxRefresh, refresh)) {
          _taskInboxRefresh = null;
        }
      });
      _taskInboxRefresh = refresh;
    });
  }

  void _startTaskInboxMaintenance(
    TaskInboxController controller, {
    bool runImmediately = false,
  }) {
    _taskInboxMaintenanceTimer?.cancel();
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    if (lifecycleState != null && lifecycleState != AppLifecycleState.resumed) {
      _taskInboxMaintenanceTimer = null;
      return;
    }
    if (runImmediately) _scheduleTaskInboxMaintenance(controller);
    _taskInboxMaintenanceTimer = Timer.periodic(
      widget.taskInboxMaintenanceInterval,
      (_) => _scheduleTaskInboxMaintenance(controller),
    );
  }

  void _scheduleTaskInboxMaintenance(TaskInboxController controller) {
    if (!mounted || _taskInboxController != controller) return;
    if (_taskInboxMaintenance != null) return;
    late final Future<void> maintenance;
    maintenance = _maintainTaskInbox(controller).whenComplete(() {
      if (identical(_taskInboxMaintenance, maintenance)) {
        _taskInboxMaintenance = null;
      }
    });
    _taskInboxMaintenance = maintenance;
  }

  Future<void> _maintainTaskInbox(TaskInboxController controller) async {
    try {
      final refresh = _taskInboxRefresh;
      if (refresh != null) await refresh;
      if (!mounted || _taskInboxController != controller) return;
      await controller.purgeRawPayloads(force: false);
    } on TaskPersistenceStalledException catch (error) {
      _taskInboxMaintenanceTimer?.cancel();
      _taskInboxMaintenanceTimer = null;
      final scheduler = _taskScheduler;
      if (scheduler != null) {
        scheduler.handlePersistenceFault(error);
        return;
      }
      if (!mounted || _taskInboxController != controller) return;
      _taskInboxInitializationError = _taskInboxErrorMessage(error);
      setState(() {});
    } on Object {
      // A transient maintenance failure is retried on the next foreground
      // interval or when the app resumes.
    }
  }

  Future<void> _refreshTaskInbox(TaskInboxController controller) async {
    try {
      await controller.refreshIfChanged();
    } on TaskPersistenceStalledException catch (error) {
      _taskInboxRefreshTimer?.cancel();
      _taskInboxRefreshTimer = null;
      final scheduler = _taskScheduler;
      if (scheduler != null) {
        scheduler.handlePersistenceFault(error);
        return;
      }
      if (!mounted || _taskInboxController != controller) return;
      _taskInboxInitializationError = _taskInboxErrorMessage(error);
      setState(() {});
    } on Object {
      // A transient read failure is retried by the next foreground poll.
    }
  }

  Future<void>? _stopTaskInboxRefresh() {
    _taskInboxRefreshTimer?.cancel();
    _taskInboxRefreshTimer = null;
    _taskInboxMaintenanceTimer?.cancel();
    _taskInboxMaintenanceTimer = null;
    return _joinTaskCleanup(_taskInboxRefresh, _taskInboxMaintenance);
  }

  Future<void>? _stopTaskInboxTransition() {
    return _joinTaskCleanup(
      _taskInboxTransition,
      _disposeOwnedTaskInboxController(),
    );
  }

  TaskScheduler _createTaskScheduler(TaskInboxController taskController) {
    final agentPool = _createTaskAgentPool(_config);
    final runner = TaskRunner(
      taskController: taskController,
      agentPool: agentPool,
    );
    late final TaskScheduler scheduler;
    scheduler = TaskScheduler(
      taskController: taskController,
      worker: TaskRunnerWorker(runner: runner),
      runtimeRegistry: LocalRuntimeRegistry(probe: agentPool.probeAgent),
      onPersistenceFault: (error) {
        _handleTaskSchedulerPersistenceFault(scheduler, error);
      },
    );
    return scheduler;
  }

  void _handleTaskSchedulerPersistenceFault(
    TaskScheduler scheduler,
    TaskPersistenceStalledException error,
  ) {
    if (!mounted || !identical(_taskScheduler, scheduler)) return;
    _taskInboxRefreshTimer?.cancel();
    _taskInboxRefreshTimer = null;
    _taskInboxMaintenanceTimer?.cancel();
    _taskInboxMaintenanceTimer = null;
    _taskInboxInitializationError = _taskInboxErrorMessage(error);
    setState(() {});
  }

  Future<void> _startTaskPersistenceCleanup({
    TaskScheduler? scheduler,
    TaskInboxController? controller,
    TaskInboxSqliteStore? repository,
  }) {
    if (controller != null && repository != null) {
      final owner = TaskPersistenceOwnerCleanup(
        path: repository.path,
        controller: controller,
        shutdownScheduler: () => scheduler?.shutdown() ?? Future<void>.value(),
        disposeController: controller.dispose,
        closeRepository: repository.close,
      );
      _taskPersistenceQuarantine.retain(owner);
      return _taskPersistenceQuarantine.ensurePathAvailable(owner.path);
    }
    return () async {
      await scheduler?.shutdown();
      controller?.dispose();
      await repository?.close();
    }();
  }

  Future<void>? _joinTaskCleanup(Future<void>? first, Future<void>? second) {
    if (first == null) return second;
    if (second == null) return first;
    return Future.wait(<Future<void>>[first, second]);
  }

  void _ignoreTaskCleanup(Future<void>? cleanup) {
    if (cleanup == null) return;
    unawaited(() async {
      try {
        await cleanup;
      } on Object {
        // There is no live task UI to report teardown failures to.
      }
    }());
  }

  Future<void> _disposeControllersAfterTaskCleanup(
    Future<void> cleanup,
    List<ChatController> controllers,
  ) async {
    try {
      await cleanup;
    } on Object {
      // Cached controllers still need disposal after task teardown errors.
    } finally {
      _disposeControllerList(controllers);
    }
  }

  String _taskInboxErrorMessage(Object error) {
    if (error is FormatException) {
      return 'Could not initialize Task Inbox: legacy task data is invalid; '
          'the original file was not changed.';
    }
    if (error is TaskPersistenceStalledException) {
      return 'Task persistence stalled during ${error.operation}. '
          'Background task dispatch was stopped. The repository remains '
          'quarantined until the pending operation finishes; retry the '
          'configuration change afterward.';
    }
    return 'Could not initialize Task Inbox: $error';
  }

  void _setupDeepLinkHandling() {
    if (widget.controller != null) return;
    _deepLinkChannel.setMethodCallHandler((call) async {
      if (call.method != 'openDeepLink') return null;
      final rawLink = call.arguments;
      if (rawLink is String) unawaited(_handleDeepLink(rawLink));
      return null;
    });
    unawaited(_loadInitialDeepLinks());
  }

  Future<void> _loadInitialDeepLinks() async {
    try {
      final rawLinks = await _deepLinkChannel.invokeMethod<List<Object?>>(
        'getInitialDeepLinks',
      );
      if (rawLinks == null) return;
      for (final rawLink in rawLinks) {
        if (rawLink is String) await _handleDeepLink(rawLink);
      }
    } on MissingPluginException {
      return;
    }
  }

  Future<void> _handleDeepLink(String rawLink) async {
    final normalizedLink = rawLink.trim();
    if (normalizedLink.isEmpty) return;
    final request = StartupOptions.fromDeepLink(normalizedLink);
    if (request == null) return;
    if (!request.requiresConfirmation) {
      if (request.taskId != null) {
        _openTaskFromStartupOptions(StartupOptions(taskId: request.taskId));
      }
      return;
    }

    final key = _deepLinkRequestKey(request);
    if (!_handledDeepLinks.add(key)) return;

    final confirmationCount =
        _pendingDeepLinkRequests.length + (_deepLinkConfirmationActive ? 1 : 0);
    if (confirmationCount >= _maxDeepLinkConfirmations) {
      _handledDeepLinks.remove(key);
      return;
    }
    _pendingDeepLinkRequests.add(
      _PendingDeepLinkRequest(key: key, request: request),
    );
    unawaited(_drainDeepLinkConfirmationQueue());
  }

  String _deepLinkRequestKey(DeepLinkRequest request) {
    return jsonEncode(switch (request.kind) {
      DeepLinkRequestKind.session => <String?>[
        'session',
        request.sessionId,
        request.cwd,
        request.agentName,
      ],
      DeepLinkRequestKind.task => <String?>['task', request.taskId],
    });
  }

  Future<void> _drainDeepLinkConfirmationQueue() async {
    if (_deepLinkConfirmationActive || !mounted) return;
    if (_navigatorKey.currentContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_drainDeepLinkConfirmationQueue());
      });
      return;
    }

    _deepLinkConfirmationActive = true;
    try {
      while (mounted && _pendingDeepLinkRequests.isNotEmpty) {
        final dialogContext = _navigatorKey.currentContext;
        if (dialogContext == null) return;
        if (!dialogContext.mounted) return;
        final pending = _pendingDeepLinkRequests.removeFirst();
        final confirmed = await showDialog<bool>(
          context: dialogContext,
          barrierDismissible: false,
          builder: (_) => DeepLinkConfirmationDialog(request: pending.request),
        );
        if (!mounted) return;
        if (confirmed != true) {
          _handledDeepLinks.remove(pending.key);
          continue;
        }
        final request = pending.request;
        final workspace = validateDeepLinkWorkspace(request.cwd);
        if (workspace.errors.isNotEmpty) {
          _handledDeepLinks.remove(pending.key);
          _showSnackBar(
            'Could not open external session: ${workspace.errors.join(' ')}',
          );
          continue;
        }
        try {
          await _resumeFromStartupOptions(
            StartupOptions(
              resumeSessionId: request.sessionId,
              resumeCwd: workspace.path,
              resumeAgentName: request.agentName,
            ),
          );
        } on Object catch (error) {
          if (mounted) _showSnackBar('Could not open external session: $error');
        }
      }
    } finally {
      _deepLinkConfirmationActive = false;
    }
  }

  Future<void> _resumeFromStartupOptions(StartupOptions options) async {
    final sessionId = _trimmedOrNull(options.resumeSessionId);
    if (sessionId == null || !mounted) return;

    var controller = _controller;
    final agentName = _trimmedOrNull(options.resumeAgentName);
    if (widget.controller == null && agentName != null) {
      final config = _configForAgent(_config, agentName);
      if (config == null) {
        _showSnackBar('Could not select agent "$agentName".');
        return;
      }
      controller = _activateAgent(config);
    }

    await controller.resumeSession(sessionId, cwd: options.resumeCwd);
    if (mounted) setState(() {});
  }

  void _openTaskFromStartupOptions(StartupOptions options) {
    final taskId = _trimmedOrNull(options.taskId);
    if (taskId == null || !mounted) return;
    if (_taskInboxController == null) {
      if (_taskInboxInitializationPending) {
        _selectedTaskId = taskId;
        return;
      }
      _showSnackBar('Task Inbox is unavailable.');
      return;
    }
    setState(() => _selectedTaskId = taskId);
  }

  String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
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
        inputBudget: _inputBudget,
        imageDecodeLedger: _imageDecodeLedger,
        boundedImageDecoder: _boundedImageDecoder,
        controller: _controller,
        taskInboxController: _taskInboxController,
        initialSidebarMode: _selectedTaskId == null
            ? AppShellSidebarMode.workspaces
            : AppShellSidebarMode.inbox,
        selectedTaskId: _selectedTaskId,
        agentName: _config.agentName,
        agentServers: _config.selectableAgentServers,
        mcpServers: _config.mcpServers,
        additionalDirectories: _config.additionalDirectories,
        clientProviders: _clientProviderConfig(_config),
        configPath: _config.configPath,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: _combinedStartupError,
        canSwitchAgent: widget.controller == null,
        autoLoadWorkspaceSessions: _canAutoLoadWorkspaceSessions,
        sessionControllers: _sessionControllers,
        onNewSession: (context) => unawaited(_startNewSession(context)),
        onNewSessionInWorkspace: (context, workspace) =>
            unawaited(_startNewSession(context, initialCwd: workspace.path)),
        onSelectSession: (session) => unawaited(_selectSession(session)),
        canForkSession: _canForkSession,
        onSessionMenuAction: (context, session, action) =>
            unawaited(_handleSessionMenuAction(context, session, action)),
        onCreateWorkspaceWorktree: (context, workspace) =>
            unawaited(_createWorkspaceWorktree(context, workspace)),
        onArchiveWorkspaceSessions: (context, workspace) =>
            _archiveWorkspaceSessions(workspace),
        onRunTask: (context, task) => _runTask(context, task),
        onOpenTaskSession: (context, task) => _openTaskSession(context, task),
        onAgentAuthenticated: _authenticateTaskAgent,
        onSelectAgent: widget.controller == null
            ? (agentName) => unawaited(_selectAgent(agentName))
            : null,
        onSaveConfig: widget.controller == null && widget.configurationWritable
            ? (config) => _saveConfig(config)
            : null,
      ),
    );
  }

  String? get _combinedStartupError {
    final errors = <String>[
      if (widget.startupError case final error? when error.trim().isNotEmpty)
        error.trim(),
      if (_taskInboxInitializationError case final error?
          when error.trim().isNotEmpty)
        error.trim(),
    ];
    return errors.isEmpty ? null : errors.join('\n');
  }

  Future<void> _maybeDiscoverAgents() async {
    if (_agentDiscoveryStarted ||
        widget.controller != null ||
        !widget.configurationWritable) {
      return;
    }
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
      final injectedWrite = widget.writeDiscoveredAgentServers;
      final nextConfig = injectedWrite == null
          ? await AcpAgentDiscovery.writeSelectedAgentServers(
              _config,
              selected,
              secretStore: widget.secretStore,
            )
          : await injectedWrite(_config, selected);
      if (!mounted) return;
      _replaceOwnedControllerConfiguration(nextConfig);
      unawaited(_loadAllAgentSessionCatalogs());
      _showSnackBar('Added ${selected.length} discovered ACP agent(s).');
    } catch (error) {
      _showSnackBar('Could not add discovered agents: $error');
    }
  }

  ChatController _controllerFor(AcpClientConfig config) {
    final createAgentClient = widget.createAgentClient ?? _defaultAgentClient;
    return _controllerForWithFactory(config, createAgentClient);
  }

  ChatController _controllerForWithFactory(
    AcpClientConfig config,
    AcpAgentClientFactory createAgentClient,
  ) {
    return _controllerForClient(config, createAgentClient(config));
  }

  ChatController _controllerForClient(
    AcpClientConfig config,
    AcpAgentClient client,
  ) {
    final permissions = _permissionConfig(config);
    return ChatController(
      client: client,
      cwd: _cwd,
      additionalDirectories: config.additionalDirectories,
      agentName: config.agentName,
      permissionTrustRules: permissions.trustRules,
      permissionReviewer: _permissionReviewer(config),
    );
  }

  void _ensureControllersForSelectableAgents(AcpClientConfig config) {
    if (widget.controller != null) return;
    final seenAgentNames = <String>{};
    for (final server in config.selectableAgentServers) {
      final agentName = server.name.trim();
      if (agentName.isEmpty || !seenAgentNames.add(agentName)) continue;
      final agentConfig = _configForAgent(config, agentName);
      if (agentConfig != null) _cachedControllerFor(agentConfig);
    }
  }

  ChatController _cachedControllerFor(AcpClientConfig config) {
    final agentName = config.agentName;
    final signature = _controllerSignature(config);
    final existing = _controllersByAgent[agentName];
    if (existing != null &&
        _controllerSignaturesByAgent[agentName] == signature) {
      return existing;
    }

    if (existing != null) {
      _detachSessionIndexPersistence(existing);
      existing.dispose();
    }
    final controller = _controllerFor(config);
    _controllersByAgent[agentName] = controller;
    _controllerSignaturesByAgent[agentName] = signature;
    _attachSessionIndexPersistence(controller);
    return controller;
  }

  LocalTaskAgentPool _createTaskAgentPool(AcpClientConfig config) {
    final createAgentClient =
        widget.createTaskAgentClient ??
        widget.createAgentClient ??
        _defaultAgentClient;
    return LocalTaskAgentPool(
      controllerFactory: (agentName) {
        if (!mounted) return null;
        final agentConfig = _configForAgent(config, agentName.trim());
        if (agentConfig == null) return null;
        final client = createAgentClient(agentConfig);
        final reusesForegroundClient = _sessionControllers.any(
          (foreground) => identical(foreground.client, client),
        );
        if (reusesForegroundClient) {
          throw StateError(
            'The task agent factory must create a separate ACP client.',
          );
        }
        return _controllerForClient(agentConfig, client);
      },
    );
  }

  Future<void> _runTask(BuildContext _, TaskRecord task) async {
    final taskController = _taskInboxController;
    if (taskController == null) return;
    final scheduler = _taskScheduler;
    if (scheduler != null) {
      try {
        await scheduler.enqueueTask(task.id);
      } on TaskPersistenceStalledException catch (error) {
        scheduler.handlePersistenceFault(error);
        if (mounted) {
          _taskInboxInitializationError = _taskInboxErrorMessage(error);
        }
      }
      if (mounted) setState(() {});
      return;
    }
    final agentPool = _createTaskAgentPool(_config);
    final runner = TaskRunner(
      taskController: taskController,
      agentPool: agentPool,
    );
    try {
      await runner.runTask(task.id);
    } on TaskPersistenceStalledException catch (error) {
      if (mounted) {
        _taskInboxInitializationError = _taskInboxErrorMessage(error);
      }
    } finally {
      await runner.dispose();
    }
    if (mounted) setState(() {});
  }

  Future<void> _authenticateTaskAgent(String agentName, String methodId) async {
    final hasBlockedTask = _taskInboxController?.tasks.any(
      (task) =>
          task.agentName == agentName &&
          task.status == TaskStatus.blockedOnUserInput &&
          task.metadata['failure_reason'] ==
              TaskFailureReason.authRequired.name,
    );
    if (hasBlockedTask != true) return;
    final scheduler = _taskScheduler;
    if (scheduler == null) return;
    try {
      final authenticated = await scheduler.authenticateAgent(
        agentName,
        methodId,
      );
      if (!authenticated && mounted) {
        _showSnackBar(
          'The background task agent still requires authentication.',
        );
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnackBar(
          'Could not authenticate the background task agent: $error',
        );
      }
    }
  }

  Future<void> _openTaskSession(BuildContext _, TaskRecord task) async {
    final sessionId = task.sessionId?.trim();
    if (sessionId == null || sessionId.isEmpty) {
      _showSnackBar('This task does not have a linked session yet.');
      return;
    }

    var controller = _controller;
    final agentName = task.agentName.trim();
    if (widget.controller == null && agentName.isNotEmpty) {
      final config = _configForAgent(_config, agentName);
      if (config == null) {
        _showSnackBar('Could not select agent "$agentName".');
        return;
      }
      controller = _activateAgent(config);
    } else if (widget.controller != null && agentName != controller.agentName) {
      _showSnackBar('Could not open task session for agent "$agentName".');
      return;
    }

    await controller.resumeSession(sessionId, cwd: task.workspacePath);
    if (mounted) setState(() {});
  }

  void _replaceOwnedControllerConfiguration(
    AcpClientConfig nextConfig, {
    bool rebuild = true,
  }) {
    final taskCleanup = _stopTaskInboxTransition();
    final staleControllers = _takeCachedControllers();
    _config = nextConfig;
    _controller = _cachedControllerFor(nextConfig);
    _ensureControllersForSelectableAgents(nextConfig);
    unawaited(_hydrateSessionIndex());
    if (taskCleanup == null) {
      _disposeControllerList(staleControllers);
    } else {
      unawaited(
        _disposeControllersAfterTaskCleanup(taskCleanup, staleControllers),
      );
    }
    _configureTaskInboxController(previousCleanup: taskCleanup);
    if (rebuild && mounted) setState(() {});
  }

  void _replaceOwnedControllerFactory({Future<void>? previousTaskCleanup}) {
    final staleControllers = _takeCachedControllers();
    _controller = _cachedControllerFor(_config);
    _ensureControllersForSelectableAgents(_config);
    unawaited(_hydrateSessionIndex());
    if (previousTaskCleanup == null) {
      _disposeControllerList(staleControllers);
    } else {
      unawaited(
        _disposeControllersAfterTaskCleanup(
          previousTaskCleanup,
          staleControllers,
        ),
      );
    }
  }

  AcpClientConfig? _configForAgent(AcpClientConfig config, String agentName) {
    if (config.activeAgentServer != null && config.agentName == agentName) {
      return config;
    }
    return config.agentServerNamed(agentName) == null
        ? null
        : config.withActiveAgentServer(agentName);
  }

  bool get _canAutoLoadWorkspaceSessions {
    if (!widget.autoLoadWorkspaceSessions) return false;
    if (widget.controller != null) return true;
    if (_config.activeAgentServer == null) return false;
    final configPath = _config.configPath?.trim();
    return configPath != null && configPath.isNotEmpty;
  }

  List<ChatController> _takeCachedControllers() {
    final controllers = _controllersByAgent.values.toList(growable: false);
    for (final controller in controllers) {
      _detachSessionIndexPersistence(controller);
    }
    _controllersByAgent.clear();
    _controllerSignaturesByAgent.clear();
    return controllers;
  }

  void _disposeControllerList(Iterable<ChatController> controllers) {
    for (final controller in controllers) {
      controller.dispose();
    }
  }

  Future<void> _hydrateSessionIndex() async {
    if (widget.controller != null) return;
    final serial = ++_sessionIndexHydrationSerial;
    _sessionIndexHydrated = false;
    _sessionIndexPersistence = null;

    final workspaceStateStore = _workspaceStateStore;
    final sessions = await workspaceStateStore.loadSessionIndex();
    if (!mounted ||
        widget.controller != null ||
        serial != _sessionIndexHydrationSerial) {
      return;
    }
    _sessionIndexPersistence = WorkspaceSessionIndexPersistenceQueue(
      store: workspaceStateStore,
    );

    _ensureControllersForSelectableAgents(_config);
    for (final session in sessions) {
      final config = _configForSessionIndex(session);
      if (config == null) continue;
      _cachedControllerFor(config).mergeSessionIndex([
        _sessionIndexWithFallbackAgent(session, config.agentName),
      ]);
    }

    _sessionIndexHydrated = true;
    _schedulePersistSessionIndex();
    if (mounted) setState(() {});
    unawaited(_loadAllAgentSessionCatalogs());
  }

  Future<void> _loadAllAgentSessionCatalogs() async {
    if (widget.controller != null || !_canAutoLoadWorkspaceSessions) return;
    final serial = ++_sessionCatalogLoadSerial;
    _ensureControllersForSelectableAgents(_config);
    final controllers = _controllersByAgent.values.toList(growable: false);
    await Future.wait(
      controllers.map((controller) async {
        if (serial != _sessionCatalogLoadSerial) return;
        if (controller.isStreaming || controller.isSessionOperationRunning) {
          return;
        }
        if (!controller.canListSessions) return;
        try {
          await controller.loadSessionCatalog();
        } catch (_) {
          // One agent may not support session/list or may be offline; keep
          // loading the rest so workspace aggregation remains best-effort.
        }
      }),
    );
    if (!mounted || serial != _sessionCatalogLoadSerial) return;
    _schedulePersistSessionIndex();
    setState(() {});
  }

  AcpClientConfig? _configForSessionIndex(AgentSession session) {
    return _config.configForSessionIndexAgent(session.agentName);
  }

  AgentSession _sessionIndexWithFallbackAgent(
    AgentSession session,
    String agentName,
  ) {
    final existingAgentName = session.agentName?.trim();
    if (existingAgentName != null && existingAgentName.isNotEmpty) {
      return session;
    }
    return AgentSession(
      id: session.id,
      cwd: session.cwd,
      createdAt: session.createdAt,
      additionalDirectories: session.additionalDirectories,
      title: session.title,
      titleOverride: session.titleOverride,
      updatedAt: session.updatedAt,
      agentName: agentName,
      pinned: session.pinned,
      archived: session.archived,
      unread: session.unread,
    );
  }

  WorkspaceSidebarStateStore get _workspaceStateStore {
    return widget.workspaceStateStore ??
        WorkspaceSidebarStateStore(
          path: WorkspaceSidebarStateStore.defaultPath(
            configPath: _config.configPath,
          ),
        );
  }

  void _attachSessionIndexPersistence(ChatController controller) {
    if (widget.controller != null) return;
    if (_sessionIndexListeners.containsKey(controller)) return;
    void listener() => _schedulePersistSessionIndex();
    _sessionIndexListeners[controller] = listener;
    controller.addListener(listener);
  }

  void _detachSessionIndexPersistence(ChatController controller) {
    final listener = _sessionIndexListeners.remove(controller);
    if (listener == null) return;
    controller.removeListener(listener);
  }

  void _schedulePersistSessionIndex() {
    if (widget.controller != null || !_sessionIndexHydrated) return;
    if (_sessionIndexPersistScheduled) return;
    _sessionIndexPersistScheduled = true;
    scheduleMicrotask(() {
      _sessionIndexPersistScheduled = false;
      if (!mounted || widget.controller != null || !_sessionIndexHydrated) {
        return;
      }

      final sessions = _persistableSessionIndex();
      final signature = _sessionIndexSignature(sessions);
      _sessionIndexPersistence?.enqueue(
        sessions: sessions,
        signature: signature,
      );
    });
  }

  List<AgentSession> _persistableSessionIndex() {
    final sessionsByKey = <String, AgentSession>{};
    for (final controller in _controllersByAgent.values) {
      for (final session in controller.sessions) {
        final id = session.id.trim();
        final cwd = session.cwd.trim();
        if (id.isEmpty || cwd.isEmpty) continue;
        final agentName = session.agentName?.trim() ?? controller.agentName;
        sessionsByKey['$agentName\u0000$id'] = _sessionIndexWithFallbackAgent(
          session,
          agentName,
        );
      }
    }
    final sessions = sessionsByKey.values.toList()
      ..sort((a, b) => b.displayTime.compareTo(a.displayTime));
    return List.unmodifiable(sessions);
  }

  String _sessionIndexSignature(List<AgentSession> sessions) {
    return jsonEncode(
      sessions
          .map(
            (session) => <String, Object?>{
              'id': session.id,
              'cwd': session.cwd,
              'createdAt': session.createdAt.toIso8601String(),
              'updatedAt': session.updatedAt?.toIso8601String(),
              'title': session.title,
              'titleOverride': session.titleOverride,
              'agentName': session.agentName,
              'additionalDirectories': session.additionalDirectories,
              'pinned': session.pinned,
              'archived': session.archived,
              'unread': session.unread,
            },
          )
          .toList(growable: false),
    );
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
    if (!widget.configurationWritable) {
      throw StateError(
        'ACP configuration is read-only because startup loading failed.',
      );
    }
    final write = widget.writeConfig;
    late final AcpClientConfig nextConfig;
    var cleanupWarning = false;
    try {
      nextConfig = write == null
          ? await AcpConfigStore.writeConfig(
              config: config,
              secretStore: widget.secretStore,
            )
          : await write(config);
    } on AcpConfigPostCommitCleanupException catch (error) {
      nextConfig = error.committedConfig;
      cleanupWarning = true;
    }
    if (!mounted) return nextConfig;
    _replaceOwnedControllerConfiguration(nextConfig);
    unawaited(_loadAllAgentSessionCatalogs());
    _showSnackBar(
      cleanupWarning
          ? 'Saved agent configuration, but some retired Keychain entries could not be removed.'
          : 'Saved agent configuration.',
    );
    return nextConfig;
  }

  Future<void> _startNewSession(
    BuildContext dialogContext, {
    String? initialCwd,
  }) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }

    final agentServers = _config.selectableAgentServers;
    if (widget.controller == null && agentServers.isEmpty) {
      _showSnackBar(_noAgentConfiguredMessage);
      return;
    }
    final selection = await showDialog<NewSessionSelection>(
      context: dialogContext,
      builder: (context) => NewSessionAgentDialog(
        agentServers: widget.controller == null
            ? agentServers
            : const <AgentServerConfig>[],
        currentAgentName: _config.agentName,
        initialCwd:
            _trimmedOrNull(initialCwd) ??
            _controller.currentSession?.cwd ??
            _controller.cwd,
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

    final existingTargetController = _existingControllerForAgentName(
      session.agentName,
    );
    final existingTargetSession = existingTargetController?.currentSession;
    if (existingTargetSession != null &&
        existingTargetSession.id.trim() == session.id.trim()) {
      if (!sameSessionWorkspaceIdentity(existingTargetSession, session)) {
        _showSnackBar(sessionWorkspaceConflictMessage(session.id));
        return;
      }
      if (identical(existingTargetController, _controller)) return;
    }

    final approved = await showSessionWorkspaceReviewDialog(context, session);
    if (!approved || !mounted) return;

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

    await controller.resumeSession(
      session.id,
      cwd: session.cwd,
      additionalDirectories: session.additionalDirectories,
      title: session.title,
      updatedAt: session.updatedAt,
    );
    if (mounted) setState(() {});
  }

  ChatController? _existingControllerForAgentName(String? agentName) {
    final trimmed = agentName?.trim();
    if (trimmed == null ||
        trimmed.isEmpty ||
        trimmed == _controller.agentName.trim()) {
      return _controller;
    }
    return _controllersByAgent[trimmed];
  }

  bool _canForkSession(AgentSession session) {
    final controller = _controllerForSession(session);
    return controller.supportsSessionFork &&
        !controller.isStreaming &&
        !controller.isSessionOperationRunning;
  }

  Future<void> _handleSessionMenuAction(
    BuildContext context,
    AgentSession session,
    WorkspaceSessionMenuAction action,
  ) async {
    final controller = _controllerForSession(session);
    switch (action) {
      case WorkspaceSessionMenuAction.togglePinned:
        controller.setSessionPinned(session.id, !session.pinned);
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.rename:
        await _renameSession(context, controller, session);
      case WorkspaceSessionMenuAction.archive:
        final snapshot = controller.archiveSessionLocally(session.id);
        if (snapshot == null) return;
        _showUndoableSnackBar(
          'Archived "${session.displayTitle}".',
          <({ChatController controller, ArchivedSessionSnapshot snapshot})>[
            (controller: controller, snapshot: snapshot),
          ],
        );
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.toggleUnread:
        controller.setSessionUnread(session.id, !session.unread);
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.revealInFinder:
        await _revealPathInFinder(context, session.cwd, label: 'session');
      case WorkspaceSessionMenuAction.copyWorkingDirectory:
        await _copyToClipboard(session.cwd, label: 'Working directory');
      case WorkspaceSessionMenuAction.copySessionId:
        await _copyToClipboard(session.id, label: 'Session ID');
      case WorkspaceSessionMenuAction.copyDeepLink:
        await _copyToClipboard(
          _deepLinkForSession(session),
          label: 'Deep link',
        );
      case WorkspaceSessionMenuAction.forkLocally:
        await _forkSession(session);
      case WorkspaceSessionMenuAction.forkToNewWorktree:
        await _forkSessionToNewWorktree(context, session);
      case WorkspaceSessionMenuAction.openInNewWindow:
        await _openSessionInNewWindow(session);
    }
  }

  void _archiveWorkspaceSessions(WorkspaceRecord workspace) {
    final workspacePath = normalizeWorkspacePath(workspace.path);
    final archivedSnapshots =
        <({ChatController controller, ArchivedSessionSnapshot snapshot})>[];
    var archivedCount = 0;
    for (final controller in _sessionControllers) {
      for (final session in controller.sessions.toList(growable: false)) {
        if (normalizeWorkspacePath(session.cwd) != workspacePath) continue;
        if (session.archived) continue;
        final snapshot = controller.archiveSessionLocally(session.id);
        if (snapshot == null) continue;
        archivedSnapshots.add((controller: controller, snapshot: snapshot));
        archivedCount += 1;
      }
    }
    if (archivedCount > 0) {
      _showUndoableSnackBar(
        'Archived $archivedCount conversation(s).',
        archivedSnapshots,
      );
    }
    if (mounted) setState(() {});
  }

  ChatController _controllerForSession(AgentSession session) {
    final agentName = session.agentName?.trim();
    if (widget.controller == null &&
        agentName != null &&
        agentName.isNotEmpty) {
      final config = _configForAgent(_config, agentName);
      if (config != null) return _cachedControllerFor(config);
    }
    return _controller;
  }

  Future<void> _renameSession(
    BuildContext context,
    ChatController controller,
    AgentSession session,
  ) async {
    var draftTitle = session.displayTitle;
    final nextTitle = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename Conversation'),
          content: SizedBox(
            width: 340,
            child: TextFormField(
              initialValue: draftTitle,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Display name',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => draftTitle = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(draftTitle),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );
    final trimmed = nextTitle?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    controller.renameSession(session.id, trimmed);
    if (mounted) setState(() {});
  }

  Future<void> _forkSession(AgentSession session) async {
    if (!_canForkSession(session)) {
      _showSnackBar('This agent does not advertise session/fork.');
      return;
    }

    var controller = _controllerForSession(session);
    final agentName = session.agentName?.trim();
    if (widget.controller == null &&
        agentName != null &&
        agentName.isNotEmpty &&
        agentName != _config.agentName) {
      final config = _configForAgent(_config, agentName);
      if (config == null) {
        _showSnackBar('Could not select agent "$agentName".');
        return;
      }
      controller = _activateAgent(config);
    }

    await controller.forkSession(session);
    if (mounted) setState(() {});
  }

  Future<void> _forkSessionToNewWorktree(
    BuildContext context,
    AgentSession session,
  ) async {
    if (!_canForkSession(session)) {
      _showSnackBar('This agent does not advertise session/fork.');
      return;
    }

    final worktreePath = await _promptWorktreePath(context, session);
    if (worktreePath == null) return;

    try {
      final gitRoot = await _gitRootFor(session.cwd);
      final branchName = _worktreeBranchName(
        session.cwd,
        '${session.shortId}-fork',
      );
      final result = await Process.run('git', [
        '-C',
        gitRoot,
        'worktree',
        'add',
        '-b',
        branchName,
        worktreePath,
        'HEAD',
      ]);
      if (result.exitCode != 0) throw StateError(result.stderr.toString());

      await _forkSession(session.copyWith(cwd: worktreePath));
    } catch (error) {
      _showSnackBar('Could not fork to new worktree: $error');
    }
  }

  Future<void> _createWorkspaceWorktree(
    BuildContext context,
    WorkspaceRecord workspace,
  ) async {
    if (_controller.isStreaming || _controller.isSessionOperationRunning) {
      return;
    }

    final worktreePath = await _promptWorkspaceWorktreePath(context, workspace);
    if (worktreePath == null) return;

    try {
      final gitRoot = await _gitRootFor(workspace.path);
      final branchName = _worktreeBranchName(workspace.path, 'worktree');
      final result = await Process.run('git', [
        '-C',
        gitRoot,
        'worktree',
        'add',
        '-b',
        branchName,
        worktreePath,
        'HEAD',
      ]);
      if (result.exitCode != 0) throw StateError(result.stderr.toString());

      await _controller.newSession(cwd: worktreePath);
      _showSnackBar('Created worktree "$branchName".');
      if (mounted) setState(() {});
    } catch (error) {
      _showSnackBar('Could not create worktree: $error');
    }
  }

  Future<String?> _promptWorktreePath(
    BuildContext context,
    AgentSession session,
  ) async {
    var draftPath = _defaultWorktreePath(session);
    final nextPath = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Fork to New Worktree'),
          content: SizedBox(
            width: 440,
            child: TextFormField(
              initialValue: draftPath,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Worktree path',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => draftPath = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(draftPath),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    final trimmed = nextPath?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  Future<String?> _promptWorkspaceWorktreePath(
    BuildContext context,
    WorkspaceRecord workspace,
  ) async {
    var draftPath = _defaultWorkspaceWorktreePath(workspace);
    final nextPath = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create Permanent Worktree'),
          content: SizedBox(
            width: 440,
            child: TextFormField(
              initialValue: draftPath,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Worktree path',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) => draftPath = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(draftPath),
              child: const Text('Create'),
            ),
          ],
        );
      },
    );
    final trimmed = nextPath?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  String _defaultWorktreePath(AgentSession session) {
    final normalized = normalizeWorkspacePath(session.cwd);
    final directory = Directory(normalized);
    final parent = directory.parent.path;
    final workspaceName = workspaceNameFromPath(normalized);
    return _joinPath(parent, '$workspaceName-${session.shortId}-fork');
  }

  String _defaultWorkspaceWorktreePath(WorkspaceRecord workspace) {
    final normalized = normalizeWorkspacePath(workspace.path);
    final directory = Directory(normalized);
    final parent = directory.parent.path;
    final workspaceName = workspaceNameFromPath(normalized);
    return _joinPath(parent, '$workspaceName-worktree');
  }

  Future<String> _gitRootFor(String cwd) async {
    final result = await Process.run('git', [
      '-C',
      cwd,
      'rev-parse',
      '--show-toplevel',
    ]);
    if (result.exitCode != 0) {
      throw StateError(result.stderr.toString());
    }
    final root = result.stdout.toString().trim();
    if (root.isEmpty) throw StateError('No git root found for $cwd.');
    return root;
  }

  String _worktreeBranchName(String workspacePath, String suffix) {
    final workspaceName = workspaceNameFromPath(workspacePath)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    final prefix = workspaceName.isEmpty ? 'session' : workspaceName;
    return 'codex/$prefix-$suffix-${DateTime.now().millisecondsSinceEpoch}';
  }

  String _joinPath(String directory, String basename) {
    if (directory.endsWith(Platform.pathSeparator)) {
      return '$directory$basename';
    }
    return '$directory${Platform.pathSeparator}$basename';
  }

  Future<void> _revealPathInFinder(
    BuildContext context,
    String path, {
    required String label,
  }) async {
    try {
      final target = path.trim();
      if (target.isEmpty) return;
      await revealPathInFileManager(target);
    } catch (error) {
      if (!context.mounted) return;
      _showSnackBar('Could not reveal $label: $error');
    }
  }

  Future<void> _copyToClipboard(String text, {required String label}) async {
    await Clipboard.setData(ClipboardData(text: text));
    _showSnackBar('$label copied.');
  }

  String _deepLinkForSession(AgentSession session) {
    return Uri(
      scheme: 'ianvs-acp',
      host: 'session',
      queryParameters: <String, String>{
        'id': session.id,
        'cwd': session.cwd,
        if (session.agentName?.trim().isNotEmpty == true)
          'agent': session.agentName!.trim(),
      },
    ).toString();
  }

  Future<void> _openSessionInNewWindow(AgentSession session) async {
    final args = <String>[
      '--resume-session-id',
      session.id,
      '--resume-cwd',
      session.cwd,
      if (session.agentName?.trim().isNotEmpty == true) ...[
        '--resume-agent',
        session.agentName!.trim(),
      ],
    ];

    try {
      final injectedOpener = widget.openSessionWindow;
      if (injectedOpener != null) {
        await injectedOpener(List<String>.unmodifiable(args));
        return;
      }

      if (Platform.isMacOS) {
        final bundlePath = _macAppBundlePath(Platform.resolvedExecutable);
        if (bundlePath != null) {
          final result = await Process.run('open', [
            '-n',
            bundlePath,
            '--args',
            ...args,
          ]);
          if (result.exitCode != 0) throw StateError(result.stderr.toString());
          return;
        }
      }

      await Process.start(Platform.resolvedExecutable, args);
    } catch (error) {
      _showSnackBar('Could not open session in a new window: $error');
    }
  }

  String? _macAppBundlePath(String executablePath) {
    const marker = '.app/Contents/MacOS/';
    final index = executablePath.indexOf(marker);
    if (index == -1) return null;
    return executablePath.substring(0, index + '.app'.length);
  }

  ChatController _activateAgent(AcpClientConfig nextConfig) {
    final controller = _cachedControllerFor(nextConfig);
    _ensureControllersForSelectableAgents(nextConfig);
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

  void _showUndoableSnackBar(
    String message,
    List<({ChatController controller, ArchivedSessionSnapshot snapshot})>
    archivedSnapshots,
  ) {
    void discardSnapshots() {
      for (final archived in archivedSnapshots) {
        archived.snapshot.discard();
        _pendingUndoSnapshots.remove(archived.snapshot);
      }
    }

    if (!mounted) {
      discardSnapshots();
      return;
    }
    final messenger = _messengerKey.currentState;
    if (messenger == null) {
      discardSnapshots();
      return;
    }
    for (final archived in archivedSnapshots) {
      _pendingUndoSnapshots.add(archived.snapshot);
    }
    final featureController = messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () {
            for (final archived in archivedSnapshots) {
              archived.controller.restoreArchivedSessionLocally(
                archived.snapshot,
              );
            }
            if (mounted) setState(() {});
          },
        ),
      ),
    );
    unawaited(
      featureController.closed
          .whenComplete(discardSnapshots)
          .then<void>((_) {}),
    );
  }

  AcpAgentClient _defaultAgentClient(AcpClientConfig config) {
    final server = config.activeAgentServer;
    final mcpServers = config.mcpServers
        .map((server) => server.toRuntimeJson())
        .toList();
    if (server == null) {
      return const UnavailableAcpAgentClient(
        message: _noAgentConfiguredMessage,
      );
    }
    return DartAcpAgentClient(
      agentCommand: server.isStdio ? server.command : null,
      agentArgs: server.isStdio ? server.args : const <String>[],
      agentCwd: server.isStdio ? server.cwd : null,
      envOverrides: server.isStdio ? server.env : const <String, String>{},
      agentWebSocketUrl: server.isWebSocket
          ? parseAndValidateAcpEndpoint(
              server.url,
              allowedSchemes: const <String>{'ws', 'wss'},
            )
          : null,
      agentHttpUrl: server.isStreamableHttp
          ? parseAndValidateAcpEndpoint(
              server.url,
              allowedSchemes: const <String>{'http', 'https'},
            )
          : null,
      agentHeaders: server.headers,
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
      agentWebSocketUrl: server.isWebSocket
          ? parseAndValidateAcpEndpoint(
              server.url,
              allowedSchemes: const <String>{'ws', 'wss'},
            )
          : null,
      agentHttpUrl: server.isStreamableHttp
          ? parseAndValidateAcpEndpoint(
              server.url,
              allowedSchemes: const <String>{'http', 'https'},
            )
          : null,
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
          .map(_mcpServerSignature)
          .toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'configPath': config.configPath,
      'defaultAgentServerName': config.defaultAgentServerName,
      'runtimeSecretGeneration': config.runtimeSecretGeneration,
    });
  }

  String _controllerSignature(AcpClientConfig config) {
    return jsonEncode(<String, Object?>{
      'agentName': config.agentName,
      'activeAgentServer': _agentServerSignature(config.activeAgentServer),
      'mcpServers': config.mcpServers
          .map(_mcpServerSignature)
          .toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'runtimeSecretGeneration': config.runtimeSecretGeneration,
    });
  }

  Map<String, Object?>? _agentServerSignature(AgentServerConfig? server) {
    if (server == null) return null;
    return <String, Object?>{
      'name': server.name,
      ...server.toJson(),
      'runtimeSecretSignature': <String>[
        _runtimeSecretSignature(server.env),
        _runtimeSecretSignature(server.headers),
      ],
      'permissionReviewAgent': _reviewAgentSignature(
        server.permissionReviewAgent,
      ),
    };
  }

  Map<String, Object?> _mcpServerSignature(McpServerConfig server) {
    return <String, Object?>{
      ...server.toJson(),
      'runtimeSecretSignature': <String>[
        _runtimeSecretSignature(server.env),
        _runtimeSecretSignature(server.headers),
      ],
    };
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
      'mcpServer': config.mcpServer == null
          ? null
          : _mcpServerSignature(config.mcpServer!),
      'mcpServerName': config.mcpServerName,
      'toolName': config.toolName,
      'model': config.model,
      'timeoutMs': config.timeout.inMilliseconds,
    };
  }
}

final List<int> _runtimeSecretSignatureKey = List<int>.unmodifiable(
  List<int>.generate(32, (_) => math.Random.secure().nextInt(256)),
);

String _runtimeSecretSignature(Map<String, String> values) {
  final keys = values.keys.toList()..sort();
  final canonical = <List<String>>[
    for (final key in keys) <String>[key, values[key]!],
  ];
  return Hmac(
    sha256,
    _runtimeSecretSignatureKey,
  ).convert(utf8.encode(jsonEncode(canonical))).toString();
}
