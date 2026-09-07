import 'package:flutter/widgets.dart';
import '../models/prompt_attachment.dart';
import 'chat_platform_stub.dart'
    if (dart.library.io) 'chat_platform_io.dart'
    as platform;

Future<PromptAttachment?> readDroppedImageAttachment(
  PromptAttachment attachment,
) => platform.readDroppedImageAttachment(attachment);

typedef ChatPathResolver =
    Future<String> Function(String path, {required bool isDirectory});

/// Override platform access at the embedding boundary. Defaults use standard
/// desktop pickers/files; no host-specific MethodChannel or workspace exists.
class ChatPlatformServices {
  const ChatPlatformServices({
    this.pickAttachments = platform.pickPlatformAttachments,
    this.readImage = platform.readDroppedImageAttachment,
    this.resolvePath = platform.resolvePlatformPath,
    this.imageForPath = platform.platformImageForPath,
    this.workingDirectory = platform.platformWorkingDirectory,
  });
  final Future<List<PromptAttachment>> Function(PromptAttachmentKind kind)
  pickAttachments;
  final Future<PromptAttachment?> Function(PromptAttachment attachment)
  readImage;
  final ChatPathResolver resolvePath;
  final String Function() workingDirectory;
  final ImageProvider<Object> Function(String path) imageForPath;
}

class ChatPlatformScope extends InheritedWidget {
  const ChatPlatformScope({
    super.key,
    required this.services,
    required super.child,
  });
  final ChatPlatformServices services;

  /// Lookup is safe in event handlers and state initialization, and does not
  /// establish an inherited dependency before initState has finished.
  static ChatPlatformServices of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ChatPlatformScope>()?.services ??
      const ChatPlatformServices();
  @override
  bool updateShouldNotify(ChatPlatformScope oldWidget) =>
      !identical(services, oldWidget.services);
}
