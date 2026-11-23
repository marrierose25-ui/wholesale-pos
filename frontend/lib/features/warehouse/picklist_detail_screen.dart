import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;



import '../../core/theme/app_design.dart';

import 'warehouse_shared.dart';

/// The warehouse worker's screen for one list: a tick box per product. Ticking
/// calls [PicklistRepository.toggleItemTaken], which sets the line's taken qty
/// to its requested qty (or back to 0) and re-derives the header status.
///
/// Every warehouse account sees money now: the Warehouse tab passes
/// [showMoney] true for both of its ticks, so the header carries the list's
/// requested value and each line its unit price and value. The write is
/// optimistic — the box ticks instantly and reverts if the save fails. A
/// COMPLETED list is frozen, so closed history can never be restated. This
/// screen only ever touches the picklist tables.
class PicklistDetailScreen extends StatefulWidget {
  final PicklistRepository repository;
  final Picklist picklist;

  /// Whether prices and the list total are shown. The Warehouse tab passes
  /// true for both of its ticks (shop and fill); the default keeps the screen
  /// safe if it is ever reused somewhere money is not wanted.
  final bool showMoney;

  const PicklistDetailScreen({
    super.key,
    required this.repository,
    required this.picklist,
    this.showMoney = false,
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

  /// Corrects one line: product name, requested quantity, unit and price. The
  /// line total is recomputed here from price x quantity and the repository
  /// re-checks it again, so the two can never disagree.
  Future<void> _editItem(PicklistItem item) async {
    if (_readOnly) return;
    final result = await showDialog<_EditItemResult>(
      context: context,
      builder: (_) => _EditItemDialog(item: item),
    );
    if (result == null || !mounted) return;

    try {
      await widget.repository.updatePicklistItem(
        PicklistItem(
          id: item.id,
          picklistId: item.picklistId,
          productName: result.productName,
          requestedQty: result.requestedQty,
          takenQty: item.takenQty,
          unit: result.unit,
          unitPriceMinorUnits: result.unitPriceMinorUnits,
          lineTotalMinorUnits: result.unitPriceMinorUnits * result.requestedQty,
          updatedAt: DateTime.now(),
        ),
      );
      if (!mounted) return;
      setState(() => _changed = true);
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showError(e);
    }
  }

  /// Soft-deletes one line. Deleting the last line also removes the header (in
  /// the repository), so the screen pops and the queue refreshes instead of
  /// leaving an empty list behind.
  Future<void> _deleteItem(PicklistItem item) async {
    if (_readOnly) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete this entry?'),
        content: Text(
          '"${item.productName}" will be removed from this list on every '
          'device. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(backgroundColor: AppDesign.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deletePicklistItem(widget.picklist.id, item.id);
      if (!mounted) return;
      setState(() => _changed = true);
      await _load();
      if (!mounted) return;
      // The last line takes the header with it; there is nothing left to fill.
      if (_items.isEmpty) Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      _showError(e);
    }
  }

  void _showError(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        // Popping with `true` when anything was toggled tells the directory to
        // refresh (and nudge the sync engine); otherwise back is a no-op.
        leading: IconButton(
          icon: const Icon(CupertinoIcons.chevron_left),
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
    final progressColor = _readOnly ? AppDesign.success : AppDesign.accent;

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
          if (widget.showMoney && showProgress) ...[
            const SizedBox(height: 10),
            Divider(height: 1, thickness: 1, color: AppDesign.stroke),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  'List value',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  MoneyUtils.formatBr(_requestedTotal),
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Value of the whole list as requested: unit price x requested quantity.
  int get _requestedTotal =>
      _items.fold(0, (sum, i) => sum + i.unitPriceMinorUnits * i.requestedQty);

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
            CupertinoIcons.checkmark_circle,
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
          Icon(CupertinoIcons.exclamationmark_circle, color: AppDesign.danger, size: 28),
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
              CupertinoIcons.cube_box,
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
                    if (widget.showMoney) ...[
                      const SizedBox(height: 2),
                      Text(
                        '${MoneyUtils.formatBr(item.unitPriceMinorUnits)} each · '
                        '${MoneyUtils.formatBr(item.unitPriceMinorUnits * item.requestedQty)}',
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
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
              if (!_readOnly)
                PopupMenuButton<String>(
                  tooltip: 'Entry actions',
                  padding: EdgeInsets.zero,
                  splashRadius: 18,
                  icon: Icon(
                    CupertinoIcons.ellipsis,
                    size: 18,
                    color: AppDesign.textLo,
                  ),
                  onSelected: (value) {
                    if (value == 'edit') _editItem(item);
                    if (value == 'delete') _deleteItem(item);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem<String>(
                      value: 'edit',
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.pencil, size: 18),
                          SizedBox(width: 8),
                          Text('Edit entry'),
                        ],
                      ),
                    ),
                    PopupMenuItem<String>(
                      value: 'delete',
                      child: Row(
                        children: [
                          Icon(CupertinoIcons.trash, size: 18),
                          SizedBox(width: 8),
                          Text('Delete entry'),
                        ],
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

/// What the edit dialog returns. A plain value object keeps the dialog's
/// controllers owned by [_EditItemDialogState], so they are disposed with the
/// route instead of while it is still animating out.
class _EditItemResult {
  final String productName;
  final int requestedQty;
  final String? unit;
  final int unitPriceMinorUnits;

  const _EditItemResult({
    required this.productName,
    required this.requestedQty,
    required this.unit,
    required this.unitPriceMinorUnits,
  });
}

class _EditItemDialog extends StatefulWidget {
  final PicklistItem item;

  const _EditItemDialog({required this.item});

  @override
  State<_EditItemDialog> createState() => _EditItemDialogState();
}

class _EditItemDialogState extends State<_EditItemDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _qty;
  late final TextEditingController _price;
  late String _unit;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.item.productName);
    _qty = TextEditingController(text: widget.item.requestedQty.toString());
    _price = TextEditingController(
      text: MoneyUtils.minorUnitsToString(widget.item.unitPriceMinorUnits),
    );
    _unit = widget.item.unit ?? '';
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _price.dispose();
    super.dispose();
  }

  void _save() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final qty = int.tryParse(_qty.text.trim()) ?? 0;
    final unit = _unit.trim();
    Navigator.of(context).pop(
      _EditItemResult(
        productName: _name.text.trim(),
        requestedQty: qty,
        unit: unit.isEmpty ? null : unit,
        unitPriceMinorUnits: MoneyUtils.stringToMinorUnits(_price.text) ?? 0,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final unitOptions = <String>[
      '',
      ...kPicklistUnits,
      if (_unit.isNotEmpty && !kPicklistUnits.contains(_unit)) _unit,
    ];
    return AlertDialog(
      title: const Text('Edit entry'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Product name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => (value == null || value.trim().isEmpty)
                    ? 'Product name is required.'
                    : null,
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      controller: _qty,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        labelText: 'Qty',
                        border: OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final qty = int.tryParse(value?.trim() ?? '');
                        return (qty == null || qty <= 0) ? 'Qty?' : null;
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 4,
                    child: DropdownButtonFormField<String>(
                      initialValue: _unit,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Unit',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        for (final unit in unitOptions)
                          DropdownMenuItem(
                            value: unit,
                            child: Text(
                              unit.isEmpty ? '—' : unit,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (value) => setState(() => _unit = value ?? ''),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _price,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: const InputDecoration(
                  labelText: 'Unit price (Br)',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  final text = value?.trim() ?? '';
                  if (text.isEmpty) return null;
                  return MoneyUtils.stringToMinorUnits(text) == null
                      ? 'Enter a valid price.'
                      : null;
                },
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
