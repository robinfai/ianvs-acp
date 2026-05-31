import 'dart:io';

import 'package:mime/mime.dart' as mime;
import 'package:path/path.dart' as p;

/// Builds content blocks from prompts with @-mention support.
class ContentBuilder {
  /// Build content blocks from a prompt string with @-mentions.
  ///
  /// Supports:
  /// - Plain text
  /// - @-mentions for files: @file.txt, @"path with spaces/file.txt"
  /// - @-mentions for URLs: @https://example.com/file
  /// - Tilde expansion: @~/Documents/file.txt
  static List<Map<String, dynamic>> buildFromPrompt(
    String prompt, {
    String? workspaceRoot,
  }) {
    final blocks = <Map<String, dynamic>>[];

    // Always include the original user text with @-mentions untouched
    blocks.add({'type': 'text', 'text': prompt});

    // Extract and process @-mentions
    final mentions = _extractMentions(prompt);
    final cwd = workspaceRoot ?? Directory.current.path;

    for (final mention in mentions) {
      final uri = _toUri(mention, cwd: cwd);
      if (uri == null) continue; // Skip malformed mentions

      final name = _displayNameFor(uri);
      final mimeType =
          mime.lookupMimeType(uri.path) ?? mime.lookupMimeType(uri.toString());

      final block = {
        'type': 'resource_link',
        'name': name,
        'uri': uri.toString(),
        'mimeType': ?mimeType,
      };
      blocks.add(block);
    }

    return blocks;
  }

  static final _mentionRe = RegExp(
    r'''@("([^"\\]|\\.)*"|'([^'\\]|\\.)*'|\S+)''',
  );

  static List<String> _extractMentions(String text) {
    final matches = _mentionRe.allMatches(text);
    final mentions = <String>[];

    for (final match in matches) {
      var token = match.group(1)!;
      // Strip surrounding quotes and unescape simple escapes
      if ((token.startsWith('"') && token.endsWith('"')) ||
          (token.startsWith("'") && token.endsWith("'"))) {
        token = token.substring(1, token.length - 1);
      }
      mentions.add(token);
    }

    return mentions;
  }

  static Uri? _toUri(String token, {required String cwd}) {
    // URLs
    if (token.startsWith('http://') || token.startsWith('https://')) {
      try {
        return Uri.parse(token);
      } on FormatException {
        // Invalid URL, skip it
        return null;
      }
    }

    // Local file path
    var path = token;

    // Handle tilde expansion
    if (path.startsWith('~')) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        path = p.join(home, path.substring(1));
      }
    }

    // Make relative paths absolute
    if (!p.isAbsolute(path)) {
      path = p.join(cwd, path);
    }

    // Normalize the path
    path = p.normalize(path);

    // Note: We don't check file existence here - that's the agent's job
    // We just build the URI for the file path
    return Uri.file(path);
  }

  static String _displayNameFor(Uri uri) {
    if (uri.hasScheme && (uri.scheme == 'http' || uri.scheme == 'https')) {
      final segments = uri.pathSegments;
      return segments.isNotEmpty ? segments.last : uri.host;
    }
    return p.basename(uri.path);
  }
}
