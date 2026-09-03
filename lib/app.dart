import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'acp/acp_agent_client.dart';
import 'acp/assistant_agent_enhancer.dart';
import 'acp/acp_input_budget.dart';
import 'acp/acp_session_settings.dart';
import 'acp/agent_event.dart';
import 'acp/agent_session.dart';
import 'acp/rust_acp_agent_client.dart';
import 'acp/acp_permission_reviewer.dart';
import 'acp/session_scoped_agent_client.dart';
import 'acp/unavailable_acp_agent_client.dart';
import 'config/acp_agent_discovery.dart';
import 'config/acp_client_config.dart';
import 'config/acp_config_store.dart';
import 'config/assistant_agent_config.dart';
import 'config/macos_keychain_secret_store.dart';
import 'config/secret_store.dart';
import 'platform/file_manager.dart';
import 'startup/deep_link_request.dart';
import 'startup/startup_options.dart';
import 'storage/session_transcript_cache.dart';
import 'storage/app_state_path.dart';
import 'state/chat_controller.dart';
import 'state/workspace_controller.dart';
import 'ui/components/agent_discovery_dialog.dart';
import 'ui/components/bounded_image_preview.dart';
import 'ui/components/deep_link_confirmation_dialog.dart';
import 'ui/components/new_session_agent_dialog.dart';
import 'ui/components/session_workspace_review_dialog.dart';
import 'ui/components/workspace_sidebar.dart';
import 'ui/image_decode_budget.dart';
import 'ui/shell/app_shell.dart';
import 'ui/theme/app_theme.dart';
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
typedef DeepLinkWorkspaceValidator =
    Future<DeepLinkWorkspaceValidation> Function(String? path);

const String _noAgentConfiguredMessage =
    'Add an ACP agent before starting a session.';

String? _rustAcpSessionDatabasePath(String? configPath) {
  return resolveAppStateFilePath(
    fileName: 'acp_sessions.sqlite3',
    configPath: configPath,
  );
}

Map<String, Object?> _rustMcpServerProjection(McpServerConfig server) {
  final type = server.type;
  if (type == 'acp') {
    throw UnsupportedError(
      'Rust ACP runtime does not expose unstable MCP-over-ACP.',
    );
  }
  if (type == 'stdio') {
    return <String, Object?>{
      'type': 'stdio',
      'name': server.name,
      'command': server.command,
      'args': (server.raw['args'] as List? ?? const <Object?>[])
          .whereType<String>()
          .toList(growable: false),
      'environment': server.env,
    };
  }
  return <String, Object?>{
    'type': type,
    'name': server.name,
    'url': server.url,
    'headers': server.headers,
  };
}

class _PendingDeepLinkRequest {
  _PendingDeepLinkRequest({
    required this.key,
    required this.token,
    required this.request,
    required this.handlerEpoch,
  });

  final String key;
  final Object token;
  final DeepLinkRequest request;
  final int handlerEpoch;
  bool resumeStarted = false;
}

class AcpClientApp extends StatefulWidget {
  const AcpClientApp({
    super.key,
    this.controller,
    this.config = const AcpClientConfig(),
    this.startupError,
    this.onRetryStartup,
    this.discoverAgentServers,
    this.writeDiscoveredAgentServers,
    this.writeConfig,
    this.secretStore = const MacosKeychainSecretStore(),
    this.configurationWritable = true,
    this.initialResumeSessionId,
    this.initialResumeCwd,
    this.initialResumeAgentName,
    this.initialResumeSessionTemplateId,
    this.initialResumeSessionTemplateVersion,
    this.openSessionWindow,
    this.autoLoadWorkspaceSessions = true,
    this.createAgentClient,
    this.agentClientFactoryKey,
    this.workspaceStateStore,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder,
    this.gitWorkspaceDetector = workspaceSupportsGitWorktrees,
    this.processRunner,
    this.deepLinkWorkspaceValidator = validateDeepLinkWorkspace,
  });

  final ChatController? controller;
  final AcpClientConfig config;
  final String? startupError;
  final VoidCallback? onRetryStartup;
  final AgentServerDiscoverer? discoverAgentServers;
  final DiscoveredAgentServerWriter? writeDiscoveredAgentServers;
  final AcpConfigWriter? writeConfig;
  final SecretStore secretStore;
  final bool configurationWritable;
  final String? initialResumeSessionId;
  final String? initialResumeCwd;
  final String? initialResumeAgentName;
  final String? initialResumeSessionTemplateId;
  final int? initialResumeSessionTemplateVersion;
  final SessionWindowOpener? openSessionWindow;
  final bool autoLoadWorkspaceSessions;
  final AcpAgentClientFactory? createAgentClient;

  /// Change this key when [createAgentClient] changes behavior. Keep it stable
  /// across ordinary widget rebuilds.
  final Object? agentClientFactoryKey;

  final WorkspaceSidebarStateStore? workspaceStateStore;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder? boundedImageDecoder;
  final bool Function(String path) gitWorkspaceDetector;
  final AppShellProcessRunner? processRunner;
  final DeepLinkWorkspaceValidator deepLinkWorkspaceValidator;

  @override
  State<AcpClientApp> createState() => _AcpClientAppState();
}

class _AcpClientAppState extends State<AcpClientApp> {
  static const String _initialResumeSessionId = String.fromEnvironment(
    'ACP_RESUME_SESSION_ID',
  );
  static const MethodChannel _deepLinkChannel = MethodChannel(
    'ianvs_acp/deep_links',
  );
  static const int _maxDeepLinkConfirmations = 8;
  static const int _maxInFlightDeepLinks = 8;
  static Object? _deepLinkHandlerOwner;

  late AcpClientConfig _config;
  late String _widgetConfigSignature;
  late ChatController _controller;
  late AcpInputBudget _inputBudget;
  late AcpImageDecodeBudgetLedger _imageDecodeLedger;
  late BoundedImageDecoder _boundedImageDecoder;
  late final String _cwd;
  final Map<String, ChatController> _controllersByAgent =
      <String, ChatController>{};
  // A ChatController intentionally owns one mutable foreground timeline and
  // prompt subscription. Extra controllers keep simultaneously running
  // conversations isolated while the primary per-agent controllers continue
  // to own catalog loading and ordinary idle session switching.
  final List<ChatController> _supplementalControllers = <ChatController>[];
  final Map<String, String> _controllerSignaturesByAgent = <String, String>{};
  final Map<ChatController, String> _controllerRuntimeSignatures =
      <ChatController, String>{};
  final Map<ChatController, AcpClientConfig> _controllerRuntimeConfigs =
      <ChatController, AcpClientConfig>{};
  final Map<String, SessionScopedAgentClientPool> _clientPoolsByRuntime =
      <String, SessionScopedAgentClientPool>{};
  final Map<ChatController, VoidCallback> _sessionIndexListeners =
      <ChatController, VoidCallback>{};
  // Platform deep-link handlers can move between State instances while a
  // restore is still in flight. Keep token-guarded dedupe process-wide so a
  // replacement State cannot start the same external operation twice.
  static final Map<String, Object> _inFlightDeepLinks = <String, Object>{};
  final Queue<_PendingDeepLinkRequest> _pendingDeepLinkRequests =
      Queue<_PendingDeepLinkRequest>();
  _PendingDeepLinkRequest? _activeDeepLinkRequest;
  Object? _activeDeepLinkDrainToken;
  bool _deepLinkHandlerInstalled = false;
  bool _initialDeepLinksLoaded = false;
  final Object _deepLinkHandlerToken = Object();
  int _deepLinkHandlerEpoch = 0;
  Object? _activeDeepLinkDialogToken;
  Route<dynamic>? _activeDeepLinkDialogRoute;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();
  final Set<ArchivedSessionSnapshot> _pendingUndoSnapshots =
      HashSet<ArchivedSessionSnapshot>.identity();
  bool _agentDiscoveryStarted = false;
  bool _sessionIndexHydrated = false;
  Future<Object?>? _sessionIndexHydration;
  String? _sessionIndexHydrationError;
  bool _sessionIndexPersistScheduled = false;
  List<AgentSession> _unresolvedSessionIndex = const <AgentSession>[];
  int _sessionIndexHydrationSerial = 0;
  int _sessionCatalogLoadSerial = 0;
  Future<void>? _sessionCatalogLoad;
  bool _sessionSelectionInProgress = false;
  WorkspaceSessionIndexPersistenceQueue? _sessionIndexPersistence;
  WorkspaceSidebarStateStore? _ownedWorkspaceStateStore;
  String? _ownedWorkspaceStateStorePath;

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
    _config = _configWithInitialAgent(widget.config);
    _widgetConfigSignature = _configSignature(_config);
    _cwd = AcpClientConfig.resolveWorkspaceCwd(
      currentDirectory: Directory.current.path,
    );
    if (widget.controller == null) {
      _controller = _cachedControllerFor(_config);
      _ensureControllersForSelectableAgents(_config);
      _beginSessionIndexHydration();
    } else {
      _controller = widget.controller!;
    }
    final initialStartupOptions = _initialStartupOptions;
    if (initialStartupOptions.hasResumeSession) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_resumeFromStartupOptions(initialStartupOptions));
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

    final nextWidgetConfig = _configWithInitialAgent(widget.config);
    final nextConfigSignature = _configSignature(nextWidgetConfig);
    final configChanged = nextConfigSignature != _widgetConfigSignature;
    final controllerChanged = oldWidget.controller != widget.controller;
    final foregroundAgentFactoryChanged =
        oldWidget.agentClientFactoryKey != widget.agentClientFactoryKey ||
        (oldWidget.createAgentClient == null) !=
            (widget.createAgentClient == null);
    if (controllerChanged) {
      if (oldWidget.controller == null) {
        _teardownDeepLinkHandling();
        _disposeControllerList(_takeCachedControllers(clearClientPools: true));
      }
      _config = nextWidgetConfig;
      _widgetConfigSignature = nextConfigSignature;
      if (widget.controller == null) {
        _controller = _cachedControllerFor(_config);
        _ensureControllersForSelectableAgents(_config);
        _beginSessionIndexHydration();
      } else {
        _controller = widget.controller!;
      }
      if (widget.controller == null) _setupDeepLinkHandling();
      return;
    }

    if (!configChanged && foregroundAgentFactoryChanged) {
      if (foregroundAgentFactoryChanged && widget.controller == null) {
        _replaceOwnedControllerFactory();
      }
      if (mounted) setState(() {});
      return;
    }

    if (!configChanged) {
      if (widget.controller != null) _controller = widget.controller!;
      return;
    }

    if (widget.controller != null) {
      _config = nextWidgetConfig;
      _widgetConfigSignature = nextConfigSignature;
      _controller = widget.controller!;
      return;
    }

    _widgetConfigSignature = nextConfigSignature;
    _replaceOwnedControllerConfiguration(
      nextWidgetConfig,
      rebuild: false,
      clearClientPools: foregroundAgentFactoryChanged,
    );
  }

  StartupOptions get _initialStartupOptions {
    final runtime = widget.initialResumeSessionId?.trim();
    return StartupOptions(
      resumeSessionId: runtime != null && runtime.isNotEmpty
          ? runtime
          : _initialResumeSessionId,
      resumeCwd: _trimmedOrNull(widget.initialResumeCwd),
      resumeAgentName: _trimmedOrNull(widget.initialResumeAgentName),
      resumeSessionTemplateId: _trimmedOrNull(
        widget.initialResumeSessionTemplateId,
      ),
      resumeSessionTemplateVersion: widget.initialResumeSessionTemplateVersion,
    );
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
    _invalidateSessionCatalogLoad();
    for (final snapshot in _pendingUndoSnapshots.toList(growable: false)) {
      snapshot.discard();
    }
    _pendingUndoSnapshots.clear();
    _teardownDeepLinkHandling();
    if (widget.controller == null) {
      _disposeControllerList(_takeCachedControllers(clearClientPools: true));
    }
    super.dispose();
  }

  void _setupDeepLinkHandling() {
    if (widget.controller != null || _deepLinkHandlerInstalled) return;
    final handlerEpoch = ++_deepLinkHandlerEpoch;
    _deepLinkHandlerInstalled = true;
    _deepLinkHandlerOwner = _deepLinkHandlerToken;
    _deepLinkChannel.setMethodCallHandler((call) async {
      if (!_ownsDeepLinkHandler(handlerEpoch)) return null;
      if (call.method != 'openDeepLink') return null;
      final rawLink = call.arguments;
      if (rawLink is String) {
        unawaited(_handleDeepLink(rawLink, handlerEpoch));
      }
      return null;
    });
    if (!_initialDeepLinksLoaded) {
      _initialDeepLinksLoaded = true;
      unawaited(_loadInitialDeepLinks(handlerEpoch));
    }
  }

  void _teardownDeepLinkHandling() {
    if (!_deepLinkHandlerInstalled) return;
    _deepLinkHandlerInstalled = false;
    _deepLinkHandlerEpoch += 1;
    _activeDeepLinkDrainToken = null;
    while (_pendingDeepLinkRequests.isNotEmpty) {
      _releaseDeepLinkRequest(_pendingDeepLinkRequests.removeFirst());
    }
    final activeRequest = _activeDeepLinkRequest;
    if (activeRequest != null) {
      if (!activeRequest.resumeStarted) {
        _releaseDeepLinkRequest(activeRequest);
      }
      _activeDeepLinkRequest = null;
    }
    final activeDialogRoute = _activeDeepLinkDialogRoute;
    _activeDeepLinkDialogToken = null;
    _activeDeepLinkDialogRoute = null;
    if (activeDialogRoute != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = activeDialogRoute.navigator;
        if (navigator != null && activeDialogRoute.isActive) {
          navigator.removeRoute(activeDialogRoute, false);
        }
      });
    }
    if (identical(_deepLinkHandlerOwner, _deepLinkHandlerToken)) {
      _deepLinkHandlerOwner = null;
      _deepLinkChannel.setMethodCallHandler(null);
    }
  }

  bool _ownsDeepLinkHandler(int handlerEpoch) {
    return mounted &&
        _deepLinkHandlerInstalled &&
        widget.controller == null &&
        _deepLinkHandlerEpoch == handlerEpoch &&
        identical(_deepLinkHandlerOwner, _deepLinkHandlerToken);
  }

  Future<void> _loadInitialDeepLinks(int handlerEpoch) async {
    try {
      final rawLinks = await _deepLinkChannel.invokeMethod<List<Object?>>(
        'getInitialDeepLinks',
      );
      if (!_ownsDeepLinkHandler(handlerEpoch)) return;
      if (rawLinks == null) return;
      for (final rawLink in rawLinks) {
        if (!_ownsDeepLinkHandler(handlerEpoch)) return;
        if (rawLink is String) {
          await _handleDeepLink(rawLink, handlerEpoch);
          if (!_ownsDeepLinkHandler(handlerEpoch)) return;
        }
      }
    } on MissingPluginException catch (_) {
      return;
    } on PlatformException catch (_) {
      return;
    }
  }

  Future<void> _handleDeepLink(String rawLink, int handlerEpoch) async {
    if (!_ownsDeepLinkHandler(handlerEpoch)) return;
    final normalizedLink = rawLink.trim();
    if (normalizedLink.isEmpty) return;
    final request = StartupOptions.fromDeepLink(normalizedLink);
    if (request == null) return;
    if (!request.requiresConfirmation) return;

    final key = _deepLinkRequestKey(request);
    if (_inFlightDeepLinks.containsKey(key)) return;
    if (_inFlightDeepLinks.length >= _maxInFlightDeepLinks) return;
    final requestToken = Object();
    _inFlightDeepLinks[key] = requestToken;

    final confirmationCount =
        _pendingDeepLinkRequests.length +
        (_activeDeepLinkDrainToken == null ? 0 : 1);
    if (confirmationCount >= _maxDeepLinkConfirmations) {
      if (identical(_inFlightDeepLinks[key], requestToken)) {
        _inFlightDeepLinks.remove(key);
      }
      return;
    }
    _pendingDeepLinkRequests.add(
      _PendingDeepLinkRequest(
        key: key,
        token: requestToken,
        request: request,
        handlerEpoch: handlerEpoch,
      ),
    );
    unawaited(_drainDeepLinkConfirmationQueue());
  }

  String _deepLinkRequestKey(DeepLinkRequest request) {
    final canonical = jsonEncode(<Object?>[
      'session',
      request.sessionId,
      request.cwd,
      request.agentName,
      request.sessionTemplateId,
      request.sessionTemplateVersion?.toString(),
      request.validationErrors,
    ]);
    return sha256.convert(utf8.encode(canonical)).toString();
  }

  void _releaseDeepLinkRequest(_PendingDeepLinkRequest pending) {
    if (identical(_inFlightDeepLinks[pending.key], pending.token)) {
      _inFlightDeepLinks.remove(pending.key);
    }
  }

  Future<void> _drainDeepLinkConfirmationQueue() async {
    if (_activeDeepLinkDrainToken != null ||
        !_ownsDeepLinkHandler(_deepLinkHandlerEpoch)) {
      return;
    }
    if (_navigatorKey.currentContext == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_drainDeepLinkConfirmationQueue());
      });
      return;
    }

    final drainToken = Object();
    _activeDeepLinkDrainToken = drainToken;
    try {
      while (_pendingDeepLinkRequests.isNotEmpty &&
          identical(_activeDeepLinkDrainToken, drainToken) &&
          _ownsDeepLinkHandler(_deepLinkHandlerEpoch)) {
        final pending = _pendingDeepLinkRequests.removeFirst();
        _activeDeepLinkRequest = pending;
        try {
          if (!_ownsDeepLinkHandler(pending.handlerEpoch)) continue;
          final dialogContext = _navigatorKey.currentContext;
          if (dialogContext == null || !dialogContext.mounted) return;
          final confirmationToken = Object();
          final confirmed = await showDialog<bool>(
            context: dialogContext,
            barrierDismissible: false,
            builder: (context) {
              _activeDeepLinkDialogToken = confirmationToken;
              _activeDeepLinkDialogRoute = ModalRoute.of(context);
              return DeepLinkConfirmationDialog(request: pending.request);
            },
          );
          if (identical(_activeDeepLinkDialogToken, confirmationToken)) {
            _activeDeepLinkDialogToken = null;
            _activeDeepLinkDialogRoute = null;
          }
          if (!_ownsDeepLinkHandler(pending.handlerEpoch)) return;
          if (confirmed != true) continue;
          final request = pending.request;
          DeepLinkWorkspaceValidation workspace;
          try {
            workspace = await widget.deepLinkWorkspaceValidator(request.cwd);
          } on Object catch (error) {
            if (!_ownsDeepLinkHandler(pending.handlerEpoch)) return;
            _showSnackBar('Could not open external session: $error');
            continue;
          }
          if (!_ownsDeepLinkHandler(pending.handlerEpoch)) return;
          if (workspace.errors.isNotEmpty) {
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
                resumeSessionTemplateId: request.sessionTemplateId,
                resumeSessionTemplateVersion: request.sessionTemplateVersion,
              ),
              trustExplicitTemplate: false,
              isCurrentRequest: () =>
                  _ownsDeepLinkHandler(pending.handlerEpoch) &&
                  identical(_activeDeepLinkDrainToken, drainToken) &&
                  identical(_activeDeepLinkRequest, pending),
              onResumeStarted: () => pending.resumeStarted = true,
            );
          } on Object catch (error) {
            if (_ownsDeepLinkHandler(pending.handlerEpoch)) {
              _showSnackBar('Could not open external session: $error');
            }
          }
        } finally {
          _releaseDeepLinkRequest(pending);
          if (identical(_activeDeepLinkRequest, pending)) {
            _activeDeepLinkRequest = null;
          }
        }
      }
    } finally {
      if (identical(_activeDeepLinkDrainToken, drainToken)) {
        _activeDeepLinkDrainToken = null;
        if (_pendingDeepLinkRequests.isNotEmpty &&
            _ownsDeepLinkHandler(_deepLinkHandlerEpoch)) {
          unawaited(_drainDeepLinkConfirmationQueue());
        }
      }
    }
  }

  Future<bool> _resumeFromStartupOptions(
    StartupOptions options, {
    bool trustExplicitTemplate = true,
    bool Function()? isCurrentRequest,
    VoidCallback? onResumeStarted,
  }) async {
    final sessionId = _trimmedOrNull(options.resumeSessionId);
    if (sessionId == null || !mounted) return false;
    if (widget.controller == null && !await _awaitSessionIndexHydration()) {
      return false;
    }
    if (!mounted || isCurrentRequest?.call() == false) return false;

    var config = _config;
    final agentName = _trimmedOrNull(options.resumeAgentName);
    if (widget.controller == null && agentName != null) {
      final selectedConfig = _configForAgent(_config, agentName);
      if (selectedConfig == null) {
        _showSnackBar('Could not select agent "$agentName".');
        return false;
      }
      config = selectedConfig;
    }

    final explicitCwd = _trimmedOrNull(options.resumeCwd);
    final knownSession = _knownSessionForResume(
      sessionId,
      config,
      cwd: explicitCwd,
    );
    final explicitTemplateId = _trimmedOrNull(options.resumeSessionTemplateId);
    final explicitTemplateVersion = options.resumeSessionTemplateVersion;
    if (!trustExplicitTemplate &&
        (explicitTemplateId != null || explicitTemplateVersion != null)) {
      final markerMatchesIndex =
          knownSession != null &&
          explicitTemplateId != null &&
          explicitTemplateVersion != null &&
          knownSession.sessionTemplateId?.trim() == explicitTemplateId &&
          knownSession.sessionTemplateVersion == explicitTemplateVersion;
      if (!markerMatchesIndex) {
        _showSnackBar(
          'Could not open external session: the template does not match the local session index.',
        );
        return false;
      }
    }
    final hasCompleteExplicitTemplate =
        explicitTemplateId != null && explicitTemplateVersion != null;
    final selectedTemplateId =
        trustExplicitTemplate && hasCompleteExplicitTemplate
        ? explicitTemplateId
        : knownSession?.sessionTemplateId;
    final selectedTemplateVersion =
        trustExplicitTemplate && hasCompleteExplicitTemplate
        ? explicitTemplateVersion
        : knownSession?.sessionTemplateVersion;
    var targetSession =
        knownSession?.copyWith(
          cwd: explicitCwd ?? knownSession.cwd,
          sessionTemplateId: selectedTemplateId,
          sessionTemplateVersion: selectedTemplateVersion,
        ) ??
        AgentSession(
          id: sessionId,
          cwd: explicitCwd ?? _controller.cwd,
          createdAt: DateTime.now(),
          additionalDirectories: config.additionalDirectories,
          agentName:
              config.activeAgentServer?.persistenceIdentity ?? config.agentName,
          sessionTemplateId: selectedTemplateId,
          sessionTemplateVersion: selectedTemplateVersion,
        );
    if (widget.controller == null) {
      config = _configForSessionIndex(targetSession) ?? config;
    }
    if (knownSession == null &&
        selectedTemplateId != null &&
        selectedTemplateVersion != null) {
      targetSession = targetSession.copyWith(
        additionalDirectories: config.additionalDirectories,
      );
    }

    final activeController = _controllerWithCurrentSession(
      targetSession,
      config: config,
    );
    if (activeController != null) {
      if (_blockedByBusyLegacyRuntime(config, target: activeController)) {
        _showSnackBar(
          'Wait for the current response before opening this session.',
        );
        return false;
      }
      _activateController(config, activeController);
      return true;
    }
    if (_hasBoundSessionWorkspaceConflict(targetSession, config)) {
      _showSnackBar(sessionWorkspaceConflictMessage(sessionId));
      return false;
    }

    final localController = _controllerWithLocalSessionState(
      targetSession,
      config,
    );
    if (localController != null &&
        _blockedByBusyLegacyRuntime(config, target: localController)) {
      _showSnackBar(
        'Wait for the current response before opening this session.',
      );
      return false;
    }
    final controller =
        localController ??
        (widget.controller == null
            ? _availableControllerFor(config)
            : _controller);
    if (controller == null) {
      _showSnackBar(
        'Wait for the current response before opening this session.',
      );
      return false;
    }
    if (explicitTemplateId != null && explicitTemplateVersion != null) {
      controller.mergeSessionIndex(<AgentSession>[targetSession]);
    }
    _activateController(config, controller);
    onResumeStarted?.call();
    await controller.resumeSession(
      sessionId,
      cwd: targetSession.cwd,
      additionalDirectories: targetSession.additionalDirectories,
      title: targetSession.title,
      updatedAt: targetSession.updatedAt,
    );
    if (!mounted || isCurrentRequest?.call() == false) return false;
    setState(() {});
    final resumed = controller.currentSession;
    final succeeded =
        resumed != null &&
        resumed.id.trim() == sessionId &&
        normalizeWorkspacePath(resumed.cwd) ==
            normalizeWorkspacePath(targetSession.cwd);
    if (!succeeded) {
      _showSnackBar(
        controller.lastError ?? 'Could not open session "$sessionId".',
      );
    }
    return succeeded;
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
      theme: AppTheme.light,
      home: AppShell(
        inputBudget: _inputBudget,
        imageDecodeLedger: _imageDecodeLedger,
        boundedImageDecoder: _boundedImageDecoder,
        gitWorkspaceDetector: widget.gitWorkspaceDetector,
        processRunner: widget.processRunner,
        controller: _controller,
        agentName: _config.agentName,
        agentServers: _config.selectableAgentServers,
        mcpServers: _config.mcpServers,
        additionalDirectories: _config.additionalDirectories,
        clientProviders: _clientProviderConfig(_config),
        storage: _config.storage,
        assistantAgent: _config.assistantAgent,
        sessionTemplates: _config.sessionTemplates,
        defaultSessionTemplateId: _config.defaultSessionTemplateId,
        runtimeConfig: _controllerRuntimeConfigs[_controller] ?? _config,
        configPath: _config.configPath,
        workspaceStateStore: _workspaceStateStore,
        defaultAgentName: _config.defaultAgentServerName,
        startupError: _combinedStartupError,
        onRetryStartup: widget.onRetryStartup,
        canSwitchAgent: widget.controller == null,
        autoLoadWorkspaceSessions: _canAutoLoadWorkspaceSessions,
        onLoadSessionCatalogs: widget.controller == null
            ? _loadAllAgentSessionCatalogs
            : null,
        sessionControllers: _sessionControllers,
        supportsConcurrentSessions:
            widget.controller == null &&
            _controller.client.supportsConcurrentPrompts,
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
        onValidateAssistantAgent: _validateAssistantAgent,
        onLoadAssistantAgentModels: _loadAssistantAgentModels,
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
      if (_sessionIndexHydrationError case final error?
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
    return _controllerForClient(config, _acquireAgentClient(config));
  }

  AcpAgentClient _acquireAgentClient(AcpClientConfig config) {
    _clientPoolsByRuntime.removeWhere((_, pool) => pool.isClosed);
    final agentName = config.agentName.trim();
    final signature = _agentClientRuntimeSignature(config);
    final runtimeIdentity =
        config.activeAgentServer?.persistenceIdentity ?? agentName;
    final runtimeKey = jsonEncode(<String>[runtimeIdentity, signature]);
    var pool = _clientPoolsByRuntime[runtimeKey];
    if (pool == null || pool.isClosed) {
      final createAgentClient = widget.createAgentClient ?? _defaultAgentClient;
      pool = SessionScopedAgentClientPool(createAgentClient(config));
      _clientPoolsByRuntime[runtimeKey] = pool;
    }
    return pool.acquire();
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
      sessionPersistenceIdentity:
          config.activeAgentServer?.persistenceIdentity ?? config.agentName,
      sessionCatalogSourceKey: _sessionCatalogSourceKeyForConfig(config),
      permissionTrustRules: permissions.trustRules,
      permissionReviewer: _permissionReviewer(config),
      assistantAgentConfig: config.assistantAgent,
      assistantAgentEnhancer: _assistantAgentEnhancer(config),
      enableAutomaticSessionTitles: true,
      sessionTranscriptCache: _sessionTranscriptCache(config),
    );
  }

  SessionTranscriptCache? _sessionTranscriptCache(AcpClientConfig config) {
    final directoryPath = resolveSessionTranscriptCacheDirectoryPath(
      config.configPath,
    );
    if (directoryPath == null) return null;
    return FileSessionTranscriptCache(
      directoryPath: directoryPath,
      maxDirectoryBytes: config.storage.maxBytes,
      retention: config.storage.retention,
    );
  }

  AssistantAgentEnhancer? _assistantAgentEnhancer(AcpClientConfig config) {
    final assistant = config.assistantAgent;
    if (!assistant.isConfigured) return null;
    final agentName = assistant.agentName;
    if (agentName == null) return null;
    try {
      final helperConfig = config.withActiveAgentServer(agentName);
      final helperClient =
          widget.createAgentClient?.call(helperConfig) ??
          _defaultAgentClient(helperConfig, restrictedAssistant: true);
      return AcpAssistantAgentEnhancer(helperClient, _cwd, config: assistant);
    } on Object {
      return null;
    }
  }

  Future<void> _validateAssistantAgent(AssistantAgentConfig assistant) async {
    final agentName = assistant.agentName?.trim();
    if (!assistant.enabled || agentName == null || agentName.isEmpty) {
      throw StateError('Choose and enable an Assistant Agent.');
    }
    final helperConfig = _config.withActiveAgentServer(agentName);
    final helperClient =
        widget.createAgentClient?.call(helperConfig) ??
        _defaultAgentClient(helperConfig, restrictedAssistant: true);
    final enhancer = AcpAssistantAgentEnhancer(
      helperClient,
      _cwd,
      config: assistant,
    );
    try {
      await enhancer.validate().timeout(assistant.timeout);
    } finally {
      await enhancer.dispose();
    }
  }

  Future<AcpConfigOption?> _loadAssistantAgentModels(String agentName) async {
    final normalizedAgentName = agentName.trim();
    if (normalizedAgentName.isEmpty) {
      throw StateError('Choose an Assistant Agent before loading models.');
    }
    final assistant = _config.assistantAgent.copyWith(
      enabled: true,
      agentName: normalizedAgentName,
      clearModel: true,
    );
    final helperConfig = _config.withActiveAgentServer(normalizedAgentName);
    final helperClient =
        widget.createAgentClient?.call(helperConfig) ??
        _defaultAgentClient(helperConfig, restrictedAssistant: true);
    final enhancer = AcpAssistantAgentEnhancer(
      helperClient,
      _cwd,
      config: assistant,
    );
    try {
      return await enhancer.discoverModelOption().timeout(assistant.timeout);
    } finally {
      await enhancer.dispose();
    }
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
      _controllerRuntimeSignatures[existing] = signature;
      _controllerRuntimeConfigs[existing] = config;
      return existing;
    }

    if (existing != null) {
      _detachSessionIndexPersistence(existing);
      _controllerRuntimeSignatures.remove(existing);
      _controllerRuntimeConfigs.remove(existing);
      existing.dispose();
    }
    final controller = _controllerFor(config);
    _controllersByAgent[agentName] = controller;
    _controllerSignaturesByAgent[agentName] = signature;
    _controllerRuntimeSignatures[controller] = signature;
    _controllerRuntimeConfigs[controller] = config;
    _attachSessionIndexPersistence(controller);
    return controller;
  }

  ChatController _createSupplementalController(AcpClientConfig config) {
    final controller = _controllerFor(config);
    _supplementalControllers.add(controller);
    _controllerRuntimeSignatures[controller] = _controllerSignature(config);
    _controllerRuntimeConfigs[controller] = config;
    _attachSessionIndexPersistence(controller);
    return controller;
  }

  ChatController? _idleControllerFor(AcpClientConfig config) {
    final agentName = config.agentName.trim();
    final signature = _controllerSignature(config);
    final candidates = <ChatController>[
      if (_controller.agentName.trim() == agentName) _controller,
      ?_controllersByAgent[agentName],
      ..._supplementalControllers.where(
        (controller) => controller.agentName.trim() == agentName,
      ),
    ];
    final seen = <ChatController>{};
    for (final controller in candidates) {
      if (!seen.add(controller) ||
          _controllerRuntimeSignatures[controller] != signature ||
          controller.isStreaming ||
          controller.isSessionOperationRunning) {
        continue;
      }
      return controller;
    }
    return null;
  }

  ChatController? _availableControllerFor(AcpClientConfig config) {
    if (_blockedByBusyLegacyRuntime(config)) {
      return null;
    }
    final idle = _idleControllerFor(config);
    if (idle != null) return idle;
    final primary = _controllersByAgent[config.agentName.trim()];
    if (primary != null &&
        _controllerRuntimeSignatures[primary] == _controllerSignature(config) &&
        primary.client.supportsConcurrentPrompts != true) {
      return null;
    }
    return _createSupplementalController(config);
  }

  bool _blockedByBusyLegacyRuntime(
    AcpClientConfig config, {
    ChatController? target,
  }) {
    final agentName = config.agentName.trim();
    return _sessionControllers.any(
      (controller) =>
          !identical(controller, target) &&
          controller.agentName.trim() == agentName &&
          (controller.isStreaming || controller.isSessionOperationRunning) &&
          controller.client.supportsConcurrentPrompts != true,
    );
  }

  ChatController _controllerForIndexedConfig(AcpClientConfig config) {
    final base = _configForAgent(_config, config.agentName);
    if (base != null &&
        _controllerSignature(base) == _controllerSignature(config)) {
      return _cachedControllerFor(base);
    }
    return _idleControllerFor(config) ?? _createSupplementalController(config);
  }

  void _replaceOwnedControllerConfiguration(
    AcpClientConfig nextConfig, {
    bool rebuild = true,
    bool clearClientPools = false,
  }) {
    final staleControllers = _takeCachedControllers(
      clearClientPools: clearClientPools,
    );
    _config = nextConfig;
    _controller = _cachedControllerFor(nextConfig);
    _ensureControllersForSelectableAgents(nextConfig);
    _beginSessionIndexHydration();
    _disposeControllerList(staleControllers);
    if (rebuild && mounted) setState(() {});
  }

  void _replaceOwnedControllerFactory() {
    final staleControllers = _takeCachedControllers(clearClientPools: true);
    _controller = _cachedControllerFor(_config);
    _ensureControllersForSelectableAgents(_config);
    _beginSessionIndexHydration();
    _disposeControllerList(staleControllers);
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

  List<ChatController> _takeCachedControllers({bool clearClientPools = false}) {
    final controllers = <ChatController>{
      ..._controllersByAgent.values,
      ..._supplementalControllers,
    }.toList(growable: false);
    for (final controller in controllers) {
      _detachSessionIndexPersistence(controller);
    }
    _controllersByAgent.clear();
    _supplementalControllers.clear();
    _controllerSignaturesByAgent.clear();
    _controllerRuntimeSignatures.clear();
    _controllerRuntimeConfigs.clear();
    // Configuration-only replacement deliberately keeps exact-recipe pools:
    // replacement controllers acquire a lease before stale controllers release
    // theirs, so one recipe never has overlapping authoritative runtimes.
    if (clearClientPools) _clientPoolsByRuntime.clear();
    return controllers;
  }

  void _disposeControllerList(Iterable<ChatController> controllers) {
    for (final controller in controllers) {
      controller.dispose();
    }
  }

  Future<void> _hydrateSessionIndex() async {
    if (widget.controller != null) return;
    _invalidateSessionCatalogLoad();
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
    final unresolvedSessions = <AgentSession>[];
    for (final session in sessions) {
      final config = _configForSessionIndex(session);
      if (config == null) {
        unresolvedSessions.add(session);
        continue;
      }
      _controllerForIndexedConfig(config).mergeSessionIndex([
        _sessionIndexWithFallbackAgent(session, config.agentName),
      ]);
    }
    _unresolvedSessionIndex = List<AgentSession>.unmodifiable(
      unresolvedSessions,
    );

    _sessionIndexHydrated = true;
    _schedulePersistSessionIndex();
    if (mounted) setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || serial != _sessionIndexHydrationSerial) return;
      unawaited(_loadAllAgentSessionCatalogs().catchError((_) {}));
    });
  }

  void _beginSessionIndexHydration() {
    _sessionIndexHydrationError = null;
    final hydration = _hydrateSessionIndex().then<Object?>(
      (_) => null,
      onError: (Object error, StackTrace _) => error,
    );
    _sessionIndexHydration = hydration;
    unawaited(
      hydration.then((error) {
        if (!mounted ||
            !identical(hydration, _sessionIndexHydration) ||
            error == null) {
          return;
        }
        _sessionIndexHydrationError =
            'Could not load the local session index: $error';
        setState(() {});
      }),
    );
  }

  Future<bool> _awaitSessionIndexHydration() async {
    while (mounted && widget.controller == null) {
      final hydration = _sessionIndexHydration;
      if (hydration == null) return true;
      final error = await hydration;
      if (!identical(hydration, _sessionIndexHydration)) continue;
      if (error != null) {
        if (mounted) {
          _showSnackBar('Could not load the local session index: $error');
        }
        return false;
      }
      return true;
    }
    return mounted;
  }

  Future<void> _loadAllAgentSessionCatalogs() {
    final activeLoad = _sessionCatalogLoad;
    if (activeLoad != null) return activeLoad;
    final serial = ++_sessionCatalogLoadSerial;
    late final Future<void> trackedLoad;
    trackedLoad = () async {
      try {
        await _performAgentSessionCatalogLoad(serial);
      } finally {
        if (identical(_sessionCatalogLoad, trackedLoad)) {
          _sessionCatalogLoad = null;
        }
      }
    }();
    _sessionCatalogLoad = trackedLoad;
    return trackedLoad;
  }

  Future<void> _performAgentSessionCatalogLoad(int serial) async {
    if (widget.controller != null || !_canAutoLoadWorkspaceSessions) return;
    _ensureControllersForSelectableAgents(_config);
    final controllers = <ChatController>[
      _controller,
      for (final controller in _controllersByAgent.values)
        if (!identical(controller, _controller)) controller,
    ];
    final seenCatalogSources = <String>{};
    final errors = <Object>[];
    var attemptedLoads = 0;

    for (final controller in controllers) {
      if (serial != _sessionCatalogLoadSerial) return;
      if (controller.isStreaming || controller.isSessionOperationRunning) {
        continue;
      }
      if (!controller.canListSessions) continue;
      if (widget.createAgentClient == null &&
          !seenCatalogSources.add(_sessionCatalogSourceKey(controller))) {
        continue;
      }

      attemptedLoads += 1;
      try {
        await controller.loadSessionCatalog();
      } catch (error) {
        // One agent may not support session/list or may be offline; keep
        // loading the rest so workspace aggregation remains best-effort.
        errors.add(error);
      }
    }
    if (!mounted || serial != _sessionCatalogLoadSerial) return;
    _schedulePersistSessionIndex();
    setState(() {});
    if (attemptedLoads > 0 && errors.length == attemptedLoads) {
      throw errors.first;
    }
  }

  void _invalidateSessionCatalogLoad() {
    _sessionCatalogLoadSerial += 1;
    _sessionCatalogLoad = null;
  }

  String _sessionCatalogSourceKey(ChatController controller) {
    final config = _configForAgent(_config, controller.agentName);
    if (config != null) return _sessionCatalogSourceKeyForConfig(config);
    return 'controller:${identityHashCode(controller)}';
  }

  String _sessionCatalogSourceKeyForConfig(AcpClientConfig config) {
    final server = config.activeAgentServer;
    if (server == null) return 'agent:${config.agentName}';
    return jsonEncode(<String, Object?>{
      'type': server.type,
      'command': server.command,
      'cwd': server.cwd,
      'url': server.url,
      'args': server.args,
      'env': _runtimeSecretSignature(server.env),
      'headers': _runtimeSecretSignature(server.headers),
    });
  }

  AcpClientConfig? _configForSessionIndex(AgentSession session) {
    final agentConfig = _config.configForSessionIndexAgent(session.agentName);
    if (agentConfig == null) return null;
    final template = _sessionTemplateForIndex(session, agentConfig);
    if (template == null) return agentConfig;
    try {
      return agentConfig.forSessionTemplate(template);
    } on FormatException {
      return agentConfig;
    }
  }

  SessionTemplateConfig? _sessionTemplateForIndex(
    AgentSession session,
    AcpClientConfig agentConfig,
  ) {
    final templateId = session.sessionTemplateId?.trim();
    if (templateId == null || templateId.isEmpty) return null;
    final template = _config.sessionTemplateNamed(templateId);
    if (template == null ||
        session.sessionTemplateVersion != template.version) {
      return null;
    }
    try {
      final runtime = agentConfig.forSessionTemplate(template);
      final persistedAgent =
          agentConfig.activeAgentServer?.persistenceIdentity ??
          agentConfig.agentName;
      final templateAgent =
          runtime.activeAgentServer?.persistenceIdentity ?? runtime.agentName;
      return persistedAgent == templateAgent ? template : null;
    } on FormatException {
      return null;
    }
  }

  AgentSession _sessionIndexWithFallbackAgent(
    AgentSession session,
    String agentName,
  ) {
    final existingAgentName = session.agentName?.trim();
    if (existingAgentName == agentName) {
      return session;
    }
    return session.copyWith(agentName: agentName);
  }

  WorkspaceSidebarStateStore get _workspaceStateStore {
    final injected = widget.workspaceStateStore;
    if (injected != null) return injected;

    final configPath = _config.configPath?.trim();
    // An in-memory/programmatic config has no stable persistence identity.
    // Keeping its sidebar index in memory also prevents unrelated ephemeral
    // app instances from sharing the user's default on-disk state.
    final path = configPath == null || configPath.isEmpty
        ? null
        : WorkspaceSidebarStateStore.defaultPath(configPath: configPath);
    final cached = _ownedWorkspaceStateStore;
    if (cached != null && _ownedWorkspaceStateStorePath == path) return cached;
    final store = WorkspaceSidebarStateStore(path: path);
    _ownedWorkspaceStateStorePath = path;
    _ownedWorkspaceStateStore = store;
    return store;
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
    for (final session in _unresolvedSessionIndex) {
      final id = session.id.trim();
      final cwd = session.cwd.trim();
      final persistenceIdentity = session.agentName?.trim() ?? '';
      if (id.isEmpty || cwd.isEmpty) continue;
      sessionsByKey['$cwd\u0000$persistenceIdentity\u0000$id'] = session;
    }
    final workspaceController = WorkspaceController(
      controllers: _sessionControllers,
      currentWorkspacePath: _cwd,
      defaultAgentName: _config.defaultAgentServerName ?? _config.agentName,
      includeArchived: true,
    );
    for (final workspace in workspaceController.workspaces) {
      for (final session in workspace.sessions) {
        final id = session.id.trim();
        final cwd = session.cwd.trim();
        if (id.isEmpty || cwd.isEmpty) continue;
        final agentName = session.agentName?.trim() ?? _config.agentName;
        final sessionConfig = _config.configForSessionIndexAgent(agentName);
        final persistenceIdentity =
            sessionConfig?.activeAgentServer?.persistenceIdentity ?? agentName;
        final normalized = _sessionIndexWithFallbackAgent(
          session,
          persistenceIdentity,
        );
        sessionsByKey['$cwd\u0000$persistenceIdentity\u0000$id'] = normalized;
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
              'sessionTemplateId': session.sessionTemplateId,
              'sessionTemplateVersion': session.sessionTemplateVersion,
              'additionalDirectories': session.additionalDirectories,
              'pinned': session.pinned,
              'archived': session.archived,
              'unread': session.unread,
              'localUnstarted': session.localUnstarted,
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
    if (_controller.isSessionOperationRunning ||
        (widget.controller != null && _controller.isStreaming)) {
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
        sessionTemplates: widget.controller == null
            ? _config.sessionTemplates
            : const <SessionTemplateConfig>[],
        defaultSessionTemplateId: _config.defaultSessionTemplateId,
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

    final template = selection.sessionTemplate;
    if (template != null) {
      late final AcpClientConfig templateConfig;
      try {
        templateConfig = _config.forSessionTemplate(template);
      } catch (error) {
        _showSnackBar('Could not resolve session template: $error');
        return;
      }
      final controller = _availableControllerFor(templateConfig);
      if (controller == null) {
        _showSnackBar(
          'Wait for the current response before starting this template.',
        );
        return;
      }
      _activateController(
        _config.withActiveAgentServer(templateConfig.agentName),
        controller,
      );
      final created = await controller.newSession(
        cwd: selection.cwd,
        template: template,
      );
      if (created && controller.sessionTemplateWarnings.isNotEmpty) {
        _showSnackBar(controller.sessionTemplateWarnings.join(' '));
      }
      if (mounted) setState(() {});
      return;
    }

    final selected = selection.agentServer;
    if (selected == null) {
      final controller = _availableControllerFor(_config);
      if (controller == null) {
        _showSnackBar(
          'Wait for the current response before starting a session.',
        );
        return;
      }
      _activateController(_config, controller);
      await controller.newSession(cwd: selection.cwd);
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

    final controller = _availableControllerFor(nextConfig);
    if (controller == null) {
      _showSnackBar('Wait for the current response before starting a session.');
      return;
    }
    _activateController(nextConfig, controller);
    await controller.newSession(cwd: selection.cwd);
    if (mounted) setState(() {});
  }

  Future<void> _selectSession(AgentSession session) async {
    if (_sessionSelectionInProgress) {
      _showSnackBar('A session switch is already in progress.');
      return;
    }

    _sessionSelectionInProgress = true;
    try {
      await _selectSessionOnce(session);
    } finally {
      _sessionSelectionInProgress = false;
    }
  }

  Future<void> _selectSessionOnce(AgentSession session) async {
    if (!mounted) return;
    final sessionConfig = widget.controller == null
        ? _configForSessionIndex(session)
        : _config;
    if (sessionConfig == null) {
      _showSnackBar(
        'Could not select the agent for "${session.displayTitle}".',
      );
      return;
    }

    final activeTargetController = _controllerWithCurrentSession(
      session,
      config: sessionConfig,
    );
    if (activeTargetController != null) {
      if (_blockedByBusyLegacyRuntime(
        sessionConfig,
        target: activeTargetController,
      )) {
        _showSnackBar(
          'Wait for the current response before switching sessions.',
        );
        return;
      }
      _restoreSessionAcrossCatalogAliases(
        session,
        preferred: activeTargetController,
      );
      _activateController(sessionConfig, activeTargetController);
      return;
    }

    if (_hasBoundSessionWorkspaceConflict(session, sessionConfig)) {
      _showSnackBar(sessionWorkspaceConflictMessage(session.id));
      return;
    }

    final localTargetController = _controllerWithLocalSessionState(
      session,
      sessionConfig,
    );
    if (localTargetController != null) {
      if (_blockedByBusyLegacyRuntime(
        sessionConfig,
        target: localTargetController,
      )) {
        _showSnackBar(
          'Wait for the current response before switching sessions.',
        );
        return;
      }
      _activateController(sessionConfig, localTargetController);
      await localTargetController.resumeSession(
        session.id,
        cwd: session.cwd,
        additionalDirectories: session.additionalDirectories,
        title: session.title,
        updatedAt: session.updatedAt,
      );
      final activated = localTargetController.currentSession;
      if (activated != null &&
          activated.id.trim() == session.id.trim() &&
          normalizeWorkspacePath(activated.cwd) ==
              normalizeWorkspacePath(session.cwd)) {
        _restoreSessionAcrossCatalogAliases(
          session,
          preferred: localTargetController,
        );
      }
      if (mounted) setState(() {});
      return;
    }

    if (widget.controller != null && _controller.isStreaming) {
      _showSnackBar('Wait for the current response before switching sessions.');
      return;
    }

    if (!mounted) return;
    final dialogContext = _navigatorKey.currentState?.overlay?.context;
    if (dialogContext == null || !dialogContext.mounted) return;
    final approved = await showSessionWorkspaceReviewDialog(
      dialogContext,
      session,
    );
    if (!approved || !mounted) return;
    if (_hasBoundSessionWorkspaceConflict(session, sessionConfig)) {
      _showSnackBar(sessionWorkspaceConflictMessage(session.id));
      return;
    }

    final controller = widget.controller == null
        ? _availableControllerFor(sessionConfig)
        : _controller;
    if (controller == null) {
      _showSnackBar('Wait for the current response before switching sessions.');
      return;
    }
    if (controller.isSessionOperationRunning) {
      _showSnackBar('Waiting for the current session operation to finish.');
      await controller.waitForSessionOperationIdle();
      if (!mounted) return;
    }
    if (controller.hasBoundSessionWorkspaceConflict(session)) {
      _showSnackBar(sessionWorkspaceConflictMessage(session.id));
      return;
    }

    _activateController(sessionConfig, controller);
    await controller.resumeSession(
      session.id,
      cwd: session.cwd,
      additionalDirectories: session.additionalDirectories,
      title: session.title,
      updatedAt: session.updatedAt,
    );
    final resumed = controller.currentSession;
    if (resumed != null &&
        resumed.id.trim() == session.id.trim() &&
        normalizeWorkspacePath(resumed.cwd) ==
            normalizeWorkspacePath(session.cwd) &&
        !resumed.archived) {
      _restoreSessionAcrossCatalogAliases(session, preferred: controller);
    }
    if (mounted) setState(() {});
  }

  ChatController? _controllerWithCurrentSession(
    AgentSession session, {
    AcpClientConfig? config,
  }) {
    final sessionId = session.id.trim();
    final workspacePath = normalizeWorkspacePath(session.cwd);
    final agentName = session.agentName?.trim();
    final sourceKey = config == null
        ? null
        : _sessionCatalogSourceKeyForConfig(config);
    final runtimeSignature = config == null
        ? null
        : _controllerSignature(config);
    for (final controller in _sessionControllers) {
      if (widget.controller == null &&
          runtimeSignature != null &&
          _controllerRuntimeSignatures[controller] != runtimeSignature) {
        continue;
      }
      if (sourceKey != null &&
          controller.sessionCatalogSourceKey?.trim() != sourceKey) {
        continue;
      }
      final current = controller.currentSession;
      if (current == null ||
          current.id.trim() != sessionId ||
          normalizeWorkspacePath(current.cwd) != workspacePath) {
        continue;
      }
      if (agentName == null ||
          agentName.isEmpty ||
          controller.agentName.trim() == agentName ||
          controller.sessionPersistenceIdentity.trim() == agentName) {
        return controller;
      }
    }
    return null;
  }

  ChatController? _controllerWithLocalSessionState(
    AgentSession session,
    AcpClientConfig config,
  ) {
    if (widget.controller != null) {
      return _controller.canActivateSessionLocally(session.id)
          ? _controller
          : null;
    }

    final agentName = config.agentName.trim();
    final persistenceIdentity =
        config.activeAgentServer?.persistenceIdentity ?? agentName;
    final runtimeSignature = _controllerSignature(config);
    for (final controller in _sessionControllers) {
      if (!controller.canActivateSessionLocally(session.id)) continue;
      if (_controllerRuntimeSignatures[controller] != runtimeSignature) {
        continue;
      }
      if (controller.agentName.trim() == agentName ||
          controller.sessionPersistenceIdentity.trim() == persistenceIdentity) {
        return controller;
      }
    }
    return null;
  }

  AgentSession? _knownSessionForResume(
    String sessionId,
    AcpClientConfig config, {
    String? cwd,
  }) {
    final normalizedSessionId = sessionId.trim();
    final sourceKey = _sessionCatalogSourceKeyForConfig(config);
    final agentName = config.agentName.trim();
    final persistenceIdentity =
        config.activeAgentServer?.persistenceIdentity ?? agentName;
    final controllers = _sessionControllers.where(
      (controller) =>
          widget.controller != null ||
          (controller.sessionCatalogSourceKey?.trim() == sourceKey &&
              (controller.agentName.trim() == agentName ||
                  controller.sessionPersistenceIdentity.trim() ==
                      persistenceIdentity)),
    );
    final candidates = <AgentSession>[];
    for (final controller in controllers) {
      final current = controller.currentSession;
      if (current != null && current.id.trim() == normalizedSessionId) {
        candidates.add(current);
      }
    }
    for (final controller in controllers) {
      for (final session in controller.sessions) {
        if (session.id.trim() == normalizedSessionId) candidates.add(session);
      }
    }
    if (candidates.isEmpty) return null;
    final requestedWorkspace = _trimmedOrNull(cwd);
    final workspaceCandidates = requestedWorkspace == null
        ? candidates
        : candidates
              .where(
                (session) =>
                    normalizeWorkspacePath(session.cwd) ==
                    normalizeWorkspacePath(requestedWorkspace),
              )
              .toList(growable: false);
    final eligible = workspaceCandidates.isEmpty
        ? candidates
        : workspaceCandidates;
    for (final session in eligible) {
      final indexedAgentConfig = _config.configForSessionIndexAgent(
        session.agentName,
      );
      if (indexedAgentConfig != null &&
          _sessionTemplateForIndex(session, indexedAgentConfig) != null) {
        return session;
      }
    }
    for (final session in eligible) {
      final templateId = session.sessionTemplateId?.trim();
      if (templateId != null &&
          templateId.isNotEmpty &&
          session.sessionTemplateVersion != null) {
        return session;
      }
    }
    return eligible.first;
  }

  bool _hasBoundSessionWorkspaceConflict(
    AgentSession session,
    AcpClientConfig config,
  ) {
    if (widget.controller != null) {
      return _controller.hasBoundSessionWorkspaceConflict(session);
    }
    final sourceKey = _sessionCatalogSourceKeyForConfig(config);
    return _sessionControllers.any(
      (controller) =>
          controller.sessionCatalogSourceKey?.trim() == sourceKey &&
          controller.hasBoundSessionWorkspaceConflict(session),
    );
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
    final metadataControllers = _metadataControllersForSession(session);
    switch (action) {
      case WorkspaceSessionMenuAction.togglePinned:
        for (final candidate in metadataControllers) {
          candidate.setSessionPinned(session.id, !session.pinned);
        }
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.rename:
        await _renameSession(context, metadataControllers, session);
      case WorkspaceSessionMenuAction.archive:
        final archivedSnapshots = _archiveSessionAcrossCatalogAliases(session);
        if (archivedSnapshots == null || archivedSnapshots.isEmpty) return;
        _showUndoableSnackBar(
          'Archived "${session.displayTitle}".',
          archivedSnapshots,
        );
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.toggleUnread:
        for (final candidate in metadataControllers) {
          candidate.setSessionUnread(session.id, !session.unread);
        }
        if (mounted) setState(() {});
      case WorkspaceSessionMenuAction.openSideSession:
        await _openSideSession(session);
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
      case WorkspaceSessionMenuAction.copyMarkdown:
        await _copyToClipboard(
          _sessionMarkdown(controller, session),
          label: 'Conversation Markdown',
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
    final archivedSnapshots =
        <({ChatController controller, ArchivedSessionSnapshot snapshot})>[];
    var archivedCount = 0;
    for (final session in workspace.sessions) {
      final sessionSnapshots = _archiveSessionAcrossCatalogAliases(session);
      if (sessionSnapshots == null || sessionSnapshots.isEmpty) continue;
      archivedSnapshots.addAll(sessionSnapshots);
      archivedCount += 1;
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
    final active = _controllerWithCurrentSession(
      session,
      config: widget.controller == null
          ? _configForSessionIndex(session)
          : _config,
    );
    if (active != null) return active;

    late final ChatController preferred;
    final agentName = session.agentName?.trim();
    if (widget.controller == null &&
        agentName != null &&
        agentName.isNotEmpty) {
      final config = _configForSessionIndex(session);
      preferred = config == null
          ? _controller
          : _controllerForIndexedConfig(config);
    } else {
      preferred = _controller;
    }
    if (_controllerContainsSession(preferred, session)) return preferred;

    final sourceKey = preferred.sessionCatalogSourceKey?.trim();
    final preferredRuntimeSignature = _controllerRuntimeSignatures[preferred];
    if (sourceKey != null && sourceKey.isNotEmpty) {
      for (final controller in _sessionControllers) {
        if (identical(controller, preferred) ||
            controller.sessionCatalogSourceKey?.trim() != sourceKey ||
            (widget.controller == null &&
                _controllerRuntimeSignatures[controller] !=
                    preferredRuntimeSignature) ||
            !_controllerContainsSession(controller, session)) {
          continue;
        }
        return controller;
      }
    }
    return preferred;
  }

  List<ChatController> _metadataControllersForSession(AgentSession session) {
    final preferred = _controllerForSession(session);
    final sourceKey = preferred.sessionCatalogSourceKey?.trim();
    if (sourceKey == null || sourceKey.isEmpty) {
      return <ChatController>[preferred];
    }

    final controllers = <ChatController>[
      for (final controller in _sessionControllers)
        if (controller.sessionCatalogSourceKey?.trim() == sourceKey &&
            _controllerContainsSession(controller, session))
          controller,
    ];
    if (controllers.isEmpty) return <ChatController>[preferred];
    controllers.sort((left, right) {
      if (identical(left, preferred)) return -1;
      if (identical(right, preferred)) return 1;
      return left.agentName.compareTo(right.agentName);
    });
    return List<ChatController>.unmodifiable(controllers);
  }

  void _restoreSessionAcrossCatalogAliases(
    AgentSession session, {
    required ChatController preferred,
  }) {
    final sourceKey = preferred.sessionCatalogSourceKey?.trim();
    final sessionId = session.id.trim();
    final workspacePath = normalizeWorkspacePath(session.cwd);
    for (final controller in _sessionControllers) {
      if (sourceKey == null || sourceKey.isEmpty) {
        if (!identical(controller, preferred)) continue;
      } else if (controller.sessionCatalogSourceKey?.trim() != sourceKey) {
        continue;
      }
      final matches = controller.sessions.any(
        (candidate) =>
            candidate.id.trim() == sessionId &&
            normalizeWorkspacePath(candidate.cwd) == workspacePath,
      );
      if (matches) {
        controller.setSessionArchived(sessionId, false);
        controller.setSessionUnread(sessionId, false);
      }
    }
  }

  bool _controllerContainsSession(
    ChatController controller,
    AgentSession session,
  ) {
    final sessionId = session.id.trim();
    final workspacePath = normalizeWorkspacePath(session.cwd);
    return controller.sessions.any(
      (candidate) =>
          candidate.id.trim() == sessionId &&
          normalizeWorkspacePath(candidate.cwd) == workspacePath,
    );
  }

  List<({ChatController controller, ArchivedSessionSnapshot snapshot})>?
  _archiveSessionAcrossCatalogAliases(AgentSession session) {
    final targets = <ChatController>[
      for (final controller in _metadataControllersForSession(session))
        if (controller.sessions.any(
          (candidate) =>
              candidate.id.trim() == session.id.trim() &&
              normalizeWorkspacePath(candidate.cwd) ==
                  normalizeWorkspacePath(session.cwd) &&
              !candidate.archived,
        ))
          controller,
    ];
    if (targets.isEmpty ||
        targets.any(
          (controller) =>
              controller.isStreaming || controller.isSessionOperationRunning,
        )) {
      return null;
    }

    final archived =
        <({ChatController controller, ArchivedSessionSnapshot snapshot})>[];
    for (final controller in targets) {
      final snapshot = controller.archiveSessionLocally(session.id);
      if (snapshot == null) {
        for (final entry in archived.reversed) {
          entry.controller.restoreArchivedSessionLocally(entry.snapshot);
        }
        return null;
      }
      archived.add((controller: controller, snapshot: snapshot));
    }
    return archived;
  }

  Future<void> _renameSession(
    BuildContext context,
    List<ChatController> controllers,
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
    for (final controller in controllers) {
      controller.renameSession(session.id, trimmed);
    }
    if (mounted) setState(() {});
  }

  Future<void> _openSideSession(AgentSession session) async {
    final agentConfig = widget.controller == null
        ? _config.configForSessionIndexAgent(session.agentName)
        : _config;
    final template = widget.controller == null && agentConfig != null
        ? _sessionTemplateForIndex(session, agentConfig)
        : null;
    final config = template == null
        ? agentConfig
        : agentConfig!.forSessionTemplate(template);
    if (config == null) {
      _showSnackBar('Could not select the session agent.');
      return;
    }
    if (widget.controller != null &&
        (_controller.isStreaming || _controller.isSessionOperationRunning)) {
      _showSnackBar(
        'Finish the active operation before opening a side session.',
      );
      return;
    }
    final controller = widget.controller == null
        ? _availableControllerFor(config)
        : _controller;
    if (controller == null) {
      _showSnackBar(
        'Finish the active response before opening a side session.',
      );
      return;
    }
    _activateController(config, controller);
    final created = await controller.newSession(
      cwd: session.cwd,
      template: template,
    );
    if (!created) {
      _showSnackBar('Could not open a side session.');
      return;
    }
    _showSnackBar('Opened a new side session in this workspace.');
    if (mounted) setState(() {});
  }

  Future<bool> _forkSession(AgentSession session) async {
    if (!_canForkSession(session)) {
      _showSnackBar('This agent does not advertise session/fork.');
      return false;
    }

    final controller = _controllerForSession(session);
    if (widget.controller == null) {
      final config = _configForSessionIndex(session);
      if (config == null) {
        _showSnackBar('Could not select the session runtime.');
        return false;
      }
      if (_blockedByBusyLegacyRuntime(config, target: controller)) {
        _showSnackBar(
          'Wait for the current response before forking a session.',
        );
        return false;
      }
      _activateController(config, controller);
    }

    await controller.forkSession(session);
    if (mounted) setState(() {});
    final forked = controller.currentSession;
    return forked != null &&
        forked.id != session.id &&
        normalizeWorkspacePath(forked.cwd) ==
            normalizeWorkspacePath(session.cwd) &&
        controller.lastError == null;
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

    String? gitRoot;
    String? branchName;
    var worktreeCreated = false;
    try {
      _validateNewWorktreePath(worktreePath);
      gitRoot = await _gitRootFor(session.cwd);
      branchName = _worktreeBranchName(session.cwd, '${session.shortId}-fork');
      final result = await _runProcess('git', [
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
      worktreeCreated = true;

      final didFork = await _forkSession(session.copyWith(cwd: worktreePath));
      if (!didFork) {
        throw StateError('The ACP agent did not create the forked session.');
      }
      _showSnackBar('Created worktree "$branchName" for the new session.');
    } catch (error) {
      final cleanupError =
          worktreeCreated && gitRoot != null && branchName != null
          ? await _rollbackCreatedWorktree(
              gitRoot: gitRoot,
              worktreePath: worktreePath,
              branchName: branchName,
            )
          : null;
      _showSnackBar(
        'Could not fork to new worktree: $error'
        '${cleanupError == null ? '' : ' Cleanup also failed: $cleanupError'}',
      );
    }
  }

  Future<void> _createWorkspaceWorktree(
    BuildContext context,
    WorkspaceRecord workspace,
  ) async {
    if (_controller.isSessionOperationRunning ||
        (widget.controller != null && _controller.isStreaming)) {
      return;
    }

    final worktreePath = await _promptWorkspaceWorktreePath(context, workspace);
    if (worktreePath == null) return;

    String? gitRoot;
    String? branchName;
    var worktreeCreated = false;
    try {
      _validateNewWorktreePath(worktreePath);
      gitRoot = await _gitRootFor(workspace.path);
      branchName = _worktreeBranchName(workspace.path, 'worktree');
      final result = await _runProcess('git', [
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
      worktreeCreated = true;

      final controller = widget.controller == null
          ? _availableControllerFor(_config)
          : _controller;
      if (controller == null) {
        throw StateError(
          'Finish the active response before creating a worktree session.',
        );
      }
      _activateController(_config, controller);
      await controller.newSession(cwd: worktreePath);
      if (controller.currentSession == null ||
          normalizeWorkspacePath(controller.currentSession!.cwd) !=
              normalizeWorkspacePath(worktreePath) ||
          controller.lastError != null) {
        throw StateError('The ACP agent did not create the worktree session.');
      }
      _showSnackBar('Created worktree "$branchName".');
      if (mounted) setState(() {});
    } catch (error) {
      final cleanupError =
          worktreeCreated && gitRoot != null && branchName != null
          ? await _rollbackCreatedWorktree(
              gitRoot: gitRoot,
              worktreePath: worktreePath,
              branchName: branchName,
            )
          : null;
      _showSnackBar(
        'Could not create worktree: $error'
        '${cleanupError == null ? '' : ' Cleanup also failed: $cleanupError'}',
      );
    }
  }

  void _validateNewWorktreePath(String path) {
    final normalized = normalizeWorkspacePath(path);
    if (normalized.isEmpty || !File(normalized).isAbsolute) {
      throw ArgumentError('Worktree path must be absolute.');
    }
    if (FileSystemEntity.typeSync(normalized, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('Worktree path already exists: $normalized');
    }
  }

  Future<String?> _rollbackCreatedWorktree({
    required String gitRoot,
    required String worktreePath,
    required String branchName,
  }) async {
    final errors = <String>[];
    final remove = await _runProcess('git', [
      '-C',
      gitRoot,
      'worktree',
      'remove',
      '--force',
      worktreePath,
    ]);
    if (remove.exitCode != 0) {
      errors.add(remove.stderr.toString().trim());
    }
    final branch = await _runProcess('git', [
      '-C',
      gitRoot,
      'branch',
      '-D',
      branchName,
    ]);
    if (branch.exitCode != 0) {
      errors.add(branch.stderr.toString().trim());
    }
    errors.removeWhere((message) => message.isEmpty);
    return errors.isEmpty ? null : errors.join('; ');
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
    final result = await _runProcess('git', [
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

  Future<ProcessResult> _runProcess(String executable, List<String> arguments) {
    final runner = widget.processRunner;
    return runner == null
        ? Process.run(executable, arguments)
        : runner(executable, List<String>.unmodifiable(arguments));
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
    try {
      await Clipboard.setData(ClipboardData(text: text));
      _showSnackBar('$label copied.');
    } catch (error) {
      _showSnackBar('Could not copy $label: $error');
    }
  }

  String _sessionMarkdown(ChatController controller, AgentSession session) {
    final buffer = StringBuffer()
      ..writeln('# ${session.displayTitle}')
      ..writeln()
      ..writeln('- Session: `${session.id}`')
      ..writeln('- Workspace: `${session.cwd}`')
      ..writeln('- Agent: `${session.agentName ?? controller.agentName}`')
      ..writeln();
    if (controller.currentSession?.id == session.id) {
      for (final message in controller.messages) {
        final heading = switch (message.role) {
          ChatMessageRole.user => 'User',
          ChatMessageRole.assistant => 'Agent',
          ChatMessageRole.tool => 'Tool',
          ChatMessageRole.error => 'Error',
          ChatMessageRole.status => 'Status',
        };
        final text = message.text.trim();
        if (text.isEmpty) continue;
        buffer
          ..writeln('## $heading')
          ..writeln()
          ..writeln(text)
          ..writeln();
      }
    } else {
      for (final event in session.initialEvents) {
        final heading = switch (event.type) {
          AgentEventType.userMessage => 'User',
          AgentEventType.agentTextDelta ||
          AgentEventType.agentTextDone => 'Agent',
          AgentEventType.toolCall => 'Tool',
          AgentEventType.error => 'Error',
          AgentEventType.status => 'Status',
        };
        final text = event.text.trim();
        if (text.isEmpty) continue;
        buffer
          ..writeln('## $heading')
          ..writeln()
          ..writeln(text)
          ..writeln();
      }
    }
    return buffer.toString().trimRight();
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
        if (session.sessionTemplateId?.trim().isNotEmpty == true)
          'template': session.sessionTemplateId!.trim(),
        if (session.sessionTemplateVersion != null)
          'template_version': session.sessionTemplateVersion.toString(),
      },
    ).toString();
  }

  Future<void> _openSessionInNewWindow(AgentSession session) async {
    final args = <String>[
      '--resume-session-id=${session.id}',
      '--resume-cwd=${session.cwd}',
      if (session.agentName?.trim().isNotEmpty == true) ...[
        '--resume-agent=${session.agentName!.trim()}',
      ],
      if (session.sessionTemplateId?.trim().isNotEmpty == true) ...[
        '--resume-template=${session.sessionTemplateId!.trim()}',
      ],
      if (session.sessionTemplateVersion != null) ...[
        '--resume-template-version=${session.sessionTemplateVersion}',
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

      // The new window is intentionally independent. A normal-mode child
      // exposes stdout/stderr pipes that this parent never consumes, so a
      // chatty child could eventually block on a full pipe.
      await Process.start(
        Platform.resolvedExecutable,
        args,
        mode: ProcessStartMode.detached,
      );
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
    _activateController(nextConfig, controller);
    return controller;
  }

  void _activateController(
    AcpClientConfig nextConfig,
    ChatController controller,
  ) {
    final navigationConfig =
        widget.controller == null &&
            _config.agentServerNamed(nextConfig.agentName) != null
        ? _config.withActiveAgentServer(nextConfig.agentName)
        : nextConfig;
    _ensureControllersForSelectableAgents(navigationConfig);
    setState(() {
      _config = navigationConfig;
      _controller = controller;
    });
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

  AcpAgentClient _defaultAgentClient(
    AcpClientConfig config, {
    bool restrictedAssistant = false,
  }) {
    final server = config.activeAgentServer;
    if (server == null) {
      return const UnavailableAcpAgentClient(
        message: _noAgentConfiguredMessage,
      );
    }
    if (!server.isStdio) {
      return const UnavailableAcpAgentClient(
        message:
            'Remote ACP transports are unavailable until Rust Core owns '
            'their connection lifecycle.',
      );
    }
    if (config.mcpServers.any((server) => server.type == 'acp')) {
      return const UnavailableAcpAgentClient(
        message:
            'Unstable MCP-over-ACP is unavailable until Rust Core owns '
            'its typed transport.',
      );
    }
    return RustAcpAgentClient(
      agentName: server.name,
      agentPersistenceId: server.persistenceIdentity,
      agentPersistenceAliases: server.persistenceNames,
      agentCommand: server.command,
      agentArgs: server.args,
      agentCwd: server.cwd,
      sessionStorePath: restrictedAssistant
          ? null
          : _rustAcpSessionDatabasePath(config.configPath),
      sessionStoreMaxBytes: config.storage.maxBytes,
      sessionStoreRetentionDays: config.storage.retentionDays,
      mcpServers: restrictedAssistant
          ? const <Map<String, Object?>>[]
          : config.mcpServers
                .map(_rustMcpServerProjection)
                .toList(growable: false),
      envOverrides: server.env,
      additionalDirectories: restrictedAssistant
          ? const <String>[]
          : config.additionalDirectories,
      enableFilesystemReadTextFile:
          !restrictedAssistant &&
          config.clientProviders.filesystem.readTextFile,
      enableFilesystemWriteTextFile:
          !restrictedAssistant &&
          config.clientProviders.filesystem.writeTextFile,
      enableTerminalProvider:
          !restrictedAssistant && config.clientProviders.terminal.enabled,
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
      final target = reviewAgent.mcpServerName?.trim() ?? 'unknown';
      return AcpAgentPermissionReviewer(
        agentName: 'Unavailable MCP permission reviewer "$target"',
        modelOverride: reviewAgent.model,
        timeout: reviewAgent.timeout,
        clientFactory: () => UnavailableAcpAgentClient(
          message: 'Permission-review MCP server "$target" is unavailable.',
        ),
      );
    }

    final configuredAgentName = reviewAgent.enabled
        ? reviewAgent.agentServerName?.trim()
        : null;
    final reviewServer =
        configuredAgentName == null || configuredAgentName.isEmpty
        ? activeAgent
        : config.agentServerNamed(configuredAgentName);
    if (reviewServer == null) {
      return AcpAgentPermissionReviewer(
        agentName: configuredAgentName!,
        modelOverride: reviewAgent.model,
        timeout: reviewAgent.timeout,
        clientFactory: () => UnavailableAcpAgentClient(
          message:
              'Permission-review agent "$configuredAgentName" is not configured.',
        ),
      );
    }
    return AcpAgentPermissionReviewer(
      agentName: reviewServer.name,
      modelOverride: reviewAgent.model,
      canAutoApprove: true,
      timeout: reviewAgent.timeout,
      clientFactory: () => _reviewAgentClient(reviewServer),
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
    return config.effectivePermissionConfig;
  }

  AcpAgentClient _reviewAgentClient(AgentServerConfig server) {
    if (!server.isStdio) {
      return const UnavailableAcpAgentClient(
        message:
            'Remote permission-review agents require a Rust ACP transport.',
      );
    }
    return RustAcpAgentClient(
      agentName: '${server.name} permission reviewer',
      agentCommand: server.command,
      agentArgs: server.args,
      agentCwd: server.cwd,
      envOverrides: server.env,
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
    return <ChatController>{
      ..._controllersByAgent.values,
      ..._supplementalControllers,
    }.toList(growable: false);
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
      'storage': config.storage.toJson(),
      'assistantAgent': config.assistantAgent.toJson(),
      'sessionTemplates': <String, Object?>{
        for (final template in config.sessionTemplates)
          template.id: template.toJson(),
      },
      'configPath': config.configPath,
      'defaultAgentServerName': config.defaultAgentServerName,
      'defaultSessionTemplateId': config.defaultSessionTemplateId,
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
      'assistantAgent': config.assistantAgent.toJson(),
      'storage': config.storage.toJson(),
      'configPath': config.configPath,
      'runtimeSecretGeneration': config.runtimeSecretGeneration,
    });
  }

  String _agentClientRuntimeSignature(AcpClientConfig config) {
    return jsonEncode(<String, Object?>{
      'agentName': config.agentName,
      'activeAgentServer': _agentServerSignature(config.activeAgentServer),
      'mcpServers': config.mcpServers
          .map(_mcpServerSignature)
          .toList(growable: false),
      'additionalDirectories': config.additionalDirectories,
      'clientProviders': _clientProvidersSignature(config.clientProviders),
      'storage': config.storage.toJson(),
      'configPath': config.configPath,
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
      'agentServerName': config.agentServerName,
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
