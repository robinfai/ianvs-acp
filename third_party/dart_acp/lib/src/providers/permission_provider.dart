/// Decision outcomes for a permission prompt.
enum PermissionOutcome {
  /// Allow the operation (typically once).
  allow,

  /// Deny the operation.
  deny,

  /// The prompt turn was cancelled while awaiting decision.
  cancelled,
}

/// A permission decision and, when selected, the exact ACP option id.
class PermissionDecision {
  /// Create a decision for [outcome].
  const PermissionDecision(this.outcome, {this.optionId});

  /// Create an allowed decision.
  const PermissionDecision.allow({this.optionId})
    : outcome = PermissionOutcome.allow;

  /// Create a denied decision.
  const PermissionDecision.deny({this.optionId})
    : outcome = PermissionOutcome.deny;

  /// Create a cancelled decision.
  const PermissionDecision.cancelled()
    : outcome = PermissionOutcome.cancelled,
      optionId = null;

  /// Semantic decision used by local policy checks.
  final PermissionOutcome outcome;

  /// Exact option selected by the user, when one was selected.
  final String? optionId;
}

/// One permission option exactly as advertised by the agent.
class PermissionChoice {
  /// Create a structured permission option.
  const PermissionChoice({
    required this.optionId,
    required this.name,
    this.kind,
  });

  /// Protocol identifier returned when this option is selected.
  final String optionId;

  /// Human-readable option label.
  final String name;

  /// ACP option kind, such as `allow_once` or `reject_once`.
  final String? kind;
}

/// Structured permission request options sent to a provider.
class PermissionOptions {
  /// Create options describing the tool and choices.
  PermissionOptions({
    required this.title,
    required this.rationale,
    required this.options,
    required this.sessionId,
    required this.toolName,
    this.choices = const <PermissionChoice>[],
    this.toolKind,
    this.metadata = const <String, Object?>{},
    this.transientPolicyContext = const <String, Object?>{},
    this.cancellationToken,
  });

  /// Display title of the permission prompt.
  final String title;

  /// Rationale for the permission request.
  final String rationale;

  /// Display-only option names provided by the agent.
  final List<String> options;

  /// Structured choices supplied by the agent.
  final List<PermissionChoice> choices;

  /// Owning session identifier.
  final String sessionId;

  /// Agent-provided tool name.
  final String toolName;

  /// Tool kind (read/edit/execute/etc), if provided.
  final String? toolKind;

  /// Extra request context for client-side policy and audit.
  final Map<String, Object?> metadata;

  /// Memory-only context for policy decisions.
  ///
  /// Values in this map must not be copied into protocol messages, audit
  /// records, UI metadata, or logs.
  final Map<String, Object?> transientPolicyContext;

  /// Memory-only identity used to cancel this exact permission request.
  final Object? cancellationToken;
}

/// Fixed error for a permission request deadline.
final class PermissionRequestTimeoutException implements Exception {
  /// Create the fixed timeout error.
  const PermissionRequestTimeoutException();

  @override
  String toString() => 'Permission request timed out.';
}

/// Local reason for settling an exact permission request.
enum PermissionCancellationReason {
  /// The permission deadline elapsed.
  timedOut,

  /// The owning prompt ended.
  promptEnded,

  /// The owning prompt was cancelled.
  promptCancelled,

  /// The owning session was closed.
  sessionClosed,

  /// The peer connection closed.
  connectionClosed,

  /// The client was disposed.
  disposed,
}

/// Provider interface for answering permission requests.
abstract class PermissionProvider {
  /// Return a decision for the given options.
  Future<PermissionDecision> request(PermissionOptions options);
}

/// Optional permission provider interface for exact local cancellation.
abstract interface class CancellablePermissionProvider
    implements PermissionProvider {
  /// Cancel the request identified by [cancellationToken].
  void cancelPendingPermission({
    required Object cancellationToken,
    required PermissionCancellationReason reason,
  });
}

/// Callback signature for handling permission prompts.
typedef PermissionCallback =
    Future<PermissionDecision> Function(PermissionOptions options);

/// Default provider with simple policy and optional callback override.
class DefaultPermissionProvider implements PermissionProvider {
  /// Optional callback to override the decision.
  const DefaultPermissionProvider({this.onRequest});

  /// Optional callback invoked to determine the outcome.
  final PermissionCallback? onRequest;

  @override
  /// Return a decision for the given [options]. If [onRequest] is provided,
  /// it is invoked; otherwise a simple policy is applied.
  Future<PermissionDecision> request(PermissionOptions options) async {
    if (onRequest != null) {
      return onRequest!(options);
    }
    // Defaults: allow read; deny write/execute; others deny.
    final lowerKind = options.toolKind?.trim().toLowerCase() ?? '';
    if (lowerKind.isNotEmpty) {
      return lowerKind == 'read'
          ? const PermissionDecision.allow()
          : const PermissionDecision.deny();
    }
    final normalizedName = options.toolName.trim().toLowerCase();
    const readToolNames = <String>{'read', 'read file', 'read_text_file'};
    if (readToolNames.contains(normalizedName)) {
      return const PermissionDecision.allow();
    }
    return const PermissionDecision.deny();
  }
}
