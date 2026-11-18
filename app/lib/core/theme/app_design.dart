import 'dart:ui' show ImageFilter;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../utils/date_range.dart';

/// iOS 17/18 design system — theme-aware.
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

  // ---- Brand accent + semantic colours ---------------------------------
  // iOS systemBlue. A single accent per view, per HIG.
  // Linear/Vercel indigo accent — replaces the old iOS systemBlue.
  static const Color blue = Color(0xFF4F46E5);
  // Brighter tint for icons/active labels on near-black surfaces.
  static const Color blueBright = Color(0xFF6366F1);
  static const Color blueDeep = Color(0xFF3730A3);
  static const Color onBlue = Colors.white;

  /// The accent to use for icons/labels sitting ON a surface.
  static Color get accent => isDark ? blueBright : blue;

  /// Neutral rounded fill behind a selected sidebar row — never a solid
  /// accent block.
  static Color get tertiaryFill =>
      isDark ? const Color(0x3D6B7280) : const Color(0x1F6B7280);

  // Linear/Vercel semantic palette: emerald-600 / red-600 / amber-600.
  static const Color success = Color(0xFF059669);
  static const Color danger = Color(0xFFDC2626);
  static const Color warning = Color(0xFFD97706);

  /// Solid accent — flat fill, no gradient.
  static const LinearGradient buttonGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [blue, blue],
  );

  // ---- Radii / spacing --------------------------------------------------
  static const double radiusCard = 12;
  static const double radiusCardSm = 8;
  static const double radiusPill = 999;
  static const double radiusButton = 100;

  /// iOS inset-grouped list corner radius (~10pt continuous).
  static const double radiusGrouped = 10;

  // ---- Signature background gradient (theme-aware) ---------------------
  static List<Color> get auroraColors => _p.aurora;

  /// A soft NEUTRAL shadow. Colored glows are a Material/fintech artifact —
  /// elevation is conveyed with black only.
  static BoxShadow blueGlow({double alpha = 0.30, double blur = 22}) {
    return BoxShadow(
      color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.04),
      blurRadius: 18,
      offset: const Offset(0, 6),
    );
  }

  /// Tight, soft card elevation — one contact shadow and a faint ambient
  /// lift. Direction B uses subtle 2+6px shadows with lower alpha.
  static List<BoxShadow> cardShadow({bool? dark}) {
    final isDark = dark ?? AppDesign.isDark;
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.05),
        blurRadius: 2,
        offset: const Offset(0, 1),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: isDark ? 0.30 : 0.06),
        blurRadius: 6,
        offset: const Offset(0, 4),
      ),
    ];
  }

  /// The card fill: a solid iOS surface (systemBackground /
  /// secondarySystemBackground), not a gradient.
  static LinearGradient get glassFill => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [_p.card, _p.card],
  );

  // ---- Direction B typography -------------------------------------------
  // Geist for body, Geist Mono for data/monetary values. Both ship as TTF
  // assets declared in pubspec.yaml, so the family names resolve offline on
  // every platform (Windows, Android, web) with no runtime fetch and no
  // google_fonts dependency. If the assets ever go missing the engine falls
  // back to the platform stack, which is why the app must never depend on
  // this for legibility.
  static const String fontBody = 'Geist';
  static const String fontData = 'Geist Mono';

  /// Body text style. Respects the active brightness for colour.
  static TextStyle body({Color? color, double? fontSize, FontWeight? weight}) =>
      TextStyle(
        color: color ?? textHi,
        fontSize: fontSize ?? 17,
        fontWeight: weight ?? FontWeight.w400,
        fontFamily: fontBody,
        height: 1.35,
      );

  /// Monospace data/monetary style. Tabular figures so money columns align.
  static TextStyle data({
    Color? color,
    double? fontSize,
    FontWeight? weight,
  }) => TextStyle(
    color: color ?? textHi,
    fontFamily: fontData,
    fontSize: fontSize ?? 14,
    fontWeight: weight ?? FontWeight.w500,
    fontFeatures: const [FontFeature.tabularFigures()],
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

/// iOS system colours: pure black grouped background in dark mode,
/// systemGroupedBackground (#F2F2F7) in light mode.
const AppPalette _darkPalette = AppPalette(
  brightness: Brightness.dark,
  bg: Color(0xFF000000),
  bgElevated: Color(0xFF1C1C1E),
  card: Color(0xFF1C1C1E),
  cardSoft: Color(0xFF2C2C2E),
  stroke: Color(0x1FFFFFFF), // white @ ~12%
  strokeStrong: Color(0x29FFFFFF), // white @ ~16%
  textHi: Color(0xFFFFFFFF),
  textLo: Color(0x99EBEBF5), // label secondary
  textFaint: Color(0x4DFFFFFF), // label tertiary
  aurora: [Color(0xFF000000), Color(0xFF000000), Color(0xFF000000)],
);

const AppPalette _lightPalette = AppPalette(
  brightness: Brightness.light,
  bg: Color(0xFFFAFAFA), // Linear/Vercel light canvas
  bgElevated: Color(0xFFFFFFFF),
  card: Color(0xFFFFFFFF),
  cardSoft: Color(0xFFF3F4F6),
  stroke: Color(0x14E5E7EB), // #E5E7EB @ ~8% — hairline card border
  strokeStrong: Color(0x26E5E7EB), // #E5E7EB @ ~15%
  textHi: Color(0xFF111827), // near-black, not pure black
  textLo: Color(0xFF6B7280), // gray-500
  textFaint: Color(0xFF9CA3AF), // gray-400
  aurora: [Color(0xFFFAFAFA), Color(0xFFFAFAFA), Color(0xFFFAFAFA)],
);

/// Full-bleed app background with a soft accent bloom. Wrap screen bodies in
/// this to get the signature look behind the content.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    // Flat monochrome systemGroupedBackground — iOS chrome has no bloom.
    return DecoratedBox(
      decoration: BoxDecoration(color: AppDesign.bg),
      child: child,
    );
  }
}

/// Premium card: white fill with subtle border and soft shadow.
/// Direction B aesthetic — Linear/Vercel clean card surface.
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Gradient? gradient;
  final BoxBorder? border;

  /// Overrides the default neutral [AppDesign.cardShadow] — hero surfaces
  /// use this for a soft accent-tinted glow.
  final List<BoxShadow>? shadow;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(22),
    this.radius = AppDesign.radiusCard,
    this.onTap,
    this.gradient,
    this.border,
    this.shadow,
  });

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    // Direction B separates cards with a hairline border (#E5E7EB) instead of
    // relying on tone alone — the Linear/Vercel aesthetic uses outlines.
    final effectiveBorder =
        border ??
        (AppDesign.isDark
            ? null
            : Border.all(color: AppDesign.strokeStrong, width: 1));
    final decoration = BoxDecoration(
      borderRadius: borderRadius,
      gradient: gradient ?? AppDesign.glassFill,
      border: effectiveBorder,
      boxShadow: shadow ?? AppDesign.cardShadow(),
    );

    Widget content = Padding(padding: padding, child: child);

    // A transparent Material gives any inner InkWell / ListTile / Checkbox a
    // valid ink host without covering the card background behind it.
    // Direction B: cards use subtle borders + shadows, not frosted glass.
    // No backdrop blur. Tap handled by [Pressable].
    content = Material(
      type: MaterialType.transparency,
      child: onTap == null ? content : Pressable(onTap: onTap, child: content),
    );

    return DecoratedBox(decoration: decoration, child: content);
  }
}

/// iOS press feedback: a subtle 98% scale-down while touched, springing back
/// on release. Wrap any tappable surface in this instead of a bare
/// GestureDetector/InkWell when ripple feedback would look off-platform.
class Pressable extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final BorderRadius? borderRadius;

  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.borderRadius,
  });

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable>
    with SingleTickerProviderStateMixin {
  /// One controller drives the whole press: tweened down fast on touch-down,
  /// then sprung back to rest on release — the subtle physical "give" iOS
  /// buttons have. Under-damped just enough for a 3–4% overshoot.
  late final AnimationController _scale = AnimationController(
    vsync: this,
    value: 1,
  );

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _setPressed(bool value) {
    // A null onTap means "disabled": no press feedback, matching button
    // convention everywhere else in the app.
    if (widget.onTap == null) return;
    if (value) {
      _scale.animateTo(
        0.97,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scale.animateWith(
        SpringSimulation(
          const SpringDescription(mass: 1, stiffness: 420, damping: 30),
          _scale.value,
          1,
          0,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      onTapDown: (_) => _setPressed(true),
      onTapUp: (_) => _setPressed(false),
      onTapCancel: () => _setPressed(false),
      child: AnimatedBuilder(
        animation: _scale,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}

/// iOS filled (systemBlue) pill button — flat fill, no glow, press-scale.
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
    return Pressable(
      onTap: onPressed,
      child: SizedBox(
        width: expanded ? double.infinity : null,
        height: height,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
            gradient: AppDesign.buttonGradient,
          ),
          child: Material(
            type: MaterialType.transparency,
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          // The selection pill slides to the tapped segment instead of
          // snapping — iOS segmented-control motion. Each Expanded label
          // occupies exactly one segment width, so the pill's left/width
          // track the same geometry.
          final segmentWidth = (constraints.maxWidth - 8) / labels.length;
          // `selected` may be -1 to mean "nothing chosen yet" (the New Sale
          // payment step starts unselected). The pill must then be invisible
          // and parked on the first segment rather than sliding off the
          // control: `left` is clamped so no segment is ever half-covered.
          final bool anySelected = selected >= 0;
          final int pillIndex = anySelected ? selected : 0;
          return Stack(
            children: [
              AnimatedPositioned(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                left: pillIndex * segmentWidth,
                top: 0,
                bottom: 0,
                width: segmentWidth,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 160),
                  opacity: anySelected ? 1 : 0,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                      color: AppDesign.blue,
                    ),
                  ),
                ),
              ),
              Row(
                children: [
                  for (var i = 0; i < labels.length; i++)
                    Expanded(
                      child: Pressable(
                        onTap: () => onSelect(i),
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 180),
                            style: TextStyle(
                              color: i == selected
                                  ? AppDesign.onBlue
                                  : AppDesign.textLo,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                            child: Text(labels[i]),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
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
        color: c.withValues(alpha: AppDesign.isDark ? 0.16 : 0.10),
        border: Border.all(color: c.withValues(alpha: 0.20)),
      ),
      child: Icon(icon, size: size * 0.46, color: color ?? AppDesign.accent),
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
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up
                ? CupertinoIcons.arrow_up_right
                : CupertinoIcons.arrow_down_right,
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
          Pressable(
            onTap: onAction,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                actionLabel!,
                style: TextStyle(
                  color: AppDesign.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
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
            Icon(CupertinoIcons.calendar, size: 14, color: AppDesign.textLo),
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
            Icon(
              CupertinoIcons.chevron_down,
              size: 12,
              color: AppDesign.textLo,
            ),
          ],
        ),
      ),
    );
  }
}

/// One-shot entrance: fade + a few-pixel rise with an ease-out settle, the
/// quiet motion iOS lists use when content arrives. Purely visual — the
/// widget occupies its final layout box from the first frame, so wrapping a
/// list item never shifts its neighbours. [delay] staggers siblings.
class FadeSlideIn extends StatefulWidget {
  final Widget child;
  final Duration delay;
  final Duration duration;

  const FadeSlideIn({
    super.key,
    required this.child,
    this.delay = Duration.zero,
    this.duration = const Duration(milliseconds: 340),
  });

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final Animation<double> _opacity = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOut,
  );
  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, 0.05),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));

  @override
  void initState() {
    super.initState();
    if (widget.delay == Duration.zero) {
      _controller.forward();
    } else {
      Future<void>.delayed(widget.delay, () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// iOS large-title navigation header, used as a pinned sliver inside a
/// [CustomScrollView]. The 34pt title sits in an expanded zone below the nav
/// row; scrolling collapses the header to a frosted 44pt bar whose small
/// title fades in — the same motion as UINavigationBar with
/// .largeTitleDisplayMode(.automatic).
///
/// Usage inside `slivers:`:
/// ```dart
/// IosLargeTitle.sliver(context,
///     title: 'Dashboard',
///     actions: [IconButton(...)])
/// ```
class IosLargeTitle {
  IosLargeTitle._();

  static const double _navHeight = 44;
  static const double _largeHeight = 56;

  static Widget sliver(
    BuildContext context, {
    required String title,
    List<Widget> actions = const [],
  }) {
    return SliverPersistentHeader(
      pinned: true,
      delegate: _IosLargeTitleDelegate(
        title: title,
        actions: actions,
        topPad: MediaQuery.paddingOf(context).top,
      ),
    );
  }
}

class _IosLargeTitleDelegate extends SliverPersistentHeaderDelegate {
  _IosLargeTitleDelegate({
    required this.title,
    required this.actions,
    required this.topPad,
  });

  final String title;
  final List<Widget> actions;
  final double topPad;

  static const double _navH = IosLargeTitle._navHeight;
  static const double _largeH = IosLargeTitle._largeHeight;

  @override
  double get minExtent => topPad + _navH;

  @override
  double get maxExtent => topPad + _navH + _largeH;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final t = (shrinkOffset / _largeH).clamp(0.0, 1.0);
    // Smoothstep so the crossfade eases at both ends like UIKit's.
    final s = t * t * (3 - 2 * t);
    final isDark = AppDesign.isDark;

    // The collapsed bar materialises: grouped-background tint fades in over
    // the blur as the large title collapses into it.
    final scrimAlpha = isDark ? 0.55 + 0.40 * s : 0.60 + 0.35 * s;
    final scrim = isDark ? _darkPalette.card : _lightPalette.bg;

    // The large title shrinks toward its bottom-left corner — the iOS
    // collapse — while the small bar title fades in at the top.
    final largeOpacity = s < 0.65
        ? 1.0
        : (1 - (s - 0.65) / 0.35).clamp(0.0, 1.0);

    return ClipRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
        child: Container(
          color: scrim.withValues(alpha: scrimAlpha),
          padding: EdgeInsets.only(top: topPad),
          child: SizedBox(
            height: _navH + _largeH,
            child: Stack(
              children: [
                // Small collapsed title, left-aligned like the old AppBar.
                Positioned(
                  left: 16,
                  right: 72,
                  top: 0,
                  height: _navH,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Opacity(
                      opacity: s,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppDesign.textHi,
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                          letterSpacing: -0.3,
                        ),
                      ),
                    ),
                  ),
                ),
                // Large title: 34pt bold, tight tracking, collapses upward.
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 6,
                  child: Opacity(
                    opacity: largeOpacity,
                    child: Transform.scale(
                      scale: 1 - 0.45 * s,
                      alignment: Alignment.bottomLeft,
                      child: Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: AppDesign.textHi,
                          fontSize: 34,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.8,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
                // Trailing actions stay in the nav zone, always visible —
                // same slot the old AppBar actions occupied.
                Positioned(
                  right: 4,
                  top: 0,
                  height: _navH,
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
                // Hairline separator that fades in once collapsed.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: _largeH - 0.5,
                  child: Opacity(
                    opacity: s,
                    child: Container(height: 0.5, color: AppDesign.stroke),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(_IosLargeTitleDelegate oldDelegate) => true;
}
