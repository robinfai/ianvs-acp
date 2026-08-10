import 'package:flutter/material.dart';

import 'app_design_tokens.dart';

/// The single assembly point for ACP's Conversation Canvas design language.
///
/// Widgets should prefer [ThemeData.colorScheme] and [ThemeData.textTheme].
/// Product-specific values that Material does not model, such as the terminal
/// viewport palette, live in a [ThemeExtension].
abstract final class AppTheme {
  static ThemeData get light {
    const colorScheme = ColorScheme.light(
      primary: AppColors.primary,
      onPrimary: Colors.white,
      primaryContainer: AppColors.accentSoft,
      onPrimaryContainer: AppColors.accentDark,
      secondary: Color(0xff4f6963),
      onSecondary: Colors.white,
      secondaryContainer: Color(0xffe4ece9),
      onSecondaryContainer: Color(0xff304640),
      tertiary: Color(0xff536f78),
      onTertiary: Colors.white,
      tertiaryContainer: Color(0xffe0ebee),
      onTertiaryContainer: Color(0xff30474f),
      error: AppColors.danger,
      onError: Colors.white,
      errorContainer: Color(0xffffe7e7),
      onErrorContainer: Color(0xff742127),
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: AppColors.surfaceRaised,
      surfaceContainer: AppColors.surfaceMuted,
      surfaceContainerHigh: AppColors.surfaceHover,
      surfaceContainerHighest: AppColors.userMessageSurface,
      inverseSurface: AppColors.textPrimary,
      onInverseSurface: Colors.white,
      inversePrimary: Color(0xff75d9ca),
      outline: Color(0xff929c97),
      outlineVariant: AppColors.border,
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      colorScheme: colorScheme,
      scaffoldBackgroundColor: AppColors.bg,
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      splashFactory: NoSplash.splashFactory,
      fontFamily: AppTypography.family,
      fontFamilyFallback: AppTypography.familyFallback,
      extensions: const <ThemeExtension<dynamic>>[
        AppTerminalTheme.conversationCanvas,
      ],
      textTheme: const TextTheme(
        titleLarge: AppTypography.pageTitle,
        titleMedium: AppTypography.sectionTitle,
        titleSmall: AppTypography.label,
        bodyLarge: AppTypography.body,
        bodyMedium: AppTypography.bodyCompact,
        bodySmall: TextStyle(
          color: AppColors.textSecondary,
          fontSize: 12.5,
          height: 1.4,
          fontWeight: FontWeight.w400,
        ),
        labelLarge: AppTypography.label,
        labelMedium: AppTypography.metadata,
        labelSmall: TextStyle(
          color: AppColors.textTertiary,
          fontSize: 11,
          height: 1.35,
          fontWeight: FontWeight.w500,
        ),
      ),
      focusColor: AppColors.accentMist,
      hoverColor: AppColors.surfaceHover,
      dividerTheme: const DividerThemeData(
        color: AppColors.border,
        thickness: 1,
        space: 1,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.borderSoft),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surface,
        hoverColor: AppColors.surfaceMuted,
        isDense: true,
        hintStyle: const TextStyle(
          color: AppColors.textTertiary,
          fontSize: 13.5,
          fontWeight: FontWeight.w400,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 11,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: const BorderSide(color: AppColors.accent, width: 1.4),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: AppColors.surface,
        elevation: 0,
        shadowColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        menuPadding: const EdgeInsets.symmetric(vertical: 5),
        textStyle: AppTypography.label,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
          side: const BorderSide(color: AppColors.borderSoft),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: AppColors.textSecondary,
          hoverColor: AppColors.surfaceHover,
          highlightColor: AppColors.surfaceSelected,
          minimumSize: const Size(32, 32),
          maximumSize: const Size(40, 40),
          padding: const EdgeInsets.all(7),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: AppColors.primaryDark,
          minimumSize: const Size(32, 34),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          textStyle: AppTypography.label,
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          foregroundColor: colorScheme.onPrimary,
          backgroundColor: colorScheme.primary,
          disabledForegroundColor: AppColors.textTertiary,
          disabledBackgroundColor: AppColors.surfaceHover,
          minimumSize: const Size(36, 36),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: 9,
          ),
          elevation: 0,
          textStyle: AppTypography.label,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          minimumSize: const Size(36, 36),
          padding: const EdgeInsets.symmetric(
            horizontal: 13,
            vertical: AppSpacing.sm,
          ),
          side: const BorderSide(color: AppColors.border),
          textStyle: AppTypography.label,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : AppColors.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.surfaceMuted,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.border,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(Colors.white),
        side: const BorderSide(color: AppColors.textTertiary),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.accent
              : AppColors.textTertiary,
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: AppColors.accent,
        linearTrackColor: AppColors.surfaceMuted,
        circularTrackColor: AppColors.surfaceMuted,
      ),
      scrollbarTheme: ScrollbarThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.hovered)
              ? AppColors.textSecondary.withValues(alpha: 0.58)
              : AppColors.textTertiary.withValues(alpha: 0.38),
        ),
        trackColor: WidgetStatePropertyAll(
          AppColors.surfaceHover.withValues(alpha: 0.5),
        ),
        thickness: const WidgetStatePropertyAll(6),
        radius: const Radius.circular(AppRadius.pill),
        interactive: true,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(
          horizontal: 28,
          vertical: AppSpacing.xl,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xl),
          side: const BorderSide(color: AppColors.borderSoft),
        ),
        titleTextStyle: AppTypography.dialogTitle,
        contentTextStyle: AppTypography.bodyCompact,
        actionsPadding: const EdgeInsets.only(
          left: 20,
          top: AppSpacing.sm,
          right: 20,
          bottom: 18,
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: AppColors.textPrimary,
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        textStyle: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          fontWeight: FontWeight.w500,
        ),
        waitDuration: const Duration(milliseconds: 420),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppColors.textPrimary,
        contentTextStyle: const TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w400,
        ),
        actionTextColor: colorScheme.inversePrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: AppColors.accent,
        selectionColor: AppColors.accent.withValues(alpha: 0.22),
        selectionHandleColor: AppColors.accent,
      ),
    );
  }
}
