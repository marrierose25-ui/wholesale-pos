import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/product.dart';
import '../../core/models/user.dart';
import '../../core/repositories/product_repository.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';
import '../../core/utils/receipt_pdf_generator.dart';
import 'cart.dart';
import 'cart_item.dart';
import 'sale.dart';
import 'sale_item.dart';
import 'shift.dart';

class SalesScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final ShiftRepository shiftRepository;
  final ProductRepository productRepository;
  final String deviceId;
  final User currentUser;
  final VoidCallback onSaleCompleted;

  const SalesScreen({
    super.key,
    required this.saleRepository,
    required this.shiftRepository,
    required this.productRepository,
    required this.deviceId,
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
  final _productSearchController = TextEditingController();
  final _nameFocusNode = FocusNode();

  List<Product> _products = [];
  bool _productsLoading = true;
  String? _productError;

  @override
  void initState() {
    super.initState();
    loadShift();
    _loadProducts();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    _qtyController.dispose();
    _productSearchController.dispose();
    _nameFocusNode.dispose();
    super.dispose();
  }

  Future<void> loadShift() async {
    try {
      final shift = await widget.shiftRepository.getActiveShift();
      if (mounted) setState(() => _activeShift = shift);
    } catch (_) {
      if (mounted) setState(() => _activeShift = null);
    }
  }

  Future<void> _loadProducts() async {
    setState(() {
      _productsLoading = true;
      _productError = null;
    });
    try {
      final products = await widget.productRepository.getAllActive();
      if (!mounted) return;
      setState(() {
        _products = products;
        _productsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _productsLoading = false;
        _productError = 'Could not load the product catalog.';
      });
    }
  }

  List<Product> get _filteredProducts {
    final query = _productSearchController.text.trim().toLowerCase();
    if (query.isEmpty) return _products;
    return _products.where((product) {
      return product.name.toLowerCase().contains(query) ||
          product.code.toLowerCase().contains(query);
    }).toList();
  }

  void _addProduct(Product product) {
    if (_isProcessing) return;
    setState(() {
      _cart.addItem(
        CartItem(
          id: const Uuid().v4(),
          productId: product.id,
          name: product.name,
          unitPriceMinorUnits: product.sellingPriceMinorUnits,
        ),
      );
    });
  }

  void _addItem() {
    if (_isProcessing) return;
    final name = _nameController.text.trim();
    final price = MoneyUtils.stringToMinorUnits(_priceController.text);
    final qty = int.tryParse(_qtyController.text);

    if (name.isEmpty) {
      _showMessage('Please enter an item name.');
      return;
    }
    if (price == null || price <= 0) {
      _showMessage('Please enter a valid price.');
      return;
    }
    if (qty == null || qty <= 0) {
      _showMessage('Please enter a valid quantity.');
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

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
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
      _showMessage('Please open the register before making a sale.');
      return;
    }

    final totalMinorUnits = _cart.totalMinorUnits;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _CheckoutDialog(totalMinorUnits: totalMinorUnits),
    );
    if (result == null) return;

    setState(() => _isProcessing = true);

    try {
      final now = DateTime.now();
      final saleId = const Uuid().v4();
      final receiptNumber = await widget.saleRepository.nextReceiptNumber();
      final cashPaid = result['paid'] as int;
      final method = result['method'] as String;
      final changeMinorUnits = method == 'CASH'
          ? cashPaid - totalMinorUnits
          : 0;

      final items = _cart.items.map((item) {
        return SaleItem(
          id: const Uuid().v4(),
          saleId: saleId,
          productId: item.productId,
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
        deviceId: widget.deviceId,
        shiftId: _activeShift!.id,
        paymentMethod: method,
        subtotalMinorUnits: _cart.subtotalMinorUnits,
        discountMinorUnits: 0,
        totalMinorUnits: totalMinorUnits,
        amountPaidMinorUnits: cashPaid,
        changeMinorUnits: changeMinorUnits,
        createdAt: now,
        items: items,
      );

      await widget.saleRepository.saveSale(sale);
      widget.onSaleCompleted();

      if (!mounted) return;

      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
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
                  'Change Due: '
                  '${MoneyUtils.minorUnitsToString(changeMinorUnits)} ETB',
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
                try {
                  await ReceiptPdfGenerator.printReceipt(sale);
                } catch (e) {
                  if (!dialogContext.mounted) return;
                  ScaffoldMessenger.of(dialogContext).showSnackBar(
                    SnackBar(content: Text('Could not print receipt: $e')),
                  );
                }
              },
              child: const Text('Print Receipt'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('New Sale'),
            ),
          ],
        ),
      );

      if (!mounted) return;
      setState(() => _cart.clear());
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
    return LayoutBuilder(
      builder: (context, constraints) {
        final cartWidth = constraints.maxWidth >= 1200
            ? 400.0
            : constraints.maxWidth >= 900
            ? 340.0
            : 300.0;

        return Row(
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).scaffoldBackgroundColor,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildAddItemCard(),
                    const SizedBox(height: 16),
                    Expanded(child: _buildProductCatalog()),
                  ],
                ),
              ),
            ),
            SizedBox(width: cartWidth, child: _buildCartPanel(context)),
          ],
        );
      },
    );
  }

  Widget _buildAddItemCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Item',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _nameController,
                    focusNode: _nameFocusNode,
                    decoration: const InputDecoration(labelText: 'Item Name'),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _priceController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Price (ETB)'),
                    onSubmitted: (_) => FocusScope.of(context).nextFocus(),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _qtyController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Qty'),
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
    );
  }

  Widget _buildProductCatalog() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'Product Catalog',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload products',
                  onPressed: _loadProducts,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: TextField(
              controller: _productSearchController,
              decoration: InputDecoration(
                labelText: 'Search by name or code',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _productSearchController.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _productSearchController.clear();
                          setState(() {});
                        },
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(child: _buildProductList()),
        ],
      ),
    );
  }

  Widget _buildProductList() {
    if (_productsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_productError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_productError!),
            const SizedBox(height: 8),
            TextButton(onPressed: _loadProducts, child: const Text('Retry')),
          ],
        ),
      );
    }

    final products = _filteredProducts;
    if (products.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _products.isEmpty
                ? 'No products yet. Add them from the Products screen, '
                      'or use the manual item form above.'
                : 'No products match this search.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: products.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final product = products[index];
        return ListTile(
          leading: const Icon(Icons.add_circle_outline),
          title: Text(product.name),
          subtitle: Text('${product.code} • ${product.unit}'),
          trailing: Text(
            '${MoneyUtils.minorUnitsToString(product.sellingPriceMinorUnits)} ETB',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _addProduct(product),
        );
      },
    );
  }

  Widget _buildCartPanel(BuildContext context) {
    final itemCount = _cart.items.length;
    return Container(
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
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Theme.of(context).scaffoldBackgroundColor,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Theme.of(context).dividerColor),
                  ),
                  child: Text(
                    '$itemCount ${itemCount == 1 ? 'item' : 'items'}',
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
                                onTap: () =>
                                    _updateQuantity(item.id, item.quantity - 1),
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
                                onTap: () =>
                                    _updateQuantity(item.id, item.quantity + 1),
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
    );
  }
}

class _CheckoutDialog extends StatefulWidget {
  final int totalMinorUnits;

  const _CheckoutDialog({required this.totalMinorUnits});

  @override
  State<_CheckoutDialog> createState() => _CheckoutDialogState();
}

class _CheckoutDialogState extends State<_CheckoutDialog> {
  late final TextEditingController _paidController;
  String _paymentMethod = 'CASH';
  String? _error;

  String get _totalText =>
      MoneyUtils.minorUnitsToString(widget.totalMinorUnits);

  @override
  void initState() {
    super.initState();
    _paidController = TextEditingController(text: _totalText);
  }

  @override
  void dispose() {
    _paidController.dispose();
    super.dispose();
  }

  void _complete() {
    final paidMinorUnits = MoneyUtils.stringToMinorUnits(_paidController.text);
    if (paidMinorUnits == null) {
      setState(() => _error = 'Enter a valid amount.');
      return;
    }
    if (_paymentMethod == 'CASH' && paidMinorUnits < widget.totalMinorUnits) {
      setState(() => _error = 'Amount paid is less than the total.');
      return;
    }
    Navigator.of(context)
        .pop({'paid': paidMinorUnits, 'method': _paymentMethod});
  }

  @override
  Widget build(BuildContext context) {
    final isBank = _paymentMethod == 'BANK';
    return AlertDialog(
      title: const Text('Checkout'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Total Due: $_totalText ETB',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
            selected: {_paymentMethod},
            onSelectionChanged: (selection) {
              setState(() {
                _paymentMethod = selection.first;
                _error = null;
                _paidController.text = _paymentMethod == 'BANK'
                    ? _totalText
                    : '';
              });
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _paidController,
            readOnly: isBank,
            autofocus: !isBank,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: isBank ? 'Bank Transfer Amount' : 'Cash Paid (ETB)',
            ),
            onSubmitted: (_) => _complete(),
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
        FilledButton(onPressed: _complete, child: const Text('Complete Sale')),
      ],
    );
  }
}
