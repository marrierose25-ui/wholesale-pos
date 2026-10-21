import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_theme.dart';
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
  String? _error;

  @override
  void initState() {
    super.initState();
    loadDashboard();
  }

  Future<void> loadDashboard() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final stats = await widget.saleRepository.getDashboardStats();
      final recent = await widget.saleRepository.getRecentSales(limit: 5);
      if (!mounted) return;
      setState(() {
        _stats = stats;
        _recentSales = recent;
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
            TextButton(onPressed: loadDashboard, child: const Text('Retry')),
          ],
        ),
      );
    }

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
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                _buildStatCard(
                  'Today\'s Revenue',
                  _stats['today_revenue'] ?? 0,
                  isPrimary: true,
                ),
                _buildStatCard('Cash Collected', _stats['today_cash'] ?? 0),
                _buildStatCard('Digital Payments', _stats['today_bank'] ?? 0),
                _buildStatCard(
                  'Register Expected Cash',
                  _stats['expected_cash'] ?? 0,
                ),
              ],
            ),
            const SizedBox(height: 32),
            LayoutBuilder(
              builder: (context, constraints) {
                final recentCard = _buildRecentSalesCard();
                final statusCard = _buildStatusCard();
                if (constraints.maxWidth < 900) {
                  return Column(
                    children: [
                      recentCard,
                      const SizedBox(height: 24),
                      statusCard,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 2, child: recentCard),
                    const SizedBox(width: 24),
                    Expanded(child: statusCard),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentSalesCard() {
    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Recent Transactions',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
          ),
          const Divider(height: 1),
          if (_recentSales.isEmpty)
            Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'No sales recorded yet.',
                style: TextStyle(
                  color: Theme.of(context).textTheme.bodySmall?.color,
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
                  '${sale.createdAt.toString().split('.')[0]} • ${sale.paymentMethod}',
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
    );
  }

  Widget _buildStatusCard() {
    final isOpen = (_stats['is_shift_open'] ?? 0) == 1;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Register Status',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Icon(
                  Icons.circle,
                  color: isOpen ? AppTheme.success : AppTheme.danger,
                  size: 12,
                ),
                const SizedBox(width: 8),
                Text(
                  isOpen ? 'Register Open' : 'Register Closed',
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              isOpen
                  ? 'Expected Cash: '
                        '${MoneyUtils.minorUnitsToString(_stats['expected_cash'] ?? 0)} ETB'
                  : 'Open the register to start recording cash sales.',
              style: TextStyle(
                color: Theme.of(context).textTheme.bodySmall?.color,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(String title, int amount, {bool isPrimary = false}) {
    return SizedBox(
      width: 240,
      child: Card(
        margin: EdgeInsets.zero,
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
      ),
    );
  }
}
