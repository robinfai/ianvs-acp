import 'deep_link_request.dart';

class StartupOptions {
  const StartupOptions({
    this.resumeSessionId,
    this.resumeCwd,
    this.resumeAgentName,
  });

  final String? resumeSessionId;
  final String? resumeCwd;
  final String? resumeAgentName;

  bool get hasResumeSession {
    final id = resumeSessionId?.trim();
    return id != null && id.isNotEmpty;
  }

  static StartupOptions fromArgs(List<String> args) {
    return StartupOptions(
      resumeSessionId: _argValue(args, '--resume-session-id'),
      resumeCwd: _argValue(args, '--resume-cwd'),
      resumeAgentName: _argValue(args, '--resume-agent'),
    );
  }

  static DeepLinkRequest? fromDeepLink(String rawLink) {
    final normalizedLink = rawLink.trim();
    if (normalizedLink.isEmpty ||
        normalizedLink.length > DeepLinkRequest.maxRawLinkLength) {
      return null;
    }
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null || uri.scheme != 'ianvs-acp') return null;

    final query = uri.queryParameters;
    if (uri.host != 'session') return null;
    final sessionId = _trimmedOrNull(query['id'] ?? query['session_id']);
    final workspace = validateDeepLinkWorkspaceSyntax(query['cwd']);
    final errors = <String>[
      if (sessionId == null) 'Session is required.',
      ...workspace.errors,
    ];

    return DeepLinkRequest(
      rawLink: normalizedLink,
      source: DeepLinkSource.external,
      kind: DeepLinkRequestKind.session,
      sessionId: sessionId,
      cwd: workspace.path,
      agentName: _trimmedOrNull(query['agent']),
      validationErrors: List<String>.unmodifiable(errors),
    );
  }

  static String? _argValue(List<String> args, String key) {
    for (var index = 0; index < args.length; index += 1) {
      final arg = args[index];
      if (arg == key && index + 1 < args.length) {
        return _trimmedOrNull(args[index + 1]);
      }
      if (arg.startsWith('$key=')) {
        return _trimmedOrNull(arg.substring(key.length + 1));
      }
    }
    return null;
  }

  static String? _trimmedOrNull(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
