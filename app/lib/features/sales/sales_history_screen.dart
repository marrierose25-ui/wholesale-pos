import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_theme.dart';
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
  String? _error;
  final _searchController = TextEditingController();
  DateTimeRange? _selectedDateRange;

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadSales() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final sales = await widget.saleRepository.getAllSales(
        searchQuery: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        startDate: _selectedDateRange?.start,
        endDate: _selectedDateRange?.end,
      );
      if (!mounted) return;
      setState(() {
        _sales = sales;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(now.year + 1, 12, 31),
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

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  Future<bool> _voidSale(Sale sale) async {
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => _VoidSaleDialog(receiptNumber: sale.receiptNumber),
    );
    if (reason == null || !mounted) return false;

    try {
      await widget.saleRepository.voidSale(
        sale.id,
        sale.receiptNumber,
        widget.currentUser.id,
        reason,
      );
      widget.onSaleVoided();
      await _loadSales();
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
      return false;
    }
  }

  Future<void> _showReceipt(Sale sale) async {
    final isVoided = sale.status == 'VOIDED';
    final isOwner = widget.currentUser.role == 'OWNER';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Flexible(child: Text('Receipt ${sale.receiptNumber}')),
            if (isVoided) ...[
              const SizedBox(width: 8),
              const Chip(label: Text('VOIDED'), backgroundColor: Colors.red),
            ],
          ],
        ),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
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
                if (isVoided && sale.voidReason != null) ...[
                  const Divider(),
                  Text(
                    'Voided: ${sale.voidReason}',
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (isOwner && !isVoided)
            TextButton(
              onPressed: () async {
                final voided = await _voidSale(sale);
                if (voided && dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text(
                'Void Sale',
                style: TextStyle(color: AppTheme.danger),
              ),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
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
          _buildFilterBar(),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(_error!),
                        const SizedBox(height: 8),
                        TextButton(
                          onPressed: _loadSales,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
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

  Widget _buildFilterBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      color: AppTheme.surface,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final searchField = TextField(
            controller: _searchController,
            decoration: const InputDecoration(
              hintText: 'Search receipt number...',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: (_) => _loadSales(),
          );
          final actions = Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: _pickDateRange,
                icon: const Icon(Icons.calendar_today, size: 16),
                label: Text(
                  _selectedDateRange == null
                      ? 'Filter by Date'
                      : '${_formatDate(_selectedDateRange!.start)} - '
                            '${_formatDate(_selectedDateRange!.end)}',
                ),
              ),
              if (_selectedDateRange != null ||
                  _searchController.text.isNotEmpty)
                TextButton(
                  onPressed: _clearFilters,
                  child: const Text('Clear Filters'),
                ),
            ],
          );

          if (constraints.maxWidth < 800) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [searchField, const SizedBox(height: 12), actions],
            );
          }
          return Row(
            children: [
              Expanded(child: searchField),
              const SizedBox(width: 16),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _VoidSaleDialog extends StatefulWidget {
  final String receiptNumber;

  const _VoidSaleDialog({required this.receiptNumber});

  @override
  State<_VoidSaleDialog> createState() => _VoidSaleDialogState();
}

class _VoidSaleDialogState extends State<_VoidSaleDialog> {
  final _reasonController = TextEditingController();

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  void _submit() {
    final reason = _reasonController.text.trim();
    if (reason.isEmpty) return;
    Navigator.of(context).pop(reason);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Void Sale?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Void receipt ${widget.receiptNumber}? '
            'This keeps the original sale in the audit trail.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _reasonController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Reason for void'),
            maxLength: 240,
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: _reasonController.text.trim().isEmpty ? null : _submit,
          child: const Text('Void Sale'),
        ),
      ],
    );
  }
}
