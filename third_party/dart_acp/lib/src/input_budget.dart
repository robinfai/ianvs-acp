import 'dart:collection';
import 'dart:math' as math;

/// Host-controlled limits for untrusted ACP input.
class AcpInputBudget {
  const AcpInputBudget({
    this.maxJsonDepth = 32,
    this.maxCapabilityDepth = 16,
    this.maxCapabilityNodes = 4096,
    this.maxCapabilityBytes = 256 * 1024,
    this.maxAuthMethods = 32,
    this.maxMetadataDepth = 16,
    this.maxMetadataNodes = 8192,
    this.maxMetadataEntries = 1024,
    this.maxMetadataBytes = 512 * 1024,
  });

  final int maxJsonDepth;
  final int maxCapabilityDepth;
  final int maxCapabilityNodes;
  final int maxCapabilityBytes;
  final int maxAuthMethods;

  // Defined here so later input slices share the same host-owned policy.
  final int maxMetadataDepth;
  final int maxMetadataNodes;
  final int maxMetadataEntries;
  final int maxMetadataBytes;

  /// Reject invalid dynamic budgets in debug and release builds.
  void validate() {
    _requirePositive(maxJsonDepth, 'maxJsonDepth');
    _requirePositive(maxCapabilityDepth, 'maxCapabilityDepth');
    _requirePositive(maxCapabilityNodes, 'maxCapabilityNodes');
    _requirePositive(maxCapabilityBytes, 'maxCapabilityBytes');
    _requirePositive(maxAuthMethods, 'maxAuthMethods');
    _requirePositive(maxMetadataDepth, 'maxMetadataDepth');
    _requirePositive(maxMetadataNodes, 'maxMetadataNodes');
    _requirePositive(maxMetadataEntries, 'maxMetadataEntries');
    _requirePositive(maxMetadataBytes, 'maxMetadataBytes');
  }
}

/// Capacity failure that never includes the rejected ACP payload.
class AcpInputLimitExceeded implements Exception {
  const AcpInputLimitExceeded({
    required this.resource,
    required this.limit,
    required this.observedAtLeast,
  });

  final String resource;
  final int limit;
  final int observedAtLeast;

  @override
  String toString() =>
      'AcpInputLimitExceeded(resource: $resource, limit: $limit, '
      'observedAtLeast: $observedAtLeast)';
}

({
  Map<String, dynamic> agentCapabilities,
  List<Map<String, dynamic>> authMethods,
  Map<String, dynamic> agentInfo,
})
copyBoundedInitializeInput({
  required Object? agentCapabilities,
  required Object? authMethods,
  Object? agentInfo,
  AcpInputBudget budget = const AcpInputBudget(),
}) {
  budget.validate();
  final List<dynamic> rawAuthMethods;
  if (authMethods == null) {
    rawAuthMethods = const <Object?>[];
  } else if (authMethods is List) {
    rawAuthMethods = authMethods;
  } else {
    throw const FormatException(
      'ACP initialize auth methods must be a JSON array.',
    );
  }
  final authMethodCount = rawAuthMethods.length;
  if (authMethodCount > budget.maxAuthMethods) {
    throw AcpInputLimitExceeded(
      resource: 'ACP initialize auth methods',
      limit: budget.maxAuthMethods,
      observedAtLeast: authMethodCount,
    );
  }
  final guard = AcpJsonInputGuard(
    resource: 'ACP initialize input',
    maxDepth: math.min(budget.maxJsonDepth, budget.maxCapabilityDepth),
    maxNodes: budget.maxCapabilityNodes,
    maxBytes: budget.maxCapabilityBytes,
  );
  final copiedAgentCapabilities = guard.copyMap(agentCapabilities);
  final copiedAuthValues = guard.copyList(
    _FixedLengthListView(rawAuthMethods, authMethodCount),
    rootElementObjectError:
        'ACP initialize auth methods must contain only JSON objects.',
  );
  final copiedAgentInfo = guard.copyMap(agentInfo);
  final copiedAuthMethods = <Map<String, dynamic>>[];
  for (final value in copiedAuthValues) {
    copiedAuthMethods.add(value as Map<String, dynamic>);
  }
  return (
    agentCapabilities: copiedAgentCapabilities,
    authMethods: copiedAuthMethods,
    agentInfo: copiedAgentInfo,
  );
}

/// Iteratively creates bounded defensive copies of JSON-compatible values.
///
/// One guard may copy several roots while sharing a single node and byte
/// budget, which prevents an initialize response from multiplying the limit
/// across capabilities, authentication methods, and agent metadata.
class AcpJsonInputGuard {
  AcpJsonInputGuard({
    required this.resource,
    required this.maxDepth,
    required this.maxNodes,
    required this.maxBytes,
  }) {
    _requirePositive(maxDepth, 'maxDepth');
    _requirePositive(maxNodes, 'maxNodes');
    _requirePositive(maxBytes, 'maxBytes');
  }

  final String resource;
  final int maxDepth;
  final int maxNodes;
  final int maxBytes;

  var _nodes = 0;
  var _bytes = 0;

  Map<String, dynamic> copyMap(Object? source) {
    if (source == null) return <String, dynamic>{};
    final copy = _copy(source);
    if (copy is! Map<String, dynamic>) {
      throw FormatException('$resource must be a JSON object.');
    }
    return copy;
  }

  List<dynamic> copyList(Object? source, {String? rootElementObjectError}) {
    if (source == null) return <dynamic>[];
    final copy = _copy(source, rootElementObjectError: rootElementObjectError);
    if (copy is! List<dynamic>) {
      throw FormatException('$resource must be a JSON array.');
    }
    return copy;
  }

  Object? _copy(Object? source, {String? rootElementObjectError}) {
    Object? result;
    final pending = <_PendingJsonValue>[
      _PendingJsonValue(
        source: source,
        depth: 1,
        assign: (value) => result = value,
      ),
    ];

    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      final value = current.source;
      _recordNode();

      if (value is Map) {
        _checkContainerDepth(current.depth);
        final reportedLength = value.length;
        _precheckChildren(reportedLength);
        final entries = <MapEntry<dynamic, dynamic>>[];
        for (final entry in value.entries) {
          if (entry.key is! String) {
            throw FormatException(
              '$resource contains a JSON object with a non-string key.',
            );
          }
          final observedAtLeast = _nodes + entries.length + 1;
          if (observedAtLeast > maxNodes) {
            _throwLimit(maxNodes, observedAtLeast);
          }
          entries.add(entry);
        }
        final copy = <String, dynamic>{};
        current.assign(copy);
        for (var index = entries.length - 1; index >= 0; index -= 1) {
          final entry = entries[index];
          final key = entry.key as String;
          _recordStringBytes(key);
          pending.add(
            _PendingJsonValue(
              source: entry.value,
              depth: current.depth + 1,
              assign: (child) => copy[key] = child,
            ),
          );
        }
        continue;
      }

      if (value is List) {
        _checkContainerDepth(current.depth);
        final length = value.length;
        _precheckChildren(length);
        final copy = List<dynamic>.filled(length, null);
        current.assign(copy);
        for (var index = length - 1; index >= 0; index -= 1) {
          final child = value[index];
          if (current.depth == 1 &&
              rootElementObjectError != null &&
              child is! Map) {
            throw FormatException(rootElementObjectError);
          }
          pending.add(
            _PendingJsonValue(
              source: child,
              depth: current.depth + 1,
              assign: (child) => copy[index] = child,
            ),
          );
        }
        continue;
      }

      if (value is String) {
        _recordStringBytes(value);
        current.assign(value);
        continue;
      }
      if (value is double && !value.isFinite) {
        throw FormatException('$resource contains a non-finite JSON number.');
      }
      if (value is num) {
        _recordStringBytes(value.toString());
        current.assign(value);
        continue;
      }
      if (value is bool) {
        _recordBytes(value ? 4 : 5);
        current.assign(value);
        continue;
      }
      if (value == null) {
        _recordBytes(4);
        current.assign(null);
        continue;
      }
      throw FormatException('$resource contains a non-JSON value.');
    }

    return result;
  }

  void _recordNode() {
    _nodes += 1;
    if (_nodes > maxNodes) _throwLimit(maxNodes, _nodes);
  }

  void _recordBytes(int count) {
    _bytes += count;
    if (_bytes > maxBytes) _throwLimit(maxBytes, _bytes);
  }

  void _recordStringBytes(String value) {
    var index = 0;
    while (index < value.length) {
      final codeUnit = value.codeUnitAt(index);
      if (codeUnit <= 0x7f) {
        _recordBytes(1);
      } else if (codeUnit <= 0x7ff) {
        _recordBytes(2);
      } else if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
        final nextIndex = index + 1;
        if (nextIndex < value.length) {
          final next = value.codeUnitAt(nextIndex);
          if (next >= 0xdc00 && next <= 0xdfff) {
            _recordBytes(4);
            index = nextIndex;
          } else {
            _recordBytes(3);
          }
        } else {
          _recordBytes(3);
        }
      } else {
        // BMP values and unpaired low surrogates encode as three bytes. Dart's
        // UTF-8 encoder replaces unpaired surrogates with U+FFFD.
        _recordBytes(3);
      }
      index += 1;
    }
  }

  void _precheckChildren(int count) {
    final observedAtLeast = _nodes + count;
    if (observedAtLeast > maxNodes) {
      _throwLimit(maxNodes, observedAtLeast);
    }
  }

  void _checkContainerDepth(int depth) {
    if (depth > maxDepth) _throwLimit(maxDepth, depth);
  }

  Never _throwLimit(int limit, int observedAtLeast) {
    throw AcpInputLimitExceeded(
      resource: resource,
      limit: limit,
      observedAtLeast: observedAtLeast,
    );
  }
}

void _requirePositive(int value, String name) {
  if (value <= 0) {
    throw ArgumentError.value(value, name, 'must be greater than zero');
  }
}

class _PendingJsonValue {
  const _PendingJsonValue({
    required this.source,
    required this.depth,
    required this.assign,
  });

  final Object? source;
  final int depth;
  final void Function(Object? value) assign;
}

class _FixedLengthListView extends ListBase<dynamic> {
  _FixedLengthListView(this._source, this._length);

  final List<dynamic> _source;
  final int _length;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('fixed-length view');

  @override
  dynamic operator [](int index) => _source[index];

  @override
  void operator []=(int index, dynamic value) =>
      throw UnsupportedError('read-only view');
}
