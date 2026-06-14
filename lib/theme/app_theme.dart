import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// SyncNews Audio のテーマ定義。
///
/// 開発者の既存自作アプリ群（角丸タイル + 白線画アイコン）の系譜を継承し、
/// ブランドカラーは未使用の「ディープ・インディゴ」を採用。
/// 再生中ハイライトには視認性の高いアンバーをアクセントとして用いる。
class AppColors {
  AppColors._();

  // --- ブランド ---
  static const Color brand = Color(0xFF4F46E5); // ディープ・インディゴ（アイコン背景と一致）
  static const Color brandDark = Color(0xFF6366F1); // ダークモードで沈まないよう一段明るく

  // --- 同期ハイライト（再生中の文）---
  static const Color highlight = Color(0xFFFFB020); // アンバー: テキスト追従の現在位置
  static const Color highlightBg = Color(0x33FFB020); // 行背景の淡いアンバー

  // --- ライト ---
  static const Color lightBg = Color(0xFFF7F7FB);
  static const Color lightSurface = Color(0xFFFFFFFF);
  static const Color lightText = Color(0xFF1A1A2E);
  static const Color lightSubtle = Color(0xFF6B6B85);

  // --- ダーク ---
  static const Color darkBg = Color(0xFF121225);
  static const Color darkSurface = Color(0xFF1C1C33);
  static const Color darkText = Color(0xFFECECF5);
  static const Color darkSubtle = Color(0xFF9A9ABA);
}

class AppTheme {
  AppTheme._();

  static ThemeData get light => _base(Brightness.light);
  static ThemeData get dark => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brand,
      brightness: brightness,
      primary: isDark ? AppColors.brandDark : AppColors.brand,
      surface: isDark ? AppColors.darkSurface : AppColors.lightSurface,
    );

    final textColor = isDark ? AppColors.darkText : AppColors.lightText;

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
      textTheme: GoogleFonts.notoSansJpTextTheme(
        ThemeData(brightness: brightness).textTheme,
      ).apply(bodyColor: textColor, displayColor: textColor),
      cardTheme: CardTheme(
        elevation: 0,
        color: isDark ? AppColors.darkSurface : AppColors.lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: isDark ? AppColors.darkBg : AppColors.lightBg,
        foregroundColor: textColor,
        elevation: 0,
        centerTitle: false,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        ),
      ),
    );
  }
}
