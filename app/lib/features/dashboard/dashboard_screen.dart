import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';

class DashboardScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const DashboardScreen({super.key, required this.saleRepository});

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
      // Comparison against the immediately preceding window of equal length
      // (for "Today" that is yesterday; for "This Week" last week, etc.).
      final duration = range.end.difference(range.start);
      final prevStats = await widget.saleRepository.getDashboardStats(
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
            'Revenue from completed sales only. This app does not track '
            'costs, so revenue is not profit.',
            style: TextStyle(color: AppDesign.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
