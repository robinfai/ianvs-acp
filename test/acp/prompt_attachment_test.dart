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
}
