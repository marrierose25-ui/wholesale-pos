import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/sale_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/date_formatter.dart';
import '../dashboard/sales_by_day_screen.dart';

/// Audit history grouped by day, newest first — the same two-level drill-down
/// the Sales and Register histories use. Level 1 lists the days; tapping one
/// opens that day's entries.
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

/// One calendar day of audit entries.
class _AuditDay {
  final DateTime day;
  final List<Map<String, dynamic>> logs;

  _AuditDay(this.day, this.logs);
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  List<_AuditDay> _days = [];
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
    // Bucketed on the Addis Ababa clock so a day's card and its rows'
    // displayed times always agree (display-side only — stored timestamps
    // and queries are untouched).
    final buckets = <DateTime, List<Map<String, dynamic>>>{};
    for (final log in logs) {
      final t = toAddisAbabaTime(DateTime.parse(log['created_at'] as String));
      (buckets[DateTime(t.year, t.month, t.day)] ??= []).add(log);
    }
    final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
    if (!mounted) return;
    setState(() {
      _days = [for (final k in keys) _AuditDay(k, buckets[k]!)];
      _isLoading = false;
    });
  }

  void _openDay(_AuditDay group) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AuditDayScreen(day: group.day, logs: group.logs),
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
        child: _days.isEmpty
            ? Center(
                child: Text(
                  'No audit entries yet.',
                  style: TextStyle(color: AppDesign.textLo),
                ),
              )
            : RefreshIndicator(
                onRefresh: _loadLogs,
                child: ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: _days.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final group = _days[index];
                    return _AuditDayCard(
                      group: group,
                      onTap: () => _openDay(group),
                    );
                  },
                ),
              ),
      ),
    );
  }
}

/// Level 1 row: the day and how many events it holds.
class _AuditDayCard extends StatelessWidget {
  final _AuditDay group;
  final VoidCallback onTap;

  const _AuditDayCard({required this.group, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final count = group.logs.length;
    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Text(
              SalesByDayScreen.formatDay(group.day),
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 14.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            '$count event${count == 1 ? '' : 's'}',
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            Icons.chevron_right_rounded,
            color: AppDesign.textFaint,
            size: 20,
          ),
        ],
      ),
    );
  }
}

/// Level 2: everything logged on the tapped day, newest first.
class AuditDayScreen extends StatelessWidget {
  final DateTime day;
  final List<Map<String, dynamic>> logs;

  const AuditDayScreen({super.key, required this.day, required this.logs});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(SalesByDayScreen.formatDay(day))),
      body: AppBackground(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: logs.length,
          itemBuilder: (context, index) => _AuditEntryRow(log: logs[index]),
        ),
      ),
    );
  }
}

/// One compact entry line: icon · ACTION by user · time · details.
class _AuditEntryRow extends StatelessWidget {
  final Map<String, dynamic> log;

  const _AuditEntryRow({required this.log});

  @override
  Widget build(BuildContext context) {
    final action = log['action'] as String;
    final username = log['username'] as String? ?? 'System';
    final details = log['details'] as String? ?? '';
    final date = DateTime.parse(log['created_at'] as String);

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
          // Day lives in the screen's app bar — the row only carries the
          // time and the details on one compact ellipsized line.
          subtitle: Text(
            '${formatAddisTime(date)}  ·  $details',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    );
  }
}
