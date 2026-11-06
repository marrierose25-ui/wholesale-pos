import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'warehouse_shared.dart';

/// Read-only Warehouse History, following the Sales History drill-down:
/// a list of days, then the customers served that day, then exactly what each
/// customer took. No actions and no money — quantities only.
class WarehouseHistoryScreen extends StatefulWidget {
  final PicklistRepository repository;

  const WarehouseHistoryScreen({super.key, required this.repository});

  @override
  State<WarehouseHistoryScreen> createState() => _WarehouseHistoryScreenState();
}

class _WarehouseHistoryScreenState extends State<WarehouseHistoryScreen> {
  List<_DayGroup> _days = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final lists = await widget.repository.getPicklists();
      final buckets = <DateTime, List<Picklist>>{};
      for (final list in lists) {
        final t = list.createdAt.toLocal();
        (buckets[DateTime(t.year, t.month, t.day)] ??= []).add(list);
      }
      final keys = buckets.keys.toList()..sort((a, b) => b.compareTo(a));
      if (!mounted) return;
      setState(() {
        _days = [for (final key in keys) _DayGroup(key, buckets[key]!)];
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
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _load,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AppBackground(child: _buildBody()),
    );
  }

  Widget _buildBody() {
    if (_isLoading && _days.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _days.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_days.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'No history yet.',
            style: TextStyle(color: AppDesign.textLo, fontSize: 14),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
        itemCount: _days.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final group = _days[index];
          return _DayCard(
            group: group,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => PicklistDayScreen(
                  repository: widget.repository,
                  day: group.day,
                  picklists: group.lists,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One calendar day of picklists.
class _DayGroup {
  final DateTime day;
  final List<Picklist> lists;

  _DayGroup(this.day, this.lists);

  int get customerCount => lists.map((l) => l.customerName).toSet().length;

  int get doneCount => lists.where((l) => l.isCompleted).length;
}

/// Level 1 row: the day, how many customers it served and how many lists are
/// finished.
class _DayCard extends StatelessWidget {
  final _DayGroup group;
  final VoidCallback onTap;

  const _DayCard({required this.group, required this.onTap});

  String _relativeLabel() {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(group.day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final relative = _relativeLabel();
    final customers =
        '${group.customerCount} '
        'customer${group.customerCount == 1 ? '' : 's'}';
    final finished = '${group.doneCount} of ${group.lists.length} finished';
    return GlassCard(
      radius: AppDesign.radiusCardSm,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      onTap: onTap,
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  formatPicklistDay(group.day),
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  relative.isEmpty
                      ? '$customers · $finished'
                      : '$relative · $customers · $finished',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            Icons.chevron_right_rounded,
            color: AppDesign.textFaint,
            size: 22,
          ),
        ],
      ),
    );
  }
}

/// Level 2: the customers served on one day. One row per list so two orders
/// from the same customer stay separate and easy to open.
class PicklistDayScreen extends StatelessWidget {
  final PicklistRepository repository;
  final DateTime day;
  final List<Picklist> picklists;

  const PicklistDayScreen({
    super.key,
    required this.repository,
    required this.day,
    required this.picklists,
  });

  @override
  Widget build(BuildContext context) {
    final ordered = [...picklists]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(formatPicklistDay(day))),
      body: AppBackground(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          itemCount: ordered.length,
          separatorBuilder: (_, _) => const SizedBox(height: 10),
          itemBuilder: (context, index) {
            final list = ordered[index];
            return _CustomerRow(
              picklist: list,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PicklistTakenScreen(
                    repository: repository,
                    picklist: list,
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CustomerRow extends StatelessWidget {
  final Picklist picklist;
  final VoidCallback onTap;

  const _CustomerRow({required this.picklist, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = picklist.customerName;
    return GlassCard(
      padding: EdgeInsets.zero,
      radius: AppDesign.radiusCardSm,
      onTap: onTap,
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: AppDesign.buttonGradient,
          ),
          child: Center(
            child: Text(
              name.isEmpty ? '?' : name[0].toUpperCase(),
              style: const TextStyle(
                color: AppDesign.onBlue,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ),
        title: Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
        ),
        subtitle: Text(
          'Tap to see what was taken',
          style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            PicklistStatusChip(status: picklist.status),
            const SizedBox(width: 2),
            Icon(
              Icons.chevron_right_rounded,
              color: AppDesign.textFaint,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }
}

/// Level 3: exactly what one customer took. Shows every requested product with
/// the taken quantity first, so a partial pick is obvious.
class PicklistTakenScreen extends StatefulWidget {
  final PicklistRepository repository;
  final Picklist picklist;

  const PicklistTakenScreen({
    super.key,
    required this.repository,
    required this.picklist,
  });

  @override
  State<PicklistTakenScreen> createState() => _PicklistTakenScreenState();
}

class _PicklistTakenScreenState extends State<PicklistTakenScreen> {
  List<PicklistItem> _items = const [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final items = await widget.repository.getItems(widget.picklist.id);
      if (!mounted) return;
      setState(() {
        _items = items;
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
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: const Text('What Was Taken')),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Center(
                child: Column(
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            else if (_items.isEmpty)
              GlassCard(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Text(
                      'No products on this list.',
                      style: TextStyle(color: AppDesign.textLo, fontSize: 14),
                    ),
                  ),
                ),
              )
            else
              for (final item in _items) _buildItemRow(item),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final name = widget.picklist.customerName;
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppDesign.buttonGradient,
            ),
            child: Center(
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: const TextStyle(
                  color: AppDesign.onBlue,
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  formatPicklistDate(widget.picklist.createdAt),
                  style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          PicklistStatusChip(status: widget.picklist.status),
        ],
      ),
    );
  }

  Widget _buildItemRow(PicklistItem item) {
    final unit = (item.unit == null || item.unit!.isEmpty) ? '' : item.unit!;
    final took = item.takenQty;
    final short = took < item.requestedQty;
    final dimmed = took <= 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Opacity(
        opacity: dimmed ? 0.55 : 1,
        child: GlassCard(
          radius: AppDesign.radiusCardSm,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppDesign.textHi,
                      ),
                    ),
                    if (short) ...[
                      const SizedBox(height: 3),
                      Text(
                        'asked for ${item.requestedQty}'
                        '${unit.isEmpty ? '' : ' $unit'}',
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontSize: 12.5,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '$took${unit.isEmpty ? '' : ' $unit'}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.2,
                      color: took > 0 ? AppDesign.textHi : AppDesign.textLo,
                    ),
                  ),
                  Text(
                    'taken',
                    style: TextStyle(
                      color: AppDesign.textFaint,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
