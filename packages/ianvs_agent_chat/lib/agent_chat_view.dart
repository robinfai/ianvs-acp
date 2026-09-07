import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'chat_session.dart';
import 'models/chat_message.dart';
import 'models/chat_permission_request.dart';
import 'ui/components/bounded_image_preview.dart';
import 'ui/components/chat_timeline.dart';
import 'ui/components/prompt_input.dart';
import 'ui/image_decode_budget.dart';
import 'ui/tool_presentation/tool_presentation_registry.dart';

typedef ChatPartBuilder =
    Widget Function(BuildContext context, ChatSessionState state, Widget child);

/// Embeddable conversation with no application shell or backend dependency.
class AgentChatView extends StatelessWidget {
  const AgentChatView({
    super.key,
    required this.session,
    this.onTapLink,
    this.onNewSession,
    this.attachmentController,
    this.pickAttachments,
    this.pickAttachmentsForKind,
    this.readClipboardImage,
    this.readDroppedImage,
    this.imageDecodeLedger,
    this.boundedImageDecoder = const DartUiBoundedImageDecoder(),
    this.toolPresentationRegistry,
    this.timelineBuilder,
    this.composerBuilder,
    this.showError = true,
  });
  final ChatSession session;
  final MarkdownTapLinkCallback? onTapLink;
  final VoidCallback? onNewSession;
  final PromptAttachmentController? attachmentController;
  final PromptAttachmentPicker? pickAttachments;
  final PromptAttachmentKindPicker? pickAttachmentsForKind;
  final PromptImageClipboardReader? readClipboardImage;
  final PromptDroppedImageReader? readDroppedImage;
  final ChatImageDecodeBudgetLedger? imageDecodeLedger;
  final BoundedImageDecoder boundedImageDecoder;
  final ToolPresentationRegistry? toolPresentationRegistry;
  final ChatPartBuilder? timelineBuilder;
  final ChatPartBuilder? composerBuilder;
  final bool showError;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final state = session.state;
      final timeline = ChatTimeline(
        key: ValueKey(('timeline', state.identity)),
        messages: state.messages,
        messageListRevision: state.messagesRevision,
        agentName: state.agentName,
        hasActiveSession: state.hasSession,
        activeSessionLabel: state.title,
        isLoadingSession: state.isLoading,
        showNewSessionAction: onNewSession != null,
        onNewSession: onNewSession,
        onTapLink: onTapLink,
        inputBudget: state.inputBudget,
        imageDecodeLedger: imageDecodeLedger,
        boundedImageDecoder: boundedImageDecoder,
        toolPresentationRegistry: toolPresentationRegistry,
      );
      final composer = PromptInput(
        key: ValueKey(('composer', state.identity)),
        agentName: state.agentName,
        enabled: state.enabled,
        isSending: state.isSending,
        promptAppearsStalled: state.promptAppearsStalled,
        inputBudget: state.inputBudget,
        availableCommands: state.commands,
        availableCommandsRevision: state.commandsRevision,
        promptCapabilities: state.capabilities.prompt,
        showAttachmentControl: state.capabilities.attachments,
        showExecutionPolicy: state.capabilities.executionPolicy,
        canQueueWhileSending: state.capabilities.queue,
        pendingPermissionRequest: state.capabilities.permissions
            ? state.permission
            : null,
        onAllowPermission: () => _run(
          context,
          () => session.resolvePermission(ChatPermissionDecision.allow),
        ),
        onDenyPermission: () => _run(
          context,
          () => session.resolvePermission(ChatPermissionDecision.deny),
        ),
        onCancelPermission: () => _run(
          context,
          () => session.resolvePermission(ChatPermissionDecision.cancel),
        ),
        onSelectPermissionOption: (id) =>
            _run(context, () => session.selectPermissionOption(id)),
        toolCallExecutionPolicy: state.executionPolicy,
        hasPermissionReviewer: state.hasPermissionReviewer,
        onToolCallExecutionPolicyChanged: state.capabilities.executionPolicy
            ? session.setExecutionPolicy
            : null,
        configOptions: state.configOptions,
        onConfigOptionSelected: (id, value) =>
            _run(context, () => session.setConfigOption(id, value)),
        promptHistory: [
          for (final m in state.messages)
            if (m.role == ChatMessageRole.user && m.text.trim().isNotEmpty)
              m.text,
        ],
        queuedPrompts: state.queuedPrompts,
        onGuideQueuedPrompt: session.guideQueuedPrompt,
        onRemoveQueuedPrompt: session.removeQueuedPrompt,
        onClearQueuedPrompts: session.clearQueuedPrompts,
        onReorderQueuedPrompt: session.reorderQueuedPrompt,
        workspaceRoots: state.workspaceRoots,
        imageAttachmentLimitation: state.imageAttachmentLimitation,
        attachmentController: attachmentController,
        pickAttachments: pickAttachments,
        pickAttachmentsForKind: pickAttachmentsForKind,
        readClipboardImage: readClipboardImage ?? emptyClipboardImage,
        readDroppedImage: readDroppedImage ?? readDroppedImageAttachment,
        onSend: (text, attachments) =>
            _run(context, () => session.send(text, attachments: attachments)),
        onStop: () => _run(context, session.stop),
      );
      return Column(
        children: [
          if (showError && state.error != null)
            MaterialBanner(
              content: Text(state.error!),
              actions: [
                TextButton(
                  onPressed: () => _run(context, session.stop),
                  child: const Text('Stop'),
                ),
              ],
            ),
          Expanded(
            child: timelineBuilder?.call(context, state, timeline) ?? timeline,
          ),
          composerBuilder?.call(context, state, composer) ?? composer,
        ],
      );
    },
  );

  void _run(BuildContext context, Future<void> Function() action) {
    unawaited(() async {
      try {
        await action();
      } catch (error) {
        if (context.mounted) {
          ScaffoldMessenger.maybeOf(
            context,
          )?.showSnackBar(SnackBar(content: Text('$error')));
        }
      }
    }());
  }
}
