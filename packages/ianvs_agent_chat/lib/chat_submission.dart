import 'dart:async';

import 'models/prompt_attachment.dart';

/// An immutable draft captured before a host starts asynchronous admission.
class ChatSubmission {
  ChatSubmission({
    required this.id,
    required this.sessionIdentity,
    required this.draftRevision,
    required this.text,
    List<PromptAttachment> attachments = const [],
  }) : attachments = List.unmodifiable(attachments);

  final String id;
  final Object sessionIdentity;
  final int draftRevision;
  final String text;
  final List<PromptAttachment> attachments;
}

enum ChatSubmitStatus { accepted, queued, rejected }

class ChatSubmitResult {
  const ChatSubmitResult.accepted()
    : status = ChatSubmitStatus.accepted,
      message = null;
  const ChatSubmitResult.queued()
    : status = ChatSubmitStatus.queued,
      message = null;
  const ChatSubmitResult.rejected(String reason)
    : assert(reason != ''),
      status = ChatSubmitStatus.rejected,
      message = reason;

  final ChatSubmitStatus status;
  final String? message;
  bool get isAccepted => status != ChatSubmitStatus.rejected;
}

/// Opt in separately from ChatSession.send, whose completion timing is unchanged.
/// Return acceptance as soon as the host owns the request. Later generation
/// failures belong in session state, rather than in the user's next draft.
abstract interface class ChatSubmissionSession {
  Future<ChatSubmitResult> submit(ChatSubmission submission);
}

/// Deduplicates both pending and completed submissions for an adapter's lifetime.
/// Rejections are also remembered; an intentional retry uses a fresh draft ID.
class ChatSubmissionLedger {
  final _receipts = <String, Future<ChatSubmitResult>>{};

  Future<ChatSubmitResult> submit(
    ChatSubmission submission,
    FutureOr<ChatSubmitResult> Function() admit,
  ) {
    final existing = _receipts[submission.id];
    if (existing != null) return existing;
    final completer = Completer<ChatSubmitResult>();
    _receipts[submission.id] = completer.future;
    // Register the receipt before invoking host code (which may reenter).
    Future.sync(
      admit,
    ).then(completer.complete, onError: completer.completeError);
    return completer.future;
  }
}
