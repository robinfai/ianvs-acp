import 'dart:async';

import 'package:flutter/material.dart';

import '../../acp/acp_permission_request.dart';
import '../../acp/agent_session.dart';
import '../../config/acp_agent_discovery.dart';
import '../../config/acp_client_config.dart';
import '../../memory/memory_config.dart';
import '../../memory/memory_runtime_status.dart';
import '../../state/chat_controller.dart';
import '../../state/connection_state.dart';
import '../components/agent_config_dialog.dart';
import '../components/agent_toolbar.dart';
import '../components/capabilities_dialog.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/extension_request_dialog.dart';
import '../components/memory_explorer_page.dart';
import '../components/permission_history_dialog.dart';
import '../components/prompt_input.dart';
import '../components/protocol_feature_review_dialog.dart';
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
    this.additionalDirectories = const <String>[],
    this.clientProviders = const AcpClientProviderConfig(),
    this.memory = const MemoryConfig(),
    this.configPath,
    this.defaultAgentName,
    this.startupError,
    this.memoryStatus = MemoryRuntimeStatus.disabled,
    this.memoryPendingCount = 0,
    this.memoryPendingChangeRequestCount = 0,
    this.memoryAutomationNotice,
    this.memoryExplorerActions,
    this.canSwitchAgent = true,
    this.onSelectAgent,
    this.onSelectSession,
    this.onNewSession,
    this.onSaveConfig,
    this.sessionControllers = const <ChatController>[],
  });

  final ChatController controller;
  final String agentName;
  final List<AgentServerConfig> agentServers;
  final List<McpServerConfig> mcpServers;
  final List<String> additionalDirectories;
  final AcpClientProviderConfig clientProviders;
  final MemoryConfig memory;
  final String? configPath;
  final String? defaultAgentName;
  final String? startupError;
  final MemoryRuntimeStatus memoryStatus;
  final int memoryPendingCount;
  final int memoryPendingChangeRequestCount;
  final MemoryAutomationNotice? memoryAutomationNotice;
  final MemoryExplorerActions? memoryExplorerActions;
  final bool canSwitchAgent;
  final ValueChanged<String>? onSelectAgent;
  final ValueChanged<AgentSession>? onSelectSession;
  final void Function(BuildContext context)? onNewSession;
  final AcpConfigSaveCallback? onSaveConfig;
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
        final canReconnect =
            sessionActionsEnabled &&
            (controller.status == ConnectionStatus.disconnected ||
                controller.status == ConnectionStatus.error);

        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                _MemoryReviewPromptNotifier(
                  pendingCount: memoryPendingCount,
                  pendingChangeRequestCount: memoryPendingChangeRequestCount,
                  automationNotice: memoryAutomationNotice,
                  autoOpen: memory.review.autoOpen,
                  canOpen: memory.enabled && memoryExplorerActions != null,
                  onReview: (initialTab) => unawaited(
                    _showMemoryExplorerPage(context, initialTab: initialTab),
                  ),
                ),
                AgentToolbar(
                  agentName: agentName,
                  agentServers: agentServers,
                  status: controller.status,
                  canSwitchAgent: canSwitchAgent && sessionActionsEnabled,
                  onSelectAgent: onSelectAgent,
                  onShowAgentConfig: () => _showAgentConfigDialog(context),
                  onShowProtocolCoverage: () =>
                      _showProtocolFeatureReviewDialog(context),
                  onShowMemoryExplorer: () => _showMemoryExplorerPage(context),
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
                          final hideSidebar = constraints.maxWidth < 700;
                          final timeline = ChatTimeline(
                            messages: controller.messages,
                            agentName: agentName,
                            hasActiveSession: controller.currentSession != null,
                            activeSessionLabel:
                                controller.currentSession?.displayTitle,
                            onNewSession: startNewSession,
                            onMemoryFeedback: controller.submitMemoryFeedback,
                          );

                          if (hideSidebar) return timeline;

                          return Row(
                            children: [
                              SizedBox(
                                width: 244,
                                child: SessionSidebar(
                                  agentName: agentName,
                                  sessions: _sessions(),
                                  currentSession: controller.currentSession,
                                  onNewSession: startNewSession,
                                  onResumeSession: controller.canResumeSessions
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
                              Expanded(child: timeline),
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
                  memoryStatus: memoryStatus,
                  memoryPendingCount: memoryPendingCount,
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

  Future<void> _showMemoryExplorerPage(
    BuildContext context, {
    MemoryExplorerInitialTab initialTab = MemoryExplorerInitialTab.allMemory,
  }) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => MemoryExplorerPage(
          actions: memoryExplorerActions,
          initialTab: initialTab,
        ),
      ),
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
    final detectedAgentServers = AcpAgentDiscovery.discoverMissing(
      AcpClientConfig(
        agentServers: agentServers,
        defaultAgentServerName: defaultAgentName,
        configPath: configPath,
      ),
    );
    await showDialog<void>(
      context: context,
      builder: (context) {
        return AgentConfigDialog(
          agentServers: agentServers,
          detectedAgentServers: detectedAgentServers,
          mcpServers: mcpServers,
          additionalDirectories: additionalDirectories,
          clientProviders: clientProviders,
          memory: memory,
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

class MemoryAutomationNotice {
  const MemoryAutomationNotice({
    required this.sequence,
    this.approvedCandidates = 0,
    this.pendingCandidateReviews = 0,
    this.autoAppliedChangeRequests = 0,
    this.maintenanceAutoApplied = 0,
    this.maintenanceNeedsReview = 0,
    this.maintenanceSkipped = 0,
    this.maintenanceAutoRejectedCandidates = 0,
    this.maintenanceAutoRejectedChangeRequests = 0,
  });

  final int sequence;
  final int approvedCandidates;
  final int pendingCandidateReviews;
  final int autoAppliedChangeRequests;
  final int maintenanceAutoApplied;
  final int maintenanceNeedsReview;
  final int maintenanceSkipped;
  final int maintenanceAutoRejectedCandidates;
  final int maintenanceAutoRejectedChangeRequests;

  int get autoApplied =>
      approvedCandidates + autoAppliedChangeRequests + maintenanceAutoApplied;

  int get needsReview => pendingCandidateReviews + maintenanceNeedsReview;

  int get autoCleaned =>
      maintenanceAutoRejectedCandidates + maintenanceAutoRejectedChangeRequests;

  bool get shouldPrompt =>
      autoApplied > 0 || needsReview > 0 || autoCleaned > 0;

  MemoryExplorerInitialTab initialReviewTab(int pendingCount) {
    if (maintenanceNeedsReview > 0 ||
        autoAppliedChangeRequests > 0 ||
        maintenanceAutoApplied > 0 ||
        maintenanceAutoRejectedChangeRequests > 0) {
      return MemoryExplorerInitialTab.changeRequests;
    }
    if (pendingCandidateReviews > 0 ||
        approvedCandidates > 0 ||
        maintenanceAutoRejectedCandidates > 0 ||
        pendingCount > 0) {
      return MemoryExplorerInitialTab.candidates;
    }
    return MemoryExplorerInitialTab.allMemory;
  }

  String get label {
    final parts = <String>[];
    if (autoApplied > 0) {
      final suffix = autoApplied == 1 ? 'change' : 'changes';
      parts.add('$autoApplied memory $suffix auto applied');
    }
    if (needsReview > 0) {
      final suffix = needsReview == 1 ? 'needs review' : 'need review';
      parts.add('$needsReview $suffix');
    }
    if (autoCleaned > 0) {
      final suffix = autoCleaned == 1 ? 'review' : 'reviews';
      parts.add('$autoCleaned memory $suffix cleaned');
    }
    if (parts.isEmpty && maintenanceSkipped > 0) {
      parts.add('$maintenanceSkipped skipped');
    }
    return parts.join(' · ');
  }
}

class _MemoryReviewPromptNotifier extends StatefulWidget {
  const _MemoryReviewPromptNotifier({
    required this.pendingCount,
    required this.pendingChangeRequestCount,
    required this.automationNotice,
    required this.autoOpen,
    required this.canOpen,
    required this.onReview,
  });

  final int pendingCount;
  final int pendingChangeRequestCount;
  final MemoryAutomationNotice? automationNotice;
  final String autoOpen;
  final bool canOpen;
  final ValueChanged<MemoryExplorerInitialTab> onReview;

  @override
  State<_MemoryReviewPromptNotifier> createState() =>
      _MemoryReviewPromptNotifierState();
}

class _MemoryReviewPromptNotifierState
    extends State<_MemoryReviewPromptNotifier> {
  late int _lastPendingCount;
  int? _lastAutomationNoticeSequence;

  @override
  void initState() {
    super.initState();
    _lastPendingCount = widget.pendingCount;
  }

  @override
  void didUpdateWidget(covariant _MemoryReviewPromptNotifier oldWidget) {
    super.didUpdateWidget(oldWidget);
    final countIncreased = widget.pendingCount > _lastPendingCount;
    _lastPendingCount = widget.pendingCount;
    final notice = widget.automationNotice;
    if (notice != null &&
        notice.shouldPrompt &&
        notice.sequence != _lastAutomationNoticeSequence &&
        _canPrompt(widget)) {
      _lastAutomationNoticeSequence = notice.sequence;
      _schedulePrompt(
        notice.label,
        noticeSequence: notice.sequence,
        initialTab: notice.initialReviewTab(widget.pendingCount),
      );
      return;
    }
    if (!countIncreased || widget.pendingCount <= 0 || !_canPrompt(widget)) {
      return;
    }
    _schedulePrompt(
      '${widget.pendingCount} memory reviews pending',
      pendingCount: widget.pendingCount,
      initialTab: widget.pendingChangeRequestCount > 0
          ? MemoryExplorerInitialTab.changeRequests
          : MemoryExplorerInitialTab.candidates,
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  bool _canPrompt(_MemoryReviewPromptNotifier widget) {
    final autoOpen = widget.autoOpen.trim().toLowerCase();
    return widget.canOpen &&
        autoOpen != 'never' &&
        autoOpen != 'off' &&
        autoOpen != 'false';
  }

  void _schedulePrompt(
    String message, {
    int? pendingCount,
    int? noticeSequence,
    MemoryExplorerInitialTab initialTab = MemoryExplorerInitialTab.allMemory,
  }) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (pendingCount != null && widget.pendingCount != pendingCount) {
        return;
      }
      if (noticeSequence != null &&
          widget.automationNotice?.sequence != noticeSequence) {
        return;
      }
      if (!_canPrompt(widget)) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      if (messenger == null) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: 'Review',
            onPressed: () => widget.onReview(initialTab),
          ),
        ),
      );
    });
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
