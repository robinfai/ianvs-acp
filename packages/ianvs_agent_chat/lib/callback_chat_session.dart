import 'package:flutter/foundation.dart';
import 'chat_session.dart';
import 'chat_submission.dart';
import 'models/chat_permission_request.dart';
import 'models/prompt_attachment.dart';

/// Adapts an existing ACP/client controller without transferring its ownership.
/// The host projects protocol state once, then reuses the common UI unchanged.
class CallbackChatSession extends ChatSession {
  CallbackChatSession({
    required this.changes,
    required this.readState,
    required this.onSend,
    required this.onStop,
    this.onResolvePermission,
    this.onSelectPermissionOption,
    this.onSetConfigOption,
    this.onSetExecutionPolicy,
    this.onGuideQueuedPrompt,
    this.onRemoveQueuedPrompt,
    this.onClearQueuedPrompts,
    this.onReorderQueuedPrompt,
  });
  final ValueChanged<ChatToolCallExecutionPolicy>? onSetExecutionPolicy;
  final ValueChanged<int>? onGuideQueuedPrompt;
  final ValueChanged<int>? onRemoveQueuedPrompt;
  final VoidCallback? onClearQueuedPrompts;
  final void Function(int, int)? onReorderQueuedPrompt;
  final Listenable changes;
  final ChatSessionState Function() readState;
  final Future<void> Function(String text, List<PromptAttachment> attachments)
  onSend;
  final Future<void> Function() onStop;
  final Future<void> Function(ChatPermissionDecision)? onResolvePermission;
  final Future<void> Function(String)? onSelectPermissionOption;
  final Future<void> Function(String, Object)? onSetConfigOption;
  @override
  ChatSessionState get state => readState();
  @override
  void addListener(VoidCallback listener) => changes.addListener(listener);
  @override
  void removeListener(VoidCallback listener) =>
      changes.removeListener(listener);
  @override
  Future<void> send(
    String text, {
    List<PromptAttachment> attachments = const [],
  }) => onSend(text, attachments);
  @override
  void setExecutionPolicy(ChatToolCallExecutionPolicy policy) =>
      onSetExecutionPolicy != null
      ? onSetExecutionPolicy!(policy)
      : super.setExecutionPolicy(policy);
  @override
  void guideQueuedPrompt(int id) => onGuideQueuedPrompt?.call(id);
  @override
  void removeQueuedPrompt(int id) => onRemoveQueuedPrompt?.call(id);
  @override
  void clearQueuedPrompts() => onClearQueuedPrompts?.call();
  @override
  void reorderQueuedPrompt(int oldIndex, int newIndex) =>
      onReorderQueuedPrompt?.call(oldIndex, newIndex);
  @override
  Future<void> stop() => onStop();
  @override
  Future<void> resolvePermission(ChatPermissionDecision decision) =>
      onResolvePermission?.call(decision) ?? super.resolvePermission(decision);
  @override
  Future<void> selectPermissionOption(String optionId) =>
      onSelectPermissionOption?.call(optionId) ??
      super.selectPermissionOption(optionId);
  @override
  Future<void> setConfigOption(String id, Object value) =>
      onSetConfigOption?.call(id, value) ?? super.setConfigOption(id, value);
}

/// Callback adapter with an explicit admission callback. The legacy adapter
/// continues to use onSend, with its existing completion timing.
class CallbackSubmissionChatSession extends CallbackChatSession
    implements ChatSubmissionSession {
  CallbackSubmissionChatSession({
    required super.changes,
    required super.readState,
    required super.onSend,
    required super.onStop,
    required this.onSubmit,
    super.onResolvePermission,
    super.onSelectPermissionOption,
    super.onSetConfigOption,
    super.onSetExecutionPolicy,
    super.onGuideQueuedPrompt,
    super.onRemoveQueuedPrompt,
    super.onClearQueuedPrompts,
    super.onReorderQueuedPrompt,
  });
  final Future<ChatSubmitResult> Function(ChatSubmission) onSubmit;
  final _submissions = ChatSubmissionLedger();
  @override
  Future<ChatSubmitResult> submit(ChatSubmission submission) =>
      _submissions.submit(submission, () {
        if (submission.sessionIdentity != state.identity) {
          return Future.value(
            const ChatSubmitResult.rejected('The conversation changed.'),
          );
        }
        return onSubmit(submission);
      });
}
