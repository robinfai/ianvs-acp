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

/// Text content block.
class TextContent extends ContentBlock {
  /// Creates a text content block.
  const TextContent({required this.text});

  /// Creates from JSON.
  factory TextContent.fromJson(Map<String, dynamic> json) =>
      TextContent(text: _optionalString(json['text'] ?? json['content']) ?? '');

  /// The text content.
  final String text;

  @override
  Map<String, dynamic> toJson() => {'type': 'text', 'text': text};
}

/// Image content block.
class ImageContent extends ContentBlock {
  /// Creates an image content block.
  const ImageContent({required this.mimeType, required this.data});

  /// Creates from JSON.
  factory ImageContent.fromJson(Map<String, dynamic> json) => ImageContent(
    mimeType: _optionalString(json['mimeType'] ?? json['mime_type']) ?? '',
    data:
        _optionalString(json['data'] ?? json['base64Data'] ?? json['base64']) ??
        '',
  );

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
  factory AudioContent.fromJson(Map<String, dynamic> json) => AudioContent(
    mimeType: _optionalString(json['mimeType'] ?? json['mime_type']) ?? '',
    data: _optionalString(json['data'] ?? json['base64Data'] ?? json['base64']),
    uri: _optionalString(json['uri']),
  );

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
      mimeType:
          _optionalString(json['mimeType'] ?? json['mime_type']) ??
          _optionalString(source['mimeType'] ?? source['mime_type']),
      text: _optionalString(source['text'] ?? source['content']),
      blob: _optionalString(source['blob']),
      size: _optionalNum(source['size']),
      embedded: embedded,
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
