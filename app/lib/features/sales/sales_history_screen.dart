import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/utils/money_utils.dart';
import 'sale.dart';

class SalesHistoryScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User currentUser;
  final VoidCallback onSaleVoided;

  const SalesHistoryScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
    required this.onSaleVoided,
  });

  @override
  State<SalesHistoryScreen> createState() => _SalesHistoryScreenState();
}

class _SalesHistoryScreenState extends State<SalesHistoryScreen> {
  List<Sale> _sales = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    setState(() => _isLoading = true);
    final sales = await widget.saleRepository.getAllSales();
    setState(() {
      _sales = sales;
      _isLoading = false;
    });
  }

  Future<void> _voidSale(Sale sale) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Void Sale?'),
        content: Text(
          'Are you sure you want to void receipt ${sale.receiptNumber}?\n\nThis will remove its revenue from all reports but will not delete the record.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Void Sale'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await widget.saleRepository.voidSale(
        sale.id,
        sale.receiptNumber,
        widget.currentUser.id,
      );
      if (mounted) {
        Navigator.pop(context); // Close the receipt dialog
        _loadSales(); // Refresh the list
      }
    }
  }

  void _showReceipt(Sale sale) {
    final isVoided = sale.status == 'VOIDED';

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Text('Receipt ${sale.receiptNumber}'),
            if (isVoided) ...[
              const SizedBox(width: 8),
              const Chip(label: Text('VOIDED'), backgroundColor: Colors.red),
            ],
          ],
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Date: ${sale.createdAt.toString().split('.')[0]}'),
              const Divider(),
              ...sale.items.map(
                (item) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '${item.quantity}x ${item.productNameSnapshot}',
                        ),
                      ),
                      Text(
                        '${MoneyUtils.minorUnitsToString(item.lineTotalMinorUnits)} ETB',
                      ),
                    ],
                  ),
                ),
              ),
              const Divider(),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Subtotal:'),
                  Text(
                    '${MoneyUtils.minorUnitsToString(sale.subtotalMinorUnits)} ETB',
                  ),
                ],
              ),
              if (sale.discountMinorUnits > 0)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Discount:'),
                    Text(
                      '- ${MoneyUtils.minorUnitsToString(sale.discountMinorUnits)} ETB',
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'TOTAL:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text(
                    '${MoneyUtils.minorUnitsToString(sale.totalMinorUnits)} ETB',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
        actions: [
          if (!isVoided)
            TextButton(
              onPressed: () => _voidSale(sale),
              child: const Text(
                'Void Sale',
                style: TextStyle(color: Colors.red),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_sales.isEmpty) {
      return const Center(child: Text('No sales recorded yet.'));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sales History'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadSales),
        ],
      ),
      body: ListView.builder(
        itemCount: _sales.length,
        itemBuilder: (context, index) {
          final sale = _sales[index];
          final isVoided = sale.status == 'VOIDED';
          return ListTile(
            leading: Icon(Icons.receipt, color: isVoided ? Colors.grey : null),
            title: Text(
              sale.receiptNumber,
              style: TextStyle(
                decoration: isVoided ? TextDecoration.lineThrough : null,
                color: isVoided ? Colors.grey : null,
              ),
            ),
            subtitle: Text(sale.createdAt.toString().split('.')[0]),
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${MoneyUtils.minorUnitsToString(sale.totalMinorUnits)} ETB',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                    decoration: isVoided ? TextDecoration.lineThrough : null,
                    color: isVoided ? Colors.grey : null,
                  ),
                ),
                if (isVoided)
                  const Text(
                    'VOIDED',
                    style: TextStyle(
                      color: Colors.red,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
            onTap: () => _showReceipt(sale),
          );
        },
      ),
    );
  }
}
