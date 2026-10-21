import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/utils/money_utils.dart';
import '../sales/sale.dart';

class DashboardScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const DashboardScreen({super.key, required this.saleRepository});

  @override
  State<DashboardScreen> createState() => DashboardScreenState();
}

class DashboardScreenState extends State<DashboardScreen> {
  Map<String, int> _stats = {};
  List<Sale> _recentSales = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    loadDashboard();
  }

  Future<void> loadDashboard() async {
    setState(() => _isLoading = true);

    final stats = await widget.saleRepository.getDashboardStats();
    final allSales = await widget.saleRepository.getAllSales();
    final recent = allSales.take(5).toList();

    setState(() {
      _stats = stats;
      _recentSales = recent;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: loadDashboard),
          const SizedBox(width: 16),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top Stat Cards
            Row(
              children: [
                Expanded(
                  child: _buildStatCard(
                    'Today\'s Revenue',
                    _stats['today_revenue'] ?? 0,
                    isPrimary: true,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildStatCard(
                    'Cash Collected',
                    _stats['today_cash'] ?? 0,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildStatCard(
                    'Digital Payments',
                    _stats['today_bank'] ?? 0,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: _buildStatCard(
                    'Register Expected Cash',
                    _stats['expected_cash'] ?? 0,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // Bottom Section
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Recent Transactions
                Expanded(
                  flex: 2,
                  child: Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text(
                            'Recent Transactions',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const Divider(height: 1),
                        if (_recentSales.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              'No sales recorded yet.',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                              ),
                            ),
                          )
                        else
                          ..._recentSales.map(
                            (sale) => ListTile(
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 8,
                              ),
                              leading: CircleAvatar(
                                backgroundColor: sale.status == 'VOIDED'
                                    ? Colors.grey
                                    : Theme.of(context).scaffoldBackgroundColor,
                                child: Icon(
                                  Icons.receipt,
                                  color: sale.status == 'VOIDED'
                                      ? Colors.white
                                      : Theme.of(context).colorScheme.onSurface,
                                  size: 20,
                                ),
                              ),
                              title: Text(
                                sale.receiptNumber,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                  fontSize: 14,
                                ),
                              ),
                              subtitle: Text(
                                '${sale.createdAt.toString().split('.')[0]} â€¢ ${sale.paymentMethod}',
                                style: const TextStyle(fontSize: 12),
                              ),
                              trailing: Text(
                                '${MoneyUtils.minorUnitsToString(sale.totalMinorUnits)} ETB',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  decoration: sale.status == 'VOIDED'
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: sale.status == 'VOIDED'
                                      ? Colors.grey
                                      : Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                // Right: Quick Actions / Info
                Expanded(
                  flex: 1,
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Register Status',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Icon(
                                Icons.circle,
                                color: (_stats['is_shift_open'] ?? 0) == 1
                                    ? Colors.green
                                    : Colors.red,
                                size: 12,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                (_stats['is_shift_open'] ?? 0) == 1
                                    ? 'Register Open'
                                    : 'Register Closed',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Expected Cash: ${MoneyUtils.minorUnitsToString(_stats['expected_cash'] ?? 0)} ETB',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, int amount, {bool isPrimary = false}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              '${MoneyUtils.minorUnitsToString(amount)} ETB',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: isPrimary
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
