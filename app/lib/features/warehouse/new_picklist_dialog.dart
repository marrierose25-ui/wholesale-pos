import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:uuid/uuid.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_customer.dart';
import '../../core/models/picklist_item.dart';
import '../../core/models/user.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/money_utils.dart';
import 'warehouse_shared.dart';

/// The shop worker's New List window: a two-step dialog that mirrors the POS
/// New Sale and Money Tracking wizards. Step one picks the customer, step two
/// is the item detail; the list is only written when "Send to Warehouse" is
/// pressed, so nothing reaches the outbox on a cancelled run.
///
/// Pops `true` after a successful [PicklistRepository.createPicklist] so the
/// warehouse screen can refresh its queues.
class NewPicklistDialog extends StatefulWidget {
  final PicklistRepository repository;
  final User currentUser;

  const NewPicklistDialog({
    super.key,
    required this.repository,
    required this.currentUser,
  });

  @override
  State<NewPicklistDialog> createState() => _NewPicklistDialogState();
}

/// One editable product row. Controllers live here so they survive step
/// switches and rebuilds, and are disposed with the dialog. The unit is a fixed
/// choice, not typed text.
class _ItemDraft {
  final TextEditingController product = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// Starts empty on purpose: the worker must type the quantity they need, so
  /// a stray "1" can never be sent by accident.
  final TextEditingController qty = TextEditingController();

  /// One of [kPicklistUnits], defaulting to the POS default.
  String unit = kPicklistUnits.first;

  void dispose() {
    product.dispose();
    price.dispose();
    qty.dispose();
  }

  /// Parsed unit price in minor units (0 when blank/invalid).
  int get unitPriceMinor => MoneyUtils.stringToMinorUnits(price.text) ?? 0;

  /// Parsed whole-unit quantity (0 when blank/invalid).
  int get requestedQty => int.tryParse(qty.text.trim()) ?? 0;

  /// Exact integer line value: unit price (minor units) x whole quantity.
  int get lineTotalMinor => unitPriceMinor * requestedQty;
}

class _NewPicklistDialogState extends State<NewPicklistDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oneTimeController = TextEditingController();
  final List<_ItemDraft> _items = [_ItemDraft()];

  List<PicklistCustomer> _customers = const [];
  PicklistCustomer? _selectedCustomer;

  /// When true the customer is typed by hand instead of picked from the
  /// directory (a walk-in / one-time customer).
  bool _oneTimeMode = false;

  /// 0 = customer, 1 = items.
  int _step = 0;

  bool _loadingCustomers = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadCustomers();
  }

  @override
  void dispose() {
    _oneTimeController.dispose();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCustomers() async {
    setState(() => _loadingCustomers = true);
    try {
      final customers = await widget.repository.getCustomers();
      if (!mounted) return;
      setState(() {
        _customers = customers;
        _loadingCustomers = false;
        // A brand-new shop with no directory starts in typed-entry mode so the
        // window is never blocked behind an empty dropdown.
        if (customers.isEmpty) _oneTimeMode = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loadingCustomers = false;
        _oneTimeMode = true;
      });
    }
  }

  void _addItem() => setState(() => _items.add(_ItemDraft()));

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index).dispose();
      // Always keep at least one blank row so the step never collapses.
      if (_items.isEmpty) _items.add(_ItemDraft());
    });
  }

  String get _customerName => _oneTimeMode
      ? _oneTimeController.text.trim()
      : (_selectedCustomer?.name ?? '').trim();

  /// Step one -> step two. The customer must be chosen before the worker can
  /// start the item detail, exactly like the POS sale wizard.
  void _next() {
    if (_customerName.isEmpty) {
      setState(() {
        _error = _oneTimeMode
            ? 'Type the customer name.'
            : 'Choose a customer.';
      });
      return;
    }
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  /// Opens a small dialog to save a new directory customer, then selects it.
  Future<void> _addCustomerDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final formKey = GlobalKey<FormState>();
        return AlertDialog(
          title: const Text('New Customer'),
          content: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 6),
                TextFormField(
                  controller: nameController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Name is required.'
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: phoneController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone (optional)',
                    border: OutlineInputBorder(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) {
                  Navigator.of(dialogContext).pop(true);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );

    final name = nameController.text.trim();
    if (saved == true && name.isNotEmpty) {
      final customer = PicklistCustomer(
        id: const Uuid().v4(),
        name: name,
        phone: phoneController.text.trim().isEmpty
            ? null
            : phoneController.text.trim(),
        createdAt: DateTime.now(),
      );
      try {
        await widget.repository.addCustomer(customer);
        await _loadCustomers();
        if (!mounted) return;
        setState(() {
          _oneTimeMode = false;
          _selectedCustomer = _customers.firstWhere(
            (c) => c.id == customer.id,
            orElse: () => customer,
          );
          _error = null;
        });
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(_cleanError(e))));
        }
      }
    }
    nameController.dispose();
    phoneController.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final customer = _customerName;
    if (customer.isEmpty) {
      setState(() => _step = 0);
      return;
    }

    final now = DateTime.now();
    final picklistId = const Uuid().v4();

    final items = <PicklistItem>[];
    for (final draft in _items) {
      final productName = draft.product.text.trim();
      if (productName.isEmpty || draft.requestedQty <= 0) continue;
      items.add(
        PicklistItem(
          id: const Uuid().v4(),
          picklistId: picklistId,
          productName: productName,
          requestedQty: draft.requestedQty,
          takenQty: 0,
          unit: draft.unit,
          unitPriceMinorUnits: draft.unitPriceMinor,
          lineTotalMinorUnits: draft.lineTotalMinor,
          updatedAt: now,
        ),
      );
    }

    if (items.isEmpty) {
      setState(() => _error = 'Add at least one item with a quantity.');
      return;
    }

    final picklist = Picklist(
      id: picklistId,
      customerName: customer,
      status: Picklist.statusPending,
      createdBy: widget.currentUser.id,
      createdAt: now,
      updatedAt: now,
    );

    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.repository.createPicklist(picklist, items);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = _cleanError(e);
        });
      }
    }
  }

  String _cleanError(Object e) => e.toString().replaceAll('Exception: ', '');

  /// Sum of every filled row's line value.
  int get _grandTotalMinor =>
      _items.fold(0, (sum, draft) => sum + draft.lineTotalMinor);

  @override
  Widget build(BuildContext context) {
    // The keyboard would otherwise push the fields (and the action row) out of
    // the window, so cap the dialog body above it and let the content scroll.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 210).clamp(
      140.0,
      620.0,
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(_step == 0 ? 'New List (1/2)' : 'New List (2/2)'),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxBodyHeight),
          child: _step == 0 ? _buildCustomerStep() : _buildItemsStep(),
        ),
      ),
      actions: _step == 0
          ? [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: _next, child: const Text('Next')),
            ]
          : [
              TextButton(
                onPressed: _saving ? null : () => setState(() => _step = 0),
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppDesign.onBlue,
                        ),
                      )
                    : const Text('Send to Warehouse'),
              ),
            ],
    );
  }

  Widget _buildCustomerStep() {
    return SingleChildScrollView(
      clipBehavior: Clip.none,
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_oneTimeMode)
            TextField(
              controller: _oneTimeController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Customer Name',
                hintText: 'Type the name',
                prefixIcon: Icon(Icons.edit_outlined, size: 20),
              ),
              onChanged: (_) => setState(() => _error = null),
            )
          else if (_loadingCustomers)
            const SizedBox(
              height: 56,
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
            )
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: DropdownButtonFormField<PicklistCustomer>(
                    initialValue: _selectedCustomer,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Select Customer',
                      prefixIcon: Icon(Icons.storefront_outlined, size: 20),
                    ),
                    items: [
                      for (final c in _customers)
                        DropdownMenuItem(
                          value: c,
                          child: Text(
                            c.phone == null || c.phone!.isEmpty
                                ? c.name
                                : '${c.name}  ·  ${c.phone}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _selectedCustomer = value;
                      _error = null;
                    }),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 56,
                  height: 56,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: AppDesign.blue.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppDesign.blue.withValues(alpha: 0.35),
                      ),
                    ),
                    child: IconButton(
                      onPressed: _addCustomerDialog,
                      icon: const Icon(Icons.add, size: 22),
                      color: AppDesign.isDark
                          ? AppDesign.blueBright
                          : AppDesign.blue,
                      tooltip: 'Add customer',
                    ),
                  ),
                ),
              ],
            ),
          if (!_oneTimeMode && !_loadingCustomers && _customers.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _oneTimeMode = true;
                  _selectedCustomer = null;
                  _error = null;
                }),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('New customer (not saved)'),
              ),
            ),
          if (_oneTimeMode && _customers.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _oneTimeMode = false;
                  _error = null;
                }),
                icon: const Icon(Icons.list_alt_outlined, size: 17),
                label: const Text('Pick a saved customer'),
              ),
            ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(
              _error!,
              style: const TextStyle(color: AppDesign.danger, fontSize: 13),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildItemsStep() {
    return Form(
      key: _formKey,
      child: SingleChildScrollView(
        clipBehavior: Clip.none,
        padding: const EdgeInsets.only(top: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: AppDesign.blue.withValues(
                  alpha: AppDesign.isDark ? 0.14 : 0.07,
                ),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: AppDesign.blue.withValues(alpha: 0.28),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 17,
                    color: AppDesign.isDark
                        ? AppDesign.blueBright
                        : AppDesign.blue,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _customerName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppDesign.textHi,
                        fontSize: 13.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < _items.length; i++) ...[
              _buildItemCard(i),
              const SizedBox(height: 10),
            ],
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _addItem,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add Product'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppDesign.isDark
                      ? AppDesign.blueBright
                      : AppDesign.blue,
                  side: BorderSide(
                    color: AppDesign.blue.withValues(alpha: 0.45),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppDesign.radiusButton),
                  ),
                  textStyle: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppDesign.cardSoft,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppDesign.stroke),
              ),
              child: Row(
                children: [
                  Text(
                    'Total',
                    style: TextStyle(
                      color: AppDesign.textLo,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        MoneyUtils.formatBr(_grandTotalMinor),
                        style: TextStyle(
                          color: AppDesign.isDark
                              ? AppDesign.blueBright
                              : AppDesign.blue,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: const TextStyle(color: AppDesign.danger, fontSize: 13),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItemCard(int index) {
    final draft = _items[index];
    // Rebuild on every keystroke so the line total and the dialog total stay in
    // step with what the worker is typing.
    void recompute() => setState(() {});
    final canRemove = _items.length > 1 || draft.product.text.isNotEmpty;
    return Container(
      key: ObjectKey(draft),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 12),
      decoration: BoxDecoration(
        color: AppDesign.isDark
            ? Colors.white.withValues(alpha: 0.03)
            : Colors.white,
        borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
        border: Border.all(color: AppDesign.stroke),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: AppDesign.blue.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                ),
                child: Text(
                  'PRODUCT ${index + 1}',
                  style: TextStyle(
                    color: AppDesign.isDark
                        ? AppDesign.blueBright
                        : AppDesign.blue,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: _saving
                    ? null
                    : canRemove
                    ? () => _removeItem(index)
                    : null,
                icon: const Icon(Icons.delete_outline, size: 19),
                tooltip: 'Remove product',
                style: IconButton.styleFrom(
                  foregroundColor: AppDesign.danger,
                  disabledForegroundColor: AppDesign.textFaint,
                  minimumSize: const Size(34, 34),
                  padding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          TextFormField(
            controller: draft.product,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => recompute(),
            decoration: const InputDecoration(
              labelText: 'Product',
              hintText: 'e.g. White Sugar',
              isDense: true,
            ),
            validator: (value) {
              // A row is ignored on save when it has no quantity, so only flag
              // a row where something was typed but the name is missing.
              if (draft.requestedQty > 0 &&
                  (value == null || value.trim().isEmpty)) {
                return 'Type the product name.';
              }
              return null;
            },
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 2,
                child: TextFormField(
                  controller: draft.qty,
                  keyboardType: TextInputType.number,
                  onChanged: (_) => recompute(),
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Quantity',
                    hintText: 'e.g. 5',
                    isDense: true,
                  ),
                  validator: (value) {
                    if (draft.product.text.trim().isEmpty) return null;
                    return draft.requestedQty <= 0 ? 'Qty?' : null;
                  },
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: DropdownButtonFormField<String>(
                  initialValue: draft.unit,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Unit',
                    isDense: true,
                  ),
                  items: [
                    for (final unit in kPicklistUnits)
                      DropdownMenuItem(value: unit, child: Text(unit)),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value == null) return;
                          setState(() => draft.unit = value);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextFormField(
            controller: draft.price,
            keyboardType: TextInputType.number,
            onChanged: (_) => recompute(),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
            ],
            decoration: const InputDecoration(
              labelText: 'Price (Br)',
              hintText: 'e.g. 500',
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'Line total',
                style: TextStyle(
                  color: AppDesign.textLo,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    MoneyUtils.formatBr(draft.lineTotalMinor),
                    style: TextStyle(
                      color: AppDesign.isDark
                          ? AppDesign.blueBright
                          : AppDesign.blue,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
