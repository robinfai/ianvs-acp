import 'package:mime/mime.dart' as mime;

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
