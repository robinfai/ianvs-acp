import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';
import 'package:ianvs_acp/ui/theme/app_theme.dart';

void main() {
  test('the primary role uses the restrained product teal', () {
    expect(AppColors.primary, AppColors.accent);
    expect(AppColors.primaryDark, AppColors.accentDark);
    expect(AppColors.primarySoft, AppColors.accentSoft);
    expect(AppColors.primaryMist, AppColors.accentMist);
  });

  test(
    'Conversation Canvas keeps navigation and content surfaces distinct',
    () {
      expect(AppColors.bg, const Color(0xfff3f5f3));
      expect(AppColors.surface, const Color(0xffffffff));
      expect(AppColors.surfaceSelected, const Color(0xffe2f2ee));
      expect(AppColors.userMessageSurface, const Color(0xfff0f2f0));
      expect(AppColors.textPrimary, const Color(0xff202422));
      expect(AppColors.accent, const Color(0xff0b7e75));
    },
  );

  test('Conversation Canvas uses restrained product typography', () {
    expect(AppTypography.family, '.AppleSystemUIFont');
    expect(AppTypography.body.fontSize, 15);
    expect(AppTypography.body.fontWeight, FontWeight.w400);
    expect(AppTypography.label.fontWeight, FontWeight.w500);
    expect(AppTypography.sectionTitle.fontWeight, FontWeight.w600);
  });

  test('Material color roles and terminal palette share one theme', () {
    final theme = AppTheme.light;
    final scheme = theme.colorScheme;
    final terminal = theme.extension<AppTerminalTheme>();

    expect(scheme.primary, AppColors.accent);
    expect(scheme.primaryContainer, AppColors.accentSoft);
    expect(scheme.surfaceContainer, AppColors.surfaceMuted);
    expect(scheme.outlineVariant, AppColors.border);
    expect(terminal, AppTerminalTheme.conversationCanvas);
  });

  test('primary text, metadata, and terminal colors meet AA contrast', () {
    expect(_contrast(AppColors.textPrimary, AppColors.surface), greaterThan(7));
    expect(
      _contrast(AppColors.textSecondary, AppColors.surface),
      greaterThan(4.5),
    );
    expect(
      _contrast(AppColors.textTertiary, AppColors.surface),
      greaterThan(4.5),
    );
    expect(_contrast(AppColors.accent, AppColors.surface), greaterThan(4.5));
    expect(
      _contrast(
        AppTerminalTheme.conversationCanvas.foreground,
        AppTerminalTheme.conversationCanvas.background,
      ),
      greaterThan(7),
    );
    expect(
      _contrast(
        AppTerminalTheme.conversationCanvas.cursor,
        AppTerminalTheme.conversationCanvas.background,
      ),
      greaterThan(4.5),
    );
  });
}

double _contrast(Color first, Color second) {
  final lighter = first.computeLuminance() > second.computeLuminance()
      ? first
      : second;
  final darker = identical(lighter, first) ? second : first;
  return (lighter.computeLuminance() + 0.05) /
      (darker.computeLuminance() + 0.05);
}
