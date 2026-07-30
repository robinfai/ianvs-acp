import 'package:flutter/material.dart';

class AppColors {
  const AppColors._();

  static const Color bg = Color(0xfff7f7f7);
  static const Color surface = Color(0xffffffff);
  static const Color surfaceMuted = Color(0xffeeeeee);
  static const Color surfaceRaised = Color(0xfffafafa);
  static const Color border = Color(0xffe3e3e3);
  static const Color borderSoft = Color(0xffeeeeee);

  static const Color textPrimary = Color(0xff202020);
  static const Color textSecondary = Color(0xff686868);
  static const Color textTertiary = Color(0xff9a9a9a);

  static const Color primary = Color(0xff4f46e5);
  static const Color primaryDark = Color(0xff202020);
  static const Color primarySoft = Color(0xffececec);
  static const Color primaryMist = Color(0xfff3f3f3);

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
