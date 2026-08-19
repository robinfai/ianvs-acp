final RegExp _textImageMarkerPattern = RegExp(
  r'\[@(?:codex-clipboard-[^\]]+|image)\]\(([^)]+)\)',
  caseSensitive: false,
);

/// Projects a persisted user message into the same privacy-safe text shown by
/// the chat UI. Attachment envelopes and local image markers are metadata, not
/// user-visible prompt content.
String userPromptDisplayText(String text) {
  const marker = '## My request for Codex:';
  final markerIndex = text.indexOf(marker);
  final display = markerIndex < 0
      ? text.trim()
      : text.substring(markerIndex + marker.length).trim();
  return display.replaceAll(_textImageMarkerPattern, '').trim();
}

bool isAttachmentProjectionText(String text) {
  final normalized = text.trim();
  if (!normalized.startsWith('[') || !normalized.endsWith(')')) return false;
  return normalized.contains('](file://') ||
      normalized.startsWith('[@image](') ||
      normalized.startsWith('[@codex-clipboard-');
}

List<String> textImagePaths(String text) {
  final paths = <String>[];
  final seen = <String>{};
  for (final match in _textImageMarkerPattern.allMatches(text)) {
    final source = match.group(1)?.trim();
    if (source == null || source.isEmpty) continue;
    final uri = Uri.tryParse(source);
    final path = uri?.scheme == 'file'
        ? uri!.toFilePath()
        : uri?.scheme.isEmpty == true && source.startsWith('/')
        ? source
        : null;
    if (path == null || !_looksLikeImagePath(path) || !seen.add(path)) {
      continue;
    }
    paths.add(path);
  }
  return List<String>.unmodifiable(paths);
}

bool _looksLikeImagePath(String path) {
  final lower = path.toLowerCase();
  return const <String>[
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.webp',
    '.bmp',
  ].any(lower.endsWith);
}
