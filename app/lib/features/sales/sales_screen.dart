import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/product.dart';
import '../../core/models/user.dart';
import '../../core/repositories/product_repository.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/repositories/shift_repository.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/date_range.dart';
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
  final _customerNameController = TextEditingController();

  List<Product> _savedNames = [];
  bool _savedNamesLoading = true;

  List<Sale> _recentSales = [];

  @override
  void initState() {
    super.initState();
    loadShift();
    _loadSavedNames();
    _loadRecentSales();
  }

  @override
  void dispose() {
    _customerNameController.dispose();
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

  Future<void> _loadSavedNames() async {
    setState(() => _savedNamesLoading = true);
    try {
      final products = await widget.productRepository.getAllActive();
      if (!mounted) return;
      setState(() {
        _savedNames = products;
        _savedNamesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _savedNamesLoading = false);
      // Saved names are optional; manual entry still works without them.
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Loads today's and yesterday's sales for the POS recent-sales panel so the
  /// cashier can see recent history without leaving the register.
  Future<void> _loadRecentSales() async {
    final now = DateTime.now();
    final range = DateRange.custom(now.subtract(const Duration(days: 1)), now);
    try {
      final sales = await widget.saleRepository.getSales(
        period: range,
        status: 'ALL',
        limit: 40,
      );
      if (!mounted) return;
      setState(() => _recentSales = sales);
    } catch (_) {
      // Recent sales are informational; ignore load failures.
    }
  }

  Future<void> _showLineDialog({
    CartItem? editing,
    String? prefillName,
    int? prefillPriceMinorUnits,
  }) async {
    final result = await showDialog<CartItem>(
      context: context,
      builder: (context) => _LineItemDialog(
        savedNames: _savedNames,
        initial: editing,
        prefillName: prefillName,
        prefillPriceMinorUnits: prefillPriceMinorUnits,
      ),
    );
    if (result == null) return;
    setState(() {
      if (editing == null) {
        _cart.addItem(result);
      } else {
        _cart.replaceItem(result);
      }
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
          quantityText: item.quantityText,
          billingQuantityMilliunits: item.usesManualLineTotal
              ? null
              : item.billingQuantityMilliunits,
          lineDiscountMinorUnits: 0,
          lineTotalMinorUnits: item.lineTotalMinorUnits,
          notes: item.notes,
        );
      }).toList();

      final customerName = _customerNameController.text.trim();

      final sale = Sale(
        id: saleId,
        receiptNumber: receiptNumber,
        cashierId: widget.currentUser.id,
        deviceId: widget.deviceId,
        shiftId: _activeShift!.id,
        customerName: customerName.isEmpty ? null : customerName,
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Total: ${MoneyUtils.formatBr(totalMinorUnits)}',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 8),
              if (method == 'CASH')
                Text(
                  'Change Due: ${MoneyUtils.formatBr(changeMinorUnits)}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              if (customerName.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Customer: $customerName'),
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
      setState(() {
        _cart.clear();
        _customerNameController.clear();
      });
      _loadRecentSales();
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
            ? 420.0
            : constraints.maxWidth >= 900
            ? 360.0
            : 320.0;

        return Row(
          children: [
            Expanded(
              child: Container(
                color: Theme.of(context).scaffoldBackgroundColor,
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_activeShift == null) ...[
                      _buildClosedRegisterBanner(),
                      const SizedBox(height: 16),
                    ],
                    _buildAddItemCard(),
                    const SizedBox(height: 16),
                    Expanded(flex: 3, child: _buildSavedNamesCard()),
                    const SizedBox(height: 16),
                    Expanded(flex: 2, child: _buildRecentSalesCard()),
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

  Widget _buildClosedRegisterBanner() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 18),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'The register is closed. Open it from the Register screen '
              'before making a sale.',
              style: TextStyle(fontSize: 13),
            ),
          ),
          TextButton(onPressed: loadShift, child: const Text('Refresh')),
        ],
      ),
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
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Add Item',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _showLineDialog(),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add Line'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Type any product name. Quantities can be words, e.g. '
              '"2 boxes and 1 piece".',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            _buildSavedNameSuggestions(),
          ],
        ),
      ),
    );
  }

  /// Quick-fill chips from the saved-names list so repetitive sales are fast.
  /// Purely optional: the cashier can always type a brand-new name.
  Widget _buildSavedNameSuggestions() {
    if (_savedNamesLoading || _savedNames.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: _savedNames.take(12).map((product) {
        return ActionChip(
          label: Text(product.name),
          onPressed: () => _showLineDialog(
            editing: null,
            prefillName: product.name,
            prefillPriceMinorUnits: product.sellingPriceMinorUnits > 0
                ? product.sellingPriceMinorUnits
                : null,
          ),
        );
      }).toList(),
    );
  }

  Widget _buildSavedNamesCard() {
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
                    'Saved Names',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload saved names',
                  onPressed: _loadSavedNames,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(child: _buildSavedNamesList()),
        ],
      ),
    );
  }

  Widget _buildSavedNamesList() {
    if (_savedNamesLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_savedNames.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'No saved names yet. Names are optional — you can always type '
            'new ones on each sale. The owner can save frequent names from '
            'the Saved Names screen.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.only(bottom: 12),
      itemCount: _savedNames.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final product = _savedNames[index];
        return ListTile(
          dense: true,
          leading: const Icon(Icons.add_circle_outline),
          title: Text(product.name),
          trailing: Text(
            MoneyUtils.formatBr(product.sellingPriceMinorUnits),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          onTap: () => _showLineDialog(
            editing: null,
            prefillName: product.name,
            prefillPriceMinorUnits: product.sellingPriceMinorUnits > 0
                ? product.sellingPriceMinorUnits
                : null,
          ),
        );
      },
    );
  }

  /// DineFlow-style recent-sales panel: today + yesterday at a glance so the
  /// cashier can verify a mistake without leaving the register.
  Widget _buildRecentSalesCard() {
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
                    'Recent Sales',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  tooltip: 'Reload recent sales',
                  onPressed: _loadRecentSales,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _recentSales.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No sales today or yesterday yet.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: _recentSales.length,
                    separatorBuilder: (context, index) =>
                        const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _buildRecentSaleRow(_recentSales[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildRecentSaleRow(Sale sale) {
    final isVoid = sale.status == 'VOIDED';
    final timeLabel =
        '${sale.createdAt.hour.toString().padLeft(2, '0')}:'
        '${sale.createdAt.minute.toString().padLeft(2, '0')}';
    final amountStyle = TextStyle(
      fontWeight: FontWeight.w600,
      color: isVoid ? Theme.of(context).textTheme.bodySmall?.color : null,
      decoration: isVoid ? TextDecoration.lineThrough : null,
    );
    return InkWell(
      onTap: () => _showRecentSaleDetail(sale),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Text(
                timeLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _recentHeadline(sale),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        _recentDayLabel(sale.createdAt),
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                      if (sale.customerName != null &&
                          sale.customerName!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            sale.customerName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color,
                            ),
                          ),
                        ),
                      ],
                      if (sale.hasPendingVoidRequest) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.warning.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'REQ',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.warning,
                            ),
                          ),
                        ),
                      ],
                      if (isVoid) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: AppTheme.danger.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'VOID',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppTheme.danger,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(MoneyUtils.formatBr(sale.totalMinorUnits), style: amountStyle),
          ],
        ),
      ),
    );
  }

  /// A short headline for a row: first item name plus a count of extra lines.
  String _recentHeadline(Sale sale) {
    if (sale.items.isEmpty) return 'Sale';
    final first = sale.items.first.productNameSnapshot;
    final extra = sale.items.length - 1;
    if (extra > 0) return '$first +$extra more';
    return first;
  }

  String _recentDayLabel(DateTime moment) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(moment.year, moment.month, moment.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '${day.year}-${day.month.toString().padLeft(2, '0')}-'
        '${day.day.toString().padLeft(2, '0')}';
  }

  Future<void> _showRecentSaleDetail(Sale sale) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(_recentDayLabel(sale.createdAt)),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Time: ${sale.createdAt.hour.toString().padLeft(2, '0')}:'
                '${sale.createdAt.minute.toString().padLeft(2, '0')}  •  '
                '${sale.paymentMethod}',
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
                ),
              ),
              if (sale.customerName != null && sale.customerName!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Customer: ${sale.customerName}'),
                ),
              const SizedBox(height: 12),
              if (sale.items.isEmpty)
                const Text('No item detail recorded.')
              else
                ...sale.items.map(
                  (item) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            '${item.productNameSnapshot}  (${item.quantityText})',
                          ),
                        ),
                        Text(MoneyUtils.formatBr(item.lineTotalMinorUnits)),
                      ],
                    ),
                  ),
                ),
              const Divider(height: 24),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Total',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    MoneyUtils.formatBr(sale.totalMinorUnits),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              if (sale.status == 'VOIDED')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Voided${sale.voidReason != null ? ': ${sale.voidReason}' : ''}',
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (sale.hasPendingVoidRequest)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'A void has been requested and is awaiting owner approval.',
                    style: TextStyle(
                      color: AppTheme.warning,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
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
                  'Current Sale',
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
                    '$itemCount ${itemCount == 1 ? 'line' : 'lines'}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: TextField(
              controller: _customerNameController,
              decoration: const InputDecoration(
                labelText: 'Customer Name (optional)',
                prefixIcon: Icon(Icons.person_outline),
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: _cart.items.isEmpty
                ? Center(
                    child: Text(
                      'Add items to start a sale',
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
                      return _buildCartLine(item);
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
                      MoneyUtils.formatBr(_cart.subtotalMinorUnits),
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
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
                      MoneyUtils.formatBr(_cart.totalMinorUnits),
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (itemCount > 0)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: _isProcessing
                          ? null
                          : () => setState(() => _cart.clear()),
                      child: const Text('Clear Sale'),
                    ),
                  ),
                const SizedBox(height: 8),
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

  Widget _buildCartLine(CartItem item) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
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
                    '${item.quantityText} @ '
                    '${MoneyUtils.formatBr(item.unitPriceMinorUnits)} each',
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color,
                      fontSize: 12,
                    ),
                  ),
                  if (item.usesManualLineTotal)
                    Text(
                      'Manual amount',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontSize: 11,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  if (item.notes != null && item.notes!.trim().isNotEmpty)
                    Text(
                      'Note: ${item.notes}',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontSize: 11,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              MoneyUtils.formatBr(item.lineTotalMinorUnits),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            PopupMenuButton<String>(
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.edit_outlined),
                    title: Text('Edit'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'remove',
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.delete_outline),
                    title: Text('Remove'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'edit') {
                  _showLineDialog(editing: item);
                } else if (value == 'remove') {
                  setState(() => _cart.removeItem(item.id));
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

/// Dialog for entering or editing one sale line. The quantity is free text;
/// the numeric billing quantity and the manual amount are kept explicitly
/// separate so descriptive quantities are never silently turned into numbers.
class _LineItemDialog extends StatefulWidget {
  final List<Product> savedNames;
  final CartItem? initial;
  final String? prefillName;
  final int? prefillPriceMinorUnits;

  const _LineItemDialog({
    required this.savedNames,
    this.initial,
    this.prefillName,
    this.prefillPriceMinorUnits,
  });

  @override
  State<_LineItemDialog> createState() => _LineItemDialogState();
}

class _LineItemDialogState extends State<_LineItemDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _priceController;
  late final TextEditingController _quantityController;
  late final TextEditingController _billingQuantityController;
  late final TextEditingController _manualAmountController;
  late final TextEditingController _notesController;

  late bool _manualMode;
  bool _billingTouched = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _nameController = TextEditingController(
      text: initial?.name ?? widget.prefillName ?? '',
    );
    _priceController = TextEditingController(
      text: initial == null
          ? (widget.prefillPriceMinorUnits == null
                ? ''
                : MoneyUtils.minorUnitsToString(widget.prefillPriceMinorUnits!))
          : MoneyUtils.minorUnitsToString(initial.unitPriceMinorUnits),
    );
    _quantityController = TextEditingController(
      text: initial?.quantityText ?? '',
    );
    _billingQuantityController = TextEditingController(
      text: initial == null || initial.billingQuantityMilliunits == null
          ? ''
          : MoneyUtils.milliunitsToString(initial.billingQuantityMilliunits!),
    );
    _manualAmountController = TextEditingController(
      text: initial != null && initial.usesManualLineTotal
          ? MoneyUtils.minorUnitsToString(initial.manualLineTotalMinorUnits!)
          : '',
    );
    _notesController = TextEditingController(text: initial?.notes ?? '');
    _manualMode = initial?.usesManualLineTotal ?? false;
    _billingTouched = _billingQuantityController.text.isNotEmpty;
    _quantityController.addListener(_syncBillingFromQuantity);
  }

  void _syncBillingFromQuantity() {
    if (_manualMode || _billingTouched) return;
    final parsed = MoneyUtils.stringToMilliunits(_quantityController.text);
    final next = parsed == null ? '' : MoneyUtils.milliunitsToString(parsed);
    if (next != _billingQuantityController.text) {
      _billingQuantityController.text = next;
    }
  }

  @override
  void dispose() {
    _quantityController.removeListener(_syncBillingFromQuantity);
    _nameController.dispose();
    _priceController.dispose();
    _quantityController.dispose();
    _billingQuantityController.dispose();
    _manualAmountController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Parses the form into a cart item, or returns an error message.
  (CartItem?, String?) _parseForm() {
    final name = _nameController.text.trim();
    if (name.isEmpty) return (null, 'Enter a product name.');

    final price = MoneyUtils.stringToMinorUnits(_priceController.text);
    if (price == null || price <= 0) {
      return (null, 'Enter a valid unit price in Br.');
    }

    final quantityText = _quantityController.text.trim();
    if (quantityText.isEmpty) {
      return (null, 'Enter a quantity, e.g. "2 boxes" or "1.5 kg".');
    }

    int? manualTotal;
    int? billingMilliunits;

    if (_manualMode) {
      manualTotal = MoneyUtils.stringToMinorUnits(_manualAmountController.text);
      if (manualTotal == null || manualTotal <= 0) {
        return (null, 'Enter the line amount in Br.');
      }
    } else {
      final billingText = _billingQuantityController.text.trim();
      if (billingText.isEmpty) {
        return (
          null,
          'Enter a billing quantity (a number like 2 or 1.5), or switch '
              'to "Manual amount" when the quantity is not a number.',
        );
      }
      billingMilliunits = MoneyUtils.stringToMilliunits(billingText);
      if (billingMilliunits == null) {
        return (null, 'Billing quantity must be a number like 2 or 1.5.');
      }
      if (MoneyUtils.tryLineTotalMinorUnits(price, billingMilliunits) == null) {
        return (null, 'The calculated amount is too large.');
      }
    }

    final notes = _notesController.text.trim();

    return (
      CartItem(
        id: widget.initial?.id ?? const Uuid().v4(),
        productId: widget.initial?.productId ?? 'MANUAL',
        name: name,
        unitPriceMinorUnits: price,
        quantityText: quantityText,
        billingQuantityMilliunits: billingMilliunits,
        manualLineTotalMinorUnits: manualTotal,
        notes: notes.isEmpty ? null : notes,
      ),
      null,
    );
  }

  void _submit() {
    final (item, error) = _parseForm();
    if (item == null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(item);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add Item' : 'Edit Item'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _nameController,
                autofocus: widget.initial == null,
                decoration: const InputDecoration(
                  labelText: 'Product Name',
                  hintText: 'Type any name, new or repeated',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Unit Price (Br)',
                  hintText: 'e.g. 500',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _quantityController,
                decoration: const InputDecoration(
                  labelText: 'Quantity',
                  hintText: 'e.g. 2 boxes and 1 piece',
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    label: Text('Price x Quantity'),
                    icon: Icon(Icons.calculate_outlined),
                  ),
                  ButtonSegment(
                    value: true,
                    label: Text('Manual Amount'),
                    icon: Icon(Icons.edit_note),
                  ),
                ],
                selected: {_manualMode},
                onSelectionChanged: (selection) => setState(() {
                  _manualMode = selection.first;
                  _error = null;
                }),
              ),
              const SizedBox(height: 12),
              if (!_manualMode)
                TextField(
                  controller: _billingQuantityController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Billing Quantity',
                    helperText:
                        'The number used to calculate the total, e.g. 2 or '
                        '1.5. Filled automatically when the quantity above is '
                        'a plain number.',
                  ),
                  onChanged: (_) {
                    _billingTouched = true;
                    setState(() {});
                  },
                )
              else
                TextField(
                  controller: _manualAmountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Line Amount (Br)',
                    helperText:
                        'The final amount for this line. Use this when the '
                        'quantity cannot be interpreted as a number.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                ),
              ),
              const SizedBox(height: 16),
              _buildPreview(),
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
        FilledButton(onPressed: _submit, child: const Text('Add to Sale')),
      ],
    );
  }

  Widget _buildPreview() {
    final (item, _) = _parseForm();
    if (item == null) {
      final quantityParsed =
          MoneyUtils.stringToMilliunits(_quantityController.text) != null;
      if (!_manualMode && !quantityParsed) {
        return Text(
          'The quantity is descriptive. The billing quantity or a manual '
          'amount decides the total — nothing is guessed.',
          style: TextStyle(
            color: Theme.of(context).textTheme.bodySmall?.color,
            fontSize: 12,
          ),
        );
      }
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            item.usesManualLineTotal
                ? 'Manual line total'
                : '${item.quantityText} x '
                      '${MoneyUtils.formatBr(item.unitPriceMinorUnits)}',
            style: const TextStyle(fontSize: 13),
          ),
          Text(
            MoneyUtils.formatBr(item.lineTotalMinorUnits),
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
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
            'Total Due: ${MoneyUtils.formatBr(widget.totalMinorUnits)}',
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
              labelText: isBank
                  ? 'Bank Transfer Amount (Br)'
                  : 'Cash Paid (Br)',
            ),
            onSubmitted: (_) => _complete(),
          ),
          if (!isBank) ...[
            const SizedBox(height: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _paidController,
              builder: (context, value, _) {
                final paid = MoneyUtils.stringToMinorUnits(value.text);
                if (paid == null || paid < widget.totalMinorUnits) {
                  return const SizedBox.shrink();
                }
                return Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Change: '
                    '${MoneyUtils.formatBr(paid - widget.totalMinorUnits)}',
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                );
              },
            ),
          ],
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
