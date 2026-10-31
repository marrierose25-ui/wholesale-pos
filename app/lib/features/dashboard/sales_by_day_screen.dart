import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../sales/sale.dart';
import '../sales/sale_details.dart';

/// The single Sales History view: every sale grouped by day, newest first.
///
/// Search by product / customer / cashier / quantity / notes, narrow to a date
/// with the period picker, and filter All / Completed / Voided. Tap a day to
/// open that day's sales in detail; tap a sale for its full receipt with the
/// Void / Request-Void action. This replaces the old flat History ledger and is
/// the same view the Dashboard's "Completed Sales" card drills into.
///
/// A day's money figure counts only cash + bank *completed* sales — loans
/// collect nothing and voided sales are reversed — so the rollups tie to the
/// dashboard revenue KPI even though the day's list still records those sales.
class SalesByDayScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User currentUser;

  /// Fires after a sale is voided so the shell can refresh its other screens.
  final VoidCallback? onSaleVoided;

  const SalesByDayScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
    this.onSaleVoided,
  });

  /// '27 October 2026' — the day-heading format the whole drill-down uses.
  static String formatDay(DateTime day) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return '${day.day} ${months[day.month - 1]} ${day.year}';
  }

  @override
  State<SalesByDayScreen> createState() => SalesByDayScreenState();
}

class SalesByDayScreenState extends State<SalesByDayScreen> {
  List<_DayGroup> _days = [];
  bool _isLoading = true;
  String? _error;

  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;

  int _tab = 0;
  static const _tabLabels = ['All', 'Completed', 'Voided'];
  static const _tabStatuses = ['ALL', 'COMPLETED', 'VOIDED'];

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

  DateRange get _activeRange {
    if (_period == ReportPeriod.custom) {
      final range = _customRange;
      if (range == null) return DateRange.allTime();
      return DateRange.custom(range.start, range.end);
    }
    return _period.toDateRange() ?? DateRange.allTime();
  }

  bool get _hasActiveFilters =>
      _searchController.text.isNotEmpty ||
      _period != ReportPeriod.allTime ||
      _tab != 0;

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final text = _searchController.text.trim();
      final sales = await widget.saleRepository.getSales(
        userId: widget.currentUser.id,
        searchQuery: text.isEmpty ? null : text,
        period: _activeRange,
        status: _tabStatuses[_tab],
      );
      final buckets = <DateTime, List<Sale>>{};
      for (final sale in sales) {
        final t = sale.createdAt;
        (buckets[DateTime(t.year, t.month, t.day)] ??= []).add(sale);
      }
      final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
      if (!mounted) return;
      setState(() {
        _days = [for (final k in keys) _DayGroup(k, buckets[k]!)]
          ..sort((a, b) => b.day.compareTo(a.day));
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
      _tab = 0;
    });
    load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Sales History'),
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
          PillTabs(
            labels: _tabLabels,
            selected: _tab,
            onSelect: (i) {
              setState(() => _tab = i);
              load();
            },
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search product, customer, cashier, quantity, notes...',
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
                ? 'No sales match these filters.'
                : 'No sales recorded yet.',
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
          return _DayCard(group: group, onTap: () => _openDay(group));
        },
      ),
    );
  }

  void _openDay(_DayGroup group) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DaySalesScreen(
          saleRepository: widget.saleRepository,
          currentUser: widget.currentUser,
          day: group.day,
          sales: group.sales,
          onVoided: () {
            widget.onSaleVoided?.call();
            load(silent: true);
          },
        ),
      ),
    );
  }
}

/// One calendar day of sales.
class _DayGroup {
  final DateTime day;
  final List<Sale> sales;

  _DayGroup(this.day, this.sales);

  /// Money actually collected that day: completed cash + bank only. Loans
  /// collect nothing and voided sales are reversed, so both stay out.
  int get collectedMinorUnits => sales
      .where(
        (s) =>
            s.status == 'COMPLETED' &&
            (s.paymentMethod == 'CASH' || s.paymentMethod == 'BANK'),
      )
      .fold(0, (sum, s) => sum + s.totalMinorUnits);
}

/// Level 1 row: the day, its sale count and its collected total.
class _DayCard extends StatelessWidget {
  final _DayGroup group;
  final VoidCallback onTap;

  const _DayCard({required this.group, required this.onTap});

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
        '${group.sales.length} sale${group.sales.length == 1 ? '' : 's'}';
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
            MoneyUtils.formatBr(group.collectedMinorUnits),
            style: TextStyle(
              color: AppDesign.textHi,
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

/// Level 2: a compact ledger of the day's sales, newest first — one row per
/// sale with Item / Quantity / Unit Price / Total columns, like the old flat
/// history ledger. Tapping a row opens the shared Sale Details popup (with
/// Void / Request-Void).
class DaySalesScreen extends StatelessWidget {
  final SaleRepository saleRepository;
  final User currentUser;
  final DateTime day;
  final List<Sale> sales;
  final VoidCallback? onVoided;

  const DaySalesScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
    required this.day,
    required this.sales,
    this.onVoided,
  });

  @override
  Widget build(BuildContext context) {
    final ordered = [...sales]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final collected = ordered
        .where(
          (s) =>
              s.status == 'COMPLETED' &&
              (s.paymentMethod == 'CASH' || s.paymentMethod == 'BANK'),
        )
        .fold(0, (sum, s) => sum + s.totalMinorUnits);
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(SalesByDayScreen.formatDay(day))),
      body: AppBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${ordered.length} sale${ordered.length == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: AppDesign.textLo,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    MoneyUtils.formatBr(collected),
                    style: TextStyle(
                      color: AppDesign.textHi,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            // Bold column captions aligned with the ledger rows below.
            const SaleLedgerHeader(),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
                itemCount: ordered.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final sale = ordered[index];
                  return SaleLedgerRow(
                    sale: sale,
                    onTap: () => showSaleDetails(
                      context: context,
                      sale: sale,
                      repository: saleRepository,
                      currentUser: currentUser,
                      onChanged: onVoided,
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bold Item / Quantity / Unit Price / Total captions that sit above a list of
/// [SaleLedgerRow]s so the fixed columns read as a ledger.
class SaleLedgerHeader extends StatelessWidget {
  const SaleLedgerHeader({super.key});

  static Widget _cell(String label, TextAlign align, {double? width}) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        textAlign: align,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppDesign.textLo,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
      child: Row(
        children: [
          const SizedBox(width: 34),
          Expanded(child: _cell('Item', TextAlign.start)),
          _cell('Quantity', TextAlign.end, width: 64),
          _cell('Unit Price', TextAlign.end, width: 78),
          const SizedBox(width: 8),
          _cell('Total', TextAlign.end, width: 90),
        ],
      ),
    );
  }
}

/// One ledger line: time · item · quantity · unit price · total. Voided sales
/// are greyed with a strike-through. Shared by the Dashboard's day drill-down
/// and the Register History day screen so both list sales identically.
class SaleLedgerRow extends StatelessWidget {
  final Sale sale;
  final VoidCallback? onTap;

  const SaleLedgerRow({super.key, required this.sale, this.onTap});

  String get _time {
    final t = sale.createdAt;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isVoided = sale.status == 'VOIDED';
    final item = sale.items.isNotEmpty ? sale.items.first : null;
    final color = isVoided ? Colors.grey : AppDesign.textHi;
    final decoration = isVoided ? TextDecoration.lineThrough : null;

    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: EdgeInsets.zero,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            SizedBox(
              width: 34,
              child: Text(
                _time,
                style: TextStyle(fontSize: 11.5, color: AppDesign.textLo),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  // Expanded (not Flexible) so the name gives room to the
                  // VOID/REQ badge and the "+N" count before ellipsizing.
                  Expanded(
                    child: Text(
                      item?.productNameSnapshot ?? 'Sale',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: color,
                        decoration: decoration,
                      ),
                    ),
                  ),
                  if (sale.items.length > 1) ...[
                    const SizedBox(width: 4),
                    Text(
                      '+${sale.items.length - 1}',
                      style: TextStyle(fontSize: 11, color: AppDesign.textLo),
                    ),
                  ],
                  if (!isVoided && sale.hasPendingVoidRequest) ...[
                    const SizedBox(width: 6),
                    const _MiniBadge('REQ', color: AppDesign.danger),
                  ],
                  // Voided rows need no badge: grey + strike-through already
                  // mark them, and the fixed columns must leave the item name
                  // room at phone width.
                ],
              ),
            ),
            SizedBox(
              width: 64,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  item?.quantityText ?? '-',
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
            ),
            SizedBox(
              width: 78,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  item == null
                      ? '-'
                      : MoneyUtils.formatBr(item.unitPriceSnapshotMinorUnits),
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: 12, color: color),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text(
                  MoneyUtils.formatBr(sale.totalMinorUnits),
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color,
                    decoration: decoration,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A tiny inline status badge (VOID / REQ) used in the day list rows.
class _MiniBadge extends StatelessWidget {
  final String text;
  final Color color;

  const _MiniBadge(this.text, {required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
