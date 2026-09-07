import 'package:ianvs_agent_chat/chat_session.dart';
import 'package:ianvs_agent_chat/models/chat_capabilities.dart';
import 'package:ianvs_agent_chat/models/chat_permission_request.dart';
import 'package:ianvs_agent_chat/models/prompt_attachment.dart';
import 'package:flutter/foundation.dart';

import '../acp/acp_prompt_capability_policy.dart';
import '../state/chat_controller.dart';

/// Zero-copy bridge over the existing ACP controller. The application retains
/// controller ownership, replay transactions, queueing, permissions and cache.
class AcpChatSession extends ChatSession {
  AcpChatSession(this.controller);
  final ChatController controller;

  @override
  void addListener(VoidCallback listener) => controller.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      controller.removeListener(listener);

  @override
  ChatSessionState get state {
    final active = controller.currentSession;
    final resolution = resolvePromptCapabilitiesForSession(
      advertised: controller.capabilities?.prompt,
      settings: controller.sessionSettings,
      agentName: controller.agentName,
      agentInfo: controller.capabilities?.agentInfo ?? const {},
    );
    return ChatSessionState(
      identity: (
        controller.agentName,
        active?.id,
        active?.cwd ?? controller.cwd,
      ),
      agentName: controller.agentName,
      title: active?.displayTitle,
      messages: controller.visibleMessages,
      messagesRevision: controller.messagesRevision,
      hasSession: active != null,
      isLoading: controller.isSessionReplayLoading,
      enabled: !controller.isSessionOperationRunning,
      isSending: controller.isStreaming,
      promptAppearsStalled: controller.promptAppearsStalled,
      capabilities: ChatCapabilities(
        prompt:
            resolution.capabilities ??
            const ChatPromptCapabilities(
              image: false,
              audio: false,
              embeddedContext: false,
            ),
        attachments: true,
        tools: true,
        permissions: true,
        executionPolicy: true,
        queue: true,
        restore: controller.capabilities?.loadSession == true,
      ),
      commands: controller.availableCommands,
      commandsRevision: controller.availableCommandsRevision,
      permission: controller.pendingPermissionRequest,
      executionPolicy: controller.toolCallExecutionPolicy,
      hasPermissionReviewer: controller.hasPermissionReviewer,
      configOptions: controller.sessionSettings.configOptions,
      queuedPrompts: controller.queuedPrompts,
      workspaceRoots: {
        active?.cwd ?? controller.cwd,
        ...?active?.additionalDirectories,
        if (active == null) ...controller.additionalDirectories,
      }.where((path) => path.trim().isNotEmpty).toList(),
      imageAttachmentLimitation: resolution.imageLimitation,
      error: controller.lastError,
      inputBudget: controller.inputBudget,
    );
  }

  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) async {
    await controller.submitOrQueuePrompt(text, attachments: attachments);
  }

  @override
  Future<void> stop() => controller.stop();
  @override
  Future<void> resolvePermission(ChatPermissionDecision decision) =>
      controller.resolvePermissionRequest(decision);
  @override
  Future<void> selectPermissionOption(String optionId) =>
      controller.resolvePermissionOption(optionId);
  @override
  Future<void> setConfigOption(String id, Object value) =>
      controller.setConfigOption(id, value);
  @override
  void setExecutionPolicy(ChatToolCallExecutionPolicy policy) =>
      controller.setToolCallExecutionPolicy(policy);
  @override
  void guideQueuedPrompt(int id) => controller.guideQueuedPrompt(id);
  @override
  void removeQueuedPrompt(int id) => controller.removeQueuedPrompt(id);
  @override
  void clearQueuedPrompts() => controller.clearQueuedPrompts();
  @override
  void reorderQueuedPrompt(int oldIndex, int newIndex) =>
      controller.reorderQueuedPrompt(oldIndex, newIndex);
}
