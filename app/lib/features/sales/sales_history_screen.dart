import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/utils/money_utils.dart';
import '../../core/theme/app_theme.dart';
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
  final _searchController = TextEditingController();
  DateTimeRange? _selectedDateRange;

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    setState(() => _isLoading = true);
    final sales = await widget.saleRepository.getAllSales(
      searchQuery: _searchController.text.trim().isEmpty
          ? null
          : _searchController.text.trim(),
      startDate: _selectedDateRange?.start,
      endDate: _selectedDateRange?.end,
    );
    setState(() {
      _sales = sales;
      _isLoading = false;
    });
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDateRange: _selectedDateRange,
    );
    if (picked != null) {
      setState(() => _selectedDateRange = picked);
      _loadSales();
    }
  }

  void _clearFilters() {
    _searchController.clear();
    setState(() => _selectedDateRange = null);
    _loadSales();
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
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
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
        'Voided from history',
      );
      if (mounted) {
        Navigator.pop(context);
        widget.onSaleVoided();
        _loadSales();
      }
    }
  }

  void _showReceipt(Sale sale) {
    final isVoided = sale.status == 'VOIDED';
    final isOwner = widget.currentUser.role == 'OWNER';

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
              Text(
                'Payment: ${sale.paymentMethod}',
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
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
          if (isOwner && !isVoided)
            TextButton(
              onPressed: () => _voidSale(sale),
              child: const Text(
                'Void Sale',
                style: TextStyle(color: AppTheme.danger),
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
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(title: const Text('Sales History')),
      body: Column(
        children: [
          // Filter Bar
          Container(
            padding: const EdgeInsets.all(16),
            color: AppTheme.surface,
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    decoration: const InputDecoration(
                      hintText: 'Search receipt number...',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onSubmitted: (_) => _loadSales(),
                  ),
                ),
                const SizedBox(width: 16),
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(
                    _selectedDateRange == null
                        ? 'Filter by Date'
                        : '${_selectedDateRange!.start.toString().split(' ')[0]} - ${_selectedDateRange!.end.toString().split(' ')[0]}',
                  ),
                ),
                if (_selectedDateRange != null ||
                    _searchController.text.isNotEmpty) ...[
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: _clearFilters,
                    child: const Text('Clear Filters'),
                  ),
                ],
              ],
            ),
          ),

          // Results
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _sales.isEmpty
                ? const Center(
                    child: Text(
                      'No sales found.',
                      style: TextStyle(color: AppTheme.muted),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _sales.length,
                    itemBuilder: (context, index) {
                      final sale = _sales[index];
                      final isVoided = sale.status == 'VOIDED';
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isVoided
                                ? Colors.grey
                                : AppTheme.background,
                            child: Icon(
                              Icons.receipt,
                              color: isVoided
                                  ? Colors.white
                                  : AppTheme.foreground,
                              size: 20,
                            ),
                          ),
                          title: Text(
                            sale.receiptNumber,
                            style: TextStyle(
                              decoration: isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: isVoided
                                  ? Colors.grey
                                  : AppTheme.foreground,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            '${sale.createdAt.toString().split('.')[0]} • ${sale.paymentMethod}',
                          ),
                          trailing: Text(
                            '${MoneyUtils.minorUnitsToString(sale.totalMinorUnits)} ETB',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              decoration: isVoided
                                  ? TextDecoration.lineThrough
                                  : null,
                              color: isVoided
                                  ? Colors.grey
                                  : AppTheme.foreground,
                            ),
                          ),
                          onTap: () => _showReceipt(sale),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
