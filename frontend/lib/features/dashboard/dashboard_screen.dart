import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_contracts/pos_contracts.dart';

import '../../core/theme/app_design.dart';
import 'sales_by_day_screen.dart';

/// Dashboard screen — restyled with native Cupertino widgets and the shared
/// design-system components ([GlassCard], [IconChip], [TrendChip],
/// [FadeSlideIn], [PeriodDropdown], [IosLargeTitle]).
///
/// Logic is preserved verbatim: same fields, same methods, same data flow.
/// No repositories, models, or shell code are touched.
class DashboardScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User currentUser;

  const DashboardScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
  });

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class DashboardScreenState extends State<DashboardScreen> {
  Map<String, int> _stats = {};
  int _prevRevenue = 0;
  bool _isLoading = true;
  String? _error;

  ReportPeriod _period = ReportPeriod.today;
  DateTimeRange? _customRange;

  /// Watches for the local calendar date changing so "Today" rolls over at
  /// midnight without deleting or resetting anything — totals are recomputed
  /// by date filtering.
  Timer? _midnightWatcher;
  DateTime _watchedDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    loadDashboard();
    _midnightWatcher = Timer.periodic(const Duration(minutes: 1), (_) {
      final now = DateTime.now();
      if (now.year != _watchedDate.year ||
          now.month != _watchedDate.month ||
          now.day != _watchedDate.day) {
        _watchedDate = now;
        if (_period == ReportPeriod.today ||
            _period == ReportPeriod.yesterday) {
          loadDashboard();
        }
      }
    });
  }

  @override
  void dispose() {
    _midnightWatcher?.cancel();
    super.dispose();
  }

  DateRange? get _activeRange {
    if (_period == ReportPeriod.custom) {
      if (_customRange == null) return null;
      return DateRange.custom(_customRange!.start, _customRange!.end);
    }
    return _period.toDateRange();
  }

  Future<void> loadDashboard({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }

    try {
      final range = _activeRange ?? DateRange.today();
      final stats = await widget.saleRepository.getDashboardStats(
        userId: widget.currentUser.id,
        period: _activeRange,
      );
      // Comparison against the immediately preceding window of equal length
      // (for "Today" that is yesterday; for "This Week" last week, etc.).
      final duration = range.end.difference(range.start);
      final prevStats = await widget.saleRepository.getDashboardStats(
        userId: widget.currentUser.id,
        period: DateRange(
          start: range.start.subtract(duration),
          end: range.start,
        ),
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _prevRevenue = prevStats['revenue'] ?? 0;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  /// Opens the unified Sales History (the "Completed Sales" drill-down): every
  /// day's sales, searchable, each day opening its individual receipts.
  void _openCompletedSalesByDay() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SalesByDayScreen(
          saleRepository: widget.saleRepository,
          currentUser: widget.currentUser,
          onSaleVoided: () => loadDashboard(silent: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _stats.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _stats.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            CupertinoButton(
              onPressed: loadDashboard,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppDesign.bg,
      body: CustomScrollView(
        slivers: [
          IosLargeTitle.sliver(
            context,
            title: 'Dashboard',
            actions: [
              IconButton(
                icon: const Icon(CupertinoIcons.arrow_clockwise),
                onPressed: loadDashboard,
              ),
            ],
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                _buildPeriodSelector(),
                const SizedBox(height: 20),
                FadeSlideIn(
                  delay: const Duration(milliseconds: 60),
                  child: _buildHeroBalance(),
                ),
                const SizedBox(height: 16),
                _buildMetricGrid(),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// Compact day/week/month/… selector backed by the shared [PeriodDropdown].
  Widget _buildPeriodSelector() {
    return Align(
      alignment: Alignment.centerLeft,
      child: PeriodDropdown(
        value: _period,
        customRange: _customRange,
        onChanged: (period, range) {
          setState(() {
            _period = period;
            _customRange = range;
          });
          loadDashboard();
        },
      ),
    );
  }

  /// Big balance figure at the top of the dashboard.
  Widget _buildHeroBalance() {
    final revenue = _stats['revenue'] ?? 0;
    final pct = _prevRevenue > 0
        ? (revenue - _prevRevenue) / _prevRevenue * 100
        : 0.0;
    return GlassCard(
      padding: const EdgeInsets.all(28),
      radius: AppDesign.radiusCard,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 12,
          offset: const Offset(0, 4),
        ),
      ],
      border: Border.all(color: AppDesign.strokeStrong),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(
                icon: CupertinoIcons.money_dollar_circle,
                size: 42,
                color: AppDesign.blue,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Total Revenue',
                  style: TextStyle(
                    color: AppDesign.textFaint,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                    letterSpacing: 0.08,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // The figure and its trend share one baseline, so a wide card reads
          // as a single hero line instead of a number stranded on the left.
          // The selected period is already named by the chip above the card,
          // so it is not repeated underneath.
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    MoneyUtils.formatBr(revenue),
                    style: TextStyle(
                      color: AppDesign.textHi,
                      fontSize: 52,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -1.4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
              if (_prevRevenue > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 12, bottom: 10),
                  child: TrendChip(percent: pct),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The four headline figures under the hero card: how many sales completed,
  /// how much arrived in cash vs by bank transfer, and the average per sale.
  Widget _buildMetricGrid() {
    final metrics = <_Metric>[
      _Metric(
        'Completed Sales',
        '${_stats['sales_count'] ?? 0}',
        CupertinoIcons.list_bullet,
        AppDesign.success,
        onTap: _openCompletedSalesByDay,
      ),
      _Metric(
        'Cash Collected',
        MoneyUtils.formatBr(_stats['cash_revenue'] ?? 0),
        CupertinoIcons.creditcard,
        AppDesign.blue,
      ),
      _Metric(
        'Bank Collected',
        MoneyUtils.formatBr(_stats['bank_revenue'] ?? 0),
        CupertinoIcons.building_2_fill,
        AppDesign.blue,
      ),
      _Metric(
        'Average / Sale',
        MoneyUtils.formatBr(_stats['average_sale'] ?? 0),
        CupertinoIcons.arrow_up_right,
        AppDesign.warning,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 16.0;
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (int i = 0; i < metrics.length; i++)
              FadeSlideIn(
                delay: Duration(milliseconds: 80 + i * 50),
                child: SizedBox(
                  width: itemWidth,
                  child: _buildMetricCard(metrics[i]),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _buildMetricCard(_Metric metric) {
    final isActive = metric.onTap != null;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      radius: AppDesign.radiusCard,
      shadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 8,
          offset: const Offset(0, 2),
        ),
      ],
      border: Border.all(color: AppDesign.strokeStrong),
      onTap: metric.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(icon: metric.icon, size: 32, color: metric.color),
              const Spacer(),
              if (isActive)
                Icon(
                  CupertinoIcons.chevron_right,
                  size: 14,
                  color: AppDesign.textFaint,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            metric.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.0,
              letterSpacing: 0.08,
              fontFamily: AppDesign.fontData,
            ),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              metric.value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w700,
                color: metric.color,
                letterSpacing: -0.5,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One headline figure shown in the dashboard metric grid. Cards with an
/// [onTap] drill into a detail view and render a small affordance icon.
class _Metric {
  final String title;
  final String value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;

  const _Metric(this.title, this.value, this.icon, this.color, {this.onTap});
}
