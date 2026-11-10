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
        userId: widget.currentUser.id,
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
    if (!mounted) return;

    // Second step: choose how the sale is settled and why. Back/cancel returns
    // null and abandons the sale without saving anything.
    final settlement = await showDialog<_SaleSettlement>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _PaymentDialog(draft: draft),
    );
    if (settlement == null) return;

    setState(() => _isProcessing = true);
    try {
      final shift =
          _activeShift ??
          await widget.shiftRepository.ensureActiveShift(
            widget.currentUser.id,
            userId: widget.currentUser.id,
          );
      final receiptNumber = await widget.saleRepository.nextReceiptNumber(
        userId: widget.currentUser.id,
      );
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
        notes: settlement.reason,
      );

      final sale = Sale(
        id: saleId,
        receiptNumber: receiptNumber,
        cashierId: widget.currentUser.id,
        deviceId: widget.deviceId,
        shiftId: shift.id,
        paymentMethod: settlement.paymentMethod,
        subtotalMinorUnits: lineTotal,
        discountMinorUnits: 0,
        totalMinorUnits: lineTotal,
        amountPaidMinorUnits: lineTotal,
        changeMinorUnits: 0,
        createdAt: now,
        items: [item],
      );

      await widget.saleRepository.saveSale(sale);
      // Confirm the receipt out loud: a loan sale moves no money, so without
      // this the dashboard and the drawer would look unchanged and the cashier
      // could think the sale was never recorded.
      final methodLabel = switch (settlement.paymentMethod) {
        'LOAN' => 'Loan (on credit)',
        'BANK' => 'Bank transfer',
        _ => 'Cash',
      };
      _showMessage(
        'Sale $receiptNumber recorded · '
        '${MoneyUtils.formatBr(lineTotal)} · $methodLabel',
      );
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

  const _SaleDraft({
    required this.name,
    required this.quantityText,
    required this.billingQuantityMilliunits,
    required this.unitPriceMinorUnits,
    required this.lineTotalMinorUnits,
  });
}

/// The settlement chosen on step two. The reason rides on the sale's line-item
/// notes, which already syncs end to end, so no schema change is needed and the
/// cloud keeps the audit trail with the sale it explains.
class _SaleSettlement {
  final String paymentMethod;
  final String reason;

  const _SaleSettlement({required this.paymentMethod, required this.reason});
}

/// Units offered in the New Sale dialog's Unit dropdown.
const List<String> _saleUnits = ['Karton', 'Kuntal', 'Derzen', 'Fre'];

/// A focused one-item sale dialog: Name, Unit, Quantity, Price with a live
/// Total. The payment method is chosen on the following screen, so this dialog
/// stays short enough to remain fully visible above the on-screen keyboard.
class _SaleDialog extends StatefulWidget {
  const _SaleDialog();

  @override
  State<_SaleDialog> createState() => _SaleDialogState();
}

class _SaleDialogState extends State<_SaleDialog> {
  final _nameController = TextEditingController();
  // Starts empty on purpose: the cashier must type the quantity, so a stray
  // "1" can never be posted by accident.
  final _quantityController = TextEditingController();
  final _priceController = TextEditingController();

  String _unit = _saleUnits.first;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
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
    return '$quantity $_unit';
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
    // Payment method is chosen on the next screen, so the fields here stay
    // fully visible even while the on-screen keyboard is up.
    Navigator.of(context).pop(
      _SaleDraft(
        name: name,
        quantityText: _quantityText,
        billingQuantityMilliunits: quantity,
        unitPriceMinorUnits: price,
        lineTotalMinorUnits: lineTotal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lineTotal = _lineTotalMinorUnits;
    // The keyboard would otherwise push the dialog's lower fields off-screen
    // (AlertDialog scrolls itself when viewInsets are applied), so neutralise
    // them for the dialog body and cap its height above the keyboard: the
    // fields scroll and the Next button always stays visible.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 190).clamp(
      200.0,
      520.0,
    );
    return AlertDialog(
      // Default horizontal insets (40) squeeze the content past a phone's
      // usable width; tightening them keeps the row of controls inside 390px.
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('New Sale'),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          // Cap the dialog at 420 on wide screens but let it shrink to the
          // viewport on a phone, so the fixed 420 never overflows a narrow width.
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxBodyHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  clipBehavior: Clip.none,
                  padding: const EdgeInsets.only(top: 8),
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
                              keyboardType:
                                  const TextInputType.numberWithOptions(
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
                            child: DropdownButtonFormField<String>(
                              initialValue: _unit,
                              isDense: true,
                              isExpanded: true,
                              decoration: const InputDecoration(
                                labelText: 'Unit',
                              ),
                              items: [
                                for (final unit in _saleUnits)
                                  DropdownMenuItem(
                                    value: unit,
                                    child: Text(unit),
                                  ),
                              ],
                              onChanged: (value) => setState(
                                () => _unit = value ?? _saleUnits.first,
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
                          children: [
                            const Text(
                              'Total',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerRight,
                                child: Text(
                                  lineTotal == null
                                      ? '—'
                                      : MoneyUtils.formatBr(lineTotal),
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
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
        FilledButton(onPressed: _submit, child: const Text('Next')),
      ],
    );
  }
}

/// The second step of the sale: shows the line just entered, asks for the
/// payment method, and requires a reason/reference. Nothing is pre-selected, so
/// the cashier must make an explicit Cash / Bank Transfer / Loan choice before
/// the sale is posted. The reason rides on the line item's notes (which already
/// syncs end to end), so no schema change is needed.
class _PaymentDialog extends StatefulWidget {
  final _SaleDraft draft;

  const _PaymentDialog({required this.draft});

  @override
  State<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends State<_PaymentDialog> {
  final _reasonController = TextEditingController();
  String? _paymentMethod;
  String? _error;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _complete() {
    final method = _paymentMethod;
    final reason = _reasonController.text.trim();
    if (method == null) {
      setState(() => _error = 'Select a payment method.');
      return;
    }
    if (reason.isEmpty) {
      setState(() => _error = 'Enter a reason for this sale.');
      return;
    }
    Navigator.of(context)
        .pop(_SaleSettlement(paymentMethod: method, reason: reason));
  }

  @override
  Widget build(BuildContext context) {
    // The keyboard lifts the dialog, so the body is capped to the space left
    // above it and scrolls instead of pushing the chips/action off-screen.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 200).clamp(
      120.0,
      420.0,
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: const Text('Payment Method'),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          // Cap at 360 on wide screens but never exceed the space above the
          // keyboard, so the summary row can't overflow a narrow phone.
          constraints: BoxConstraints(maxWidth: 360, maxHeight: maxBodyHeight),
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            padding: const EdgeInsets.only(top: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.draft.name,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.draft.quantityText,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(color: AppTheme.muted),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              alignment: Alignment.centerRight,
                              child: Text(
                                MoneyUtils.formatBr(
                                  widget.draft.lineTotalMinorUnits,
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final option in const <(String, String)>[
                      ('CASH', 'Cash'),
                      ('BANK', 'Bank Transfer'),
                      ('LOAN', 'Loan'),
                    ])
                      ChoiceChip(
                        label: Text(option.$2),
                        selected: _paymentMethod == option.$1,
                        onSelected: (_) => setState(() {
                          _paymentMethod = option.$1;
                          _error = null;
                        }),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reasonController,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    labelText: 'Reason / Reference',
                    hintText: 'Why is this sale being recorded?',
                  ),
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  onSubmitted: (_) => _complete(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back'),
        ),
        FilledButton(onPressed: _complete, child: const Text('Complete')),
      ],
    );
  }
}
