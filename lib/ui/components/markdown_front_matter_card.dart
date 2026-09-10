import 'package:ianvs_design/ianvs_design.dart';

import '../file_preview/markdown_front_matter.dart';

const int _collapsedMetadataItems = 6;

class MarkdownFrontMatterCard extends StatefulWidget {
  const MarkdownFrontMatterCard({super.key, required this.entries});

  final List<MarkdownMetadataEntry> entries;

  @override
  State<MarkdownFrontMatterCard> createState() =>
      _MarkdownFrontMatterCardState();
}

class _MarkdownFrontMatterCardState extends State<MarkdownFrontMatterCard> {
  var _expanded = false;

  @override
  void didUpdateWidget(covariant MarkdownFrontMatterCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.entries, widget.entries)) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final canExpand = widget.entries.length > _collapsedMetadataItems;
    final entries = canExpand && !_expanded
        ? widget.entries.take(_collapsedMetadataItems)
        : widget.entries;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: context.ianvs.chrome,
        border: Border.all(color: context.ianvs.selected),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.description_outlined,
                size: 17,
                color: context.ianvs.focus,
              ),
              const SizedBox(width: 8),
              Text(
                '文档信息',
                style: TextStyle(
                  color: context.ianvs.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: context.ianvs.selected,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  'YAML',
                  style: TextStyle(
                    color: context.ianvs.focus,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    letterSpacing: .5,
                  ),
                ),
              ),
              const Spacer(),
              Text(
                '${widget.entries.length} 项',
                style: TextStyle(
                  color: context.ianvs.subtle,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (canExpand) ...[
                const SizedBox(width: 4),
                IconButton(
                  tooltip: _expanded ? '收起元数据' : '展开全部元数据',
                  onPressed: () => setState(() => _expanded = !_expanded),
                  icon: Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 17,
                  ),
                  color: context.ianvs.muted,
                  constraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 30,
                  ),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.standard,
                ),
              ],
            ],
          ),
          const SizedBox(height: 9),
          LayoutBuilder(
            builder: (context, constraints) {
              const spacing = 8.0;
              final twoColumns = constraints.maxWidth >= 500;
              final halfWidth = twoColumns
                  ? (constraints.maxWidth - spacing) / 2
                  : constraints.maxWidth;
              return Wrap(
                spacing: spacing,
                runSpacing: spacing,
                children: [
                  for (final entry in entries)
                    SizedBox(
                      width: twoColumns && !entry.isLong
                          ? halfWidth
                          : constraints.maxWidth,
                      child: _MetadataEntryTile(entry: entry),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MetadataEntryTile extends StatelessWidget {
  const _MetadataEntryTile({required this.entry});

  final MarkdownMetadataEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: context.ianvs.canvas.withValues(alpha: .82),
        border: Border.all(color: context.ianvs.separator),
        borderRadius: BorderRadius.circular(context.ianvs.panelRadius),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: context.ianvs.subtle,
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          if (entry.items.length > 1)
            Wrap(
              spacing: 5,
              runSpacing: 4,
              children: [
                for (final item in entry.items.take(12))
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: context.ianvs.accent.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      item,
                      style: TextStyle(
                        color: context.ianvs.focus,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            )
          else
            SelectableText(
              entry.value,
              style: TextStyle(
                color: context.ianvs.text,
                fontSize: 11.5,
                height: 1.35,
                fontWeight: FontWeight.w600,
              ),
            ),
        ],
      ),
    );
  }
}
