import 'dart:collection';
import 'buffered_chat_message.dart';
import 'models/chat_input_budget.dart';
import 'models/chat_message.dart';

String chatToolCallId(Map<String, Object?> metadata) {
  const keys = ['toolCallId', 'tool_call_id', 'id', 'callId', 'call_id'];
  for (final source in [
    metadata,
    if (metadata['toolCall'] is Map) metadata['toolCall'] as Map,
  ]) {
    for (final key in keys) {
      final value = source[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
  }
  return '';
}

/// Null fields are omissions. Explicit empty collections replace prior values.
Map<String, Object?> mergeChatToolMetadata(
  Map<String, Object?> previous,
  Map<String, Object?> update,
) => Map.unmodifiable({
  ...previous,
  for (final entry in update.entries)
    if (entry.value != null) entry.key: entry.value,
});

int findChatToolMessage(
  List<ChatMessageView> messages,
  String callId, {
  int? turnId,
}) {
  for (var i = messages.length - 1; i >= 0; i--) {
    final message = messages[i];
    if (message.role == ChatMessageRole.user) break;
    if (message.role == ChatMessageRole.tool &&
        (turnId == null || message.turnId == turnId) &&
        chatToolCallId(message.metadata) == callId) {
      return i;
    }
  }
  return -1;
}

class ChatTextAppend {
  const ChatTextAppend({
    required this.target,
    required this.text,
    required this.acceptedUtf8Bytes,
  });
  final ChatMessage target;
  final String text;
  final int acceptedUtf8Bytes;
}

/// Computes an atomic content mutation before any host budget admission. Both
/// native adapters and the app controller use this same retained-size algorithm.
class ChatTextMutation {
  ChatTextMutation._(
    this.parts,
    this.omissionTarget,
    this.omission,
    this.totalDelta,
    this.nextRetained,
    this._revisions,
  );
  factory ChatTextMutation.prepare({
    required List<ChatTextAppend> parts,
    required Map<ChatMessage, int> previousRetained,
    required ChatInputBudget inputBudget,
    ChatMessage? omissionTarget,
    ChatInputOmission? omission,
  }) {
    final projections = HashMap<ChatMessage, _MessageMutation>.identity();
    _MessageMutation projectionFor(ChatMessage message) =>
        projections.putIfAbsent(message, () {
          final retained = previousRetained[message];
          if (retained == null) {
            throw StateError('Message is not owned by the active ledger');
          }
          return _MessageMutation(message, retained);
        });
    for (final part in parts) {
      if (part.acceptedUtf8Bytes < 0) throw ArgumentError('Negative text size');
      projectionFor(part.target).acceptedUtf8Bytes += part.acceptedUtf8Bytes;
    }
    if (omissionTarget != null && omission != null) {
      final p = projectionFor(omissionTarget);
      if (!p.omissions.any(
            (old) =>
                old.resource == omission.resource &&
                old.reason == omission.reason,
          ) &&
          p.omissions.length < inputBudget.maxCollectionItems) {
        p.omissions.add(omission);
      }
    }
    var totalDelta = 0;
    final next = HashMap<ChatMessage, int>.identity();
    for (final p in projections.values) {
      final retained = projectionEstimateChatMessageRetainedBytes(
        metadata: p.message.metadata,
        omissions: p.omissions,
        acceptedUtf8Bytes: p.acceptedUtf8Bytes,
        inputBudget: inputBudget,
      );
      final delta = retained - p.previousRetained;
      if (delta < 0) throw StateError('Append cannot shrink retained content');
      totalDelta = projectionCheckedRetainedAdd(totalDelta, delta);
      next[p.message] = retained;
    }
    return ChatTextMutation._(
      List.unmodifiable(parts),
      omissionTarget,
      omission,
      totalDelta,
      Map.unmodifiable(next),
      {for (final m in projections.keys) m: m.revision},
    );
  }
  final List<ChatTextAppend> parts;
  final ChatMessage? omissionTarget;
  final ChatInputOmission? omission;
  final int totalDelta;
  final Map<ChatMessage, int> nextRetained;
  final Map<ChatMessage, int> _revisions;
  bool _applied = false;
  Set<ChatMessage> apply(Object ownerToken) {
    if (_applied) throw StateError('Mutation already applied');
    for (final entry in _revisions.entries) {
      entry.key.projectionRequireOwner(ownerToken);
      if (entry.key.revision != entry.value) {
        throw StateError('Stale content mutation');
      }
    }
    _applied = true;
    final changed = <ChatMessage>{};
    for (final part in parts) {
      final before = part.target.revision;
      part.target.projectionAppendAcceptedTextForOwner(
        ownerToken,
        part.text,
        acceptedUtf8Bytes: part.acceptedUtf8Bytes,
      );
      if (before != part.target.revision) changed.add(part.target);
    }
    final target = omissionTarget;
    final omitted = omission;
    if (target != null &&
        omitted != null &&
        target.projectionAddOmissionForOwner(ownerToken, omitted)) {
      changed.add(target);
    }
    return changed;
  }
}

class _MessageMutation {
  _MessageMutation(this.message, this.previousRetained)
    : acceptedUtf8Bytes = message.acceptedUtf8Bytes,
      omissions = [...message.omissions];
  final ChatMessage message;
  final int previousRetained;
  int acceptedUtf8Bytes;
  final List<ChatInputOmission> omissions;
}
