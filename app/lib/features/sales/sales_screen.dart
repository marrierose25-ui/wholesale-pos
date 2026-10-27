import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';
import 'sale.dart';
import 'sale_item.dart';
import 'shift.dart';

/// The POS screen. The redesign trims it to a single action: tapping "New
/// Sale" opens a compact dialog that captures one item (name, unit, quantity,
/// price) and a payment method, then records the sale and hands off to the
/// register. No cart, no saved names, no receipt printing.
class SalesScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final ShiftRepository shiftRepository;
  final String deviceId;
  final User currentUser;
  final VoidCallback onSaleCompleted;

  const SalesScreen({
    super.key,
    required this.saleRepository,
    required this.shiftRepository,
    required this.deviceId,
    required this.currentUser,
    required this.onSaleCompleted,
  });

  @override
  State<SalesScreen> createState() => SalesScreenState();
}

class SalesScreenState extends State<SalesScreen> {
  bool _isProcessing = false;
  Shift? _activeShift;

  @override
  void initState() {
    super.initState();
    loadShift();
  }

  /// Guarantees a perpetual open shift so a sale can always be recorded. Safe
  /// to call again from the shell's refresh hook (it is idempotent).
  Future<void> loadShift() async {
    try {
      final shift = await widget.shiftRepository.ensureActiveShift(
        widget.currentUser.id,
      );
      if (mounted) setState(() => _activeShift = shift);
    } catch (_) {
      if (mounted) setState(() => _activeShift = null);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _newSale() async {
    if (_isProcessing) return;
    final draft = await showDialog<_SaleDraft>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const _SaleDialog(),
    );
    if (draft == null) return;

    setState(() => _isProcessing = true);
    try {
      final shift =
          _activeShift ??
          await widget.shiftRepository.ensureActiveShift(widget.currentUser.id);
      final receiptNumber = await widget.saleRepository.nextReceiptNumber();
      final now = DateTime.now();
      final saleId = const Uuid().v4();
      final lineTotal = draft.lineTotalMinorUnits;

      final item = SaleItem(
        id: const Uuid().v4(),
        saleId: saleId,
        productId: 'MANUAL',
        productNameSnapshot: draft.name,
        unitPriceSnapshotMinorUnits: draft.unitPriceMinorUnits,
        quantityText: draft.quantityText,
        billingQuantityMilliunits: draft.billingQuantityMilliunits,
        lineDiscountMinorUnits: 0,
        lineTotalMinorUnits: lineTotal,
        notes: null,
      );

      final sale = Sale(
        id: saleId,
        receiptNumber: receiptNumber,
        cashierId: widget.currentUser.id,
        deviceId: widget.deviceId,
        shiftId: shift.id,
        paymentMethod: draft.paymentMethod,
        subtotalMinorUnits: lineTotal,
        discountMinorUnits: 0,
        totalMinorUnits: lineTotal,
        amountPaidMinorUnits: lineTotal,
        changeMinorUnits: 0,
        createdAt: now,
        items: [item],
      );

      await widget.saleRepository.saveSale(sale);
      // Refresh every data screen and switch the shell to the Register tab so
      // the cashier immediately sees the drawer move.
      widget.onSaleCompleted();
    } catch (e) {
      if (!mounted) return;
      _showMessage(
        'Failed to save sale: ${e.toString().replaceAll('Exception: ', '')}',
      );
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 32,
                    vertical: 40,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The + circle is the one and only action: tap it to
                      // ring up a sale. No labels, no descriptions.
                      InkWell(
                        onTap: _isProcessing ? null : _newSale,
                        customBorder: const CircleBorder(),
                        child: Ink(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppDesign.buttonGradient,
                            boxShadow: [AppDesign.blueGlow(alpha: 0.4)],
                          ),
                          child: Container(
                            width: 88,
                            height: 88,
                            alignment: Alignment.center,
                            child: AnimatedSwitcher(
                              duration: const Duration(milliseconds: 180),
                              child: _isProcessing
                                  ? const SizedBox(
                                      key: ValueKey('spinner'),
                                      width: 34,
                                      height: 34,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 3,
                                        color: AppDesign.onBlue,
                                      ),
                                    )
                                  : const Icon(
                                      key: ValueKey('plus'),
                                      Icons.add,
                                      size: 48,
                                      color: AppDesign.onBlue,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The values captured by [SalesScreen]'s sale dialog, already parsed into the
/// minor-unit / milliunit space the repositories expect.
class _SaleDraft {
  final String name;
  final String quantityText;
  final int? billingQuantityMilliunits;
  final int unitPriceMinorUnits;
  final int lineTotalMinorUnits;
  final String paymentMethod;

  const _SaleDraft({
    required this.name,
    required this.quantityText,
    required this.billingQuantityMilliunits,
    required this.unitPriceMinorUnits,
    required this.lineTotalMinorUnits,
    required this.paymentMethod,
  });
}

/// A focused one-item sale dialog: Name, Unit, Quantity, Price with a live
/// Total, and a Cash / Bank Transfer choice. Completing records the sale.
class _SaleDialog extends StatefulWidget {
  const _SaleDialog();

  @override
  State<_SaleDialog> createState() => _SaleDialogState();
}

class _SaleDialogState extends State<_SaleDialog> {
  final _nameController = TextEditingController();
  final _unitController = TextEditingController(text: 'piece');
  final _quantityController = TextEditingController(text: '1');
  final _priceController = TextEditingController();

  String _paymentMethod = 'CASH';
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _unitController.dispose();
    _quantityController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  int? get _quantityMilliunits =>
      MoneyUtils.stringToMilliunits(_quantityController.text);

  int? get _priceMinorUnits =>
      MoneyUtils.stringToMinorUnits(_priceController.text);

  int? get _lineTotalMinorUnits {
    final price = _priceMinorUnits;
    final quantity = _quantityMilliunits;
    if (price == null || quantity == null) return null;
    return MoneyUtils.tryLineTotalMinorUnits(price, quantity);
  }

  String get _quantityText {
    final quantity = _quantityController.text.trim();
    final unit = _unitController.text.trim();
    if (unit.isEmpty) return quantity;
    return '$quantity $unit';
  }

  void _submit() {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter what was sold.');
      return;
    }
    final price = _priceMinorUnits;
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter a valid price in Br.');
      return;
    }
    final quantity = _quantityMilliunits;
    if (quantity == null || quantity <= 0) {
      setState(() => _error = 'Enter a quantity like 2 or 1.5.');
      return;
    }
    final lineTotal = _lineTotalMinorUnits;
    if (lineTotal == null) {
      setState(() => _error = 'The calculated total is too large.');
      return;
    }
    Navigator.of(context).pop(
      _SaleDraft(
        name: name,
        quantityText: _quantityText,
        billingQuantityMilliunits: quantity,
        unitPriceMinorUnits: price,
        lineTotalMinorUnits: lineTotal,
        paymentMethod: _paymentMethod,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lineTotal = _lineTotalMinorUnits;
    return AlertDialog(
      // Default horizontal insets (40) squeeze the content past a phone's
      // usable width; tightening them keeps the row of controls inside 390px.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('New Sale'),
      content: ConstrainedBox(
        // Cap the dialog at 420 on wide screens but let it shrink to the
        // viewport on a phone, so the fixed 420 never overflows a narrow width.
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _nameController,
                autofocus: true,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'What was sold',
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _quantityController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Quantity',
                        hintText: 'e.g. 2',
                      ),
                      onChanged: (_) => setState(() => _error = null),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: _unitController,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        hintText: 'box / kg / piece',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Price (Br)',
                  hintText: 'e.g. 500',
                ),
                onChanged: (_) => setState(() => _error = null),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).scaffoldBackgroundColor,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.border),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Total',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      lineTotal == null ? '—' : MoneyUtils.formatBr(lineTotal),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(
                    value: 'CASH',
                    label: Text('Cash'),
                    icon: Icon(Icons.payments_outlined),
                  ),
                  ButtonSegment(
                    value: 'BANK',
                    label: Text('Bank Transfer'),
                    icon: Icon(Icons.account_balance_rounded),
                  ),
                ],
                selected: {_paymentMethod},
                onSelectionChanged: (selection) =>
                    setState(() => _paymentMethod = selection.first),
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
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Complete Sale')),
      ],
    );
  }
}
