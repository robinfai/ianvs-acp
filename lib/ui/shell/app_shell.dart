import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:dart_acp/dart_acp.dart';

import '../../acp/acp_session_catalog.dart';
import '../../acp/acp_permission_request.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../config/acp_agent_discovery.dart';
import '../../platform/file_manager.dart';
import '../../state/chat_controller.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_controller.dart';
import '../../tasks/task_inbox_controller.dart';
import '../../tasks/task_record.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
import '../components/agent_config_dialog.dart';
import '../components/agent_toolbar.dart';
import '../components/bounded_image_preview.dart';
import '../components/capabilities_dialog.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/extension_request_dialog.dart';
import '../components/file_preview_workspace.dart';
import '../components/permission_history_dialog.dart';
import '../components/prompt_input.dart';
import '../components/protocol_feature_review_dialog.dart';
import '../components/resume_session_dialog.dart';
import '../components/session_settings_dialog.dart';
import '../components/session_workspace_review_dialog.dart';
import '../components/status_bar.dart';
import '../components/task_inbox_sidebar.dart';
import '../components/workspace_header.dart';
import '../components/workspace_inspector.dart';
import '../components/workspace_sidebar.dart';
import '../image_decode_budget.dart';
import '../theme/app_design_tokens.dart';

typedef AppShellProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);
typedef AppShellAgentAuthenticated =
    FutureOr<void> Function(String agentName, String methodId);

enum AppShellSidebarMode { workspaces, inbox }

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.taskInboxController,
    this.initialSidebarMode = AppShellSidebarMode.workspaces,
    this.selectedTaskId,
    this.agentName = 'Codex',
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.configPath,
    this.defaultAgentName,
    this.startupError,
    this.canSwitchAgent = true,
    this.autoLoadWorkspaceSessions = true,
    this.onSelectAgent,
    this.onSelectSession,
    this.onNewSession,
    this.onNewSessionInWorkspace,
    this.canForkSession,
    this.onSessionMenuAction,
    this.onCreateWorkspaceWorktree,
    this.onArchiveWorkspaceSessions,
    this.onRunTask,
    this.onOpenTaskSession,
    this.onAgentAuthenticated,
    this.onSaveConfig,
    this.sessionControllers = const <ChatController>[],
    this.processRunner,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
  });

  final ChatController controller;
  final TaskInboxController? taskInboxController;
  final AppShellSidebarMode initialSidebarMode;
  final String? selectedTaskId;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;
  final String? defaultAgentName;
  final String? startupError;
  final bool canSwitchAgent;
  final bool autoLoadWorkspaceSessions;
  final ValueChanged<String>? onSelectAgent;
  final ValueChanged<AgentSession>? onSelectSession;
  final void Function(BuildContext context)? onNewSession;
  final void Function(BuildContext context, WorkspaceRecord workspace)?
  onNewSessionInWorkspace;
  final bool Function(AgentSession session)? canForkSession;
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
  final FutureOr<void> Function(BuildContext context, TaskRecord task)?
  onRunTask;
  final FutureOr<void> Function(BuildContext context, TaskRecord task)?
  onOpenTaskSession;
  final AppShellAgentAuthenticated? onAgentAuthenticated;
  final AcpConfigSaveCallback? onSaveConfig;
  final List<ChatController> sessionControllers;
  final AppShellProcessRunner? processRunner;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;

  @override
  Widget build(BuildContext context) {
    final sessionControllerList = _controllers();
    return AnimatedBuilder(
      animation: Listenable.merge(sessionControllerList),
      builder: (context, _) {
        final sessionActionsEnabled =
            !controller.isStreaming && !controller.isSessionOperationRunning;
        final VoidCallback? startNewSession = sessionActionsEnabled
            ? onNewSession == null
                  ? controller.newSession
                  : () => onNewSession!(context)
            : null;
        final ValueChanged<WorkspaceRecord>? startNewSessionInWorkspace =
            sessionActionsEnabled
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
        final canResumeSessions = sessionControllerList.any(
          (controller) => controller.canResumeSessions,
        );
        final canLoadWorkspaceSessions =
            autoLoadWorkspaceSessions &&
            sessionControllerList.any(
              (controller) => controller.canListSessions,
            );
        final workspaceStateStore = WorkspaceSidebarStateStore(
          path: WorkspaceSidebarStateStore.defaultPath(configPath: configPath),
        );
        Widget promptDock() => PromptInput(
          inputBudget: inputBudget,
          agentName: agentName,
          enabled: !controller.isSessionOperationRunning,
          isSending: controller.isStreaming,
          availableCommands: controller.availableCommands,
          availableCommandsRevision: controller.availableCommandsRevision,
          promptCapabilities: controller.capabilities?.prompt,
          pendingPermissionRequest: controller.pendingPermissionRequest,
          onAllowPermission: () => unawaited(
            controller.resolvePermissionRequest(AcpPermissionDecision.allow),
          ),
          onDenyPermission: () => unawaited(
            controller.resolvePermissionRequest(AcpPermissionDecision.deny),
          ),
          onCancelPermission: () => unawaited(
            controller.resolvePermissionRequest(AcpPermissionDecision.cancel),
          ),
          onSelectPermissionOption: (optionId) =>
              unawaited(controller.resolvePermissionOption(optionId)),
          toolCallExecutionPolicy: controller.toolCallExecutionPolicy,
          hasPermissionReviewer: controller.hasPermissionReviewer,
          onToolCallExecutionPolicyChanged:
              controller.setToolCallExecutionPolicy,
          modelOption: controller.sessionSettings.modelOption,
          reasoningEffortOption:
              controller.sessionSettings.reasoningEffortOption,
          onModelSelected:
              controller.currentSession != null && sessionActionsEnabled
              ? (value) => unawaited(controller.setSessionModel(value))
              : null,
          onReasoningEffortSelected:
              controller.currentSession != null && sessionActionsEnabled
              ? (value) =>
                    unawaited(controller.setSessionReasoningEffort(value))
              : null,
          onSend: (text, attachments) =>
              controller.sendPrompt(text, attachments: attachments),
          onStop: controller.stop,
        );

        Widget statusDock() => StatusBar(
          controller: controller,
          onShowSessionSettings: () => _showSessionSettingsDialog(context),
          onShowCapabilities: () => _showCapabilitiesDialog(context),
        );

        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                AgentToolbar(
                  agentName: agentName,
                  agentServers: agentServers,
                  status: controller.status,
                  canSwitchAgent: canSwitchAgent && sessionActionsEnabled,
                  onSelectAgent: onSelectAgent,
                  onShowAgentConfig: () => _showAgentConfigDialog(context),
                  onShowProtocolCoverage: () =>
                      _showProtocolFeatureReviewDialog(context),
                  onAuthenticate: controller.canAuthenticate
                      ? () => unawaited(_showAuthenticateDialog(context))
                      : null,
                  onShowPermissionHistory:
                      controller.permissionHistory.isNotEmpty
                      ? () => _showPermissionHistoryDialog(context)
                      : null,
                  onExtensionRequest: controller.canSendExtensionRequest
                      ? () => _showExtensionRequestDialog(context)
                      : null,
                  onLogout: controller.canLogout
                      ? () => unawaited(_confirmLogout(context))
                      : null,
                  onNewSession: startNewSession,
                  onResumeSession: canResumeSessions
                      ? () => _showResumeDialog(context)
                      : null,
                  onReconnect: canReconnect ? controller.reconnect : null,
                ),
                if (startupError != null) ErrorBanner(message: startupError!),
                if (controller.lastError != null)
                  ErrorBanner(message: controller.lastError!),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 2, 8, 6),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppShadows.soft,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final hideSidebar = constraints.maxWidth < 760;
                          final hideInspector = constraints.maxWidth < 1120;
                          Widget conversationColumn(
                            BuildContext context,
                            FilePreviewLinkHandler onTapLink,
                          ) => Column(
                            children: [
                              WorkspaceHeader(
                                workspace: currentWorkspace,
                                agentName: agentName,
                                currentSession: controller.currentSession,
                              ),
                              const Divider(height: 1, color: AppColors.border),
                              Expanded(
                                child: ChatTimeline(
                                  inputBudget: inputBudget,
                                  imageDecodeLedger: imageDecodeLedger,
                                  boundedImageDecoder: boundedImageDecoder,
                                  messages: controller.messages,
                                  messageListRevision:
                                      controller.messagesRevision,
                                  agentName: agentName,
                                  hasActiveSession:
                                      controller.currentSession != null,
                                  activeSessionLabel:
                                      controller.currentSession?.displayTitle,
                                  isLoadingSession:
                                      controller.isSessionReplayLoading,
                                  onNewSession: null,
                                  onTapLink: onTapLink,
                                ),
                              ),
                              promptDock(),
                              statusDock(),
                            ],
                          );

                          final previewWorkspace = FilePreviewWorkspace(
                            workspacePath: currentWorkspace.path,
                            additionalDirectories: additionalDirectories,
                            conversationBuilder: conversationColumn,
                            showInspector: !hideInspector,
                            processRunner: processRunner,
                            inspector: WorkspaceInspector(
                              workspace: currentWorkspace,
                              agentName: agentName,
                              currentSession: controller.currentSession,
                              mcpServers: mcpServers,
                              additionalDirectories: additionalDirectories,
                              clientProviders: clientProviders,
                              configPath: configPath,
                            ),
                          );

                          if (hideSidebar) return previewWorkspace;

                          return Row(
                            children: [
                              if (!hideSidebar) ...[
                                SizedBox(
                                  width: 350,
                                  child: _ShellSidebar(
                                    workspaceSidebar: WorkspaceSidebar(
                                      agentName: agentName,
                                      workspaces:
                                          workspaceController.workspaces,
                                      currentWorkspace: currentWorkspace,
                                      currentSession: controller.currentSession,
                                      onNewSession: startNewSession,
                                      onNewSessionInWorkspace:
                                          startNewSessionInWorkspace,
                                      onResumeSession: canResumeSessions
                                          ? () => _showResumeDialog(context)
                                          : null,
                                      onSelectSession: onSelectSession,
                                      canForkSession: canForkSession,
                                      onSessionMenuAction:
                                          onSessionMenuAction == null
                                          ? null
                                          : (session, action) =>
                                                onSessionMenuAction!(
                                                  context,
                                                  session,
                                                  action,
                                                ),
                                      onLoadWorkspaceSessions:
                                          canLoadWorkspaceSessions
                                          ? (_) async {
                                              await _loadSessionCatalogs(
                                                sessionControllerList,
                                              );
                                            }
                                          : null,
                                      onRevealWorkspace: (workspace) =>
                                          unawaited(
                                            _revealWorkspaceInFinder(
                                              context,
                                              workspace,
                                            ),
                                          ),
                                      onCreateWorkspaceWorktree:
                                          onCreateWorkspaceWorktree == null
                                          ? null
                                          : (workspace) =>
                                                onCreateWorkspaceWorktree!(
                                                  context,
                                                  workspace,
                                                ),
                                      onArchiveWorkspaceSessions:
                                          onArchiveWorkspaceSessions == null
                                          ? null
                                          : (workspace) =>
                                                onArchiveWorkspaceSessions!(
                                                  context,
                                                  workspace,
                                                ),
                                      stateStore: workspaceStateStore,
                                    ),
                                    taskInboxController: taskInboxController,
                                    initialMode: initialSidebarMode,
                                    taskInboxSidebar:
                                        taskInboxController == null
                                        ? null
                                        : TaskInboxSidebar(
                                            controller: taskInboxController!,
                                            selectedTaskId: selectedTaskId,
                                            defaultWorkspacePath:
                                                currentWorkspace.path,
                                            defaultAgentName: agentName,
                                            defaultModel:
                                                controller.currentModelValue,
                                            agentNames: _agentNamesForTasks(),
                                            onRunTask: onRunTask == null
                                                ? null
                                                : (task) =>
                                                      onRunTask!(context, task),
                                            onOpenLinkedSession:
                                                onOpenTaskSession == null
                                                ? null
                                                : (task) {
                                                    unawaited(
                                                      Future<void>.sync(
                                                        () =>
                                                            onOpenTaskSession!(
                                                              context,
                                                              task,
                                                            ),
                                                      ),
                                                    );
                                                  },
                                          ),
                                  ),
                                ),
                                const VerticalDivider(
                                  width: 1,
                                  color: AppColors.border,
                                ),
                              ],
                              Expanded(child: previewWorkspace),
                            ],
                          );
                        },
                      ),
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

  Future<void> _showCapabilitiesDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return CapabilitiesDialog(
          capabilities: controller.capabilities,
          inputBudget: inputBudget,
        );
      },
    );
  }

  Future<void> _showExtensionRequestDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return ExtensionRequestDialog(
          controller: controller,
          inputBudget: inputBudget,
        );
      },
    );
  }

  Future<void> _showPermissionHistoryDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return PermissionHistoryDialog(entries: controller.permissionHistory);
      },
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
                foregroundColor: Colors.white,
                backgroundColor: AppColors.danger,
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

  Future<void> _showAuthenticateDialog(BuildContext context) async {
    final methods = controller.authMethods;
    if (methods.isEmpty) return;
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
    if (methodId == null || methodId.isEmpty) return;
    if (!context.mounted) return;
    final authenticated = await controller.authenticate(methodId);
    final callback = onAgentAuthenticated;
    if (!authenticated || callback == null) return;
    await Future<void>.sync(() => callback(controller.agentName, methodId));
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

  Future<void> _loadSessionCatalogs(List<ChatController> controllers) async {
    final loadable = controllers
        .where(
          (controller) =>
              controller.canListSessions &&
              !controller.isStreaming &&
              !controller.isSessionOperationRunning,
        )
        .toList(growable: false);
    if (loadable.isEmpty) return;

    final errors = <Object>[];
    await Future.wait(
      loadable.map((controller) async {
        try {
          await controller.loadSessionCatalog();
        } catch (error) {
          errors.add(error);
        }
      }),
    );

    if (errors.length == loadable.length) throw errors.first;
  }

  Future<List<AcpProjectSessions>> _loadResumableSessions(
    List<ChatController> controllers,
  ) async {
    final loadable = controllers
        .where(
          (controller) =>
              controller.canListSessions &&
              !controller.isStreaming &&
              !controller.isSessionOperationRunning,
        )
        .toList(growable: false);
    if (loadable.isEmpty) {
      throw StateError('No configured ACP agent can list resumable sessions.');
    }

    final errors = <Object>[];
    final sessions = <AcpSessionEntry>[];
    await Future.wait(
      loadable.map((controller) async {
        try {
          final projects = await controller.listResumableSessions();
          for (final project in projects) {
            final fallbackCwd = normalizeWorkspacePath(project.cwd);
            for (final session in project.sessions) {
              final sessionCwd = normalizeWorkspacePath(session.cwd);
              sessions.add(
                AcpSessionEntry(
                  id: session.id,
                  cwd: sessionCwd.isEmpty ? fallbackCwd : sessionCwd,
                  title: session.title,
                  additionalDirectories: session.additionalDirectories,
                  updatedAt: session.updatedAt,
                  meta: <String, Object?>{
                    ...session.meta,
                    resumeSessionAgentNameMetaKey: controller.agentName,
                  },
                ),
              );
            }
          }
        } catch (error) {
          errors.add(error);
        }
      }),
    );

    if (sessions.isEmpty) {
      if (errors.isNotEmpty) throw errors.first;
      return const <AcpProjectSessions>[];
    }
    return groupAcpSessionsByProject(sessions);
  }

  ChatController? _controllerForAgentName(
    List<ChatController> controllers,
    String? agentName,
  ) {
    final trimmed = agentName?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    for (final controller in controllers) {
      if (controller.agentName == trimmed) return controller;
    }
    return null;
  }

  List<String> _agentNamesForTasks() {
    final names = <String>{};
    final active = agentName.trim();
    if (active.isNotEmpty) names.add(active);
    for (final server in agentServers) {
      final name = server.name.trim();
      if (name.isNotEmpty) names.add(name);
    }
    final sorted = names.toList()..sort();
    return sorted;
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
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AgentConfigDialog(
          agentServers: agentServers,
          agentPresets: AcpAgentDiscovery.discover(),
          mcpServers: mcpServers,
          additionalDirectories: additionalDirectories,
          clientProviders: clientProviders,
          activeAgentName: agentName,
          configPath: configPath,
          defaultAgentName: defaultAgentName,
          onSaveConfig: onSaveConfig,
        );
      },
    );
  }

  Future<void> _showProtocolFeatureReviewDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return ProtocolFeatureReviewDialog(
          controller: controller,
          agentServers: agentServers,
          mcpServers: mcpServers,
          additionalDirectories: additionalDirectories,
          clientProviders: clientProviders,
          configPath: configPath,
        );
      },
    );
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

  Future<void> _showResumeDialog(BuildContext context) async {
    final sessionControllerList = _controllers();
    final selection = await showDialog<ResumeSessionSelection>(
      context: context,
      builder: (context) => ResumeSessionDialog(
        inputBudget: inputBudget,
        loadSessions: () => _loadResumableSessions(sessionControllerList),
        initialCwd: controller.currentSession?.cwd ?? controller.cwd,
      ),
    );

    if (selection == null) return;
    if (!context.mounted) return;
    final selectedSession = AgentSession(
      id: selection.conversation.id,
      cwd: selection.conversation.cwd,
      createdAt:
          selection.conversation.updatedAt ??
          DateTime.fromMillisecondsSinceEpoch(0),
      additionalDirectories: selection.conversation.additionalDirectories,
      title: selection.conversation.title,
      updatedAt: selection.conversation.updatedAt,
      agentName: _resumeSelectionAgentName(selection),
    );
    final selectedAgentName = selectedSession.agentName?.trim();
    final trustedTargetController = _controllerForAgentName(
      sessionControllerList,
      selectedSession.agentName,
    );
    final externalSelectSession = onSelectSession;
    final conflictController =
        trustedTargetController ??
        (externalSelectSession == null ||
                selectedAgentName == null ||
                selectedAgentName.isEmpty
            ? controller
            : null);
    if (conflictController?.hasBoundSessionWorkspaceConflict(selectedSession) ==
        true) {
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

    final targetController = trustedTargetController ?? controller;
    final activeSession = targetController.currentSession;
    if (activeSession != null &&
        activeSession.id.trim() == selectedSession.id.trim()) {
      return;
    }

    final approved = await showSessionWorkspaceReviewDialog(
      context,
      selectedSession,
    );
    if (!approved || !context.mounted) return;

    unawaited(
      targetController.resumeSession(
        selectedSession.id,
        cwd: selectedSession.cwd,
        additionalDirectories: selectedSession.additionalDirectories,
        title: selectedSession.title,
        updatedAt: selectedSession.updatedAt,
      ),
    );
  }

  String? _resumeSelectionAgentName(ResumeSessionSelection selection) {
    final agentName =
        selection.conversation.meta[resumeSessionAgentNameMetaKey];
    if (agentName is! String) return null;
    final trimmed = agentName.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _ShellSidebar extends StatefulWidget {
  const _ShellSidebar({
    required this.workspaceSidebar,
    required this.taskInboxController,
    required this.initialMode,
    required this.taskInboxSidebar,
  });

  final Widget workspaceSidebar;
  final TaskInboxController? taskInboxController;
  final AppShellSidebarMode initialMode;
  final Widget? taskInboxSidebar;

  @override
  State<_ShellSidebar> createState() => _ShellSidebarState();
}

class _ShellSidebarState extends State<_ShellSidebar> {
  late AppShellSidebarMode _mode;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
  }

  @override
  void didUpdateWidget(covariant _ShellSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.taskInboxController == null) {
      _mode = AppShellSidebarMode.workspaces;
      return;
    }
    if (oldWidget.taskInboxController == null &&
        widget.initialMode == AppShellSidebarMode.inbox) {
      _mode = AppShellSidebarMode.inbox;
      return;
    }
    if (widget.initialMode != oldWidget.initialMode) {
      _mode = widget.initialMode;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.taskInboxController == null || widget.taskInboxSidebar == null) {
      return widget.workspaceSidebar;
    }

    return Container(
      color: AppColors.surfaceRaised,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
            child: _SidebarModeSwitch(
              selectedMode: _mode,
              onChanged: (mode) {
                setState(() => _mode = mode);
              },
            ),
          ),
          Expanded(
            child: _mode == AppShellSidebarMode.workspaces
                ? widget.workspaceSidebar
                : widget.taskInboxSidebar!,
          ),
        ],
      ),
    );
  }
}

class _SidebarModeSwitch extends StatelessWidget {
  const _SidebarModeSwitch({
    required this.selectedMode,
    required this.onChanged,
  });

  final AppShellSidebarMode selectedMode;
  final ValueChanged<AppShellSidebarMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 32,
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: AppColors.border),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SidebarModeSegment(
                flex: 7,
                mode: AppShellSidebarMode.workspaces,
                selected: selectedMode == AppShellSidebarMode.workspaces,
                icon: Icons.folder_open_rounded,
                label: 'Workspaces',
                onChanged: onChanged,
              ),
              const VerticalDivider(width: 1, color: AppColors.border),
              _SidebarModeSegment(
                flex: 5,
                mode: AppShellSidebarMode.inbox,
                selected: selectedMode == AppShellSidebarMode.inbox,
                icon: Icons.inbox_rounded,
                label: 'Inbox',
                onChanged: onChanged,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SidebarModeSegment extends StatelessWidget {
  const _SidebarModeSegment({
    required this.flex,
    required this.mode,
    required this.selected,
    required this.icon,
    required this.label,
    required this.onChanged,
  });

  final int flex;
  final AppShellSidebarMode mode;
  final bool selected;
  final IconData icon;
  final String label;
  final ValueChanged<AppShellSidebarMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final color = selected ? AppColors.textPrimary : AppColors.textSecondary;
    return Expanded(
      flex: flex,
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: Material(
          color: selected ? AppColors.primarySoft : Colors.transparent,
          child: InkWell(
            onTap: selected ? null : () => onChanged(mode),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, size: 15, color: color),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: color,
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        height: 1,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
      leading: const Icon(Icons.login_rounded, color: AppColors.primaryDark),
      title: Text(
        name,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontWeight: FontWeight.w800,
          letterSpacing: 0,
        ),
      ),
      subtitle: description.isEmpty
          ? null
          : Text(
              description,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
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
