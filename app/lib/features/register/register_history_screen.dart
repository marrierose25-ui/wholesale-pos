import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../dashboard/sales_by_day_screen.dart';
import 'cash_history_screen.dart';
import '../sales/shift.dart';

/// The single Register History view, opened from the Register screen's one
/// "Register History" button: every cash movement grouped by day, newest
/// first, with search and a period (date) picker. Tap a day to open that
/// day's compact register history (Sales / Credits / Debits tabs and the net
/// drawer change) in [RegisterDayScreen].
class RegisterHistoryScreen extends StatefulWidget {
  final ShiftRepository shiftRepository;
  final SaleRepository saleRepository;
  final User currentUser;

  const RegisterHistoryScreen({
    super.key,
    required this.shiftRepository,
    required this.saleRepository,
    required this.currentUser,
  });

  @override
  State<RegisterHistoryScreen> createState() => RegisterHistoryScreenState();
}

class RegisterHistoryScreenState extends State<RegisterHistoryScreen> {
  List<_MovementDayGroup> _days = [];

  /// Every movement, unfiltered — used so a tapped day always shows its
  /// complete picture (all types) even when a tab/search narrows the list.
  List<CashMovement> _all = [];
  bool _isLoading = true;
  String? _error;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  ReportPeriod _period = ReportPeriod.allTime;
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  bool get _hasActiveFilters =>
      _searchController.text.isNotEmpty || _period != ReportPeriod.allTime;

  /// The day window the period picker currently selects (null = all time).
  DateRange? get _activeWindow {
    if (_period == ReportPeriod.allTime) return null;
    final range = _period.toDateRange();
    if (range != null) return range;
    final custom = _customRange;
    if (custom == null) return null;
    return DateRange.custom(custom.start, custom.end);
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final movements = await widget.shiftRepository.getCashMovements(
        userId: widget.currentUser.id,
      );
      _all = movements;
      // Completed cash sales feed each day's net drawer change (money that
      // physically entered the drawer), so the card number matches the day
      // detail's "Net drawer change" rather than only the movement totals.
      final sales = await widget.saleRepository.getSales(
        userId: widget.currentUser.id,
        status: 'COMPLETED',
      );
      final cashByDay = <DateTime, int>{};
      for (final s in sales) {
        if (s.paymentMethod != 'CASH') continue;
        final t = s.createdAt;
        final key = DateTime(t.year, t.month, t.day);
        cashByDay[key] = (cashByDay[key] ?? 0) + s.totalMinorUnits;
      }
      final text = _searchController.text.trim().toLowerCase();
      final window = _activeWindow;
      final visible = movements.where((m) {
        if (window != null && !window.contains(m.createdAt)) {
          return false;
        }
        if (text.isNotEmpty) {
          final haystack = [
            m.reason,
            m.userName ?? '',
            MoneyUtils.formatBr(m.amountMinorUnits),
          ].join(' ').toLowerCase();
          if (!haystack.contains(text)) return false;
        }
        return true;
      }).toList();
      final buckets = <DateTime, List<CashMovement>>{};
      for (final m in visible) {
        final t = m.createdAt;
        (buckets[DateTime(t.year, t.month, t.day)] ??= []).add(m);
      }
      final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
      if (!mounted) return;
      setState(() {
        _days = [
          for (final k in keys)
            _MovementDayGroup(k, buckets[k]!, cashByDay[k] ?? 0),
        ];
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

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), load);
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _period = ReportPeriod.allTime;
      _customRange = null;
    });
    load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Register History'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: load),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            _buildFilterBar(),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search reason, user, amount...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        load();
                      },
                    ),
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (_) => load(),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              PeriodDropdown(
                value: _period,
                customRange: _customRange,
                onChanged: (period, range) {
                  setState(() {
                    _period = period;
                    _customRange = range;
                  });
                  load();
                },
              ),
              if (_hasActiveFilters)
                TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear Filters'),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _days.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _days.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            TextButton(onPressed: load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _hasActiveFilters
                ? 'No movements match these filters.'
                : 'No cash movements recorded yet.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppDesign.textLo),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => load(silent: true),
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        itemCount: _days.length,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final group = _days[index];
          return _MovementDayCard(group: group, onTap: () => _openDay(group));
        },
      ),
    );
  }

  void _openDay(_MovementDayGroup group) {
    // Always the complete day (ignores the active search filter).
    final dayMovements = _all.where((m) {
      final t = m.createdAt;
      return t.year == group.day.year &&
          t.month == group.day.month &&
          t.day == group.day.day;
    }).toList();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegisterDayScreen(
          saleRepository: widget.saleRepository,
          currentUser: widget.currentUser,
          day: group.day,
          movements: dayMovements,
        ),
      ),
    );
  }
}

/// One calendar day of cash movements plus that day's cash sales (for the net).
class _MovementDayGroup {
  final DateTime day;
  final List<CashMovement> movements;
  final int cashSalesMinorUnits;

  _MovementDayGroup(this.day, this.movements, this.cashSalesMinorUnits);

  /// Net drawer change: cash sales + credits − debits — the same figure the
  /// day detail reports, so the list and the drill-down always agree.
  int get netMinorUnits =>
      cashSalesMinorUnits +
      movements.fold(0, (sum, m) {
        return sum + (m.isDeposit ? m.amountMinorUnits : -m.amountMinorUnits);
      });
}

/// Level 1 row: the day, its movement count and its net.
class _MovementDayCard extends StatelessWidget {
  final _MovementDayGroup group;
  final VoidCallback onTap;

  const _MovementDayCard({required this.group, required this.onTap});

  String _relativeLabel() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(group.day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final relative = _relativeLabel();
    final countLabel =
        '${group.movements.length} movement${group.movements.length == 1 ? '' : 's'}';
    final net = group.netMinorUnits;
    final netColor = net > 0
        ? AppDesign.success
        : net < 0
        ? AppDesign.danger
        : AppDesign.textHi;
    final netText =
        '${net > 0
            ? '+'
            : net < 0
            ? '-'
            : ''}'
        '${MoneyUtils.formatBr(net.abs())}';
    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  SalesByDayScreen.formatDay(group.day),
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  relative.isEmpty ? countLabel : '$relative · $countLabel',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            netText,
            style: TextStyle(
              color: netColor,
              fontSize: 15,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            color: AppDesign.textFaint,
            size: 20,
          ),
        ],
      ),
    );
  }
}
