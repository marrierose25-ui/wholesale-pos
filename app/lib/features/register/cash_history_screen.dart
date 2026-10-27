import 'package:flutter/material.dart';

import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';
import '../sales/shift.dart';

/// The cash-register history: every deposit, withdrawal and expense that moved
/// through the drawer, newest first. Pill tabs switch between all movements,
/// money in, and money out — the same ledger the register screen's hero
/// balance is built from.
class CashHistoryScreen extends StatefulWidget {
  final ShiftRepository shiftRepository;

  const CashHistoryScreen({super.key, required this.shiftRepository});

  @override
  State<CashHistoryScreen> createState() => CashHistoryScreenState();
}

class CashHistoryScreenState extends State<CashHistoryScreen> {
  List<CashMovement> _movements = [];
  bool _isLoading = true;
  String? _error;

  /// 0 = All, 1 = Deposits, 2 = Withdrawals (incl. expenses).
  int _tab = 0;
  static const _tabLabels = ['All', 'Deposits', 'Withdrawals'];

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Pulls the full ledger. [silent] (the shell's tab-select hook) repaints in
  /// the background without the loading spinner.
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final movements = await widget.shiftRepository.getCashMovements();
      if (!mounted) return;
      setState(() {
        _movements = movements;
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

  List<CashMovement> get _visibleMovements {
    if (_tab == 1) return _movements.where((m) => m.isDeposit).toList();
    if (_tab == 2) return _movements.where((m) => !m.isDeposit).toList();
    return _movements;
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
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PillTabs(
                    labels: _tabLabels,
                    selected: _tab,
                    onSelect: (i) => setState(() => _tab = i),
                  ),
                  const SizedBox(height: 10),
                  // Bold column captions matching the ledger rows below.
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Date / Reason',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.muted,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 120,
                          child: Text(
                            'Amount',
                            textAlign: TextAlign.end,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.muted,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _movements.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _movements.isEmpty) {
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
    final visible = _visibleMovements;
    if (visible.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _movements.isEmpty
                ? 'No cash movements recorded yet.'
                : 'No movements in this category.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.muted),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [_buildSummaryRow(visible), ..._buildRows(visible)],
      ),
    );
  }

  /// Totals for what the current tab is showing, so "Withdrawals" answers
  /// "how much left the drawer" at a glance.
  Widget _buildSummaryRow(List<CashMovement> movements) {
    var deposits = 0;
    var withdrawals = 0;
    for (final m in movements) {
      if (m.isDeposit) {
        deposits += m.amountMinorUnits;
      } else {
        withdrawals += m.amountMinorUnits;
      }
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 10),
      child: Row(
        children: [
          Text(
            '${movements.length} movement${movements.length == 1 ? '' : 's'}',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
          const Spacer(),
          if (deposits > 0) ...[
            Text(
              '+${MoneyUtils.formatBr(deposits)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.success,
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (withdrawals > 0)
            Text(
              '-${MoneyUtils.formatBr(withdrawals)}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: AppTheme.danger,
              ),
            ),
        ],
      ),
    );
  }

  List<Widget> _buildRows(List<CashMovement> movements) {
    final rows = <Widget>[];
    String? lastDay;
    for (final m in movements) {
      final day = _formatDate(m.createdAt);
      if (day != lastDay) {
        rows.add(_buildDayHeader(day));
        lastDay = day;
      }
      rows.add(_buildRow(m));
    }
    return rows;
  }

  Widget _buildDayHeader(String day) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
      child: Text(
        day,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.muted,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildRow(CashMovement m) {
    final typeColor = m.isDeposit ? AppTheme.success : AppTheme.danger;
    final typeLabel = m.isDeposit
        ? 'Deposit'
        : m.type == 'EXPENSE'
        ? 'Expense'
        : 'Withdrawal';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        radius: AppDesign.radiusCardSm,
        child: Row(
          children: [
            Icon(
              m.isDeposit ? Icons.north_east_rounded : Icons.south_west_rounded,
              size: 18,
              color: typeColor,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.reason,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${_formatTime(m.createdAt)}  •  $typeLabel'
                    '${m.userName == null ? '' : '  •  ${m.userName}'}',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${m.isDeposit ? '+' : '-'}'
              '${MoneyUtils.formatBr(m.amountMinorUnits)}',
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                color: typeColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
