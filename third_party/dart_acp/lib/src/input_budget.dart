import 'dart:convert';

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
  }) : assert(maxJsonDepth > 0),
       assert(maxCapabilityDepth > 0),
       assert(maxCapabilityNodes > 0),
       assert(maxCapabilityBytes > 0),
       assert(maxAuthMethods > 0),
       assert(maxMetadataDepth > 0),
       assert(maxMetadataNodes > 0),
       assert(maxMetadataEntries > 0),
       assert(maxMetadataBytes > 0);

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
  }) : assert(maxDepth > 0),
       assert(maxNodes > 0),
       assert(maxBytes > 0);

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

  List<dynamic> copyList(Object? source) {
    if (source == null) return <dynamic>[];
    final copy = _copy(source);
    if (copy is! List<dynamic>) {
      throw FormatException('$resource must be a JSON array.');
    }
    return copy;
  }

  Object? _copy(Object? source) {
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
        if (value.length > maxNodes) {
          _throwLimit(maxNodes, value.length);
        }
        final copy = <String, dynamic>{};
        current.assign(copy);
        final entries = value.entries.toList(growable: false);
        for (var index = entries.length - 1; index >= 0; index -= 1) {
          final entry = entries[index];
          final key = entry.key.toString();
          _recordBytes(_utf8Length(key));
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
        if (value.length > maxNodes) {
          _throwLimit(maxNodes, value.length);
        }
        final copy = List<dynamic>.filled(value.length, null);
        current.assign(copy);
        for (var index = value.length - 1; index >= 0; index -= 1) {
          pending.add(
            _PendingJsonValue(
              source: value[index],
              depth: current.depth + 1,
              assign: (child) => copy[index] = child,
            ),
          );
        }
        continue;
      }

      if (value is String) {
        _recordBytes(_utf8Length(value));
        current.assign(value);
        continue;
      }
      if (value is num || value is bool) {
        _recordBytes(_utf8Length(value.toString()));
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

  static int _utf8Length(String value) => utf8.encode(value).length;
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
