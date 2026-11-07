import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'warehouse_shared.dart';

/// The warehouse worker's screen for one list: a tick box per product. Ticking
/// calls [PicklistRepository.toggleItemTaken], which sets the line's taken qty
/// to its requested qty (or back to 0) and re-derives the header status.
///
/// No prices and no totals here: money is the shop's concern and would only
/// confuse the person pulling stock. The write is optimistic — the box ticks
/// instantly and reverts if the save fails. A COMPLETED list is frozen, so
/// closed history can never be restated. This screen only ever touches the
/// picklist tables.
class PicklistDetailScreen extends StatefulWidget {
  final PicklistRepository repository;
  final Picklist picklist;

  const PicklistDetailScreen({
    super.key,
    required this.repository,
    required this.picklist,
  });

  @override
  State<PicklistDetailScreen> createState() => _PicklistDetailScreenState();
}

class _PicklistDetailScreenState extends State<PicklistDetailScreen> {
  List<PicklistItem> _items = const [];

  /// Rows with an in-flight toggle, so only the tapped line shows a spinner.
  final Set<String> _savingIds = {};

  bool _isLoading = true;
  String? _error;

  /// Live header status, re-derived locally after each toggle so the chip keeps
  /// pace with the boxes without a full reload.
  late String _status = widget.picklist.status;

  /// Whether any toggle landed, so the directory refreshes on the way out.
  bool _changed = false;

  bool get _readOnly => _status == Picklist.statusCompleted;

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
        _status = _deriveStatus(items);
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

  /// Mirrors the repository's derivation so the local chip matches the server.
  static String _deriveStatus(List<PicklistItem> items) {
    if (items.isEmpty) return Picklist.statusPending;
    if (items.every((i) => i.isFulfilled)) return Picklist.statusCompleted;
    if (items.every((i) => i.takenQty <= 0)) return Picklist.statusPending;
    return Picklist.statusPartial;
  }

  Future<void> _toggle(PicklistItem item, bool isTaken) async {
    if (_readOnly || _savingIds.contains(item.id)) return;

    // Optimistic flip: replace the row with its toggled copy and re-derive the
    // header status before the write even lands.
    final optimistic = item.copyWith(
      takenQty: isTaken ? item.requestedQty : 0,
      updatedAt: DateTime.now(),
    );
    setState(() {
      _items = [for (final i in _items) i.id == item.id ? optimistic : i];
      _status = _deriveStatus(_items);
      _savingIds.add(item.id);
    });

    try {
      await widget.repository.toggleItemTaken(
        widget.picklist.id,
        item.id,
        isTaken,
      );
      if (!mounted) return;
      setState(() {
        _savingIds.remove(item.id);
        _changed = true;
      });
    } catch (e) {
      if (!mounted) return;
      // Revert the optimistic change so the UI never lies about saved state.
      setState(() {
        _items = [for (final i in _items) i.id == item.id ? item : i];
        _status = _deriveStatus(_items);
        _savingIds.remove(item.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        // Popping with `true` when anything was toggled tells the directory to
        // refresh (and nudge the sync engine); otherwise back is a no-op.
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(_changed ? true : null),
          tooltip: 'Back',
        ),
        title: const Text('Fill List'),
      ),
      body: AppBackground(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 28),
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            if (_readOnly) ...[
              _buildCompletedBanner(),
              const SizedBox(height: 12),
            ],
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 40),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _buildError()
            else if (_items.isEmpty)
              _buildEmpty()
            else ...[
              _buildItemsHeader(),
              const SizedBox(height: 8),
              for (final item in _items) _buildItemCard(item),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final picked = _items.where((i) => i.isFulfilled).length;
    final total = _items.length;
    final showProgress = !_isLoading && _error == null && total > 0;
    final progressColor = _readOnly ? AppDesign.success : AppDesign.blueBright;

    return GlassCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.picklist.customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppDesign.textHi,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatPicklistDate(widget.picklist.createdAt),
                      style: TextStyle(color: AppDesign.textLo, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              PicklistStatusChip(status: _status),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Text(
                  _readOnly ? 'All items taken' : 'Taken',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$picked of $total',
                  style: TextStyle(
                    color: _readOnly ? AppDesign.success : AppDesign.textHi,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : picked / total,
                minHeight: 6,
                backgroundColor: AppDesign.cardSoft,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCompletedBanner() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppDesign.success.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
        border: Border.all(color: AppDesign.success.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.check_circle_outline,
            color: AppDesign.success,
            size: 18,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'DONE — this list is finished.',
              style: TextStyle(
                color: AppDesign.success,
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildError() {
    return GlassCard(
      child: Column(
        children: [
          Icon(Icons.error_outline, color: AppDesign.danger, size: 28),
          const SizedBox(height: 8),
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
          ),
          const SizedBox(height: 6),
          TextButton(onPressed: _load, child: const Text('Retry')),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 30,
              color: AppDesign.textFaint,
            ),
            const SizedBox(height: 8),
            Text(
              'No products on this list.',
              style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemsHeader() {
    return Row(
      children: [
        Expanded(
          child: Text(
            'Products',
            style: TextStyle(
              color: AppDesign.textHi,
              fontSize: 13.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Text(
          '${_items.length}',
          style: TextStyle(
            color: AppDesign.textLo,
            fontSize: 12.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  Widget _buildItemCard(PicklistItem item) {
    final taken = item.isFulfilled;
    final saving = _savingIds.contains(item.id);
    final unit = (item.unit == null || item.unit!.isEmpty)
        ? ''
        : ' ${item.unit}';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: AppDesign.radiusCardSm,
        onTap: _readOnly ? null : () => _toggle(item, !taken),
        border: Border.all(
          color: taken
              ? AppDesign.success.withValues(alpha: 0.45)
              : AppDesign.stroke,
          width: taken ? 1.3 : 1,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
          child: Row(
            children: [
              if (saving)
                const SizedBox(
                  width: 42,
                  height: 42,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                )
              else
                SizedBox(
                  width: 42,
                  height: 42,
                  child: Checkbox(
                    value: taken,
                    onChanged: _readOnly ? null : (_) => _toggle(item, !taken),
                    activeColor: AppDesign.success,
                    checkColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(5),
                    ),
                    side: BorderSide(
                      color: taken ? AppDesign.success : AppDesign.textFaint,
                      width: 1.6,
                    ),
                    visualDensity: VisualDensity.compact,
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.productName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppDesign.textHi,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      '${item.requestedQty}$unit requested',
                      style: TextStyle(color: AppDesign.textLo, fontSize: 11.5),
                    ),
                  ],
                ),
              ),
              if (taken) ...[
                const SizedBox(width: 8),
                Text(
                  'Taken',
                  style: TextStyle(
                    color: AppDesign.success,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
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
