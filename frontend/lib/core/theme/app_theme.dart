import 'package:material_ui/material_ui.dart';

import 'app_design.dart';

/// App-wide Material theme, built on the [AppDesign] token system.
///
/// Dark is the flagship "premium fintech" look, but the light variant is a
/// first-class, hand-tuned palette (not a seeded approximation) so both modes
/// feel deliberate. The [AppTheme] colour accessors mirror [AppDesign] so the
/// many screens that reference them shift with the active brightness.
class AppTheme {
  AppTheme._();

  // ---- Fixed dark surfaces (used when building the dark ThemeData, which
  // must not depend on the currently-active AppDesign palette). -----------
  static const Color _darkBg = Color(0xFF080B16);
  static const Color _darkBgElevated = Color(0xFF0C1120);
  static const Color _darkCard = Color(0xFF111A2E);
  static const Color _darkCardSoft = Color(0xFF16203A);
  static const Color _darkStroke = Color(0x17FFFFFF);
  static const Color _darkStrokeStrong = Color(0x2BFFFFFF);
  static const Color _darkTextHi = Color(0xFFF5F7FB);
  static const Color _darkTextLo = Color(0xFF9AA6BF);

  // ---- Fixed light surfaces. --------------------------------------------
  static const Color _lightBg = Color(0xFFFAFAFA);
  static const Color _lightCard = Color(0xFFFFFFFF);
  static const Color _lightInput = Color(0xFFF3F4F6);
  static const Color _lightStroke = Color(0x14E5E7EB);
  static const Color _lightTextHi = Color(0xFF111827);
  static const Color _lightTextLo = Color(0xFF6B7280);

  // ---- Public palette (mirrors AppDesign; surface/text are dynamic) -----
  static Color get background => AppDesign.bg;
  static Color get foreground => AppDesign.textHi;
  static Color get surface => AppDesign.card;
  static Color get border => AppDesign.stroke;
  static Color get muted => AppDesign.textLo;
  static const Color primary = AppDesign.blue;
  static const Color primaryForeground = AppDesign.onBlue;
  static const Color danger = AppDesign.danger;
  static const Color success = AppDesign.success;
  static const Color warning = AppDesign.warning;

  static const String _font = 'Geist';

  static ThemeData light() => _build(_lightScheme(), false);
  static ThemeData dark() => _build(_darkScheme(), true);

  static ColorScheme _darkScheme() => const ColorScheme(
    brightness: Brightness.dark,
    primary: AppDesign.blue,
    onPrimary: Colors.white,
    primaryContainer: AppDesign.blueDeep,
    onPrimaryContainer: Colors.white,
    secondary: AppDesign.blueBright,
    onSecondary: Colors.white,
    surface: _darkCard,
    onSurface: _darkTextHi,
    surfaceContainerHighest: _darkCardSoft,
    onSurfaceVariant: _darkTextLo,
    outline: _darkStrokeStrong,
    outlineVariant: _darkStroke,
    error: AppDesign.danger,
    onError: Colors.white,
    inverseSurface: Colors.white,
    onInverseSurface: _darkBg,
    shadow: Colors.black,
  );

  static ColorScheme _lightScheme() => const ColorScheme(
    brightness: Brightness.light,
    primary: AppDesign.blue,
    onPrimary: Colors.white,
    primaryContainer: Color(0xFFE4ECFF),
    onPrimaryContainer: AppDesign.blueDeep,
    secondary: AppDesign.blueBright,
    onSecondary: Colors.white,
    surface: _lightCard,
    onSurface: _lightTextHi,
    surfaceContainerHighest: Color(0xFFEEF2FB),
    onSurfaceVariant: _lightTextLo,
    outline: Color(0x330A1330),
    outlineVariant: _lightStroke,
    error: AppDesign.danger,
    onError: Colors.white,
    inverseSurface: _darkBg,
    onInverseSurface: Colors.white,
    shadow: Color(0xFF0B1220),
  );

  static ThemeData _build(ColorScheme scheme, bool isDark) {
    final scaffoldBg = isDark ? _darkBg : _lightBg;
    final cardColor = isDark ? _darkCard : _lightCard;
    final strokeColor = isDark ? _darkStroke : _lightStroke;

    return ThemeData(
      useMaterial3: true,
      
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBg,
      // InkSparkle is Material 3's fluid highlight — the ripple hugs the
      // finger and settles without the hard edge InkRipple shows.
      splashFactory: InkSparkle.splashFactory,
      textTheme: _textTheme(scheme),
      iconTheme: IconThemeData(color: scheme.onSurface),

      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 19,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      cardTheme: CardThemeData(
        color: cardColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppDesign.radiusCard),
          side: BorderSide(color: strokeColor),
        ),
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: AppDesign.blue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
            letterSpacing: 0.1,
            
          ),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppDesign.blue,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14.5,
            letterSpacing: 0.1,
            
          ),
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.onSurface,
          side: BorderSide(color: scheme.outlineVariant),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            
          ),
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? AppDesign.blueBright : AppDesign.blue,
          textStyle: const TextStyle(
            fontWeight: FontWeight.w600,
            
          ),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: isDark ? Colors.white.withValues(alpha: 0.04) : _lightInput,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 16,
        ),
        hintStyle: TextStyle(color: scheme.onSurfaceVariant, fontSize: 14),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        floatingLabelStyle: TextStyle(
          color: isDark ? AppDesign.blueBright : AppDesign.blue,
          fontWeight: FontWeight.w600,
        ),
        prefixIconColor: scheme.onSurfaceVariant,
        suffixIconColor: scheme.onSurfaceVariant,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppDesign.blue, width: 1.8),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: scheme.error, width: 1.8),
        ),
      ),

      dividerTheme: DividerThemeData(color: strokeColor, thickness: 1),

      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 15.5,
          fontWeight: FontWeight.w600,
          
        ),
        subtitleTextStyle: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 13,
          
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: isDark
            ? Colors.white.withValues(alpha: 0.06)
            : const Color(0xFFEEF2FB),
        selectedColor: AppDesign.blue,
        side: BorderSide.none,
        labelStyle: TextStyle(color: scheme.onSurface, fontFamily: _font),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: isDark ? _darkBgElevated : _lightCard,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        indicatorColor: AppDesign.blue,
        elevation: 0,
        height: 64,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontWeight: FontWeight.w600, fontFamily: _font),
        ),
      ),

      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: Colors.transparent,
        selectedIconTheme: const IconThemeData(color: AppDesign.blueBright),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: const TextStyle(
          color: AppDesign.blueBright,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),

      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: AppDesign.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? Colors.white
              : scheme.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppDesign.blue
              : scheme.surfaceContainerHighest,
        ),
        trackOutlineColor: WidgetStatePropertyAll(scheme.outlineVariant),
      ),

      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: AppDesign.blue,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
      ),

      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? _darkCardSoft : _lightCard,
        contentTextStyle: TextStyle(color: Colors.white, fontFamily: _font),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),

      tabBarTheme: TabBarThemeData(
        indicatorColor: AppDesign.blue,
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(
          fontWeight: FontWeight.w700,
          
        ),
      ),
    );
  }

  /// A deliberate, premium type scale: tighter tracking on the big figures,
  /// comfortable line-height in body copy, consistent weights throughout.
  static TextTheme _textTheme(ColorScheme scheme) {
    return TextTheme(
      displayLarge: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.5,
        fontSize: 48,
      ),
      displayMedium: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        fontSize: 40,
      ),
      displaySmall: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -1,
        fontSize: 32,
      ),
      headlineLarge: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        fontSize: 28,
      ),
      headlineMedium: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.6,
        fontSize: 24,
      ),
      headlineSmall: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.4,
        fontSize: 20,
      ),
      titleLarge: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
        fontSize: 18,
      ),
      titleMedium: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
        fontSize: 15.5,
      ),
      titleSmall: TextStyle(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w600,
        fontSize: 13.5,
      ),
      bodyLarge: TextStyle(
        color: scheme.onSurface,
        fontSize: 15.5,
        height: 1.4,
      ),
      bodyMedium: TextStyle(
        color: scheme.onSurface,
        fontSize: 14,
        height: 1.45,
      ),
      bodySmall: TextStyle(
        color: scheme.onSurfaceVariant,
        fontSize: 12.5,
        height: 1.4,
      ),
      labelLarge: TextStyle(
        color: scheme.onSurface,
        fontWeight: FontWeight.w600,
        fontSize: 14,
      ),
      labelMedium: TextStyle(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
        fontSize: 12,
      ),
      labelSmall: TextStyle(
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w500,
        fontSize: 11,
        letterSpacing: 0.3,
      ),
    );
  }
}
