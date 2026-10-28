import 'dart:async';
import 'package:ianvs_design/ianvs_design.dart';
import '../../chat_theme.dart';

/// Literal text, never Markdown or a terminal emulator. Copy is opt-in and uses
/// the unchanged source; newline normalization only affects the display.
class ChatCodePreview extends StatelessWidget {
  const ChatCodePreview({
    super.key,
    required this.source,
    this.language,
    this.maxHeight = 240,
    this.maxCharacters = 32768,
    this.expanded = false,
    this.onExpandedChanged,
    this.onCopy,
  }) : assert(maxHeight > 0),
       assert(maxCharacters > 0);
  final String source;
  final String? language;
  final double maxHeight;
  final int maxCharacters;
  final bool expanded;
  final ValueChanged<bool>? onExpandedChanged;
  final FutureOr<void> Function(String source)? onCopy;

  @override
  Widget build(BuildContext context) {
    final theme = ChatTheme.of(context);
    var end = source.length.clamp(0, maxCharacters);
    if (end > 0 &&
        end < source.length &&
        source.codeUnitAt(end - 1) >= 0xd800 &&
        source.codeUnitAt(end - 1) <= 0xdbff) {
      end--;
    }
    final omitted = end < source.length;
    final display = source
        .substring(0, end)
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
    final code = SingleChildScrollView(
      primary: false,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        display,
        style: TextStyle(
          fontFamily: context.ianvsTypography.code.fontFamily,
          fontFamilyFallback: context.ianvsTypography.code.fontFamilyFallback,
          fontSize: 12,
          height: 1.5,
          color: theme.textPrimary,
        ),
      ),
    );
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(context.ianvs.controlRadius),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (language != null || onCopy != null || onExpandedChanged != null)
            Wrap(
              spacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (language != null)
                  Padding(
                    padding: const EdgeInsets.all(8),
                    child: Text(
                      language!,
                      style: TextStyle(color: theme.textSecondary),
                    ),
                  ),
                if (onCopy != null)
                  IconButton(
                    tooltip: 'Copy source',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: () => onCopy!(source),
                    icon: const Icon(Icons.copy_outlined, size: 18),
                  ),
                if (onExpandedChanged != null)
                  IconButton(
                    tooltip: expanded ? 'Collapse preview' : 'Expand preview',
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                    onPressed: () => onExpandedChanged!(!expanded),
                    icon: Icon(
                      expanded ? Icons.unfold_less : Icons.unfold_more,
                    ),
                  ),
              ],
            ),
          if (expanded)
            code
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
              child: SingleChildScrollView(primary: false, child: code),
            ),
          if (omitted)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(
                'Preview truncated',
                style: TextStyle(color: theme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
