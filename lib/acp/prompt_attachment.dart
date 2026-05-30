import 'package:mime/mime.dart' as mime;

import 'acp_agent_capabilities.dart';

enum PromptAttachmentPromptMode { image, audio, embeddedResource, resourceLink }

class PromptAttachment {
  const PromptAttachment({
    required this.path,
    required this.name,
    this.mimeType,
    this.size,
  });

  factory PromptAttachment.fromPath({
    required String path,
    String? name,
    String? mimeType,
    int? size,
  }) {
    final normalizedName = name?.trim();
    return PromptAttachment(
      path: path,
      name: normalizedName == null || normalizedName.isEmpty
          ? _basename(path)
          : normalizedName,
      mimeType: mimeType ?? mime.lookupMimeType(path),
      size: size,
    );
  }

  final String path;
  final String name;
  final String? mimeType;
  final int? size;

  Uri get uri => Uri.file(path);

  Map<String, Object?> toResourceLink() {
    return <String, Object?>{
      'type': 'resource_link',
      'uri': uri.toString(),
      'name': name,
      if (mimeType != null && mimeType!.isNotEmpty) 'mimeType': mimeType,
      if (size != null) 'size': size,
    };
  }

  PromptAttachmentPromptMode promptMode(AcpPromptCapabilities? capabilities) {
    if (isImage) {
      return capabilities?.image == true
          ? PromptAttachmentPromptMode.image
          : PromptAttachmentPromptMode.resourceLink;
    }
    if (isAudio) {
      return capabilities?.audio == true
          ? PromptAttachmentPromptMode.audio
          : PromptAttachmentPromptMode.resourceLink;
    }
    if (isText || isGenericBinary) {
      return capabilities?.embeddedContext == true
          ? PromptAttachmentPromptMode.embeddedResource
          : PromptAttachmentPromptMode.resourceLink;
    }
    return PromptAttachmentPromptMode.resourceLink;
  }

  bool get isImage => imageMimeType != null;

  bool get isAudio => audioMimeType != null;

  bool get isGenericBinary => !isImage && !isAudio && !isText;

  bool get isText {
    final type = mimeType?.toLowerCase();
    if (type != null) {
      if (type.startsWith('text/')) return true;
      if (const <String>{
        'application/json',
        'application/javascript',
        'application/toml',
        'application/xml',
        'application/x-yaml',
        'application/yaml',
      }.contains(type)) {
        return true;
      }
    }

    final lowerName = name.toLowerCase();
    return const <String>[
      '.c',
      '.cc',
      '.cpp',
      '.css',
      '.csv',
      '.dart',
      '.go',
      '.h',
      '.html',
      '.java',
      '.js',
      '.json',
      '.kt',
      '.log',
      '.md',
      '.php',
      '.py',
      '.rb',
      '.rs',
      '.sh',
      '.sql',
      '.swift',
      '.toml',
      '.ts',
      '.txt',
      '.xml',
      '.yaml',
      '.yml',
      '.zsh',
    ].any(lowerName.endsWith);
  }

  String? get imageMimeType {
    final type = mimeType?.toLowerCase();
    if (type != null && type.startsWith('image/')) return type;

    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.png')) return 'image/png';
    if (lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg')) {
      return 'image/jpeg';
    }
    if (lowerName.endsWith('.gif')) return 'image/gif';
    if (lowerName.endsWith('.webp')) return 'image/webp';
    if (lowerName.endsWith('.bmp')) return 'image/bmp';
    return null;
  }

  String? get audioMimeType {
    final type = mimeType?.toLowerCase();
    if (type != null && type.startsWith('audio/')) return type;

    final lowerName = name.toLowerCase();
    if (lowerName.endsWith('.wav') || lowerName.endsWith('.wave')) {
      return 'audio/wav';
    }
    if (lowerName.endsWith('.mp3')) return 'audio/mpeg';
    if (lowerName.endsWith('.m4a')) return 'audio/mp4';
    if (lowerName.endsWith('.aac')) return 'audio/aac';
    if (lowerName.endsWith('.flac')) return 'audio/flac';
    if (lowerName.endsWith('.ogg')) return 'audio/ogg';
    if (lowerName.endsWith('.opus')) return 'audio/opus';
    if (lowerName.endsWith('.webm')) return 'audio/webm';
    if (lowerName.endsWith('.aiff') || lowerName.endsWith('.aif')) {
      return 'audio/aiff';
    }
    return null;
  }

  String toPromptMention() => '@"${path.replaceAll('"', r'\"')}"';

  String get displaySize {
    final byteCount = size;
    if (byteCount == null) return '';
    if (byteCount < 1024) return '$byteCount B';
    final kb = byteCount / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
    final gb = mb / 1024;
    return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
  }

  @override
  bool operator ==(Object other) {
    return other is PromptAttachment &&
        other.path == path &&
        other.name == name &&
        other.mimeType == mimeType &&
        other.size == size;
  }

  @override
  int get hashCode => Object.hash(path, name, mimeType, size);

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    final parts = normalized.split('/');
    return parts.isEmpty ? path : parts.last;
  }
}
