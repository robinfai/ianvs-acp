import 'dart:convert';

import '../acp/acp_permission_request.dart';

class EgressPolicyMatch {
  const EgressPolicyMatch({required this.reason, required this.commandLine});

  final String reason;
  final String commandLine;
}

bool isEgressSensitiveCommand(String commandLine) {
  return egressSensitiveCommandMatch(commandLine) != null;
}

EgressPolicyMatch? egressPolicyMatchForPermission(
  AcpPermissionRequest request,
) {
  final commandLine = commandLineFromPermissionRequest(request);
  if (commandLine != null) {
    return egressSensitiveCommandMatch(commandLine);
  }

  final toolName = request.toolName.trim();
  if (toolName.isEmpty) return null;
  return egressSensitiveCommandMatch(toolName);
}

EgressPolicyMatch? egressSensitiveCommandMatch(String commandLine) {
  final normalized = _normalizedCommandLine(commandLine);
  if (normalized.isEmpty) return null;

  for (final nested in _nestedShellCommands(normalized)) {
    final match = egressSensitiveCommandMatch(nested);
    if (match != null) return match;
  }

  for (final pattern in _patterns) {
    if (pattern.regex.hasMatch(normalized)) {
      return EgressPolicyMatch(reason: pattern.reason, commandLine: normalized);
    }
  }

  final tokens = _shellWords(normalized);
  if (tokens.isEmpty) return null;
  final executable = _basename(tokens.first).toLowerCase();
  if ((executable == 'curl' || executable == 'wget') &&
      tokens.any(_isExternalHttpUrl)) {
    return EgressPolicyMatch(
      reason: 'external_http_transfer',
      commandLine: normalized,
    );
  }

  if (_egressExecutables.contains(executable)) {
    return EgressPolicyMatch(
      reason: 'external_transfer_command',
      commandLine: normalized,
    );
  }

  if (executable == 'git' && tokens.skip(1).contains('push')) {
    return EgressPolicyMatch(reason: 'git_push', commandLine: normalized);
  }

  if (executable == 'gh' &&
      tokens.length >= 3 &&
      tokens[1] == 'pr' &&
      tokens[2] == 'create') {
    return EgressPolicyMatch(reason: 'pull_request', commandLine: normalized);
  }

  if (executable == 'hub' && tokens.skip(1).contains('pull-request')) {
    return EgressPolicyMatch(reason: 'pull_request', commandLine: normalized);
  }

  return null;
}

String? commandLineFromPermissionRequest(AcpPermissionRequest request) {
  final metadata = request.metadata;
  final rawInput = _firstValue(metadata, const [
    'rawInput',
    'raw_input',
    'input',
    'args',
    'arguments',
  ]);
  final nestedToolCall = metadata['toolCall'];
  final nestedRawInput = nestedToolCall is Map
      ? _firstValue(nestedToolCall, const [
          'rawInput',
          'raw_input',
          'input',
          'args',
          'arguments',
        ])
      : null;
  final commandSource =
      _decodedJsonObject(rawInput) ??
      _decodedJsonObject(nestedRawInput) ??
      metadata;
  final toolCallSource = nestedToolCall is Map ? nestedToolCall : null;

  final command =
      _firstString(commandSource, const [
        'command',
        'cmd',
        'commandLine',
        'command_line',
        'shellCommand',
        'shell_command',
        'script',
      ]) ??
      _firstString(toolCallSource, const [
        'command',
        'cmd',
        'commandLine',
        'command_line',
        'shellCommand',
        'shell_command',
      ]) ??
      _commandLineFromPermissionText(request.title) ??
      _commandLineFromPermissionText(request.rationale);
  final args = _firstStringList(commandSource, const [
    'args',
    'argv',
    'arguments',
  ]);

  return _commandLine(command, args);
}

const Set<String> _egressExecutables = {
  'ssh',
  'scp',
  'rsync',
  'sendmail',
  'mail',
};

final List<_EgressPattern> _patterns = [
  _EgressPattern(RegExp(r'(^|[;&|]\s*)git\s+push\b'), 'git_push'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)gh\s+pr\s+create\b'), 'pull_request'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)hub\s+pull-request\b'), 'pull_request'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)ssh\b'), 'external_transfer_command'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)scp\b'), 'external_transfer_command'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)rsync\b'), 'external_transfer_command'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)sendmail\b'), 'external_mail_command'),
  _EgressPattern(RegExp(r'(^|[;&|]\s*)mail\b'), 'external_mail_command'),
  _EgressPattern(RegExp(r'\bwebhook\b'), 'webhook_call'),
  _EgressPattern(RegExp(r'\bupload\b'), 'upload_api'),
];

class _EgressPattern {
  const _EgressPattern(this.regex, this.reason);

  final RegExp regex;
  final String reason;
}

List<String> _nestedShellCommands(String commandLine) {
  final tokens = _shellWords(commandLine);
  if (tokens.length < 3) return const <String>[];
  final executable = _basename(tokens.first).toLowerCase();
  if (!const {'sh', 'bash', 'zsh'}.contains(executable)) {
    return const <String>[];
  }

  final commands = <String>[];
  for (var index = 1; index < tokens.length - 1; index += 1) {
    final token = tokens[index];
    if (token == '-c' || token == '-lc' || token == '-ilc') {
      commands.add(tokens[index + 1]);
    }
  }
  return commands;
}

String _normalizedCommandLine(String value) {
  return value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
}

String _basename(String value) {
  final normalized = value.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}

bool _isExternalHttpUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  final host = uri.host.toLowerCase();
  if (host.isEmpty) return false;
  return host != 'localhost' &&
      host != '127.0.0.1' &&
      host != '0.0.0.0' &&
      host != '::1';
}

List<String> _shellWords(String commandLine) {
  final words = <String>[];
  final buffer = StringBuffer();
  var quote = '';
  var escaped = false;

  void flush() {
    if (buffer.isEmpty) return;
    words.add(buffer.toString());
    buffer.clear();
  }

  for (var index = 0; index < commandLine.length; index += 1) {
    final char = commandLine[index];
    if (escaped) {
      buffer.write(char);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (quote.isNotEmpty) {
      if (char == quote) {
        quote = '';
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char.trim().isEmpty) {
      flush();
      continue;
    }
    buffer.write(char);
  }
  flush();
  return words;
}

Object? _firstValue(Map? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    if (map.containsKey(key)) return map[key];
  }
  return null;
}

Map<String, Object?>? _decodedJsonObject(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map) {
    return value.map((key, item) => MapEntry(key.toString(), item));
  }
  if (value is! String || value.trim().isEmpty) return null;
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map) {
      return decoded.map((key, item) => MapEntry(key.toString(), item));
    }
  } on FormatException {
    return null;
  }
  return null;
}

String? _firstString(Map? map, List<String> keys) {
  if (map == null) return null;
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}

List<String> _firstStringList(Map? map, List<String> keys) {
  if (map == null) return const <String>[];
  for (final key in keys) {
    final values = _stringList(map[key]);
    if (values.isNotEmpty) return values;
  }
  return const <String>[];
}

List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  return value.whereType<String>().toList(growable: false);
}

String? _commandLineFromPermissionText(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  for (final pattern in <RegExp>[
    RegExp(r'^running:\s*(.+)$', caseSensitive: false),
    RegExp(r'^run:\s*(.+)$', caseSensitive: false),
    RegExp(r'^command:\s*(.+)$', caseSensitive: false),
    RegExp(r'^executing:\s*(.+)$', caseSensitive: false),
  ]) {
    final match = pattern.firstMatch(trimmed);
    final value = match?.group(1)?.trim();
    if (value != null && value.isNotEmpty) return _stripInlineCode(value);
  }
  final inline = RegExp(r'`([^`]+)`').firstMatch(trimmed)?.group(1)?.trim();
  return inline == null || inline.isEmpty ? null : inline;
}

String _stripInlineCode(String value) {
  var result = value.trim();
  while (result.startsWith('`') && result.endsWith('`') && result.length > 1) {
    result = result.substring(1, result.length - 1).trim();
  }
  return result;
}

String? _commandLine(String? command, List<String> args) {
  final trimmedCommand = command?.trim();
  if (trimmedCommand == null || trimmedCommand.isEmpty) return null;
  if (args.isEmpty) return trimmedCommand;
  return [trimmedCommand, ...args.map(_shellDisplayArg)].join(' ');
}

String _shellDisplayArg(String arg) {
  if (!arg.contains(RegExp(r'\s'))) return arg;
  return "'${arg.replaceAll("'", r"'\''")}'";
}
