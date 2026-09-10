import 'package:ianvs_design/ianvs_design.dart';

/// Conversation-specific overrides layered on the shared Ianvs design theme.
class ChatThemeData {
  const ChatThemeData({
    this.colors = const {},
    this.contentMaxWidth = 800,
    this.bodyFontSize = 15,
  }) : tokens = IanvsTokens.light;

  const ChatThemeData._resolved({
    required this.colors,
    required this.contentMaxWidth,
    required this.bodyFontSize,
    required this.tokens,
  });
  final IanvsTokens tokens;
  final double bodyFontSize;

  ChatThemeData resolve(BuildContext context) => ChatThemeData._resolved(
    colors: colors,
    contentMaxWidth: contentMaxWidth,
    bodyFontSize: bodyFontSize,
    tokens: context.ianvs,
  );
  final Map<String, Color> colors;
  final double contentMaxWidth;
  Color get bg => colors['bg'] ?? tokens.chrome;
  Color get surface => colors['surface'] ?? tokens.canvas;
  Color get surfaceMuted => colors['surfaceMuted'] ?? tokens.chrome;
  Color get surfaceRaised => colors['surfaceRaised'] ?? tokens.raised;
  Color get surfaceSelected => colors['surfaceSelected'] ?? tokens.selected;
  Color get surfaceHover =>
      colors['surfaceHover'] ?? tokens.text.withValues(alpha: .06);
  Color get userMessageSurface => colors['userMessageSurface'] ?? tokens.chrome;
  Color get border => colors['border'] ?? tokens.border;
  Color get borderSoft => colors['borderSoft'] ?? tokens.separator;
  Color get textPrimary => colors['textPrimary'] ?? tokens.text;
  Color get textSecondary => colors['textSecondary'] ?? tokens.muted;
  Color get textTertiary => colors['textTertiary'] ?? tokens.subtle;
  Color get accent => colors['accent'] ?? tokens.accent;
  Color get accentDark => colors['accentDark'] ?? tokens.focus;
  Color get accentSoft => colors['accentSoft'] ?? tokens.selected;
  Color get accentMist =>
      colors['accentMist'] ?? tokens.accent.withValues(alpha: .08);
  Color get accentBorder =>
      colors['accentBorder'] ?? tokens.accent.withValues(alpha: .35);
  Color get focusRing =>
      colors['focusRing'] ?? tokens.focus.withValues(alpha: .24);
  Color get primary => colors['primary'] ?? tokens.accent;
  Color get primaryDark => colors['primaryDark'] ?? tokens.focus;
  Color get primarySoft => colors['primarySoft'] ?? tokens.selected;
  Color get primaryMist =>
      colors['primaryMist'] ?? tokens.accent.withValues(alpha: .08);
  Color get disabled => colors['disabled'] ?? tokens.separator;
  Color get success => colors['success'] ?? tokens.success;
  Color get warning => colors['warning'] ?? tokens.warning;
  Color get danger => colors['danger'] ?? tokens.danger;
}

class ChatTheme extends InheritedWidget {
  const ChatTheme({super.key, required this.data, required super.child});
  final ChatThemeData data;
  static ChatThemeData of(BuildContext context) =>
      (context.dependOnInheritedWidgetOfExactType<ChatTheme>()?.data ??
              const ChatThemeData())
          .resolve(context);
  @override
  bool updateShouldNotify(ChatTheme oldWidget) =>
      !identical(data, oldWidget.data);
}
