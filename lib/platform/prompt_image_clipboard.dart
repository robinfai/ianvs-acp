import 'package:flutter/services.dart';

import '../acp/prompt_attachment.dart';

const MethodChannel _promptImageClipboardChannel = MethodChannel(
  'com.ianvs.acp/prompt_image_clipboard',
);

Future<PromptAttachment?> readPromptImageFromClipboard() async {
  final payload = await _promptImageClipboardChannel
      .invokeMapMethod<String, Object?>('readImage');
  if (payload == null) return null;

  final bytes = payload['bytes'];
  final mimeType = payload['mimeType'];
  final name = payload['name'];
  if (bytes is! Uint8List ||
      mimeType is! String ||
      !mimeType.startsWith('image/') ||
      name is! String ||
      name.trim().isEmpty) {
    throw const FormatException('Clipboard returned invalid image data.');
  }
  return PromptAttachment.fromBytes(
    bytes: bytes,
    name: name.trim(),
    mimeType: mimeType,
  );
}
