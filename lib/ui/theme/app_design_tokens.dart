import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  static const Color bg = Color(0xfff8f9fd);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xfff3f0ff);
  static const Color surfaceRaised = Color(0xfffbfcff);
  static const Color border = Color(0xffe2e5f0);
  static const Color borderSoft = Color(0xffedf0f7);

  static const Color textPrimary = Color(0xff111827);
  static const Color textSecondary = Color(0xff667085);
  static const Color textTertiary = Color(0xff98a2b3);

  static const Color primary = Color(0xff6d3fef);
  static const Color primaryDark = Color(0xff4f2bc7);
  static const Color primarySoft = Color(0xffede7ff);
  static const Color primaryMist = Color(0xfff7f3ff);

  static const Color disabled = Color(0xffe5e7eb);
  static const Color success = Color(0xff16a34a);
  static const Color warning = Color(0xffd97706);
  static const Color danger = Color(0xffb42318);
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

  static const double sm = 10;
  static const double md = 14;
  static const double lg = 18;
  static const double xl = 24;
  static const double pill = 999;
}

class AppShadows {
  const AppShadows._();

  static const List<BoxShadow> soft = [
    BoxShadow(color: Color(0x0f4f2bc7), blurRadius: 24, offset: Offset(0, 12)),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(color: Color(0x14525f7f), blurRadius: 34, offset: Offset(0, 18)),
  ];
}
