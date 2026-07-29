const int maxSessionTitleCharacters = 256;

const int _ellipsisRune = 0x2026;
const int _spaceRune = 0x20;

/// Converts an agent-provided title or preview into bounded sidebar metadata.
///
/// ACP agents are allowed to return arbitrary strings for session titles. Some
/// adapters use an entire prompt as a fallback title, so this function avoids
/// building an equally large normalized copy and stops after the display limit.
String? normalizeSessionTitle(String? value) {
  if (value == null || value.isEmpty) return null;

  final normalized = <int>[];
  var pendingSpace = false;
  var truncated = false;

  for (final rune in value.runes) {
    if (_isTitleWhitespace(rune)) {
      if (normalized.isNotEmpty) pendingSpace = true;
      continue;
    }

    final requiredCharacters = pendingSpace ? 2 : 1;
    if (normalized.length + requiredCharacters > maxSessionTitleCharacters) {
      truncated = true;
      break;
    }
    if (pendingSpace) normalized.add(_spaceRune);
    normalized.add(rune);
    pendingSpace = false;
  }

  if (normalized.isEmpty) return null;
  if (truncated) {
    if (normalized.length == maxSessionTitleCharacters) {
      normalized.removeLast();
    }
    normalized.add(_ellipsisRune);
  }
  return String.fromCharCodes(normalized);
}

bool _isTitleWhitespace(int rune) {
  return rune <= 0x20 ||
      (rune >= 0x7f && rune <= 0x9f) ||
      rune == 0xa0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200a) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202f ||
      rune == 0x205f ||
      rune == 0x3000 ||
      rune == 0xfeff;
}
