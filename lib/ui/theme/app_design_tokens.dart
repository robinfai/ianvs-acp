import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // Conversation Canvas uses a warm graphite neutral scale so the navigation,
  // reading surface, inspector, and terminal chrome feel like one workspace.
  // Teal is the product primary: it is reserved for focus, selection, active
  // state, and primary actions rather than being used as decorative color.
  static const Color bg = Color(0xfff3f5f3);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xfff1f3f1);
  static const Color surfaceRaised = Color(0xfffafbfa);
  static const Color surfaceSelected = Color(0xffe2f2ee);
  static const Color surfaceHover = Color(0xffebf0ed);
  static const Color userMessageSurface = Color(0xfff0f2f0);
  static const Color border = Color(0xffdce1de);
  static const Color borderSoft = Color(0xffe8ece9);

  static const Color textPrimary = Color(0xff202422);
  static const Color textSecondary = Color(0xff5f6864);
  static const Color textTertiary = Color(0xff6f7773);

  static const Color accent = Color(0xff0b7e75);
  static const Color accentDark = Color(0xff08645d);
  static const Color accentSoft = Color(0xffdcefea);
  static const Color accentMist = Color(0xfff0f9f6);
  static const Color accentBorder = Color(0xffa9d7cf);
  static const Color focusRing = Color(0x520b7e75);

  // Keep the legacy primary aliases while making their intent match
  // ColorScheme.primary. Existing components now inherit the product accent
  // instead of treating graphite text as an action color.
  static const Color primary = accent;
  static const Color primaryDark = accentDark;
  static const Color primarySoft = accentSoft;
  static const Color primaryMist = accentMist;

  static const Color disabled = Color(0xffd7ddda);
  static const Color success = Color(0xff218758);
  static const Color warning = Color(0xffa56a15);
  static const Color danger = Color(0xffc33f43);
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
    fontSize: 12,
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

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 18;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x080d1b17), blurRadius: 12, offset: Offset(0, 3)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x0d0d1b17), blurRadius: 20, offset: Offset(0, 7)),
  ];

  static const List<BoxShadow> floatingPanel = [
    BoxShadow(color: Color(0x120d1b17), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x080d1b17), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

class AppMotion {
  const AppMotion._();

  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration emphasized = Duration(milliseconds: 300);
  static const Curve curve = Cubic(0.2, 0, 0, 1);
}
