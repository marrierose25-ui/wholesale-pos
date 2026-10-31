import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../dashboard/sales_by_day_screen.dart';
import '../sales/sale.dart';
import '../sales/sale_details.dart';
import '../sales/shift.dart';

String _hhmm(DateTime date) {
  return '${date.hour.toString().padLeft(2, '0')}:'
      '${date.minute.toString().padLeft(2, '0')}';
}

/// One compact ledger line for a cash movement: time · reason · type · user,
/// with a signed amount on the right. When a proof photo was attached, the
/// whole row is tappable (a "Proof" chip hints at it) and opens the viewer.
class _MovementRow extends StatelessWidget {
  final CashMovement m;

  const _MovementRow({required this.m});

  @override
  Widget build(BuildContext context) {
    final typeColor = m.isDeposit ? AppTheme.success : AppTheme.danger;
    final typeLabel = m.isDeposit
        ? 'Credit'
        : m.type == 'EXPENSE'
        ? 'Expense'
        : 'Debit';
    final hasProof = m.photo != null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        radius: AppDesign.radiusCardSm,
        // Touch the transaction anywhere to view its attached proof.
        onTap: hasProof ? () => _openProof(context, m) : null,
        child: Row(
          children: [
            Icon(
              // Credit arrow points down, debit arrow points up.
              m.isDeposit ? Icons.south_west_rounded : Icons.north_east_rounded,
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
                    '${_hhmm(m.createdAt)}  •  $typeLabel'
                    '${m.userName == null ? '' : '  •  ${m.userName}'}',
                    style: TextStyle(fontSize: 11.5, color: AppTheme.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Proof photo attached at record time — a labelled chip so it is
            // obvious the row can be tapped to open the full-screen viewer.
            if (hasProof)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppDesign.blue.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: AppDesign.blue.withValues(alpha: 0.4),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.photo_camera_outlined,
                        size: 13,
                        color: AppDesign.blue,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Proof',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: AppDesign.blue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
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

/// Full-screen viewer for a movement's proof photo. MemoryImage decodes and
/// caches the base64 blob by bytes; the error builder keeps a corrupt proof
/// from crashing the ledger.
Future<void> _openProof(BuildContext context, CashMovement m) async {
  final photo = m.photo;
  if (photo == null) return;
  final bytes = base64Decode(photo);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              child: Image(
                image: MemoryImage(bytes),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stack) => const Text(
                  'Photo unavailable.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white),
              onPressed: () => Navigator.of(dialogContext).pop(),
            ),
          ),
        ],
      ),
    ),
  );
}

/// Level 2 of the Register History drill-down: everything that happened on the
/// tapped day, shown compactly behind Sales / Credits / Debits tabs. The
/// completed sales rung up that date (Cash = money that entered the drawer,
/// Bank/Loan = money that bypassed it), the day's credits, and its
/// debits/expenses, closed out by the net drawer change summary.
class RegisterDayScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User? currentUser;
  final DateTime day;
  final List<CashMovement> movements;

  const RegisterDayScreen({
    super.key,
    required this.saleRepository,
    this.currentUser,
    required this.day,
    required this.movements,
  });

  @override
  State<RegisterDayScreen> createState() => _RegisterDayScreenState();
}

class _RegisterDayScreenState extends State<RegisterDayScreen> {
  List<Sale> _sales = [];
  bool _isLoading = true;
  String? _error;

  int _tab = 0;
  static const _tabLabels = ['Sales', 'Credits', 'Debits'];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final range = DateRange(
        start: widget.day,
        end: widget.day.add(const Duration(days: 1)),
      );
      final sales = await widget.saleRepository.getSales(
        userId: widget.currentUser?.id ?? '',
        period: range,
        status: 'COMPLETED',
      );
      if (!mounted) return;
      setState(() {
        _sales = sales..sort((a, b) => b.createdAt.compareTo(a.createdAt));
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

  Widget _sectionHeader(String label) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 14, 6, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppTheme.muted,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _empty(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
      child: Text(text, style: TextStyle(fontSize: 12, color: AppTheme.muted)),
    );
  }

  Widget _summaryRow(
    String label,
    int minorUnits,
    Color color, {
    bool signed = true,
    bool bold = false,
  }) {
    final sign = minorUnits == 0 || !signed
        ? ''
        : minorUnits > 0
        ? '+'
        : '-';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
                color: bold ? AppDesign.textHi : AppTheme.muted,
              ),
            ),
          ),
          Text(
            '$sign${MoneyUtils.formatBr(minorUnits.abs())}',
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // Same ledger line the Dashboard's Completed Sales drill-down uses — time,
  // item, quantity, unit price, total — tapping it opens the Sale Details
  // dialog when a signed-in user is available to authorise the void actions.
  Widget _saleRow(Sale s) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SaleLedgerRow(
        sale: s,
        onTap: widget.currentUser == null
            ? null
            : () => showSaleDetails(
                context: context,
                sale: s,
                repository: widget.saleRepository,
                currentUser: widget.currentUser!,
                onChanged: _load,
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final deposits = widget.movements.where((m) => m.isDeposit).toList();
    final withdrawals = widget.movements.where((m) => !m.isDeposit).toList();
    final depositsTotal = deposits.fold(0, (a, m) => a + m.amountMinorUnits);
    final withdrawalsTotal = withdrawals.fold(
      0,
      (a, m) => a + m.amountMinorUnits,
    );

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(SalesByDayScreen.formatDay(widget.day))),
      body: AppBackground(
        child: _isLoading && _sales.isEmpty && _error == null
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  children: [
                    PillTabs(
                      labels: _tabLabels,
                      selected: _tab,
                      onSelect: (i) => setState(() => _tab = i),
                    ),
                    // The summary card belongs to the money-movement tabs only:
                    // Credits shows its single figure, Debits shows its single
                    // figure. The Sales tab renders no summary at all.
                    if (_tab != 0) ...[
                      const SizedBox(height: 12),
                      GlassCard(
                        radius: AppDesign.radiusCardSm,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        child: Column(
                          children: [
                            if (_tab == 1)
                              _summaryRow(
                                'Credits',
                                depositsTotal,
                                AppTheme.success,
                              )
                            else
                              _summaryRow(
                                'Debits',
                                -withdrawalsTotal,
                                AppTheme.danger,
                              ),
                          ],
                        ),
                      ),
                    ],
                    // One tab at a time: the tapped day's sales, credits or
                    // debits, each with its own empty state.
                    ...switch (_tab) {
                      1 => [
                        _sectionHeader('Credits'),
                        if (deposits.isEmpty)
                          _empty('No credits this day.')
                        else
                          for (final m in deposits) _MovementRow(m: m),
                      ],
                      2 => [
                        _sectionHeader('Debits'),
                        if (withdrawals.isEmpty)
                          _empty('No debits this day.')
                        else
                          for (final m in withdrawals) _MovementRow(m: m),
                      ],
                      _ => [
                        _sectionHeader('Sales'),
                        if (_error == null && _sales.isNotEmpty)
                          const SaleLedgerHeader(),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    _error!,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: AppTheme.danger,
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: _load,
                                  child: const Text('Retry'),
                                ),
                              ],
                            ),
                          )
                        else if (_sales.isEmpty)
                          _empty('No sales on this day.')
                        else
                          for (final s in _sales) _saleRow(s),
                      ],
                    },
                  ],
                ),
              ),
      ),
    );
  }
}
