import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_contracts/pos_contracts.dart';

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
      body: AppBackground(
        child: RefreshIndicator(
          onRefresh: _loadLogs,
          child: CustomScrollView(
            slivers: [
              IosLargeTitle.sliver(
                context,
                title: 'Audit Logs',
                actions: [
                  IconButton(
                    icon: const Icon(CupertinoIcons.arrow_clockwise),
                    onPressed: _loadLogs,
                  ),
                ],
              ),
              if (_days.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Text(
                      'No audit entries yet.',
                      style: TextStyle(color: AppDesign.textLo),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  sliver: SliverList(
                    delegate: SliverChildBuilderDelegate((context, index) {
                      final group = _days[index];
                      return FadeSlideIn(
                        delay: Duration(milliseconds: index.clamp(0, 8) * 30),
                        child: _AuditDayCard(
                          group: group,
                          isFirst: index == 0,
                          isLast: index == _days.length - 1,
                          onTap: () => _openDay(group),
                        ),
                      );
                    }, childCount: _days.length),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Level 1 row: the day and how many events it holds.
class _AuditDayCard extends StatelessWidget {
  final _AuditDay group;
  final bool isFirst;
  final bool isLast;
  final VoidCallback onTap;

  const _AuditDayCard({
    required this.group,
    required this.onTap,
    this.isFirst = false,
    this.isLast = false,
  });

  @override
  Widget build(BuildContext context) {
    final count = group.logs.length;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: AppDesign.card,
          borderRadius: BorderRadius.vertical(
            top: isFirst
                ? const Radius.circular(AppDesign.radiusGrouped)
                : Radius.zero,
            bottom: isLast
                ? const Radius.circular(AppDesign.radiusGrouped)
                : Radius.zero,
          ),
          border: isLast
              ? null
              : Border(bottom: BorderSide(color: AppDesign.stroke, width: 0.5)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                SalesByDayScreen.formatDay(group.day),
                style: TextStyle(
                  color: AppDesign.textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w500,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            Text(
              '$count event${count == 1 ? '' : 's'}',
              style: TextStyle(
                color: AppDesign.textLo,
                fontSize: 13,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              CupertinoIcons.chevron_right,
              color: AppDesign.textFaint,
              size: 18,
            ),
          ],
        ),
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
          itemBuilder: (context, index) => FadeSlideIn(
            delay: Duration(milliseconds: index.clamp(0, 12) * 20),
            duration: const Duration(milliseconds: 280),
            child: _AuditEntryRow(log: logs[index]),
          ),
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

    Color iconColor = AppDesign.accent;
    IconData icon = CupertinoIcons.info;

    if (action == 'SALE_VOIDED') {
      iconColor = AppDesign.danger;
      icon = CupertinoIcons.xmark_circle;
    } else if (action == 'SALE_COMPLETED') {
      iconColor = AppDesign.success;
      icon = CupertinoIcons.checkmark_circle_fill;
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
