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
  final tokenization = _shellWords(commandLine);
  if (!tokenization.syntaxComplete) {
    return _manualMatch(
      'malformed_shell_syntax',
      tokenization.tokens.isEmpty
          ? const <String>['<redacted>']
          : _tokenValues(tokenization.tokens),
    );
  }
  final commandWords = tokenization.tokens;
  final words = args.isEmpty
      ? commandWords
      : <_ShellToken>[...commandWords, ...args.map(_ShellToken.expanding)];
  if (words.isEmpty) return null;

  final segments = args.isEmpty
      ? _commandSegments(words)
      : <List<_ShellToken>>[words];
  for (final segment in segments) {
    final match = _classifySegment(segment, environment);
    if (match != null) return match;
  }
  return null;
}

EgressPolicyMatch? _classifySegment(
  List<_ShellToken> sourceTokens,
  Map<String, String> inheritedEnvironment,
) {
  final environment = Map<String, String>.of(inheritedEnvironment);
  final tokens = List<_ShellToken>.of(sourceTokens);
  var index = 0;

  while (index < tokens.length && _isAssignment(tokens[index].value)) {
    final assignment = _assignment(tokens[index]);
    final resolved = _resolveToken(assignment.value, environment);
    if (!resolved.complete) {
      return _manualMatch(
        'unresolved_variable',
        _tokenValues(tokens.skip(index)),
      );
    }
    environment[assignment.name] = resolved.value;
    index += 1;
  }
  if (index >= tokens.length) return null;

  while (index < tokens.length) {
    final wrapper = _basename(tokens[index].value).toLowerCase();
    if (_uncertainCommandWrappers.contains(wrapper)) {
      return _manualMatch(
        'unresolved_wrapper',
        _tokenValues(tokens.skip(index)),
      );
    }
    if (wrapper == 'env') {
      index += 1;
      var optionsEnded = false;
      while (index < tokens.length) {
        final token = tokens[index];
        final value = token.value;
        if (!optionsEnded && value == '--') {
          optionsEnded = true;
          index += 1;
          continue;
        }
        if (!optionsEnded &&
            (value == '-i' || value == '--ignore-environment')) {
          environment.clear();
          index += 1;
          continue;
        }
        if (!optionsEnded && value == '-u') {
          if (index + 1 >= tokens.length) {
            return _manualMatch(
              'unresolved_wrapper',
              _tokenValues(tokens.skip(index - 1)),
            );
          }
          environment.remove(tokens[index + 1].value);
          index += 2;
          continue;
        }
        if (!optionsEnded && value.startsWith('--unset=')) {
          environment.remove(value.substring('--unset='.length));
          index += 1;
          continue;
        }
        if (!optionsEnded && value.startsWith('-')) {
          return _manualMatch(
            'unresolved_wrapper',
            _tokenValues(tokens.skip(index - 1)),
          );
        }
        if (_isAssignment(value)) {
          final assignment = _assignment(token);
          final resolved = _resolveToken(assignment.value, environment);
          if (!resolved.complete) {
            return _manualMatch(
              'unresolved_variable',
              _tokenValues(tokens.skip(index)),
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
        final value = token.value;
        if (value == '--' || value == '-p') {
          index += 1;
          continue;
        }
        if (value == '-v' || value == '-V') return null;
        if (value.startsWith('-')) {
          return _manualMatch(
            'unresolved_wrapper',
            _tokenValues(tokens.skip(index - 1)),
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
      return _manualMatch('unresolved_variable', _tokenValues(finalTokens));
    }
    resolvedTokens.add(resolved.value);
  }
  if (resolvedTokens.first.trim().isEmpty) {
    return _manualMatch('unresolved_executable', _tokenValues(finalTokens));
  }

  final executable = _basename(resolvedTokens.first).toLowerCase();
  final args = resolvedTokens.skip(1).toList(growable: false);
  final display = _normalizedDisplay(_tokenValues(finalTokens));

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

  if (executable == 'curl' || executable == 'wget') {
    if (executable == 'curl' && _hasCurlTransferConfig(args)) {
      return EgressPolicyMatch(
        reason: 'unresolved_transfer_config',
        commandLine: display,
      );
    }
    final externalUrl = _externalHttpTransferUrl(executable, args);
    if (externalUrl == null) return null;
    final lowerUrl = externalUrl.toLowerCase();
    final reason = lowerUrl.contains('webhook')
        ? 'webhook_call'
        : lowerUrl.contains('upload')
        ? 'upload_api'
        : 'external_http_transfer';
    return EgressPolicyMatch(reason: reason, commandLine: display);
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

const Set<String> _uncertainCommandWrappers = {
  'sudo',
  'doas',
  'nice',
  'timeout',
  'nohup',
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

({String name, _ShellToken value}) _assignment(_ShellToken token) {
  final match = _assignmentPattern.firstMatch(token.value)!;
  return (
    name: match.group(1)!,
    value: token.substring(match.start + match.group(1)!.length + 1),
  );
}

_ResolvedToken _resolveToken(
  _ShellToken token,
  Map<String, String> environment,
) {
  var complete = true;
  final supportedExpansionIndexes = <int>{};
  final resolved = token.value.replaceAllMapped(_variablePattern, (match) {
    final expansionAllowed = token.allowsExpansionRange(match.start, match.end);
    if (!expansionAllowed) return match.group(0)!;
    supportedExpansionIndexes.addAll(
      Iterable<int>.generate(
        match.end - match.start,
        (index) => match.start + index,
      ),
    );
    final name = match.group(1) ?? match.group(2)!;
    final value = environment[name];
    if (value == null) {
      complete = false;
      return match.group(0)!;
    }
    return value;
  });
  for (var index = 0; index < token.value.length; index += 1) {
    if (!token.allowsExpansionAt(index)) continue;
    final character = token.value[index];
    if (character == '`' ||
        (character == r'$' && !supportedExpansionIndexes.contains(index))) {
      complete = false;
    }
  }
  return _ResolvedToken(resolved, complete);
}

class _ResolvedToken {
  const _ResolvedToken(this.value, this.complete);

  final String value;
  final bool complete;
}

List<List<_ShellToken>> _commandSegments(List<_ShellToken> tokens) {
  final result = <List<_ShellToken>>[];
  var segment = <_ShellToken>[];
  for (final token in tokens) {
    if (const {';', '&', '&&', '||', '|'}.contains(token.value)) {
      if (segment.isNotEmpty) result.add(segment);
      segment = <_ShellToken>[];
      continue;
    }
    segment.add(token);
  }
  if (segment.isNotEmpty) result.add(segment);
  return result;
}

List<String> _tokenValues(Iterable<_ShellToken> tokens) {
  return tokens.map((token) => token.value).toList(growable: false);
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

String? _externalHttpTransferUrl(String executable, List<String> args) {
  var optionsEnded = false;
  for (var index = 0; index < args.length; index += 1) {
    final arg = args[index];
    if (!optionsEnded && arg == '--') {
      optionsEnded = true;
      continue;
    }
    if (!optionsEnded && arg == '--url') {
      if (index + 1 < args.length) {
        final target = args[++index];
        if (!_isLocalTransferTarget(target)) return target;
      }
      continue;
    }
    if (!optionsEnded && arg.startsWith('--url=')) {
      final target = arg.substring('--url='.length);
      if (!_isLocalTransferTarget(target)) return target;
      continue;
    }
    if (!optionsEnded && _optionTakesSeparateValue(executable, arg)) {
      index += 1;
      continue;
    }
    if (!optionsEnded && _isOptionWithAttachedValue(executable, arg)) {
      continue;
    }
    if (!optionsEnded && arg.startsWith('-')) continue;
    if (arg != '-' && !_isLocalTransferTarget(arg)) return arg;
  }
  return null;
}

bool _hasCurlTransferConfig(List<String> args) {
  return args.any(
    (arg) =>
        arg == '-K' ||
        arg == '--config' ||
        arg.startsWith('--config=') ||
        (arg.startsWith('-K') && arg.length > 2),
  );
}

bool _optionTakesSeparateValue(String executable, String option) {
  final options = executable == 'wget'
      ? _wgetOptionsTakingValue
      : _curlOptionsTakingValue;
  return options.contains(option);
}

bool _isOptionWithAttachedValue(String executable, String option) {
  final options = executable == 'wget'
      ? _wgetOptionsTakingValue
      : _curlOptionsTakingValue;
  if (option.startsWith('--')) {
    final equalsIndex = option.indexOf('=');
    return equalsIndex > 2 &&
        options.contains(option.substring(0, equalsIndex));
  }
  final shortOptions = executable == 'wget'
      ? _wgetShortOptionsAllowingAttachedValue
      : _curlShortOptionsAllowingAttachedValue;
  return shortOptions.any(
    (prefix) => option.startsWith(prefix) && option.length > prefix.length,
  );
}

// Kept in option-name form so detached and --option=value parsing share one
// source of truth. Network endpoint options (for example --proxy and
// --doh-url) are intentionally omitted so they remain conservatively visible
// to the egress classifier.
const Set<String> _curlOptionsTakingValue = {
  '--abstract-unix-socket',
  '--alt-svc',
  '--aws-sigv4',
  '--cacert',
  '--capath',
  '-E',
  '--cert',
  '--cert-type',
  '--ciphers',
  '--connect-timeout',
  '-C',
  '--continue-at',
  '-b',
  '--cookie',
  '-c',
  '--cookie-jar',
  '--create-file-mode',
  '--crlfile',
  '--curves',
  '-d',
  '--data',
  '--data-ascii',
  '--data-binary',
  '--data-raw',
  '--data-urlencode',
  '--delegation',
  '--dns-interface',
  '--dns-ipv4-addr',
  '--dns-ipv6-addr',
  '--dns-servers',
  '-D',
  '--dump-header',
  '--engine',
  '--etag-compare',
  '--etag-save',
  '--expect100-timeout',
  '-F',
  '--form',
  '--form-string',
  '--ftp-account',
  '--ftp-alternative-to-user',
  '--ftp-method',
  '--ftp-ssl-ccc-mode',
  '--happy-eyeballs-timeout-ms',
  '--haproxy-clientip',
  '-H',
  '--header',
  '-h',
  '--help',
  '--hostpubmd5',
  '--hostpubsha256',
  '--hsts',
  '--interface',
  '--json',
  '--keepalive-time',
  '--key',
  '--key-type',
  '--krb',
  '--libcurl',
  '--limit-rate',
  '--local-port',
  '--login-options',
  '--mail-auth',
  '--mail-from',
  '--mail-rcpt',
  '--max-filesize',
  '--max-redirs',
  '-m',
  '--max-time',
  '--netrc-file',
  '--noproxy',
  '--oauth2-bearer',
  '-o',
  '--output',
  '--output-dir',
  '--parallel-max',
  '--pass',
  '--pinnedpubkey',
  '--proto',
  '--proto-default',
  '--proto-redir',
  '--proxy-cacert',
  '--proxy-capath',
  '--proxy-cert',
  '--proxy-cert-type',
  '--proxy-ciphers',
  '--proxy-crlfile',
  '--proxy-header',
  '--proxy-key',
  '--proxy-key-type',
  '--proxy-pass',
  '--proxy-pinnedpubkey',
  '--proxy-service-name',
  '--proxy-tls13-ciphers',
  '--proxy-tlsauthtype',
  '--proxy-tlspassword',
  '--proxy-tlsuser',
  '-U',
  '--proxy-user',
  '--pubkey',
  '-Q',
  '--quote',
  '--random-file',
  '-r',
  '--range',
  '--rate',
  '-e',
  '--referer',
  '-X',
  '--request',
  '--request-target',
  '--retry',
  '--retry-delay',
  '--retry-max-time',
  '--sasl-authzid',
  '--service-name',
  '-Y',
  '--speed-limit',
  '-y',
  '--speed-time',
  '--stderr',
  '-t',
  '--telnet-option',
  '--tftp-blksize',
  '-z',
  '--time-cond',
  '--tls-max',
  '--tls13-ciphers',
  '--tlsauthtype',
  '--tlspassword',
  '--tlsuser',
  '--trace',
  '--trace-ascii',
  '--trace-config',
  '--unix-socket',
  '-T',
  '--upload-file',
  '--url-query',
  '-u',
  '--user',
  '-A',
  '--user-agent',
  '--variable',
  '-w',
  '--write-out',
};

const Set<String> _curlShortOptionsAllowingAttachedValue = {
  '-E',
  '-C',
  '-b',
  '-c',
  '-d',
  '-D',
  '-F',
  '-H',
  '-h',
  '-m',
  '-o',
  '-U',
  '-Q',
  '-r',
  '-e',
  '-X',
  '-Y',
  '-y',
  '-t',
  '-z',
  '-T',
  '-u',
  '-A',
  '-w',
};

const Set<String> _wgetOptionsTakingValue = {
  '-O',
  '--output-document',
  '--post-data',
  '--post-file',
  '--header',
  '--user',
  '--password',
};

const Set<String> _wgetShortOptionsAllowingAttachedValue = {'-O'};

bool _isLocalTransferTarget(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return true;
  final lower = normalized.toLowerCase();
  if (lower.startsWith('file:') || lower.startsWith('data:')) return true;

  if (normalized.contains('://')) {
    final uri = Uri.tryParse(normalized);
    if (uri == null || uri.host.isEmpty) return false;
    return _isLoopbackHost(uri.host);
  }

  var authority = normalized.split('/').first;
  final userInfoEnd = authority.lastIndexOf('@');
  if (userInfoEnd >= 0) authority = authority.substring(userInfoEnd + 1);
  late final String host;
  if (authority.startsWith('[')) {
    final closingBracket = authority.indexOf(']');
    host = closingBracket > 0
        ? authority.substring(1, closingBracket)
        : authority;
  } else {
    host = authority.split(':').first;
  }
  return _isLoopbackHost(host);
}

bool _isLoopbackHost(String value) {
  final host = value.trim().toLowerCase();
  return host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '0.0.0.0' ||
      host == '::1';
}

_ShellTokenization _shellWords(String commandLine) {
  final words = <_ShellToken>[];
  var buffer = _ShellTokenBuilder();
  var quote = '';
  var escaped = false;

  void flush() {
    if (buffer.isEmpty) return;
    words.add(buffer.build());
    buffer = _ShellTokenBuilder();
  }

  for (var index = 0; index < commandLine.length; index += 1) {
    final char = commandLine[index];
    if (quote == "'") {
      if (char == quote) {
        quote = '';
      } else {
        buffer.write(char, allowsExpansion: false);
      }
      continue;
    }
    if (escaped) {
      buffer.write(char, allowsExpansion: false);
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (quote == '"') {
      if (char == quote) {
        quote = '';
      } else {
        buffer.write(char, allowsExpansion: true);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '\n' || char == '\r') {
      flush();
      if (words.isEmpty || words.last.value != ';') {
        words.add(_ShellToken.literal(';'));
      }
      continue;
    }
    if (char.trim().isEmpty) {
      flush();
      continue;
    }
    if (char == ';' || char == '|') {
      flush();
      if (index + 1 < commandLine.length && commandLine[index + 1] == char) {
        words.add(_ShellToken.literal('$char$char'));
        index += 1;
      } else {
        words.add(_ShellToken.literal(char));
      }
      continue;
    }
    if (char == '&') {
      flush();
      if (index + 1 < commandLine.length && commandLine[index + 1] == '&') {
        words.add(_ShellToken.literal('&&'));
        index += 1;
      } else {
        words.add(_ShellToken.literal('&'));
      }
      continue;
    }
    buffer.write(char, allowsExpansion: true);
  }
  flush();
  return _ShellTokenization(
    tokens: words,
    syntaxComplete: quote.isEmpty && !escaped,
  );
}

class _ShellTokenization {
  const _ShellTokenization({
    required this.tokens,
    required this.syntaxComplete,
  });

  final List<_ShellToken> tokens;
  final bool syntaxComplete;
}

class _ShellToken {
  const _ShellToken(this.value, this._expansionAllowed);

  factory _ShellToken.expanding(String value) {
    return _ShellToken(
      value,
      List<bool>.filled(value.length, true, growable: false),
    );
  }

  factory _ShellToken.literal(String value) {
    return _ShellToken(
      value,
      List<bool>.filled(value.length, false, growable: false),
    );
  }

  final String value;
  final List<bool> _expansionAllowed;

  bool allowsExpansionAt(int index) => _expansionAllowed[index];

  bool allowsExpansionRange(int start, int end) {
    for (var index = start; index < end; index += 1) {
      if (!_expansionAllowed[index]) return false;
    }
    return true;
  }

  _ShellToken substring(int start) {
    return _ShellToken(
      value.substring(start),
      _expansionAllowed.sublist(start),
    );
  }
}

class _ShellTokenBuilder {
  final StringBuffer _value = StringBuffer();
  final List<bool> _expansionAllowed = <bool>[];

  bool get isEmpty => _value.isEmpty;

  void write(String value, {required bool allowsExpansion}) {
    _value.write(value);
    _expansionAllowed.addAll(
      List<bool>.filled(value.length, allowsExpansion, growable: false),
    );
  }

  _ShellToken build() => _ShellToken(_value.toString(), _expansionAllowed);
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
