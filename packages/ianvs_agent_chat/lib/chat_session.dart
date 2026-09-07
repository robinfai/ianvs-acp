import 'package:flutter/foundation.dart';

import 'models/chat_capabilities.dart';
import 'models/chat_input_budget.dart';
import 'models/chat_message.dart';
import 'models/chat_permission_request.dart';
import 'models/chat_session_settings.dart';
import 'models/prompt_attachment.dart';

/// Features advertised by a particular conversation, not assumed from a brand.
class ChatCapabilities {
  const ChatCapabilities({
    this.prompt = const ChatPromptCapabilities(
      image: false,
      audio: false,
      embeddedContext: false,
    ),
    this.attachments = false,
    this.tools = false,
    this.permissions = false,
    this.executionPolicy = false,
    this.queue = false,
    this.restore = false,
  });
  final ChatPromptCapabilities prompt;
  final bool attachments;
  final bool tools;
  final bool permissions;
  final bool executionPolicy;
  final bool queue;
  final bool restore;
}

/// One atomic visible snapshot. Hosts keep replay staging and persistence out
/// of the widget tree. Bump [messagesRevision] on in-place transcript updates.
class ChatSessionState {
  const ChatSessionState({
    required this.identity,
    required this.agentName,
    required this.messages,
    this.title,
    this.hasSession = true,
    this.isLoading = false,
    this.enabled = true,
    this.isSending = false,
    this.promptAppearsStalled = false,
    this.messagesRevision = 0,
    this.capabilities = const ChatCapabilities(),
    this.commands = const [],
    this.commandsRevision = 0,
    this.permission,
    this.executionPolicy = ChatToolCallExecutionPolicy.defaultPermissions,
    this.hasPermissionReviewer = false,
    this.configOptions = const [],
    this.queuedPrompts = const [],
    this.workspaceRoots = const [],
    this.imageAttachmentLimitation,
    this.error,
    this.inputBudget = const ChatInputBudget(),
  });
  final Object identity;
  final String agentName;
  final String? title;
  final List<ChatMessageView> messages;
  final bool hasSession;
  final bool isLoading;
  final bool enabled;
  final bool isSending;
  final bool promptAppearsStalled;
  final int messagesRevision;
  final ChatCapabilities capabilities;
  final List<Map<String, Object?>> commands;
  final int commandsRevision;
  final ChatPermissionRequest? permission;
  final ChatToolCallExecutionPolicy executionPolicy;
  final bool hasPermissionReviewer;
  final List<ChatConfigOption> configOptions;
  final List<ChatQueuedPrompt> queuedPrompts;
  final List<String> workspaceRoots;
  final String? imageAttachmentLimitation;
  final String? error;
  final ChatInputBudget inputBudget;
}

/// A session is owned by the host. Widgets only subscribe/unsubscribe; they
/// never close agent connections, destroy history, or dispose this object.
abstract class ChatSession implements Listenable {
  ChatSessionState get state;
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  });
  Future<void> stop();
  Future<void> resolvePermission(ChatPermissionDecision decision) async {
    throw UnsupportedError('Permission requests are unavailable.');
  }

  Future<void> selectPermissionOption(String optionId) async {
    throw UnsupportedError('Permission options are unavailable.');
  }

  Future<void> setConfigOption(String id, Object value) async {
    throw UnsupportedError('Session configuration is unavailable.');
  }

  void setExecutionPolicy(ChatToolCallExecutionPolicy policy) {
    throw UnsupportedError('Execution policy is host-owned.');
  }

  void guideQueuedPrompt(int id) {}
  void removeQueuedPrompt(int id) {}
  void clearQueuedPrompts() {}
  void reorderQueuedPrompt(int oldIndex, int newIndex) {}
}
