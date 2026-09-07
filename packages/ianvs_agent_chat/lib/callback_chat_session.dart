import 'package:flutter/foundation.dart';
import 'chat_session.dart';
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
  });
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
