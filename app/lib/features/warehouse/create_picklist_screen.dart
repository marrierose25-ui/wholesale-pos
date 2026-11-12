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

/// The shop worker's New List screen: a customer plus one or more products,
/// sent to the warehouse as a picklist. Writes through
/// [PicklistRepository.createPicklist], which also queues the header and every
/// item to the sync outbox. Pops `true` on success so the directory reloads.
///
/// The layout is the original full-screen New List form — the same
/// [AppBackground], [GlassCard] sections and grand-total footer — split into
/// two steps so a phone never has to scroll past a customer form to reach the
/// products: step one is the customer, step two is the item detail.
///
/// Deliberately the simplest form in the app: one customer choice, one product
/// per card, a unit picked from the same four words the POS uses, and a typed
/// quantity. Prices stay here because the shop sets them; the warehouse
/// screens never show money.
class CreatePicklistScreen extends StatefulWidget {
  final PicklistRepository repository;
  final User currentUser;

  const CreatePicklistScreen({
    super.key,
    required this.repository,
    required this.currentUser,
  });

  @override
  State<CreatePicklistScreen> createState() => _CreatePicklistScreenState();
}

/// One editable row. Controllers live here so they survive step switches and
/// rebuilds, and are disposed with the screen. The unit is a fixed choice, not
/// typed text.
class _ItemDraft {
  final TextEditingController product = TextEditingController();
  final TextEditingController price = TextEditingController();

  /// Starts empty on purpose: the worker must type the quantity they need, so
  /// a stray "1" can never be sent by accident.
  final TextEditingController qty = TextEditingController();

  /// One of [kPicklistUnits]. Defaults to the POS default so the row is always
  /// saveable without the worker having to understand what a unit is.
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

class _CreatePicklistScreenState extends State<CreatePicklistScreen> {
  final _customerFormKey = GlobalKey<FormState>();
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
        // form is never blocked behind an empty dropdown.
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
      // Always keep at least one blank row so the form never collapses to empty.
      if (_items.isEmpty) _items.add(_ItemDraft());
    });
  }

  String get _customerName => _oneTimeMode
      ? _oneTimeController.text.trim()
      : (_selectedCustomer?.name ?? '').trim();

  /// Step one -> step two. The customer must be chosen before the worker can
  /// start the item detail, exactly like the POS sale wizard.
  void _next() {
    if ((_customerFormKey.currentState?.validate() ?? false) == false) return;
    if (_customerName.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() => _step = 1);
  }

  /// Step two -> step one, so the customer can be changed without losing the
  /// product rows already typed.
  void _back() {
    FocusScope.of(context).unfocus();
    setState(() => _step = 0);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one item with a quantity.')),
      );
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

    setState(() => _saving = true);
    try {
      await widget.repository.createPicklist(picklist, items);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_cleanError(e))));
      }
    }
  }

  String _cleanError(Object e) => e.toString().replaceAll('Exception: ', '');

  /// Sum of every filled row's line value, for the Grand Total footer.
  int get _grandTotalMinor =>
      _items.fold(0, (sum, draft) => sum + draft.lineTotalMinor);

  @override
  Widget build(BuildContext context) {
    final customerStep = _step == 0;
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        leading: customerStep
            ? null
            : IconButton(
                onPressed: _saving ? null : _back,
                icon: const Icon(Icons.arrow_back),
                tooltip: 'Back to customer',
              ),
        title: const Text('New List'),
        actions: [
          Text(
            customerStep ? 'Step 1 of 2' : 'Step 2 of 2',
            style: TextStyle(
              color: AppDesign.textLo,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 20),
        ],
      ),
      body: AppBackground(
        child: Column(
          children: [
            Expanded(
              child: customerStep ? _buildCustomerStep() : _buildItemsStep(),
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomerStep() {
    return Form(
      key: _customerFormKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _buildCustomerSection(),
          const SizedBox(height: 10),
          Text(
            'Next, add the products this customer needs.',
            style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
          ),
        ],
      ),
    );
  }

  Widget _buildItemsStep() {
    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
        children: [
          _buildItemsHeader(),
          const SizedBox(height: 10),
          for (var i = 0; i < _items.length; i++) ...[
            _buildItemRow(i),
            const SizedBox(height: 10),
          ],
          SizedBox(
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _saving ? null : _addItem,
              icon: const Icon(Icons.add, size: 20),
              label: const Text('Add Product'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppDesign.isDark
                    ? AppDesign.blueBright
                    : AppDesign.blue,
                side: BorderSide(color: AppDesign.blue.withValues(alpha: 0.45)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppDesign.radiusButton),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCustomerSection() {
    return GlassCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const IconChip(
                icon: Icons.person_outline,
                size: 34,
                color: AppDesign.blue,
              ),
              const SizedBox(width: 10),
              Text(
                'Customer',
                style: TextStyle(
                  color: AppDesign.textHi,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildCustomerField(),
          if (!_oneTimeMode && !_loadingCustomers && _customers.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() {
                  _oneTimeMode = true;
                  _selectedCustomer = null;
                }),
                icon: const Icon(Icons.edit_outlined, size: 17),
                label: const Text('New customer (not saved)'),
              ),
            ),
          if (_oneTimeMode && _customers.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _oneTimeMode = false),
                icon: const Icon(Icons.list_alt_outlined, size: 17),
                label: const Text('Pick a saved customer'),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCustomerField() {
    if (_oneTimeMode) {
      return TextFormField(
        controller: _oneTimeController,
        textCapitalization: TextCapitalization.words,
        decoration: const InputDecoration(
          labelText: 'Customer Name',
          hintText: 'Type the name',
          prefixIcon: Icon(Icons.edit_outlined, size: 20),
        ),
        validator: (v) => (v == null || v.trim().isEmpty)
            ? 'Customer name is required.'
            : null,
      );
    }
    if (_loadingCustomers) {
      return const SizedBox(
        height: 56,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.4)),
      );
    }
    return Row(
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
            onChanged: (value) => setState(() => _selectedCustomer = value),
            validator: (v) => v == null ? 'Choose a customer.' : null,
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
              border: Border.all(color: AppDesign.blue.withValues(alpha: 0.35)),
            ),
            child: IconButton(
              onPressed: _addCustomerDialog,
              icon: const Icon(Icons.add, size: 22),
              color: AppDesign.isDark ? AppDesign.blueBright : AppDesign.blue,
              tooltip: 'Add customer',
            ),
          ),
        ),
      ],
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

  Widget _fieldLabel(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          color: AppDesign.textLo,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildItemRow(int index) {
    final draft = _items[index];
    // Rebuild on every keystroke so the live line total and the grand total
    // footer stay in step with what the worker is typing.
    void recompute() => setState(() {});
    final canRemove = _items.length > 1 || draft.product.text.isNotEmpty;
    return GlassCard(
      key: ObjectKey(draft),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 14),
      radius: AppDesign.radiusCardSm,
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
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: canRemove ? () => _removeItem(index) : null,
                icon: const Icon(Icons.delete_outline, size: 20),
                tooltip: 'Remove product',
                style: IconButton.styleFrom(
                  foregroundColor: AppDesign.danger,
                  disabledForegroundColor: AppDesign.textFaint,
                  backgroundColor: AppDesign.danger.withValues(alpha: 0.09),
                  disabledBackgroundColor: Colors.transparent,
                  minimumSize: const Size(38, 38),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          _fieldLabel('Product name'),
          TextFormField(
            controller: draft.product,
            textCapitalization: TextCapitalization.words,
            onChanged: (_) => recompute(),
            decoration: const InputDecoration(hintText: 'e.g. White Sugar'),
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
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Unit'),
                    DropdownButtonFormField<String>(
                      initialValue: draft.unit,
                      isExpanded: true,
                      decoration: const InputDecoration(isDense: true),
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
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Qty'),
                    TextFormField(
                      controller: draft.qty,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => recompute(),
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(
                        hintText: '0',
                        isDense: true,
                      ),
                      validator: (value) {
                        if (draft.product.text.trim().isEmpty) return null;
                        return draft.requestedQty <= 0 ? 'Qty?' : null;
                      },
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _fieldLabel('Price (Br)'),
                    TextFormField(
                      controller: draft.price,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => recompute(),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                      ],
                      decoration: const InputDecoration(
                        hintText: '0.00',
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: AppDesign.blue.withValues(
                alpha: AppDesign.isDark ? 0.10 : 0.06,
              ),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  'Line total',
                  style: TextStyle(
                    color: AppDesign.textLo,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Text(
                      MoneyUtils.formatBr(draft.lineTotalMinor),
                      style: TextStyle(
                        color: AppDesign.isDark
                            ? AppDesign.blueBright
                            : AppDesign.blue,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter() {
    final customerStep = _step == 0;

    final totalBlock = customerStep
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'CUSTOMER',
                style: TextStyle(
                  color: AppDesign.textLo,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  'Choose a customer',
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                ),
              ),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'GRAND TOTAL',
                style: TextStyle(
                  color: AppDesign.textLo,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  MoneyUtils.formatBr(_grandTotalMinor),
                  style: TextStyle(
                    color: AppDesign.textHi,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1,
                  ),
                ),
              ),
            ],
          );

    final actionButton = SizedBox(
      height: 54,
      child: customerStep
          ? FilledButton.icon(
              onPressed: _saving ? null : _next,
              icon: const Icon(Icons.arrow_forward, size: 20),
              label: const Text('Next'),
              style: _footerButtonStyle(),
            )
          : FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppDesign.onBlue,
                      ),
                    )
                  : const Icon(Icons.send_outlined, size: 20),
              label: Text(_saving ? 'Sending…' : 'Send to Warehouse'),
              style: _footerButtonStyle(),
            ),
    );

    return Container(
      decoration: BoxDecoration(
        color: AppDesign.isDark ? AppDesign.bgElevated : AppDesign.card,
        border: Border(top: BorderSide(color: AppDesign.stroke)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: AppDesign.isDark ? 0.35 : 0.06,
            ),
            blurRadius: 24,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 430) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    totalBlock,
                    const SizedBox(height: 10),
                    actionButton,
                  ],
                );
              }
              return Row(
                children: [
                  Expanded(child: totalBlock),
                  const SizedBox(width: 20),
                  actionButton,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  ButtonStyle _footerButtonStyle() {
    return FilledButton.styleFrom(
      backgroundColor: AppDesign.blue,
      foregroundColor: AppDesign.onBlue,
      disabledBackgroundColor: AppDesign.blue.withValues(alpha: 0.5),
      disabledForegroundColor: AppDesign.onBlue.withValues(alpha: 0.85),
      padding: const EdgeInsets.symmetric(horizontal: 22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppDesign.radiusButton),
      ),
      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
    );
  }
}
