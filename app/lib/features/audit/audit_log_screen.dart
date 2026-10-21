import 'package:flutter/material.dart';

import '../../core/repositories/sale_repository.dart';

class AuditLogScreen extends StatefulWidget {
  final SaleRepository saleRepository;

  const AuditLogScreen({super.key, required this.saleRepository});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<Map<String, dynamic>> _logs = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final logs = await widget.saleRepository.getAuditLogs();
    setState(() {
      _logs = logs;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Audit Logs'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadLogs),
        ],
      ),
      body: ListView.builder(
        itemCount: _logs.length,
        itemBuilder: (context, index) {
          final log = _logs[index];
          final action = log['action'] as String;
          final username = log['username'] as String? ?? 'System';
          final details = log['details'] as String? ?? '';
          final date = DateTime.parse(log['created_at'] as String)
              .toString()
              .split('.')[0];

          Color iconColor = Colors.blue;
          IconData icon = Icons.info;

          if (action == 'SALE_VOIDED') {
            iconColor = Colors.red;
            icon = Icons.cancel;
          } else if (action == 'SALE_COMPLETED') {
            iconColor = Colors.green;
            icon = Icons.check_circle;
          }

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: ListTile(
              leading: Icon(icon, color: iconColor),
              title: Text('$action by $username'),
              subtitle: Text('$details\n$date'),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}
