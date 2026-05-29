import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';
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
  const AppShell({super.key, required this.controller});

  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          backgroundColor: AppColors.bg,
          body: SafeArea(
            child: Column(
              children: [
                AgentToolbar(
                  status: controller.status,
                  onNewSession: controller.newSession,
                  onResumeSession: () => _showResumeDialog(context),
                  onReconnect: controller.reconnect,
                ),
                if (controller.lastError != null)
                  ErrorBanner(message: controller.lastError!),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: AppColors.border),
                        boxShadow: AppShadows.soft,
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 308,
                            child: SessionSidebar(
                              sessions: controller.sessions,
                              currentSession: controller.currentSession,
                              onNewSession: controller.newSession,
                            ),
                          ),
                          const VerticalDivider(
                            width: 1,
                            color: AppColors.border,
                          ),
                          Expanded(
                            child: ChatTimeline(messages: controller.messages),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                PromptInput(
                  isSending: controller.isStreaming,
                  onSend: controller.sendPrompt,
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
      ),
    );
  }
}
