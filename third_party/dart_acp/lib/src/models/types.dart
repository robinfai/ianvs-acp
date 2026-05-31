/// Terminal reasons reported when a prompt turn completes.
enum StopReason {
  /// The model finished the turn without requesting more tools.
  endTurn,

  /// The agent hit token limits for the turn.
  maxTokens,

  /// The maximum number of model requests in a single turn is exceeded.
  maxTurnRequests,

  /// The client cancelled the turn (`session/cancel`).
  cancelled,

  /// The agent refused to continue the turn.
  refusal,

  /// Any other non-standard stop reason.
  other,
}

/// Convert a wire stop reason string to [StopReason].
StopReason stopReasonFromWire(String s) {
  switch (s) {
    case 'end_turn':
      return StopReason.endTurn;
    case 'max_tokens':
      return StopReason.maxTokens;
    case 'max_turn_requests':
      return StopReason.maxTurnRequests;
    case 'cancelled':
      return StopReason.cancelled;
    case 'refusal':
      return StopReason.refusal;
    default:
      return StopReason.other;
  }
}

/// Base class for ACP types that support meta fields for extensibility.
abstract class AcpType {
  /// Creates an ACP type.
  const AcpType({this.meta});

  /// Meta fields for custom information and extensions.
  final Map<String, dynamic>? meta;
}
