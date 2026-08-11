import 'dart:convert';

import 'acp_permission_request.dart';

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
      if (!values[key]!.contains(value)) values[key]!.add(value);
    }
  }
  if (values.values.any((candidates) => candidates.length > 1)) {
    return PermissionDisplayContext.incomplete();
  }

  final encoder = _PermissionDisplayEncoder(effectiveLimits.maxUtf8Bytes);
  final entries = <PermissionDisplayEntry>[];
  if (_containersHavePermissionCommandEvidence(projection.containers)) {
    final invocation = _commandFromPermissionDisplayContainers(
      request,
      projection.containers,
    );
    if (invocation == null || invocation.ambiguous) {
      return PermissionDisplayContext.incomplete();
    }
    final value = encoder.encodeCommand(<String>[
      invocation.command,
      ...invocation.args,
    ]);
    if (value == null) return PermissionDisplayContext.incomplete();
    entries.add(PermissionDisplayEntry(label: 'Command', value: value));
  }

  for (final field in const <({String key, String label})>[
    (key: 'cwd', label: 'Working directory'),
    (key: 'path', label: 'Path'),
    (key: 'target', label: 'Target'),
  ]) {
    final candidates = values[field.key]!;
    if (candidates.isNotEmpty) {
      final value = encoder.encodeField(candidates.single);
      if (value == null) return PermissionDisplayContext.incomplete();
      entries.add(PermissionDisplayEntry(label: field.label, value: value));
    }
  }
  final additionalDetails = <String, Object?>{};
  for (final key in _permissionDisplayAdditionalKeys) {
    final candidates = <Object?>[];
    for (final container in projection.containers) {
      if (!container.containsKey(key)) continue;
      final value = container[key];
      if (!candidates.any(
        (candidate) => _samePermissionDetail(candidate, value),
      )) {
        candidates.add(value);
      }
    }
    if (candidates.length > 1) return PermissionDisplayContext.incomplete();
    if (candidates.isNotEmpty) additionalDetails[key] = candidates.single;
  }
  if (additionalDetails.isNotEmpty) {
    final value = encoder.encodeDetails(additionalDetails);
    if (value == null) return PermissionDisplayContext.incomplete();
    entries.add(
      PermissionDisplayEntry(label: 'Additional details', value: value),
    );
  }
  return PermissionDisplayContext.complete(entries);
}

class _PermissionDisplayEncoder {
  _PermissionDisplayEncoder(this.maxUtf8Bytes);

  final int maxUtf8Bytes;
  var _utf8Bytes = 0;
  var _failed = false;

  String? encodeCommand(List<String> tokens) {
    final output = StringBuffer();
    if (!_write(output, '[')) return null;
    for (var index = 0; index < tokens.length; index += 1) {
      if (index > 0 && !_write(output, ',')) return null;
      if (!_write(output, '"') ||
          !_writeString(output, tokens[index], escapeBoundarySpaces: false) ||
          !_write(output, '"')) {
        return null;
      }
    }
    if (!_write(output, ']')) return null;
    return output.toString();
  }

  String? encodeField(String value) {
    final output = StringBuffer();
    return _writeString(output, value, escapeBoundarySpaces: true)
        ? output.toString()
        : null;
  }

  String? encodeDetails(Map<String, Object?> details) {
    final output = StringBuffer();
    return _writeJsonValue(output, details) ? output.toString() : null;
  }

  bool _writeJsonValue(StringBuffer output, Object? value) {
    if (value == null) return _write(output, 'null');
    if (value is bool || value is int) {
      return _write(output, value.toString());
    }
    if (value is String) {
      return _write(output, '"') &&
          _writeJsonString(output, value) &&
          _write(output, '"');
    }
    if (value is List<Object?>) {
      if (!_write(output, '[')) return false;
      for (var index = 0; index < value.length; index += 1) {
        if (index > 0 && !_write(output, ',')) return false;
        if (!_writeJsonValue(output, value[index])) return false;
      }
      return _write(output, ']');
    }
    if (value is Map<String, Object?>) {
      if (!_write(output, '{')) return false;
      final keys = value.keys.toList(growable: false)..sort();
      for (var index = 0; index < keys.length; index += 1) {
        if (index > 0 && !_write(output, ',')) return false;
        final key = keys[index];
        if (!_write(output, '"') ||
            !_writeJsonString(output, key) ||
            !_write(output, '":') ||
            !_writeJsonValue(output, value[key])) {
          return false;
        }
      }
      return _write(output, '}');
    }
    return false;
  }

  bool _writeJsonString(StringBuffer output, String value) {
    var firstNonSpace = 0;
    var lastNonSpace = value.length - 1;
    while (firstNonSpace < value.length &&
        value.codeUnitAt(firstNonSpace) == 0x20) {
      firstNonSpace += 1;
    }
    while (lastNonSpace >= firstNonSpace &&
        value.codeUnitAt(lastNonSpace) == 0x20) {
      lastNonSpace -= 1;
    }
    for (var index = 0; index < value.length; index += 1) {
      final first = value.codeUnitAt(index);
      if (first >= 0xd800 && first <= 0xdbff) {
        if (index + 1 < value.length) {
          final second = value.codeUnitAt(index + 1);
          if (second >= 0xdc00 && second <= 0xdfff) {
            final codePoint =
                0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
            if (!_write(output, String.fromCharCode(codePoint))) return false;
            index += 1;
            continue;
          }
        }
        if (!_writeJsonEscape(output, first)) return false;
        continue;
      }
      if (first >= 0xdc00 && first <= 0xdfff) {
        if (!_writeJsonEscape(output, first)) return false;
        continue;
      }
      final boundarySpace =
          first == 0x20 && (index < firstNonSpace || index > lastNonSpace);
      if (boundarySpace || _isUnsafePermissionDisplayCodePoint(first)) {
        if (!_writeJsonEscape(output, first)) return false;
      } else if (first == 0x22) {
        if (!_write(output, r'\"')) return false;
      } else if (first == 0x5c) {
        if (!_write(output, r'\\')) return false;
      } else if (!_write(output, String.fromCharCode(first))) {
        return false;
      }
    }
    return true;
  }

  bool _writeJsonEscape(StringBuffer output, int codePoint) {
    if (codePoint <= 0xffff) {
      return _write(
        output,
        '\\u${codePoint.toRadixString(16).toUpperCase().padLeft(4, '0')}',
      );
    }
    final scalar = codePoint - 0x10000;
    final high = 0xd800 + (scalar >> 10);
    final low = 0xdc00 + (scalar & 0x3ff);
    return _writeJsonEscape(output, high) && _writeJsonEscape(output, low);
  }

  bool _writeString(
    StringBuffer output,
    String value, {
    required bool escapeBoundarySpaces,
  }) {
    var firstNonSpace = 0;
    var lastNonSpace = value.length - 1;
    if (escapeBoundarySpaces) {
      while (firstNonSpace < value.length &&
          value.codeUnitAt(firstNonSpace) == 0x20) {
        firstNonSpace += 1;
      }
      while (lastNonSpace >= firstNonSpace &&
          value.codeUnitAt(lastNonSpace) == 0x20) {
        lastNonSpace -= 1;
      }
    }

    for (var index = 0; index < value.length; index += 1) {
      final first = value.codeUnitAt(index);
      if (first >= 0xd800 && first <= 0xdbff) {
        if (index + 1 < value.length) {
          final second = value.codeUnitAt(index + 1);
          if (second >= 0xdc00 && second <= 0xdfff) {
            final codePoint =
                0x10000 + ((first - 0xd800) << 10) + (second - 0xdc00);
            if (!_writeCodePoint(output, codePoint)) return false;
            index += 1;
            continue;
          }
        }
        if (!_writeEscape(output, first)) return false;
        continue;
      }
      if (first >= 0xdc00 && first <= 0xdfff) {
        if (!_writeEscape(output, first)) return false;
        continue;
      }
      final isBoundarySpace =
          escapeBoundarySpaces &&
          first == 0x20 &&
          (index < firstNonSpace || index > lastNonSpace);
      if (isBoundarySpace || _isUnsafePermissionDisplayCodePoint(first)) {
        if (!_writeEscape(output, first)) return false;
      } else if (!_writeCodePoint(output, first)) {
        return false;
      }
    }
    return true;
  }

  bool _writeCodePoint(StringBuffer output, int codePoint) {
    if (_isUnsafePermissionDisplayCodePoint(codePoint)) {
      return _writeEscape(output, codePoint);
    }
    if (codePoint == 0x5c) return _write(output, r'\\');
    if (codePoint == 0x22) return _write(output, r'\"');
    return _write(output, String.fromCharCode(codePoint));
  }

  bool _writeEscape(StringBuffer output, int codePoint) {
    final minimumDigits = codePoint > 0xffff ? 6 : 4;
    final hex = codePoint
        .toRadixString(16)
        .toUpperCase()
        .padLeft(minimumDigits, '0');
    return _write(output, '\\u{$hex}');
  }

  bool _write(StringBuffer output, String chunk) {
    if (_failed) return false;
    final length = utf8.encode(chunk).length;
    if (_utf8Bytes + length > maxUtf8Bytes) {
      _failed = true;
      return false;
    }
    _utf8Bytes += length;
    output.write(chunk);
    return true;
  }
}

bool _isUnsafePermissionDisplayCodePoint(int codePoint) {
  return codePoint <= 0x1f ||
      (codePoint >= 0x7f && codePoint <= 0x9f) ||
      codePoint == 0x061c ||
      codePoint == 0x200e ||
      codePoint == 0x200f ||
      (codePoint >= 0x2028 && codePoint <= 0x202e) ||
      (codePoint >= 0x2066 && codePoint <= 0x2069);
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
  ..._permissionDisplayAdditionalKeys,
];

const List<String> _permissionDisplayAdditionalKeys = <String>[
  'environment',
  'writeBytes',
  'contentPreview',
  'contentTruncated',
  'truncated',
  'line',
  'limit',
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
      final root = _projectMap(
        metadata,
        depth: 0,
        countUtf8: true,
        rejectUnknownKeys: false,
      );
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
    required bool rejectUnknownKeys,
  }) {
    if (depth > limits.maxDepth || (takeSelfNode && !_takeNode())) {
      return _fail();
    }
    final projected = <String, Object?>{};

    for (final key in _permissionDisplayScalarKeys) {
      if (_failed) return null;
      final contains = _mapContainsKey(source, key);
      if (contains == null) return null;
      if (!contains) continue;
      if (!_takeEntry()) return _fail();
      if (_permissionArgumentKeys.contains(key) && depth >= limits.maxDepth) {
        return _fail();
      }
      if (!_takeNode()) return _fail();
      final read = _mapValue(source, key);
      if (!read.succeeded) return null;
      final raw = read.value;
      if (_permissionDisplayAdditionalKeys.contains(key)) {
        final value = _projectJsonValue(
          raw,
          depth: depth + 1,
          countUtf8: countUtf8,
        );
        if (_failed) return null;
        projected[key] = value;
        continue;
      }
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
      if (raw.trim().isEmpty) return _fail();
      projected[key] = raw;
    }

    for (final key in _permissionDisplayContainerKeys) {
      if (_failed) return null;
      final contains = _mapContainsKey(source, key);
      if (contains == null) return null;
      if (!contains) continue;
      if (!_takeEntry()) return _fail();
      if (depth >= limits.maxDepth || !_takeNode()) return _fail();
      final read = _mapValue(source, key);
      if (!read.succeeded) return null;
      final raw = read.value;
      Map? nested;
      var nestedCountsUtf8 = countUtf8;
      if (raw is Map) {
        nested = raw;
      } else if (raw is String) {
        if (!_addUtf8(raw, countUtf8: countUtf8)) {
          return _fail();
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
        rejectUnknownKeys: key != 'toolCall',
      );
      if (nestedProjection == null) return _fail();
      projected[key] = nestedProjection;
    }

    if (rejectUnknownKeys && !_containsOnlyRecognizedKeys(source)) {
      return _fail();
    }

    final immutable = Map<String, Object?>.unmodifiable(projected);
    _containers.add(immutable);
    return immutable;
  }

  Object? _projectJsonValue(
    Object? raw, {
    required int depth,
    required bool countUtf8,
  }) {
    if (depth > limits.maxDepth || !_takeNode()) return _fail();
    if (raw == null || raw is bool || raw is int) return raw;
    if (raw is String) {
      return _addUtf8(raw, countUtf8: countUtf8) ? raw : _fail();
    }
    if (raw is List) {
      late final int length;
      try {
        length = raw.length;
      } on Object {
        return _fail();
      }
      if (length < 0 || length > limits.maxNodes - _nodes) return _fail();
      final result = <Object?>[];
      for (var index = 0; index < length; index += 1) {
        late final Object? item;
        try {
          item = raw[index];
        } on Object {
          return _fail();
        }
        final value = _projectJsonValue(
          item,
          depth: depth + 1,
          countUtf8: countUtf8,
        );
        if (_failed) return null;
        result.add(value);
      }
      return List<Object?>.unmodifiable(result);
    }
    if (raw is Map) {
      final entries = <String, Object?>{};
      late final Iterator<Object?> iterator;
      try {
        iterator = raw.keys.cast<Object?>().iterator;
      } on Object {
        return _fail();
      }
      while (true) {
        late final bool hasNext;
        try {
          hasNext = iterator.moveNext();
        } on Object {
          return _fail();
        }
        if (!hasNext) break;
        late final Object? key;
        try {
          key = iterator.current;
        } on Object {
          return _fail();
        }
        if (key is! String ||
            entries.containsKey(key) ||
            !_addUtf8(key, countUtf8: countUtf8)) {
          return _fail();
        }
        late final Object? item;
        try {
          item = raw[key];
        } on Object {
          return _fail();
        }
        final value = _projectJsonValue(
          item,
          depth: depth + 1,
          countUtf8: countUtf8,
        );
        if (_failed) return null;
        entries[key] = value;
      }
      final sorted = entries.keys.toList(growable: false)..sort();
      return Map<String, Object?>.unmodifiable({
        for (final key in sorted) key: entries[key],
      });
    }
    return _fail();
  }

  bool _containsOnlyRecognizedKeys(Map source) {
    late final Iterator<Object?> iterator;
    try {
      iterator = source.keys.cast<Object?>().iterator;
    } on Object {
      return false;
    }
    var seen = 0;
    final maximum =
        _permissionDisplayScalarKeys.length +
        _permissionDisplayContainerKeys.length;
    while (true) {
      late final bool hasNext;
      try {
        hasNext = iterator.moveNext();
      } on Object {
        return false;
      }
      if (!hasNext) return true;
      seen += 1;
      if (seen > maximum) return false;
      late final Object? key;
      try {
        key = iterator.current;
      } on Object {
        return false;
      }
      if (key is! String ||
          (!_permissionDisplayScalarKeys.contains(key) &&
              !_permissionDisplayContainerKeys.contains(key))) {
        return false;
      }
    }
  }

  bool? _mapContainsKey(Map source, String key) {
    try {
      return source.containsKey(key);
    } on Object {
      _failed = true;
      return null;
    }
  }

  ({bool succeeded, Object? value}) _mapValue(Map source, String key) {
    try {
      return (succeeded: true, value: source[key]);
    } on Object {
      _failed = true;
      return (succeeded: false, value: null);
    }
  }

  List<String>? _projectStringList(
    Object? raw, {
    required int depth,
    required bool countUtf8,
  }) {
    if (raw is! List || depth > limits.maxDepth) return null;
    final remainingNodes = limits.maxNodes - _nodes;
    if (remainingNodes <= 0) return null;
    late final int length;
    try {
      length = raw.length;
    } on Object {
      return null;
    }
    if (length < 0 || length > remainingNodes) return null;

    final result = <String>[];
    for (var index = 0; index < length; index += 1) {
      if (!_takeNode()) return null;
      late final Object? item;
      try {
        item = raw[index];
      } on Object {
        return null;
      }
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

bool _samePermissionDetail(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (!_samePermissionDetail(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_samePermissionDetail(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
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
      final command = value;
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

final RegExp _assignmentPattern = RegExp(r'^([A-Za-z_][A-Za-z0-9_]*)=(.*)$');
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

String _shellDisplayArg(String arg) {
  if (!arg.contains(RegExp(r'\s'))) return arg;
  return "'${arg.replaceAll("'", r"'\''")}'";
}
