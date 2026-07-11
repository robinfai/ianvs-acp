import 'dart:convert';

import '../acp/acp_permission_request.dart';

class EgressPolicyMatch {
  const EgressPolicyMatch({required this.reason, required this.commandLine});

  final String reason;
  final String commandLine;
}

class PermissionDisplayEntry {
  const PermissionDisplayEntry({required this.label, required this.value});

  final String label;
  final String value;
}

class PermissionDisplayContext {
  PermissionDisplayContext._({
    required List<PermissionDisplayEntry> entries,
    required this.isComplete,
    required this.warning,
  }) : entries = List<PermissionDisplayEntry>.unmodifiable(entries);

  static const String incompleteWarning =
      'Some operation details could not be displayed safely.';

  factory PermissionDisplayContext.complete(
    List<PermissionDisplayEntry> entries,
  ) {
    return PermissionDisplayContext._(
      entries: entries,
      isComplete: true,
      warning: null,
    );
  }

  factory PermissionDisplayContext.incomplete() {
    return PermissionDisplayContext._(
      entries: const <PermissionDisplayEntry>[],
      isComplete: false,
      warning: incompleteWarning,
    );
  }

  final List<PermissionDisplayEntry> entries;
  final bool isComplete;
  final String? warning;
}

class PermissionDisplayContextLimits {
  PermissionDisplayContextLimits({
    this.maxUtf8Bytes = 16 * 1024,
    this.maxEntries = 16,
    this.maxDepth = 4,
    this.maxNodes = 128,
  }) {
    if (maxUtf8Bytes <= 0) {
      throw ArgumentError.value(maxUtf8Bytes, 'maxUtf8Bytes');
    }
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    if (maxDepth <= 0) {
      throw ArgumentError.value(maxDepth, 'maxDepth');
    }
    if (maxNodes <= 0) {
      throw ArgumentError.value(maxNodes, 'maxNodes');
    }
  }

  final int maxUtf8Bytes;
  final int maxEntries;
  final int maxDepth;
  final int maxNodes;
}

final PermissionDisplayContextLimits _defaultPermissionDisplayContextLimits =
    PermissionDisplayContextLimits();

PermissionDisplayContext permissionDisplayContextForRequest(
  AcpPermissionRequest request, {
  PermissionDisplayContextLimits? limits,
  Object? Function(String source)? decodeRawJsonForTesting,
}) {
  final effectiveLimits = limits ?? _defaultPermissionDisplayContextLimits;
  final projection = _PermissionDisplayProjectionBuilder(
    effectiveLimits,
    decodeRawJsonForTesting ?? jsonDecode,
  ).build(request.metadata);
  if (projection == null) return PermissionDisplayContext.incomplete();
  if (projection.root.isEmpty) {
    return PermissionDisplayContext.complete(const <PermissionDisplayEntry>[]);
  }

  final values = <String, List<String>>{
    'cwd': <String>[],
    'path': <String>[],
    'target': <String>[],
  };
  for (final container in projection.containers) {
    for (final key in values.keys) {
      if (!container.containsKey(key)) continue;
      final value = container[key];
      if (value is! String || value.trim().isEmpty) {
        return PermissionDisplayContext.incomplete();
      }
      final normalized = value.trim();
      if (!values[key]!.contains(normalized)) values[key]!.add(normalized);
    }
  }
  if (values.values.any((candidates) => candidates.length > 1)) {
    return PermissionDisplayContext.incomplete();
  }

  final entries = <PermissionDisplayEntry>[];
  if (_containersHavePermissionCommandEvidence(projection.containers)) {
    final invocation = _commandFromPermissionDisplayContainers(
      request,
      projection.containers,
    );
    if (invocation == null || invocation.ambiguous) {
      return PermissionDisplayContext.incomplete();
    }
    final commandLine = _commandLine(invocation.command, invocation.args);
    if (commandLine == null || commandLine == '<redacted>') {
      return PermissionDisplayContext.incomplete();
    }
    entries.add(PermissionDisplayEntry(label: 'Command', value: commandLine));
  }

  for (final field in const <({String key, String label})>[
    (key: 'cwd', label: 'Working directory'),
    (key: 'path', label: 'Path'),
    (key: 'target', label: 'Target'),
  ]) {
    final candidates = values[field.key]!;
    if (candidates.isNotEmpty) {
      entries.add(
        PermissionDisplayEntry(label: field.label, value: candidates.single),
      );
    }
  }
  return PermissionDisplayContext.complete(entries);
}

_PermissionCommand? _commandFromPermissionDisplayContainers(
  AcpPermissionRequest request,
  List<Map<String, Object?>> containers,
) {
  return _permissionCommandFromResolvedContainers(
    request,
    containers.map(_resolvePermissionCommandContainer).toList(growable: false),
    allowTextFallback: false,
  );
}

const List<String> _permissionDisplayScalarKeys = <String>[
  ..._permissionCommandKeys,
  ..._permissionArgumentKeys,
  'cwd',
  'path',
  'target',
];

const List<String> _permissionDisplayContainerKeys = <String>[
  'toolCall',
  'rawInput',
  'raw_input',
  'input',
];

class _PermissionDisplayProjection {
  const _PermissionDisplayProjection({
    required this.root,
    required this.containers,
  });

  final Map<String, Object?> root;
  final List<Map<String, Object?>> containers;
}

class _PermissionDisplayProjectionBuilder {
  _PermissionDisplayProjectionBuilder(this.limits, this.decodeRawJson);

  final PermissionDisplayContextLimits limits;
  final Object? Function(String source) decodeRawJson;
  var _utf8Bytes = 0;
  var _entries = 0;
  var _nodes = 0;
  final List<Map<String, Object?>> _containers = <Map<String, Object?>>[];
  var _failed = false;

  _PermissionDisplayProjection? build(Map<String, Object?> metadata) {
    try {
      final root = _projectMap(metadata, depth: 0, countUtf8: true);
      if (_failed || root == null) return null;
      return _PermissionDisplayProjection(
        root: root,
        containers: List<Map<String, Object?>>.unmodifiable(_containers),
      );
    } on FormatException {
      return null;
    }
  }

  Map<String, Object?>? _projectMap(
    Map source, {
    required int depth,
    required bool countUtf8,
    bool takeSelfNode = true,
  }) {
    if (depth > limits.maxDepth || (takeSelfNode && !_takeNode())) {
      return _fail();
    }
    final projected = <String, Object?>{};

    for (final key in _permissionDisplayScalarKeys) {
      if (_failed) return null;
      if (!source.containsKey(key)) continue;
      if (!_takeEntry()) return _fail();
      if (_permissionArgumentKeys.contains(key) && depth >= limits.maxDepth) {
        return _fail();
      }
      if (!_takeNode()) return _fail();
      final raw = source[key];
      if (_permissionArgumentKeys.contains(key)) {
        final args = _projectStringList(
          raw,
          depth: depth + 1,
          countUtf8: countUtf8,
        );
        if (args == null) return _fail();
        projected[key] = args;
        continue;
      }
      if (raw is! String || !_addUtf8(raw, countUtf8: countUtf8)) {
        return _fail();
      }
      final normalized = raw.trim();
      if (normalized.isEmpty) return _fail();
      projected[key] = normalized;
    }

    for (final key in _permissionDisplayContainerKeys) {
      if (_failed) return null;
      if (!source.containsKey(key)) continue;
      if (!_takeEntry()) return _fail();
      if (depth >= limits.maxDepth || !_takeNode()) return _fail();
      final raw = source[key];
      Map? nested;
      var nestedCountsUtf8 = countUtf8;
      if (raw is Map) {
        nested = raw;
      } else if (raw is String) {
        if (!_addUtf8(raw, countUtf8: countUtf8)) {
          return _fail();
        }
        if (key == 'input' && !raw.trimLeft().startsWith('{')) {
          continue;
        }
        final decoded = decodeRawJson(raw);
        if (decoded is! Map) return _fail();
        nested = decoded;
        nestedCountsUtf8 = false;
      } else {
        return _fail();
      }
      final nestedProjection = _projectMap(
        nested,
        depth: depth + 1,
        countUtf8: nestedCountsUtf8,
        takeSelfNode: raw is String,
      );
      if (nestedProjection == null) return _fail();
      projected[key] = nestedProjection;
    }

    final immutable = Map<String, Object?>.unmodifiable(projected);
    _containers.add(immutable);
    return immutable;
  }

  List<String>? _projectStringList(
    Object? raw, {
    required int depth,
    required bool countUtf8,
  }) {
    if (raw is! List || depth > limits.maxDepth) return null;
    final result = <String>[];
    var index = 0;
    while (index < raw.length) {
      if (!_takeNode()) return null;
      final item = raw[index++];
      if (item is! String || !_addUtf8(item, countUtf8: countUtf8)) {
        return null;
      }
      result.add(item);
    }
    return List<String>.unmodifiable(result);
  }

  bool _takeEntry() {
    if (_entries >= limits.maxEntries) {
      _failed = true;
      return false;
    }
    _entries += 1;
    return true;
  }

  bool _takeNode() {
    if (_nodes >= limits.maxNodes) {
      _failed = true;
      return false;
    }
    _nodes += 1;
    return true;
  }

  bool _addUtf8(String value, {required bool countUtf8}) {
    if (!countUtf8) return true;
    final remaining = limits.maxUtf8Bytes - _utf8Bytes;
    if (value.length > remaining) {
      _failed = true;
      return false;
    }
    final length = utf8.encode(value).length;
    if (length > remaining) {
      _failed = true;
      return false;
    }
    _utf8Bytes += length;
    return true;
  }

  T? _fail<T>() {
    _failed = true;
    return null;
  }
}

bool _containersHavePermissionCommandEvidence(
  List<Map<String, Object?>> containers,
) {
  for (final container in containers) {
    for (final key in _permissionCommandKeys) {
      if (container.containsKey(key)) return true;
    }
    for (final key in _permissionArgumentKeys) {
      if (container.containsKey(key)) return true;
    }
  }
  return false;
}

bool isEgressSensitiveCommand(String commandLine) {
  return egressSensitiveCommandMatch(commandLine) != null;
}

EgressPolicyMatch? egressPolicyMatchForPermission(
  AcpPermissionRequest request,
) {
  final invocation = _commandFromPermissionRequest(request);
  if (invocation != null) {
    if (invocation.ambiguous) {
      return const EgressPolicyMatch(
        reason: 'ambiguous_command_metadata',
        commandLine: '<redacted>',
      );
    }
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
  if (tokenization.tokens.any((token) => token.hasShellControl)) {
    return _manualMatch(
      'unresolved_shell_control',
      _tokenValues(tokenization.tokens),
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
    final wrapper = _executableName(tokens[index].value);
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
    if (wrapper == 'exec') {
      index += 1;
      if (index < tokens.length && tokens[index].value == '--') index += 1;
      if (index >= tokens.length) {
        return _manualMatch('unresolved_executable', const <String>['exec']);
      }
      if (tokens[index].value.startsWith('-')) {
        return _manualMatch(
          'unresolved_wrapper',
          _tokenValues(tokens.skip(index - 1)),
        );
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

  final executable = _executableName(resolvedTokens.first);
  final args = resolvedTokens.skip(1).toList(growable: false);
  final display = _normalizedDisplay(_tokenValues(finalTokens));

  if (executable == 'find' &&
      args.any(
        (arg) =>
            arg == '-exec' ||
            arg == '-execdir' ||
            arg == '-ok' ||
            arg == '-okdir',
      )) {
    return EgressPolicyMatch(
      reason: 'unresolved_wrapper',
      commandLine: display,
    );
  }

  if (_posixShellExecutables.contains(executable)) {
    final commandIndex = _posixShellCommandIndex(args);
    if (commandIndex != null) {
      final nested = egressSensitiveCommandMatch(
        args[commandIndex],
        environment: environment,
      );
      return nested == null
          ? null
          : EgressPolicyMatch(reason: nested.reason, commandLine: display);
    }
    return EgressPolicyMatch(
      reason: 'unresolved_wrapper',
      commandLine: display,
    );
  }

  if (_powerShellExecutables.contains(executable)) {
    return EgressPolicyMatch(
      reason: 'unresolved_wrapper',
      commandLine: display,
    );
  }

  if (_multiCallExecutableRoot(executable) != null) {
    if (args.isNotEmpty &&
        _posixShellExecutables.contains(_executableName(args.first))) {
      final nested = egressSensitiveCommandMatch(
        args.first,
        args: args.skip(1).toList(growable: false),
        environment: environment,
      );
      return nested == null
          ? null
          : EgressPolicyMatch(reason: nested.reason, commandLine: display);
    }
    return EgressPolicyMatch(
      reason: 'unresolved_wrapper',
      commandLine: display,
    );
  }

  if (_isScriptInterpreterExecutable(executable)) {
    return EgressPolicyMatch(
      reason: 'script_interpreter',
      commandLine: display,
    );
  }

  final lowerArgs = args
      .map((arg) => arg.toLowerCase())
      .toList(growable: false);

  if (executable == 'curl' || executable == 'wget') {
    if (_hasExternalProxyEnvironment(environment)) {
      return EgressPolicyMatch(
        reason: 'external_proxy_environment',
        commandLine: display,
      );
    }
    if (executable == 'curl' && _hasCurlTransferConfig(args)) {
      return EgressPolicyMatch(
        reason: 'unresolved_transfer_config',
        commandLine: display,
      );
    }
    if (executable == 'curl' && args.any(_isCurlExpandOption)) {
      return EgressPolicyMatch(
        reason: 'unresolved_transfer_expansion',
        commandLine: display,
      );
    }
    if (executable == 'curl') {
      final rewrite = _curlEndpointRewriteDisposition(args);
      if (rewrite == _EndpointRewriteDisposition.external ||
          rewrite == _EndpointRewriteDisposition.unresolved) {
        return EgressPolicyMatch(
          reason: rewrite == _EndpointRewriteDisposition.external
              ? 'external_endpoint_rewrite'
              : 'unresolved_endpoint_rewrite',
          commandLine: display,
        );
      }
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

final RegExp _shellShortOptionPattern = RegExp(
  r'^-[abcefihklmnprstuvxBCDEHOPT]+$',
);

const Set<String> _posixShellExecutables = {
  'sh',
  'bash',
  'zsh',
  'dash',
  'ksh',
  'mksh',
  'fish',
  'csh',
  'tcsh',
  'nu',
  'ash',
  'yash',
  'xonsh',
  'osh',
};

const Set<String> _powerShellExecutables = {
  'pwsh',
  'powershell',
  'pwsh-preview',
  'powershell-preview',
};
const List<String> _scriptInterpreterRoots = <String>[
  'python',
  'pypy',
  'node',
  'nodejs',
  'ruby',
  'perl',
  'php',
  'osascript',
  'lua',
  'luajit',
  'rscript',
  'r',
  'julia',
  'tclsh',
  'wish',
];

final RegExp _scriptInterpreterSuffixPattern = RegExp(
  r'^(?:-?\d+(?:\.\d+)*)?(?:[-_.](?:bin|static))?$',
);

bool _isScriptInterpreterExecutable(String executable) {
  // executable is already a lowercase basename with a terminal .exe removed.
  // Accept only a known root followed by a numeric/dotted version and an
  // optional packaging suffix; arbitrary prefixes such as node_modules do not
  // become interpreter launchers.
  for (final root in _scriptInterpreterRoots) {
    if (!executable.startsWith(root)) continue;
    if (root == 'r') return executable == root;
    final suffix = executable.substring(root.length);
    if (_scriptInterpreterSuffixPattern.hasMatch(suffix)) return true;
  }
  return false;
}

String? _multiCallExecutableRoot(String executable) {
  // _executableName has already reduced this to a lowercase basename and
  // removed a terminal .exe. A dot/dash suffix is a packaging variant such as
  // busybox.static; only the exact busybox/toybox root is accepted.
  for (final root in const <String>['busybox', 'toybox']) {
    if (executable == root ||
        executable.startsWith('$root.') ||
        executable.startsWith('$root-')) {
      return root;
    }
  }
  return null;
}

int? _posixShellCommandIndex(List<String> args) {
  for (var index = 0; index < args.length; index += 1) {
    final option = args[index];
    if (option == '-o' || option == '+o') {
      if (index + 1 >= args.length) return null;
      index += 1;
      continue;
    }
    if (option.startsWith('--') || !option.startsWith('-')) return null;
    if (!_shellShortOptionPattern.hasMatch(option)) return null;
    if (option.substring(1).contains('c')) {
      return index + 1 < args.length ? index + 1 : null;
    }
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
  if (invocation.ambiguous) return '<redacted>';
  return _commandLine(invocation.command, invocation.args);
}

Map<String, Object?> redactedPermissionMetadataForAudit(
  AcpPermissionRequest request,
) {
  final invocation = _commandFromPermissionRequest(request);
  if (invocation == null) return const <String, Object?>{};
  if (invocation.ambiguous) {
    return const <String, Object?>{'commandLine': '<redacted>'};
  }
  final tokenization = _shellWords(invocation.command);
  final tokens = <_ShellToken>[
    ...tokenization.tokens,
    ...invocation.args.map(_ShellToken.expanding),
  ];
  return <String, Object?>{
    'commandLine': _normalizedDisplay(_tokenValues(tokens)),
  };
}

String redactedPermissionTitleForAudit(AcpPermissionRequest request) {
  final display = _permissionCommandDisplayForAudit(request);
  return display == null ? request.title : 'Command: $display';
}

String redactedPermissionRationaleForAudit(AcpPermissionRequest request) {
  return _commandFromPermissionRequest(request) == null
      ? request.rationale
      : 'Command details withheld from audit.';
}

String? _permissionCommandDisplayForAudit(AcpPermissionRequest request) {
  final invocation = _commandFromPermissionRequest(request);
  if (invocation == null) return null;
  if (invocation.ambiguous) return '<redacted>';
  final tokenization = _shellWords(invocation.command);
  return _normalizedDisplay(<String>[
    ..._tokenValues(tokenization.tokens),
    ...invocation.args,
  ]);
}

_PermissionCommand? _commandFromPermissionRequest(
  AcpPermissionRequest request,
) {
  final metadata = request.metadata;
  final nestedToolCall = metadata['toolCall'];
  final toolCallSource = nestedToolCall is Map ? nestedToolCall : null;
  return _permissionCommandFromResolvedContainers(
    request,
    <_PermissionCommandContainer>[
      _resolvePermissionCommandContainer(metadata),
      _resolvePermissionCommandContainer(toolCallSource),
    ],
  );
}

_PermissionCommand? _permissionCommandFromResolvedContainers(
  AcpPermissionRequest request,
  List<_PermissionCommandContainer> containers, {
  bool allowTextFallback = true,
}) {
  final sawCommandEvidence = containers.any(
    (container) => container.sawCommandEvidence,
  );
  final sawArgsEvidence = containers.any(
    (container) => container.sawArgsEvidence,
  );
  if (containers.any((container) => container.ambiguous)) {
    if (sawCommandEvidence ||
        (sawArgsEvidence && _isExplicitCommandPermission(request))) {
      return const _PermissionCommand.ambiguous();
    }
    return null;
  }

  _PermissionCommandContainer? selected;
  for (final container in containers) {
    if (container.command == null) continue;
    if (selected == null) {
      selected = container;
      continue;
    }
    if (selected.command != container.command ||
        selected.hasArgs != container.hasArgs ||
        !_sameStringList(selected.args, container.args)) {
      return const _PermissionCommand.ambiguous();
    }
  }
  if (selected != null) {
    return _PermissionCommand(selected.command!, selected.args);
  }
  if (!allowTextFallback) return null;
  final textCommand =
      _commandLineFromPermissionText(request.title) ??
      _commandLineFromPermissionText(request.rationale);
  return textCommand == null ? null : _PermissionCommand(textCommand, const []);
}

bool _isExplicitCommandPermission(AcpPermissionRequest request) {
  final kind = request.toolKind?.trim().toLowerCase();
  final tool = request.toolName.trim().toLowerCase();
  return const {'execute', 'command', 'terminal', 'shell'}.contains(kind) ||
      const {'execute', 'command', 'terminal', 'shell', 'bash'}.contains(tool);
}

class _PermissionCommand {
  const _PermissionCommand(this.command, this.args) : ambiguous = false;

  const _PermissionCommand.ambiguous()
    : command = '<redacted>',
      args = const <String>[],
      ambiguous = true;

  final String command;
  final List<String> args;
  final bool ambiguous;
}

const List<String> _permissionCommandKeys = <String>[
  'command',
  'cmd',
  'commandLine',
  'command_line',
  'shellCommand',
  'shell_command',
  'script',
];
const List<String> _permissionArgumentKeys = <String>[
  'args',
  'argv',
  'arguments',
];
const List<String> _permissionRawInputKeys = <String>[
  'rawInput',
  'raw_input',
  'input',
];

class _PermissionCommandContainer {
  const _PermissionCommandContainer({
    required this.command,
    required this.args,
    required this.hasArgs,
    required this.ambiguous,
    required this.sawCommandEvidence,
    required this.sawArgsEvidence,
  });

  final String? command;
  final List<String> args;
  final bool hasArgs;
  final bool ambiguous;
  final bool sawCommandEvidence;
  final bool sawArgsEvidence;
}

_PermissionCommandContainer _resolvePermissionCommandContainer(Map? source) {
  if (source == null) {
    return const _PermissionCommandContainer(
      command: null,
      args: <String>[],
      hasArgs: false,
      ambiguous: false,
      sawCommandEvidence: false,
      sawArgsEvidence: false,
    );
  }
  final sources = <Map>[source];
  var malformed = false;
  for (final key in <String>[
    ..._permissionRawInputKeys,
    ..._permissionArgumentKeys,
  ]) {
    if (!source.containsKey(key)) continue;
    final value = source[key];
    final isArgumentList =
        _permissionArgumentKeys.contains(key) && value is List;
    if (isArgumentList) continue;
    if (value == null) {
      malformed = true;
      continue;
    }
    final decoded = _decodedJsonObject(value);
    if (decoded == null) {
      if (_permissionRawInputKeys.contains(key) ||
          _permissionArgumentKeys.contains(key)) {
        malformed = true;
      }
      continue;
    }
    sources.add(decoded);
  }

  final commands = <String>[];
  final argumentLists = <List<String>>[];
  var sawCommandEvidence = false;
  var sawArgsEvidence = false;
  for (final candidate in sources) {
    for (final key in _permissionCommandKeys) {
      if (!candidate.containsKey(key)) continue;
      sawCommandEvidence = true;
      final value = candidate[key];
      if (value is! String || value.trim().isEmpty) {
        malformed = true;
        continue;
      }
      final command = value.trim();
      if (!commands.contains(command)) commands.add(command);
    }
    for (final key in _permissionArgumentKeys) {
      if (!candidate.containsKey(key)) continue;
      sawArgsEvidence = true;
      final value = candidate[key];
      if (identical(candidate, source) && value is! List) continue;
      if (value is! List || value.any((item) => item is! String)) {
        malformed = true;
        continue;
      }
      final args = value.cast<String>().toList(growable: false);
      if (!argumentLists.any((existing) => _sameStringList(existing, args))) {
        argumentLists.add(args);
      }
    }
  }

  final hasArgs = argumentLists.isNotEmpty;
  final command = commands.length == 1 ? commands.single : null;
  final ambiguous =
      malformed ||
      commands.length > 1 ||
      argumentLists.length > 1 ||
      (command == null && hasArgs);
  return _PermissionCommandContainer(
    command: command,
    args: argumentLists.length == 1 ? argumentLists.single : const <String>[],
    hasArgs: hasArgs,
    ambiguous: ambiguous,
    sawCommandEvidence: sawCommandEvidence,
    sawArgsEvidence: sawArgsEvidence,
  );
}

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
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
  'xargs',
  'parallel',
  'eval',
  'source',
  '.',
  'time',
  'if',
  'for',
  'while',
  'until',
  'case',
  'select',
  'function',
  'then',
  'do',
  'coproc',
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

bool _hasExternalProxyEnvironment(Map<String, String> environment) {
  for (final entry in environment.entries) {
    final name = entry.key.toLowerCase();
    if (!const {
      'http_proxy',
      'https_proxy',
      'ftp_proxy',
      'all_proxy',
    }.contains(name)) {
      continue;
    }
    final proxy = entry.value.trim();
    if (proxy.isNotEmpty && !_isLocalTransferTarget(proxy)) return true;
  }
  return false;
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
    if (token.allowsFieldSplittingAt(match.start) &&
        value.contains(RegExp(r'[\s*?\[\]{}();&|<>]'))) {
      complete = false;
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

String _normalizedDisplay(List<String> tokens, {int depth = 0}) {
  if (tokens.isEmpty) return '<redacted>';
  if (depth >= 4) return '<redacted>';
  final executable = _executableName(tokens.first);
  final args = tokens.skip(1).toList(growable: false);

  if (_isScriptInterpreterExecutable(executable)) {
    return args.isEmpty
        ? _shellDisplayArg(tokens.first)
        : '${_shellDisplayArg(tokens.first)} <redacted>';
  }

  if (_multiCallExecutableRoot(executable) != null) {
    if (args.isNotEmpty &&
        _posixShellExecutables.contains(_executableName(args.first))) {
      final nested = _normalizedDisplay(args, depth: depth + 1);
      return '${_shellDisplayArg(tokens.first)} ${_shellDisplayArg(nested)}';
    }
    return args.isEmpty
        ? _shellDisplayArg(tokens.first)
        : '${_shellDisplayArg(tokens.first)} <redacted>';
  }

  if (_posixShellExecutables.contains(executable)) {
    final commandIndex = _posixShellCommandIndex(args);
    if (commandIndex == null) {
      return args.isEmpty
          ? _shellDisplayArg(tokens.first)
          : '${_shellDisplayArg(tokens.first)} <redacted>';
    }
    final absoluteIndex = commandIndex + 1;
    final nestedTokens = _nestedCommandTokens(tokens[absoluteIndex]);
    final prefix = _normalizedDisplayFlat(tokens.sublist(0, absoluteIndex));
    final nested = nestedTokens.isEmpty
        ? '<redacted>'
        : _normalizedDisplay(nestedTokens, depth: depth + 1);
    return '$prefix ${_shellDisplayArg(nested)}'
        '${absoluteIndex + 1 < tokens.length ? ' <redacted>' : ''}';
  }

  if (_powerShellExecutables.contains(executable)) {
    return '${_shellDisplayArg(tokens.first)} <redacted>';
  }

  if (executable == 'eval') {
    if (args.isEmpty) return _shellDisplayArg(tokens.first);
    final nestedTokens = <String>[
      ..._nestedCommandTokens(args.first),
      ...args.skip(1),
    ];
    final nested = nestedTokens.isEmpty
        ? '<redacted>'
        : _normalizedDisplay(nestedTokens, depth: depth + 1);
    return '${_shellDisplayArg(tokens.first)} ${_shellDisplayArg(nested)}';
  }

  if (_uncertainCommandWrappers.contains(executable)) {
    return args.isEmpty
        ? _shellDisplayArg(tokens.first)
        : '${_shellDisplayArg(tokens.first)} <redacted>';
  }

  return _normalizedDisplayFlat(tokens);
}

List<String> _nestedCommandTokens(String command) {
  final tokenization = _shellWords(command);
  return tokenization.syntaxComplete
      ? _tokenValues(tokenization.tokens)
      : const <String>[];
}

String _normalizedDisplayFlat(List<String> tokens) {
  if (tokens.isEmpty) return '<redacted>';
  final displayed = <String>[];
  var redactNext = false;
  for (final token in tokens) {
    final assignment = _assignmentPattern.firstMatch(token);
    if (assignment != null) {
      displayed.add('${assignment.group(1)}=<redacted>');
      redactNext = false;
      continue;
    }
    if (redactNext) {
      displayed.add('<redacted>');
      redactNext = false;
      continue;
    }
    if (_isSensitiveDetachedOption(token)) {
      displayed.add(token);
      redactNext = true;
      continue;
    }
    final sensitiveAttached = _redactedSensitiveAttachedOption(token);
    if (sensitiveAttached != null) {
      displayed.add(sensitiveAttached);
      continue;
    }
    final equalsIndex = token.startsWith('--') ? token.indexOf('=') : -1;
    if (equalsIndex > 2) {
      final name = token.substring(0, equalsIndex);
      final value = token.substring(equalsIndex + 1);
      displayed.add('$name=${_sanitizeAuditValue(value)}');
      continue;
    }
    displayed.add(_sanitizeAuditValue(token));
  }
  return displayed.map(_shellDisplayArg).join(' ').trim();
}

const Set<String> _sensitiveDetachedOptions = {
  '-u',
  '--user',
  '-U',
  '--proxy-user',
  '-H',
  '--header',
  '--proxy-header',
  '-b',
  '--cookie',
  '-d',
  '--data',
  '--data-ascii',
  '--data-binary',
  '--data-raw',
  '--data-urlencode',
  '-F',
  '--form',
  '--form-string',
  '--json',
  '--oauth2-bearer',
  '--pass',
  '--proxy-pass',
  '--url-query',
  '--tlspassword',
  '--proxy-tlspassword',
  '-E',
  '--cert',
  '--proxy-cert',
  '--key',
  '--proxy-key',
  '--password',
  '--http-password',
  '--ftp-password',
  '--proxy-password',
  '--post-data',
  '--post-file',
  '--body-data',
  '--body-file',
  '--variable',
};

bool _isSensitiveDetachedOption(String option) {
  if (option.contains('=')) return false;
  return _sensitiveDetachedOptions.contains(option) ||
      _isCurlExpandOption(option);
}

bool _isCurlExpandOption(String option) {
  final name = option.split('=').first;
  return name.startsWith('--expand-') && name.length > '--expand-'.length;
}

const Set<String> _sensitiveShortOptions = {
  '-u',
  '-U',
  '-H',
  '-b',
  '-d',
  '-F',
  '-E',
};

String? _redactedSensitiveAttachedOption(String token) {
  if (token.startsWith('--')) {
    final equalsIndex = token.indexOf('=');
    if (equalsIndex > 2) {
      final name = token.substring(0, equalsIndex);
      if (_isSensitiveDetachedOption(name)) {
        return '$name=<redacted>';
      }
    }
    return null;
  }
  for (final option in _sensitiveShortOptions) {
    if (token.startsWith(option) && token.length > option.length) {
      return '$option<redacted>';
    }
  }
  return null;
}

String _sanitizeAuditValue(String value) {
  if (_isPureShellReference(value)) return value;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
    return _sanitizeBareAuditTarget(value);
  }
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  final origin = '${uri.scheme}://$host${uri.hasPort ? ':${uri.port}' : ''}';
  final hasSensitiveSuffix =
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment;
  return hasSensitiveSuffix ? '$origin/<redacted>' : origin;
}

String _sanitizeBareAuditTarget(String value) {
  if (!_looksLikeNetworkTarget(value)) return value;
  final separatorIndexes = <int>[
    for (final separator in const ['/', '?', '#'])
      if (value.contains(separator)) value.indexOf(separator),
  ];
  final suffixStart = separatorIndexes.isEmpty
      ? value.length
      : (separatorIndexes..sort()).first;
  final authority = value.substring(0, suffixStart);
  final safeAuthority = authority.split('@').last;
  final hasSensitiveSuffix =
      authority.contains('@') || suffixStart < value.length;
  return hasSensitiveSuffix ? '$safeAuthority/<redacted>' : safeAuthority;
}

bool _isPureShellReference(String value) {
  return RegExp(
    r'^\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[^}]+\}|[0-9@*#?!$-]+)$',
  ).hasMatch(value);
}

String _basename(String value) {
  final normalized = value.replaceAll('\\', '/');
  final index = normalized.lastIndexOf('/');
  return index == -1 ? normalized : normalized.substring(index + 1);
}

String _executableName(String value) {
  final basename = _basename(value).toLowerCase();
  return basename.endsWith('.exe')
      ? basename.substring(0, basename.length - 4)
      : basename;
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
    if (!optionsEnded && (arg == '--resolve' || arg == '--connect-to')) {
      index += 1;
      continue;
    }
    if (!optionsEnded &&
        (arg.startsWith('--resolve=') || arg.startsWith('--connect-to='))) {
      continue;
    }
    if (!optionsEnded && _networkEndpointOptions.contains(arg)) {
      if (index + 1 < args.length) {
        final target = args[++index];
        if (!_isLocalTransferTarget(target)) return target;
      }
      continue;
    }
    if (!optionsEnded) {
      final endpointValue = _attachedNetworkEndpointValue(arg);
      if (endpointValue != null) {
        if (!_isLocalTransferTarget(endpointValue)) return endpointValue;
        continue;
      }
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
    if (!optionsEnded && arg.startsWith('--')) {
      final equalsIndex = arg.indexOf('=');
      if (equalsIndex > 2) {
        final value = arg.substring(equalsIndex + 1);
        if (_looksLikeNetworkTarget(value) && !_isLocalTransferTarget(value)) {
          return value;
        }
      }
    }
    if (!optionsEnded && arg.startsWith('-')) continue;
    if (arg != '-' && !_isLocalTransferTarget(arg)) return arg;
  }
  return null;
}

enum _EndpointRewriteDisposition { safe, external, unresolved }

_EndpointRewriteDisposition _curlEndpointRewriteDisposition(List<String> args) {
  var disposition = _EndpointRewriteDisposition.safe;
  for (var index = 0; index < args.length; index += 1) {
    final option = args[index];
    String? value;
    var isResolve = false;
    if (option == '--resolve' || option == '--connect-to') {
      if (index + 1 >= args.length) {
        return _EndpointRewriteDisposition.unresolved;
      }
      value = args[++index];
      isResolve = option == '--resolve';
    } else if (option.startsWith('--resolve=')) {
      value = option.substring('--resolve='.length);
      isResolve = true;
    } else if (option.startsWith('--connect-to=')) {
      value = option.substring('--connect-to='.length);
    } else {
      continue;
    }

    final current = isResolve
        ? _resolveDisposition(value)
        : _connectToDisposition(value);
    if (current == _EndpointRewriteDisposition.external ||
        current == _EndpointRewriteDisposition.unresolved) {
      return current;
    }
    disposition = current;
  }
  return disposition;
}

_EndpointRewriteDisposition _resolveDisposition(String value) {
  final fields = _splitCurlColonFields(
    value.startsWith('+') ? value.substring(1) : value,
  );
  if (fields.length != 3 || fields[2].trim().isEmpty) {
    return _EndpointRewriteDisposition.unresolved;
  }
  final destinations = fields[2].split(',');
  for (final destination in destinations) {
    final host = _withoutIpv6Brackets(destination.trim());
    if (host.isEmpty) return _EndpointRewriteDisposition.unresolved;
    if (!_isLoopbackHost(host)) return _EndpointRewriteDisposition.external;
  }
  return _EndpointRewriteDisposition.safe;
}

_EndpointRewriteDisposition _connectToDisposition(String value) {
  final fields = _splitCurlColonFields(value);
  if (fields.length != 4 || fields[2].trim().isEmpty) {
    return _EndpointRewriteDisposition.unresolved;
  }
  return _isLoopbackHost(_withoutIpv6Brackets(fields[2].trim()))
      ? _EndpointRewriteDisposition.safe
      : _EndpointRewriteDisposition.external;
}

List<String> _splitCurlColonFields(String value) {
  final fields = <String>[];
  final buffer = StringBuffer();
  var bracketDepth = 0;
  for (var index = 0; index < value.length; index += 1) {
    final character = value[index];
    if (character == '[') bracketDepth += 1;
    if (character == ']') bracketDepth -= 1;
    if (character == ':' && bracketDepth == 0) {
      fields.add(buffer.toString());
      buffer.clear();
    } else {
      buffer.write(character);
    }
    if (bracketDepth < 0) return const <String>[];
  }
  if (bracketDepth != 0) return const <String>[];
  fields.add(buffer.toString());
  return fields;
}

String _withoutIpv6Brackets(String value) {
  return value.startsWith('[') && value.endsWith(']') && value.length > 2
      ? value.substring(1, value.length - 1)
      : value;
}

const Set<String> _networkEndpointOptions = {
  '-x',
  '--proxy',
  '--preproxy',
  '--doh-url',
  '--ipfs-gateway',
  '--proxy1.0',
  '--socks4',
  '--socks4a',
  '--socks5',
  '--socks5-hostname',
};

String? _attachedNetworkEndpointValue(String option) {
  if (option.startsWith('--')) {
    final equalsIndex = option.indexOf('=');
    if (equalsIndex <= 2) return null;
    final name = option.substring(0, equalsIndex);
    return _networkEndpointOptions.contains(name)
        ? option.substring(equalsIndex + 1)
        : null;
  }
  if (option.startsWith('-x') && option.length > 2) {
    return option.substring(2);
  }
  return null;
}

bool _looksLikeNetworkTarget(String value) {
  final normalized = value.trim();
  if (normalized.isEmpty) return false;
  if (normalized.contains('://')) return true;
  if (normalized.startsWith('[')) return true;
  final authority = normalized.split('/').first.split('@').last;
  final host = authority.split(':').first;
  return host == 'localhost' ||
      RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$').hasMatch(host) ||
      host.contains('.') ||
      (host.isNotEmpty && normalized.contains(RegExp(r'[/#?]')));
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
  '--body-data',
  '--body-file',
  '--header',
  '--user',
  '--password',
  '--http-password',
  '--ftp-password',
  '--proxy-password',
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
  var commandSubstitutionDepth = 0;
  var parameterExpansionDepth = 0;

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
        buffer.write(char, allowsExpansion: false, allowsFieldSplitting: false);
      }
      continue;
    }
    if (escaped) {
      buffer.write(char, allowsExpansion: false, allowsFieldSplitting: false);
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
        buffer.write(char, allowsExpansion: true, allowsFieldSplitting: false);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char == '(' && buffer.endsWithExpandableDollar) {
      buffer.write(char, allowsExpansion: true, allowsFieldSplitting: true);
      commandSubstitutionDepth += 1;
      continue;
    }
    if (char == '{' && buffer.endsWithExpandableDollar) {
      buffer.write(char, allowsExpansion: true, allowsFieldSplitting: true);
      parameterExpansionDepth += 1;
      continue;
    }
    if (parameterExpansionDepth > 0 && (char == '{' || char == '}')) {
      buffer.write(char, allowsExpansion: true, allowsFieldSplitting: true);
      parameterExpansionDepth += char == '{' ? 1 : -1;
      continue;
    }
    if (commandSubstitutionDepth > 0 && (char == '(' || char == ')')) {
      buffer.write(char, allowsExpansion: true, allowsFieldSplitting: true);
      commandSubstitutionDepth += char == '(' ? 1 : -1;
      continue;
    }
    if (const {'(', ')', '{', '}', '<', '>', '!'}.contains(char)) {
      flush();
      words.add(_ShellToken.control(char));
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
    buffer.write(char, allowsExpansion: true, allowsFieldSplitting: true);
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
  const _ShellToken(
    this.value,
    this._expansionAllowed,
    this._fieldSplittingAllowed, {
    this.hasShellControl = false,
  });

  factory _ShellToken.expanding(String value) {
    return _ShellToken(
      value,
      List<bool>.filled(value.length, true, growable: false),
      List<bool>.filled(value.length, false, growable: false),
    );
  }

  factory _ShellToken.literal(String value) {
    return _ShellToken(
      value,
      List<bool>.filled(value.length, false, growable: false),
      List<bool>.filled(value.length, false, growable: false),
    );
  }

  factory _ShellToken.control(String value) {
    return _ShellToken(
      value,
      List<bool>.filled(value.length, false, growable: false),
      List<bool>.filled(value.length, false, growable: false),
      hasShellControl: true,
    );
  }

  final String value;
  final List<bool> _expansionAllowed;
  final List<bool> _fieldSplittingAllowed;
  final bool hasShellControl;

  bool allowsExpansionAt(int index) => _expansionAllowed[index];

  bool allowsFieldSplittingAt(int index) => _fieldSplittingAllowed[index];

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
      _fieldSplittingAllowed.sublist(start),
      hasShellControl: hasShellControl,
    );
  }
}

class _ShellTokenBuilder {
  final StringBuffer _value = StringBuffer();
  final List<bool> _expansionAllowed = <bool>[];
  final List<bool> _fieldSplittingAllowed = <bool>[];

  bool get isEmpty => _value.isEmpty;

  bool get endsWithExpandableDollar {
    final value = _value.toString();
    return value.endsWith(r'$') &&
        _expansionAllowed.isNotEmpty &&
        _expansionAllowed.last;
  }

  void write(
    String value, {
    required bool allowsExpansion,
    required bool allowsFieldSplitting,
  }) {
    _value.write(value);
    _expansionAllowed.addAll(
      List<bool>.filled(value.length, allowsExpansion, growable: false),
    );
    _fieldSplittingAllowed.addAll(
      List<bool>.filled(value.length, allowsFieldSplitting, growable: false),
    );
  }

  _ShellToken build() =>
      _ShellToken(_value.toString(), _expansionAllowed, _fieldSplittingAllowed);
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
