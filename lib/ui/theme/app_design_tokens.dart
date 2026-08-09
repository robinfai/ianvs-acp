import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // Conversation Canvas keeps the persistent navigation one quiet step away
  // from the pure-white reading surface. The teal is deliberately reserved for
  // focus, selection, and success so long coding sessions stay visually calm.
  static const Color bg = Color(0xfff7f7f5);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xfff4f4f2);
  static const Color surfaceRaised = Color(0xfffbfbfa);
  static const Color surfaceSelected = Color(0xffeaf4f2);
  static const Color surfaceHover = Color(0xfff0f1ef);
  static const Color userMessageSurface = Color(0xfff4f4f3);
  static const Color border = Color(0xffe4e5e2);
  static const Color borderSoft = Color(0xffeeeeeb);

  static const Color textPrimary = Color(0xff242526);
  static const Color textSecondary = Color(0xff6b6f74);
  static const Color textTertiary = Color(0xff989ca1);

  static const Color primary = textPrimary;
  static const Color primaryDark = textPrimary;
  static const Color primarySoft = Color(0xffececea);
  static const Color primaryMist = Color(0xfff6f6f4);

  static const Color accent = Color(0xff0f8a83);
  static const Color accentDark = Color(0xff0c6f6a);
  static const Color accentSoft = Color(0xffe6f4f2);
  static const Color accentMist = Color(0xfff3faf8);
  static const Color accentBorder = Color(0xffb7ddd8);
  static const Color focusRing = Color(0x520f8a83);

  static const Color disabled = Color(0xffdedfdd);
  static const Color success = Color(0xff1f9d55);
  static const Color warning = Color(0xffb7791f);
  static const Color danger = Color(0xffd14343);
}

class AppTypography {
  const AppTypography._();

  static const String family = '.AppleSystemUIFont';
  static const List<String> familyFallback = <String>[
    'SF Pro Text',
    'PingFang SC',
    'Helvetica Neue',
    'Arial',
  ];
  static const String monoFamily = 'SF Mono';
  static const List<String> monoFallback = <String>[
    'Menlo',
    'Monaco',
    'monospace',
  ];

  static const TextStyle pageTitle = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 20,
    height: 1.25,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.15,
  );
  static const TextStyle dialogTitle = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 18,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
  );
  static const TextStyle sectionTitle = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 14,
    height: 1.35,
    fontWeight: FontWeight.w600,
  );
  static const TextStyle body = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 15,
    height: 1.55,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle bodyCompact = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 14,
    height: 1.48,
    fontWeight: FontWeight.w400,
  );
  static const TextStyle label = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 13,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle metadata = TextStyle(
    color: AppColors.textSecondary,
    fontFamily: family,
    fontFamilyFallback: familyFallback,
    fontSize: 11.5,
    height: 1.35,
    fontWeight: FontWeight.w500,
  );
  static const TextStyle code = TextStyle(
    color: AppColors.textPrimary,
    fontFamily: monoFamily,
    fontFamilyFallback: monoFallback,
    fontSize: 13,
    height: 1.5,
    fontWeight: FontWeight.w400,
  );
}

class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 40;
}

class AppRadius {
  const AppRadius._();

  static const double sm = 7;
  static const double md = 10;
  static const double lg = 12;
  static const double xl = 16;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x09000000), blurRadius: 12, offset: Offset(0, 3)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x10000000), blurRadius: 20, offset: Offset(0, 7)),
  ];

  static const List<BoxShadow> floatingPanel = [
    BoxShadow(color: Color(0x0d000000), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x07000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}
