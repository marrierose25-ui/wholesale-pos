import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/inventory.dart';
import '../../core/theme/app_design.dart';
import 'product_wizard.dart';
import 'stores_screen.dart';

/// The Inventory tab: every product that holds stock, once each, with its
/// per-store quantities and a risk-first status dot. The store filter
/// defaults to "All stores" (aggregated quantities); picking one store shows
/// only the products stocked there with that store's numbers.
class InventoryScreen extends StatefulWidget {
  final InventoryRepository repository;

  /// Fired after a local write so the shell can nudge the sync engine.
  final VoidCallback? onDataChanged;

  const InventoryScreen({
    super.key,
    required this.repository,
    this.onDataChanged,
  });

  @override
  State<InventoryScreen> createState() => InventoryScreenState();
}

class InventoryScreenState extends State<InventoryScreen> {
  /// Null means "All stores".
  String? _storeFilter;
  late Future<_InventoryData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<_InventoryData> _load() async {
    final results = await Future.wait([
      widget.repository.getStores(),
      widget.repository.getInventory(storeId: _storeFilter),
    ]);
    return _InventoryData(
      stores: results[0] as List<Store>,
      items: results[1] as List<InventoryItem>,
    );
  }

  /// Re-runs both fetches. Called by the shell on tab-select and after the
  /// wizard or a store change returns.
  void refresh({bool silent = false}) {
    // Start the load first: a setState closure must not return the Future.
    final future = _load();
    setState(() {
      _future = future;
    });
  }

  void _openWizard(List<Store> stores) async {
    await ProductWizard.show(
      context,
      repository: widget.repository,
      stores: stores,
    );
    widget.onDataChanged?.call();
    refresh();
  }

  void _openStores() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => StoresScreen(
          repository: widget.repository,
          onDataChanged: widget.onDataChanged,
        ),
      ),
    );
    widget.onDataChanged?.call();
    refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Inventory',
                          style: TextStyle(
                            color: AppDesign.textHi,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Stock on hand by store',
                          style: TextStyle(
                            color: AppDesign.textLo,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Store management lives one tap away; keeps the list
                  // screen focused on stock.
                  Pressable(
                    onTap: _openStores,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: AppDesign.cardSoft,
                        border: Border.all(color: AppDesign.stroke),
                      ),
                      child: Icon(
                        CupertinoIcons.bag,
                        size: 19,
                        color: AppDesign.textLo,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Pressable(
                    onTap: () {
                      // The wizard needs the store list; it arrives with the
                      // same future the list below renders.
                      _future.then(
                        (data) => _openWizard(data.stores),
                        onError: (_) {},
                      );
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: AppDesign.buttonGradient,
                      ),
                      child: const Icon(
                        CupertinoIcons.add,
                        color: AppDesign.onBlue,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Store filter chips: "All stores" + one per store.
            FutureBuilder<_InventoryData>(
              future: _future,
              builder: (context, snapshot) {
                final stores = snapshot.data?.stores ?? const <Store>[];
                if (stores.isEmpty && snapshot.hasData) {
                  return const SizedBox.shrink();
                }
                return SizedBox(
                  height: 40,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    children: [
                      _filterChip(null, 'All stores'),
                      for (final store in stores) ...[
                        const SizedBox(width: 8),
                        _filterChip(store.id, store.name),
                      ],
                    ],
                  ),
                );
              },
            ),
            const SizedBox(height: 6),
            Expanded(
              child: FutureBuilder<_InventoryData>(
                future: _future,
                builder: (context, snapshot) {
                  if (snapshot.connectionState != ConnectionState.done) {
                    return const Center(child: CupertinoActivityIndicator());
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          '${snapshot.error}',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppDesign.danger),
                        ),
                      ),
                    );
                  }
                  final data = snapshot.data!;
                  if (data.items.isEmpty) {
                    return _emptyState(data.stores.isEmpty);
                  }
                  return RefreshIndicator(
                    onRefresh: () async => refresh(),
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                      itemCount: data.items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 10),
                      itemBuilder: (context, i) =>
                          _productRow(context, data.items[i]),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String? storeId, String label) {
    final selected = _storeFilter == storeId;
    return Pressable(
      onTap: () {
        if (_storeFilter == storeId) return;
        setState(() => _storeFilter = storeId);
        refresh();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppDesign.radiusPill),
          color: selected
              ? AppDesign.accent.withValues(alpha: 0.15)
              : AppDesign.cardSoft,
          border: Border.all(
            color: selected ? AppDesign.accent : AppDesign.stroke,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? AppDesign.accent : AppDesign.textLo,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _emptyState(bool noStores) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconChip(icon: CupertinoIcons.cube_box, size: 56),
            const SizedBox(height: 12),
            Text(
              noStores ? 'Create a store first' : 'No stock yet',
              style: TextStyle(
                color: AppDesign.textHi,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              noStores
                  ? 'Inventory lives in stores — add one, then create your first product.'
                  : 'Tap + to add a product and its opening stock.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppDesign.textLo, fontSize: 13),
            ),
            if (noStores) ...[
              const SizedBox(height: 14),
              GlowButton(
                label: 'Manage stores',
                height: 44,
                expanded: false,
                onPressed: _openStores,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _productRow(BuildContext context, InventoryItem item) {
    final product = item.product;
    // Per-store view shows that store's numbers; All stores aggregates and
    // takes the risk-first status.
    final stock = _storeFilter == null ? null : item.stockFor(_storeFilter!);
    final onHand = _storeFilter == null
        ? item.totalOnHandMilliunits
        : (stock?.onHandMilliunits ?? 0);
    final status = _storeFilter == null
        ? item.aggregateStatus
        : (stock?.status ?? StockStatus.healthy);
    final statusLabel = switch (status) {
      StockStatus.healthy => 'In stock',
      StockStatus.low => 'Low stock',
      StockStatus.reorder => 'At reorder level',
    };
    final statusColor = switch (status) {
      StockStatus.healthy => AppDesign.success,
      StockStatus.low => AppDesign.danger,
      StockStatus.reorder => AppDesign.warning,
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: AppDesign.card,
        borderRadius: BorderRadius.circular(AppDesign.radiusCard),
        border: Border.all(color: AppDesign.stroke),
        boxShadow: AppDesign.cardShadow(),
      ),
      child: Row(
        children: [
          // Circular image / placeholder with the status dot on its lower
          // edge — the requested profile treatment.
          SizedBox(
            width: 52,
            height: 52,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppDesign.cardSoft,
                    border: Border.all(color: AppDesign.stroke),
                    image: product.imageData == null
                        ? null
                        : DecorationImage(
                            image: MemoryImage(
                              base64Decode(product.imageData!),
                            ),
                            fit: BoxFit.cover,
                          ),
                  ),
                  child: product.imageData == null
                      ? Center(
                          child: Text(
                            product.name.isEmpty
                                ? '?'
                                : product.name[0].toUpperCase(),
                            style: TextStyle(
                              color: AppDesign.accent,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      : null,
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Semantics(
                    label: statusLabel,
                    child: Container(
                      width: 16,
                      height: 16,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: statusColor,
                        border: Border.all(color: AppDesign.card, width: 2),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  _storeFilter == null
                      ? '${MoneyUtils.milliunitsToString(onHand)} ${product.unit} total · $statusLabel'
                      : '${MoneyUtils.milliunitsToString(onHand)} ${product.unit} on hand · $statusLabel',
                  style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                ),
              ],
            ),
          ),
          if (_storeFilter == null && item.stocks.length > 1)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: AppDesign.cardSoft,
                borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              ),
              child: Text(
                '${item.stocks.length} stores',
                style: TextStyle(color: AppDesign.textLo, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _InventoryData {
  final List<Store> stores;
  final List<InventoryItem> items;
  const _InventoryData({required this.stores, required this.items});
}
