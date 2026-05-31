// Content block types for ACP messages.

/// Base class for content blocks.
sealed class ContentBlock {
  const ContentBlock();

  /// Convert to JSON for wire format.
  Map<String, dynamic> toJson();

  /// Create from JSON.
  static ContentBlock fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'text':
        return TextContent.fromJson(json);
      case 'image':
        return ImageContent.fromJson(json);
      case 'resource_link':
        // Preferred wire form for files/URIs
        return ResourceContent.fromJson(json);
      case 'resource':
        // Back-compat: treat legacy/embedded shape as a link if presented
        // in link-like form (uri/title/mimeType only). The library does not
        // construct embedded resources; prefer resource_link.
        return ResourceContent.fromJson(json);
      default:
        return UnknownContent(json);
    }
  }
}

/// Text content block.
class TextContent extends ContentBlock {
  /// Creates a text content block.
  const TextContent({required this.text});

  /// Creates from JSON.
  factory TextContent.fromJson(Map<String, dynamic> json) =>
      TextContent(text: json['text'] as String? ?? '');

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
    mimeType: json['mimeType'] as String? ?? '',
    data: json['data'] as String? ?? '',
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

/// Resource link content block.
class ResourceContent extends ContentBlock {
  /// Creates a resource content block.
  const ResourceContent({required this.uri, this.title, this.mimeType});

  /// Creates from JSON.
  factory ResourceContent.fromJson(Map<String, dynamic> json) =>
      ResourceContent(
        uri: json['uri'] as String? ?? '',
        title: json['title'] as String?,
        mimeType: json['mimeType'] as String?,
      );

  /// URI of the resource.
  final String uri;

  /// Optional title.
  final String? title;

  /// Optional MIME type.
  final String? mimeType;

  @override
  Map<String, dynamic> toJson() => {
    // Prefer resource_link over embedded resource payloads.
    'type': 'resource_link',
    'uri': uri,
    if (title != null) 'title': title,
    if (mimeType != null) 'mimeType': mimeType,
  };
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
