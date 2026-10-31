import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_formatter.dart';
import '../dashboard/sales_by_day_screen.dart';

class AuditLogScreen extends StatefulWidget {
  final SaleRepository saleRepository;
  final User currentUser;

  const AuditLogScreen({
    super.key,
    required this.saleRepository,
    required this.currentUser,
  });

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  // Entries compacted by calendar day: the flat list alternates a day header
  // (a DateTime item) with that day's log rows (Map items), newest day first.
  List<Object> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadLogs();
  }

  Future<void> _loadLogs() async {
    setState(() => _isLoading = true);
    final logs = await widget.saleRepository.getAuditLogs(
      userId: widget.currentUser.id,
    );
    final buckets = <DateTime, List<Map<String, dynamic>>>{};
    for (final log in logs) {
      final t = DateTime.parse(log['created_at'] as String).toLocal();
      (buckets[DateTime(t.year, t.month, t.day)] ??= []).add(log);
    }
    final days = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    final items = <Object>[];
    for (final day in days) {
      items.add(day);
      items.addAll(buckets[day]!);
    }
    if (!mounted) return;
    setState(() {
      _items = items;
      _isLoading = false;
    });
  }

  String _hhmm(DateTime date) => formatAddisTime(date);

  Widget _dayHeader(DateTime day, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
      child: Text(
        '${SalesByDayScreen.formatDay(day)}  ·  '
        '$count event${count == 1 ? '' : 's'}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppDesign.textLo,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _entryRow(Map<String, dynamic> log) {
    final action = log['action'] as String;
    final username = log['username'] as String? ?? 'System';
    final details = log['details'] as String? ?? '';
    final date = DateTime.parse(log['created_at'] as String).toLocal();

    Color iconColor = AppDesign.blueBright;
    IconData icon = Icons.info;

    if (action == 'SALE_VOIDED') {
      iconColor = AppDesign.danger;
      icon = Icons.cancel;
    } else if (action == 'SALE_COMPLETED') {
      iconColor = AppDesign.success;
      icon = Icons.check_circle;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          leading: IconChip(icon: icon, size: 28, color: iconColor),
          title: Text(
            '$action by $username',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          // Day lives in the section header — the row only carries the time
          // and the details on one compact ellipsized line.
          subtitle: Text(
            '${_hhmm(date)}  ·  $details',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Audit Logs'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadLogs),
        ],
      ),
      body: AppBackground(
        child: ListView.builder(
          padding: const EdgeInsets.only(bottom: 16),
          itemCount: _items.length,
          itemBuilder: (context, index) {
            final item = _items[index];
            if (item is DateTime) {
              var count = 0;
              for (
                var i = index + 1;
                i < _items.length && _items[i] is! DateTime;
                i++
              ) {
                count++;
              }
              return _dayHeader(item, count);
            }
            return _entryRow(item as Map<String, dynamic>);
          },
        ),
      ),
    );
  }
}
