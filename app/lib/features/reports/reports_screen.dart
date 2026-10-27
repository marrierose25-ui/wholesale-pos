import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';

class ReportsScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const ReportsScreen({super.key, required this.saleRepository});

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen> {
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _cashiers = [];
  bool _isLoading = true;
  String? _error;

  ReportPeriod _period = ReportPeriod.thisMonth;
  DateTimeRange? _customRange;

  @override
  void initState() {
    super.initState();
    loadReports();
  }

  DateRange? get _activeRange {
    if (_period == ReportPeriod.custom) {
      if (_customRange == null) return null;
      return DateRange.custom(_customRange!.start, _customRange!.end);
    }
    return _period.toDateRange();
  }

  Future<void> loadReports() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.saleRepository.getProductSalesSummary(period: _activeRange),
        widget.saleRepository.getCashierPerformance(period: _activeRange),
      ]);
      if (!mounted) return;
      setState(() {
        _products = results[0];
        _cashiers = results[1];
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
      loadReports();
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            TextButton(onPressed: loadReports, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadReports),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildPeriodBar(),
              const SizedBox(height: 24),
              LayoutBuilder(
                builder: (context, constraints) {
                  final productsCard = _buildProductsCard();
                  final cashiersCard = _buildCashiersCard();
                  if (constraints.maxWidth < 1000) {
                    return Column(
                      children: [
                        productsCard,
                        const SizedBox(height: 24),
                        cashiersCard,
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: productsCard),
                      const SizedBox(width: 24),
                      Expanded(child: cashiersCard),
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
                  loadReports();
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

  Widget _buildProductsCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                const IconChip(icon: Icons.inventory_2_rounded, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Top Products',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppDesign.textHi,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_products.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No completed sales in this period.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Product')),
                  DataColumn(label: Text('Qty'), numeric: true),
                  DataColumn(label: Text('Revenue'), numeric: true),
                ],
                rows: _products.map((row) {
                  // Cloud rows may omit or null a field (e.g. a product name
                  // that was renamed away), and money can arrive as a JSON
                  // double on web — normalise with num.toInt() and never a bare
                  // `as String`/`as int` cast, which throws on the PWA.
                  final revenue = (row['total_revenue'] as num?)?.toInt() ?? 0;
                  final qtyMilliunits =
                      (row['total_qty_milliunits'] as num?)?.toInt() ?? 0;
                  final lineCount = (row['line_count'] as num?)?.toInt() ?? 0;
                  final manualLines = qtyMilliunits == 0 && lineCount > 0;
                  return DataRow(
                    cells: [
                      DataCell(
                        Text(row['product_name_snapshot']?.toString() ?? ''),
                      ),
                      DataCell(
                        Text(
                          manualLines
                              ? '—'
                              : MoneyUtils.milliunitsToString(qtyMilliunits),
                        ),
                      ),
                      DataCell(Text(MoneyUtils.formatBr(revenue))),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCashiersCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                const IconChip(icon: Icons.people_alt_rounded, size: 38),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Cashier Performance',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: AppDesign.textHi,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_cashiers.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No completed sales in this period.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Cashier')),
                  DataColumn(label: Text('Sales'), numeric: true),
                  DataColumn(label: Text('Revenue'), numeric: true),
                ],
                rows: _cashiers.map((row) {
                  // A synced sale's cashier_id may not resolve to a pos_users
                  // row yet (the table is new), so `username` can be null —
                  // fall back to a label instead of a crashing `as String`.
                  final revenue = (row['total_revenue'] as num?)?.toInt() ?? 0;
                  final salesCount = (row['total_sales'] as num?)?.toInt() ?? 0;
                  return DataRow(
                    cells: [
                      DataCell(Text(row['username']?.toString() ?? 'Unknown')),
                      DataCell(Text('$salesCount')),
                      DataCell(Text(MoneyUtils.formatBr(revenue))),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
