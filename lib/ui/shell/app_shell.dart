import '../components/activity_diagnostics_dialog.dart';
import 'independent_llm_page.dart';
import 'package:ianvs_agent_chat/agent_chat_view.dart';
import '../../chat/acp_chat_session.dart';
import '../../platform/prompt_image_clipboard.dart';
import 'dart:async';
import 'dart:io';

import 'package:ianvs_design/ianvs_design.dart';
import 'package:flutter/services.dart';

import '../../acp/acp_input_budget.dart';
import '../../acp/acp_prompt_capability_policy.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../config/acp_agent_discovery.dart';
import '../../config/assistant_agent_config.dart';
import '../../storage/sqlite_storage_config.dart';
import '../../platform/file_manager.dart';
import '../../state/chat_controller.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_controller.dart';
import '../../terminal/acp_session_terminal_region.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
import '../components/agent_config_dialog.dart';
import '../components/session_menu_actions.dart';
import 'package:flutter/foundation.dart';
import '../components/agent_toolbar.dart';
import 'package:ianvs_agent_chat/ui/components/bounded_image_preview.dart';
import '../components/error_banner.dart';
import '../components/file_preview_workspace.dart';
import 'package:ianvs_agent_chat/ui/components/prompt_input.dart';
import '../components/resume_session_dialog.dart';
import '../components/session_settings_dialog.dart';
import '../components/session_workspace_review_dialog.dart';
import '../components/workspace_inspector.dart';
import '../components/workspace_sidebar.dart';
import '../image_decode_budget.dart';
import 'macos_workspace_layout.dart';

typedef AppShellProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.agentName = 'Codex',
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.storage = const SqliteStorageConfig(),
    this.assistantAgent = const AssistantAgentConfig(),
    this.sessionTemplates = const <SessionTemplateConfig>[],
    this.defaultSessionTemplateId,
    this.runtimeConfig,
    this.configPath,
    this.workspaceStateStore,
    this.defaultAgentName,
    this.startupError,
    this.onRetryStartup,
    this.canSwitchAgent = true,
    this.onSelectAgent,
    this.onSelectSession,
    this.onNewSession,
    this.onNewSessionInWorkspace,
    this.sessionActionAvailability,
    this.settingsRuntimeBusy,
    this.settingsClientProviders,
    this.onSessionMenuAction,
    this.onCreateWorkspaceWorktree,
    this.onArchiveWorkspaceSessions,
    this.onSaveConfig,
    this.onValidateAssistantAgent,
    this.onLoadAssistantAgentModels,
    this.sessionControllers = const <ChatController>[],
    this.supportsConcurrentSessions = false,
    this.processRunner,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
    this.gitWorkspaceDetector = workspaceSupportsGitWorktrees,
    this.terminalRuntimeFactory = createAcpTerminalRuntime,
  });

  final ChatController controller;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final SqliteStorageConfig storage;
  final AssistantAgentConfig assistantAgent;
  final List<SessionTemplateConfig> sessionTemplates;
  final String? defaultSessionTemplateId;
  final AcpClientConfig? runtimeConfig;
  final String? configPath;
  final WorkspaceSidebarStateStore? workspaceStateStore;
  final String? defaultAgentName;
  final String? startupError;
  final VoidCallback? onRetryStartup;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final ValueChanged<AgentSession>? onSelectSession;
  final void Function(BuildContext context)? onNewSession;
  final void Function(BuildContext context, WorkspaceRecord workspace)?
  onNewSessionInWorkspace;
  final SessionActionAvailability Function(AgentSession session)?
  sessionActionAvailability;
  final ValueListenable<bool>? settingsRuntimeBusy;
  final AcpClientProviderConfig? settingsClientProviders;
  final FutureOr<void> Function(
    BuildContext context,
    AgentSession session,
    WorkspaceSessionMenuAction action,
  )?
  onSessionMenuAction;
  final FutureOr<void> Function(
    BuildContext context,
    WorkspaceRecord workspace,
  )?
  onCreateWorkspaceWorktree;
  final FutureOr<void> Function(
    BuildContext context,
    WorkspaceRecord workspace,
  )?
  onArchiveWorkspaceSessions;
  final AcpConfigSaveCallback? onSaveConfig;
  final AssistantAgentValidationCallback? onValidateAssistantAgent;
  final AssistantAgentModelsLoadCallback? onLoadAssistantAgentModels;
  final List<ChatController> sessionControllers;
  final bool supportsConcurrentSessions;
  final AppShellProcessRunner? processRunner;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;
  final bool Function(String path) gitWorkspaceDetector;
  final AcpTerminalRuntimeFactory terminalRuntimeFactory;
  static final Expando<bool> _settingsRoutes = Expando<bool>(
    'AppShell settings routes',
  );

  @override
  Widget build(BuildContext context) {
    final sessionControllerList = _controllers();
    return AnimatedBuilder(
      animation: Listenable.merge(sessionControllerList),
      builder: (context, _) {
        final agentLifecycleBusy = sessionControllerList.any(
          (candidate) =>
              !identical(candidate, controller) &&
              candidate.agentName.trim() == controller.agentName.trim() &&
              (candidate.isStreaming || candidate.isSessionOperationRunning),
        );
        final sessionActionsEnabled =
            !controller.isStreaming && !controller.isSessionOperationRunning;
        final canStartNewSession =
            !controller.isSessionOperationRunning &&
            (!controller.isStreaming || supportsConcurrentSessions);
        final VoidCallback? startNewSession = canStartNewSession
            ? onNewSession == null
                  ? controller.newSession
                  : () => onNewSession!(context)
            : null;
        final ValueChanged<WorkspaceRecord>? startNewSessionInWorkspace =
            canStartNewSession
            ? (workspace) {
                if (onNewSessionInWorkspace != null) {
                  onNewSessionInWorkspace!(context, workspace);
                  return;
                }
                if (onNewSession != null) {
                  onNewSession!(context);
                  return;
                }
                unawaited(() async {
                  await controller.newSession(cwd: workspace.path);
                }());
              }
            : null;
        final canReconnect =
            sessionActionsEnabled &&
            (controller.status == ConnectionStatus.disconnected ||
                controller.status == ConnectionStatus.error);
        final workspaceController = WorkspaceController(
          controllers: sessionControllerList,
          currentWorkspacePath:
              controller.currentSession?.cwd ?? controller.cwd,
          defaultAgentName: defaultAgentName ?? agentName,
        );
        final currentWorkspace = workspaceController.currentWorkspace;
        final canOpenResumeDialog = _canOpenResumeDialog(sessionControllerList);
        final workspaceStateStore =
            this.workspaceStateStore ??
            WorkspaceSidebarStateStore(
              path: WorkspaceSidebarStateStore.defaultPath(
                configPath: configPath,
              ),
            );
        final promptCapabilityResolution = resolvePromptCapabilitiesForSession(
          advertised: controller.capabilities?.prompt,
          settings: controller.sessionSettings,
          agentName: agentName,
          agentInfo:
              controller.capabilities?.agentInfo ?? const <String, Object?>{},
        );
        final promptCapabilities = promptCapabilityResolution.capabilities;
        final activeSession = controller.currentSession;
        final activeAdditionalDirectories =
            activeSession?.additionalDirectories ??
            controller.additionalDirectories;
        final promptAttachmentController = PromptAttachmentController();

        return Scaffold(
          backgroundColor: context.ianvs.chrome,
          body: SafeArea(
            top: false,
            child: Column(
              children: [
                if (startupError != null)
                  ErrorBanner(
                    message: startupError!,
                    detail: configPath,
                    onOpen: configPath == null || configPath!.trim().isEmpty
                        ? null
                        : () => unawaited(_openConfig(context)),
                    onRetry: onRetryStartup,
                    onCopy: () => unawaited(
                      _copyDiagnostics(
                        context,
                        message: startupError!,
                        detail: configPath,
                      ),
                    ),
                  ),
                if (controller.lastError != null)
                  ErrorBanner(
                    message: controller.lastError!,
                    onRetry: canReconnect ? controller.reconnect : null,
                    onCopy: () => unawaited(
                      _copyDiagnostics(context, message: controller.lastError!),
                    ),
                  ),
                Expanded(
                  child: ColoredBox(
                    color: context.ianvs.canvas,
                    child: MacosWorkspaceLayout(
                      builder: (context, constraints, layout) {
                        final compactWindow = constraints.maxWidth < 780;
                        final hideSidebar =
                            compactWindow || !layout.sidebarVisible;
                        final hideInspector =
                            constraints.maxWidth < 1280 ||
                            !layout.inspectorVisible;
                        Widget buildInspector() => WorkspaceInspector(
                          workspace: currentWorkspace,
                          agentName: agentName,
                          currentSession: controller.currentSession,
                          environmentBranch: _branchFromMessages(
                            controller.messages,
                          ),
                          sessionSettings: controller.sessionSettings,
                          sessionUsage: controller.sessionUsage,
                          lastLatency: controller.lastLatency,
                          onShowSessionSettings: () =>
                              _showSessionSettingsDialog(context),
                          onShowCapabilities: () => _showDiagnostics(
                            context,
                            initialTab: DiagnosticsTab.runtime,
                          ),
                          mcpServers: mcpServers,
                          additionalDirectories: additionalDirectories,
                          clientProviders: clientProviders,
                          configPath: configPath,
                        );
                        Widget buildSidebar() => _ShellSidebar(
                          agentName: agentName,
                          onNewSession: startNewSession,
                          onShowAgentConfig: layout.openSettings,
                          onShowDiagnostics: () => _showDiagnostics(context),
                          workspaceSidebar: WorkspaceSidebar(
                            agentName: agentName,
                            workspaces: workspaceController.workspaces,
                            currentWorkspace: currentWorkspace,
                            currentSession: controller.currentSession,
                            onNewSession: startNewSession,
                            onNewSessionInWorkspace: startNewSessionInWorkspace,
                            onResumeSessionInWorkspace: canOpenResumeDialog
                                ? (workspace) => _showResumeDialog(
                                    context,
                                    workspaceCwd: workspace.path,
                                  )
                                : null,
                            onSelectSession: onSelectSession,
                            sessionActionAvailability:
                                sessionActionAvailability,
                            onSessionMenuAction: onSessionMenuAction == null
                                ? null
                                : (session, action) => onSessionMenuAction!(
                                    context,
                                    session,
                                    action,
                                  ),
                            onRevealWorkspace: (workspace) => unawaited(
                              _revealWorkspaceInFinder(context, workspace),
                            ),
                            onCreateWorkspaceWorktree:
                                onCreateWorkspaceWorktree == null
                                ? null
                                : (workspace) => onCreateWorkspaceWorktree!(
                                    context,
                                    workspace,
                                  ),
                            onArchiveWorkspaceSessions:
                                onArchiveWorkspaceSessions == null
                                ? null
                                : (workspace) => onArchiveWorkspaceSessions!(
                                    context,
                                    workspace,
                                  ),
                            stateStore: workspaceStateStore,
                            gitWorkspaceDetector: gitWorkspaceDetector,
                          ),
                        );
                        void showCompactPanel({
                          required String title,
                          required WidgetBuilder builder,
                        }) {
                          unawaited(
                            showDialog<void>(
                              context: context,
                              builder: (sheetContext) => _CompactPanelSheet(
                                title: title,
                                child: builder(sheetContext),
                              ),
                            ),
                          );
                        }

                        layout.onSidebarMenu = compactWindow
                            ? () => showCompactPanel(
                                title: 'Workspaces',
                                builder: (_) => buildSidebar(),
                              )
                            : layout.toggleSidebar;
                        layout.onInspectorMenu = constraints.maxWidth < 1280
                            ? () => showCompactPanel(
                                title: 'Context',
                                builder: (_) => buildInspector(),
                              )
                            : layout.toggleInspector;
                        layout.onSettingsMenu = () =>
                            _showAgentConfigDialog(context);

                        Widget conversationColumn(
                          BuildContext context,
                          FilePreviewLinkHandler onTapLink,
                        ) => PromptAttachmentDropRegion(
                          controller: promptAttachmentController,
                          enabled: !controller.isSessionOperationRunning,
                          promptCapabilities: promptCapabilities,
                          child: Column(
                            children: [
                              if (controller.newSessionStage case final stage?)
                                Semantics(
                                  liveRegion: true,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Row(
                                      children: [
                                        const SizedBox.square(
                                          dimension: 18,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(child: Text(stage.label)),
                                      ],
                                    ),
                                  ),
                                ),
                              Expanded(
                                child: AgentChatView(
                                  session: AcpChatSession(controller),
                                  onTapLink: onTapLink,
                                  onNewSession: startNewSession,
                                  attachmentController:
                                      promptAttachmentController,
                                  readClipboardImage:
                                      readPromptImageFromClipboard,
                                  imageDecodeLedger: imageDecodeLedger,
                                  boundedImageDecoder: boundedImageDecoder,
                                  showError: false,
                                ),
                              ),
                            ],
                          ),
                        );

                        final previewWorkspace = AcpSessionTerminalRegion(
                          session: activeSession,
                          runtimeFactory: terminalRuntimeFactory,
                          builder: (context, terminalToggle, terminalPanel) =>
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  AgentToolbar(
                                    sessionActionAvailability:
                                        controller.currentSession == null
                                        ? const SessionActionAvailability()
                                        : (sessionActionAvailability?.call(
                                                controller.currentSession!,
                                              ) ??
                                              const SessionActionAvailability()),
                                    onOpenLlmChat: () =>
                                        Navigator.of(context).push<void>(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const IndependentLlmPage(),
                                          ),
                                        ),
                                    sidebarVisible: !hideSidebar,
                                    inspectorVisible: !hideInspector,
                                    onToggleSidebar: compactWindow
                                        ? () => showCompactPanel(
                                            title: 'Workspaces',
                                            builder: (_) => buildSidebar(),
                                          )
                                        : layout.toggleSidebar,
                                    onToggleInspector:
                                        constraints.maxWidth < 1280
                                        ? () => showCompactPanel(
                                            title: 'Context',
                                            builder: (_) => buildInspector(),
                                          )
                                        : layout.toggleInspector,
                                    title:
                                        controller
                                            .currentSession
                                            ?.displayTitle ??
                                        currentWorkspace.name,
                                    agentName: agentName,
                                    agentServers: agentServers,
                                    status: controller.status,
                                    forceFullActions:
                                        constraints.maxWidth >= 1120,
                                    windowControlsInset:
                                        hideSidebar && Platform.isMacOS
                                        ? 70
                                        : 0,
                                    canSwitchAgent:
                                        canSwitchAgent &&
                                        !controller.isSessionOperationRunning &&
                                        (!controller.isStreaming ||
                                            supportsConcurrentSessions),
                                    onSelectAgent: onSelectAgent,
                                    onShowAgentConfig: layout.openSettings,
                                    onAuthenticate:
                                        controller.canAuthenticate &&
                                            !agentLifecycleBusy
                                        ? () => unawaited(
                                            _showAuthenticateDialog(context),
                                          )
                                        : null,
                                    onLogout:
                                        controller.canLogout &&
                                            !agentLifecycleBusy
                                        ? () =>
                                              unawaited(_confirmLogout(context))
                                        : null,
                                    currentSession: controller.currentSession,
                                    supportsGitWorktrees: gitWorkspaceDetector(
                                      currentWorkspace.path,
                                    ),
                                    onSessionMenuAction:
                                        controller.currentSession == null ||
                                            onSessionMenuAction == null
                                        ? null
                                        : (action) {
                                            final result = onSessionMenuAction!(
                                              context,
                                              controller.currentSession!,
                                              action,
                                            );
                                            if (result is Future<void>) {
                                              unawaited(result);
                                            }
                                          },
                                    onNewSession: startNewSession,
                                    onReconnect: canReconnect
                                        ? controller.reconnect
                                        : null,
                                    terminalPanelAction: terminalToggle,
                                  ),
                                  Expanded(
                                    child: FilePreviewWorkspace(
                                      workspacePath: currentWorkspace.path,
                                      additionalDirectories:
                                          activeAdditionalDirectories,
                                      conversationBuilder:
                                          (context, onTapLink) =>
                                              conversationColumn(
                                                context,
                                                onTapLink,
                                              ),
                                      showInspector: !hideInspector,
                                      processRunner: processRunner,
                                      inputBudget: inputBudget,
                                      imageDecodeLedger: imageDecodeLedger,
                                      boundedImageDecoder: boundedImageDecoder,
                                      inspector: buildInspector(),
                                    ),
                                  ),
                                  terminalPanel,
                                ],
                              ),
                        );

                        final sidebarWidth = layout.sidebarWidth;
                        final sidebarDivider = layout.sidebarDivider;
                        return Stack(
                          fit: StackFit.expand,
                          children: [
                            Row(
                              children: [
                                if (!hideSidebar)
                                  SizedBox(
                                    width: sidebarWidth,
                                    child: buildSidebar(),
                                  ),
                                Expanded(
                                  key: const ValueKey('conversation-workspace'),
                                  child: previewWorkspace,
                                ),
                              ],
                            ),
                            // Keep the resize target over the shared edge so
                            // panel backgrounds and borders meet underneath it.
                            if (!hideSidebar)
                              PositionedDirectional(
                                start:
                                    sidebarWidth - sidebarDivider.hitExtent / 2,
                                top: 0,
                                bottom: 0,
                                child: sidebarDivider,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _openConfig(BuildContext context) async {
    final path = configPath?.trim();
    if (path == null || path.isEmpty) return;
    try {
      await openPathExternally(path, processRunner: processRunner);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open config: $error')));
    }
  }

  Future<void> _copyDiagnostics(
    BuildContext context, {
    required String message,
    String? detail,
  }) async {
    final diagnostic = <String>[
      message.trim(),
      if (detail?.trim().isNotEmpty == true) 'Config: ${detail!.trim()}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: diagnostic));
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Diagnostics copied')));
  }

  Future<void> _showDiagnostics(
    BuildContext context, {
    DiagnosticsTab initialTab = DiagnosticsTab.events,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ActivityDiagnosticsDialog(
        controller: controller,
        runtimeConfig: runtimeConfig ?? _fallbackRuntimeConfig(),
        initialTab: initialTab,
      ),
    );
  }

  AcpClientConfig _fallbackRuntimeConfig() {
    AgentServerConfig? active;
    for (final server in agentServers) {
      if (server.name == agentName) active = server;
    }
    return AcpClientConfig(
      activeAgentServer: active,
      agentServers: agentServers,
      mcpServers: mcpServers,
      additionalDirectories: additionalDirectories,
      clientProviders: clientProviders,
      storage: storage,
      assistantAgent: assistantAgent,
      sessionTemplates: sessionTemplates,
      defaultAgentServerName: defaultAgentName,
      defaultSessionTemplateId: defaultSessionTemplateId,
      configPath: configPath,
    );
  }

  Future<void> _confirmLogout(BuildContext context) async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Log Out?'),
          content: Text(
            'Log out of the connected $agentName ACP agent and clear local '
            'session state.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: FilledButton.styleFrom(
                foregroundColor: IanvsTheme.foregroundFor(context.ianvs.danger),
                backgroundColor: context.ianvs.danger,
              ),
              child: const Text('Log Out'),
            ),
          ],
        );
      },
    );
    if (shouldLogout == true) {
      await controller.logout();
    }
  }

  Future<bool> _showAuthenticateDialog(
    BuildContext context, {
    ChatController? targetController,
  }) async {
    final authenticationController = targetController ?? controller;
    final methods = authenticationController.authMethods;
    if (methods.isEmpty) return false;
    final methodId = methods.length == 1
        ? _authMethodId(methods.single)
        : await showDialog<String>(
            context: context,
            builder: (context) {
              return AlertDialog(
                title: const Text('Authenticate'),
                content: SizedBox(
                  width: 420,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final method in methods)
                        _AuthMethodTile(
                          id: _authMethodId(method),
                          name: _authMethodLabel(method),
                          description: _authMethodDescription(method),
                        ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ],
              );
            },
          );
    if (methodId == null || methodId.isEmpty) return false;
    if (!context.mounted) return false;
    return authenticationController.authenticate(methodId);
  }

  List<ChatController> _controllers() {
    final controllers = <ChatController>[];
    void addController(ChatController candidate) {
      if (!controllers.contains(candidate)) controllers.add(candidate);
    }

    addController(controller);
    for (final sessionController in sessionControllers) {
      addController(sessionController);
    }
    return controllers;
  }

  bool _canOpenResumeDialog(List<ChatController> controllers) {
    return controllers.any(
      (candidate) =>
          candidate.canResumeSessions ||
          ((candidate.isStreaming || candidate.isSessionOperationRunning) &&
              candidate.supportsSessionList &&
              candidate.supportsSessionResume),
    );
  }

  List<_ResumeSessionAgentBinding> _resumeSessionAgentBindings(
    List<ChatController> controllers,
    BuildContext context,
  ) {
    final controllersByAgent = <String, ChatController>{};
    for (final candidate in controllers) {
      final name = candidate.agentName.trim();
      if (name.isEmpty) continue;
      final existing = controllersByAgent[name];
      if (existing == null ||
          _resumeControllerPriority(candidate) >
              _resumeControllerPriority(existing)) {
        controllersByAgent[name] = candidate;
      }
    }

    var nextId = 0;
    return controllersByAgent.entries
        .map((entry) {
          final candidate = entry.value;
          final isCurrent = entry.key == controller.agentName.trim();
          return _ResumeSessionAgentBinding(
            option: ResumeSessionAgentOption(
              id: 'resume-agent-${nextId++}',
              name: entry.key,
              description: _resumeAgentDescription(candidate),
              enabled: candidate.canResumeSessions,
              isCurrent: isCurrent,
              authenticate: candidate.canAuthenticate
                  ? () => _showAuthenticateDialog(
                      context,
                      targetController: candidate,
                    )
                  : null,
              loadSessions: candidate.listResumableSessions,
            ),
            controller: candidate,
          );
        })
        .toList(growable: false);
  }

  int _resumeControllerPriority(ChatController candidate) {
    return (candidate.canResumeSessions ? 4 : 0) +
        (identical(candidate, controller) ? 2 : 0) +
        (!candidate.isStreaming && !candidate.isSessionOperationRunning
            ? 1
            : 0);
  }

  String _resumeAgentDescription(ChatController candidate) {
    if (candidate.isStreaming) return 'Response in progress';
    if (candidate.isSessionOperationRunning) {
      return 'Session operation in progress';
    }
    final lastError = candidate.lastError?.toLowerCase() ?? '';
    if (lastError.contains('auth_required') ||
        lastError.contains('authentication required')) {
      return 'Authentication required';
    }
    if (!candidate.canResumeSessions && candidate.capabilities != null) {
      if (!candidate.supportsSessionList) {
        return 'Session listing unsupported';
      }
      if (!candidate.supportsSessionResume) {
        return 'Session restore unsupported';
      }
    }
    if (candidate.status == ConnectionStatus.connecting ||
        candidate.status == ConnectionStatus.reconnecting) {
      return 'Connecting...';
    }
    if (candidate.status == ConnectionStatus.error) {
      return 'Connection error';
    }
    return 'Ready';
  }

  Future<void> _revealWorkspaceInFinder(
    BuildContext context,
    WorkspaceRecord workspace,
  ) async {
    try {
      await revealPathInFileManager(
        workspace.path,
        processRunner: processRunner,
        checkExists: processRunner == null,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Could not reveal workspace: $error')),
      );
    }
  }

  Future<void> _showAgentConfigDialog(BuildContext context) async {
    final navigator = Navigator.of(context);
    if (_settingsRoutes[navigator] == true) return;
    _settingsRoutes[navigator] = true;
    SettingsExitAction? destination;
    try {
      destination = await navigator.push<SettingsExitAction>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/settings'),
          builder: (context) => AgentConfigDialog(
            agentServers: agentServers,
            agentPresets: AcpAgentDiscovery.discover(),
            mcpServers: mcpServers,
            additionalDirectories: additionalDirectories,
            clientProviders: settingsClientProviders ?? clientProviders,
            storage: storage,
            assistantAgent: assistantAgent,
            sessionTemplates: sessionTemplates,
            defaultSessionTemplateId: defaultSessionTemplateId,
            activeAgentName: agentName,
            configPath: configPath,
            defaultAgentName: defaultAgentName,
            onSaveConfig: onSaveConfig,
            runtimeBusy: settingsRuntimeBusy,
            allowAppNavigation: true,
            onValidateAssistantAgent: onValidateAssistantAgent,
            onLoadAssistantAgentModels: onLoadAssistantAgentModels,
          ),
        ),
      );
    } finally {
      _settingsRoutes[navigator] = false;
    }
    if (!context.mounted || destination == null) return;
    final currentShell =
        context.findAncestorWidgetOfExactType<AppShell>() ?? this;
    switch (destination) {
      case SettingsExitAction.newSession:
        if (currentShell.onNewSession != null) {
          currentShell.onNewSession!(context);
        } else {
          await currentShell.controller.newSession();
        }
      case SettingsExitAction.diagnostics:
        await currentShell._showDiagnostics(context);
    }
  }

  Future<void> _showSessionSettingsDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return SessionSettingsDialog(
          controller: controller,
          inputBudget: inputBudget,
        );
      },
    );
  }

  Future<void> _showResumeDialog(
    BuildContext context, {
    required String workspaceCwd,
  }) async {
    final sessionControllerList = _controllers();
    if ((controller.status == ConnectionStatus.disconnected ||
            controller.status == ConnectionStatus.error) &&
        !controller.isSessionOperationRunning) {
      await controller.connect();
      if (!context.mounted) return;
    }
    if (!_canOpenResumeDialog(sessionControllerList)) return;
    final agentBindings = _resumeSessionAgentBindings(
      sessionControllerList,
      context,
    );
    final bindingsById = <String, _ResumeSessionAgentBinding>{
      for (final binding in agentBindings) binding.option.id: binding,
    };
    final selection = await showDialog<ResumeSessionSelection>(
      context: context,
      builder: (context) => ResumeSessionDialog(
        inputBudget: inputBudget,
        agents: agentBindings
            .map((binding) => binding.option)
            .toList(growable: false),
        initialAgentId: agentBindings
            .where((binding) => binding.option.isCurrent)
            .firstOrNull
            ?.option
            .id,
        initialCwd: workspaceCwd,
        workspaceCwd: workspaceCwd,
      ),
    );

    if (selection == null) return;
    if (!context.mounted) return;
    final selectedBinding = bindingsById[selection.agentId];
    if (selectedBinding == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The selected ACP agent is unavailable.')),
      );
      return;
    }
    final selectionAgentName = selection.agentName.trim();
    final indexedSession = _indexedSessionForResume(
      sessionControllerList,
      sessionId: selection.conversation.id,
      cwd: selection.conversation.cwd,
      agentName: selectionAgentName,
    );
    final selectedSession = AgentSession(
      id: selection.conversation.id,
      cwd: selection.conversation.cwd,
      createdAt:
          selection.conversation.updatedAt ??
          DateTime.fromMillisecondsSinceEpoch(0),
      additionalDirectories: selection.conversation.additionalDirectories,
      title: selection.conversation.title,
      updatedAt: selection.conversation.updatedAt,
      agentName: selectionAgentName,
      sessionTemplateId: indexedSession?.sessionTemplateId,
      sessionTemplateVersion: indexedSession?.sessionTemplateVersion,
    );
    final trustedTargetController = selectedBinding.controller;
    final externalSelectSession = onSelectSession;
    if (trustedTargetController.hasBoundSessionWorkspaceConflict(
      selectedSession,
    )) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(sessionWorkspaceConflictMessage(selectedSession.id)),
        ),
      );
      return;
    }
    if (externalSelectSession != null) {
      externalSelectSession(selectedSession);
      return;
    }

    final targetController = trustedTargetController;
    final activeSession = targetController.currentSession;
    if (activeSession != null &&
        activeSession.id.trim() == selectedSession.id.trim()) {
      _restoreSessionAcrossCatalogAliases(
        sessionControllerList,
        targetController,
        selectedSession,
      );
      return;
    }

    final approved = await showSessionWorkspaceReviewDialog(
      context,
      selectedSession,
    );
    if (!approved || !context.mounted) return;

    await targetController.resumeSession(
      selectedSession.id,
      cwd: selectedSession.cwd,
      additionalDirectories: selectedSession.additionalDirectories,
      title: selectedSession.title,
      updatedAt: selectedSession.updatedAt,
    );
    final resumed = targetController.currentSession;
    if (resumed != null &&
        resumed.id.trim() == selectedSession.id.trim() &&
        normalizeWorkspacePath(resumed.cwd) ==
            normalizeWorkspacePath(selectedSession.cwd) &&
        !resumed.archived) {
      _restoreSessionAcrossCatalogAliases(
        sessionControllerList,
        targetController,
        selectedSession,
      );
    }
  }

  void _restoreSessionAcrossCatalogAliases(
    List<ChatController> controllers,
    ChatController target,
    AgentSession session,
  ) {
    final sourceKey = target.sessionCatalogSourceKey?.trim();
    final sessionId = session.id.trim();
    final workspacePath = normalizeWorkspacePath(session.cwd);
    for (final candidateController in controllers) {
      if (sourceKey == null || sourceKey.isEmpty) {
        if (!identical(candidateController, target)) continue;
      } else if (candidateController.sessionCatalogSourceKey?.trim() !=
          sourceKey) {
        continue;
      }
      final matches = candidateController.sessions.any(
        (candidate) =>
            candidate.id.trim() == sessionId &&
            normalizeWorkspacePath(candidate.cwd) == workspacePath,
      );
      if (matches) {
        candidateController.setSessionArchived(sessionId, false);
        candidateController.setSessionUnread(sessionId, false);
      }
    }
  }

  AgentSession? _indexedSessionForResume(
    List<ChatController> controllers, {
    required String sessionId,
    required String cwd,
    required String? agentName,
  }) {
    final normalizedId = sessionId.trim();
    final normalizedCwd = normalizeWorkspacePath(cwd);
    final normalizedAgent = agentName?.trim();
    AgentSession? fallback;
    for (final candidateController in controllers) {
      if (normalizedAgent != null &&
          normalizedAgent.isNotEmpty &&
          candidateController.agentName.trim() != normalizedAgent &&
          candidateController.sessionPersistenceIdentity.trim() !=
              normalizedAgent) {
        continue;
      }
      final candidates = <AgentSession>[
        ?candidateController.currentSession,
        ...candidateController.sessions,
      ];
      for (final candidate in candidates) {
        if (candidate.id.trim() != normalizedId ||
            normalizeWorkspacePath(candidate.cwd) != normalizedCwd) {
          continue;
        }
        if (candidate.sessionTemplateId?.trim().isNotEmpty == true) {
          return candidate;
        }
        fallback ??= candidate;
      }
    }
    return fallback;
  }
}

final class _ResumeSessionAgentBinding {
  const _ResumeSessionAgentBinding({
    required this.option,
    required this.controller,
  });

  final ResumeSessionAgentOption option;
  final ChatController controller;
}

class _CompactPanelSheet extends StatelessWidget {
  const _CompactPanelSheet({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final height = (size.height - 80).clamp(0.0, 720.0).toDouble();
    return SafeArea(
      top: false,
      child: Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: Dialog(
            clipBehavior: Clip.antiAlias,
            insetPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 24,
            ),
            child: SizedBox(
              height: height,
              child: Column(
                children: [
                  SizedBox(
                    height: 50,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 6, 8, 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              style: TextStyle(
                                color: context.ianvs.text,
                                fontFamily: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.fontFamily,
                                fontFamilyFallback: Theme.of(
                                  context,
                                ).textTheme.bodyMedium?.fontFamilyFallback,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: 'Close $title',
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded, size: 19),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Divider(height: 1, color: context.ianvs.border),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ShellSidebar extends StatelessWidget {
  const _ShellSidebar({
    required this.agentName,
    required this.onNewSession,
    required this.onShowAgentConfig,
    required this.onShowDiagnostics,
    required this.workspaceSidebar,
  });

  final String agentName;
  final VoidCallback? onNewSession;
  final VoidCallback? onShowAgentConfig;
  final VoidCallback? onShowDiagnostics;
  final Widget workspaceSidebar;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.ianvs.chrome,
      child: Column(
        children: [
          _SidebarBrandHeader(
            agentName: agentName,
            windowControlsInset: Platform.isMacOS ? 28 : 0,
            onNewSession: onNewSession,
            onShowAgentConfig: onShowAgentConfig,
            onShowDiagnostics: onShowDiagnostics,
          ),
          Expanded(child: workspaceSidebar),
          _SidebarAccountFooter(agentName: agentName),
        ],
      ),
    );
  }
}

class _SidebarBrandHeader extends StatelessWidget {
  const _SidebarBrandHeader({
    required this.agentName,
    required this.windowControlsInset,
    required this.onNewSession,
    required this.onShowAgentConfig,
    required this.onShowDiagnostics,
  });

  final String agentName;
  final double windowControlsInset;
  final VoidCallback? onNewSession;
  final VoidCallback? onShowAgentConfig;
  final VoidCallback? onShowDiagnostics;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Padding(
              padding: EdgeInsets.only(left: windowControlsInset > 0 ? 76 : 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Shift',
                  style: Theme.of(context).textTheme.titleMedium!,
                ),
              ),
            ),
          ),
          _SidebarNavItem(
            icon: Icons.edit_square,
            label: '新对话',
            onTap: onNewSession,
          ),
          _SidebarNavItem(
            icon: Icons.manage_accounts_outlined,
            label: '设置',
            onTap: onShowAgentConfig,
          ),
          _SidebarNavItem(
            icon: Icons.manage_history_rounded,
            label: '活动与诊断',
            onTap: onShowDiagnostics,
          ),
        ],
      ),
    );
  }
}

class _SidebarNavItem extends StatelessWidget {
  const _SidebarNavItem({required this.icon, required this.label, this.onTap});

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        onTap: onTap,
        child: SizedBox(
          height: 35,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                Icon(icon, size: 18, color: context.ianvs.muted),
                const SizedBox(width: 10),
                Text(
                  label,
                  style: TextStyle(
                    color: context.ianvs.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarAccountFooter extends StatelessWidget {
  const _SidebarAccountFooter({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    final trimmed = agentName.trim();
    final initial = trimmed.isEmpty ? 'A' : trimmed.characters.first;
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: context.ianvs.separator)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: const Color(0xff9aa6a2),
            child: Text(
              initial.toUpperCase(),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              agentName,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.text,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthMethodTile extends StatelessWidget {
  const _AuthMethodTile({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(Icons.login_rounded, color: context.ianvs.focus),
      title: Text(
        name,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: context.ianvs.text,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      subtitle: description.isEmpty
          ? null
          : Text(
              description,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: context.ianvs.muted,
                fontWeight: FontWeight.w600,
                letterSpacing: 0,
              ),
            ),
      onTap: () => Navigator.of(context).pop(id),
    );
  }
}

String _authMethodId(Map<String, Object?> method) {
  final id = method['id'];
  return id is String ? id.trim() : '';
}

String _authMethodLabel(Map<String, Object?> method) {
  final name = method['name'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final id = _authMethodId(method);
  return id.isEmpty ? 'Authenticate' : id;
}

String _authMethodDescription(Map<String, Object?> method) {
  final description = method['description'];
  return description is String ? description.trim() : '';
}

String? _branchFromMessages(List<ChatMessage> messages) {
  const candidateKeys = [
    'branch',
    'branchName',
    'branch_name',
    'gitBranch',
    'git_branch',
    'worktreeBranch',
  ];
  for (final message in messages.reversed.take(128)) {
    for (final key in candidateKeys) {
      final value = message.metadata[key];
      if (value == null) continue;
      final label = value.toString().trim().replaceAll(RegExp(r'\s+'), ' ');
      if (label.isNotEmpty) return label;
    }
  }
  return null;
}
