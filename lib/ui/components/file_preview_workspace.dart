import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:path/path.dart' as p;

import '../../platform/file_manager.dart';
import '../file_preview/file_preview_document.dart';
import '../file_preview/markdown_front_matter.dart';
import '../theme/app_design_tokens.dart';
import 'markdown_code_block.dart';
import 'markdown_front_matter_card.dart';
import 'markdown_preview_image.dart';

typedef FilePreviewLinkHandler =
    void Function(String text, String? href, String title);
typedef FilePreviewConversationBuilder =
    Widget Function(BuildContext context, FilePreviewLinkHandler onTapLink);

class FilePreviewWorkspace extends StatefulWidget {
  const FilePreviewWorkspace({
    super.key,
    required this.workspacePath,
    required this.additionalDirectories,
    required this.conversationBuilder,
    required this.inspector,
    required this.showInspector,
    this.processRunner,
  });

  final String workspacePath;
  final List<String> additionalDirectories;
  final FilePreviewConversationBuilder conversationBuilder;
  final Widget inspector;
  final bool showInspector;
  final FilePreviewProcessRunner? processRunner;

  @override
  State<FilePreviewWorkspace> createState() => _FilePreviewWorkspaceState();
}

class _FilePreviewWorkspaceState extends State<FilePreviewWorkspace> {
  static const _maximumTabs = 6;

  final List<_FilePreviewTab> _tabs = <_FilePreviewTab>[];
  int _activeTab = -1;
  double? _previewWidth;

  @override
  void didUpdateWidget(covariant FilePreviewWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workspacePath != widget.workspacePath) {
      _tabs.clear();
      _activeTab = -1;
      _previewWidth = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversation = widget.conversationBuilder(
      context,
      (text, href, title) => unawaited(
        _openLink(text, href, title, baseDirectory: widget.workspacePath),
      ),
    );
    if (_activeTab < 0 || _tabs.isEmpty) {
      return Row(
        children: [
          Expanded(child: conversation),
          if (widget.showInspector) ...[
            const VerticalDivider(width: 1, color: AppColors.border),
            SizedBox(width: 292, child: widget.inspector),
          ],
        ],
      );
    }

    final active = _tabs[_activeTab];
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 820;
        final preview = FilePreviewPane(
          key: ValueKey(active.target.path),
          tabs: _tabs.map((tab) => tab.target).toList(growable: false),
          activeTab: _activeTab,
          document: active.document,
          additionalDirectories: widget.additionalDirectories,
          processRunner: widget.processRunner,
          onSelectTab: (index) => setState(() => _activeTab = index),
          onCloseTab: _closeTab,
          onClosePreview: () => _closeTab(_activeTab),
          onOpenNestedLink: (text, href, title) => unawaited(
            _openLink(
              text,
              href,
              title,
              baseDirectory: active.target.parentPath,
            ),
          ),
        );
        if (compact) return preview;

        final maximumPreviewWidth = constraints.maxWidth - 360;
        final desiredPreviewWidth = _previewWidth ?? constraints.maxWidth * .58;
        final previewWidth = desiredPreviewWidth
            .clamp(480.0, maximumPreviewWidth)
            .toDouble();
        return Row(
          children: [
            Expanded(child: conversation),
            _PreviewResizeHandle(
              onDrag: (delta) {
                setState(() {
                  _previewWidth = (previewWidth - delta)
                      .clamp(480.0, maximumPreviewWidth)
                      .toDouble();
                });
              },
            ),
            SizedBox(width: previewWidth, child: preview),
          ],
        );
      },
    );
  }

  Future<void> _openLink(
    String text,
    String? href,
    String title, {
    required String baseDirectory,
  }) async {
    final value = href?.trim();
    if (value == null || value.isEmpty) return;
    final uri = Uri.tryParse(value);
    if (uri != null &&
        const {'http', 'https', 'mailto'}.contains(uri.scheme.toLowerCase())) {
      try {
        await openUriExternally(uri, processRunner: widget.processRunner);
      } catch (error) {
        if (mounted) _showError('无法打开链接：${_errorText(error)}');
      }
      return;
    }

    try {
      final target = await resolveFilePreviewTarget(
        href: value,
        workspacePath: widget.workspacePath,
        additionalDirectories: widget.additionalDirectories,
        baseDirectory: baseDirectory,
      );
      if (!mounted) return;
      final existingIndex = _tabs.indexWhere(
        (tab) => tab.target.path == target.path,
      );
      setState(() {
        if (existingIndex >= 0) {
          _tabs[existingIndex] = _FilePreviewTab(
            target: target,
            document: loadFilePreviewDocument(
              target,
              processRunner: widget.processRunner,
            ),
          );
          _activeTab = existingIndex;
          return;
        }
        if (_tabs.length == _maximumTabs) {
          _tabs.removeAt(0);
          _activeTab -= 1;
        }
        _tabs.add(
          _FilePreviewTab(
            target: target,
            document: loadFilePreviewDocument(
              target,
              processRunner: widget.processRunner,
            ),
          ),
        );
        _activeTab = _tabs.length - 1;
      });
    } catch (error) {
      if (mounted) _showError(_errorText(error));
    }
  }

  void _closeTab(int index) {
    if (index < 0 || index >= _tabs.length) return;
    setState(() {
      _tabs.removeAt(index);
      if (_tabs.isEmpty) {
        _activeTab = -1;
      } else if (_activeTab >= _tabs.length) {
        _activeTab = _tabs.length - 1;
      } else if (index < _activeTab) {
        _activeTab -= 1;
      }
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }
}

final class _FilePreviewTab {
  const _FilePreviewTab({required this.target, required this.document});

  final FilePreviewTarget target;
  final Future<FilePreviewDocument> document;
}

class FilePreviewPane extends StatefulWidget {
  const FilePreviewPane({
    super.key,
    required this.tabs,
    required this.activeTab,
    required this.document,
    required this.additionalDirectories,
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onClosePreview,
    required this.onOpenNestedLink,
    this.processRunner,
  });

  final List<FilePreviewTarget> tabs;
  final int activeTab;
  final Future<FilePreviewDocument> document;
  final List<String> additionalDirectories;
  final ValueChanged<int> onSelectTab;
  final ValueChanged<int> onCloseTab;
  final VoidCallback onClosePreview;
  final FilePreviewLinkHandler onOpenNestedLink;
  final FilePreviewProcessRunner? processRunner;

  @override
  State<FilePreviewPane> createState() => _FilePreviewPaneState();
}

class _FilePreviewPaneState extends State<FilePreviewPane> {
  final TextEditingController _searchController = TextEditingController();
  var _showSearch = false;
  var _showMarkdownSource = false;
  var _wrapText = true;

  FilePreviewTarget get _target => widget.tabs[widget.activeTab];

  @override
  void didUpdateWidget(covariant FilePreviewPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPath = oldWidget.tabs[oldWidget.activeTab].path;
    if (oldPath != _target.path) {
      _searchController.clear();
      _showSearch = false;
      _showMarkdownSource = false;
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey('file-preview-pane'),
      color: AppColors.surfaceRaised,
      child: Column(
        children: [
          _PreviewTabs(
            tabs: widget.tabs,
            activeTab: widget.activeTab,
            onSelect: widget.onSelectTab,
            onClose: widget.onCloseTab,
          ),
          const Divider(height: 1, color: AppColors.border),
          _FileBreadcrumb(target: _target),
          const Divider(height: 1, color: AppColors.border),
          _PreviewToolbar(
            showSearch: _showSearch,
            searchController: _searchController,
            wrapText: _wrapText,
            onSearchChanged: () => setState(() {}),
            onToggleSearch: () => setState(() => _showSearch = !_showSearch),
            onToggleWrap: () => setState(() => _wrapText = !_wrapText),
            onCopyPath: _copyPath,
            onReveal: _reveal,
            onOpenExternal: _openExternal,
            onClose: widget.onClosePreview,
          ),
          const Divider(height: 1, color: AppColors.border),
          Expanded(
            child: FutureBuilder<FilePreviewDocument>(
              future: widget.document,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return _PreviewFailure(
                    icon: Icons.error_outline_rounded,
                    title: '无法读取文件',
                    message: _errorText(snapshot.error!),
                    onOpenExternal: _openExternal,
                  );
                }
                final document = snapshot.data;
                if (document == null) {
                  return const _PreviewLoading();
                }
                return Column(
                  children: [
                    if (document.textTruncated)
                      const _PreviewNotice(text: '文件较大，当前仅加载前 4 MB 内容。'),
                    if (document.kind == FilePreviewKind.markdown)
                      _MarkdownModeToggle(
                        showSource: _showMarkdownSource,
                        onChanged: (value) =>
                            setState(() => _showMarkdownSource = value),
                      ),
                    Expanded(
                      child: _PreviewBody(
                        document: document,
                        searchQuery: _searchController.text,
                        showMarkdownSource: _showMarkdownSource,
                        wrapText: _wrapText,
                        additionalDirectories: widget.additionalDirectories,
                        onTapLink: widget.onOpenNestedLink,
                        onOpenExternal: _openExternal,
                      ),
                    ),
                    _PreviewStatus(document: document),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: _target.path));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('文件路径已复制。'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _reveal() async {
    await _runFileAction(
      () => revealPathInFileManager(
        _target.path,
        processRunner: widget.processRunner,
      ),
      failure: '无法在文件管理器中显示文件',
    );
  }

  Future<void> _openExternal() async {
    await _runFileAction(
      () =>
          openPathExternally(_target.path, processRunner: widget.processRunner),
      failure: '无法用其他应用打开文件',
    );
  }

  Future<void> _runFileAction(
    Future<void> Function() action, {
    required String failure,
  }) async {
    try {
      await action();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$failure：${_errorText(error)}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

class _PreviewResizeHandle extends StatelessWidget {
  const _PreviewResizeHandle({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        key: const ValueKey('file-preview-resize-handle'),
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (details) => onDrag(details.delta.dx),
        child: Container(
          width: 7,
          color: AppColors.surface,
          alignment: Alignment.center,
          child: Container(width: 1, color: AppColors.border),
        ),
      ),
    );
  }
}

class _PreviewTabs extends StatelessWidget {
  const _PreviewTabs({
    required this.tabs,
    required this.activeTab,
    required this.onSelect,
    required this.onClose,
  });

  final List<FilePreviewTarget> tabs;
  final int activeTab;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs.length,
              itemBuilder: (context, index) {
                final selected = index == activeTab;
                final tab = tabs[index];
                return InkWell(
                  key: ValueKey('file-preview-tab-${tab.path}'),
                  onTap: () => onSelect(index),
                  child: Container(
                    constraints: const BoxConstraints(
                      minWidth: 150,
                      maxWidth: 230,
                    ),
                    padding: const EdgeInsets.only(left: 13),
                    decoration: BoxDecoration(
                      color: selected
                          ? AppColors.surface
                          : AppColors.surfaceRaised,
                      border: Border(
                        bottom: BorderSide(
                          color: selected
                              ? AppColors.primary
                              : Colors.transparent,
                          width: 2,
                        ),
                        right: const BorderSide(color: AppColors.borderSoft),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _iconForPath(tab.path),
                          size: 16,
                          color: selected
                              ? AppColors.primary
                              : AppColors.textTertiary,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            tab.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.primaryDark
                                  : AppColors.textSecondary,
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w800
                                  : FontWeight.w600,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '关闭 ${tab.name}',
                          onPressed: () => onClose(index),
                          icon: const Icon(Icons.close_rounded, size: 15),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 10),
            child: Icon(
              Icons.more_vert_rounded,
              size: 18,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileBreadcrumb extends StatelessWidget {
  const _FileBreadcrumb({required this.target});

  final FilePreviewTarget target;

  @override
  Widget build(BuildContext context) {
    final relative = target.displayPath;
    final segments = p.split(relative);
    return SizedBox(
      height: 48,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Container(
              width: 27,
              height: 27,
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Icon(
                _iconForPath(target.path),
                size: 16,
                color: AppColors.primaryDark,
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    for (var index = 0; index < segments.length; index++) ...[
                      TextSpan(
                        text: segments[index],
                        style: TextStyle(
                          color: index == segments.length - 1
                              ? AppColors.textPrimary
                              : AppColors.textSecondary,
                          fontWeight: index == segments.length - 1
                              ? FontWeight.w800
                              : FontWeight.w500,
                        ),
                      ),
                      if (index != segments.length - 1)
                        const TextSpan(
                          text: '  /  ',
                          style: TextStyle(color: AppColors.textTertiary),
                        ),
                    ],
                  ],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewToolbar extends StatelessWidget {
  const _PreviewToolbar({
    required this.showSearch,
    required this.searchController,
    required this.wrapText,
    required this.onSearchChanged,
    required this.onToggleSearch,
    required this.onToggleWrap,
    required this.onCopyPath,
    required this.onReveal,
    required this.onOpenExternal,
    required this.onClose,
  });

  final bool showSearch;
  final TextEditingController searchController;
  final bool wrapText;
  final VoidCallback onSearchChanged;
  final VoidCallback onToggleSearch;
  final VoidCallback onToggleWrap;
  final VoidCallback onCopyPath;
  final VoidCallback onReveal;
  final VoidCallback onOpenExternal;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 52),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      color: AppColors.surface,
      child: Row(
        children: [
          _ToolbarButton(
            tooltip: showSearch ? '关闭搜索' : '在文件中搜索',
            icon: showSearch ? Icons.search_off_rounded : Icons.search_rounded,
            onPressed: onToggleSearch,
          ),
          if (showSearch)
            SizedBox(
              width: 150,
              height: 34,
              child: TextField(
                key: const ValueKey('file-preview-search-field'),
                controller: searchController,
                autofocus: true,
                onChanged: (_) => onSearchChanged(),
                decoration: InputDecoration(
                  hintText: '搜索',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  suffixIcon: searchController.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: '清空',
                          onPressed: () {
                            searchController.clear();
                            onSearchChanged();
                          },
                          icon: const Icon(Icons.close_rounded, size: 15),
                        ),
                ),
              ),
            ),
          _ToolbarButton(
            tooltip: wrapText ? '关闭自动换行' : '自动换行',
            icon: Icons.wrap_text_rounded,
            selected: wrapText,
            onPressed: onToggleWrap,
          ),
          _ToolbarButton(
            tooltip: '复制路径',
            icon: Icons.copy_rounded,
            onPressed: onCopyPath,
          ),
          _ToolbarButton(
            tooltip: '在 Finder 中显示',
            icon: Icons.folder_open_rounded,
            onPressed: onReveal,
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onOpenExternal,
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('用其他应用打开'),
              ),
            ),
          ),
          _ToolbarButton(
            tooltip: '关闭预览',
            icon: Icons.close_rounded,
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatelessWidget {
  const _ToolbarButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: selected ? AppColors.primaryDark : AppColors.textSecondary,
      style: selected
          ? IconButton.styleFrom(backgroundColor: AppColors.primarySoft)
          : null,
      icon: Icon(icon, size: 18),
      visualDensity: VisualDensity.compact,
    );
  }
}

class _MarkdownModeToggle extends StatelessWidget {
  const _MarkdownModeToggle({
    required this.showSource,
    required this.onChanged,
  });

  final bool showSource;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 2),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('预览')),
            ButtonSegment(value: true, label: Text('源码')),
          ],
          selected: <bool>{showSource},
          onSelectionChanged: (value) => onChanged(value.single),
          showSelectedIcon: false,
          style: const ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle: WidgetStatePropertyAll(
              TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewBody extends StatelessWidget {
  const _PreviewBody({
    required this.document,
    required this.searchQuery,
    required this.showMarkdownSource,
    required this.wrapText,
    required this.additionalDirectories,
    required this.onTapLink,
    required this.onOpenExternal,
  });

  final FilePreviewDocument document;
  final String searchQuery;
  final bool showMarkdownSource;
  final bool wrapText;
  final List<String> additionalDirectories;
  final FilePreviewLinkHandler onTapLink;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    switch (document.kind) {
      case FilePreviewKind.markdown:
        if (showMarkdownSource) {
          return _TextFilePreview(
            text: document.text ?? '',
            selectedLine: document.target.line,
            searchQuery: searchQuery,
            wrapText: wrapText,
          );
        }
        return _MarkdownFilePreview(
          text: document.text ?? '',
          documentPath: document.target.path,
          workspacePath: document.target.workspacePath,
          additionalDirectories: additionalDirectories,
          onTapLink: onTapLink,
        );
      case FilePreviewKind.text:
        return _TextFilePreview(
          text: document.text ?? '',
          selectedLine: document.target.line,
          searchQuery: searchQuery,
          wrapText: wrapText,
        );
      case FilePreviewKind.image:
        return _ImageFilePreview(path: document.target.path);
      case FilePreviewKind.quickLook:
        final bytes = document.previewBytes;
        if (bytes != null) {
          return Container(
            color: const Color(0xffeef0f5),
            padding: const EdgeInsets.all(20),
            alignment: Alignment.center,
            child: InteractiveViewer(
              minScale: .5,
              maxScale: 4,
              child: Image.memory(bytes, fit: BoxFit.contain),
            ),
          );
        }
        return _PreviewFailure(
          icon: _iconForPath(document.target.path),
          title: '暂时无法生成预览',
          message: document.previewError ?? '可用其他应用打开此文件。',
          onOpenExternal: onOpenExternal,
        );
      case FilePreviewKind.unsupported:
        return _PreviewFailure(
          icon: Icons.insert_drive_file_outlined,
          title: '此文件类型不支持内嵌预览',
          message: '文件保持只读，你仍可以在 Finder 中定位或用其他应用打开。',
          onOpenExternal: onOpenExternal,
        );
    }
  }
}

class _MarkdownFilePreview extends StatefulWidget {
  const _MarkdownFilePreview({
    required this.text,
    required this.documentPath,
    required this.workspacePath,
    required this.additionalDirectories,
    required this.onTapLink,
  });

  final String text;
  final String documentPath;
  final String workspacePath;
  final List<String> additionalDirectories;
  final FilePreviewLinkHandler onTapLink;

  @override
  State<_MarkdownFilePreview> createState() => _MarkdownFilePreviewState();
}

class _MarkdownFilePreviewState extends State<_MarkdownFilePreview> {
  final ScrollController _scrollController = ScrollController();
  late MarkdownFrontMatterDocument _document = parseMarkdownFrontMatter(
    widget.text,
  );
  late List<_MarkdownHeading> _headings = _markdownHeadings(_document.body);
  var _outlineCollapsed = false;
  int? _activeHeadingIndex;

  @override
  void didUpdateWidget(covariant _MarkdownFilePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text == widget.text &&
        oldWidget.documentPath == widget.documentPath) {
      return;
    }
    _document = parseMarkdownFrontMatter(widget.text);
    _headings = _markdownHeadings(_document.body);
    _activeHeadingIndex = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final headingBuilder = _MarkdownHeadingBuilder(_headings);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showOutline = constraints.maxWidth >= 560 && _headings.isNotEmpty;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showOutline) ...[
              SizedBox(
                width: _outlineCollapsed ? 44 : 180,
                child: _MarkdownOutline(
                  headings: _headings,
                  collapsed: _outlineCollapsed,
                  activeHeadingIndex: _activeHeadingIndex,
                  onToggle: () =>
                      setState(() => _outlineCollapsed = !_outlineCollapsed),
                  onSelect: _scrollToHeading,
                ),
              ),
              const VerticalDivider(width: 1, color: AppColors.border),
            ],
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('markdown-preview-scroll'),
                controller: _scrollController,
                padding: const EdgeInsets.fromLTRB(28, 24, 32, 44),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_document.entries.isNotEmpty) ...[
                      MarkdownFrontMatterCard(entries: _document.entries),
                      const SizedBox(height: 18),
                    ],
                    MarkdownBody(
                      data: _document.body,
                      selectable: true,
                      onTapLink: widget.onTapLink,
                      imageBuilder: (uri, title, alt) => MarkdownPreviewImage(
                        uri: uri,
                        alt: alt,
                        workspacePath: widget.workspacePath,
                        baseDirectory: p.dirname(widget.documentPath),
                        additionalDirectories: widget.additionalDirectories,
                      ),
                      builders: <String, MarkdownElementBuilder>{
                        'pre': MarkdownCodeBlockBuilder(user: false),
                        'h1': headingBuilder,
                        'h2': headingBuilder,
                        'h3': headingBuilder,
                        'h4': headingBuilder,
                      },
                      styleSheet:
                          MarkdownStyleSheet.fromTheme(
                            Theme.of(context),
                          ).copyWith(
                            h1: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 26,
                              height: 1.22,
                              fontWeight: FontWeight.w900,
                            ),
                            h2: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 19,
                              height: 1.3,
                              fontWeight: FontWeight.w800,
                            ),
                            h3: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 15,
                              height: 1.35,
                              fontWeight: FontWeight.w800,
                            ),
                            p: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 14,
                              height: 1.65,
                            ),
                            a: const TextStyle(
                              color: AppColors.primaryDark,
                              decoration: TextDecoration.underline,
                              decorationColor: AppColors.primary,
                              fontWeight: FontWeight.w700,
                            ),
                            code: const TextStyle(
                              color: AppColors.primaryDark,
                              backgroundColor: AppColors.primaryMist,
                              fontFamily: 'monospace',
                              fontSize: 12,
                            ),
                            tableBorder: TableBorder.all(
                              color: AppColors.border,
                            ),
                            tableHead: const TextStyle(
                              fontWeight: FontWeight.w800,
                            ),
                            tableCellsPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            blockSpacing: 12,
                          ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _scrollToHeading(int index) async {
    if (index < 0 || index >= _headings.length) return;
    final headingContext = _headings[index].key.currentContext;
    if (headingContext == null) return;
    setState(() => _activeHeadingIndex = index);
    await Scrollable.ensureVisible(
      headingContext,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      alignment: .04,
    );
  }
}

class _MarkdownOutline extends StatelessWidget {
  const _MarkdownOutline({
    required this.headings,
    required this.collapsed,
    required this.activeHeadingIndex,
    required this.onToggle,
    required this.onSelect,
  });

  final List<_MarkdownHeading> headings;
  final bool collapsed;
  final int? activeHeadingIndex;
  final VoidCallback onToggle;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.surfaceRaised,
      child: collapsed
          ? Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: IconButton(
                  tooltip: '展开文档大纲',
                  onPressed: onToggle,
                  icon: const Icon(Icons.toc_rounded, size: 19),
                  color: AppColors.textSecondary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 18),
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Text(
                          '文档大纲',
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: '收起文档大纲',
                      onPressed: onToggle,
                      icon: const Icon(
                        Icons.keyboard_double_arrow_left_rounded,
                        size: 17,
                      ),
                      color: AppColors.textSecondary,
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (
                  var index = 0;
                  index < headings.length && index < 18;
                  index += 1
                )
                  _MarkdownOutlineItem(
                    key: ValueKey('markdown-outline-heading-$index'),
                    heading: headings[index],
                    selected: activeHeadingIndex == index,
                    onTap: () => onSelect(index),
                  ),
              ],
            ),
    );
  }
}

class _MarkdownOutlineItem extends StatelessWidget {
  const _MarkdownOutlineItem({
    super.key,
    required this.heading,
    required this.selected,
    required this.onTap,
  });

  final _MarkdownHeading heading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(left: (heading.level - 1) * 9, bottom: 3),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? AppColors.primarySoft : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: Text(
            heading.text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected || heading.level == 1
                  ? AppColors.primaryDark
                  : AppColors.textSecondary,
              fontSize: 11,
              height: 1.3,
              fontWeight: selected || heading.level == 1
                  ? FontWeight.w800
                  : FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}

class _MarkdownHeadingBuilder extends MarkdownElementBuilder {
  _MarkdownHeadingBuilder(this.headings);

  final List<_MarkdownHeading> headings;
  var _index = 0;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    if (_index >= headings.length) return null;
    final heading = headings[_index];
    final level = int.tryParse(element.tag.substring(1));
    final text = element.textContent.trim();
    if (heading.level != level || heading.text != text) return null;
    _index += 1;
    return Semantics(
      key: heading.key,
      header: true,
      child: SelectableText(text, style: preferredStyle ?? parentStyle),
    );
  }
}

class _TextFilePreview extends StatefulWidget {
  const _TextFilePreview({
    required this.text,
    required this.selectedLine,
    required this.searchQuery,
    required this.wrapText,
  });

  final String text;
  final int? selectedLine;
  final String searchQuery;
  final bool wrapText;

  @override
  State<_TextFilePreview> createState() => _TextFilePreviewState();
}

class _TextFilePreviewState extends State<_TextFilePreview> {
  late final ScrollController _scrollController = ScrollController(
    initialScrollOffset:
        ((widget.selectedLine ?? 1) - 4).clamp(0, 1 << 20) * 23,
  );

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lines = widget.text.split('\n');
    final query = widget.searchQuery.trim().toLowerCase();
    return ColoredBox(
      color: AppColors.surface,
      child: ListView.builder(
        key: const ValueKey('file-preview-text-lines'),
        controller: _scrollController,
        padding: const EdgeInsets.symmetric(vertical: 10),
        itemCount: lines.length,
        itemBuilder: (context, index) {
          final lineNumber = index + 1;
          final selected = lineNumber == widget.selectedLine;
          final match =
              query.isNotEmpty && lines[index].toLowerCase().contains(query);
          return Container(
            color: selected
                ? AppColors.primarySoft
                : match
                ? const Color(0xfffff4cc)
                : Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 56,
                  child: Text(
                    '$lineNumber',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      color: selected
                          ? AppColors.primaryDark
                          : AppColors.textTertiary,
                      fontFamily: 'monospace',
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: SelectableText(
                    lines[index].isEmpty ? ' ' : lines[index],
                    maxLines: widget.wrapText ? null : 1,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 18),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ImageFilePreview extends StatelessWidget {
  const _ImageFilePreview({required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xffeef0f5),
      child: InteractiveViewer(
        minScale: .2,
        maxScale: 6,
        boundaryMargin: const EdgeInsets.all(120),
        child: Center(
          child: Image(
            image: ResizeImage(FileImage(File(path)), width: 1800),
            fit: BoxFit.contain,
            errorBuilder: (context, error, stackTrace) => const _PreviewFailure(
              icon: Icons.broken_image_outlined,
              title: '无法显示图片',
              message: '图片可能已损坏，或编码格式不受当前系统支持。',
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewLoading extends StatelessWidget {
  const _PreviewLoading();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2.4),
          ),
          SizedBox(height: 12),
          Text(
            '正在安全地加载预览…',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PreviewFailure extends StatelessWidget {
  const _PreviewFailure({
    required this.icon,
    required this.title,
    required this.message,
    this.onOpenExternal,
  });

  final IconData icon;
  final String title;
  final String message;
  final VoidCallback? onOpenExternal;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: AppColors.primarySoft,
                  borderRadius: BorderRadius.circular(AppRadius.lg),
                ),
                child: Icon(icon, color: AppColors.primaryDark, size: 26),
              ),
              const SizedBox(height: 14),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 7),
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
              ),
              if (onOpenExternal != null) ...[
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: onOpenExternal,
                  icon: const Icon(Icons.open_in_new_rounded, size: 16),
                  label: const Text('用其他应用打开'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewNotice extends StatelessWidget {
  const _PreviewNotice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 7),
      color: AppColors.primaryMist,
      child: Row(
        children: [
          const Icon(
            Icons.info_outline_rounded,
            size: 15,
            color: AppColors.primary,
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewStatus extends StatelessWidget {
  const _PreviewStatus({required this.document});

  final FilePreviewDocument document;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline_rounded,
            size: 13,
            color: AppColors.success,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${document.typeLabel} · ${formatFilePreviewSize(document.size)} · 只读 · 当前工作区',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (document.target.line != null)
            Text(
              '第 ${document.target.line} 行',
              style: const TextStyle(
                color: AppColors.primaryDark,
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }
}

final class _MarkdownHeading {
  _MarkdownHeading({required this.level, required this.text});

  final int level;
  final String text;
  final GlobalKey key = GlobalKey();
}

List<_MarkdownHeading> _markdownHeadings(String source) {
  final document = md.Document(extensionSet: md.ExtensionSet.gitHubFlavored);
  final nodes = document.parseLines(source.split('\n'));
  final result = <_MarkdownHeading>[];
  for (final node in nodes) {
    if (node is! md.Element || node.tag.length != 2) continue;
    final level = switch (node.tag) {
      'h1' => 1,
      'h2' => 2,
      'h3' => 3,
      'h4' => 4,
      _ => null,
    };
    final text = node.textContent.trim();
    if (level == null || text.isEmpty) continue;
    result.add(_MarkdownHeading(level: level, text: text));
  }
  return result;
}

IconData _iconForPath(String path) {
  return switch (p.extension(path).toLowerCase()) {
    '.md' || '.markdown' => Icons.description_outlined,
    '.dart' ||
    '.js' ||
    '.jsx' ||
    '.ts' ||
    '.tsx' ||
    '.py' ||
    '.swift' ||
    '.go' ||
    '.rs' ||
    '.java' ||
    '.c' ||
    '.cpp' => Icons.code_rounded,
    '.json' ||
    '.yaml' ||
    '.yml' ||
    '.toml' ||
    '.xml' => Icons.data_object_rounded,
    '.csv' ||
    '.tsv' ||
    '.xls' ||
    '.xlsx' ||
    '.numbers' => Icons.table_chart_outlined,
    '.png' ||
    '.jpg' ||
    '.jpeg' ||
    '.gif' ||
    '.webp' ||
    '.heic' => Icons.image_outlined,
    '.pdf' => Icons.picture_as_pdf_outlined,
    '.ppt' || '.pptx' || '.key' => Icons.slideshow_outlined,
    '.mov' || '.mp4' || '.m4v' => Icons.movie_outlined,
    '.mp3' || '.m4a' || '.wav' || '.aac' => Icons.audio_file_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

String _errorText(Object error) {
  if (error is FileSystemException) {
    final message = error.message.trim();
    return message.isEmpty ? '文件操作失败。' : message;
  }
  if (error is FormatException) return error.message;
  final value = error.toString().replaceFirst(
    RegExp(r'^\w+(?:Exception)?:\s*'),
    '',
  );
  return value.isEmpty ? '操作失败。' : value;
}
