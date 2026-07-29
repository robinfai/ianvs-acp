import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:path/path.dart' as p;

import '../file_preview/file_preview_document.dart';
import '../theme/app_design_tokens.dart';

const int _maxInlineMarkdownImageBytes = 16 * 1024 * 1024;
const int _maxInlineMarkdownImageUriLength =
    ((_maxInlineMarkdownImageBytes + 2) ~/ 3) * 4 + 1024;

class MarkdownPreviewImage extends StatefulWidget {
  const MarkdownPreviewImage({
    super.key,
    required this.uri,
    required this.workspacePath,
    required this.baseDirectory,
    required this.additionalDirectories,
    this.alt,
  });

  final Uri uri;
  final String workspacePath;
  final String baseDirectory;
  final List<String> additionalDirectories;
  final String? alt;

  @override
  State<MarkdownPreviewImage> createState() => _MarkdownPreviewImageState();
}

class _MarkdownPreviewImageState extends State<MarkdownPreviewImage> {
  Future<FilePreviewTarget>? _localTarget;

  @override
  void initState() {
    super.initState();
    _updateLocalTarget();
  }

  @override
  void didUpdateWidget(covariant MarkdownPreviewImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.uri != widget.uri ||
        oldWidget.workspacePath != widget.workspacePath ||
        oldWidget.baseDirectory != widget.baseDirectory ||
        !_sameStrings(
          oldWidget.additionalDirectories,
          widget.additionalDirectories,
        )) {
      _updateLocalTarget();
    }
  }

  void _updateLocalTarget() {
    final scheme = widget.uri.scheme.toLowerCase();
    _localTarget = scheme.isEmpty || scheme == 'file'
        ? resolveMarkdownImageTarget(
            source: widget.uri.toString(),
            workspacePath: widget.workspacePath,
            baseDirectory: widget.baseDirectory,
            additionalDirectories: widget.additionalDirectories,
          )
        : null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.uri.scheme.toLowerCase();
    if (scheme == 'http' || scheme == 'https') {
      if (widget.uri.host.trim().isEmpty) {
        return _MarkdownImageFailure(alt: widget.alt, message: '图片 URL 缺少主机地址');
      }
      return _frame(
        context,
        _isSvgPath(widget.uri.path)
            ? SvgPicture.network(
                widget.uri.toString(),
                fit: BoxFit.contain,
                placeholderBuilder: (_) => const _MarkdownImageLoading(),
                errorBuilder: (_, error, stackTrace) =>
                    _MarkdownImageFailure(alt: widget.alt),
              )
            : Image.network(
                widget.uri.toString(),
                fit: BoxFit.contain,
                cacheWidth: 1800,
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _MarkdownImageLoading(),
                errorBuilder: (_, error, stackTrace) =>
                    _MarkdownImageFailure(alt: widget.alt),
              ),
      );
    }
    if (scheme == 'data') {
      return _buildDataImage(context);
    }
    if (scheme.isNotEmpty && scheme != 'file') {
      return _MarkdownImageFailure(
        alt: widget.alt,
        message: '不支持 $scheme 图片路径',
      );
    }

    return FutureBuilder<FilePreviewTarget>(
      future: _localTarget,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _MarkdownImageFailure(
            alt: widget.alt,
            message: _safeLocalError(snapshot.error!),
          );
        }
        final target = snapshot.data;
        if (target == null) return const _MarkdownImageLoading();
        final path = target.path;
        return _frame(
          context,
          _isSvgPath(path)
              ? SvgPicture.file(
                  File(path),
                  fit: BoxFit.contain,
                  placeholderBuilder: (_) => const _MarkdownImageLoading(),
                  errorBuilder: (_, error, stackTrace) =>
                      _MarkdownImageFailure(alt: widget.alt),
                )
              : Image.file(
                  File(path),
                  fit: BoxFit.contain,
                  cacheWidth: 1800,
                  errorBuilder: (_, error, stackTrace) =>
                      _MarkdownImageFailure(alt: widget.alt),
                ),
        );
      },
    );
  }

  Widget _buildDataImage(BuildContext context) {
    final source = widget.uri.toString();
    if (source.length > _maxInlineMarkdownImageUriLength) {
      return _MarkdownImageFailure(alt: widget.alt, message: '内嵌图片超过 16 MB 限制');
    }
    try {
      final data = widget.uri.data;
      final mimeType = data?.mimeType.toLowerCase() ?? '';
      if (data == null || !mimeType.startsWith('image/')) {
        return _MarkdownImageFailure(alt: widget.alt, message: 'data URI 不是图片');
      }
      final bytes = data.contentAsBytes();
      if (bytes.length > _maxInlineMarkdownImageBytes) {
        return _MarkdownImageFailure(
          alt: widget.alt,
          message: '内嵌图片超过 16 MB 限制',
        );
      }
      return _frame(
        context,
        mimeType == 'image/svg+xml'
            ? SvgPicture.memory(
                bytes,
                fit: BoxFit.contain,
                placeholderBuilder: (_) => const _MarkdownImageLoading(),
                errorBuilder: (_, error, stackTrace) =>
                    _MarkdownImageFailure(alt: widget.alt),
              )
            : Image.memory(
                Uint8List.fromList(bytes),
                fit: BoxFit.contain,
                cacheWidth: 1800,
                errorBuilder: (_, error, stackTrace) =>
                    _MarkdownImageFailure(alt: widget.alt),
              ),
      );
    } on FormatException {
      return _MarkdownImageFailure(alt: widget.alt, message: 'data URI 格式无效');
    }
  }

  Widget _frame(BuildContext context, Widget child) {
    return Semantics(
      label: widget.alt?.trim(),
      image: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 920, maxHeight: 560),
        margin: const EdgeInsets.symmetric(vertical: 8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.sm),
          child: child,
        ),
      ),
    );
  }
}

class _MarkdownImageLoading extends StatelessWidget {
  const _MarkdownImageLoading();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 96,
      child: Center(
        child: SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _MarkdownImageFailure extends StatelessWidget {
  const _MarkdownImageFailure({this.alt, this.message = '图片加载失败'});

  final String? alt;
  final String message;

  @override
  Widget build(BuildContext context) {
    final description = alt?.trim();
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          const Icon(Icons.broken_image_outlined, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              [
                message,
                if (description != null && description.isNotEmpty) description,
              ].join(' · '),
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

bool _isSvgPath(String path) => p.extension(path).toLowerCase() == '.svg';

bool _sameStrings(List<String> left, List<String> right) {
  if (identical(left, right)) return true;
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _safeLocalError(Object error) {
  if (error is FileSystemException) {
    if (error.message.contains('不在当前工作区')) {
      return '图片不在当前工作区或已授权目录中';
    }
    if (error.message.contains('不存在')) return '图片文件不存在';
  }
  if (error is FormatException) return error.message;
  return '图片加载失败';
}
