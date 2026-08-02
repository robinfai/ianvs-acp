import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../theme/app_design_tokens.dart';

class MarkdownInlineLinkBuilder extends MarkdownElementBuilder {
  MarkdownInlineLinkBuilder({required this.onTapLink});

  final MarkdownTapLinkCallback? onTapLink;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final label = element.textContent.trim();
    if (label.isEmpty) return null;
    return _MarkdownInlineLink(
      label: label,
      href: element.attributes['href'],
      title: element.attributes['title'] ?? '',
      preferredStyle: preferredStyle,
      onTapLink: onTapLink,
    );
  }
}

class _MarkdownInlineLink extends StatefulWidget {
  const _MarkdownInlineLink({
    required this.label,
    required this.href,
    required this.title,
    required this.preferredStyle,
    required this.onTapLink,
  });

  final String label;
  final String? href;
  final String title;
  final TextStyle? preferredStyle;
  final MarkdownTapLinkCallback? onTapLink;

  @override
  State<_MarkdownInlineLink> createState() => _MarkdownInlineLinkState();
}

class _MarkdownInlineLinkState extends State<_MarkdownInlineLink> {
  var _hovered = false;

  bool get _enabled => widget.onTapLink != null;

  @override
  Widget build(BuildContext context) {
    final fileReference = _looksLikeFileReference(widget.href, widget.label);
    final link = fileReference ? _fileReference() : _ordinaryLink();
    final href = widget.href?.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1),
      child: Tooltip(
        message: widget.title.trim().isNotEmpty
            ? widget.title
            : href?.isNotEmpty == true
            ? href!
            : widget.label,
        child: Semantics(
          link: true,
          enabled: _enabled,
          label: widget.label,
          child: MouseRegion(
            cursor: _enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(fileReference ? 6 : 3),
                onTap: _enabled
                    ? () => widget.onTapLink!(
                        widget.label,
                        widget.href,
                        widget.title,
                      )
                    : null,
                child: link,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _fileReference() {
    return AnimatedContainer(
      key: const ValueKey('markdown-file-reference'),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(5, 2, 7, 2),
      decoration: BoxDecoration(
        color: _hovered ? AppColors.surfaceHover : AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: _hovered ? AppColors.border : AppColors.borderSoft,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.description_outlined,
            size: 13,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 4),
          Text(
            widget.label,
            style: widget.preferredStyle?.copyWith(
              color: AppColors.textPrimary,
              backgroundColor: Colors.transparent,
              decoration: TextDecoration.none,
              fontSize: 12.5,
              height: 1.25,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ordinaryLink() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
      padding: const EdgeInsets.symmetric(horizontal: 1),
      decoration: BoxDecoration(
        color: _hovered ? AppColors.primaryMist : Colors.transparent,
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        widget.label,
        style: widget.preferredStyle?.copyWith(
          color: AppColors.textPrimary,
          backgroundColor: Colors.transparent,
          decoration: TextDecoration.underline,
          decorationColor: AppColors.textTertiary,
          decorationThickness: 1,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

bool _looksLikeFileReference(String? href, String label) {
  final source = href?.trim();
  if (source == null || source.isEmpty) return false;
  final uri = Uri.tryParse(source);
  final scheme = uri?.scheme.toLowerCase() ?? '';
  if (scheme == 'http' ||
      scheme == 'https' ||
      scheme == 'mailto' ||
      scheme == 'tel') {
    return false;
  }
  if (scheme == 'file') return true;

  final path = (uri?.path.isNotEmpty == true ? uri!.path : source)
      .split('#')
      .first
      .split('?')
      .first;
  if (path.startsWith('/') || path.contains('/')) return true;
  return RegExp(r'\.[A-Za-z0-9]{1,10}$').hasMatch(path) ||
      RegExp(r'\.[A-Za-z0-9]{1,10}$').hasMatch(label.trim());
}
