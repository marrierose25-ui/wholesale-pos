import 'package:flutter/material.dart';

import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../sales/shift.dart';

/// A searchable history of cash-register sessions (shifts). Once a shift is
/// closed the live register no longer shows it, so this screen lets the owner
/// look back at any day: opening cash, expected vs counted, the drawer
/// discrepancy, who ran it, and the full breakdown of how the cash moved.
class ShiftHistoryScreen extends StatefulWidget {
  final ShiftRepository shiftRepository;

  const ShiftHistoryScreen({super.key, required this.shiftRepository});

  @override
  State<ShiftHistoryScreen> createState() => _ShiftHistoryScreenState();
}

class _ShiftHistoryScreenState extends State<ShiftHistoryScreen> {
  List<Shift> _shifts = [];
  bool _isLoading = true;
  String? _error;

  ReportPeriod _period = ReportPeriod.allTime;
  DateTimeRange? _customRange;
  String _status = 'ALL';

  @override
  void initState() {
    super.initState();
    _load();
  }

  DateRange? get _activeRange {
    if (_period == ReportPeriod.custom) {
      if (_customRange == null) return null;
      return DateRange.custom(_customRange!.start, _customRange!.end);
    }
    return _period.toDateRange();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final shifts = await widget.shiftRepository.getShiftHistory(
        period: _activeRange,
        status: _status == 'ALL' ? null : _status,
      );
      if (!mounted) return;
      setState(() {
        _shifts = shifts;
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
            ).subtract(const Duration(days: 30)),
            end: DateTime(now.year, now.month, now.day),
          ),
    );
    if (picked != null) {
      setState(() {
        _period = ReportPeriod.custom;
        _customRange = picked;
      });
      _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Register History'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _load),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
              child: _buildFilters(),
            ),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildFilters() {
    return Column(
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ...ReportPeriod.values
                .where((p) => p != ReportPeriod.custom)
                .map(
                  (period) => ChoiceChip(
                    label: Text(period.label),
                    selected: _period == period,
                    onSelected: (_) {
                      setState(() => _period = period);
                      _load();
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
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Text(
              'Status:  ',
              style: TextStyle(fontSize: 13, color: AppTheme.muted),
            ),
            _statusChip('All', 'ALL'),
            _statusChip('Open', 'OPEN'),
            _statusChip('Closed', 'CLOSED'),
          ],
        ),
      ],
    );
  }

  Widget _statusChip(String label, String value) {
    final selected = _status == value;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) {
          setState(() => _status = value);
          _load();
        },
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_shifts.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _period == ReportPeriod.allTime && _status == 'ALL'
                ? 'No register sessions recorded yet.'
                : 'No register sessions match these filters.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _shifts.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) => _buildRow(_shifts[index]),
    );
  }

  Widget _buildRow(Shift shift) {
    final isOpen = shift.status == 'OPEN';
    final discrepancy = shift.discrepancy;
    return ListTile(
      onTap: () => _showDetail(shift),
      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      leading: IconChip(
        icon: isOpen ? Icons.play_circle_outline : Icons.check_circle_outline,
        size: 40,
        color: isOpen ? AppDesign.success : AppDesign.textFaint,
      ),
      title: Row(
        children: [
          Text(
            _dayLabel(shift.openedAt),
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(width: 8),
          Text(
            '${_formatTime(shift.openedAt)}'
            '${shift.closedAt != null ? ' - ${_formatTime(shift.closedAt!)}' : ' - open'}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ],
      ),
      subtitle: Text(
        'Cashier: ${shift.cashierName ?? 'Unknown'}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            isOpen
                ? 'Expected ${MoneyUtils.formatBr(_liveExpected(shift))}'
                : 'Counted ${MoneyUtils.formatBr(shift.closingCashMinorUnits ?? 0)}',
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          if (!isOpen && discrepancy != null)
            Text(
              discrepancy == 0
                  ? 'Balanced'
                  : 'Diff ${MoneyUtils.formatBr(discrepancy)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: discrepancy == 0 ? AppTheme.success : AppTheme.danger,
              ),
            )
          else if (isOpen)
            const Text(
              'Open',
              style: TextStyle(fontSize: 12, color: AppTheme.success),
            ),
        ],
      ),
    );
  }

  /// Expected cash is only stored when a shift closes. For a still-open shift
  /// the list shows nothing stored, so fall back to the opening figure.
  int _liveExpected(Shift shift) => shift.expectedCashMinorUnits ?? 0;

  Future<void> _showDetail(Shift shift) async {
    Map<String, int> summary;
    try {
      summary = await widget.shiftRepository.getShiftSummary(shift);
    } catch (_) {
      summary = const {};
    }
    if (!mounted) return;

    final isOpen = shift.status == 'OPEN';
    final discrepancy = shift.discrepancy;
    final expected = isOpen
        ? (summary['expected_cash'] ?? 0)
        : (shift.expectedCashMinorUnits ?? summary['expected_cash'] ?? 0);

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Register ${isOpen ? 'Open' : 'Closed'}'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _infoRow('Date', _formatDate(shift.openedAt)),
                _infoRow(
                  'Opened',
                  '${_formatDate(shift.openedAt)} ${_formatTime(shift.openedAt)}',
                ),
                if (shift.closedAt != null)
                  _infoRow(
                    'Closed',
                    '${_formatDate(shift.closedAt!)} ${_formatTime(shift.closedAt!)}',
                  ),
                _infoRow('Cashier', shift.cashierName ?? 'Unknown'),
                const Divider(height: 24),
                const Text(
                  'Cash drawer breakdown',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                _breakdownRow('Opening cash', shift.openingCashMinorUnits),
                _breakdownRow('+ Cash sales', summary['cash_sales'] ?? 0),
                _breakdownRow('+ Deposits', summary['deposits'] ?? 0),
                _breakdownRow('- Withdrawals', -(summary['withdrawals'] ?? 0)),
                _breakdownRow(
                  '- Cash refunds (other shifts)',
                  -(summary['cash_refunds'] ?? 0),
                ),
                _breakdownRow('= Expected cash', expected, emphasize: true),
                const SizedBox(height: 8),
                _breakdownRow(
                  'Bank sales (not in drawer)',
                  summary['bank_sales'] ?? 0,
                ),
                if ((summary['voids'] ?? 0) > 0)
                  _breakdownRow(
                    'Voids attributed to this shift',
                    summary['voids']!,
                  ),
                if (!isOpen) ...[
                  const Divider(height: 24),
                  _breakdownRow(
                    'Counted cash at close',
                    shift.closingCashMinorUnits ?? 0,
                  ),
                  _breakdownRow(
                    'Discrepancy (counted - expected)',
                    discrepancy ?? 0,
                    emphasize: true,
                    color: (discrepancy ?? 0) == 0
                        ? AppTheme.success
                        : AppTheme.danger,
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontSize: 13, color: AppTheme.muted)),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _breakdownRow(
    String label,
    int amount, {
    bool emphasize = false,
    Color? color,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: emphasize ? FontWeight.bold : null,
                color: emphasize ? null : AppTheme.muted,
              ),
            ),
          ),
          Text(
            MoneyUtils.formatBr(amount),
            style: TextStyle(
              fontSize: 13,
              fontWeight: emphasize ? FontWeight.bold : null,
              color:
                  color ??
                  (emphasize ? Theme.of(context).colorScheme.primary : null),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime date) {
    return '${date.hour.toString().padLeft(2, '0')}:'
        '${date.minute.toString().padLeft(2, '0')}';
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
}
