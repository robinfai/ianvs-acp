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
  final invocation = _commandFromPermissionRequest(request);
  if (invocation != null) {
    return egressSensitiveCommandMatch(
      invocation.command,
      args: invocation.args,
      cwd: _permissionCwd(request),
      environment: _transientEnvironment(request),
    );
  }

  final toolName = request.toolName.trim();
  if (toolName.isEmpty) return null;
  return egressSensitiveCommandMatch(
    toolName,
    cwd: _permissionCwd(request),
    environment: _transientEnvironment(request),
  );
}

EgressPolicyMatch? egressSensitiveCommandMatch(
  String commandLine, {
  List<String> args = const <String>[],
  String? cwd,
  Map<String, String> environment = const <String, String>{},
}) {
  final commandWords = _shellWords(commandLine);
  final words = args.isEmpty
      ? commandWords
      : <String>[...commandWords, ...args];
  if (words.isEmpty) return null;

  final segments = args.isEmpty
      ? _commandSegments(words)
      : <List<String>>[words];
  for (final segment in segments) {
    final match = _classifySegment(segment, environment);
    if (match != null) return match;
  }
  return null;
}

EgressPolicyMatch? _classifySegment(
  List<String> sourceTokens,
  Map<String, String> inheritedEnvironment,
) {
  final environment = Map<String, String>.of(inheritedEnvironment);
  final tokens = List<String>.of(sourceTokens);
  var index = 0;

  while (index < tokens.length && _isAssignment(tokens[index])) {
    final assignment = _assignment(tokens[index]);
    final resolved = _resolveToken(assignment.value, environment);
    if (!resolved.complete) {
      return _manualMatch('unresolved_variable', tokens.skip(index).toList());
    }
    environment[assignment.name] = resolved.value;
    index += 1;
  }
  if (index >= tokens.length) return null;

  while (index < tokens.length) {
    final wrapper = _basename(tokens[index]).toLowerCase();
    if (wrapper == 'env') {
      index += 1;
      var optionsEnded = false;
      while (index < tokens.length) {
        final token = tokens[index];
        if (!optionsEnded && token == '--') {
          optionsEnded = true;
          index += 1;
          continue;
        }
        if (!optionsEnded &&
            (token == '-i' || token == '--ignore-environment')) {
          environment.clear();
          index += 1;
          continue;
        }
        if (!optionsEnded && token == '-u') {
          if (index + 1 >= tokens.length) {
            return _manualMatch(
              'unresolved_wrapper',
              tokens.skip(index - 1).toList(),
            );
          }
          environment.remove(tokens[index + 1]);
          index += 2;
          continue;
        }
        if (!optionsEnded && token.startsWith('--unset=')) {
          environment.remove(token.substring('--unset='.length));
          index += 1;
          continue;
        }
        if (!optionsEnded && token.startsWith('-')) {
          return _manualMatch(
            'unresolved_wrapper',
            tokens.skip(index - 1).toList(),
          );
        }
        if (_isAssignment(token)) {
          final assignment = _assignment(token);
          final resolved = _resolveToken(assignment.value, environment);
          if (!resolved.complete) {
            return _manualMatch(
              'unresolved_variable',
              tokens.skip(index).toList(),
            );
          }
          environment[assignment.name] = resolved.value;
          index += 1;
          continue;
        }
        break;
      }
      if (index >= tokens.length) return null;
      continue;
    }

    if (wrapper == 'command') {
      index += 1;
      while (index < tokens.length) {
        final token = tokens[index];
        if (token == '--' || token == '-p') {
          index += 1;
          continue;
        }
        if (token == '-v' || token == '-V') return null;
        if (token.startsWith('-')) {
          return _manualMatch(
            'unresolved_wrapper',
            tokens.skip(index - 1).toList(),
          );
        }
        break;
      }
      if (index >= tokens.length) {
        return _manualMatch('unresolved_executable', const <String>['command']);
      }
      continue;
    }
    break;
  }

  final finalTokens = tokens.skip(index).toList(growable: false);
  if (finalTokens.isEmpty) {
    return _manualMatch('unresolved_executable', const <String>['<redacted>']);
  }
  final resolvedTokens = <String>[];
  for (final token in finalTokens) {
    final resolved = _resolveToken(token, environment);
    if (!resolved.complete) {
      return _manualMatch('unresolved_variable', finalTokens);
    }
    resolvedTokens.add(resolved.value);
  }
  if (resolvedTokens.first.trim().isEmpty) {
    return _manualMatch('unresolved_executable', finalTokens);
  }

  final executable = _basename(resolvedTokens.first).toLowerCase();
  final args = resolvedTokens.skip(1).toList(growable: false);
  final display = _normalizedDisplay(finalTokens);

  if (const {'sh', 'bash', 'zsh'}.contains(executable)) {
    for (var argIndex = 0; argIndex < args.length - 1; argIndex += 1) {
      if (const {'-c', '-lc', '-ilc'}.contains(args[argIndex])) {
        return egressSensitiveCommandMatch(
          args[argIndex + 1],
          environment: environment,
        );
      }
    }
  }

  final lowerArgs = args
      .map((arg) => arg.toLowerCase())
      .toList(growable: false);
  if (lowerArgs.any((arg) => arg.contains('webhook'))) {
    return EgressPolicyMatch(reason: 'webhook_call', commandLine: display);
  }
  if (lowerArgs.any((arg) => arg.contains('upload'))) {
    return EgressPolicyMatch(reason: 'upload_api', commandLine: display);
  }

  if (executable == 'curl' || executable == 'wget') {
    if (args.any(_isExternalHttpUrl) || _hasUnclassifiedTransferTarget(args)) {
      return EgressPolicyMatch(
        reason: 'external_http_transfer',
        commandLine: display,
      );
    }
    return null;
  }

  if (_egressExecutables.contains(executable)) {
    return EgressPolicyMatch(
      reason: executable == 'mail' || executable == 'sendmail'
          ? 'external_mail_command'
          : 'external_transfer_command',
      commandLine: display,
    );
  }

  if (executable == 'git' && lowerArgs.contains('push')) {
    return EgressPolicyMatch(reason: 'git_push', commandLine: display);
  }
  if (executable == 'gh' &&
      lowerArgs.length >= 2 &&
      lowerArgs[0] == 'pr' &&
      lowerArgs[1] == 'create') {
    return EgressPolicyMatch(reason: 'pull_request', commandLine: display);
  }
  if (executable == 'hub' && lowerArgs.contains('pull-request')) {
    return EgressPolicyMatch(reason: 'pull_request', commandLine: display);
  }

  return null;
}

EgressPolicyMatch _manualMatch(String reason, List<String> tokens) {
  return EgressPolicyMatch(
    reason: reason,
    commandLine: _normalizedDisplay(tokens),
  );
}

String? commandLineFromPermissionRequest(AcpPermissionRequest request) {
  final invocation = _commandFromPermissionRequest(request);
  if (invocation == null) return null;
  return _commandLine(invocation.command, invocation.args);
}

_PermissionCommand? _commandFromPermissionRequest(
  AcpPermissionRequest request,
) {
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

  if (command == null || command.trim().isEmpty) return null;
  return _PermissionCommand(command.trim(), args);
}

class _PermissionCommand {
  const _PermissionCommand(this.command, this.args);

  final String command;
  final List<String> args;
}

const Set<String> _egressExecutables = {
  'ssh',
  'scp',
  'rsync',
  'sendmail',
  'mail',
};

Map<String, String> _transientEnvironment(AcpPermissionRequest request) {
  final raw = request.transientPolicyContext['environment'];
  if (raw is! Map) return const <String, String>{};
  return <String, String>{
    for (final entry in raw.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

String? _permissionCwd(AcpPermissionRequest request) {
  final cwd = request.metadata['cwd'];
  return cwd is String && cwd.trim().isNotEmpty ? cwd.trim() : null;
}

final RegExp _assignmentPattern = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$');
final RegExp _variablePattern = RegExp(
  r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))',
);

bool _isAssignment(String value) => _assignmentPattern.hasMatch(value);

({String name, String value}) _assignment(String value) {
  final match = _assignmentPattern.firstMatch(value)!;
  return (name: match.group(1)!, value: match.group(2)!);
}

_ResolvedToken _resolveToken(String token, Map<String, String> environment) {
  var complete = true;
  final resolved = token.replaceAllMapped(_variablePattern, (match) {
    final name = match.group(1) ?? match.group(2)!;
    final value = environment[name];
    if (value == null) {
      complete = false;
      return match.group(0)!;
    }
    return value;
  });
  return _ResolvedToken(resolved, complete);
}

class _ResolvedToken {
  const _ResolvedToken(this.value, this.complete);

  final String value;
  final bool complete;
}

List<List<String>> _commandSegments(List<String> tokens) {
  final result = <List<String>>[];
  var segment = <String>[];
  for (final token in tokens) {
    if (const {';', '&&', '||', '|'}.contains(token)) {
      if (segment.isNotEmpty) result.add(segment);
      segment = <String>[];
      continue;
    }
    segment.add(token);
  }
  if (segment.isNotEmpty) result.add(segment);
  return result;
}

String _normalizedDisplay(List<String> tokens) {
  if (tokens.isEmpty) return '<redacted>';
  return tokens.map(_safeDisplayToken).join(' ').trim();
}

String _safeDisplayToken(String token) {
  final assignment = _assignmentPattern.firstMatch(token);
  if (assignment != null) return '${assignment.group(1)}=<redacted>';
  if (!token.contains(RegExp(r'\s'))) return token;
  return "'${token.replaceAll("'", r"'\''")}'";
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

bool _hasUnclassifiedTransferTarget(List<String> args) {
  for (final arg in args) {
    if (arg.isEmpty || arg.startsWith('-')) continue;
    final uri = Uri.tryParse(arg);
    if (uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        !_isExternalHttpUrl(arg)) {
      continue;
    }
    return true;
  }
  return false;
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
    if (char == ';' || char == '|') {
      flush();
      if (index + 1 < commandLine.length && commandLine[index + 1] == char) {
        words.add('$char$char');
        index += 1;
      } else {
        words.add(char);
      }
      continue;
    }
    if (char == '&' &&
        index + 1 < commandLine.length &&
        commandLine[index + 1] == '&') {
      flush();
      words.add('&&');
      index += 1;
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
