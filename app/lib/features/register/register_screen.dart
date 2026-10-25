import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';
import '../sales/sale.dart';
import '../sales/shift.dart';
import '../sales/void_request.dart';
import 'shift_history_screen.dart';

class RegisterScreen extends StatefulWidget {
  final User currentUser;
  final ShiftRepository shiftRepository;
  final SaleRepository saleRepository;
  final VoidCallback onShiftUpdated;

  const RegisterScreen({
    super.key,
    required this.currentUser,
    required this.shiftRepository,
    required this.saleRepository,
    required this.onShiftUpdated,
  });

  @override
  State<RegisterScreen> createState() => RegisterScreenState();
}

class RegisterScreenState extends State<RegisterScreen> {
  Shift? _activeShift;
  Map<String, int>? _summary;
  List<Sale> _voids = [];
  List<VoidRequest> _pendingRequests = [];
  bool _isLoading = true;
  bool _isProcessing = false;
  bool _voidsVerified = false;
  String? _loadError;

  final _openingCashController = TextEditingController();
  final _actualCashController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadData();
  }

  @override
  void dispose() {
    _openingCashController.dispose();
    _actualCashController.dispose();
    super.dispose();
  }

  Future<void> loadData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final shift = await widget.shiftRepository.getActiveShift();
      if (shift == null) {
        if (!mounted) return;
        setState(() {
          _activeShift = null;
          _summary = null;
          _voids = [];
          _voidsVerified = false;
          _isLoading = false;
        });
        return;
      }

      final summary = await widget.shiftRepository.getShiftSummary(shift);
      final voids = await widget.saleRepository.getVoidedSalesForShift(
        shift.id,
      );
      final isOwner = widget.currentUser.role == 'OWNER';
      final pending = isOwner
          ? await widget.saleRepository.getPendingVoidRequests()
          : <VoidRequest>[];

      final oldVoidIds = _voids.map((sale) => sale.id).toSet();
      final newVoidIds = voids.map((sale) => sale.id).toSet();
      if (!oldVoidIds.containsAll(newVoidIds) ||
          !newVoidIds.containsAll(oldVoidIds)) {
        _voidsVerified = false;
      }

      if (!mounted) return;
      setState(() {
        _activeShift = shift;
        _summary = summary;
        _voids = voids;
        _pendingRequests = pending;
        if (voids.isEmpty) _voidsVerified = true;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openRegister() async {
    if (_isProcessing) return;
    final cash = MoneyUtils.stringToMinorUnits(_openingCashController.text);
    if (cash == null) {
      _showMessage('Please enter a valid starting cash amount.');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      await widget.shiftRepository.openShift(widget.currentUser.id, cash);
      widget.onShiftUpdated();
      _openingCashController.clear();
      await loadData();
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _closeRegister() async {
    if (_activeShift == null || _isProcessing) return;
    if (!_voidsVerified) {
      _showMessage('You must verify the voided payments before closing.');
      return;
    }

    final actualCash = MoneyUtils.stringToMinorUnits(
      _actualCashController.text,
    );
    if (actualCash == null) {
      _showMessage('Please enter the actual cash counted.');
      return;
    }

    setState(() => _isProcessing = true);
    try {
      await widget.shiftRepository.closeShift(
        _activeShift!,
        actualCash,
        userId: widget.currentUser.id,
      );
      widget.onShiftUpdated();
      _actualCashController.clear();
      await loadData();
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  Future<void> _showCashMovementDialog() async {
    if (_activeShift == null) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => const _CashMovementDialog(),
    );
    if (result == null || !mounted) return;

    try {
      await widget.shiftRepository.addCashMovement(
        _activeShift!.id,
        result['type'] as String,
        result['amount'] as int,
        result['reason'] as String,
        userId: widget.currentUser.id,
      );
      await loadData();
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    }
  }

  Future<void> _approveVoidRequest(VoidRequest request) async {
    final amount = request.sale == null
        ? ''
        : ' of ${MoneyUtils.formatBr(request.sale!.totalMinorUnits)}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Approve void?'),
        content: Text(
          'This will void the sale$amount and remove it from revenue. '
          'The cashier${request.requesterName == null ? '' : ' (${request.requesterName})'} '
          'asked because: ${request.reason}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Approve void'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.saleRepository.approveVoidRequest(
        request.id,
        widget.currentUser.id,
      );
      widget.onShiftUpdated();
      await loadData();
    } catch (e) {
      if (mounted) _showMessage(e.toString().replaceAll('Exception: ', ''));
    }
  }

  Future<void> _rejectVoidRequest(VoidRequest request) async {
    try {
      await widget.saleRepository.rejectVoidRequest(
        request.id,
        widget.currentUser.id,
      );
      await loadData();
    } catch (e) {
      if (mounted) _showMessage(e.toString().replaceAll('Exception: ', ''));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!),
            const SizedBox(height: 8),
            TextButton(onPressed: loadData, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Cash Register'),
        actions: [
          if (widget.currentUser.role == 'OWNER')
            IconButton(
              icon: const Icon(Icons.receipt_long),
              tooltip: 'Register History',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => ShiftHistoryScreen(
                    shiftRepository: widget.shiftRepository,
                  ),
                ),
              ),
            ),
          if (_activeShift != null)
            IconButton(
              icon: const Icon(Icons.add_card),
              tooltip: 'Add Cash Movement',
              onPressed: _showCashMovementDialog,
            ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadData),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _activeShift == null
              ? _buildOpenRegisterCard()
              : _buildActiveRegisterCard(),
        ),
      ),
    );
  }

  Widget _buildOpenRegisterCard() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: GlassCard(
          padding: EdgeInsets.zero,
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Open Register',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Enter the starting cash in the drawer to begin your shift.',
                  style: TextStyle(color: AppTheme.muted),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _openingCashController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Starting Cash (Br)',
                  ),
                  onSubmitted: (_) => _openRegister(),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isProcessing ? null : _openRegister,
                    child: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text('Open Register'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActiveRegisterCard() {
    final expectedCash = _summary!['expected_cash']!;
    final cashSales = _summary!['cash_sales']!;
    final bankSales = _summary!['bank_sales']!;
    final deposits = _summary!['deposits']!;
    final withdrawals = _summary!['withdrawals']!;

    final actualCash =
        MoneyUtils.stringToMinorUnits(_actualCashController.text) ?? 0;
    final discrepancy = actualCash - expectedCash;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildExpectedCashHero(expectedCash),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 560 ? 3 : 2;
            const spacing = 12.0;
            final itemWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            final stats = <_RegStat>[
              _RegStat(
                'Opening Cash',
                _activeShift!.openingCashMinorUnits,
                Icons.lock_outline_rounded,
                AppDesign.textLo,
              ),
              _RegStat(
                'Cash Sales',
                cashSales,
                Icons.payments_rounded,
                AppDesign.success,
              ),
              _RegStat(
                'Bank Sales',
                bankSales,
                Icons.account_balance_rounded,
                AppDesign.blueBright,
              ),
              _RegStat(
                'Withdrawals',
                withdrawals,
                Icons.south_west_rounded,
                AppDesign.warning,
              ),
              _RegStat(
                'Deposits',
                deposits,
                Icons.north_east_rounded,
                AppDesign.blue,
              ),
            ];
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final s in stats)
                  SizedBox(
                    width: itemWidth,
                    child: _buildStatCard(
                      s.title,
                      s.value,
                      s.icon,
                      color: s.color,
                    ),
                  ),
              ],
            );
          },
        ),
        if (_pendingRequests.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildPendingRequestsCard(),
        ],
        const SizedBox(height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final closeCard = _buildCloseCard(discrepancy);
            final voidsCard = _buildVoidsCard();
            if (constraints.maxWidth < 900) {
              return Column(
                children: [closeCard, const SizedBox(height: 24), voidsCard],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 2, child: closeCard),
                const SizedBox(width: 24),
                Expanded(child: voidsCard),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildPendingRequestsCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.pending_actions,
                  color: AppTheme.warning,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Pending Void Requests',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.warning,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_pendingRequests.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Cashier void requests awaiting your decision.',
              style: TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            const Divider(height: 24),
            ..._pendingRequests.map(
              (request) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.sale == null
                            ? 'Sale ${request.saleId}'
                            : '${MoneyUtils.formatBr(request.sale!.totalMinorUnits)}'
                                  ' • ${request.sale!.paymentMethod}',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Requested by ${request.requesterName ?? 'unknown'}'
                        ' • ${_formatTime(request.createdAt)}',
                        style: TextStyle(fontSize: 12, color: AppTheme.muted),
                      ),
                      Text(
                        'Reason: ${request.reason}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => _rejectVoidRequest(request),
                            child: const Text('Reject'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppTheme.danger,
                            ),
                            onPressed: () => _approveVoidRequest(request),
                            child: const Text('Approve void'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloseCard(int discrepancy) {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Close Register',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Count the physical cash in the drawer and enter the total below.',
              style: TextStyle(color: AppTheme.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _actualCashController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: 'Actual Cash in Drawer (Br)',
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _closeRegister(),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).scaffoldBackgroundColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Theme.of(context).dividerColor),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Discrepancy',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                  // Flexible so the amount can wrap on narrow (phone) widths
                  // instead of overflowing; on desktop it keeps its natural size.
                  Flexible(
                    child: Text(
                      MoneyUtils.formatBr(discrepancy),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: discrepancy == 0
                            ? AppTheme.success
                            : AppTheme.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _voidsVerified ? AppTheme.danger : null,
                ),
                onPressed: _voidsVerified && !_isProcessing
                    ? _closeRegister
                    : null,
                child: _isProcessing
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Text('Close Register'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoidsCard() {
    return GlassCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: AppTheme.danger,
                  size: 20,
                ),
                SizedBox(width: 8),
                Text(
                  'Voided Payments',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Verify these voids before closing.',
              style: TextStyle(color: AppTheme.muted, fontSize: 13),
            ),
            const Divider(height: 24),
            if (_voids.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No voids during this shift.',
                  style: TextStyle(color: AppTheme.muted, fontSize: 13),
                ),
              )
            else ...[
              ..._voids.map(
                (voidedSale) => Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Theme.of(context).scaffoldBackgroundColor,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Theme.of(context).dividerColor),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.cancel,
                          color: AppTheme.danger,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${MoneyUtils.formatBr(voidedSale.totalMinorUnits)}'
                                ' • ${voidedSale.paymentMethod}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (voidedSale.voidReason != null &&
                                  voidedSale.voidReason!.trim().isNotEmpty)
                                Text(
                                  'Reason: ${voidedSale.voidReason}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.muted,
                                  ),
                                ),
                              if (voidedSale.voidedAt != null)
                                Text(
                                  'Voided at ${_formatTime(voidedSale.voidedAt!)}',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: AppTheme.muted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'I have reviewed these voids',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                ),
                value: _voidsVerified,
                onChanged: (value) =>
                    setState(() => _voidsVerified = value ?? false),
                controlAffinity: ListTileControlAffinity.leading,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _formatTime(DateTime time) {
    return '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildExpectedCashHero(int expectedCash) {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      gradient: const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [AppDesign.blueDeep, AppDesign.blue],
      ),
      border: Border.all(color: AppDesign.blueBright.withValues(alpha: 0.5)),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Expected Cash',
                  style: TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.4,
                  ),
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    MoneyUtils.formatBr(expectedCash),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 34,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -1,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Icon(
            Icons.account_balance_wallet_rounded,
            color: Colors.white,
            size: 34,
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    int amountMinorUnits,
    IconData icon, {
    Color? color,
  }) {
    final accent = color ?? AppDesign.blueBright;
    return GlassCard(
      padding: const EdgeInsets.all(14),
      radius: AppDesign.radiusCardSm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(icon: icon, size: 30, color: accent),
          const SizedBox(height: 10),
          Text(
            title,
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
              MoneyUtils.formatBr(amountMinorUnits),
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

class _RegStat {
  final String title;
  final int value;
  final IconData icon;
  final Color color;
  const _RegStat(this.title, this.value, this.icon, this.color);
}

class _CashMovementDialog extends StatefulWidget {
  const _CashMovementDialog();

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();
  String _type = 'WITHDRAWAL';
  String? _error;

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = MoneyUtils.stringToMinorUnits(_amountController.text);
    final reason = _reasonController.text.trim();
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }
    if (reason.isEmpty) {
      setState(() => _error = 'A reason or reference is required.');
      return;
    }
    Navigator.of(context)
        .pop({'type': _type, 'amount': amount, 'reason': reason});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Cash Movement'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'WITHDRAWAL',
                label: Text('Withdrawal'),
                icon: Icon(Icons.arrow_upward),
              ),
              ButtonSegment(
                value: 'DEPOSIT',
                label: Text('Deposit'),
                icon: Icon(Icons.arrow_downward),
              ),
            ],
            selected: {_type},
            onSelectionChanged: (selection) =>
                setState(() => _type = selection.first),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amountController,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Amount (Br)'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _reasonController,
            decoration: const InputDecoration(labelText: 'Reason / Reference'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: const TextStyle(color: AppTheme.danger, fontSize: 13),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
