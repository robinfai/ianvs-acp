import 'deep_link_request.dart';

class StartupOptions {
  static const Set<String> _resumeArgumentKeys = <String>{
    '--resume-session-id',
    '--resume-cwd',
    '--resume-agent',
    '--resume-template',
    '--resume-template-version',
  };

  const StartupOptions({
    this.resumeSessionId,
    this.resumeCwd,
    this.resumeAgentName,
    this.resumeSessionTemplateId,
    this.resumeSessionTemplateVersion,
  });

  final String? resumeSessionId;
  final String? resumeCwd;
  final String? resumeAgentName;
  final String? resumeSessionTemplateId;
  final int? resumeSessionTemplateVersion;

  bool get hasResumeSession {
    final id = resumeSessionId?.trim();
    return id != null && id.isNotEmpty;
  }

  static StartupOptions fromArgs(List<String> args) {
    final templateId = _argValue(args, '--resume-template');
    final templateVersion = _positiveIntArg(args, '--resume-template-version');
    final hasCompleteTemplate = templateId != null && templateVersion != null;
    return StartupOptions(
      resumeSessionId: _argValue(args, '--resume-session-id'),
      resumeCwd: _argValue(args, '--resume-cwd'),
      resumeAgentName: _argValue(args, '--resume-agent'),
      resumeSessionTemplateId: hasCompleteTemplate ? templateId : null,
      resumeSessionTemplateVersion: hasCompleteTemplate
          ? templateVersion
          : null,
    );
  }

  static DeepLinkRequest? fromDeepLink(String rawLink) {
    if (rawLink.length > DeepLinkRequest.maxRawLinkLength) return null;
    final normalizedLink = rawLink.trim();
    if (normalizedLink.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(normalizedLink);
    if (uri == null || uri.scheme != 'ianvs-acp') return null;

    final query = uri.queryParameters;
    if (uri.host != 'session') return null;
    final sessionId = _trimmedOrNull(query['id'] ?? query['session_id']);
    final workspace = validateDeepLinkWorkspaceSyntax(query['cwd']);
    final templateId = _trimmedOrNull(query['template']);
    final rawTemplateVersion = _trimmedOrNull(query['template_version']);
    final templateVersion = _positiveInt(rawTemplateVersion);
    final errors = <String>[
      if (sessionId == null) 'Session is required.',
      ...workspace.errors,
      if (rawTemplateVersion != null && templateVersion == null)
        'Template version must be a positive integer.',
      if ((templateId == null) != (templateVersion == null))
        'Template and template version must be provided together.',
    ];

    return DeepLinkRequest(
      rawLink: normalizedLink,
      source: DeepLinkSource.external,
      kind: DeepLinkRequestKind.session,
      sessionId: sessionId,
      cwd: workspace.path,
      agentName: _trimmedOrNull(query['agent']),
      sessionTemplateId: templateId,
      sessionTemplateVersion: templateVersion,
      validationErrors: List<String>.unmodifiable(errors),
    );
  }

  static String? _argValue(List<String> args, String key) {
    for (var index = 0; index < args.length; index += 1) {
      final arg = args[index];
      if (arg == key && index + 1 < args.length) {
        final candidate = args[index + 1];
        if (_resumeArgumentKeys.any(
          (known) => candidate == known || candidate.startsWith('$known='),
        )) {
          continue;
        }
        return _trimmedOrNull(candidate);
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

  static int? _positiveIntArg(List<String> args, String key) {
    return _positiveInt(_argValue(args, key));
  }

  static int? _positiveInt(String? value) {
    final parsed = int.tryParse(value?.trim() ?? '');
    return parsed != null && parsed > 0 ? parsed : null;
  }
}
