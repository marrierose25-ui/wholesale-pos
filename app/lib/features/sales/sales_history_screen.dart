import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import 'sale.dart';

class SalesHistoryScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User currentUser;
  final VoidCallback onSaleVoided;

  const SalesHistoryScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
    required this.onSaleVoided,
  });

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<Sale> _sales = [];
  bool _isLoading = true;
  String? _error;
  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  ReportPeriod _period = ReportPeriod.allTime;
  DateTimeRange? _customRange;
  String _status = 'ALL';

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  DateRange? get _activeRange {
    if (_period == ReportPeriod.custom) {
      if (_customRange == null) return null;
      return DateRange.custom(_customRange!.start, _customRange!.end);
    }
    return _period.toDateRange();
  }

  Future<void> _loadSales() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final sales = await widget.saleRepository.getSales(
        searchQuery: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        period: _activeRange,
        status: _status,
      );
      if (!mounted) return;
      setState(() {
        _sales = sales;
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
    _searchDebounce = Timer(const Duration(milliseconds: 350), _loadSales);
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
      _loadSales();
    }
  }

  void _selectPeriod(ReportPeriod period) {
    setState(() => _period = period);
    _loadSales();
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() {
      _period = ReportPeriod.allTime;
      _customRange = null;
      _status = 'ALL';
    });
    _loadSales();
  }

  bool get _hasActiveFilters =>
      _searchController.text.isNotEmpty ||
      _period != ReportPeriod.allTime ||
      _status != 'ALL';

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime date) {
    return '${_formatDate(date)} '
        '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
  }

  /// Short human summary of a sale for list rows: the entered product names.
  String _saleHeadline(Sale sale) {
    if (sale.items.isEmpty) return 'Sale';
    final names = sale.items.map((item) => item.productNameSnapshot).toList();
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]}, ${names[1]}';
    return '${names.first}, ${names[1]} +${names.length - 2} more';
  }

  Future<bool> _voidSale(Sale sale) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _VoidSaleDialog(),
    );
    if (reason == null || !mounted) return false;

    try {
      await widget.saleRepository.voidSale(
        sale.id,
        widget.currentUser.id,
        reason,
      );
      widget.onSaleVoided();
      await _loadSales();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
      return false;
    }
  }

  Future<bool> _requestVoid(Sale sale) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => const _VoidSaleDialog(requestMode: true),
    );
    if (reason == null || !mounted) return false;

    try {
      await widget.saleRepository.requestVoid(
        sale.id,
        widget.currentUser.id,
        reason,
      );
      widget.onSaleVoided();
      await _loadSales();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
      return false;
    }
  }

  Future<void> _showSaleDetails(Sale sale) async {
    final isVoided = sale.status == 'VOIDED';
    final isOwner = widget.currentUser.role == 'OWNER';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            const Flexible(child: Text('Sale Details')),
            if (isVoided) ...[
              const SizedBox(width: 8),
              const Chip(label: Text('VOIDED')),
            ] else if (sale.hasPendingVoidRequest) ...[
              const SizedBox(width: 8),
              const Chip(label: Text('VOID REQUESTED')),
            ],
          ],
        ),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _detailRow('Date', _formatDateTime(sale.createdAt)),
                _detailRow('Cashier', sale.cashierName ?? 'Unknown'),
                if (sale.customerName != null &&
                    sale.customerName!.trim().isNotEmpty)
                  _detailRow('Customer', sale.customerName!),
                _detailRow(
                  'Payment',
                  sale.paymentMethod == 'CASH' ? 'Cash' : 'Bank Transfer',
                ),
                _detailRow('Status', isVoided ? 'Voided' : 'Completed'),
                const Divider(),
                ...sale.items.map(
                  (item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Expanded(child: Text(item.productNameSnapshot)),
                            Text(
                              MoneyUtils.formatBr(item.lineTotalMinorUnits),
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${item.quantityText} @ '
                          '${MoneyUtils.formatBr(item.unitPriceSnapshotMinorUnits)} each'
                          '${item.hasManualLineTotal ? ' (manual amount)' : ''}',
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                            fontSize: 12,
                          ),
                        ),
                        if (item.notes != null && item.notes!.trim().isNotEmpty)
                          Text(
                            'Note: ${item.notes}',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'TOTAL:',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      MoneyUtils.formatBr(sale.totalMinorUnits),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                if (isVoided && sale.voidReason != null) ...[
                  const Divider(),
                  Text(
                    'Voided: ${sale.voidReason}',
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 12,
                    ),
                  ),
                  if (sale.voidedAt != null)
                    Text(
                      'Voided at ${_formatDateTime(sale.voidedAt!)}',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontSize: 12,
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (!isVoided && isOwner)
            TextButton(
              onPressed: () async {
                final voided = await _voidSale(sale);
                if (voided && dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text(
                'Void Sale',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
          if (!isVoided && !isOwner && !sale.hasPendingVoidRequest)
            TextButton(
              onPressed: () async {
                final requested = await _requestVoid(sale);
                if (requested && dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text(
                'Request Void',
                style: TextStyle(color: AppTheme.warning),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              label,
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Sales History'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSales),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            _buildFilterBar(),
            const Divider(height: 1),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(_error!),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _loadSales,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _sales.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _hasActiveFilters
                              ? 'No sales match these filters.'
                              : 'No sales recorded yet.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppTheme.muted),
                        ),
                      ),
                    )
                  : _buildSalesList(),
            ),
          ],
        ),
      ),
    );
  }

  String _dayLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return _formatDate(date);
  }

  /// Flattens the loaded sales into compact, day-grouped rows: a header per
  /// calendar day followed by tight single-line sale rows.
  List<_HistoryEntry> _buildGroupedEntries() {
    final entries = <_HistoryEntry>[];
    String? lastDay;
    for (final sale in _sales) {
      final day = _formatDate(sale.createdAt);
      if (day != lastDay) {
        entries.add(_HistoryEntry.header(_dayLabel(sale.createdAt)));
        lastDay = day;
      }
      entries.add(_HistoryEntry.sale(sale));
    }
    return entries;
  }

  Widget _buildSalesList() {
    final entries = _buildGroupedEntries();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${_sales.length} ${_sales.length == 1 ? 'sale' : 'sales'}',
                  style: TextStyle(color: AppTheme.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 16),
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              if (entry.isHeader) return _buildDayHeader(entry.label!);
              return _buildSaleRow(entry.sale!);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildDayHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.muted,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSaleRow(Sale sale) {
    final isVoided = sale.status == 'VOIDED';
    final time =
        '${sale.createdAt.hour.toString().padLeft(2, '0')}:'
        '${sale.createdAt.minute.toString().padLeft(2, '0')}';
    final muted = Theme.of(context).textTheme.bodySmall?.color;
    final color = isVoided ? Colors.grey : AppTheme.foreground;

    return InkWell(
      onTap: () => _showSaleDetails(sale),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: AppTheme.border)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Text(time, style: TextStyle(fontSize: 12, color: muted)),
            ),
            Expanded(
              child: Text(
                _saleHeadline(sale),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: color,
                  decoration: isVoided ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            if (!isVoided && sale.hasPendingVoidRequest)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: _MiniBadge('REQ', color: AppTheme.warning),
              ),
            if (isVoided)
              const Padding(
                padding: EdgeInsets.only(right: 6),
                child: _MiniBadge('VOID', color: Colors.grey),
              ),
            Text(
              MoneyUtils.formatBr(sale.totalMinorUnits),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
                decoration: isVoided ? TextDecoration.lineThrough : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText:
                  'Search product, customer, cashier, quantity, or notes...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _loadSales();
                      },
                    ),
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _loadSales(),
          ),
          const SizedBox(height: 12),
          Wrap(
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
                      onSelected: (_) => _selectPeriod(period),
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
              const SizedBox(width: 8),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'ALL', label: Text('All')),
                  ButtonSegment(value: 'COMPLETED', label: Text('Completed')),
                  ButtonSegment(value: 'VOIDED', label: Text('Voided')),
                ],
                selected: {_status},
                onSelectionChanged: (selection) {
                  setState(() => _status = selection.first);
                  _loadSales();
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
}

class _VoidSaleDialog extends StatefulWidget {
  final bool requestMode;

  const _VoidSaleDialog({this.requestMode = false});

  @override
  State<_VoidSaleDialog> createState() => _VoidSaleDialogState();
}

class _VoidSaleDialogState extends State<_VoidSaleDialog> {
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) return;
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    final requestMode = widget.requestMode;
    return AlertDialog(
      title: Text(requestMode ? 'Request Void?' : 'Void Sale?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            requestMode
                ? 'Ask the owner to void this sale. It keeps counting as '
                      'revenue until the owner approves. Give a reason below.'
                : 'Void this sale? The original sale stays in the audit '
                      'trail; it just stops counting as revenue.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reasonController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason'),
            maxLength: 240,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: requestMode ? AppTheme.warning : AppTheme.danger,
          ),
          onPressed: _reasonController.text.trim().isEmpty ? null : _submit,
          child: Text(requestMode ? 'Send Request' : 'Void Sale'),
        ),
      ],
    );
  }
}

/// A single row in the compact history list: either a day header or a sale.
class _HistoryEntry {
  final String? label;
  final Sale? sale;

  const _HistoryEntry.header(this.label) : sale = null;
  const _HistoryEntry.sale(Sale this.sale) : label = null;

  bool get isHeader => sale == null;
}

/// A tiny inline status badge used in compact history rows.
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
