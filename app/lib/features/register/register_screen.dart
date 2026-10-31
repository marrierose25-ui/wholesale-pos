import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_formatter.dart';
import '../../core/utils/date_range.dart';
import '../../core/utils/money_utils.dart';
import '../sales/shift.dart';
import '../sales/void_request.dart';
import '../../core/utils/proof_photo.dart';
import 'register_history_screen.dart';

/// The register ("Money in the drawer"). The redesign drops the open/close
/// shift ritual in favour of a persistent balance: the hero card shows the
/// all-time cash in the drawer, while a "Today" row of counters resets each
/// calendar day. Credits (deposits) and debits (withdrawals) are added by
/// tapping their cards. The full ledger lives behind a single "Register
/// History" button that opens [RegisterHistoryScreen].
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
  Shift? _shift;
  Map<String, int> _snapshot = const {};
  List<VoidRequest> _pendingRequests = [];
  bool _isLoading = true;
  bool _isProcessing = false;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    loadData();
  }

  Future<void> loadData({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }

    try {
      // A shift always exists: create the perpetual one on first visit.
      final shift = await widget.shiftRepository.ensureActiveShift(
        widget.currentUser.id,
        userId: widget.currentUser.id,
      );
      final snapshot = await widget.shiftRepository.getRegisterSnapshot(
        DateRange.today(),
        userId: widget.currentUser.id,
      );
      final isOwner = widget.currentUser.role == 'OWNER';
      final pending = isOwner
          ? await widget.saleRepository.getPendingVoidRequests(
              userId: widget.currentUser.id,
            )
          : <VoidRequest>[];

      if (!mounted) return;
      setState(() {
        _shift = shift;
        _snapshot = snapshot;
        _pendingRequests = pending;
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

  Future<void> _showCashMovement(String presetType) async {
    final shift = _shift;
    if (shift == null || _isProcessing) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _CashMovementDialog(initialType: presetType),
    );
    if (result == null || !mounted) return;

    setState(() => _isProcessing = true);
    try {
      await widget.shiftRepository.addCashMovement(
        shift.id,
        result['type'] as String,
        result['amount'] as int,
        result['reason'] as String,
        userId: widget.currentUser.id,
        photo: result['photo'] as String?,
      );
      widget.onShiftUpdated();
      await loadData();
    } catch (e) {
      if (mounted) {
        _showMessage(e.toString().replaceAll('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _isProcessing = false);
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
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadData),
          const SizedBox(width: 16),
        ],
      ),
      body: AppBackground(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: _buildRegister(),
        ),
      ),
    );
  }

  Widget _buildRegister() {
    final balance = _snapshot['balance'] ?? 0;
    final cashSales = _snapshot['today_cash_sales'] ?? 0;
    final bankSales = _snapshot['today_bank_sales'] ?? 0;
    final deposits = _snapshot['today_deposits'] ?? 0;
    final withdrawals = _snapshot['today_withdrawals'] ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBalanceHero(balance),
        const SizedBox(height: 20),
        const SectionHeader(title: 'Today'),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 560 ? 2 : 2;
            const spacing = 12.0;
            final itemWidth =
                (constraints.maxWidth - spacing * (columns - 1)) / columns;
            final stats = <_RegStat>[
              _RegStat(
                'Today Cash Sales',
                cashSales,
                Icons.payments_rounded,
                AppDesign.success,
              ),
              _RegStat(
                'Today Bank Sales',
                bankSales,
                Icons.account_balance_rounded,
                AppDesign.blueBright,
              ),
              _RegStat(
                'Today Credits',
                deposits,
                Icons.south_west_rounded,
                AppDesign.blue,
                onTap: () => _showCashMovement('DEPOSIT'),
              ),
              _RegStat(
                'Today Debits',
                withdrawals,
                Icons.north_east_rounded,
                AppDesign.warning,
                onTap: () => _showCashMovement('WITHDRAWAL'),
              ),
            ];
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final s in stats)
                  SizedBox(width: itemWidth, child: _buildStatCard(s)),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        // The register_history tick gates this button (owners always pass);
        // the full ledger lives behind it on RegisterHistoryScreen.
        if (widget.currentUser.can('register_history'))
          _buildRegisterHistoryButton(),
        if (_pendingRequests.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildPendingRequestsCard(),
        ],
      ],
    );
  }

  Widget _buildRegisterHistoryButton() {
    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RegisterHistoryScreen(
            shiftRepository: widget.shiftRepository,
            saleRepository: widget.saleRepository,
            currentUser: widget.currentUser,
          ),
        ),
      ),
      child: Row(
        children: [
          const IconChip(
            icon: Icons.history_rounded,
            size: 30,
            color: AppDesign.blue,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Register History',
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: AppDesign.textFaint,
            size: 20,
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceHero(int balance) {
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
                  'Register Balance',
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
                    MoneyUtils.formatBr(balance),
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

  Widget _buildStatCard(_RegStat stat) {
    final card = GlassCard(
      padding: const EdgeInsets.all(14),
      radius: AppDesign.radiusCardSm,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconChip(icon: stat.icon, size: 30, color: stat.color),
          const SizedBox(height: 10),
          Text(
            stat.title,
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
              MoneyUtils.formatBr(stat.value),
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
    if (stat.onTap == null) return card;
    return InkWell(
      onTap: _isProcessing ? null : stat.onTap,
      borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
      child: card,
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

  String _formatTime(DateTime time) => formatAddisTime(time);
}

class _RegStat {
  final String title;
  final int value;
  final IconData icon;
  final Color color;
  final VoidCallback? onTap;
  const _RegStat(this.title, this.value, this.icon, this.color, {this.onTap});
}

class _CashMovementDialog extends StatefulWidget {
  final String initialType;

  const _CashMovementDialog({this.initialType = 'WITHDRAWAL'});

  @override
  State<_CashMovementDialog> createState() => _CashMovementDialogState();
}

class _CashMovementDialogState extends State<_CashMovementDialog> {
  final _amountController = TextEditingController();
  final _reasonController = TextEditingController();
  late String _type = widget.initialType;
  String? _error;

  /// Optional proof photo (base64) — usually attached on a debit as evidence
  /// the cash actually left the drawer. Stays null until the user picks one.
  String? _photo;
  bool _picking = false;

  @override
  void dispose() {
    _amountController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    if (_picking) return;
    setState(() => _picking = true);
    String? picked;
    try {
      picked = await pickProofPhoto(context);
    } catch (_) {
      // A denied camera permission or a plugin failure must never block the
      // movement itself — the photo is optional by design.
      if (mounted) setState(() => _picking = false);
      return;
    }
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null) _photo = picked;
    });
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
    Navigator.of(
      context,
    ).pop({'type': _type, 'amount': amount, 'reason': reason, 'photo': _photo});
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cash Movement'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'WITHDRAWAL',
                label: Text('Debit'),
                icon: Icon(Icons.arrow_upward),
              ),
              ButtonSegment(
                value: 'DEPOSIT',
                label: Text('Credit'),
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
          const SizedBox(height: 4),
          // Optional proof photo. Shown for both directions, but aimed at
          // debits: "upload proof the cash left the drawer". The label is
          // Expanded + ellipsized so it can never overflow a phone-width
          // dialog.
          Row(
            children: [
              IconButton(
                onPressed: _picking ? null : _pickPhoto,
                icon: Icon(
                  _photo == null
                      ? Icons.add_a_photo_outlined
                      : Icons.photo_camera_outlined,
                ),
                tooltip: 'Add photo (optional)',
              ),
              Expanded(
                child: _photo == null
                    ? const Text(
                        'Add photo (optional)',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      )
                    : Row(
                        children: [
                          // Tap to remove the attached proof.
                          IconButton(
                            onPressed: () => setState(() => _photo = null),
                            icon: const Icon(Icons.close),
                            iconSize: 16,
                            tooltip: 'Remove photo',
                          ),
                          const Expanded(
                            child: Text(
                              'Photo attached',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
              ),
            ],
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
