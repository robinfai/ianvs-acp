// Content block types for ACP messages.

import '../input_budget.dart';

/// Base class for content blocks.
sealed class ContentBlock {
  const ContentBlock();

  /// Host-owned description of input omitted while building this block.
  AcpInputOmission? get omission => null;

  /// Convert to JSON for wire format.
  Map<String, dynamic> toJson();

  /// Create from JSON.
  static ContentBlock fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    try {
      _consumeBlock(json, guard);
      final type = _dispatchContentType(json, guard, inputBudget);
      return _fromJson(json, guard, inputBudget, type);
    } catch (error) {
      return UnknownContent.omitted(_blockFailureOmission(error));
    }
  }

  static ContentBlock _fromJson(
    Map<String, dynamic> json,
    AcpStructuredUpdateGuard guard,
    AcpInputBudget inputBudget,
    String? type,
  ) {
    switch (type) {
      case 'text':
        return TextContent._fromJson(json, inputBudget);
      case 'image':
        return ImageContent._fromJson(json, guard, inputBudget);
      case 'audio':
        return AudioContent._fromJson(json, guard, inputBudget);
      case 'resource_link':
        // Preferred wire form for files/URIs
        return ResourceContent._fromJson(json, guard, inputBudget, type);
      case 'resource':
        // Back-compat: treat legacy/embedded shape as a link if presented
        // in link-like form (uri/title/mimeType only). The library does not
        // construct embedded resources; prefer resource_link.
        return ResourceContent._fromJson(json, guard, inputBudget, type);
      default:
        if (type != null) return UnknownContent._fromJson(json, guard);
        if (_hasNonNullField(json, const <String>['text', 'content'])) {
          return TextContent._fromJson(json, inputBudget);
        }
        if (_looksLikeImageContent(json)) {
          return ImageContent._fromJson(json, guard, inputBudget);
        }
        if (_looksLikeAudioContent(json)) {
          return AudioContent._fromJson(json, guard, inputBudget);
        }
        if (_looksLikeResourceContent(json)) {
          return ResourceContent._fromJson(json, guard, inputBudget, type);
        }
        return UnknownContent._fromJson(json, guard);
    }
  }
}

/// Text content block.
class TextContent extends ContentBlock {
  /// Creates a text content block.
  const TextContent({required this.text, this.omission});

  /// Creates from JSON.
  factory TextContent.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    _consumeBlock(json, guard);
    _copyContentType(json, guard);
    return TextContent._fromJson(json, inputBudget);
  }

  factory TextContent._fromJson(
    Map<String, dynamic> json,
    AcpInputBudget inputBudget,
  ) {
    final bounded = _boundedDisplayText(
      _firstPresent(json, const <String>['text', 'content']),
      inputBudget,
      absentValue: '',
      invalidValue: '',
    );
    return TextContent(text: bounded.value, omission: bounded.omission);
  }

  /// The text content.
  final String text;

  @override
  final AcpInputOmission? omission;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

/// Image content block.
class ImageContent extends ContentBlock {
  /// Creates an image content block.
  const ImageContent({required this.mimeType, required this.data});

  /// Creates from JSON.
  factory ImageContent.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    _consumeBlock(json, guard);
    _copyContentType(json, guard);
    return ImageContent._fromJson(json, guard, inputBudget);
  }

  factory ImageContent._fromJson(
    Map<String, dynamic> json,
    AcpStructuredUpdateGuard guard,
    AcpInputBudget inputBudget,
  ) {
    final data = _requiredStringOrDefault(
      _firstRequiredAlias(json, const <String>['data', 'base64Data', 'base64']),
      defaultValue: '',
    );
    _scanEmbeddedMedia(data, inputBudget);
    return ImageContent(
      mimeType:
          _copyOptionalString(
            json,
            const <String>['mimeType', 'mime_type'],
            guard,
            field: 'image mime type',
          ) ??
          '',
      data: data,
    );
  }

  /// MIME type of the image.
  final String mimeType;

  /// Base64-encoded image data.
  final String data;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'mimeType': mimeType,
    'data': data,
  };
}

/// Audio content block.
class AudioContent extends ContentBlock {
  /// Creates an audio content block.
  const AudioContent({required this.mimeType, this.data, this.uri});

  /// Creates from JSON.
  factory AudioContent.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    _consumeBlock(json, guard);
    _copyContentType(json, guard);
    return AudioContent._fromJson(json, guard, inputBudget);
  }

  factory AudioContent._fromJson(
    Map<String, dynamic> json,
    AcpStructuredUpdateGuard guard,
    AcpInputBudget inputBudget,
  ) {
    final rawData = _firstNonNull(json, const <String>[
      'data',
      'base64Data',
      'base64',
    ]);
    final data = identical(rawData, _absentContentField) || rawData == null
        ? null
        : _requiredString(rawData);
    if (data != null) _scanEmbeddedMedia(data, inputBudget);
    return AudioContent(
      mimeType:
          _copyOptionalString(
            json,
            const <String>['mimeType', 'mime_type'],
            guard,
            field: 'audio mime type',
          ) ??
          '',
      data: data,
      uri: _copyOptionalString(
        json,
        const <String>['uri'],
        guard,
        field: 'audio uri',
      ),
    );
  }

  /// MIME type of the audio.
  final String mimeType;

  /// Base64-encoded audio data, if embedded.
  final String? data;

  /// Optional URI for linked audio.
  final String? uri;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    'mimeType': mimeType,
    if (data != null) 'data': data,
    if (uri != null) 'uri': uri,
  };
}

/// Resource link content block.
class ResourceContent extends ContentBlock {
  /// Creates a resource content block.
  const ResourceContent({
    required this.uri,
    this.title,
    this.mimeType,
    this.text,
    this.blob,
    this.size,
    this.embedded = false,
    this.omission,
  });

  /// Creates from JSON.
  factory ResourceContent.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    _consumeBlock(json, guard);
    final type = _copyContentType(json, guard);
    return ResourceContent._fromJson(json, guard, inputBudget, type);
  }

  factory ResourceContent._fromJson(
    Map<String, dynamic> json,
    AcpStructuredUpdateGuard guard,
    AcpInputBudget inputBudget,
    String? type,
  ) {
    final nested = _resourceSource(json, guard, inputBudget);
    final source = nested ?? json;
    final embedded = nested != null || type == 'resource';
    final text = _boundedDisplayText(
      _firstPresent(source, const <String>['text', 'content']),
      inputBudget,
      absentValue: null,
      invalidValue: '',
    );
    final rawBlob = _firstNonNull(source, const <String>['blob']);
    final blob = identical(rawBlob, _absentContentField) || rawBlob == null
        ? null
        : _requiredString(rawBlob);
    if (blob != null) _scanEmbeddedMedia(blob, inputBudget);
    final rawSize = _firstNonNull(source, const <String>['size']);
    final size = nested == null
        ? _copyOptionalNumber(rawSize, guard, field: 'resource size')
        : _prevalidatedOptionalNumber(rawSize);
    return ResourceContent(
      uri:
          _copyResourceString(
            json,
            nested,
            const <String>['uri', 'url', 'path'],
            guard,
            field: 'resource uri',
          ) ??
          '',
      title: _copyResourceString(
        json,
        nested,
        const <String>['title', 'name', 'label'],
        guard,
        field: 'resource title',
      ),
      mimeType: _copyResourceString(
        json,
        nested,
        const <String>['mimeType', 'mime_type'],
        guard,
        field: 'resource mime type',
      ),
      text: text.value,
      blob: blob,
      size: size,
      embedded: embedded,
      omission: text.omission,
    );
  }

  /// URI of the resource.
  final String uri;

  /// Optional title.
  final String? title;

  /// Optional MIME type.
  final String? mimeType;

  /// Optional embedded text payload.
  final String? text;

  /// Optional embedded blob payload.
  final String? blob;

  /// Optional resource size in bytes.
  final num? size;

  /// Whether to preserve embedded resource wire shape.
  final bool embedded;

  @override
  final AcpInputOmission? omission;

  @override
  Map<String, dynamic> toJson() {
    if (embedded) {
      return {
        'type': 'resource',
        'resource': {
          'uri': uri,
          if (title != null) 'title': title,
          if (mimeType != null) 'mimeType': mimeType,
          if (size != null) 'size': size,
          if (text != null) 'text': text,
          if (blob != null) 'blob': blob,
        },
      };
    }
    return {
      // Prefer resource_link over embedded resource payloads.
      'type': 'resource_link',
      'uri': uri,
      if (title != null) 'title': title,
      if (mimeType != null) 'mimeType': mimeType,
      if (size != null) 'size': size,
      if (text != null) 'text': text,
      if (blob != null) 'blob': blob,
    };
  }
}

/// Unknown content block for forward compatibility.
class UnknownContent extends ContentBlock {
  /// Creates an unknown content block.
  const UnknownContent(this.data, {this.omission});

  /// Creates an immutable, bounded copy of an unrecognized remote block.
  factory UnknownContent.fromJson(
    Map<String, dynamic> json, {
    AcpInputBudget inputBudget = const AcpInputBudget(),
    AcpStructuredUpdateGuard? structuredGuard,
  }) {
    final guard = _contentGuard(inputBudget, structuredGuard);
    try {
      _consumeBlock(json, guard);
      return UnknownContent._fromJson(json, guard);
    } on AcpInputLimitExceeded {
      rethrow;
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
  }

  factory UnknownContent._fromJson(
    Map<String, dynamic> json,
    AcpStructuredUpdateGuard guard,
  ) {
    final copy = guard.copyMetadata(json, field: 'unknown content');
    return UnknownContent(Map<String, dynamic>.unmodifiable(copy));
  }

  /// Creates a trusted local marker without retaining rejected input.
  factory UnknownContent.omitted(AcpInputOmission omission) =>
      UnknownContent(const <String, dynamic>{}, omission: omission);

  /// Raw data for unknown content type.
  final Map<String, dynamic> data;

  @override
  final AcpInputOmission? omission;

  @override
  Map<String, dynamic> toJson() {
    final trustedOmission = omission;
    if (trustedOmission != null) {
      return <String, dynamic>{'type': 'omitted', ...trustedOmission.toJson()};
    }
    return Map<String, dynamic>.from(data);
  }
}

const String _contentBlockResource = 'content_block';
const String _unknownContentType = '__unknown_content_type__';
const Set<String> _knownContentTypes = <String>{
  'text',
  'image',
  'audio',
  'resource',
  'resource_link',
};
const Set<String> _resourceStringKeys = <String>{
  'uri',
  'url',
  'path',
  'title',
  'name',
  'label',
  'mimeType',
  'mime_type',
};

AcpStructuredUpdateGuard _contentGuard(
  AcpInputBudget inputBudget,
  AcpStructuredUpdateGuard? structuredGuard,
) =>
    structuredGuard ??
    AcpStructuredUpdateGuard(
      budget: inputBudget,
      resource: _contentBlockResource,
    );

void _consumeBlock(Map<String, dynamic> json, AcpStructuredUpdateGuard guard) {
  guard.checkCollection(json, field: 'content block');
  guard.consumeEntry(field: 'content block');
}

String? _copyContentType(
  Map<String, dynamic> json,
  AcpStructuredUpdateGuard guard,
) {
  final type = _copyOptionalString(
    json,
    const <String>['type'],
    guard,
    field: 'content type',
  );
  return _normalizedType(type);
}

String? _dispatchContentType(
  Map<String, dynamic> json,
  AcpStructuredUpdateGuard guard,
  AcpInputBudget inputBudget,
) {
  final raw = _firstNonNull(json, const <String>['type']);
  if (identical(raw, _absentContentField)) return null;
  if (raw is! String) {
    throw const FormatException('Invalid ACP content block structure.');
  }
  // Bound normalization without consuming the shared guard. Known types are
  // consumed below; unknown types are consumed once by the full map copy.
  _validateContentTypeString(raw, inputBudget);
  final normalized = _normalizedType(raw);
  if (normalized == null || _knownContentTypes.contains(normalized)) {
    guard.copyString(raw, field: 'content type');
    return normalized;
  }
  return _unknownContentType;
}

void _validateContentTypeString(String raw, AcpInputBudget inputBudget) {
  final counter = AcpUtf8LineBudgetCounter(
    maxBytes: inputBudget.maxStructuredStringBytes,
    maxLines: 0x1fffffffffffff,
    resource: _contentTypeStringResource,
  );
  final appended = counter.append(raw);
  final finished = counter.finish();
  final omission = appended.omission ?? finished.omission;
  if (omission == null) return;
  throw AcpInputLimitExceeded(
    resource: _contentTypeStringResource,
    limit: omission.limit!,
    observedAtLeast: omission.observedAtLeast!,
  );
}

AcpInputOmission _blockFailureOmission(Object error) {
  if (error is _InvalidEmbeddedMediaEncoding) {
    return AcpInputOmission(
      reason: AcpInputOmissionReason.invalidEncoding,
      resource: _embeddedMediaResource,
      truncated: false,
    );
  }
  if (error is AcpInputLimitExceeded) {
    return AcpInputOmission(
      reason: AcpInputOmissionReason.inputLimit,
      resource: error.resource,
      truncated: false,
      limit: error.limit,
      observedAtLeast: error.observedAtLeast,
    );
  }
  return AcpInputOmission(
    reason: AcpInputOmissionReason.invalidStructure,
    resource: _contentBlockResource,
    truncated: false,
  );
}

const String _messageTextResource = 'message_text';
const String _embeddedMediaResource = 'embedded_media';
const String _contentTypeStringResource =
    'content_block content type string bytes';
const Object _absentContentField = Object();

final class _InvalidEmbeddedMediaEncoding extends FormatException {
  const _InvalidEmbeddedMediaEncoding()
    : super('Invalid ACP embedded media encoding.');
}

Object? _firstPresent(Map<String, dynamic> json, List<String> fields) {
  for (final field in fields) {
    try {
      if (json.containsKey(field)) return json[field];
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
  }
  return _absentContentField;
}

Object? _firstNonNull(Map<String, dynamic> json, List<String> fields) {
  for (final field in fields) {
    try {
      if (!json.containsKey(field)) continue;
      final value = json[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
  }
  return _absentContentField;
}

Object? _firstRequiredAlias(Map<String, dynamic> json, List<String> fields) {
  var found = false;
  for (final field in fields) {
    try {
      if (!json.containsKey(field)) continue;
      found = true;
      final value = json[field];
      if (value != null) return value;
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
  }
  return found ? null : _absentContentField;
}

bool _hasNonNullField(Map<String, dynamic> json, List<String> fields) =>
    !identical(_firstNonNull(json, fields), _absentContentField);

String? _copyOptionalString(
  Map<String, dynamic> json,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final value = _firstNonNull(json, fields);
  if (identical(value, _absentContentField)) return null;
  return guard.copyString(value, field: field);
}

num? _copyOptionalNumber(
  Object? value,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  if (value == null || identical(value, _absentContentField)) return null;
  final copy = guard.copyScalar(value, field: field);
  if (copy is num) return copy;
  throw const FormatException('Invalid ACP content block structure.');
}

num? _prevalidatedOptionalNumber(Object? value) {
  if (value == null || identical(value, _absentContentField)) return null;
  if (value is num) return value;
  throw const FormatException('Invalid ACP content block structure.');
}

Map<String, dynamic>? _resourceSource(
  Map<String, dynamic> json,
  AcpStructuredUpdateGuard guard,
  AcpInputBudget inputBudget,
) {
  final value = _firstNonNull(json, const <String>['resource']);
  if (identical(value, _absentContentField)) return null;
  if (value is! Map) {
    throw const FormatException('Invalid ACP content block structure.');
  }

  guard.checkCollection(value, field: 'resource object');
  guard.consumeContainerNode(field: 'resource object');
  final Iterator<MapEntry<dynamic, dynamic>> iterator;
  try {
    iterator = value.entries.iterator;
  } catch (_) {
    throw const FormatException('Invalid ACP content block structure.');
  }
  final copy = <String, dynamic>{};
  var count = 0;
  while (true) {
    final bool hasNext;
    try {
      hasNext = iterator.moveNext();
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
    if (!hasNext) break;
    if (count >= inputBudget.maxCollectionItems) {
      throw AcpInputLimitExceeded(
        resource: 'content_block resource object collection items',
        limit: inputBudget.maxCollectionItems,
        observedAtLeast: inputBudget.maxCollectionItems + 1,
      );
    }

    final MapEntry<dynamic, dynamic> entry;
    try {
      entry = iterator.current;
    } catch (_) {
      throw const FormatException('Invalid ACP content block structure.');
    }
    final key = entry.key;
    if (key is! String || copy.containsKey(key)) {
      throw const FormatException('Invalid ACP content block structure.');
    }
    final copiedKey = guard.copyString(key, field: 'resource key');
    final rawValue = entry.value;
    if (_resourceStringKeys.contains(copiedKey)) {
      copy[copiedKey] = rawValue == null
          ? null
          : guard.copyString(rawValue, field: 'resource value');
    } else if (copiedKey == 'size') {
      copy[copiedKey] = _copyOptionalNumber(
        rawValue,
        guard,
        field: 'resource size',
      );
    } else {
      copy[copiedKey] = rawValue;
    }
    count += 1;
  }
  return Map<String, dynamic>.unmodifiable(copy);
}

String? _copyResourceString(
  Map<String, dynamic> outer,
  Map<String, dynamic>? nested,
  List<String> fields,
  AcpStructuredUpdateGuard guard, {
  required String field,
}) {
  final outerValue = _copyOptionalString(outer, fields, guard, field: field);
  if (outerValue != null || nested == null) return outerValue;
  final nestedValue = _firstNonNull(nested, fields);
  if (identical(nestedValue, _absentContentField)) return null;
  if (nestedValue is String) return nestedValue;
  throw const FormatException('Invalid ACP content block structure.');
}

String _requiredString(Object? source) {
  if (source is String) return source;
  throw const FormatException('Invalid ACP content block structure.');
}

String _requiredStringOrDefault(
  Object? source, {
  required String defaultValue,
}) {
  if (identical(source, _absentContentField)) {
    return defaultValue;
  }
  return _requiredString(source);
}

void _scanEmbeddedMedia(String encoded, AcpInputBudget inputBudget) {
  try {
    scanAcpBase64(
      encoded,
      maxDecodedBytes: inputBudget.maxEmbeddedMediaBytes,
      resource: _embeddedMediaResource,
    );
  } on FormatException {
    throw const _InvalidEmbeddedMediaEncoding();
  }
}

({T value, AcpInputOmission? omission}) _boundedDisplayText<T>(
  Object? source,
  AcpInputBudget inputBudget, {
  required T absentValue,
  required T invalidValue,
}) {
  if (identical(source, _absentContentField)) {
    return (value: absentValue, omission: null);
  }
  if (source is! String) {
    return (
      value: invalidValue,
      omission: AcpInputOmission(
        reason: AcpInputOmissionReason.invalidStructure,
        resource: _messageTextResource,
        truncated: false,
      ),
    );
  }

  final counter = AcpUtf8LineBudgetCounter(
    maxBytes: inputBudget.maxMessageTextBytes,
    maxLines: inputBudget.maxMessageTextLines,
    resource: _messageTextResource,
  );
  final appended = counter.append(source);
  final finished = counter.finish();
  final omission = appended.omission ?? finished.omission;
  if (omission == null) return (value: source as T, omission: null);
  return (
    value: '${appended.safePrefix}${finished.safePrefix}' as T,
    omission: omission,
  );
}

String? _normalizedType(String? value) {
  if (value == null) return null;
  final cleaned = value.trim();
  if (cleaned.isEmpty) return null;
  return cleaned
      .replaceAllMapped(
        RegExp(r'([a-z0-9])([A-Z])'),
        (match) => '${match.group(1)}_${match.group(2)}',
      )
      .replaceAll(RegExp(r'[\s-]+'), '_')
      .toLowerCase();
}

bool _looksLikeImageContent(Map<String, dynamic> json) {
  final mime = _firstNonNull(json, const <String>['mimeType', 'mime_type']);
  final mimeType = mime is String ? mime : null;
  if (mimeType?.startsWith('audio/') == true) return false;
  return _hasNonNullField(json, const <String>['data', 'base64Data', 'base64']);
}

bool _looksLikeAudioContent(Map<String, dynamic> json) {
  final mime = _firstNonNull(json, const <String>['mimeType', 'mime_type']);
  return mime is String && mime.startsWith('audio/');
}

bool _looksLikeResourceContent(Map<String, dynamic> json) {
  return _hasNonNullField(json, const <String>['resource']) ||
      _hasNonNullField(json, const <String>['uri', 'url', 'path']);
}
