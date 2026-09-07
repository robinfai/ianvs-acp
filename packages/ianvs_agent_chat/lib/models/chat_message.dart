import 'chat_input_budget.dart';
import 'prompt_attachment.dart';

/// Rendering roles shared by every backend. Execution remains host-owned.
enum ChatMessageRole { user, assistant, tool, error, status }

/// Read-only projection. Implementations may retain streaming buffers without
/// copying the complete transcript whenever a new token arrives.
abstract interface class ChatMessageView {
  ChatMessageRole get role;
  String get text;
  String get previewText;
  DateTime get timestamp;
  int? get turnId;
  int get revision;
  Map<String, Object?> get metadata;
  List<ChatInputOmission> get omissions;
}

/// Immutable message for hosts that do not already own a message model.
/// [id] is stable across updates; [revision] must change when content changes.
class ChatMessageData implements ChatMessageView {
  ChatMessageData({
    this.id = '',
    required this.role,
    required this.text,
    DateTime? timestamp,
    this.turnId,
    this.revision = 0,
    Map<String, Object?> metadata = const {},
    List<ChatInputOmission> omissions = const [],
  }) : timestamp = timestamp ?? DateTime.now(),
       metadata = Map.unmodifiable(metadata),
       omissions = List.unmodifiable(omissions);

  final String id;
  @override
  final ChatMessageRole role;
  @override
  final String text;
  @override
  final DateTime timestamp;
  @override
  final int? turnId;
  @override
  final int revision;
  @override
  final Map<String, Object?> metadata;
  @override
  final List<ChatInputOmission> omissions;
  @override
  String get previewText =>
      text.length <= 256 ? text : '${text.substring(0, 256)}…';

  ChatMessageData copyWith({String? text, Map<String, Object?>? metadata}) =>
      ChatMessageData(
        id: id,
        role: role,
        text: text ?? this.text,
        timestamp: timestamp,
        turnId: turnId,
        revision: revision + 1,
        metadata: metadata ?? this.metadata,
        omissions: omissions,
      );
}

class ChatQueuedPrompt {
  const ChatQueuedPrompt({
    required this.id,
    required this.text,
    required this.attachments,
    required this.createdAt,
    this.guide = false,
  });

  final int id;
  final String text;
  final List<PromptAttachment> attachments;
  final DateTime createdAt;
  final bool guide;

  ChatQueuedPrompt copyWith({bool? guide}) {
    return ChatQueuedPrompt(
      id: id,
      text: text,
      attachments: attachments,
      createdAt: createdAt,
      guide: guide ?? this.guide,
    );
  }
}
