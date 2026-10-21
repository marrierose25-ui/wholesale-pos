import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppTheme {
  static const Color background = Color(0xFFFAFAFA);
  static const Color foreground = Color(0xFF09090B);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color border = Color(0xFFE4E4E7);
  static const Color muted = Color(0xFF71717A);
  static const Color primary = Color(0xFF18181B);
  static const Color primaryForeground = Color(0xFFFAFAFA);
  static const Color danger = Color(0xFFEF4444);
  static const Color success = Color(0xFF22C55E);

  static ThemeData light() {
    final fontFamily = GoogleFonts.inter().fontFamily;

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: background,
      fontFamily: fontFamily,
      colorScheme: const ColorScheme.light(
        primary: primary,
        surface: surface,
        onSurface: foreground,
        error: danger,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: foreground,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
        iconTheme: const IconThemeData(color: foreground),
        shape: const Border(bottom: BorderSide(color: border, width: 1)),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: border, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: primaryForeground,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          textStyle: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            fontFamily: fontFamily,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: foreground,
          side: const BorderSide(color: border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          textStyle: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            fontFamily: fontFamily,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: muted,
          fontSize: 14,
          fontFamily: fontFamily,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: primary, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(color: border, thickness: 1),
    );
  }

  static ThemeData dark() {
    final fontFamily = GoogleFonts.inter().fontFamily;
    const darkBackground = Color(0xFF09090B);
    const darkSurface = Color(0xFF18181B);
    const darkBorder = Color(0xFF27272A);
    const darkMuted = Color(0xFFA1A1AA);
    const darkForeground = Color(0xFFFAFAFA);

    return ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: darkBackground,
      fontFamily: fontFamily,
      colorScheme: const ColorScheme.dark(
        primary: darkForeground,
        surface: darkSurface,
        onSurface: darkForeground,
        error: danger,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: darkSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: darkForeground,
          fontSize: 16,
          fontWeight: FontWeight.w600,
          fontFamily: fontFamily,
        ),
        iconTheme: const IconThemeData(color: darkForeground),
        shape: const Border(bottom: BorderSide(color: darkBorder, width: 1)),
      ),
      cardTheme: CardThemeData(
        color: darkSurface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: const BorderSide(color: darkBorder, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: darkForeground,
          foregroundColor: darkBackground,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          textStyle: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            fontFamily: fontFamily,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: darkForeground,
          side: const BorderSide(color: darkBorder),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          textStyle: TextStyle(
            fontWeight: FontWeight.w500,
            fontSize: 14,
            fontFamily: fontFamily,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: darkSurface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 14,
        ),
        hintStyle: TextStyle(
          color: darkMuted,
          fontSize: 14,
          fontFamily: fontFamily,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: darkBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: darkBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(6),
          borderSide: const BorderSide(color: darkForeground, width: 1),
        ),
      ),
      dividerTheme: const DividerThemeData(color: darkBorder, thickness: 1),
    );
  }
}
