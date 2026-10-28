import 'dart:convert';
import 'buffered_chat_message.dart';
import 'content_mutation.dart';
import 'models/chat_message.dart';
import 'models/chat_input_budget.dart';

/// Identity belongs to a native connection generation, not merely a session ID.
class ChatContentIdentity {
  const ChatContentIdentity(this.generation, this.sessionId);
  final Object generation;
  final String sessionId;
  @override
  bool operator ==(Object other) =>
      other is ChatContentIdentity &&
      other.generation == generation &&
      other.sessionId == sessionId;
  @override
  int get hashCode => Object.hash(generation, sessionId);
}

enum ChatContentKind {
  user,
  textDelta,
  thoughtDelta,
  tool,
  plan,
  turnCompleted,
}

/// Backend adapters construct this after validating their control protocol.
class ChatContentUpdate {
  const ChatContentUpdate({
    required this.identity,
    required this.turnId,
    required this.kind,
    this.text = '',
    this.toolCallId,
    this.metadata = const {},
  });
  final ChatContentIdentity identity;
  final int turnId;
  final ChatContentKind kind;
  final String text;
  final String? toolCallId;
  final Map<String, Object?> metadata;
}

/// Reconstructible content only. Does not acknowledge cancellation or approve tools.
class ChatContentProjection {
  ChatContentProjection({
    required this.identity,
    this.inputBudget = const ChatInputBudget(),
  });
  final ChatContentIdentity identity;
  final ChatInputBudget inputBudget;
  List<ChatMessageView> _messages = [];
  List<ChatMessageView>? _staged;
  final Object _owner = Object();
  final Map<ChatMessage, ChatUtf8LineBudgetCounter> _counters = {};
  Object? _restoreId;
  int revision = 0;
  List<ChatMessageView> get messages => List.unmodifiable(_messages);

  void beginRestore(Object requestId) {
    if (_restoreId != null) throw StateError('Restore already pending');
    _restoreId = requestId;
    _staged = [];
  }

  void commitRestore(Object requestId) {
    if (_restoreId != requestId) throw StateError('Stale restore');
    _messages = _staged!;
    _counters.removeWhere((message, _) => !_messages.contains(message));
    _staged = null;
    _restoreId = null;
    revision++;
  }

  void discardRestore(Object requestId) {
    if (_restoreId != requestId) return;
    _staged = null;
    _restoreId = null;
    _counters.removeWhere((message, _) => !_messages.contains(message));
  }

  bool apply(ChatContentUpdate update, {Object? restoreId}) {
    if (update.identity != identity) return false;
    if (restoreId != null && restoreId != _restoreId) return false;
    // The adapter must explicitly route replay; live data cannot mutate staging.
    if (_restoreId != null && restoreId == null) return false;
    final target = restoreId == null ? _messages : _staged!;
    if (update.kind == ChatContentKind.turnCompleted) {
      for (final message in target.whereType<ChatMessage>().where(
        (m) => m.turnId == update.turnId,
      )) {
        final chunk = _counters[message]?.finish();
        if (chunk != null) _append(message, chunk, target);
      }
      if (restoreId == null) revision++;
      return true;
    }
    final guard = ChatStructuredUpdateGuard(
      budget: inputBudget,
      resource: 'content update',
    );
    final metadata = guard.copyJsonValue(
      update.metadata,
      field: 'content metadata',
    );
    final copied = Map<String, Object?>.from(metadata as Map);
    final role = switch (update.kind) {
      ChatContentKind.user => ChatMessageRole.user,
      ChatContentKind.textDelta => ChatMessageRole.assistant,
      ChatContentKind.tool => ChatMessageRole.tool,
      _ => ChatMessageRole.status,
    };
    var index = -1;
    if (update.kind == ChatContentKind.tool) {
      final id = update.toolCallId;
      if (id == null || id.isEmpty) {
        throw ArgumentError('toolCallId is required');
      }
      copied['toolCallId'] = id;
      index = findChatToolMessage(target, id, turnId: update.turnId);
    } else if (update.kind == ChatContentKind.textDelta ||
        update.kind == ChatContentKind.thoughtDelta) {
      if (update.kind == ChatContentKind.thoughtDelta) {
        copied['kind'] = 'thought';
      }
      if (copied.keys.every((key) => key == 'kind') &&
          target.isNotEmpty &&
          target.last.turnId == update.turnId &&
          target.last.role == role &&
          target.last.metadata['kind'] == copied['kind']) {
        index = target.length - 1;
      }
    } else if (update.kind == ChatContentKind.plan) {
      copied['kind'] = 'plan';
    }
    final previous = index < 0 ? null : target[index];
    final isDelta =
        update.kind == ChatContentKind.textDelta ||
        update.kind == ChatContentKind.thoughtDelta;
    if (isDelta) {
      ChatMessage next;
      if (previous is ChatMessage) {
        next = previous;
      } else {
        next = ChatMessage(
          role: role,
          text: '',
          metadata: copied,
          inputBudget: inputBudget,
        );
        next.projectionClaimOwnership(_owner, update.turnId);
      }
      final counter = _counters.putIfAbsent(
        next,
        () => ChatUtf8LineBudgetCounter(
          maxBytes: update.kind == ChatContentKind.thoughtDelta
              ? inputBudget.maxThoughtTextBytes
              : inputBudget.maxMessageTextBytes,
          maxLines: inputBudget.maxMessageTextLines,
          resource: 'message text',
        ),
      );
      if (index < 0 && target.length >= inputBudget.maxCollectionItems) {
        _counters.remove(next);
        throw StateError('Content message budget exceeded');
      }
      final checkpoint = counter.checkpoint();
      try {
        _append(next, counter.append(update.text), target);
        counter.commit(checkpoint);
      } catch (_) {
        counter.rollback(checkpoint);
        if (index < 0) _counters.remove(next);
        rethrow;
      }
      if (index < 0) target.add(next);
      if (restoreId == null) revision++;
      return true;
    }
    final text = guard.copyString(
      update.text.trim().isEmpty ? previous?.text ?? '' : update.text,
      field: 'content text',
    );
    final next = ChatMessageData(
      role: role,
      text: text,
      turnId: update.turnId,
      timestamp: previous?.timestamp,
      revision: (previous?.revision ?? -1) + 1,
      metadata: mergeChatToolMetadata(previous?.metadata ?? const {}, copied),
    );
    _checkRetainedBudget(target, next, replaced: previous);
    if (index < 0) {
      if (target.length >= inputBudget.maxCollectionItems) {
        throw StateError('Content message budget exceeded');
      }
      target.add(next);
    } else {
      target[index] = next;
    }
    if (restoreId == null) revision++;
    return true;
  }

  void _append(
    ChatMessage message,
    ChatTextBudgetChunk chunk,
    List<ChatMessageView> target,
  ) {
    final mutation = ChatTextMutation.prepare(
      parts: [
        ChatTextAppend(
          target: message,
          text: chunk.safePrefix,
          acceptedUtf8Bytes: chunk.acceptedBytes,
        ),
      ],
      previousRetained: {message: message.retainedBytes},
      inputBudget: inputBudget,
      omissionTarget: message,
      omission: chunk.omission,
    );
    _checkRetainedBudget(
      target,
      message,
      replaced: target.contains(message) ? message : null,
      additionalBytes: mutation.totalDelta,
    );
    mutation.apply(_owner);
  }

  int _retainedSize(ChatMessageView message) => message is ChatMessage
      ? message.retainedBytes
      : projectionEstimateChatMessageRetainedBytes(
          metadata: message.metadata,
          omissions: message.omissions,
          acceptedUtf8Bytes: utf8.encode(message.text).length,
          inputBudget: inputBudget,
        );

  void _checkRetainedBudget(
    List<ChatMessageView> target,
    ChatMessageView next, {
    ChatMessageView? replaced,
    int additionalBytes = 0,
  }) {
    var total = _retainedSize(next) + additionalBytes;
    var turn = total;
    var turnItems = 1;
    for (final message in target) {
      if (identical(message, replaced)) continue;
      final size = _retainedSize(message);
      total += size;
      if (message.turnId == next.turnId) {
        turn += size;
        turnItems++;
      }
    }
    if (total > inputBudget.maxUiStateBytes ||
        turn > inputBudget.maxTurnRetainedBytes ||
        turnItems > inputBudget.maxTurnItems) {
      throw StateError('Content retained-byte or turn-item budget exceeded');
    }
  }
}
