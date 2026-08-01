import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  // Codex uses a cool, nearly-white canvas to separate persistent navigation
  // from the pure-white conversation surface without a heavy divider.
  static const Color bg = Color(0xfff4f5f5);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xfff0f1f1);
  static const Color surfaceRaised = Color(0xfffafafa);
  static const Color surfaceSelected = Color(0xffe7e8e9);
  static const Color surfaceHover = Color(0xffeceeef);
  static const Color userMessageSurface = Color(0xfff3f3f4);
  static const Color border = Color(0xffe2e4e4);
  static const Color borderSoft = Color(0xffe9eaea);

  static const Color textPrimary = Color(0xff27292c);
  static const Color textSecondary = Color(0xff6f7275);
  static const Color textTertiary = Color(0xff96999c);

  static const Color primary = textPrimary;
  static const Color primaryDark = textPrimary;
  static const Color primarySoft = Color(0xffe9eaea);
  static const Color primaryMist = Color(0xfff3f4f4);

  static const Color disabled = Color(0xffdedede);
  static const Color success = Color(0xff16a34a);
  static const Color warning = Color(0xffca8a04);
  static const Color danger = Color(0xffdc2626);
}

class AppSpacing {
  const AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
}

class AppRadius {
  const AppRadius._();

  static const double sm = 8;
  static const double md = 10;
  static const double lg = 14;
  static const double xl = 18;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x0a000000), blurRadius: 14, offset: Offset(0, 5)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x12000000), blurRadius: 24, offset: Offset(0, 8)),
  ];

  static const List<BoxShadow> floatingPanel = [
    BoxShadow(color: Color(0x10000000), blurRadius: 30, offset: Offset(0, 10)),
    BoxShadow(color: Color(0x08000000), blurRadius: 4, offset: Offset(0, 1)),
  ];
}
