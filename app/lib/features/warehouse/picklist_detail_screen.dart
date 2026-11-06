import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'warehouse_shared.dart';

/// The warehouse worker's screen for one list. Each line shows only three
/// things — product, quantity and unit — plus one big TAKE button. Tapping it
/// calls [PicklistRepository.toggleItemTaken], which sets the line's taken qty
/// to its requested qty (or back to 0) and re-derives the header status.
///
/// No prices and no totals here: money is the shop's concern and would only
/// confuse the person pulling stock. The write is optimistic — the button flips
/// instantly, a spinner shows on that row while the save is in flight, and it
/// reverts if the call fails. A COMPLETED list is frozen, so closed history can
/// never be restated. This screen only ever touches the picklist tables.
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
  /// pace with the buttons without a full reload.
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
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            _buildHeader(),
            const SizedBox(height: 14),
            if (_readOnly) ...[
              _buildCompletedBanner(),
              const SizedBox(height: 14),
            ],
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              _buildError()
            else if (_items.isEmpty)
              _buildEmpty()
            else ...[
              _buildItemsHeader(),
              const SizedBox(height: 10),
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
      padding: const EdgeInsets.all(16),
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
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
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
              const SizedBox(width: 10),
              PicklistStatusChip(status: _status),
            ],
          ),
          if (showProgress) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                Text(
                  _readOnly ? 'All items taken' : 'Taken',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  '$picked of $total',
                  style: TextStyle(
                    color: _readOnly ? AppDesign.success : AppDesign.textHi,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(AppDesign.radiusPill),
              child: LinearProgressIndicator(
                value: total == 0 ? 0 : picked / total,
                minHeight: 8,
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
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'DONE — this list is finished.',
              style: TextStyle(
                color: AppDesign.success,
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
                height: 1.3,
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
          Icon(Icons.error_outline, color: AppDesign.danger, size: 30),
          const SizedBox(height: 10),
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

  Widget _buildEmpty() {
    return GlassCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Column(
          children: [
            Icon(
              Icons.inventory_2_outlined,
              size: 34,
              color: AppDesign.textFaint,
            ),
            const SizedBox(height: 10),
            Text(
              'No products on this list.',
              style: TextStyle(color: AppDesign.textLo, fontSize: 13.5),
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
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ),
        Text(
          '${_items.length}',
          style: TextStyle(
            color: AppDesign.textLo,
            fontSize: 13,
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
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        radius: AppDesign.radiusCardSm,
        onTap: _readOnly ? null : () => _toggle(item, !taken),
        border: Border.all(
          color: taken
              ? AppDesign.success.withValues(alpha: 0.45)
              : AppDesign.stroke,
          width: taken ? 1.4 : 1,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
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
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: AppDesign.textHi,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${item.requestedQty}$unit',
                      style: TextStyle(
                        color: AppDesign.textLo,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _TakeButton(
                taken: taken,
                saving: saving,
                readOnly: _readOnly,
                onPressed: () => _toggle(item, !taken),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The one action a warehouse worker needs: a big TAKE button that turns into
/// a green TAKEN badge. Tapping TAKEN again undoes the pick while the list is
/// still open; a finished list renders it inert.
class _TakeButton extends StatelessWidget {
  final bool taken;
  final bool saving;
  final bool readOnly;
  final VoidCallback onPressed;

  const _TakeButton({
    required this.taken,
    required this.saving,
    required this.readOnly,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    if (saving) {
      return const SizedBox(
        width: 96,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (taken) {
      final badge = Container(
        width: 96,
        height: 48,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppDesign.success.withValues(alpha: readOnly ? 0.16 : 0.20),
          borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          border: Border.all(
            color: AppDesign.success.withValues(alpha: 0.55),
            width: 1.4,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, color: AppDesign.success, size: 18),
            const SizedBox(width: 4),
            Text(
              'TAKEN',
              style: TextStyle(
                color: AppDesign.success,
                fontSize: 12,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      );
      if (readOnly) return badge;
      return Semantics(
        button: true,
        label: 'Taken. Tap to undo.',
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          child: badge,
        ),
      );
    }
    return SizedBox(
      width: 96,
      height: 48,
      child: FilledButton(
        onPressed: readOnly ? null : onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: AppDesign.blue,
          foregroundColor: AppDesign.onBlue,
          disabledBackgroundColor: AppDesign.cardSoft,
          disabledForegroundColor: AppDesign.textFaint,
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppDesign.radiusButton),
          ),
          textStyle: const TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 13,
            letterSpacing: 0.5,
          ),
        ),
        child: const Text('TAKE'),
      ),
    );
  }
}
