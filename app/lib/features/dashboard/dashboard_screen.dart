import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/utils/money_utils.dart';

class DashboardScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const DashboardScreen({super.key, required this.saleRepository});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  int _todayRevenue = 0;
  List<Map<String, dynamic>> _productSummary = [];
  List<Map<String, dynamic>> _cashierSummary = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    loadDashboard();
  }

  Future<void> loadDashboard() async {
    setState(() => _isLoading = true);

    final revenue = await widget.saleRepository.getTodayRevenue();
    final products = await widget.saleRepository.getProductSalesSummary();
    final cashiers = await widget.saleRepository.getCashierPerformance();

    setState(() {
      _todayRevenue = revenue;
      _productSummary = products;
      _cashierSummary = cashiers;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadDashboard),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Today's Revenue Card
            Card(
              color: Colors.blue[50],
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  children: [
                    const Icon(
                      Icons.attach_money,
                      size: 48,
                      color: Colors.blue,
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Today\'s Revenue',
                          style: TextStyle(fontSize: 16, color: Colors.grey),
                        ),
                        Text(
                          '${MoneyUtils.minorUnitsToString(_todayRevenue)} ETB',
                          style: const TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.bold,
                            color: Colors.blue,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Product Sales Summary
            Text(
              'Product Sales Summary',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Card(
              child: SizedBox(
                width: double.infinity,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Product')),
                    DataColumn(label: Text('Qty Sold'), numeric: true),
                    DataColumn(label: Text('Revenue'), numeric: true),
                  ],
                  rows: _productSummary.map((row) {
                    return DataRow(
                      cells: [
                        DataCell(Text(row['product_name_snapshot'] as String)),
                        DataCell(Text(row['total_qty'].toString())),
                        DataCell(
                          Text(
                            '${MoneyUtils.minorUnitsToString(row['total_revenue'] as int)} ETB',
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Cashier Performance
            Text(
              'Cashier Performance',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            Card(
              child: SizedBox(
                width: double.infinity,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Cashier')),
                    DataColumn(label: Text('Total Sales'), numeric: true),
                    DataColumn(label: Text('Revenue'), numeric: true),
                  ],
                  rows: _cashierSummary.map((row) {
                    return DataRow(
                      cells: [
                        DataCell(Text(row['username'] as String)),
                        DataCell(Text(row['total_sales'].toString())),
                        DataCell(
                          Text(
                            '${MoneyUtils.minorUnitsToString(row['total_revenue'] as int)} ETB',
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
