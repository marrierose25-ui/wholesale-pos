import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';

class ReportsScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const ReportsScreen({super.key, required this.saleRepository});

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen> {
  List<Map<String, dynamic>> _products = [];
  List<Map<String, dynamic>> _cashiers = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    loadReports();
  }

  Future<void> loadReports() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.saleRepository.getProductSalesSummary(),
        widget.saleRepository.getCashierPerformance(),
      ]);
      if (!mounted) return;
      setState(() {
        _products = results[0];
        _cashiers = results[1];
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

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            const SizedBox(height: 8),
            TextButton(onPressed: loadReports, child: const Text('Retry')),
          ],
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Reports'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadReports),
          const SizedBox(width: 16),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final productsCard = _buildProductsCard();
            final cashiersCard = _buildCashiersCard();
            if (constraints.maxWidth < 1000) {
              return Column(
                children: [
                  productsCard,
                  const SizedBox(height: 24),
                  cashiersCard,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: productsCard),
                const SizedBox(width: 24),
                Expanded(child: cashiersCard),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildProductsCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Top Products',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_products.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No completed sales yet.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Product')),
                  DataColumn(label: Text('Qty'), numeric: true),
                  DataColumn(label: Text('Revenue'), numeric: true),
                ],
                rows: _products.map((row) {
                  final revenue = (row['total_revenue'] as int?) ?? 0;
                  return DataRow(
                    cells: [
                      DataCell(Text(row['product_name_snapshot'] as String)),
                      DataCell(Text('${row['total_qty'] ?? 0}')),
                      DataCell(
                        Text('${MoneyUtils.minorUnitsToString(revenue)} ETB'),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCashiersCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Icon(
                  Icons.people_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Cashier Performance',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (_cashiers.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No completed sales yet.',
                style: TextStyle(color: AppTheme.muted, fontSize: 13),
              ),
            )
          else
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: DataTable(
                columns: const [
                  DataColumn(label: Text('Cashier')),
                  DataColumn(label: Text('Sales'), numeric: true),
                  DataColumn(label: Text('Revenue'), numeric: true),
                ],
                rows: _cashiers.map((row) {
                  final revenue = (row['total_revenue'] as int?) ?? 0;
                  return DataRow(
                    cells: [
                      DataCell(Text(row['username'] as String)),
                      DataCell(Text('${row['total_sales'] ?? 0}')),
                      DataCell(
                        Text('${MoneyUtils.minorUnitsToString(revenue)} ETB'),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }
}
