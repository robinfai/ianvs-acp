class ChatPromptCapabilities {
  const ChatPromptCapabilities({
    this.files = true,
    required this.image,
    required this.audio,
    required this.embeddedContext,
  });

  factory ChatPromptCapabilities.fromRaw(Object? raw) {
    final caps = raw is Map
        ? Map<String, Object?>.from(raw)
        : const <String, Object?>{};
    return ChatPromptCapabilities(
      image: caps['image'] == true,
      audio: caps['audio'] == true,
      embeddedContext: caps['embeddedContext'] == true,
    );
  }

  /// Whether arbitrary file references or uploads are accepted by the host.
  final bool files;
  final bool image;
  final bool audio;
  final bool embeddedContext;

  ChatPromptCapabilities copyWith({
    bool? files,
    bool? image,
    bool? audio,
    bool? embeddedContext,
  }) {
    return ChatPromptCapabilities(
      files: files ?? this.files,
      image: image ?? this.image,
      audio: audio ?? this.audio,
      embeddedContext: embeddedContext ?? this.embeddedContext,
    );
  }
}
