import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import 'sales_by_day_screen.dart';

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
            TextButton(onPressed: loadDashboard, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadDashboard),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: RefreshIndicator(
          onRefresh: loadDashboard,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 32),
            children: [
              _buildPeriodSelector(),
              const SizedBox(height: 20),
              _buildHeroBalance(),
              const SizedBox(height: 16),
              _buildMetricGrid(),
            ],
          ),
        ),
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

  /// Big glowing balance figure at the top of the dashboard.
  Widget _buildHeroBalance() {
    final revenue = _stats['revenue'] ?? 0;
    final pct = _prevRevenue > 0
        ? (revenue - _prevRevenue) / _prevRevenue * 100
        : 0.0;
    return GlassCard(
      padding: const EdgeInsets.all(22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconChip(
                icon: Icons.account_balance_wallet_rounded,
                size: 38,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Total revenue',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (_prevRevenue > 0) TrendChip(percent: pct),
            ],
          ),
          const SizedBox(height: 16),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              MoneyUtils.formatBr(revenue),
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 40,
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _period.label,
            style: TextStyle(color: AppDesign.textFaint, fontSize: 12),
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
        Icons.check_circle_rounded,
        AppDesign.success,
        onTap: _openCompletedSalesByDay,
      ),
      _Metric(
        'Cash Collected',
        MoneyUtils.formatBr(_stats['cash_revenue'] ?? 0),
        Icons.payments_rounded,
        AppDesign.blue,
      ),
      _Metric(
        'Bank Collected',
        MoneyUtils.formatBr(_stats['bank_revenue'] ?? 0),
        Icons.account_balance_rounded,
        AppDesign.blueBright,
      ),
      _Metric(
        'Average / Sale',
        MoneyUtils.formatBr(_stats['average_sale'] ?? 0),
        Icons.trending_up_rounded,
        AppDesign.warning,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 12.0;
        final columns = constraints.maxWidth >= 560 ? 4 : 2;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final m in metrics)
              SizedBox(width: itemWidth, child: _buildMetricCard(m)),
          ],
        );
      },
    );
  }

  Widget _buildMetricCard(_Metric metric) {
    return GlassCard(
      padding: const EdgeInsets.all(14),
      radius: AppDesign.radiusCardSm,
      onTap: metric.onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(icon: metric.icon, size: 30, color: metric.color),
              const Spacer(),
              if (metric.onTap != null)
                Icon(
                  Icons.open_in_new_rounded,
                  size: 15,
                  color: AppDesign.textFaint,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            metric.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              metric.value,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w800,
                color: AppDesign.textHi,
                letterSpacing: -0.3,
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
