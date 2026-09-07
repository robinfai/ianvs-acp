import 'package:flutter/painting.dart';
import 'package:file_picker/file_picker.dart';
import '../models/prompt_attachment.dart';

ImageProvider<Object> platformImageForPath(String path) =>
    throw UnsupportedError('Provide imageForPath for this platform.');
Future<String> resolvePlatformPath(
  String path, {
  required bool isDirectory,
}) async => path;
Future<PromptAttachment?> readDroppedImageAttachment(
  PromptAttachment attachment,
) async {
  if (attachment.isInline) return attachment;
  throw UnsupportedError('Provide readImage for this platform.');
}

Future<List<PromptAttachment>> pickPlatformAttachments(
  PromptAttachmentKind kind,
) async {
  final result = await FilePicker.platform.pickFiles(
    type: switch (kind) {
      PromptAttachmentKind.file => FileType.any,
      PromptAttachmentKind.image => FileType.image,
      PromptAttachmentKind.audio => FileType.audio,
    },
    allowMultiple: true,
    withData: true,
  );
  return [
    for (final file in result?.files ?? <PlatformFile>[])
      if (file.bytes != null)
        PromptAttachment.fromBytes(
          bytes: file.bytes!,
          name: file.name,
          mimeType:
              PromptAttachment.fromPath(path: file.name).mimeType ??
              'application/octet-stream',
        ),
  ];
}

String platformWorkingDirectory() => '';
