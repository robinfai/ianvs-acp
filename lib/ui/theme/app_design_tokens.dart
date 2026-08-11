import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // Desktop Canvas mirrors the reference's quiet, neutral hierarchy: a soft
  // navigation rail, a white reading plane, and near-black primary actions.
  // Blue is intentionally reserved for focus and unread state.
  static const Color bg = Color(0xfff7f7f7);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xfff4f4f4);
  static const Color surfaceRaised = Color(0xfffafafa);
  static const Color surfaceSelected = Color(0xffe9e9e9);
  static const Color surfaceHover = Color(0xffeeeeee);
  static const Color userMessageSurface = Color(0xfff2f2f2);
  static const Color border = Color(0xffdedede);
  static const Color borderSoft = Color(0xffececec);

  static const Color textPrimary = Color(0xff242424);
  static const Color textSecondary = Color(0xff666666);
  static const Color textTertiary = Color(0xff737373);

  static const Color accent = Color(0xff0b57d0);
  static const Color accentDark = Color(0xff0842a0);
  static const Color accentSoft = Color(0xffe6f0ff);
  static const Color accentMist = Color(0xfff3f7ff);
  static const Color accentBorder = Color(0xffa9c9f7);
  static const Color focusRing = Color(0x3d1677ff);

  static const Color primary = textPrimary;
  static const Color primaryDark = Color(0xff171717);
  static const Color primarySoft = Color(0xffe9e9e9);
  static const Color primaryMist = Color(0xfff5f5f5);

  static const Color disabled = Color(0xffd7ddda);
  static const Color success = Color(0xff218758);
  static const Color warning = Color(0xffa56a15);
  static const Color danger = Color(0xffc33f43);
}

@immutable
class AppTerminalTheme extends ThemeExtension<AppTerminalTheme> {
  const AppTerminalTheme({
    required this.background,
    required this.foreground,
    required this.cursor,
    required this.selection,
    required this.scrollbarTrack,
    required this.scrollbarThumb,
  });

  // The reference keeps the terminal visually continuous with the conversation
  // surface, so the viewport uses a light canvas and restrained selection.
  static const AppTerminalTheme conversationCanvas = AppTerminalTheme(
    background: Color(0xffffffff),
    foreground: Color(0xff242424),
    cursor: Color(0xff238636),
    selection: Color(0x332f81f7),
    scrollbarTrack: Color(0x0f000000),
    scrollbarThumb: Color(0x4d737373),
  );

  final Color background;
  final Color foreground;
  final Color cursor;
  final Color selection;
  final Color scrollbarTrack;
  final Color scrollbarThumb;

  @override
  AppTerminalTheme copyWith({
    Color? background,
    Color? foreground,
    Color? cursor,
    Color? selection,
    Color? scrollbarTrack,
    Color? scrollbarThumb,
  }) {
    return AppTerminalTheme(
      background: background ?? this.background,
      foreground: foreground ?? this.foreground,
      cursor: cursor ?? this.cursor,
      selection: selection ?? this.selection,
      scrollbarTrack: scrollbarTrack ?? this.scrollbarTrack,
      scrollbarThumb: scrollbarThumb ?? this.scrollbarThumb,
    );
  }

  @override
  AppTerminalTheme lerp(covariant AppTerminalTheme? other, double t) {
    if (other == null) return this;
    return AppTerminalTheme(
      background: Color.lerp(background, other.background, t)!,
      foreground: Color.lerp(foreground, other.foreground, t)!,
      cursor: Color.lerp(cursor, other.cursor, t)!,
      selection: Color.lerp(selection, other.selection, t)!,
      scrollbarTrack: Color.lerp(scrollbarTrack, other.scrollbarTrack, t)!,
      scrollbarThumb: Color.lerp(scrollbarThumb, other.scrollbarThumb, t)!,
    );
  }
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
  static const double xl = 20;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x0a000000), blurRadius: 12, offset: Offset(0, 3)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x10000000), blurRadius: 20, offset: Offset(0, 7)),
  ];

  static const List<BoxShadow> floatingPanel = [
    BoxShadow(color: Color(0x14000000), blurRadius: 24, offset: Offset(0, 8)),
    BoxShadow(color: Color(0x0a000000), blurRadius: 3, offset: Offset(0, 1)),
  ];
}

class AppMotion {
  const AppMotion._();

  static const Duration quick = Duration(milliseconds: 120);
  static const Duration standard = Duration(milliseconds: 200);
  static const Duration emphasized = Duration(milliseconds: 300);
  static const Curve curve = Cubic(0.2, 0, 0, 1);
}
