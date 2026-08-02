import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/objectivec.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/plaintext.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github.dart';

import '../../mermaid/mermaid_view.dart';
import '../theme/app_design_tokens.dart';
import 'scroll_fade_region.dart';

const int markdownCodeHighlightCharacterLimit = 200 * 1024;
const int markdownCodeHighlightLineLimit = 2000;
const double _collapsedCodeHeight = 320;
const int _longCodeLineThreshold = 24;
const int _longCodeCharacterThreshold = 2400;

class MarkdownCodeBlockBuilder extends MarkdownElementBuilder {
  MarkdownCodeBlockBuilder({required this.user});

  final bool user;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = _codeChild(element);
    if (code == null) return null;
    final source = _stripMarkdownTerminalNewline(code.textContent);
    final language = markdownCodeLanguage(code);

    if (language == 'mermaid' && source.trim().isNotEmpty) {
      return MarkdownMermaidBlock(source: source, user: user);
    }
    return MarkdownCodeBlock(source: source, language: language, user: user);
  }
}

class MarkdownCodeBlock extends StatefulWidget {
  const MarkdownCodeBlock({
    super.key,
    required this.source,
    required this.language,
    required this.user,
  });

  final String source;
  final String? language;
  final bool user;

  @override
  State<MarkdownCodeBlock> createState() => _MarkdownCodeBlockState();
}

class _MarkdownCodeBlockState extends State<MarkdownCodeBlock> {
  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();
  Timer? _copiedTimer;
  var _wrap = false;
  var _expanded = false;
  var _copied = false;

  int get _lineCount => markdownCodeLineCount(widget.source);

  bool get _isLong =>
      _lineCount > _longCodeLineThreshold ||
      widget.source.length > _longCodeCharacterThreshold;

  @override
  void didUpdateWidget(covariant MarkdownCodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _expanded = false;
      _copied = false;
      _copiedTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _copiedTimer?.cancel();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final baseStyle = const TextStyle(
      color: Color(0xff24292e),
      fontFamily: 'SF Mono',
      fontFamilyFallback: <String>['Menlo', 'Monaco', 'monospace'],
      fontSize: 12.5,
      height: 1.5,
    );
    final highlightSkipped =
        widget.language != null &&
        widget.language != 'plaintext' &&
        !markdownCodeCanHighlight(widget.source);
    final span = markdownHighlightedCodeSpan(
      widget.source,
      language: widget.language,
      baseStyle: baseStyle,
    );

    Widget body = LayoutBuilder(
      builder: (context, constraints) {
        final code = SelectableText.rich(
          span,
          style: baseStyle,
          textWidthBasis: TextWidthBasis.longestLine,
        );
        if (_wrap) {
          return SizedBox(width: constraints.maxWidth, child: code);
        }
        return Scrollbar(
          controller: _horizontalController,
          thumbVisibility: false,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: code,
            ),
          ),
        );
      },
    );
    body = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      child: body,
    );
    if (_isLong && !_expanded) {
      body = ScrollFadeRegion(
        key: const ValueKey('code-block-scroll-region'),
        controller: _verticalController,
        maxHeight: _collapsedCodeHeight,
        backgroundColor: const Color(0xfffbfbfd),
        showScrollbar: true,
        child: body,
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xfffbfbfd),
        border: Border.all(
          color: widget.user
              ? Colors.white.withValues(alpha: 0.34)
              : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: widget.user ? null : AppShadows.soft,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CodeBlockToolbar(
            language: markdownCodeLanguageLabel(widget.language),
            highlightSkipped: highlightSkipped,
            wrap: _wrap,
            copied: _copied,
            isLong: _isLong,
            expanded: _expanded,
            onToggleWrap: () => setState(() => _wrap = !_wrap),
            onToggleExpanded: () => setState(() => _expanded = !_expanded),
            onCopy: _copy,
          ),
          const Divider(height: 1, color: AppColors.borderSoft),
          body,
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.source));
    if (!mounted) return;
    _copiedTimer?.cancel();
    setState(() => _copied = true);
    _copiedTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }
}

class MarkdownMermaidBlock extends StatelessWidget {
  const MarkdownMermaidBlock({
    super.key,
    required this.source,
    required this.user,
  });

  final String source;
  final bool user;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 2),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(
          color: user ? Colors.white.withValues(alpha: 0.34) : AppColors.border,
        ),
        borderRadius: BorderRadius.circular(AppRadius.md),
        boxShadow: user ? null : AppShadows.soft,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _MermaidToolbar(source: source),
          const Divider(height: 1, color: AppColors.borderSoft),
          SizedBox(
            height: 320,
            child: MermaidView(
              source: source,
              semanticsLabel: 'Mermaid diagram',
              loadingBuilder: (_) => const Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              errorBuilder: (context, error) => Padding(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  'Mermaid render failed:\n$error',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlockToolbar extends StatelessWidget {
  const _CodeBlockToolbar({
    required this.language,
    required this.highlightSkipped,
    required this.wrap,
    required this.copied,
    required this.isLong,
    required this.expanded,
    required this.onToggleWrap,
    required this.onToggleExpanded,
    required this.onCopy,
  });

  final String language;
  final bool highlightSkipped;
  final bool wrap;
  final bool copied;
  final bool isLong;
  final bool expanded;
  final VoidCallback onToggleWrap;
  final VoidCallback onToggleExpanded;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.only(left: 12, right: 4),
      color: const Color(0xfff5f6fa),
      child: Row(
        children: [
          const Icon(
            Icons.code_rounded,
            size: 15,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 7),
          Text(
            language,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: .45,
            ),
          ),
          if (highlightSkipped) ...[
            const SizedBox(width: 8),
            const Tooltip(
              message: '代码过大，已回退为纯文本以保持预览流畅',
              child: Icon(
                Icons.speed_rounded,
                size: 14,
                color: AppColors.textTertiary,
              ),
            ),
          ],
          const Spacer(),
          if (isLong)
            TextButton.icon(
              onPressed: onToggleExpanded,
              style: TextButton.styleFrom(
                foregroundColor: AppColors.textSecondary,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 7),
                textStyle: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: Icon(
                expanded
                    ? Icons.unfold_less_rounded
                    : Icons.unfold_more_rounded,
                size: 15,
              ),
              label: Text(expanded ? '收起' : '展开'),
            ),
          _CodeToolbarButton(
            tooltip: wrap ? '关闭自动换行' : '自动换行',
            icon: Icons.wrap_text_rounded,
            selected: wrap,
            onPressed: onToggleWrap,
          ),
          _CodeToolbarButton(
            tooltip: copied ? '已复制' : '复制代码',
            icon: copied ? Icons.check_rounded : Icons.content_copy_rounded,
            selected: copied,
            onPressed: onCopy,
          ),
        ],
      ),
    );
  }
}

class _MermaidToolbar extends StatefulWidget {
  const _MermaidToolbar({required this.source});

  final String source;

  @override
  State<_MermaidToolbar> createState() => _MermaidToolbarState();
}

class _MermaidToolbarState extends State<_MermaidToolbar> {
  Timer? _timer;
  var _copied = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.only(left: 12, right: 4),
      color: const Color(0xfff5f6fa),
      child: Row(
        children: [
          const Icon(
            Icons.account_tree_outlined,
            size: 15,
            color: AppColors.textTertiary,
          ),
          const SizedBox(width: 7),
          const Text(
            'MERMAID',
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: .45,
            ),
          ),
          const Spacer(),
          _CodeToolbarButton(
            tooltip: _copied ? '已复制' : '复制源码',
            icon: _copied ? Icons.check_rounded : Icons.content_copy_rounded,
            selected: _copied,
            onPressed: _copy,
          ),
        ],
      ),
    );
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.source));
    if (!mounted) return;
    _timer?.cancel();
    setState(() => _copied = true);
    _timer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }
}

class _CodeToolbarButton extends StatelessWidget {
  const _CodeToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.selected,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      color: selected ? AppColors.primaryDark : AppColors.textSecondary,
      style: selected
          ? IconButton.styleFrom(backgroundColor: AppColors.primarySoft)
          : null,
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }
}

String? markdownCodeLanguage(md.Element code) {
  final className = code.attributes['class'] ?? '';
  for (final part in className.split(RegExp(r'\s+'))) {
    final normalizedPart = part.trim().toLowerCase();
    if (normalizedPart.startsWith('language-')) {
      return normalizeMarkdownCodeLanguage(
        normalizedPart.substring('language-'.length),
      );
    }
    if (normalizedPart.startsWith('lang-')) {
      return normalizeMarkdownCodeLanguage(
        normalizedPart.substring('lang-'.length),
      );
    }
  }
  return null;
}

String? normalizeMarkdownCodeLanguage(String? language) {
  final value = language?.trim().toLowerCase();
  if (value == null || value.isEmpty) return null;
  return _languageAliases[value] ?? value;
}

String markdownCodeLanguageLabel(String? language) {
  final normalized = normalizeMarkdownCodeLanguage(language);
  return _languageLabels[normalized] ?? normalized?.toUpperCase() ?? 'TEXT';
}

int markdownCodeLineCount(String source) {
  if (source.isEmpty) return 1;
  var lines = 1;
  for (var index = 0; index < source.length; index += 1) {
    if (source.codeUnitAt(index) == 0x0a) lines += 1;
  }
  return lines;
}

bool markdownCodeCanHighlight(String source) =>
    source.length <= markdownCodeHighlightCharacterLimit &&
    markdownCodeLineCount(source) <= markdownCodeHighlightLineLimit;

TextSpan markdownHighlightedCodeSpan(
  String source, {
  required String? language,
  required TextStyle baseStyle,
}) {
  final normalized = normalizeMarkdownCodeLanguage(language);
  if (normalized == null ||
      normalized == 'plaintext' ||
      !markdownCodeCanHighlight(source) ||
      _codeHighlighter.getLanguage(normalized) == null) {
    return TextSpan(text: source, style: baseStyle);
  }

  final key = _HighlightCacheKey(language: normalized, source: source);
  var result = _highlightCache.get(key);
  if (result == null) {
    try {
      result = _codeHighlighter.highlight(code: source, language: normalized);
      _highlightCache.put(key, result);
    } on Object {
      return TextSpan(text: source, style: baseStyle);
    }
  }
  final renderer = TextSpanRenderer(baseStyle, githubTheme);
  result.render(renderer);
  return renderer.span ?? TextSpan(text: source, style: baseStyle);
}

md.Element? _codeChild(md.Element element) {
  for (final child in element.children ?? const <md.Node>[]) {
    if (child is md.Element && child.tag == 'code') return child;
  }
  return null;
}

String _stripMarkdownTerminalNewline(String source) {
  if (source.endsWith('\r\n')) {
    return source.substring(0, source.length - 2);
  }
  if (source.endsWith('\n')) return source.substring(0, source.length - 1);
  return source;
}

final Highlight _codeHighlighter = _createCodeHighlighter();
final _HighlightCache _highlightCache = _HighlightCache();

Highlight _createCodeHighlighter() {
  return Highlight()..registerLanguages(<String, Mode>{
    'bash': langBash,
    'c': langC,
    'cpp': langCpp,
    'csharp': langCsharp,
    'css': langCss,
    'dart': langDart,
    'diff': langDiff,
    'dockerfile': langDockerfile,
    'go': langGo,
    'graphql': langGraphql,
    'ini': langIni,
    'java': langJava,
    'javascript': langJavascript,
    'json': langJson,
    'kotlin': langKotlin,
    'markdown': langMarkdown,
    'objectivec': langObjectivec,
    'php': langPhp,
    'plaintext': langPlaintext,
    'powershell': langPowershell,
    'python': langPython,
    'ruby': langRuby,
    'rust': langRust,
    'shell': langShell,
    'sql': langSql,
    'swift': langSwift,
    'typescript': langTypescript,
    'xml': langXml,
    'yaml': langYaml,
  });
}

const Map<String, String> _languageAliases = <String, String>{
  'bsh': 'bash',
  'c++': 'cpp',
  'cc': 'cpp',
  'c#': 'csharp',
  'cs': 'csharp',
  'docker': 'dockerfile',
  'golang': 'go',
  'gql': 'graphql',
  'html': 'xml',
  'js': 'javascript',
  'jsx': 'javascript',
  'kt': 'kotlin',
  'md': 'markdown',
  'objc': 'objectivec',
  'ps1': 'powershell',
  'py': 'python',
  'rb': 'ruby',
  'rs': 'rust',
  'sh': 'bash',
  'shellscript': 'bash',
  'text': 'plaintext',
  'txt': 'plaintext',
  'ts': 'typescript',
  'tsx': 'typescript',
  'yml': 'yaml',
};

const Map<String?, String> _languageLabels = <String?, String>{
  'bash': 'SHELL',
  'cpp': 'C++',
  'csharp': 'C#',
  'dockerfile': 'DOCKERFILE',
  'javascript': 'JAVASCRIPT',
  'objectivec': 'OBJECTIVE-C',
  'plaintext': 'TEXT',
  'powershell': 'POWERSHELL',
  'typescript': 'TYPESCRIPT',
  'xml': 'HTML / XML',
};

final class _HighlightCacheKey {
  _HighlightCacheKey({required this.language, required this.source})
    : _hashCode = Object.hash(language, source);

  final String language;
  final String source;
  final int _hashCode;

  @override
  int get hashCode => _hashCode;

  @override
  bool operator ==(Object other) =>
      other is _HighlightCacheKey &&
      language == other.language &&
      source == other.source;
}

final class _HighlightCache {
  static const int _maximumEntries = 64;
  static const int _maximumSourceCharacters = 1024 * 1024;

  final LinkedHashMap<_HighlightCacheKey, HighlightResult> _entries =
      LinkedHashMap<_HighlightCacheKey, HighlightResult>();
  var _sourceCharacters = 0;

  HighlightResult? get(_HighlightCacheKey key) {
    final value = _entries.remove(key);
    if (value != null) _entries[key] = value;
    return value;
  }

  void put(_HighlightCacheKey key, HighlightResult value) {
    final replaced = _entries.remove(key);
    if (replaced != null) _sourceCharacters -= key.source.length;
    _entries[key] = value;
    _sourceCharacters += key.source.length;
    while (_entries.length > _maximumEntries ||
        _sourceCharacters > _maximumSourceCharacters) {
      final oldest = _entries.keys.first;
      _entries.remove(oldest);
      _sourceCharacters -= oldest.source.length;
    }
  }
}
