import 'dart:collection';
import 'dart:math' as math;

const int _maxSafeBudgetInteger = 0x1fffffffffffff;

/// Returns the largest Base64 length needed for [decodedByteLimit].
///
/// The calculation rejects values whose encoded result would exceed Dart's
/// exact cross-platform integer range.
int acpMaxBase64EncodedLength(int decodedByteLimit) {
  _requirePositive(decodedByteLimit, 'decodedByteLimit');
  final groups = decodedByteLimit ~/ 3 + (decodedByteLimit % 3 == 0 ? 0 : 1);
  if (groups > _maxSafeBudgetInteger ~/ 4) {
    throw ArgumentError.value(
      decodedByteLimit,
      'decodedByteLimit',
      'Base64 encoded limit exceeds the cross-platform safe integer range',
    );
  }
  return groups * 4;
}

enum AcpInputOmissionReason {
  inputLimit,
  invalidEncoding,
  invalidImage,
  invalidStructure,
}

/// A typed description of ACP input that owning code omitted.
final class AcpInputOmission {
  factory AcpInputOmission({
    required AcpInputOmissionReason reason,
    required String resource,
    required bool truncated,
    int? limit,
    int? observedAtLeast,
  }) {
    final hasLimit = limit != null;
    final hasObservedAtLeast = observedAtLeast != null;
    if (hasLimit != hasObservedAtLeast) {
      throw ArgumentError(
        'limit and observedAtLeast must either both be provided or both be null',
      );
    }
    final hasCapacity = hasLimit;
    if (reason == AcpInputOmissionReason.inputLimit && !hasCapacity) {
      throw ArgumentError(
        'inputLimit omissions require limit and observedAtLeast',
      );
    }
    if (reason != AcpInputOmissionReason.inputLimit && hasCapacity) {
      throw ArgumentError(
        'only inputLimit omissions may include limit and observedAtLeast',
      );
    }
    return AcpInputOmission._(
      reason: reason,
      resource: resource,
      truncated: truncated,
      limit: limit,
      observedAtLeast: observedAtLeast,
    );
  }

  const AcpInputOmission._({
    required this.reason,
    required this.resource,
    required this.truncated,
    required this.limit,
    required this.observedAtLeast,
  });

  final AcpInputOmissionReason reason;
  final String resource;
  final bool truncated;
  final int? limit;
  final int? observedAtLeast;

  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'reason': switch (reason) {
        AcpInputOmissionReason.inputLimit => 'input_limit',
        AcpInputOmissionReason.invalidEncoding => 'invalid_encoding',
        AcpInputOmissionReason.invalidImage => 'invalid_image',
        AcpInputOmissionReason.invalidStructure => 'invalid_structure',
      },
      'resource': resource,
    };
    if (reason == AcpInputOmissionReason.inputLimit) {
      json['limit'] = limit;
      json['observedAtLeast'] = observedAtLeast;
    }
    json['truncated'] = truncated;
    return json;
  }

  @override
  String toString() {
    final fields = toJson().entries.map(
      (entry) => '${entry.key}: ${entry.value}',
    );
    return 'AcpInputOmission(${fields.join(', ')})';
  }
}

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
    this.maxCollectionItems = 1024,
    this.maxStructuredUpdateNodes = 8192,
    this.maxStructuredUpdateBytes = 1024 * 1024,
    this.maxStructuredStringBytes = 64 * 1024,
    this.maxMessageTextBytes = 1024 * 1024,
    this.maxMessageTextLines = 10000,
    this.maxMarkdownSyntaxTokens = 4096,
    this.maxMarkdownFallbackBytes = 64 * 1024,
    this.maxThoughtTextBytes = 512 * 1024,
    this.maxEmbeddedMediaBytes = 8 * 1024 * 1024,
    this.maxImageDimension = 8192,
    this.maxImagePixels = 16777216,
    this.maxImagePreviewPixels = 2097152,
    this.maxConcurrentImageDecodes = 2,
    this.maxImagePreviewPixelsGlobal = 4194304,
    this.maxImageDecodeBytesGlobal = 32 * 1024 * 1024,
    this.maxTurnItems = 512,
    this.maxTurnRetainedBytes = 16 * 1024 * 1024,
    this.maxTimelineItems = 2000,
    this.maxTimelineBytes = 16 * 1024 * 1024,
    this.maxUiStateBytes = 64 * 1024 * 1024,
    this.maxMetadataPreviewBytes = 16 * 1024,
    this.maxMetadataPreviewChars = 4096,
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

  final int maxCollectionItems;
  final int maxStructuredUpdateNodes;
  final int maxStructuredUpdateBytes;
  final int maxStructuredStringBytes;
  final int maxMessageTextBytes;
  final int maxMessageTextLines;
  final int maxMarkdownSyntaxTokens;
  final int maxMarkdownFallbackBytes;
  final int maxThoughtTextBytes;
  final int maxEmbeddedMediaBytes;
  final int maxImageDimension;
  final int maxImagePixels;
  final int maxImagePreviewPixels;
  final int maxConcurrentImageDecodes;
  final int maxImagePreviewPixelsGlobal;
  final int maxImageDecodeBytesGlobal;
  final int maxTurnItems;
  final int maxTurnRetainedBytes;
  final int maxTimelineItems;
  final int maxTimelineBytes;
  final int maxUiStateBytes;
  final int maxMetadataPreviewBytes;
  final int maxMetadataPreviewChars;

  /// Reject invalid dynamic budgets in debug and release builds.
  void validate() {
    _requirePositiveSafeBudgetInteger(maxJsonDepth, 'maxJsonDepth');
    _requirePositiveSafeBudgetInteger(maxCapabilityDepth, 'maxCapabilityDepth');
    _requirePositiveSafeBudgetInteger(maxCapabilityNodes, 'maxCapabilityNodes');
    _requirePositiveSafeBudgetInteger(maxCapabilityBytes, 'maxCapabilityBytes');
    _requirePositiveSafeBudgetInteger(maxAuthMethods, 'maxAuthMethods');
    _requirePositiveSafeBudgetInteger(maxMetadataDepth, 'maxMetadataDepth');
    _requirePositiveSafeBudgetInteger(maxMetadataNodes, 'maxMetadataNodes');
    _requirePositiveSafeBudgetInteger(maxMetadataEntries, 'maxMetadataEntries');
    _requirePositiveSafeBudgetInteger(maxMetadataBytes, 'maxMetadataBytes');
    _requirePositiveSafeBudgetInteger(maxCollectionItems, 'maxCollectionItems');
    _requirePositiveSafeBudgetInteger(
      maxStructuredUpdateNodes,
      'maxStructuredUpdateNodes',
    );
    _requirePositiveSafeBudgetInteger(
      maxStructuredUpdateBytes,
      'maxStructuredUpdateBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxStructuredStringBytes,
      'maxStructuredStringBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxMessageTextBytes,
      'maxMessageTextBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxMessageTextLines,
      'maxMessageTextLines',
    );
    _requirePositiveSafeBudgetInteger(
      maxMarkdownSyntaxTokens,
      'maxMarkdownSyntaxTokens',
    );
    _requirePositiveSafeBudgetInteger(
      maxMarkdownFallbackBytes,
      'maxMarkdownFallbackBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxThoughtTextBytes,
      'maxThoughtTextBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxEmbeddedMediaBytes,
      'maxEmbeddedMediaBytes',
    );
    _requirePositiveSafeBudgetInteger(maxImageDimension, 'maxImageDimension');
    _requirePositiveSafeBudgetInteger(maxImagePixels, 'maxImagePixels');
    _requirePositiveSafeBudgetInteger(
      maxImagePreviewPixels,
      'maxImagePreviewPixels',
    );
    _requirePositiveSafeBudgetInteger(
      maxConcurrentImageDecodes,
      'maxConcurrentImageDecodes',
    );
    _requirePositiveSafeBudgetInteger(
      maxImagePreviewPixelsGlobal,
      'maxImagePreviewPixelsGlobal',
    );
    _requirePositiveSafeBudgetInteger(
      maxImageDecodeBytesGlobal,
      'maxImageDecodeBytesGlobal',
    );
    _requirePositiveSafeBudgetInteger(maxTurnItems, 'maxTurnItems');
    _requirePositiveSafeBudgetInteger(
      maxTurnRetainedBytes,
      'maxTurnRetainedBytes',
    );
    _requirePositiveSafeBudgetInteger(maxTimelineItems, 'maxTimelineItems');
    _requirePositiveSafeBudgetInteger(maxTimelineBytes, 'maxTimelineBytes');
    _requirePositiveSafeBudgetInteger(maxUiStateBytes, 'maxUiStateBytes');
    _requirePositiveSafeBudgetInteger(
      maxMetadataPreviewBytes,
      'maxMetadataPreviewBytes',
    );
    _requirePositiveSafeBudgetInteger(
      maxMetadataPreviewChars,
      'maxMetadataPreviewChars',
    );

    acpMaxBase64EncodedLength(maxEmbeddedMediaBytes);
    if (maxImagePreviewPixels > _maxSafeBudgetInteger ~/ 4) {
      throw ArgumentError.value(
        maxImagePreviewPixels,
        'maxImagePreviewPixels',
        'decoded preview bytes exceed the cross-platform safe integer range',
      );
    }

    _requireAtMost(
      maxImagePreviewPixels,
      maxImagePixels,
      'maxImagePreviewPixels relative to maxImagePixels',
    );
    _requireAtMost(
      maxImagePreviewPixels,
      maxImagePreviewPixelsGlobal,
      'maxImagePreviewPixels relative to maxImagePreviewPixelsGlobal',
    );
    _requireAtMost(
      maxMarkdownFallbackBytes,
      maxMessageTextBytes,
      'maxMarkdownFallbackBytes relative to maxMessageTextBytes',
    );
    _requireAtMost(
      maxTurnRetainedBytes,
      maxTimelineBytes,
      'maxTurnRetainedBytes relative to maxTimelineBytes',
    );
    _requireAtMost(
      maxTimelineBytes,
      maxUiStateBytes,
      'maxTimelineBytes relative to maxUiStateBytes',
    );

    final previewBytes = maxImagePreviewPixels * 4;
    _requireAtMost(
      previewBytes,
      maxImageDecodeBytesGlobal,
      'maxImagePreviewPixels bytes relative to maxImageDecodeBytesGlobal',
    );
    final remainingImageDecodeBytes = maxImageDecodeBytesGlobal - previewBytes;
    if (maxEmbeddedMediaBytes > remainingImageDecodeBytes) {
      throw AcpInputLimitExceeded(
        resource: 'maxEmbeddedMediaBytes after image preview reservation',
        limit: remainingImageDecodeBytes,
        observedAtLeast: maxEmbeddedMediaBytes,
      );
    }
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

void _requireSafeBudgetInteger(int value, String name) {
  if (value > _maxSafeBudgetInteger) {
    throw ArgumentError.value(
      value,
      name,
      'must not exceed the cross-platform safe integer range',
    );
  }
}

void _requirePositiveSafeBudgetInteger(int value, String name) {
  _requirePositive(value, name);
  _requireSafeBudgetInteger(value, name);
}

void _requireAtMost(int observed, int limit, String resource) {
  if (observed > limit) {
    throw AcpInputLimitExceeded(
      resource: resource,
      limit: limit,
      observedAtLeast: observed,
    );
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
