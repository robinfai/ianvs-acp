import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';
import 'package:ianvs_acp/ui/theme/app_theme.dart';

void main() {
  test('primary actions stay neutral while focus uses restrained blue', () {
    expect(AppColors.primary, AppColors.textPrimary);
    expect(AppColors.primaryDark, const Color(0xff171717));
    expect(AppColors.primarySoft, const Color(0xffe9e9e9));
    expect(AppColors.accent, const Color(0xff0b57d0));
  });

  test(
    'Conversation Canvas keeps navigation and content surfaces distinct',
    () {
      expect(AppColors.bg, const Color(0xfff7f7f7));
      expect(AppColors.surface, const Color(0xffffffff));
      expect(AppColors.surfaceSelected, const Color(0xffe9e9e9));
      expect(AppColors.userMessageSurface, const Color(0xfff2f2f2));
      expect(AppColors.textPrimary, const Color(0xff242424));
      expect(AppColors.accent, const Color(0xff0b57d0));
    },
  );

  test('Conversation Canvas uses restrained product typography', () {
    expect(AppTypography.family, '.AppleSystemUIFont');
    expect(AppTypography.body.fontSize, 15);
    expect(AppTypography.body.fontWeight, FontWeight.w400);
    expect(AppTypography.label.fontWeight, FontWeight.w500);
    expect(AppTypography.sectionTitle.fontWeight, FontWeight.w600);
  });

  test('Material color roles share one application theme', () {
    final theme = AppTheme.light;
    final scheme = theme.colorScheme;

    expect(scheme.primary, AppColors.primary);
    expect(scheme.primaryContainer, AppColors.primarySoft);
    expect(scheme.surfaceContainer, AppColors.surfaceMuted);
    expect(scheme.outlineVariant, AppColors.border);
  });

  test('primary text and metadata meet AA contrast', () {
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
