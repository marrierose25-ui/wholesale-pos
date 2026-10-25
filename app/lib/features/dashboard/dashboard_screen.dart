import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../sales/sale.dart';
import 'widgets/dashboard_charts.dart';

class DashboardScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const DashboardScreen({super.key, required this.saleRepository});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  Map<String, int> _stats = {};
  List<Sale> _recentSales = [];
  List<TrendPoint> _trend = [];
  List<Map<String, dynamic>> _topProducts = [];
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

  Future<void> loadDashboard() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final range = _activeRange ?? DateRange.today();
      final stats = await widget.saleRepository.getDashboardStats(
        period: _activeRange,
      );
      final recent = await widget.saleRepository.getRecentSales(limit: 6);
      // Comparison against the immediately preceding window of equal length
      // (for "Today" that is yesterday; for "This Week" last week, etc.).
      final duration = range.end.difference(range.start);
      final prevStats = await widget.saleRepository.getDashboardStats(
        period: DateRange(
          start: range.start.subtract(duration),
          end: range.start,
        ),
      );
      final trendRows = await widget.saleRepository.getRevenueTrend(range);
      final topProducts = await widget.saleRepository.getProductSalesSummary(
        period: range,
      );
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _recentSales = recent;
        _prevRevenue = prevStats['revenue'] ?? 0;
        _trend = trendRows.map(TrendPoint.fromRow).toList();
        _topProducts = topProducts;
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

  Future<void> _pickCustomRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange:
          _customRange ??
          DateTimeRange(
            start: DateTime(
              now.year,
              now.month,
              now.day,
            ).subtract(const Duration(days: 6)),
            end: DateTime(now.year, now.month, now.day),
          ),
    );
    if (picked != null) {
      setState(() {
        _period = ReportPeriod.custom;
        _customRange = picked;
      });
      loadDashboard();
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
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
              _buildHeroBalance(),
              const SizedBox(height: 20),
              _buildPeriodBar(),
              const SizedBox(height: 20),
              _buildStatGrid(),
              const SizedBox(height: 20),
              _buildComparisonStrip(),
              const SizedBox(height: 24),
              DashboardPanel(
                title: 'Revenue Trend',
                subtitle: _periodLabel,
                child: RevenueTrendChart(points: _trend),
              ),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) {
                  final split = DashboardPanel(
                    title: 'Payment Split',
                    subtitle: 'Cash vs bank collections',
                    child: PaymentSplitBar(
                      cashMinorUnits: _stats['cash_revenue'] ?? 0,
                      bankMinorUnits: _stats['bank_revenue'] ?? 0,
                    ),
                  );
                  final top = DashboardPanel(
                    title: 'Top Products',
                    subtitle: 'By revenue',
                    child: TopProductsBar(rows: _topProducts),
                  );
                  if (constraints.maxWidth < 800) {
                    return Column(
                      children: [split, const SizedBox(height: 16), top],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: split),
                      const SizedBox(width: 16),
                      Expanded(child: top),
                    ],
                  );
                },
              ),
              const SizedBox(height: 24),
              LayoutBuilder(
                builder: (context, constraints) {
                  final recentCard = _buildRecentSalesCard();
                  final statusCard = _buildStatusCard();
                  if (constraints.maxWidth < 900) {
                    return Column(
                      children: [
                        recentCard,
                        const SizedBox(height: 24),
                        statusCard,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 2, child: recentCard),
                      const SizedBox(width: 24),
                      Expanded(child: statusCard),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _periodLabel {
    if (_period == ReportPeriod.custom) {
      if (_customRange == null) return 'No custom range selected';
      return '${_formatDate(_customRange!.start)} - '
          '${_formatDate(_customRange!.end)}';
    }
    return _period.label;
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
            'Revenue from completed sales only. This app does not track '
            'costs, so revenue is not profit.',
            style: TextStyle(color: AppDesign.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// Responsive grid of glass stat tiles.
  Widget _buildStatGrid() {
    final tiles = <Widget>[
      _buildStatCard(
        'Completed Sales',
        '${_stats['sales_count'] ?? 0}',
        Icons.receipt_long_rounded,
      ),
      _buildStatCard(
        'Cash Collected',
        MoneyUtils.formatBr(_stats['cash_revenue'] ?? 0),
        Icons.payments_rounded,
        color: AppDesign.success,
      ),
      _buildStatCard(
        'Bank Collected',
        MoneyUtils.formatBr(_stats['bank_revenue'] ?? 0),
        Icons.account_balance_rounded,
      ),
      _buildStatCard(
        'Average per Sale',
        MoneyUtils.formatBr(_stats['average_sale'] ?? 0),
        Icons.trending_up_rounded,
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 720 ? 4 : 2;
        const spacing = 14.0;
        final itemWidth =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: tiles
              .map((t) => SizedBox(width: itemWidth, child: t))
              .toList(),
        );
      },
    );
  }

  /// A compact strip of comparison metrics: revenue vs the previous period,
  /// voids, pending void requests, and average per sale.
  Widget _buildComparisonStrip() {
    final revenue = _stats['revenue'] ?? 0;
    final delta = revenue - _prevRevenue;
    final String deltaText;
    final Color deltaColor;
    if (_prevRevenue == 0 && revenue == 0) {
      deltaText = 'No sales yet';
      deltaColor =
          Theme.of(context).textTheme.bodySmall?.color ?? AppTheme.muted;
    } else if (_prevRevenue == 0) {
      deltaText = 'New (prev: ${MoneyUtils.formatBr(0)})';
      deltaColor = AppTheme.success;
    } else {
      final pct = (delta / _prevRevenue * 100).abs().toStringAsFixed(0);
      final up = delta >= 0;
      deltaText =
          '${up ? '▲' : '▼'} ${MoneyUtils.formatBr(delta.abs())} '
          '($pct% ${up ? 'up' : 'down'})';
      deltaColor = up ? AppTheme.success : AppTheme.danger;
    }

    final voidCount = _stats['void_count'] ?? 0;
    final pendingCount = _stats['pending_void_requests'] ?? 0;

    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Wrap(
          spacing: 24,
          runSpacing: 12,
          children: [
            _ComparisonItem(
              label: 'vs $_previousPeriodLabel',
              value: deltaText,
              valueColor: deltaColor,
            ),
            _ComparisonItem(
              label: 'Voided Sales',
              value: '$voidCount',
              valueColor: voidCount > 0 ? AppTheme.danger : null,
            ),
            _ComparisonItem(
              label: 'Pending Void Requests',
              value: '$pendingCount',
              valueColor: pendingCount > 0 ? AppTheme.warning : null,
            ),
            _ComparisonItem(
              label: 'Average per Sale',
              value: MoneyUtils.formatBr(_stats['average_sale'] ?? 0),
            ),
          ],
        ),
      ),
    );
  }

  String get _previousPeriodLabel {
    switch (_period) {
      case ReportPeriod.today:
        return 'yesterday';
      case ReportPeriod.yesterday:
        return '2 days ago';
      case ReportPeriod.thisWeek:
        return 'last week';
      case ReportPeriod.thisMonth:
        return 'last month';
      case ReportPeriod.thisYear:
        return 'last year';
      case ReportPeriod.allTime:
        return 'previous';
      case ReportPeriod.custom:
        return 'previous period';
    }
  }

  Widget _buildPeriodBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        ...ReportPeriod.values
            .where((p) => p != ReportPeriod.custom)
            .map(
              (period) => ChoiceChip(
                label: Text(period.label),
                selected: _period == period,
                onSelected: (_) {
                  setState(() => _period = period);
                  loadDashboard();
                },
              ),
            ),
        ActionChip(
          avatar: Icon(
            Icons.date_range,
            size: 16,
            color: _period == ReportPeriod.custom
                ? Colors.white
                : AppTheme.foreground,
          ),
          label: Text(
            _period == ReportPeriod.custom && _customRange != null
                ? '${_formatDate(_customRange!.start)} - '
                      '${_formatDate(_customRange!.end)}'
                : 'Custom',
          ),
          onPressed: _pickCustomRange,
        ),
      ],
    );
  }

  String _saleHeadline(Sale sale) {
    if (sale.items.isEmpty) return 'Sale';
    final names = sale.items.map((item) => item.productNameSnapshot).toList();
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]}, ${names[1]}';
    return '${names.first} +${names.length - 1} more';
  }

  Widget _buildRecentSalesCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Recent Sales',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          if (_recentSales.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No sales recorded yet.',
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            )
          else
            ..._recentSales.map(
              (sale) => ListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 8,
                ),
                dense: true,
                leading: CircleAvatar(
                  backgroundColor: sale.status == 'VOIDED'
                      ? Colors.grey
                      : Theme.of(context).scaffoldBackgroundColor,
                  child: Icon(
                    Icons.shopping_basket_outlined,
                    color: sale.status == 'VOIDED'
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
                    size: 20,
                  ),
                ),
                title: Text(
                  _saleHeadline(sale),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 14,
                  ),
                ),
                subtitle: Text(
                  '${sale.createdAt.toString().split('.')[0]}'
                  ' • ${sale.cashierName ?? 'Unknown'}',
                  style: const TextStyle(fontSize: 12),
                ),
                trailing: Text(
                  MoneyUtils.formatBr(sale.totalMinorUnits),
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    decoration: sale.status == 'VOIDED'
                        ? TextDecoration.lineThrough
                        : null,
                    color: sale.status == 'VOIDED'
                        ? Colors.grey
                        : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final isOpen = (_stats['is_shift_open'] ?? 0) == 1;
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Register Status',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  color: isOpen ? AppTheme.success : AppTheme.danger,
                  size: 12,
                ),
                const SizedBox(width: 8),
                Text(
                  isOpen ? 'Register Open' : 'Register Closed',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isOpen
                  ? 'Expected Cash: '
                        '${MoneyUtils.formatBr(_stats['expected_cash'] ?? 0)}'
                  : 'Open the register to start recording cash sales.',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    IconData icon, {
    Color? color,
  }) {
    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(icon: icon, size: 34, color: color),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ComparisonItem extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _ComparisonItem({
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).textTheme.bodySmall?.color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: valueColor ?? Theme.of(context).colorScheme.onSurface,
          ),
        ),
      ],
    );
  }
}
