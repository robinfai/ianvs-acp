import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  test('the primary accent stays neutral instead of purple', () {
    expect(AppColors.primary, AppColors.textPrimary);
  });

  test(
    'Conversation Canvas keeps navigation and content surfaces distinct',
    () {
      expect(AppColors.bg, const Color(0xfff7f7f5));
      expect(AppColors.surface, const Color(0xffffffff));
      expect(AppColors.surfaceSelected, const Color(0xffeaf4f2));
      expect(AppColors.userMessageSurface, const Color(0xfff4f4f3));
      expect(AppColors.textPrimary, const Color(0xff242526));
      expect(AppColors.accent, const Color(0xff0f8a83));
    },
  );

  test('Conversation Canvas uses restrained product typography', () {
    expect(AppTypography.family, '.AppleSystemUIFont');
    expect(AppTypography.body.fontSize, 15);
    expect(AppTypography.body.fontWeight, FontWeight.w400);
    expect(AppTypography.label.fontWeight, FontWeight.w500);
    expect(AppTypography.sectionTitle.fontWeight, FontWeight.w600);
  });
}
