// Content block types for ACP messages.

/// Base class for content blocks.
sealed class ContentBlock {
  const ContentBlock();

  /// Convert to JSON for wire format.
  Map<String, dynamic> toJson();

  /// Create from JSON.
  static ContentBlock fromJson(Map<String, dynamic> json) {
    final type = _normalizedType(_optionalString(json['type']));
    switch (type) {
      case 'text':
        return TextContent.fromJson(json);
      case 'image':
        return ImageContent.fromJson(json);
      case 'audio':
        return AudioContent.fromJson(json);
      case 'resource_link':
        // Preferred wire form for files/URIs
        return ResourceContent.fromJson(json);
      case 'resource':
        // Back-compat: treat legacy/embedded shape as a link if presented
        // in link-like form (uri/title/mimeType only). The library does not
        // construct embedded resources; prefer resource_link.
        return ResourceContent.fromJson(json);
      default:
        if (_optionalString(json['text'] ?? json['content']) != null) {
          return TextContent.fromJson(json);
        }
        if (_looksLikeImageContent(json)) {
          return ImageContent.fromJson(json);
        }
        if (_looksLikeAudioContent(json)) {
          return AudioContent.fromJson(json);
        }
        if (_looksLikeResourceContent(json)) {
          return ResourceContent.fromJson(json);
        }
        return UnknownContent(_dynamicMap(json));
    }
  }
}

/// Optional ACP display and routing hints for content.
class ContentAnnotations {
  /// Creates content annotations.
  const ContentAnnotations({
    this.audience = const <String>[],
    this.lastModified,
    this.priority,
    this.meta,
  });

  /// Parses annotations while preserving unknown extension metadata.
  factory ContentAnnotations.fromJson(Map<String, dynamic> json) =>
      ContentAnnotations(
        audience: json['audience'] is List
            ? (json['audience'] as List).whereType<String>().toList()
            : const <String>[],
        lastModified: _optionalString(json['lastModified']),
        priority: _optionalNum(json['priority']),
        meta: _optionalMap(json['_meta']),
      );

  /// Intended recipients (`user` and/or `assistant`).
  final List<String> audience;

  /// ISO-8601 last-modified timestamp.
  final String? lastModified;

  /// Relative display priority.
  final num? priority;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  /// Converts to the ACP wire representation.
  Map<String, dynamic> toJson() => {
    if (audience.isNotEmpty) 'audience': audience,
    if (lastModified != null) 'lastModified': lastModified,
    if (priority != null) 'priority': priority,
    if (meta != null) '_meta': meta,
  };
}

/// Text content block.
class TextContent extends ContentBlock {
  /// Creates a text content block.
  const TextContent({required this.text, this.annotations, this.meta});

  /// Creates from JSON.
  factory TextContent.fromJson(Map<String, dynamic> json) => TextContent(
    text: _optionalString(json['text'] ?? json['content']) ?? '',
    annotations: _annotationsFromRaw(json['annotations']),
    meta: _optionalMap(json['_meta']),
  );

  /// The text content.
  final String text;

  /// Optional display and routing hints.
  final ContentAnnotations? annotations;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'text',
    'text': text,
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta != null) '_meta': meta,
  };
}

/// Image content block.
class ImageContent extends ContentBlock {
  /// Creates an image content block.
  const ImageContent({
    required this.mimeType,
    required this.data,
    this.uri,
    this.annotations,
    this.meta,
  });

  /// Creates from JSON.
  factory ImageContent.fromJson(Map<String, dynamic> json) => ImageContent(
    mimeType: _optionalString(json['mimeType'] ?? json['mime_type']) ?? '',
    data:
        _optionalString(json['data'] ?? json['base64Data'] ?? json['base64']) ??
        '',
    uri: _optionalString(json['uri']),
    annotations: _annotationsFromRaw(json['annotations']),
    meta: _optionalMap(json['_meta']),
  );

  /// MIME type of the image.
  final String mimeType;

  /// Base64-encoded image data.
  final String data;

  /// Optional URI associated with the image.
  final String? uri;

  /// Optional display and routing hints.
  final ContentAnnotations? annotations;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'image',
    'mimeType': mimeType,
    'data': data,
    if (uri != null) 'uri': uri,
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta != null) '_meta': meta,
  };
}

/// Audio content block.
class AudioContent extends ContentBlock {
  /// Creates an audio content block.
  const AudioContent({
    required this.mimeType,
    this.data,
    this.uri,
    this.annotations,
    this.meta,
  });

  /// Creates from JSON.
  factory AudioContent.fromJson(Map<String, dynamic> json) => AudioContent(
    mimeType: _optionalString(json['mimeType'] ?? json['mime_type']) ?? '',
    data: _optionalString(json['data'] ?? json['base64Data'] ?? json['base64']),
    uri: _optionalString(json['uri']),
    annotations: _annotationsFromRaw(json['annotations']),
    meta: _optionalMap(json['_meta']),
  );

  /// MIME type of the audio.
  final String mimeType;

  /// Base64-encoded audio data, if embedded.
  final String? data;

  /// Optional URI for linked audio.
  final String? uri;

  /// Optional display and routing hints.
  final ContentAnnotations? annotations;

  /// ACP extension metadata.
  final Map<String, dynamic>? meta;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'audio',
    'mimeType': mimeType,
    // ACP 1.2.1 requires embedded audio data and has no audio URI field.
    // Keep [uri] only as a legacy read-side compatibility property.
    'data': data ?? '',
    if (annotations != null) 'annotations': annotations!.toJson(),
    if (meta != null) '_meta': meta,
  };
}

/// Resource link content block.
class ResourceContent extends ContentBlock {
  /// Creates a resource content block.
  const ResourceContent({
    required this.uri,
    this.title,
    this.name,
    this.description,
    this.mimeType,
    this.text,
    this.blob,
    this.size,
    this.embedded = false,
    this.annotations,
    this.meta,
    this.resourceMeta,
  });

  /// Creates from JSON.
  factory ResourceContent.fromJson(Map<String, dynamic> json) {
    final nested = _optionalMap(json['resource']);
    final source = nested ?? json;
    final type = _normalizedType(_optionalString(json['type']));
    final embedded = nested != null || type == 'resource';
    return ResourceContent(
      uri:
          _optionalString(json['uri']) ??
          _optionalString(source['uri']) ??
          _optionalString(source['url']) ??
          _optionalString(source['path']) ??
          '',
      title:
          _optionalString(json['title'] ?? json['name'] ?? json['label']) ??
          _optionalString(source['title'] ?? source['name'] ?? source['label']),
      name:
          _optionalString(json['name']) ??
          _optionalString(source['name']) ??
          _optionalString(json['title']) ??
          _optionalString(source['title']),
      description: _optionalString(
        json['description'] ?? source['description'],
      ),
      mimeType:
          _optionalString(json['mimeType'] ?? json['mime_type']) ??
          _optionalString(source['mimeType'] ?? source['mime_type']),
      text: _optionalString(source['text'] ?? source['content']),
      blob: _optionalString(source['blob']),
      size: _optionalNum(source['size']),
      embedded: embedded,
      annotations: _annotationsFromRaw(json['annotations']),
      meta: _optionalMap(json['_meta']),
      resourceMeta: _optionalMap(source['_meta']),
    );
  }

  /// URI of the resource.
  final String uri;

  /// Optional title.
  final String? title;

  /// Human-readable resource name required for resource links.
  final String? name;

  /// Optional resource description.
  final String? description;

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

  /// Optional display and routing hints.
  final ContentAnnotations? annotations;

  /// ACP extension metadata on the content block.
  final Map<String, dynamic>? meta;

  /// ACP extension metadata on the embedded resource payload.
  final Map<String, dynamic>? resourceMeta;

  @override
  Map<String, dynamic> toJson() {
    if (embedded) {
      return {
        'type': 'resource',
        'resource': {
          'uri': uri,
          if (mimeType != null) 'mimeType': mimeType,
          if (text != null) 'text': text,
          if (blob != null) 'blob': blob,
          if (resourceMeta != null) '_meta': resourceMeta,
        },
        if (annotations != null) 'annotations': annotations!.toJson(),
        if (meta != null) '_meta': meta,
      };
    }
    return {
      // Prefer resource_link over embedded resource payloads.
      'type': 'resource_link',
      'uri': uri,
      'name': name ?? title ?? uri,
      if (title != null) 'title': title,
      if (description != null) 'description': description,
      if (mimeType != null) 'mimeType': mimeType,
      if (size != null) 'size': size,
      if (annotations != null) 'annotations': annotations!.toJson(),
      if (meta != null) '_meta': meta,
    };
  }
}

/// Unknown content block for forward compatibility.
class UnknownContent extends ContentBlock {
  /// Creates an unknown content block.
  const UnknownContent(this.data);

  /// Raw data for unknown content type.
  final Map<String, dynamic> data;

  @override
  Map<String, dynamic> toJson() => data;
}

String? _optionalString(Object? value) => value is String ? value : null;

num? _optionalNum(Object? value) => value is num ? value : null;

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value is! Map) return null;
  return _dynamicMap(value);
}

ContentAnnotations? _annotationsFromRaw(Object? raw) {
  final map = _optionalMap(raw);
  return map == null ? null : ContentAnnotations.fromJson(map);
}

Map<String, dynamic> _dynamicMap(Map<dynamic, dynamic> value) {
  return value.map((key, value) => MapEntry(key.toString(), value));
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
  final mimeType = _optionalString(json['mimeType'] ?? json['mime_type']);
  if (mimeType?.startsWith('audio/') == true) return false;
  return _optionalString(
        json['data'] ?? json['base64Data'] ?? json['base64'],
      ) !=
      null;
}

bool _looksLikeAudioContent(Map<String, dynamic> json) {
  final mimeType = _optionalString(json['mimeType'] ?? json['mime_type']);
  return mimeType?.startsWith('audio/') == true;
}

bool _looksLikeResourceContent(Map<String, dynamic> json) {
  return _optionalMap(json['resource']) != null ||
      _optionalString(json['uri'] ?? json['url'] ?? json['path']) != null;
}
