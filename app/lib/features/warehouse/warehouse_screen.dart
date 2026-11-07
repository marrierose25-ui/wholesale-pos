import 'package:flutter/material.dart';

import '../../core/auth/features.dart';
import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/models/user.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'create_picklist_screen.dart';
import 'picklist_detail_screen.dart';
import 'warehouse_history_screen.dart';
import 'warehouse_shared.dart';

/// The Warehouse tab. Two separate jobs live behind this one tab, and an
/// account only ever sees the one it was ticked for:
///
///  * **Warehouse** (`warehouse`) — the shop worker's New List form.
///  * **Warehouse Filling** (`warehouse_fill`) — the picker's queue of lists
///    still to be pulled, plus History.
///
/// The owner holds every tick, so it gets a small switch between the two.
/// A staff account never sees the other job's UI at all.
class WarehouseScreen extends StatefulWidget {
  final PicklistRepository repository;
  final User currentUser;

  /// Fired after a local write so the shell can nudge the sync engine to ship
  /// the queued outbox rows promptly (same cadence the ledger writes use).
  final VoidCallback? onDataChanged;

  const WarehouseScreen({
    super.key,
    required this.repository,
    required this.currentUser,
    this.onDataChanged,
  });

  @override
  State<WarehouseScreen> createState() => WarehouseScreenState();
}

class WarehouseScreenState extends State<WarehouseScreen> {
  /// Open lists plus their lines, so the queue cards can show what has to be
  /// pulled without opening each list first.
  late Future<List<_FillList>> _future;

  /// The owner holds both ticks; this picks which job is on screen.
  bool _showFill = true;

  bool get _canCreate => widget.currentUser.can(FeatureDef.warehouse);
  bool get _canFill => widget.currentUser.can(FeatureDef.warehouseFill);
  bool get _dual => _canCreate && _canFill;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Re-runs the queue fetch. Called by the shell on tab-select and after a
  /// create / fulfillment returns.
  Future<void> refresh({bool silent = false}) async {
    setState(() => _future = _load());
  }

  Future<List<_FillList>> _load() async {
    final lists = await widget.repository.getPicklists();
    final open = lists.where((p) => !p.isCompleted).toList();
    // A card without its lines is still useful, so a single failed fetch
    // degrades to an empty summary instead of blanking the whole queue.
    final itemSets = await Future.wait(
      open.map((p) async {
        try {
          return await widget.repository.getItems(p.id);
        } catch (_) {
          return const <PicklistItem>[];
        }
      }),
    );
    return [
      for (var i = 0; i < open.length; i++) _FillList(open[i], itemSets[i]),
    ];
  }

  Future<void> _createPicklist() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => CreatePicklistScreen(
          repository: widget.repository,
          currentUser: widget.currentUser,
        ),
      ),
    );
    if (created == true) {
      widget.onDataChanged?.call();
      refresh();
    }
  }

  Future<void> _openPicklist(Picklist picklist) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => PicklistDetailScreen(
          repository: widget.repository,
          picklist: picklist,
        ),
      ),
    );
    if (changed == true) {
      widget.onDataChanged?.call();
      refresh();
    }
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (context) =>
            WarehouseHistoryScreen(repository: widget.repository),
      ),
    );
    refresh(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final showFill = _canFill && (!_canCreate || _showFill);
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: Text(
          _dual
              ? 'Warehouse'
              : showFill
              ? 'Lists to Fill'
              : 'New List',
        ),
        actions: [
          if (_canFill)
            TextButton.icon(
              onPressed: _openHistory,
              icon: const Icon(Icons.history, size: 18),
              label: const Text('History'),
              style: TextButton.styleFrom(
                foregroundColor: AppDesign.textHi,
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(width: 6),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            if (_dual)
              _ModeSwitch(
                showFill: _showFill,
                onChanged: (value) => setState(() => _showFill = value),
              ),
            Expanded(child: showFill ? _buildFillBody() : _buildShopBody()),
          ],
        ),
      ),
    );
  }

  /// Shop worker's only job: start a new list.
  Widget _buildShopBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      children: [_NewListButton(onTap: _createPicklist)],
    );
  }

  Widget _buildFillBody() {
    return FutureBuilder<List<_FillList>>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          final message = (snapshot.error?.toString() ?? '').replaceAll(
            'Exception: ',
            '',
          );
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  message.isEmpty ? 'Could not load lists.' : message,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppDesign.textLo, fontSize: 13),
                ),
                const SizedBox(height: 8),
                TextButton(onPressed: refresh, child: const Text('Retry')),
              ],
            ),
          );
        }
        final open = snapshot.data ?? const <_FillList>[];
        return RefreshIndicator(
          onRefresh: () => refresh(),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Lists to fill',
                      style: TextStyle(
                        color: AppDesign.textHi,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    '${open.length}',
                    style: TextStyle(
                      color: AppDesign.textLo,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (open.isEmpty)
                _buildEmptyQueue()
              else
                for (final entry in open) _buildFillCard(entry),
            ],
          ),
        );
      },
    );
  }

  Widget _buildEmptyQueue() {
    return GlassCard(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
      child: Column(
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 30,
            color: AppDesign.textFaint,
          ),
          const SizedBox(height: 8),
          Text(
            'No lists to fill.',
            style: TextStyle(
              color: AppDesign.textHi,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            'Finished lists move to History.',
            style: TextStyle(color: AppDesign.textLo, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// One queue card, shaped like the Sales History cards: a tinted customer
  /// header, a short item summary, and one tap to start filling. Quantities
  /// only — a picker never sees a price.
  Widget _buildFillCard(_FillList entry) {
    final picklist = entry.picklist;
    final items = entry.items;
    final shown = items.take(3).toList();
    final shortId = picklist.id.length >= 4
        ? picklist.id.substring(0, 4).toUpperCase()
        : picklist.id.toUpperCase();
    final countLabel = '${items.length} item${items.length == 1 ? '' : 's'}';
    final headerFill = AppDesign.blue.withValues(
      alpha: AppDesign.isDark ? 0.16 : 0.07,
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: AppDesign.radiusCardSm,
        onTap: () => _openPicklist(picklist),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
              decoration: BoxDecoration(
                color: headerFill,
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(AppDesign.radiusCardSm),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          picklist.customerName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppDesign.textHi,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${formatPicklistDate(picklist.createdAt)} · '
                          '$countLabel',
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
                  Text(
                    'WL-$shortId',
                    style: TextStyle(
                      color: AppDesign.isDark
                          ? AppDesign.blueBright
                          : AppDesign.blue,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                children: [
                  if (items.isEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'No products on this list.',
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontSize: 11.5,
                        ),
                      ),
                    )
                  else
                    for (final item in shown)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2.5),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.productName,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: AppDesign.textHi,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _qtyLabel(item),
                              style: TextStyle(
                                color: AppDesign.textLo,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                  if (items.length > shown.length)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '+${items.length - shown.length} more',
                          style: TextStyle(
                            color: AppDesign.textLo,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Divider(height: 1, thickness: 1, color: AppDesign.stroke),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 7, 10, 7),
              child: Row(
                children: [
                  PicklistStatusChip(status: picklist.status),
                  const Spacer(),
                  Text(
                    'Tap to fill',
                    style: TextStyle(
                      color: AppDesign.isDark
                          ? AppDesign.blueBright
                          : AppDesign.blue,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  Icon(
                    Icons.chevron_right_rounded,
                    color: AppDesign.textFaint,
                    size: 17,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One open list and its lines, cached for the queue card.
class _FillList {
  final Picklist picklist;
  final List<PicklistItem> items;

  const _FillList(this.picklist, this.items);
}

String _qtyLabel(PicklistItem item) {
  final unit = (item.unit == null || item.unit!.isEmpty) ? '' : ' ${item.unit}';
  return '${item.requestedQty}$unit';
}

/// Owner-only switch between the two warehouse jobs.
class _ModeSwitch extends StatelessWidget {
  final bool showFill;
  final ValueChanged<bool> onChanged;

  const _ModeSwitch({required this.showFill, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppDesign.cardSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppDesign.stroke),
      ),
      child: Row(
        children: [
          _segment('To Fill', Icons.checklist, showFill, () => onChanged(true)),
          _segment('New List', Icons.add, !showFill, () => onChanged(false)),
        ],
      ),
    );
  }

  Widget _segment(
    String label,
    IconData icon,
    bool selected,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: Material(
        color: selected ? AppDesign.card : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 15,
                  color: selected ? AppDesign.textHi : AppDesign.textLo,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    color: selected ? AppDesign.textHi : AppDesign.textLo,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The shop worker's one action: a wide blue card that opens the New List form.
class _NewListButton extends StatelessWidget {
  final VoidCallback onTap;

  const _NewListButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
        child: Ink(
          decoration: BoxDecoration(
            gradient: AppDesign.buttonGradient,
            borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
            boxShadow: [AppDesign.blueGlow(alpha: 0.28)],
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppDesign.onBlue.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add,
                    color: AppDesign.onBlue,
                    size: 23,
                  ),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'NEW LIST',
                        style: TextStyle(
                          color: AppDesign.onBlue,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.4,
                        ),
                      ),
                      SizedBox(height: 1),
                      Text(
                        'Send products to the warehouse',
                        style: TextStyle(
                          color: AppDesign.onBlue,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppDesign.onBlue,
                  size: 21,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
