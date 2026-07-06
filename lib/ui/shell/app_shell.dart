import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../platform/file_manager.dart';
import '../../state/chat_controller.dart';
import '../../state/connection_state.dart';
import '../../state/workspace_controller.dart';
import '../../workspace/workspace.dart';
import '../../workspace/workspace_sidebar_state_store.dart';
import '../components/agent_config_dialog.dart';
import '../components/agent_toolbar.dart';
import '../components/capabilities_dialog.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/extension_request_dialog.dart';
import '../components/permission_history_dialog.dart';
import '../components/prompt_input.dart';
import '../components/protocol_feature_review_dialog.dart';
import '../components/resume_session_dialog.dart';
import '../components/session_settings_dialog.dart';
import '../components/status_bar.dart';
import '../components/workspace_header.dart';
import '../components/workspace_inspector.dart';
import '../components/workspace_sidebar.dart';
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
    this.configPath,
    this.defaultAgentName,
    this.startupError,
    this.canSwitchAgent = true,
    this.onSelectAgent,
    this.onSelectSession,
    this.onNewSession,
    this.onNewSessionInWorkspace,
    this.canForkSession,
    this.onSessionMenuAction,
    this.onCreateWorkspaceWorktree,
    this.onArchiveWorkspaceSessions,
    this.onSaveConfig,
    this.sessionControllers = const <ChatController>[],
    this.processRunner,
  });

  final ChatController controller;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final String? configPath;
  final String? defaultAgentName;
  final String? startupError;
  final bool canSwitchAgent;
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
  final List<ChatController> sessionControllers;
  final AppShellProcessRunner? processRunner;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
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
                unawaited(controller.newSession(cwd: workspace.path));
              }
            : null;
        final canReconnect =
            sessionActionsEnabled &&
            (controller.status == ConnectionStatus.disconnected ||
                controller.status == ConnectionStatus.error);
        final workspaceController = WorkspaceController(
          controllers: _controllers(),
          currentWorkspacePath:
              controller.currentSession?.cwd ?? controller.cwd,
          defaultAgentName: agentName,
        );
        final currentWorkspace = workspaceController.currentWorkspace;
        final canLoadWorkspaceSessions =
            controller.supportsSessionList &&
            !controller.isStreaming &&
            !controller.isSessionOperationRunning;
        final workspaceStateStore = WorkspaceSidebarStateStore(
          path: WorkspaceSidebarStateStore.defaultPath(configPath: configPath),
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
                  onResumeSession: controller.canResumeSessions
                      ? () => _showResumeDialog(context)
                      : null,
                  onReconnect: canReconnect ? controller.reconnect : null,
                ),
                if (startupError != null) ErrorBanner(message: startupError!),
                if (controller.lastError != null)
                  ErrorBanner(message: controller.lastError!),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppShadows.soft,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final hideSidebar = constraints.maxWidth < 760;
                          final hideInspector = constraints.maxWidth < 1120;
                          final timeline = ChatTimeline(
                            messages: controller.messages,
                            agentName: agentName,
                            hasActiveSession: controller.currentSession != null,
                            activeSessionLabel:
                                controller.currentSession?.displayTitle,
                            onNewSession: startNewSession,
                          );
                          final conversationColumn = Column(
                            children: [
                              WorkspaceHeader(
                                workspace: currentWorkspace,
                                agentName: agentName,
                                currentSession: controller.currentSession,
                                onNewSession: startNewSession,
                                onResumeSession: controller.canResumeSessions
                                    ? () => _showResumeDialog(context)
                                    : null,
                              ),
                              const Divider(height: 1, color: AppColors.border),
                              Expanded(child: timeline),
                            ],
                          );

                          if (hideSidebar && hideInspector) {
                            return conversationColumn;
                          }

                          return Row(
                            children: [
                              if (!hideSidebar) ...[
                                SizedBox(
                                  width: 286,
                                  child: WorkspaceSidebar(
                                    agentName: agentName,
                                    workspaces: workspaceController.workspaces,
                                    currentWorkspace: currentWorkspace,
                                    currentSession: controller.currentSession,
                                    onNewSession: startNewSession,
                                    onNewSessionInWorkspace:
                                        startNewSessionInWorkspace,
                                    onResumeSession:
                                        controller.canResumeSessions
                                        ? () => _showResumeDialog(context)
                                        : null,
                                    onSelectSession: sessionActionsEnabled
                                        ? onSelectSession
                                        : null,
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
                                            if (controller.isStreaming ||
                                                controller
                                                    .isSessionOperationRunning) {
                                              return;
                                            }
                                            await controller
                                                .loadSessionCatalog();
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
                                  ),
                                ),
                                const VerticalDivider(
                                  width: 1,
                                  color: AppColors.border,
                                ),
                              ],
                              Expanded(child: conversationColumn),
                              if (!hideInspector) ...[
                                const VerticalDivider(
                                  width: 1,
                                  color: AppColors.border,
                                ),
                                SizedBox(
                                  width: 306,
                                  child: WorkspaceInspector(
                                    workspace: currentWorkspace,
                                    agentName: agentName,
                                    currentSession: controller.currentSession,
                                    mcpServers: mcpServers,
                                    additionalDirectories:
                                        additionalDirectories,
                                    clientProviders: clientProviders,
                                    configPath: configPath,
                                  ),
                                ),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
                PromptInput(
                  agentName: agentName,
                  enabled: !controller.isSessionOperationRunning,
                  isSending: controller.isStreaming,
                  availableCommands: controller.availableCommands,
                  promptCapabilities: controller.capabilities?.prompt,
                  pendingPermissionRequest: controller.pendingPermissionRequest,
                  onAllowPermission: () => unawaited(
                    controller.resolvePermissionRequest(
                      AcpPermissionDecision.allow,
                    ),
                  ),
                  onDenyPermission: () => unawaited(
                    controller.resolvePermissionRequest(
                      AcpPermissionDecision.deny,
                    ),
                  ),
                  onCancelPermission: () => unawaited(
                    controller.resolvePermissionRequest(
                      AcpPermissionDecision.cancel,
                    ),
                  ),
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
                      ? (value) => unawaited(
                          controller.setSessionReasoningEffort(value),
                        )
                      : null,
                  onSend: (text, attachments) =>
                      controller.sendPrompt(text, attachments: attachments),
                  onStop: controller.stop,
                ),
                StatusBar(
                  controller: controller,
                  onShowSessionSettings: () =>
                      _showSessionSettingsDialog(context),
                  onShowCapabilities: () => _showCapabilitiesDialog(context),
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
        return CapabilitiesDialog(capabilities: controller.capabilities);
      },
    );
  }

  Future<void> _showExtensionRequestDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return ExtensionRequestDialog(controller: controller);
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
    final controllers = sessionControllers.isEmpty
        ? <ChatController>[controller]
        : sessionControllers;
    return controllers;
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
        return SessionSettingsDialog(controller: controller);
      },
    );
  }

  Future<void> _showResumeDialog(BuildContext context) async {
    final selection = await showDialog<ResumeSessionSelection>(
      context: context,
      builder: (context) => ResumeSessionDialog(
        loadSessions: controller.listResumableSessions,
        initialCwd: controller.currentSession?.cwd ?? controller.cwd,
      ),
    );

    if (selection == null) return;
    if (!context.mounted) return;
    unawaited(
      controller.resumeSession(
        selection.conversation.id,
        cwd: selection.project.cwd,
        additionalDirectories: selection.conversation.additionalDirectories,
        title: selection.conversation.title,
        updatedAt: selection.conversation.updatedAt,
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
