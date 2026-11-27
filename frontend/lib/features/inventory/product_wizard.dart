import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/catalog.dart';
import 'package:pos_core/inventory.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/proof_photo_codec.dart';

/// The three-step product creation wizard. Step order is fixed by the brief:
///   1. product information (image, name, unit, prices)
///   2. store + initial quantity on hand
///   3. reorder quantity, then Done
///
/// Nothing is persisted until Done, and the Done write is a single atomic
/// repository call — the product and its opening stock commit or roll back
/// together.
class ProductWizard extends StatefulWidget {
  final InventoryRepository repository;
  final List<Store> stores;

  /// Called with true when a product was created (the list should reload).
  final ValueChanged<bool> onFinished;

  const ProductWizard({
    super.key,
    required this.repository,
    required this.stores,
    required this.onFinished,
  });

  /// Opens the wizard as a full-screen dialog. [stores] is the snapshot the
  /// inventory screen already loaded; the wizard re-reads it on step 2 in
  /// case the user just created one from the no-stores escape hatch.
  static Future<void> show(
    BuildContext context, {
    required InventoryRepository repository,
    required List<Store> stores,
  }) {
    return Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, _, _) => ProductWizard(
          repository: repository,
          stores: stores,
          onFinished: (_) => Navigator.of(context).pop(),
        ),
        transitionsBuilder: (_, animation, _, child) =>
            FadeTransition(opacity: animation, child: child),
      ),
    );
  }

  @override
  State<ProductWizard> createState() => _ProductWizardState();
}

class _ProductWizardState extends State<ProductWizard> {
  static const _uuid = Uuid();
  static const _units = [
    'Pieces',
    'Boxes',
    'Kilograms',
    'Grams',
    'Litres',
    'Millilitres',
  ];

  int _step = 0;
  bool _saving = false;

  // Step 1
  final _nameController = TextEditingController();
  String? _imageData;
  String? _unit;
  bool _customUnit = false;
  final _customUnitController = TextEditingController();
  final _boughtController = TextEditingController();
  final _sellingController = TextEditingController();

  // Step 2
  String? _storeId;
  List<Store> _stores = [];
  final _onHandController = TextEditingController();

  // Step 3
  final _reorderController = TextEditingController();

  String? _step1Error;
  String? _step2Error;
  String? _step3Error;

  @override
  void initState() {
    super.initState();
    _stores = widget.stores;
  }

  @override
  void dispose() {
    for (final c in [
      _nameController,
      _customUnitController,
      _boughtController,
      _sellingController,
      _onHandController,
      _reorderController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  String get _effectiveUnit =>
      _customUnit ? _customUnitController.text.trim() : (_unit ?? '');

  bool get _step1Valid {
    if (_nameController.text.trim().isEmpty) return false;
    if (_effectiveUnit.isEmpty) return false;
    if (MoneyUtils.stringToMinorUnits(_boughtController.text) == null) {
      return false;
    }
    return MoneyUtils.stringToMinorUnits(_sellingController.text) != null;
  }

  bool get _step2Valid =>
      _storeId != null &&
      MoneyUtils.stringToMilliunits(_onHandController.text) != null;

  bool get _step3Valid =>
      MoneyUtils.stringToMilliunits(_reorderController.text) != null;

  void _goNext() {
    setState(() {
      _step1Error = null;
      _step2Error = null;
      _step3Error = null;
      if (_step == 0) {
        if (!_step1Valid) {
          _step1Error = _validateStep1();
          return;
        }
      } else if (_step == 1) {
        if (_stores.isEmpty) {
          _step2Error = 'Create a store first.';
          return;
        }
        if (!_step2Valid) {
          _step2Error = _validateStep2();
          return;
        }
      }
      if (_step < 2) _step++;
    });
  }

  void _goBack() {
    setState(() {
      if (_step > 0) _step--;
      _step1Error = _step2Error = _step3Error = null;
    });
  }

  String _validateStep1() {
    if (_nameController.text.trim().isEmpty) return 'Item name is required.';
    if (_effectiveUnit.isEmpty) return 'Choose or enter a unit.';
    if (MoneyUtils.stringToMinorUnits(_boughtController.text) == null) {
      return 'Bought price must be a non-negative amount.';
    }
    if (MoneyUtils.stringToMinorUnits(_sellingController.text) == null) {
      return 'Selling price must be a non-negative amount.';
    }
    return 'Check the highlighted fields.';
  }

  String _validateStep2() {
    if (_storeId == null) return 'Select the store holding the initial stock.';
    if (MoneyUtils.stringToMilliunits(_onHandController.text) == null) {
      return 'Quantity must be a non-negative number (decimals allowed).';
    }
    return 'Check the highlighted fields.';
  }

  Future<void> _pickImage() async {
    try {
      final picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );
      if (picked == null) return; // user cancelled — image stays optional
      final bytes = await picked.readAsBytes();
      // Same compression pipeline as register proof photos so the stored
      // base64 stays small enough for sync and backup.
      final encoded = await encodeProof(bytes);
      if (encoded == null || !mounted) return;
      setState(() => _imageData = encoded);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not read that image.')),
      );
    }
  }

  Future<void> _createStoreAndReturn() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppDesign.card,
        title: Text('New store', style: TextStyle(color: AppDesign.textHi)),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          style: TextStyle(color: AppDesign.textHi),
          decoration: InputDecoration(
            hintText: 'Store name',
            hintStyle: TextStyle(color: AppDesign.textFaint),
          ),
          onSubmitted: (v) => Navigator.pop(dialogContext, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text('Cancel', style: TextStyle(color: AppDesign.textLo)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text('Save', style: TextStyle(color: AppDesign.accent)),
          ),
        ],
      ),
    );
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      await widget.repository.createStore(name);
      final stores = await widget.repository.getStores();
      if (!mounted) return;
      setState(() => _stores = stores);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e')),
      );
    }
  }

  Future<void> _done() async {
    if (_saving) return; // double-tap guard
    if (!_step3Valid) {
      setState(() => _step3Error = 'Enter a valid reorder quantity.');
      return;
    }
    setState(() {
      _saving = true;
      _step3Error = null;
    });
    try {
      final now = DateTime.now();
      final product = Product(
        id: _uuid.v4(),
        name: _nameController.text.trim(),
        code: '',
        unit: _effectiveUnit,
        sellingPriceMinorUnits: MoneyUtils.stringToMinorUnits(
          _sellingController.text,
        )!,
        boughtPriceMinorUnits: MoneyUtils.stringToMinorUnits(
          _boughtController.text,
        )!,
        imageData: _imageData,
        createdAt: now,
        updatedAt: now,
      );
      await widget.repository.createProductWithStock(
        product: product,
        storeId: _storeId!,
        onHandMilliunits: MoneyUtils.stringToMilliunits(
          _onHandController.text,
        )!,
        reorderMilliunits: MoneyUtils.stringToMilliunits(
          _reorderController.text,
        )!,
      );
      if (!mounted) return;
      widget.onFinished(true);
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _step3Error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final titles = const ['Product', 'Stock', 'Reorder'];
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        backgroundColor: AppDesign.bgElevated,
        elevation: 0,
        leading: IconButton(
          icon: Icon(CupertinoIcons.xmark, color: AppDesign.textLo),
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
        ),
        title: Text(
          'New product',
          style: TextStyle(color: AppDesign.textHi, fontSize: 17),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Step indicator
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 4),
              child: Row(
                children: [
                  for (var i = 0; i < 3; i++) ...[
                    if (i > 0) const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            height: 4,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              color: i <= _step
                                  ? AppDesign.accent
                                  : AppDesign.stroke,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '${i + 1}. ${titles[i]}',
                            style: TextStyle(
                              color: i == _step
                                  ? AppDesign.textHi
                                  : AppDesign.textFaint,
                              fontSize: 11,
                              fontWeight: i == _step
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: _step == 0
                    ? _buildStep1()
                    : _step == 1
                    ? _buildStep2()
                    : _buildStep3(),
              ),
            ),
            // Footer buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                children: [
                  if (_step > 0)
                    Expanded(
                      child: GlowButton(
                        label: 'Back',
                        height: 48,
                        onPressed: _saving ? null : _goBack,
                      ),
                    ),
                  if (_step > 0) const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: GlowButton(
                      label: _step == 2
                          ? (_saving ? 'Saving…' : 'Done')
                          : 'Next',
                      height: 48,
                      onPressed: _saving
                          ? null
                          : (_step == 2 ? _done : _goNext),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fieldLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(
      text,
      style: TextStyle(
        color: AppDesign.textLo,
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _textField({
    required TextEditingController controller,
    required String hint,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    bool enabled = true,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      enabled: enabled,
      onChanged: onChanged,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      style: TextStyle(color: AppDesign.textHi, fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: AppDesign.textFaint),
        filled: true,
        fillColor: AppDesign.cardSoft,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
          borderSide: BorderSide(color: AppDesign.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
          borderSide: BorderSide(color: AppDesign.stroke),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
          borderSide: BorderSide(color: AppDesign.accent, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
      ),
    );
  }

  Widget _errorText(String? error) {
    if (error == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        error,
        style: TextStyle(color: AppDesign.danger, fontSize: 12.5),
      ),
    );
  }

  Widget _buildStep1() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Image picker — optional
        Center(
          child: Pressable(
            onTap: _pickImage,
            child: Stack(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: AppDesign.cardSoft,
                  backgroundImage: _imageData == null
                      ? null
                      : MemoryImage(base64Decode(_imageData!)),
                  child: _imageData == null
                      ? Icon(
                          CupertinoIcons.photo,
                          size: 34,
                          color: AppDesign.textFaint,
                        )
                      : null,
                ),
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppDesign.accent,
                      border: Border.all(color: AppDesign.bg, width: 2),
                    ),
                    child: const Icon(
                      CupertinoIcons.camera_fill,
                      size: 13,
                      color: AppDesign.onBlue,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Text(
            _imageData == null ? 'Add a photo (optional)' : 'Tap to change photo',
            style: TextStyle(color: AppDesign.textLo, fontSize: 12),
          ),
        ),
        const SizedBox(height: 20),
        _fieldLabel('Item name *'),
        _textField(
          controller: _nameController,
          hint: 'e.g. Berbere 1kg',
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        _fieldLabel('Unit *'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final u in _units)
              Pressable(
                onTap: () => setState(() {
                  _customUnit = false;
                  _unit = u;
                }),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                    color: !_customUnit && _unit == u
                        ? AppDesign.accent.withValues(alpha: 0.15)
                        : AppDesign.cardSoft,
                    border: Border.all(
                      color: !_customUnit && _unit == u
                          ? AppDesign.accent
                          : AppDesign.stroke,
                    ),
                  ),
                  child: Text(
                    u,
                    style: TextStyle(
                      color: !_customUnit && _unit == u
                          ? AppDesign.accent
                          : AppDesign.textLo,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            Pressable(
              onTap: () => setState(() => _customUnit = true),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 9,
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(AppDesign.radiusPill),
                  color: _customUnit
                      ? AppDesign.accent.withValues(alpha: 0.15)
                      : AppDesign.cardSoft,
                  border: Border.all(
                    color: _customUnit ? AppDesign.accent : AppDesign.stroke,
                  ),
                ),
                child: Text(
                  'Other…',
                  style: TextStyle(
                    color: _customUnit ? AppDesign.accent : AppDesign.textLo,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_customUnit) ...[
          const SizedBox(height: 10),
          _textField(
            controller: _customUnitController,
            hint: 'Custom unit',
            onChanged: (_) => setState(() {}),
          ),
        ],
        const SizedBox(height: 16),
        _fieldLabel('Bought price *'),
        _textField(
          controller: _boughtController,
          hint: '0.00',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        _fieldLabel('Selling price *'),
        _textField(
          controller: _sellingController,
          hint: '0.00',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
          onChanged: (_) => setState(() {}),
        ),
        _errorText(_step1Error),
      ],
    );
  }

  Widget _buildStep2() {
    final storeName = _stores
        .where((s) => s.id == _storeId)
        .map((s) => s.name)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Where does the opening stock live?',
          style: TextStyle(color: AppDesign.textHi, fontSize: 15),
        ),
        const SizedBox(height: 14),
        if (_stores.isEmpty)
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppDesign.card,
              borderRadius: BorderRadius.circular(AppDesign.radiusCard),
              border: Border.all(color: AppDesign.stroke),
            ),
            child: Column(
              children: [
                Text(
                  'No stores yet. Create one first — your product details are kept.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppDesign.textLo, fontSize: 13),
                ),
                const SizedBox(height: 12),
                GlowButton(
                  label: 'Create a store',
                  height: 44,
                  expanded: false,
                  onPressed: _createStoreAndReturn,
                ),
              ],
            ),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final store in _stores)
                Pressable(
                  onTap: () => setState(() => _storeId = store.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(
                        AppDesign.radiusPill,
                      ),
                      color: _storeId == store.id
                          ? AppDesign.accent.withValues(alpha: 0.15)
                          : AppDesign.cardSoft,
                      border: Border.all(
                        color: _storeId == store.id
                            ? AppDesign.accent
                            : AppDesign.stroke,
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          CupertinoIcons.bag,
                          size: 14,
                          color: _storeId == store.id
                              ? AppDesign.accent
                              : AppDesign.textLo,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          store.name,
                          style: TextStyle(
                            color: _storeId == store.id
                                ? AppDesign.accent
                                : AppDesign.textLo,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        if (_storeId != null && storeName != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppDesign.cardSoft,
              borderRadius: BorderRadius.circular(AppDesign.radiusCardSm),
            ),
            child: Row(
              children: [
                Icon(
                  CupertinoIcons.checkmark_circle_fill,
                  size: 16,
                  color: AppDesign.success,
                ),
                const SizedBox(width: 8),
                Text(
                  'Stocking at $storeName',
                  style: TextStyle(color: AppDesign.textLo, fontSize: 12.5),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 20),
        _fieldLabel('Quantity on hand *'),
        _textField(
          controller: _onHandController,
          hint: '0 — decimals allowed (e.g. 12.5)',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
          ],
          onChanged: (_) => setState(() {}),
        ),
        _errorText(_step2Error),
      ],
    );
  }

  Widget _buildStep3() {
    final storeName = _stores
        .where((s) => s.id == _storeId)
        .map((s) => s.name)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Compact review of what was entered
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppDesign.card,
            borderRadius: BorderRadius.circular(AppDesign.radiusCard),
            border: Border.all(color: AppDesign.stroke),
          ),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: AppDesign.cardSoft,
                backgroundImage: _imageData == null
                    ? null
                    : MemoryImage(base64Decode(_imageData!)),
                child: _imageData == null
                    ? Icon(
                        CupertinoIcons.cube_box,
                        size: 20,
                        color: AppDesign.textFaint,
                      )
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _nameController.text.trim(),
                      style: TextStyle(
                        color: AppDesign.textHi,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '$_effectiveUnit · ${storeName ?? ''}',
                      style: TextStyle(color: AppDesign.textLo, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _fieldLabel('Reorder quantity *'),
        _textField(
          controller: _reorderController,
          hint: '0 — alert me when stock falls to this level',
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[\d.,]')),
          ],
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        Text(
          'If your stock falls to or below this quantity, the product is '
          'marked as low stock in the inventory list.',
          style: TextStyle(color: AppDesign.textFaint, fontSize: 12),
        ),
        _errorText(_step3Error),
      ],
    );
  }
}
