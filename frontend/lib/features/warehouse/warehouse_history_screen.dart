import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:pos_core/pos_core.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;




import '../../core/theme/app_design.dart';

import 'warehouse_shared.dart';

/// Read-only Warehouse History, following the Sales History drill-down:
/// a list of days, then the customers served that day, then a compact ledger
/// of exactly what each customer took.
///
/// [showMoney] is now true for every warehouse tick (shop creator and fill
/// worker alike), so both see prices and totals; the flag stays so the screens
/// still default to hiding money if they are ever reused elsewhere.
class WarehouseHistoryScreen extends StatefulWidget {
  final PicklistRepository repository;
  final bool showMoney;

  const WarehouseHistoryScreen({
    super.key,
    required this.repository,
    this.showMoney = false,
  });

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
            icon: const Icon(CupertinoIcons.arrow_clockwise),
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
                  showMoney: widget.showMoney,
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
            CupertinoIcons.chevron_right,
            color: AppDesign.textFaint,
            size: 19,
          ),
        ],
      ),
    );
  }
}

/// Level 2: the customers served on one day. One row per list so two orders
/// from the same customer stay separate and easy to open. When [showMoney] is
/// on, each row also carries the value of the goods taken on that list.
class PicklistDayScreen extends StatefulWidget {
  final PicklistRepository repository;
  final DateTime day;
  final List<Picklist> picklists;
  final bool showMoney;

  const PicklistDayScreen({
    super.key,
    required this.repository,
    required this.day,
    required this.picklists,
    this.showMoney = false,
  });

  @override
  State<PicklistDayScreen> createState() => _PicklistDayScreenState();
}

class _PicklistDayScreenState extends State<PicklistDayScreen> {
  /// Picklist id -> value of the goods taken (unit price x taken quantity).
  /// Empty only when money is off, in which case the item rows are not fetched.
  Map<String, int> _totals = const {};

  @override
  void initState() {
    super.initState();
    if (widget.showMoney) _loadTotals();
  }

  Future<void> _loadTotals() async {
    final totals = <String, int>{};
    await Future.wait(
      widget.picklists.map((list) async {
        try {
          final items = await widget.repository.getItems(list.id);
          totals[list.id] = items.fold(
            0,
            (sum, item) => sum + item.unitPriceMinorUnits * item.takenQty,
          );
        } catch (_) {
          // A missing item set simply leaves that row without a value.
        }
      }),
    );
    if (!mounted) return;
    setState(() => _totals = totals);
  }

  @override
  Widget build(BuildContext context) {
    final ordered = [...widget.picklists]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(formatPicklistDay(widget.day))),
      body: AppBackground(
        child: ListView.separated(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 24),
          itemCount: ordered.length,
          separatorBuilder: (_, _) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final list = ordered[index];
            return _CustomerRow(
              picklist: list,
              totalMinorUnits: widget.showMoney ? _totals[list.id] : null,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => PicklistTakenScreen(
                    repository: widget.repository,
                    picklist: list,
                    showMoney: widget.showMoney,
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
  final int? totalMinorUnits;
  final VoidCallback onTap;

  const _CustomerRow({
    required this.picklist,
    required this.onTap,
    this.totalMinorUnits,
  });

  @override
  Widget build(BuildContext context) {
    final name = picklist.customerName;
    final shortId = picklist.id.length >= 4
        ? picklist.id.substring(0, 4).toUpperCase()
        : picklist.id.toUpperCase();
    final subtitle = totalMinorUnits == null
        ? 'WL-$shortId'
        : 'WL-$shortId · ${MoneyUtils.formatBr(totalMinorUnits!)}';
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
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

/// Level 3: exactly what one customer took, as a compact ledger with the same
/// caption/row rhythm as Sales History. Quantities always; prices and totals
/// only when [showMoney] is on.
class PicklistTakenScreen extends StatefulWidget {
  final PicklistRepository repository;
  final Picklist picklist;
  final bool showMoney;

  const PicklistTakenScreen({
    super.key,
    required this.repository,
    required this.picklist,
    this.showMoney = false,
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
              _TakenLedgerHeader(
                count: _items.length,
                showMoney: widget.showMoney,
              ),
            Expanded(child: _buildBody()),
            if (widget.showMoney &&
                !_isLoading &&
                _error == null &&
                _items.isNotEmpty)
              _TakenTotalFooter(totalMinorUnits: _takenTotal),
          ],
        ),
      ),
    );
  }

  /// Value of what was actually taken: unit price x taken quantity.
  int get _takenTotal =>
      _items.fold(0, (sum, i) => sum + i.unitPriceMinorUnits * i.takenQty);

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
      itemBuilder: (context, index) =>
          _TakenRow(item: _items[index], showMoney: widget.showMoney),
    );
  }
}

/// Caption row aligned with [_TakenRow]'s columns. Price and Total only appear
/// when money is on; otherwise the ledger stops at Asked.
class _TakenLedgerHeader extends StatelessWidget {
  final int count;
  final bool showMoney;

  const _TakenLedgerHeader({required this.count, required this.showMoney});

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
              showMoney ? 'Item' : '$count item${count == 1 ? '' : 's'}',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppDesign.textLo,
                letterSpacing: 0.4,
              ),
            ),
          ),
          _cell('Asked', TextAlign.end, width: 52),
          if (showMoney) ...[
            const SizedBox(width: 6),
            _cell('Price', TextAlign.end, width: 60),
            const SizedBox(width: 6),
            _cell('Total', TextAlign.end, width: 64),
          ],
        ],
      ),
    );
  }
}

/// One product line: name, the quantity actually taken, what was asked for and
/// — when money is on — the unit price and the value taken.
class _TakenRow extends StatelessWidget {
  final PicklistItem item;
  final bool showMoney;

  const _TakenRow({required this.item, required this.showMoney});

  @override
  Widget build(BuildContext context) {
    final took = item.takenQty;
    final dimmed = took <= 0;
    final takenValue = item.unitPriceMinorUnits * took;
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
                width: 52,
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
              if (showMoney) ...[
                const SizedBox(width: 6),
                SizedBox(
                  width: 60,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      MoneyUtils.formatBr(item.unitPriceMinorUnits),
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 11.5, color: AppDesign.textLo),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 64,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      MoneyUtils.formatBr(takenValue),
                      maxLines: 1,
                      textAlign: TextAlign.end,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: took > 0 ? AppDesign.textHi : AppDesign.textLo,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The shop-side footer: the total value of everything taken on this list.
class _TakenTotalFooter extends StatelessWidget {
  final int totalMinorUnits;

  const _TakenTotalFooter({required this.totalMinorUnits});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 14),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: AppDesign.stroke)),
      ),
      child: Row(
        children: [
          Text(
            'Value taken',
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Text(
            MoneyUtils.formatBr(totalMinorUnits),
            style: TextStyle(
              color: AppDesign.textHi,
              fontSize: 14.5,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}
