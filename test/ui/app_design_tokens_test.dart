import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ianvs_acp/ui/theme/app_design_tokens.dart';

void main() {
  test('the primary accent stays neutral instead of purple', () {
    expect(AppColors.primary, AppColors.textPrimary);
  });

  test('Codex alignment keeps navigation and content surfaces distinct', () {
    expect(AppColors.bg, const Color(0xfff4f5f5));
    expect(AppColors.surface, const Color(0xffffffff));
    expect(AppColors.surfaceSelected, const Color(0xffe7e8e9));
    expect(AppColors.userMessageSurface, const Color(0xfff3f3f4));
    expect(AppColors.textPrimary, const Color(0xff27292c));
  });
}
