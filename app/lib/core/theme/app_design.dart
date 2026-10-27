import 'package:flutter/material.dart';

import '../utils/date_range.dart';

/// Premium "fintech" design system — theme-aware.
///
/// A single source of truth for the look the owner asked for. The surface and
/// text tokens flip between a near-black navy (dark) and a clean cool-white
/// (light) palette, while the royal-blue accent + semantic colours stay
/// constant because they read well on both. Screens compose these tokens and
/// the shared widgets below instead of hard-coding colours.
///
/// The active palette is chosen once per frame from the app's theme mode via
/// [AppDesign.setMode]; every `AppDesign.xxx` colour getter then resolves to
/// the right value for the current brightness. Call [setMode] from the root
/// build before returning [MaterialApp] so children read the updated tokens.
class AppDesign {
  AppDesign._();

  // ---- Active palette selection ----------------------------------------
  static AppPalette _p = _darkPalette;
  static bool get isDark => _p.brightness == Brightness.dark;

  /// Point every `AppDesign` colour getter at the palette for [brightness].
  static void setMode(Brightness brightness) =>
      _p = brightness == Brightness.light ? _lightPalette : _darkPalette;

  // ---- Theme-aware surfaces + text -------------------------------------
  static Color get bg => _p.bg;
  static Color get bgElevated => _p.bgElevated;
  static Color get card => _p.card;
  static Color get cardSoft => _p.cardSoft;
  static Color get stroke => _p.stroke;
  static Color get strokeStrong => _p.strokeStrong;
  static Color get textHi => _p.textHi;
  static Color get textLo => _p.textLo;
  static Color get textFaint => _p.textFaint;

  // ---- Brand accent + semantic colours (theme-invariant) ---------------
  static const Color blue = Color(0xFF2F6BFF);
  static const Color blueBright = Color(0xFF4F8BFF);
  static const Color blueDeep = Color(0xFF1E4FD6);
  static const Color onBlue = Colors.white;

  static const Color success = Color(0xFF22C55E);
  static const Color danger = Color(0xFFEF4444);
  static const Color warning = Color(0xFFF59E0B);

  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [blueBright, blueDeep],
  );

  // ---- Radii / spacing --------------------------------------------------
  static const double radiusCard = 22;
  static const double radiusCardSm = 16;
  static const double radiusPill = 999;
  static const double radiusButton = 14;

  // ---- Signature background gradient (theme-aware) ---------------------
  static List<Color> get auroraColors => _p.aurora;

  /// A soft accent glow. Kept subtle on purpose — heavy blur reads as cheap.
  static BoxShadow blueGlow({double alpha = 0.30, double blur = 22}) =>
      BoxShadow(
        color: blue.withValues(alpha: isDark ? alpha : alpha * 0.55),
        blurRadius: blur,
        offset: const Offset(0, 8),
      );

  /// The card elevation shadow. Crisp and diffuse (never a blurry halo).
  static List<BoxShadow> cardShadow({bool? dark}) {
    final isDarkShadow = dark ?? isDark;
    if (isDarkShadow) {
      return [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.34),
          blurRadius: 22,
          offset: const Offset(0, 10),
        ),
      ];
    }
    return [
      BoxShadow(
        color: const Color(0xFF0B1220).withValues(alpha: 0.06),
        blurRadius: 16,
        offset: const Offset(0, 6),
      ),
      BoxShadow(
        color: const Color(0xFF0B1220).withValues(alpha: 0.04),
        blurRadius: 3,
        offset: const Offset(0, 1),
      ),
    ];
  }

  /// The frosted card fill. No backdrop blur — a clean translucent gradient
  /// with a hairline border is what reads as premium (blur looks cheap).
  static LinearGradient get glassFill => isDark
      ? LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: 0.06),
            Colors.white.withValues(alpha: 0.025),
          ],
        )
      : const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFFFFFFF), Color(0xFFFAFBFE)],
        );
}

/// A brightness-scoped set of surface/text colours. Two const instances
/// ([_darkPalette] / [_lightPalette]) are selected at runtime by [AppDesign].
class AppPalette {
  final Brightness brightness;
  final Color bg;
  final Color bgElevated;
  final Color card;
  final Color cardSoft;
  final Color stroke;
  final Color strokeStrong;
  final Color textHi;
  final Color textLo;
  final Color textFaint;
  final List<Color> aurora;

  const AppPalette({
    required this.brightness,
    required this.bg,
    required this.bgElevated,
    required this.card,
    required this.cardSoft,
    required this.stroke,
    required this.strokeStrong,
    required this.textHi,
    required this.textLo,
    required this.textFaint,
    required this.aurora,
  });
}

const AppPalette _darkPalette = AppPalette(
  brightness: Brightness.dark,
  bg: Color(0xFF080B16),
  bgElevated: Color(0xFF0C1120),
  card: Color(0xFF111A2E),
  cardSoft: Color(0xFF16203A),
  stroke: Color(0x17FFFFFF),
  strokeStrong: Color(0x2BFFFFFF),
  textHi: Color(0xFFF5F7FB),
  textLo: Color(0xFF9AA6BF),
  textFaint: Color(0xFF5C6883),
  aurora: [Color(0xFF0A1330), Color(0xFF080B16), Color(0xFF080B16)],
);

const AppPalette _lightPalette = AppPalette(
  brightness: Brightness.light,
  bg: Color(0xFFF4F6FC),
  bgElevated: Color(0xFFFFFFFF),
  card: Color(0xFFFFFFFF),
  cardSoft: Color(0xFFEEF2FB),
  stroke: Color(0x140A1330), // navy ~8%
  strokeStrong: Color(0x240A1330),
  textHi: Color(0xFF0B1220),
  textLo: Color(0xFF5A6478),
  textFaint: Color(0xFF98A1B5),
  aurora: [Color(0xFFEDF2FF), Color(0xFFF4F6FC), Color(0xFFF4F6FC)],
);

/// Full-bleed app background with a soft accent bloom. Wrap screen bodies in
/// this to get the signature look behind the content.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: AppDesign.auroraColors,
        ),
      ),
      child: Stack(
        children: [
          // Top-left accent bloom (very subtle in light mode).
          Positioned(
            top: -140,
            left: -80,
            child: _Bloom(
              size: 360,
              color: AppDesign.blue,
              alpha: AppDesign.isDark ? 0.28 : 0.10,
            ),
          ),
          // Secondary cooler bloom.
          Positioned(
            top: -60,
            right: -120,
            child: _Bloom(
              size: 300,
              color: AppDesign.blueBright,
              alpha: AppDesign.isDark ? 0.16 : 0.07,
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _Bloom extends StatelessWidget {
  final double size;
  final Color color;
  final double alpha;
  const _Bloom({required this.size, required this.color, required this.alpha});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: alpha),
              color.withValues(alpha: 0),
            ],
          ),
        ),
      ),
    );
  }
}

/// Premium card: a crisp translucent fill, a hairline border and a soft
/// diffuse shadow. Deliberately NO backdrop blur — blur looked murky/cheap.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final BoxBorder? border;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.radius = AppDesign.radiusCard,
    this.onTap,
    this.gradient,
    this.border,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    final decoration = BoxDecoration(
      borderRadius: borderRadius,
      gradient: gradient ?? AppDesign.glassFill,
      border: border ?? Border.all(color: AppDesign.stroke),
      boxShadow: AppDesign.cardShadow(),
    );

    Widget content = Padding(padding: padding, child: child);

    // A transparent Material gives any inner InkWell / ListTile / Checkbox a
    // valid ink host without covering the card background behind it.
    content = Material(
      type: MaterialType.transparency,
      child: onTap == null
          ? content
          : InkWell(onTap: onTap, borderRadius: borderRadius, child: content),
    );

    return DecoratedBox(decoration: decoration, child: content);
  }
}

/// Glowing gradient primary button.
class GlowButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool expanded;
  final double height;

  const GlowButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.expanded = true,
    this.height = 52,
  });

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return SizedBox(
      width: expanded ? double.infinity : null,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          gradient: AppDesign.buttonGradient,
          boxShadow: enabled ? [AppDesign.blueGlow(alpha: 0.34)] : null,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
            child: Opacity(
              opacity: enabled ? 1 : 0.5,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (icon != null) ...[
                      Icon(icon, color: AppDesign.onBlue, size: 19),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppDesign.onBlue,
                        fontWeight: FontWeight.w700,
                        fontSize: 15.5,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill segmented control (e.g. Daily / Weekly / Monthly).
class PillTabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onSelect;
  final double height;

  const PillTabs({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelect,
    this.height = 44,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppDesign.isDark
            ? Colors.white.withValues(alpha: 0.05)
            : AppDesign.cardSoft,
        borderRadius: BorderRadius.circular(AppDesign.radiusPill),
        border: Border.all(color: AppDesign.stroke),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                onTap: () => onSelect(i),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                    gradient: i == selected ? AppDesign.buttonGradient : null,
                    boxShadow: i == selected
                        ? [AppDesign.blueGlow(alpha: 0.28, blur: 16)]
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        color: i == selected
                            ? AppDesign.onBlue
                            : AppDesign.textLo,
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Circular translucent icon chip (feature rows, quick actions).
class IconChip extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  const IconChip({super.key, required this.icon, this.size = 40, this.color});

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppDesign.blue;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: c.withValues(alpha: AppDesign.isDark ? 0.16 : 0.12),
        border: Border.all(color: c.withValues(alpha: 0.30)),
      ),
      child: Icon(
        icon,
        size: size * 0.46,
        color:
            color ?? (AppDesign.isDark ? AppDesign.blueBright : AppDesign.blue),
      ),
    );
  }
}

/// Small up/down trend chip (e.g. "+18%" green, "-6%" red).
class TrendChip extends StatelessWidget {
  final double percent;
  const TrendChip({super.key, required this.percent});

  @override
  Widget build(BuildContext context) {
    final up = percent >= 0;
    final color = up ? AppDesign.success : AppDesign.danger;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.trending_up : Icons.trending_down,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 3),
          Text(
            '${up ? '+' : ''}${percent.toStringAsFixed(0)}%',
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header with an optional trailing "View all" action.
class SectionHeader extends StatelessWidget {
  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              color: AppDesign.textHi,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
        if (actionLabel != null)
          GestureDetector(
            onTap: onAction,
            child: Text(
              actionLabel!,
              style: const TextStyle(
                color: AppDesign.blueBright,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }
}

/// Compact period selector used by the dashboard and history screens. Lists
/// the [ReportPeriod] presets; picking `Custom` opens a date-range picker and
/// reports the chosen range back through [onChanged].
class PeriodDropdown extends StatelessWidget {
  final ReportPeriod value;
  final DateTimeRange? customRange;
  final void Function(ReportPeriod period, DateTimeRange? customRange)
  onChanged;

  const PeriodDropdown({
    super.key,
    required this.value,
    this.customRange,
    required this.onChanged,
  });

  // Compact date stamp for the custom-range label (MM/DD, not full ISO), so
  // the picker stays short and does not wrap on narrow phones.
  static String _fmt(DateTime d) =>
      '${d.month.toString().padLeft(2, '0')}/'
      '${d.day.toString().padLeft(2, '0')}';

  String get _label {
    if (value == ReportPeriod.custom) {
      final r = customRange;
      return r == null ? 'Custom' : '${_fmt(r.start)}\u2013${_fmt(r.end)}';
    }
    return value.label;
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ReportPeriod>(
      initialValue: value,
      tooltip: 'Period',
      color: AppDesign.card,
      onSelected: (period) async {
        if (period != ReportPeriod.custom) {
          onChanged(period, null);
          return;
        }
        final now = DateTime.now();
        final picked = await showDateRangePicker(
          context: context,
          firstDate: DateTime(2020),
          lastDate: DateTime(now.year + 1, 12, 31),
          initialDateRange:
              customRange ??
              DateTimeRange(
                start: DateTime(
                  now.year,
                  now.month,
                  now.day,
                ).subtract(const Duration(days: 6)),
                end: DateTime(now.year, now.month, now.day),
              ),
        );
        if (picked != null) onChanged(ReportPeriod.custom, picked);
      },
      itemBuilder: (context) => [
        for (final p in ReportPeriod.values)
          PopupMenuItem<ReportPeriod>(value: p, child: Text(p.label)),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: AppDesign.card,
          borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          border: Border.all(color: AppDesign.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.date_range, size: 14, color: AppDesign.textLo),
            const SizedBox(width: 5),
            Text(
              _label,
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 2),
            Icon(Icons.expand_more, size: 14, color: AppDesign.textLo),
          ],
        ),
      ),
    );
  }
}
