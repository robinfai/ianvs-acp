/// Decision outcomes for a permission prompt.
enum PermissionOutcome {
  /// Allow the operation (typically once).
  allow,

  /// Deny the operation.
  deny,

  /// The prompt turn was cancelled while awaiting decision.
  cancelled,
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
    this.toolKind,
  });

  /// Display title of the permission prompt.
  final String title;

  /// Rationale for the permission request.
  final String rationale;

  /// Display-only option names provided by the agent.
  final List<String> options;

  /// Owning session identifier.
  final String sessionId;

  /// Agent-provided tool name.
  final String toolName;

  /// Tool kind (read/edit/execute/etc), if provided.
  final String? toolKind;
}

/// Provider interface for answering permission requests.
abstract class PermissionProvider {
  /// Return a decision for the given options.
  Future<PermissionOutcome> request(PermissionOptions options);
}

/// Callback signature for handling permission prompts.
typedef PermissionCallback =
    Future<PermissionOutcome> Function(PermissionOptions options);

/// Default provider with simple policy and optional callback override.
class DefaultPermissionProvider implements PermissionProvider {
  /// Optional callback to override the decision.
  const DefaultPermissionProvider({this.onRequest});

  /// Optional callback invoked to determine the outcome.
  final PermissionCallback? onRequest;

  @override
  /// Return a decision for the given [options]. If [onRequest] is provided,
  /// it is invoked; otherwise a simple policy is applied.
  Future<PermissionOutcome> request(PermissionOptions options) async {
    if (onRequest != null) {
      return onRequest!(options);
    }
    // Defaults: allow read; deny write/execute; others deny.
    final lowerName = options.toolName.toLowerCase();
    final lowerKind = options.toolKind?.toLowerCase();
    if (lowerKind == 'read' || lowerName.contains('read')) {
      return PermissionOutcome.allow;
    }
    return PermissionOutcome.deny;
  }
}
