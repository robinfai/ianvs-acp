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

final class AcpBase64ScanResult {
  const AcpBase64ScanResult(this.encodedLength, this.decodedBytes);

  final int encodedLength;
  final int decodedBytes;
}

/// Validates standard Base64 and counts decoded bytes without decoding it.
AcpBase64ScanResult scanAcpBase64(
  String encoded, {
  required int maxDecodedBytes,
  required String resource,
}) {
  _requirePositiveSafeBudgetInteger(maxDecodedBytes, 'maxDecodedBytes');
  final encodedLength = encoded.length;
  if (encodedLength % 4 != 0) _throwInvalidBase64();

  var decodedBytes = 0;
  for (var index = 0; index < encodedLength; index += 4) {
    final first = encoded.codeUnitAt(index);
    final second = encoded.codeUnitAt(index + 1);
    final third = encoded.codeUnitAt(index + 2);
    final fourth = encoded.codeUnitAt(index + 3);
    final secondValue = _base64SextetValue(second);
    if (_base64SextetValue(first) < 0 || secondValue < 0) {
      _throwInvalidBase64();
    }

    final isLastQuartet = index + 4 == encodedLength;
    final int quartetBytes;
    if (third == 0x3d) {
      if (fourth != 0x3d || !isLastQuartet || (secondValue & 0x0f) != 0) {
        _throwInvalidBase64();
      }
      quartetBytes = 1;
    } else {
      final thirdValue = _base64SextetValue(third);
      if (thirdValue < 0) _throwInvalidBase64();
      if (fourth == 0x3d) {
        if (!isLastQuartet || (thirdValue & 0x03) != 0) _throwInvalidBase64();
        quartetBytes = 2;
      } else {
        if (_base64SextetValue(fourth) < 0) _throwInvalidBase64();
        quartetBytes = 3;
      }
    }

    if (quartetBytes > maxDecodedBytes - decodedBytes) {
      throw AcpInputLimitExceeded(
        resource: resource,
        limit: maxDecodedBytes,
        observedAtLeast: _safeObservedAtLeast(
          decodedBytes,
          quartetBytes,
          maxDecodedBytes,
        ),
      );
    }
    decodedBytes += quartetBytes;
  }

  return AcpBase64ScanResult(encodedLength, decodedBytes);
}

int _base64SextetValue(int codeUnit) {
  if (codeUnit >= 0x41 && codeUnit <= 0x5a) return codeUnit - 0x41;
  if (codeUnit >= 0x61 && codeUnit <= 0x7a) return codeUnit - 0x47;
  if (codeUnit >= 0x30 && codeUnit <= 0x39) return codeUnit + 0x04;
  if (codeUnit == 0x2b) return 62;
  if (codeUnit == 0x2f) return 63;
  return -1;
}

Never _throwInvalidBase64() {
  throw const FormatException('Invalid ACP Base64 encoding.');
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
      'reason': _omissionReasonWireName(reason),
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

final class AcpTextBudgetChunk {
  const AcpTextBudgetChunk({
    required this.safePrefix,
    required this.acceptedBytes,
    required this.totalBytes,
    required this.totalLines,
    this.omission,
  });

  final String safePrefix;
  final int acceptedBytes;
  final int totalBytes;
  final int totalLines;
  final AcpInputOmission? omission;
}

/// Counts UTF-8 bytes and logical lines without joining input chunks.
final class AcpUtf8LineBudgetCounter {
  AcpUtf8LineBudgetCounter({
    required int maxBytes,
    required int maxLines,
    required String resource,
  }) : _maxBytes = maxBytes,
       _maxLines = maxLines,
       _resource = resource {
    _requirePositiveSafeBudgetInteger(_maxBytes, 'maxBytes');
    _requirePositiveSafeBudgetInteger(_maxLines, 'maxLines');
  }

  final int _maxBytes;
  final int _maxLines;
  final String _resource;

  var _totalBytes = 0;
  var _totalLines = 0;
  var _previousWasCR = false;
  var _finished = false;
  var _omitted = false;
  int? _pendingHighSurrogate;

  AcpTextBudgetChunk append(String chunk) {
    if (_finished) {
      throw StateError('Cannot append after the text budget is finished.');
    }
    if (_omitted) return _emptyChunk();
    return _consume(chunk, finish: false);
  }

  AcpTextBudgetChunk finish() {
    if (_finished) return _emptyChunk();
    _finished = true;
    if (_omitted) return _emptyChunk();
    return _consume('', finish: true);
  }

  AcpTextBudgetChunk _consume(String chunk, {required bool finish}) {
    final safePrefix = StringBuffer();
    var acceptedBytes = 0;
    AcpInputOmission? omission;
    var index = 0;

    bool accept(String text, int byteCount, int firstCodeUnit) {
      final startsText = _totalBytes == 0;
      var addedLines = startsText ? 1 : 0;
      if (firstCodeUnit == 0x0d) {
        addedLines += 1;
      } else if (firstCodeUnit == 0x0a && !_previousWasCR) {
        addedLines += 1;
      }

      if (byteCount > _maxBytes - _totalBytes) {
        omission = _makeOmission(
          _maxBytes,
          _safeObservedAtLeast(_totalBytes, byteCount, _maxBytes),
        );
        _omitted = true;
        return false;
      }
      if (addedLines > _maxLines - _totalLines) {
        omission = _makeOmission(
          _maxLines,
          _safeObservedAtLeast(_totalLines, addedLines, _maxLines),
        );
        _omitted = true;
        return false;
      }

      safePrefix.write(text);
      acceptedBytes += byteCount;
      _totalBytes += byteCount;
      _totalLines += addedLines;
      _previousWasCR = firstCodeUnit == 0x0d;
      return true;
    }

    final pendingHigh = _pendingHighSurrogate;
    if (pendingHigh != null && (chunk.isNotEmpty || finish)) {
      _pendingHighSurrogate = null;
      if (chunk.isNotEmpty && _isLowSurrogate(chunk.codeUnitAt(0))) {
        final low = chunk.codeUnitAt(0);
        if (!accept(
          String.fromCharCodes(<int>[pendingHigh, low]),
          4,
          pendingHigh,
        )) {
          return _chunk(safePrefix, acceptedBytes, omission);
        }
        index = 1;
      } else if (!accept(String.fromCharCode(pendingHigh), 3, pendingHigh)) {
        return _chunk(safePrefix, acceptedBytes, omission);
      }
    }

    while (index < chunk.length) {
      final codeUnit = chunk.codeUnitAt(index);
      if (_isHighSurrogate(codeUnit)) {
        final nextIndex = index + 1;
        if (nextIndex == chunk.length) {
          _pendingHighSurrogate = codeUnit;
          break;
        }
        final next = chunk.codeUnitAt(nextIndex);
        if (_isLowSurrogate(next)) {
          if (!accept(chunk.substring(index, index + 2), 4, codeUnit)) break;
          index += 2;
          continue;
        }
      }

      final byteCount = codeUnit <= 0x7f
          ? 1
          : codeUnit <= 0x7ff
          ? 2
          : 3;
      if (!accept(chunk.substring(index, index + 1), byteCount, codeUnit)) {
        break;
      }
      index += 1;
    }

    return _chunk(safePrefix, acceptedBytes, omission);
  }

  AcpInputOmission _makeOmission(int limit, int observedAtLeast) =>
      AcpInputOmission(
        reason: AcpInputOmissionReason.inputLimit,
        resource: _resource,
        truncated: true,
        limit: limit,
        observedAtLeast: observedAtLeast,
      );

  AcpTextBudgetChunk _chunk(
    StringBuffer prefix,
    int acceptedBytes,
    AcpInputOmission? omission,
  ) => AcpTextBudgetChunk(
    safePrefix: prefix.toString(),
    acceptedBytes: acceptedBytes,
    totalBytes: _totalBytes,
    totalLines: _totalLines,
    omission: omission,
  );

  AcpTextBudgetChunk _emptyChunk() => AcpTextBudgetChunk(
    safePrefix: '',
    acceptedBytes: 0,
    totalBytes: _totalBytes,
    totalLines: _totalLines,
  );
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

/// Deterministically estimates retained JSON-compatible ACP state.
final class AcpRetainedSizeEstimator {
  AcpRetainedSizeEstimator({required AcpInputBudget budget})
    : _budget = budget {
    budget.validate();
  }

  final AcpInputBudget _budget;

  int estimate(Object? value) {
    var nodes = 0;
    var bytes = 0;
    final activeContainers = HashSet<Object>.identity();
    final pending = <_RetainedSizeFrame>[
      _RetainedValueFrame(value: value, depth: 1),
    ];

    Never throwLimit(String resource, int limit, int observedAtLeast) {
      throw AcpInputLimitExceeded(
        resource: resource,
        limit: limit,
        observedAtLeast: observedAtLeast,
      );
    }

    void recordNode() {
      if (nodes >= _budget.maxMetadataNodes) {
        throwLimit(
          'ACP retained state nodes',
          _budget.maxMetadataNodes,
          _budget.maxMetadataNodes + 1,
        );
      }
      nodes += 1;
    }

    void precheckNodes(int count) {
      if (count > _budget.maxMetadataNodes - nodes) {
        throwLimit(
          'ACP retained state nodes',
          _budget.maxMetadataNodes,
          _safeObservedAtLeast(nodes, count, _budget.maxMetadataNodes),
        );
      }
    }

    void addBytes(int count) {
      if (count > _maxSafeBudgetInteger - bytes) {
        throwLimit(
          'ACP retained state bytes',
          _maxSafeBudgetInteger,
          _maxSafeBudgetInteger + 1,
        );
      }
      bytes += count;
    }

    void addRepeatedOverhead(int count) {
      if (count > _maxSafeBudgetInteger ~/ 32) {
        throwLimit(
          'ACP retained state bytes',
          _maxSafeBudgetInteger,
          _maxSafeBudgetInteger + 1,
        );
      }
      addBytes(count * 32);
    }

    void checkDepth(int depth) {
      if (depth > _budget.maxMetadataDepth) {
        throwLimit('ACP retained state depth', _budget.maxMetadataDepth, depth);
      }
    }

    int stringBytes(String string) {
      var result = 0;
      var index = 0;
      while (index < string.length) {
        final codeUnit = string.codeUnitAt(index);
        final int codePointBytes;
        if (codeUnit <= 0x7f) {
          codePointBytes = 1;
        } else if (codeUnit <= 0x7ff) {
          codePointBytes = 2;
        } else if (_isHighSurrogate(codeUnit) &&
            index + 1 < string.length &&
            _isLowSurrogate(string.codeUnitAt(index + 1))) {
          codePointBytes = 4;
          index += 1;
        } else {
          codePointBytes = 3;
        }
        if (codePointBytes > _budget.maxStructuredStringBytes - result) {
          throwLimit(
            'ACP retained state string bytes',
            _budget.maxStructuredStringBytes,
            _safeObservedAtLeast(
              result,
              codePointBytes,
              _budget.maxStructuredStringBytes,
            ),
          );
        }
        result += codePointBytes;
        index += 1;
      }
      return result;
    }

    void checkCollectionLength(int length, int limit, String resource) {
      if (length > limit) throwLimit(resource, limit, length);
    }

    while (pending.isNotEmpty) {
      final frame = pending.removeLast();
      if (frame is _RetainedExitFrame) {
        activeContainers.remove(frame.container);
        continue;
      }

      final valueFrame = frame as _RetainedValueFrame;
      final current = valueFrame.value;
      recordNode();

      if (current is List) {
        if (activeContainers.contains(current)) {
          throw const FormatException(
            'Invalid ACP retained state: cyclic container.',
          );
        }
        checkDepth(valueFrame.depth);
        final length = current.length;
        checkCollectionLength(
          length,
          _budget.maxCollectionItems,
          'ACP retained state collection items',
        );
        precheckNodes(length);
        addBytes(64);
        addRepeatedOverhead(length);
        activeContainers.add(current);
        pending.add(_RetainedExitFrame(current));
        for (var index = length - 1; index >= 0; index -= 1) {
          pending.add(
            _RetainedValueFrame(
              value: current[index],
              depth: valueFrame.depth + 1,
            ),
          );
        }
        continue;
      }

      if (current is Map) {
        if (activeContainers.contains(current)) {
          throw const FormatException(
            'Invalid ACP retained state: cyclic container.',
          );
        }
        checkDepth(valueFrame.depth);
        final entryLimit = math.min(
          _budget.maxCollectionItems,
          _budget.maxMetadataEntries,
        );
        final reportedLength = current.length;
        checkCollectionLength(
          reportedLength,
          entryLimit,
          'ACP retained state map entries',
        );
        precheckNodes(reportedLength);
        final entries = <MapEntry<String, Object?>>[];
        for (final entry in current.entries) {
          precheckNodes(entries.length + 1);
          if (entry.key is! String) {
            throw const FormatException(
              'Invalid ACP retained state: map key must be a string.',
            );
          }
          if (entries.length >= entryLimit) {
            throwLimit(
              'ACP retained state map entries',
              entryLimit,
              entryLimit + 1,
            );
          }
          final key = entry.key as String;
          addBytes(stringBytes(key));
          entries.add(MapEntry<String, Object?>(key, entry.value));
        }
        precheckNodes(entries.length);
        addBytes(64);
        addRepeatedOverhead(entries.length);
        activeContainers.add(current);
        pending.add(_RetainedExitFrame(current));
        for (var index = entries.length - 1; index >= 0; index -= 1) {
          pending.add(
            _RetainedValueFrame(
              value: entries[index].value,
              depth: valueFrame.depth + 1,
            ),
          );
        }
        continue;
      }

      if (current is AcpInputOmission) {
        checkDepth(valueFrame.depth);
        final isInputLimit =
            current.reason == AcpInputOmissionReason.inputLimit;
        final fieldCount = isInputLimit ? 5 : 3;
        precheckNodes(fieldCount);
        addBytes(64);
        addRepeatedOverhead(fieldCount);
        pending.add(
          _RetainedValueFrame(
            value: current.truncated,
            depth: valueFrame.depth + 1,
          ),
        );
        if (isInputLimit) {
          pending.add(
            _RetainedValueFrame(
              value: current.observedAtLeast!,
              depth: valueFrame.depth + 1,
            ),
          );
          pending.add(
            _RetainedValueFrame(
              value: current.limit!,
              depth: valueFrame.depth + 1,
            ),
          );
        }
        pending.add(
          _RetainedValueFrame(
            value: current.resource,
            depth: valueFrame.depth + 1,
          ),
        );
        pending.add(
          _RetainedValueFrame(
            value: _omissionReasonWireName(current.reason),
            depth: valueFrame.depth + 1,
          ),
        );
        continue;
      }

      if (current is String) {
        addBytes(stringBytes(current));
        continue;
      }
      if (current is int) {
        addBytes(current.toString().length);
        continue;
      }
      if (current is double) {
        if (!current.isFinite) {
          throw const FormatException(
            'Invalid ACP retained state: number must be finite.',
          );
        }
        addBytes(current.toString().length);
        continue;
      }
      if (current is bool) {
        addBytes(current ? 4 : 5);
        continue;
      }
      if (current == null) {
        addBytes(4);
        continue;
      }
      throw const FormatException(
        'Invalid ACP retained state: unsupported value.',
      );
    }

    return bytes;
  }
}

String _omissionReasonWireName(AcpInputOmissionReason reason) =>
    switch (reason) {
      AcpInputOmissionReason.inputLimit => 'input_limit',
      AcpInputOmissionReason.invalidEncoding => 'invalid_encoding',
      AcpInputOmissionReason.invalidImage => 'invalid_image',
      AcpInputOmissionReason.invalidStructure => 'invalid_structure',
    };

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

bool _isHighSurrogate(int codeUnit) => codeUnit >= 0xd800 && codeUnit <= 0xdbff;

bool _isLowSurrogate(int codeUnit) => codeUnit >= 0xdc00 && codeUnit <= 0xdfff;

int _safeObservedAtLeast(int current, int increment, int limit) {
  if (current <= _maxSafeBudgetInteger - increment) {
    return current + increment;
  }
  return limit + 1;
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

sealed class _RetainedSizeFrame {
  const _RetainedSizeFrame();
}

final class _RetainedValueFrame extends _RetainedSizeFrame {
  const _RetainedValueFrame({required this.value, required this.depth});

  final Object? value;
  final int depth;
}

final class _RetainedExitFrame extends _RetainedSizeFrame {
  const _RetainedExitFrame(this.container);

  final Object container;
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
