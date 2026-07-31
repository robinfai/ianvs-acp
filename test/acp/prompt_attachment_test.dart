import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/acp/acp_agent_capabilities.dart';
import 'package:ianvs_acp/acp/prompt_attachment.dart';

void main() {
  test('prompt mode follows advertised media and embedded capabilities', () {
    const text = PromptAttachment(
      path: '/workspace/readme.md',
      name: 'readme.md',
      mimeType: 'text/markdown',
    );
    const image = PromptAttachment(
      path: '/workspace/screenshot.png',
      name: 'screenshot.png',
      mimeType: 'image/png',
    );
    const audio = PromptAttachment(
      path: '/workspace/clip.wav',
      name: 'clip.wav',
      mimeType: 'audio/wav',
    );
    const binary = PromptAttachment(
      path: '/workspace/archive.bin',
      name: 'archive.bin',
      mimeType: 'application/octet-stream',
    );

    const full = AcpPromptCapabilities(
      image: true,
      audio: true,
      embeddedContext: true,
    );
    const linksOnly = AcpPromptCapabilities(
      image: false,
      audio: false,
      embeddedContext: false,
    );

    expect(text.promptMode(full), PromptAttachmentPromptMode.embeddedResource);
    expect(image.promptMode(full), PromptAttachmentPromptMode.image);
    expect(audio.promptMode(full), PromptAttachmentPromptMode.audio);
    expect(
      binary.promptMode(full),
      PromptAttachmentPromptMode.embeddedResource,
    );

    expect(text.promptMode(linksOnly), PromptAttachmentPromptMode.resourceLink);
    expect(
      image.promptMode(linksOnly),
      PromptAttachmentPromptMode.resourceLink,
    );
    expect(
      audio.promptMode(linksOnly),
      PromptAttachmentPromptMode.resourceLink,
    );
    expect(
      binary.promptMode(linksOnly),
      PromptAttachmentPromptMode.resourceLink,
    );
  });

  test('infers media and text kinds from file names', () {
    const dart = PromptAttachment(
      path: '/workspace/lib/main.dart',
      name: 'main.dart',
    );
    const jpg = PromptAttachment(
      path: '/workspace/photo.jpg',
      name: 'photo.jpg',
    );
    const mp3 = PromptAttachment(path: '/workspace/clip.mp3', name: 'clip.mp3');

    expect(dart.isText, isTrue);
    expect(jpg.imageMimeType, 'image/jpeg');
    expect(mp3.audioMimeType, 'audio/mpeg');
  });

  test('builds bounded inline image metadata from clipboard bytes', () {
    final image = PromptAttachment.fromBytes(
      bytes: Uint8List.fromList(<int>[1, 2, 3]),
      name: 'Pasted Image.png',
      mimeType: 'image/png',
    );

    expect(image.path, isEmpty);
    expect(image.size, 3);
    expect(image.data, 'AQID');
    expect(image.isInline, isTrue);
    expect(image.userApprovedOutsideWorkspace, isFalse);
    expect(image.forceResourceLink, isFalse);
    expect(image.toResourceLink(), <String, Object?>{
      'type': 'image',
      'data': 'AQID',
      'mimeType': 'image/png',
      'name': 'Pasted Image.png',
      'size': 3,
    });
  });

  test('preserves one-time outside-workspace approval in path metadata', () {
    final attachment = PromptAttachment.fromPath(
      path: '/outside/workspace/image.png',
      size: 42,
    ).copyWith(userApprovedOutsideWorkspace: true);

    expect(attachment.path, '/outside/workspace/image.png');
    expect(attachment.name, 'image.png');
    expect(attachment.userApprovedOutsideWorkspace, isTrue);
    expect(attachment.forceResourceLink, isFalse);
  });
}
