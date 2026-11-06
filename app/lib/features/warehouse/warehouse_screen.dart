import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/user.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'create_picklist_screen.dart';
import 'picklist_detail_screen.dart';
import 'warehouse_history_screen.dart';
import 'warehouse_shared.dart';

/// The Warehouse tab's landing screen. Two clearly different jobs live here:
///
///  * the blue **New List** button (shop worker: add products and send the list
///    to the warehouse), and
///  * the list of **orders to fill** (warehouse worker: tap a customer, then
///    tap TAKE on each product).
///
/// Finished lists drop out of the queue and live in [WarehouseHistoryScreen],
/// so the picker's screen only ever shows work that is still open.
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
  /// The in-flight directory query the [FutureBuilder] watches. Reassigned on
  /// every refresh so the list repulls without remounting the screen.
  late Future<List<Picklist>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.getPicklists();
  }

  /// Re-runs the directory fetch. Called by the shell on tab-select and by the
  /// refresh action after a create / fulfillment returns.
  Future<void> refresh({bool silent = false}) async {
    setState(() => _future = widget.repository.getPicklists());
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
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Warehouse'),
        actions: [
          TextButton.icon(
            onPressed: _openHistory,
            icon: const Icon(Icons.history, size: 19),
            label: const Text('History'),
            style: TextButton.styleFrom(foregroundColor: AppDesign.textHi),
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: refresh,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
              child: _NewListButton(onTap: _createPicklist),
            ),
            Expanded(
              child: FutureBuilder<List<Picklist>>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    final message = (snapshot.error?.toString() ?? '')
                        .replaceAll('Exception: ', '');
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            message.isEmpty ? 'Could not load lists.' : message,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: refresh,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    );
                  }
                  final open = (snapshot.data ?? const <Picklist>[])
                      .where((p) => !p.isCompleted)
                      .toList();
                  return _buildQueue(open);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQueue(List<Picklist> open) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Lists to fill',
                style: TextStyle(
                  color: AppDesign.textHi,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            Text(
              '${open.length}',
              style: TextStyle(
                color: AppDesign.textLo,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (open.isEmpty)
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 26),
            child: Column(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 34,
                  color: AppDesign.textFaint,
                ),
                const SizedBox(height: 10),
                Text(
                  'No lists to fill.',
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'New lists appear here.',
                  style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
                ),
              ],
            ),
          )
        else
          for (final picklist in open) _buildPicklistCard(picklist),
      ],
    );
  }

  Widget _buildPicklistCard(Picklist picklist) {
    final name = picklist.customerName;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: AppDesign.radiusCardSm,
        onTap: () => _openPicklist(picklist),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 14,
            vertical: 6,
          ),
          leading: Container(
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
          title: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 17),
          ),
          subtitle: Text(
            'Tap to fill',
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
                size: 22,
              ),
            ],
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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: AppDesign.onBlue.withValues(alpha: 0.18),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add,
                    color: AppDesign.onBlue,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'NEW LIST',
                        style: TextStyle(
                          color: AppDesign.onBlue,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        'Send products to the warehouse',
                        style: TextStyle(
                          color: AppDesign.onBlue,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppDesign.onBlue,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
