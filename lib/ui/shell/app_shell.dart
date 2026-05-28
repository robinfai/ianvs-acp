import 'dart:async';

import 'package:flutter/material.dart';

import '../../state/chat_controller.dart';
import '../components/agent_toolbar.dart';
import '../components/chat_timeline.dart';
import '../components/error_banner.dart';
import '../components/prompt_input.dart';
import '../components/session_sidebar.dart';
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
                StatusBar(controller: controller),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _showResumeDialog(BuildContext context) async {
    final textController = TextEditingController();
    final sessionId = await showDialog<String>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Resume Codex Session'),
          content: TextField(
            controller: textController,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Session ID',
              hintText: '019e...',
            ),
            onSubmitted: (value) => Navigator.of(context).pop(value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(textController.text),
              child: const Text('Resume'),
            ),
          ],
        );
      },
    );
    textController.dispose();

    if (sessionId == null || sessionId.trim().isEmpty) return;
    if (!context.mounted) return;
    unawaited(controller.resumeSession(sessionId));
  }
}
