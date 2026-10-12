import 'package:flutter/material.dart';

/// 猎书客色板（与 docs/design.md 保持一致，改动需同步文档）。
abstract final class AppColors {
  /// 应用主背景（深棕黑）
  static const background = Color(0xFF1F1A16);

  /// 卡片 / 表面（褐）
  static const surface = Color(0xFF2A231D);

  /// 表面高亮
  static const surfaceHigh = Color(0xFF332A22);

  /// 主文字（暖白）
  static const textPrimary = Color(0xFFE8DCC8);

  /// 次要文字（银灰）
  static const textSecondary = Color(0xFF9C8F7D);

  /// 分割线 / 描边
  static const outline = Color(0xFF3E352C);

  /// 强调-暗红
  static const accentRed = Color(0xFF8C3A2B);

  /// 强调-暗红（按压）
  static const accentRedPressed = Color(0xFFA33B2E);

  /// 点缀-烫金（仅小面积暗纹 / 分隔符）
  static const gold = Color(0xFFB08D57);
}

/// 猎书客全局主题。
abstract final class AppTheme {
  static ThemeData dark() {
    final scheme = ColorScheme.dark(
      primary: AppColors.accentRed,
      onPrimary: AppColors.textPrimary,
      secondary: AppColors.gold,
      onSecondary: AppColors.background,
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      error: AppColors.accentRedPressed,
      onError: AppColors.textPrimary,
      outline: AppColors.outline,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerHighest: AppColors.surfaceHigh,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: AppColors.background,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: AppColors.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: AppColors.surface,
        indicatorColor: AppColors.surfaceHigh,
        iconTheme: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return IconThemeData(
            color: selected ? AppColors.gold : AppColors.textSecondary,
          );
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            color: selected ? AppColors.textPrimary : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
          );
        }),
      ),
      cardTheme: CardThemeData(
        color: AppColors.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: AppColors.outline),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
        thickness: 1,
      ),
      iconTheme: const IconThemeData(color: AppColors.textSecondary),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: AppColors.textPrimary),
        bodySmall: TextStyle(color: AppColors.textSecondary),
      ),
    );
  }
}
