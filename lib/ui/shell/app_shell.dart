import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../acp/acp_input_budget.dart';
import '../../acp/acp_permission_request.dart';
import '../../acp/acp_prompt_capability_policy.dart';
import '../../acp/acp_session_catalog.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../config/acp_agent_discovery.dart';
import '../../config/assistant_agent_config.dart';
import '../../storage/sqlite_storage_config.dart';
import '../../platform/file_manager.dart';
import '../../state/chat_controller.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_controller.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
import '../components/agent_config_dialog.dart';
import '../components/agent_toolbar.dart';
import '../components/bounded_image_preview.dart';
import '../components/capabilities_dialog.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/file_preview_workspace.dart';
import '../components/permission_history_dialog.dart';
import '../components/prompt_input.dart';
import '../components/protocol_feature_review_dialog.dart';
import '../components/resume_session_dialog.dart';
import '../components/session_settings_dialog.dart';
import '../components/session_workspace_review_dialog.dart';
import '../components/workspace_inspector.dart';
import '../components/workspace_sidebar.dart';
import '../image_decode_budget.dart';
import '../theme/app_design_tokens.dart';

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
    this.configPath,
    this.workspaceStateStore,
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
    this.onSaveConfig,
    this.onValidateAssistantAgent,
    this.onLoadSessionCatalogs,
    this.sessionControllers = const <ChatController>[],
    this.processRunner,
    this.inputBudget = const AcpInputBudget(),
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
    this.gitWorkspaceDetector = workspaceSupportsGitWorktrees,
  });

  final ChatController controller;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final SqliteStorageConfig storage;
  final AssistantAgentConfig assistantAgent;
  final String? configPath;
  final WorkspaceSidebarStateStore? workspaceStateStore;
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
  final AcpConfigSaveCallback? onSaveConfig;
  final AssistantAgentValidationCallback? onValidateAssistantAgent;
  final Future<void> Function()? onLoadSessionCatalogs;
  final List<ChatController> sessionControllers;
  final AppShellProcessRunner? processRunner;
  final AcpInputBudget inputBudget;
  final AcpImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;
  final bool Function(String path) gitWorkspaceDetector;

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
        final promptWorkspaceRoots = <String>{
          activeSession?.cwd ?? controller.cwd,
          ...(activeSession?.additionalDirectories ??
              controller.additionalDirectories),
        }.where((path) => path.trim().isNotEmpty).toList(growable: false);
        final promptAttachmentController = PromptAttachmentController();
        Widget promptDock() => PromptInput(
          inputBudget: inputBudget,
          agentName: agentName,
          enabled: !controller.isSessionOperationRunning,
          isSending: controller.isStreaming,
          promptAppearsStalled: controller.promptAppearsStalled,
          availableCommands: controller.availableCommands,
          availableCommandsRevision: controller.availableCommandsRevision,
          promptCapabilities: promptCapabilities,
          workspaceRoots: promptWorkspaceRoots,
          imageAttachmentLimitation: promptCapabilityResolution.imageLimitation,
          queuedPrompts: controller.queuedPrompts,
          onGuideQueuedPrompt: controller.guideQueuedPrompt,
          onRemoveQueuedPrompt: controller.removeQueuedPrompt,
          onClearQueuedPrompts: controller.clearQueuedPrompts,
          onReorderQueuedPrompt: controller.reorderQueuedPrompt,
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
          configOptions: controller.sessionSettings.configOptions,
          onConfigOptionSelected:
              controller.currentSession != null && sessionActionsEnabled
              ? (configId, value) =>
                    unawaited(controller.setConfigOption(configId, value))
              : null,
          onSend: (text, attachments) =>
              controller.submitOrQueuePrompt(text, attachments: attachments),
          onStop: controller.stop,
          attachmentController: promptAttachmentController,
        );

        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                if (startupError != null) ErrorBanner(message: startupError!),
                if (controller.lastError != null)
                  ErrorBanner(message: controller.lastError!),
                Expanded(
                  child: ColoredBox(
                    color: AppColors.surface,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final hideSidebar = constraints.maxWidth < 760;
                        final hideInspector = constraints.maxWidth < 1120;
                        Widget conversationColumn(
                          BuildContext context,
                          FilePreviewLinkHandler onTapLink,
                        ) => PromptAttachmentDropRegion(
                          controller: promptAttachmentController,
                          enabled: !controller.isSessionOperationRunning,
                          promptCapabilities: promptCapabilities,
                          child: Column(
                            children: [
                              AgentToolbar(
                                title:
                                    controller.currentSession?.displayTitle ??
                                    currentWorkspace.name,
                                agentName: agentName,
                                agentServers: agentServers,
                                status: controller.status,
                                forceFullActions: constraints.maxWidth >= 1120,
                                canSwitchAgent:
                                    canSwitchAgent && sessionActionsEnabled,
                                onSelectAgent: onSelectAgent,
                                onShowAgentConfig: () =>
                                    _showAgentConfigDialog(context),
                                onShowProtocolCoverage: () =>
                                    _showProtocolFeatureReviewDialog(context),
                                onAuthenticate: controller.canAuthenticate
                                    ? () => unawaited(
                                        _showAuthenticateDialog(context),
                                      )
                                    : null,
                                onShowPermissionHistory: () =>
                                    _showPermissionHistoryDialog(context),
                                onLogout: controller.canLogout
                                    ? () => unawaited(_confirmLogout(context))
                                    : null,
                                currentSession: controller.currentSession,
                                canForkSession:
                                    controller.currentSession != null &&
                                    (canForkSession?.call(
                                          controller.currentSession!,
                                        ) ??
                                        false),
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
                                onResumeSession: canResumeSessions
                                    ? () => _showResumeDialog(context)
                                    : null,
                                onReconnect: canReconnect
                                    ? controller.reconnect
                                    : null,
                              ),
                              Expanded(
                                child: ChatTimeline(
                                  key: ValueKey(
                                    'chat-timeline-${controller.currentSession?.id ?? 'empty'}',
                                  ),
                                  inputBudget: inputBudget,
                                  imageDecodeLedger: imageDecodeLedger,
                                  boundedImageDecoder: boundedImageDecoder,
                                  messages: controller.visibleMessages,
                                  messageListRevision:
                                      controller.messagesRevision,
                                  agentName: agentName,
                                  hasActiveSession:
                                      controller.currentSession != null,
                                  activeSessionLabel:
                                      controller.currentSession?.displayTitle,
                                  isLoadingSession:
                                      controller.isSessionReplayLoading,
                                  // In compact windows the toolbar collapses the
                                  // action to an unlabeled icon. Keep one explicit
                                  // entry point next to the empty-state guidance.
                                  showNewSessionAction:
                                      constraints.maxWidth < 1120,
                                  onNewSession: constraints.maxWidth < 1120
                                      ? startNewSession
                                      : null,
                                  onTapLink: onTapLink,
                                ),
                              ),
                              promptDock(),
                            ],
                          ),
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
                            sessionSettings: controller.sessionSettings,
                            sessionUsage: controller.sessionUsage,
                            lastLatency: controller.lastLatency,
                            onConfigOptionSelected:
                                controller.currentSession != null &&
                                    sessionActionsEnabled
                                ? (configId, value) => unawaited(
                                    controller.setConfigOption(configId, value),
                                  )
                                : null,
                            onShowSessionSettings: () =>
                                _showSessionSettingsDialog(context),
                            onShowCapabilities: () =>
                                _showCapabilitiesDialog(context),
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
                                width: 312,
                                child: _ShellSidebar(
                                  agentName: agentName,
                                  workspaceSidebar: WorkspaceSidebar(
                                    agentName: agentName,
                                    workspaces: workspaceController.workspaces,
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
                                            final loader =
                                                onLoadSessionCatalogs;
                                            if (loader != null) {
                                              await loader();
                                            } else {
                                              await _loadSessionCatalogs(
                                                sessionControllerList,
                                              );
                                            }
                                          }
                                        : null,
                                    onRevealWorkspace: (workspace) => unawaited(
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
                                    gitWorkspaceDetector: gitWorkspaceDetector,
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
    await controller.authenticate(methodId);
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
          storage: storage,
          assistantAgent: assistantAgent,
          activeAgentName: agentName,
          configPath: configPath,
          defaultAgentName: defaultAgentName,
          onSaveConfig: onSaveConfig,
          onValidateAssistantAgent: onValidateAssistantAgent,
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

  String? _resumeSelectionAgentName(ResumeSessionSelection selection) {
    final agentName =
        selection.conversation.meta[resumeSessionAgentNameMetaKey];
    if (agentName is! String) return null;
    final trimmed = agentName.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

class _ShellSidebar extends StatelessWidget {
  const _ShellSidebar({
    required this.agentName,
    required this.workspaceSidebar,
  });

  final String agentName;
  final Widget workspaceSidebar;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.bg,
      child: Column(
        children: [
          _SidebarBrandHeader(agentName: agentName),
          Expanded(child: workspaceSidebar),
        ],
      ),
    );
  }
}

class _SidebarBrandHeader extends StatelessWidget {
  const _SidebarBrandHeader({required this.agentName});

  final String agentName;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Text(
            'ACP Client',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: 0,
            ),
          ),
          if (agentName != 'Codex') ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                agentName,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ],
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
