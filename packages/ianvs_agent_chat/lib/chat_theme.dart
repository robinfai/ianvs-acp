import 'package:flutter/material.dart';
import 'ui/theme/app_design_tokens.dart';

/// Per-conversation appearance. Defaults preserve the desktop application's UI.
class ChatThemeData {
  const ChatThemeData({this.colors = const {}, this.contentMaxWidth = 800});
  final Map<String, Color> colors;
  final double contentMaxWidth;
  Color get bg => colors['bg'] ?? AppColors.bg;
  Color get surface => colors['surface'] ?? AppColors.surface;
  Color get surfaceMuted => colors['surfaceMuted'] ?? AppColors.surfaceMuted;
  Color get surfaceRaised => colors['surfaceRaised'] ?? AppColors.surfaceRaised;
  Color get surfaceSelected =>
      colors['surfaceSelected'] ?? AppColors.surfaceSelected;
  Color get surfaceHover => colors['surfaceHover'] ?? AppColors.surfaceHover;
  Color get userMessageSurface =>
      colors['userMessageSurface'] ?? AppColors.userMessageSurface;
  Color get border => colors['border'] ?? AppColors.border;
  Color get borderSoft => colors['borderSoft'] ?? AppColors.borderSoft;
  Color get textPrimary => colors['textPrimary'] ?? AppColors.textPrimary;
  Color get textSecondary => colors['textSecondary'] ?? AppColors.textSecondary;
  Color get textTertiary => colors['textTertiary'] ?? AppColors.textTertiary;
  Color get accent => colors['accent'] ?? AppColors.accent;
  Color get accentDark => colors['accentDark'] ?? AppColors.accentDark;
  Color get accentSoft => colors['accentSoft'] ?? AppColors.accentSoft;
  Color get accentMist => colors['accentMist'] ?? AppColors.accentMist;
  Color get accentBorder => colors['accentBorder'] ?? AppColors.accentBorder;
  Color get focusRing => colors['focusRing'] ?? AppColors.focusRing;
  Color get primary => colors['primary'] ?? AppColors.primary;
  Color get primaryDark => colors['primaryDark'] ?? AppColors.primaryDark;
  Color get primarySoft => colors['primarySoft'] ?? AppColors.primarySoft;
  Color get primaryMist => colors['primaryMist'] ?? AppColors.primaryMist;
  Color get disabled => colors['disabled'] ?? AppColors.disabled;
  Color get success => colors['success'] ?? AppColors.success;
  Color get warning => colors['warning'] ?? AppColors.warning;
  Color get danger => colors['danger'] ?? AppColors.danger;
}

class ChatTheme extends InheritedWidget {
  const ChatTheme({super.key, required this.data, required super.child});
  final ChatThemeData data;
  static ChatThemeData of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ChatTheme>()?.data ??
      const ChatThemeData();
  @override
  bool updateShouldNotify(ChatTheme oldWidget) =>
      !identical(data, oldWidget.data);
}
