import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/painting.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import '../models/prompt_attachment.dart';
import 'bounded_file_snapshot.dart';

ImageProvider<Object> platformImageForPath(String path) =>
    FileImage(File(path));

Future<PromptAttachment?> readDroppedImageAttachment(
  PromptAttachment attachment,
) async {
  final file = File(attachment.path);
  final Uint8List bytes;
  try {
    bytes = await readBoundedFileSnapshot(file, maxBytes: 4 * 1024 * 1024);
  } on BoundedFileSnapshotOverflowException {
    throw const FileSystemException('Images must be 4 MB or smaller.');
  }
  if (bytes.isEmpty) {
    throw const FileSystemException('Images must be 4 MB or smaller.');
  }
  return PromptAttachment.fromBytes(
    bytes: bytes,
    name: attachment.name,
    mimeType: attachment.imageMimeType ?? 'image/png',
  );
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
    withData: false,
  );
  if (result == null) return const <PromptAttachment>[];
  return result.files
      .where((file) => file.path != null && file.path!.isNotEmpty)
      .map(
        (file) => PromptAttachment.fromPath(
          path: file.path!,
          name: file.name,
          size: file.size,
        ),
      )
      .toList();
}

Future<String> resolvePlatformPath(
  String path, {
  required bool isDirectory,
}) async {
  final normalized = p.normalize(p.absolute(path));
  final exists = isDirectory
      ? Directory(normalized).existsSync()
      : File(normalized).existsSync();
  if (!exists) return normalized;
  try {
    final resolved = isDirectory
        ? await Directory(normalized).resolveSymbolicLinks()
        : await File(normalized).resolveSymbolicLinks();
    return p.normalize(resolved);
  } on FileSystemException {
    // Picker and drop paths normally exist. Keep a lexical fallback for a
    // file that disappears between selection and authorization.
    return normalized;
  }
}

String platformWorkingDirectory() => Directory.current.path;
