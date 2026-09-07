import 'chat_message.dart';

/// Typed construction helpers keep backend protocol keys out of host UI code.
/// Existing ACP projections continue to use ChatMessageView without copying.
enum ChatToolStatus { pending, inProgress, completed, failed, cancelled }

class ChatToolMessage extends ChatMessageData {
  ChatToolMessage({
    required String callId,
    required String name,
    required ChatToolStatus status,
    required int super.turnId,
    Object? input,
    Object? output,
    String kind = 'tool',
    super.timestamp,
    super.revision,
  }) : super(
         id: callId,
         role: ChatMessageRole.tool,
         text: name,
         metadata: {
           'toolCallId': callId,
           'title': name,
           'kind': kind,
           'status': status == ChatToolStatus.inProgress
               ? 'in_progress'
               : status.name,
           'rawInput': ?input,
           'rawOutput': ?output,
         },
       );
}

enum ChatPlanStatus { pending, inProgress, completed }

class ChatPlanStep {
  const ChatPlanStep(this.text, {this.status = ChatPlanStatus.pending});
  final String text;
  final ChatPlanStatus status;
}

class ChatPlanMessage extends ChatMessageData {
  ChatPlanMessage({
    required List<ChatPlanStep> steps,
    required int turnId,
    String title = 'Plan',
  }) : super(
         role: ChatMessageRole.status,
         text: title,
         turnId: turnId,
         metadata: {
           'kind': 'plan',
           'entries': [
             for (final step in steps)
               {
                 'content': step.text,
                 'status': step.status == ChatPlanStatus.inProgress
                     ? 'in_progress'
                     : step.status.name,
                 'priority': 'medium',
               },
           ],
         },
       );
}

class ChatThoughtMessage extends ChatMessageData {
  ChatThoughtMessage({
    required super.text,
    required int super.turnId,
    super.revision,
  }) : super(role: ChatMessageRole.status, metadata: const {'kind': 'thought'});
}
