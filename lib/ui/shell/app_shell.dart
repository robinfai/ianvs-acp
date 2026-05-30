import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/agent_session.dart';
import '../../config/acp_client_config.dart';
import '../../state/chat_controller.dart';
import '../components/agent_config_dialog.dart';
import '../components/agent_toolbar.dart';
import '../components/capabilities_dialog.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/prompt_input.dart';
import '../components/resume_session_dialog.dart';
import '../components/session_sidebar.dart';
import '../components/session_settings_dialog.dart';
import '../components/status_bar.dart';
import '../theme/app_design_tokens.dart';

class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.controller,
    this.agentName = 'Codex',
    this.agentServers = const <AgentServerConfig>[],
    this.mcpServers = const <McpServerConfig>[],
    this.configPath,
    this.defaultAgentName,
    this.startupError,
    this.canSwitchAgent = true,
    this.onSelectAgent,
    this.onSelectSession,
    this.onNewSession,
    this.sessionControllers = const <ChatController>[],
  });

  final ChatController controller;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final String? configPath;
  final String? defaultAgentName;
  final String? startupError;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final ValueChanged<AgentSession>? onSelectSession;
  final void Function(BuildContext context)? onNewSession;
  final List<ChatController> sessionControllers;

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
                  onAuthenticate: controller.canAuthenticate
                      ? () => unawaited(_showAuthenticateDialog(context))
                      : null,
                  onLogout: controller.canLogout
                      ? () => unawaited(_confirmLogout(context))
                      : null,
                  onNewSession: startNewSession,
                  onResumeSession: sessionActionsEnabled
                      ? () => _showResumeDialog(context)
                      : null,
                  onReconnect: sessionActionsEnabled
                      ? controller.reconnect
                      : null,
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
                      child: Row(
                        children: [
                          SizedBox(
                            width: 244,
                            child: SessionSidebar(
                              agentName: agentName,
                              sessions: _sessions(),
                              currentSession: controller.currentSession,
                              onNewSession: startNewSession,
                              onResumeSession: sessionActionsEnabled
                                  ? () => _showResumeDialog(context)
                                  : null,
                              onSelectSession: sessionActionsEnabled
                                  ? onSelectSession
                                  : null,
                            ),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppColors.border,
                          ),
                          Expanded(
                            child: ChatTimeline(
                              messages: controller.messages,
                              agentName: agentName,
                              hasActiveSession:
                                  controller.currentSession != null,
                              activeSessionLabel:
                                  controller.currentSession?.displayTitle,
                              onNewSession: startNewSession,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                PromptInput(
                  agentName: agentName,
                  isSending: controller.isStreaming,
                  availableCommands: controller.availableCommands,
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

  List<AgentSession> _sessions() {
    final controllers = sessionControllers.isEmpty
        ? <ChatController>[controller]
        : sessionControllers;
    final sessions = <AgentSession>[
      for (final controller in controllers) ...controller.sessions,
    ];
    sessions.sort((a, b) => b.displayTime.compareTo(a.displayTime));
    return sessions;
  }

  Future<void> _showAgentConfigDialog(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AgentConfigDialog(
          agentServers: agentServers,
          mcpServers: mcpServers,
          activeAgentName: agentName,
          configPath: configPath,
          defaultAgentName: defaultAgentName,
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
        loadSessions: controller.listSessions,
        initialCwd: controller.currentSession?.cwd ?? controller.cwd,
      ),
    );

    if (selection == null) return;
    if (!context.mounted) return;
    unawaited(
      controller.resumeSession(
        selection.conversation.id,
        cwd: selection.project.cwd,
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
