import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/utils/money_utils.dart';
import '../../core/utils/receipt_pdf_generator.dart';
import '../../core/theme/app_theme.dart';
import 'cart.dart';
import 'cart_item.dart';
import 'sale.dart';
import 'sale_item.dart';
import 'shift.dart';

class SalesScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final ShiftRepository shiftRepository;
  final User currentUser;
  final VoidCallback onSaleCompleted;

  const SalesScreen({
    super.key,
    required this.saleRepository,
    required this.shiftRepository,
    required this.currentUser,
    required this.onSaleCompleted,
  });

  @override
  State<SalesScreen> createState() => SalesScreenState();
}

class SalesScreenState extends State<SalesScreen> {
  final Cart _cart = Cart();
  bool _isProcessing = false;
  Shift? _activeShift;

  final _nameController = TextEditingController();
  final _priceController = TextEditingController();
  final _qtyController = TextEditingController(text: '1');
  final _nameFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    loadShift();
  }

  Future<void> loadShift() async {
    final shift = await widget.shiftRepository.getActiveShift();
    if (mounted) setState(() => _activeShift = shift);
  }

  void _addItem() {
    final name = _nameController.text.trim();
    final price = MoneyUtils.stringToMinorUnits(_priceController.text);
    final qty = int.tryParse(_qtyController.text);

    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter an item name.')),
      );
      return;
    }
    if (price == null || price <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid price.')),
      );
      return;
    }
    if (qty == null || qty <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid quantity.')),
      );
      return;
    }

    setState(() {
      _cart.addItem(
        CartItem(
          id: const Uuid().v4(),
          name: name,
          unitPriceMinorUnits: price,
          quantity: qty,
        ),
      );
    });

    _nameController.clear();
    _priceController.clear();
    _qtyController.text = '1';
    _nameFocusNode.requestFocus();
  }

  void _updateQuantity(String id, int newQty) {
    if (_isProcessing) return;
    setState(() {
      _cart.updateQuantity(id, newQty);
    });
  }

  Future<void> _checkout() async {
    if (_cart.items.isEmpty || _isProcessing) return;
    if (_activeShift == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please open the register before making a sale.'),
        ),
      );
      return;
    }

    final paidController = TextEditingController();
    String paymentMethod = 'CASH';
    final totalStr = MoneyUtils.minorUnitsToString(_cart.totalMinorUnits);

    paidController.text = totalStr;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isBank = paymentMethod == 'BANK';
          return AlertDialog(
            title: const Text('Checkout'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Total Due: $totalStr ETB',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 16),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'CASH',
                      label: Text('Cash'),
                      icon: Icon(Icons.money),
                    ),
                    ButtonSegment(
                      value: 'BANK',
                      label: Text('Bank Transfer'),
                      icon: Icon(Icons.account_balance),
                    ),
                  ],
                  selected: {paymentMethod},
                  onSelectionChanged: (Set<String> newSelection) {
                    setDialogState(() {
                      paymentMethod = newSelection.first;
                      if (paymentMethod == 'BANK') {
                        paidController.text = totalStr;
                      } else {
                        paidController.clear();
                      }
                    });
                  },
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: paidController,
                  readOnly: isBank,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: isBank
                        ? 'Bank Transfer Amount'
                        : 'Cash Paid (ETB)',
                  ),
                  autofocus: !isBank,
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final paidMinorUnits = MoneyUtils.stringToMinorUnits(
                    paidController.text,
                  );
                  if (paidMinorUnits == null) return;

                  if (paymentMethod == 'CASH' &&
                      paidMinorUnits < _cart.totalMinorUnits) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Amount paid is less than total!'),
                      ),
                    );
                    return;
                  }

                  Navigator.pop(context, {
                    'paid': paidMinorUnits,
                    'method': paymentMethod,
                  });
                },
                child: const Text('Complete Sale'),
              ),
            ],
          );
        },
      ),
    );

    if (result == null) return;

    setState(() => _isProcessing = true);

    try {
      final now = DateTime.now();
      final saleId = const Uuid().v4();
      final receiptNumber = 'REC-${now.millisecondsSinceEpoch}';
      final cashPaid = result['paid'] as int;
      final method = result['method'] as String;
      final changeMinorUnits = method == 'CASH'
          ? cashPaid - _cart.totalMinorUnits
          : 0;

      final items = _cart.items.map((item) {
        return SaleItem(
          id: const Uuid().v4(),
          saleId: saleId,
          productId: 'MANUAL',
          productNameSnapshot: item.name,
          unitPriceSnapshotMinorUnits: item.unitPriceMinorUnits,
          quantity: item.quantity,
          lineDiscountMinorUnits: 0,
          lineTotalMinorUnits: item.lineTotalMinorUnits,
        );
      }).toList();

      final sale = Sale(
        id: saleId,
        receiptNumber: receiptNumber,
        cashierId: widget.currentUser.id,
        deviceId: 'device-1',
        shiftId: _activeShift!.id,
        paymentMethod: method,
        subtotalMinorUnits: _cart.subtotalMinorUnits,
        discountMinorUnits: 0,
        totalMinorUnits: _cart.totalMinorUnits,
        amountPaidMinorUnits: cashPaid,
        changeMinorUnits: changeMinorUnits,
        createdAt: now,
        items: items,
      );

      await widget.saleRepository.saveSale(sale);
      widget.onSaleCompleted();

      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.check_circle, color: AppTheme.success),
              SizedBox(width: 8),
              Text('Sale Complete'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Receipt: $receiptNumber'),
              const SizedBox(height: 8),
              if (method == 'CASH')
                Text(
                  'Change Due: ${MoneyUtils.minorUnitsToString(changeMinorUnits)} ETB',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () async {
                await ReceiptPdfGenerator.printReceipt(sale);
              },
              child: const Text('Print Receipt'),
            ),
            FilledButton(
              onPressed: () {
                setState(() => _cart.clear());
                Navigator.pop(context);
              },
              child: const Text('New Sale'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Failed to save sale: $e')));
    } finally {
      if (mounted) setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          flex: 7,
          child: Container(
            color: Theme.of(context).scaffoldBackgroundColor,
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Add Item',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextField(
                                controller: _nameController,
                                focusNode: _nameFocusNode,
                                decoration: const InputDecoration(
                                  labelText: 'Item Name',
                                ),
                                onSubmitted: (_) =>
                                    FocusScope.of(context).nextFocus(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 2,
                              child: TextField(
                                controller: _priceController,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: const InputDecoration(
                                  labelText: 'Price (ETB)',
                                ),
                                onSubmitted: (_) =>
                                    FocusScope.of(context).nextFocus(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 1,
                              child: TextField(
                                controller: _qtyController,
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(
                                  labelText: 'Qty',
                                ),
                                onSubmitted: (_) => _addItem(),
                              ),
                            ),
                            const SizedBox(width: 12),
                            ElevatedButton(
                              onPressed: _addItem,
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 24,
                                  vertical: 20,
                                ),
                              ),
                              child: const Text('Add'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        Container(
          width: 400,
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            border: Border(
              left: BorderSide(color: Theme.of(context).dividerColor, width: 1),
            ),
          ),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Current Order',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).scaffoldBackgroundColor,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context).dividerColor,
                        ),
                      ),
                      child: Text(
                        '${_cart.items.length} items',
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: _cart.items.isEmpty
                    ? Center(
                        child: Text(
                          'Cart is empty',
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.all(24),
                        itemCount: _cart.items.length,
                        separatorBuilder: (context, index) =>
                            const Divider(height: 24),
                        itemBuilder: (context, index) {
                          final item = _cart.items[index];
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                        fontSize: 14,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      '${MoneyUtils.minorUnitsToString(item.unitPriceMinorUnits)} ETB',
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
                              Row(
                                children: [
                                  InkWell(
                                    onTap: () => _updateQuantity(
                                      item.id,
                                      item.quantity - 1,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Theme.of(context).dividerColor,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Icon(Icons.remove, size: 14),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 32,
                                    child: Text(
                                      '${item.quantity}',
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  InkWell(
                                    onTap: () => _updateQuantity(
                                      item.id,
                                      item.quantity + 1,
                                    ),
                                    child: Container(
                                      padding: const EdgeInsets.all(4),
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: Theme.of(context).dividerColor,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: const Icon(Icons.add, size: 14),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
              ),
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Theme.of(context).cardColor,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).dividerColor,
                      width: 1,
                    ),
                  ),
                ),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Subtotal',
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                            fontSize: 13,
                          ),
                        ),
                        Text(
                          '${MoneyUtils.minorUnitsToString(_cart.subtotalMinorUnits)} ETB',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ],
                    ),
                    const Divider(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text(
                          'Total',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                        Text(
                          '${MoneyUtils.minorUnitsToString(_cart.totalMinorUnits)} ETB',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: (_cart.items.isEmpty || _isProcessing)
                            ? null
                            : _checkout,
                        child: _isProcessing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Text('Checkout'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
