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
    final deepLinkOptions = _firstDeepLinkOptions(args);
    return StartupOptions(
      resumeSessionId:
          _argValue(args, '--resume-session-id') ??
          deepLinkOptions?.resumeSessionId,
      resumeCwd: _argValue(args, '--resume-cwd') ?? deepLinkOptions?.resumeCwd,
      resumeAgentName:
          _argValue(args, '--resume-agent') ?? deepLinkOptions?.resumeAgentName,
    );
  }

  static StartupOptions? fromDeepLink(String rawLink) {
    final uri = Uri.tryParse(rawLink.trim());
    if (uri == null || uri.scheme != 'ianvs-acp') return null;
    if (uri.host != 'session') return null;

    final query = uri.queryParameters;
    final sessionId = _trimmedOrNull(query['id'] ?? query['session_id']);
    if (sessionId == null) return null;

    return StartupOptions(
      resumeSessionId: sessionId,
      resumeCwd: _trimmedOrNull(query['cwd']),
      resumeAgentName: _trimmedOrNull(query['agent']),
    );
  }

  static StartupOptions? _firstDeepLinkOptions(List<String> args) {
    for (final arg in args) {
      final options = fromDeepLink(arg);
      if (options != null) return options;
    }
    return null;
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
