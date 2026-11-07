import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'warehouse_shared.dart';

/// Read-only Warehouse History, following the Sales History drill-down:
/// a list of days, then the customers served that day, then a compact ledger
/// of exactly what each customer took. No actions and no money — quantities
/// only.
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
          const SizedBox(width: 6),
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
            style: TextStyle(color: AppDesign.textLo, fontSize: 13),
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
                    fontSize: 14.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  relative.isEmpty
                      ? '$customers · $finished'
                      : '$relative · $customers · $finished',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 11.5,
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
            size: 19,
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
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          itemCount: ordered.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
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
    final shortId = picklist.id.length >= 4
        ? picklist.id.substring(0, 4).toUpperCase()
        : picklist.id.toUpperCase();
    return GlassCard(
      padding: EdgeInsets.zero,
      radius: AppDesign.radiusCardSm,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
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
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 13.5,
                      color: AppDesign.textHi,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    'WL-$shortId',
                    style: TextStyle(
                      color: AppDesign.textLo,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            PicklistStatusChip(status: picklist.status),
            Icon(
              Icons.chevron_right_rounded,
              color: AppDesign.textFaint,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

/// Level 3: exactly what one customer took, as a compact ledger with the same
/// caption/row rhythm as Sales History. Quantities only.
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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.picklist.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppDesign.textHi,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    formatPicklistDate(widget.picklist.createdAt),
                    style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!_isLoading && _error == null)
              _TakenLedgerHeader(count: _items.length),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppDesign.textLo, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (_items.isEmpty) {
      return Center(
        child: Text(
          'No products on this list.',
          style: TextStyle(color: AppDesign.textLo, fontSize: 13),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
      itemCount: _items.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _TakenRow(item: _items[index]),
    );
  }
}

/// Caption row aligned with [_TakenRow]'s columns.
class _TakenLedgerHeader extends StatelessWidget {
  final int count;

  const _TakenLedgerHeader({required this.count});

  Widget _cell(String label, TextAlign align, {double? width}) {
    return SizedBox(
      width: width,
      child: Text(
        label,
        textAlign: align,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: AppDesign.textLo,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 6, 24, 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '$count item${count == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppDesign.textLo,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _cell('Taken', TextAlign.end, width: 64),
          const SizedBox(width: 10),
          _cell('Asked', TextAlign.end, width: 56),
        ],
      ),
    );
  }
}

/// One product line: name, the quantity actually taken and what was asked for.
class _TakenRow extends StatelessWidget {
  final PicklistItem item;

  const _TakenRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final unit = (item.unit == null || item.unit!.isEmpty)
        ? ''
        : ' ${item.unit}';
    final took = item.takenQty;
    final dimmed = took <= 0;
    return Opacity(
      opacity: dimmed ? 0.55 : 1,
      child: GlassCard(
        radius: AppDesign.radiusCardSm,
        padding: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  item.productName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppDesign.textHi,
                  ),
                ),
              ),
              SizedBox(
                width: 64,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '$took$unit',
                    maxLines: 1,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: took > 0 ? AppDesign.textHi : AppDesign.textLo,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 56,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '${item.requestedQty}',
                    maxLines: 1,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: 12, color: AppDesign.textLo),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
