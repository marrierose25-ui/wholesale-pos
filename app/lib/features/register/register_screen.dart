import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/utils/money_utils.dart';
import '../sales/shift.dart';
import '../sales/sale.dart';

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
  bool _isLoading = true;
  bool _voidsVerified = false;

  final _openingCashController = TextEditingController();
  final _actualCashController = TextEditingController();

  @override
  void initState() {
    super.initState();
    loadData();
  }

  Future<void> loadData() async {
    setState(() => _isLoading = true);
    final shift = await widget.shiftRepository.getActiveShift();

    if (shift != null) {
      final summary = await widget.shiftRepository.getShiftSummary(shift);
      final allSales = await widget.saleRepository.getAllSales();
      final voids = allSales
          .where(
            (s) => s.status == 'VOIDED' && s.createdAt.isAfter(shift.openedAt),
          )
          .toList();

      setState(() {
        _activeShift = shift;
        _summary = summary;
        _voids = voids;
        // If there are no voids, auto-verify so the register can be closed
        if (voids.isEmpty) _voidsVerified = true;
      });
    } else {
      setState(() {
        _activeShift = null;
        _summary = null;
        _voids = [];
        _voidsVerified = false;
      });
    }
    setState(() => _isLoading = false);
  }

  Future<void> _openRegister() async {
    final cash = MoneyUtils.stringToMinorUnits(_openingCashController.text);
    if (cash == null || cash < 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid starting cash amount.'),
        ),
      );
      return;
    }
    await widget.shiftRepository.openShift(widget.currentUser.id, cash);
    widget.onShiftUpdated();
    _openingCashController.clear();
    loadData();
  }

  Future<void> _closeRegister() async {
    if (_activeShift == null) return;
    if (!_voidsVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('You must verify the voided payments before closing.'),
        ),
      );
      return;
    }

    final actualCash = MoneyUtils.stringToMinorUnits(
      _actualCashController.text,
    );
    if (actualCash == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter the actual cash counted.')),
      );
      return;
    }

    await widget.shiftRepository.closeShift(_activeShift!, actualCash);
    widget.onShiftUpdated();
    _actualCashController.clear();
    loadData();
  }

  void _showCashMovementDialog() {
    final amountController = TextEditingController();
    final reasonController = TextEditingController();
    String type = 'WITHDRAWAL';

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
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
                  selected: {type},
                  onSelectionChanged: (val) =>
                      setDialogState(() => type = val.first),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(labelText: 'Amount (ETB)'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: reasonController,
                  decoration: const InputDecoration(
                    labelText: 'Reason / Reference',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () async {
                  final amount = MoneyUtils.stringToMinorUnits(
                    amountController.text,
                  );
                  if (amount != null && amount > 0) {
                    await widget.shiftRepository.addCashMovement(
                      _activeShift!.id,
                      type,
                      amount,
                      reasonController.text.trim(),
                    );
                    if (context.mounted) Navigator.pop(context);
                    loadData();
                  }
                },
                child: const Text('Save'),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Cash Register'),
        actions: [
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
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: _activeShift == null
            ? _buildOpenRegisterCard()
            : _buildActiveRegisterCard(),
      ),
    );
  }

  Widget _buildOpenRegisterCard() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500),
        child: Card(
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
                const Text(
                  'Enter the starting cash in the drawer to begin your shift.',
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _openingCashController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Starting Cash (ETB)',
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _openRegister,
                    child: const Text('Open Register'),
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
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _buildStatCard(
              'Opening Cash',
              MoneyUtils.minorUnitsToString(
                _activeShift!.openingCashMinorUnits,
              ),
            ),
            _buildStatCard(
              'Cash Sales',
              MoneyUtils.minorUnitsToString(cashSales),
            ),
            _buildStatCard(
              'Bank Sales',
              MoneyUtils.minorUnitsToString(bankSales),
            ),
            _buildStatCard(
              'Withdrawals',
              MoneyUtils.minorUnitsToString(withdrawals),
            ),
            _buildStatCard('Deposits', MoneyUtils.minorUnitsToString(deposits)),
            _buildStatCard(
              'Expected Cash',
              MoneyUtils.minorUnitsToString(expectedCash),
              isPrimary: true,
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Close Register',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Count the physical cash in the drawer and enter the total below.',
                        style: TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _actualCashController,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Actual Cash in Drawer (ETB)',
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: 24),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).scaffoldBackgroundColor,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: Theme.of(context).dividerColor,
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Discrepancy',
                              style: TextStyle(fontWeight: FontWeight.w500),
                            ),
                            Text(
                              '${MoneyUtils.minorUnitsToString(discrepancy)} ETB',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: discrepancy == 0
                                    ? Colors.green
                                    : Colors.red,
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
                            backgroundColor: _voidsVerified
                                ? Colors.red
                                : Colors.grey,
                          ),
                          onPressed: _voidsVerified ? _closeRegister : null,
                          child: const Text('Close Register'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              flex: 1,
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(
                            Icons.warning_amber_rounded,
                            color: Colors.red,
                            size: 20,
                          ),
                          SizedBox(width: 8),
                          Text(
                            'Voided Payments',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Verify these voids before closing.',
                        style: TextStyle(color: Colors.grey, fontSize: 13),
                      ),
                      const Divider(height: 24),
                      if (_voids.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            'No voids during this shift.',
                            style: TextStyle(color: Colors.grey, fontSize: 13),
                          ),
                        )
                      else ...[
                        ..._voids.map(
                          (v) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context)
                                    .scaffoldBackgroundColor,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: Theme.of(context).dividerColor,
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.cancel,
                                    color: Colors.red,
                                    size: 16,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          v.receiptNumber,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        Text(
                                          '${MoneyUtils.minorUnitsToString(v.totalMinorUnits)} ETB Ã¢â‚¬Â¢ ${v.paymentMethod}',
                                          style: const TextStyle(
                                            fontSize: 11,
                                            color: Colors.grey,
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
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          value: _voidsVerified,
                          onChanged: (val) =>
                              setState(() => _voidsVerified = val ?? false),
                          controlAffinity: ListTileControlAffinity.leading,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildStatCard(String title, String amount, {bool isPrimary = false}) {
    return SizedBox(
      width: 180,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '$amount ETB',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isPrimary
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
