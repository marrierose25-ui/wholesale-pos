import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/product.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';

/// Dialog for adding or editing a saved name. Saved names are purely
/// optional shortcuts on the POS screen — only the name matters; the
/// default price simply pre-fills the unit price field when tapped.
class SavedNameDialog extends StatefulWidget {
  final Product? initial;

  const SavedNameDialog({super.key, this.initial});

  @override
  State<SavedNameDialog> createState() => _SavedNameDialogState();
}

class _SavedNameDialogState extends State<SavedNameDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _priceController;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initial?.name ?? '');
    final initialPrice = widget.initial?.sellingPriceMinorUnits ?? 0;
    _priceController = TextEditingController(
      text: initialPrice > 0 ? MoneyUtils.minorUnitsToString(initialPrice) : '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

    final name = _nameController.text.trim();
    final priceText = _priceController.text.trim();
    final priceMinorUnits = priceText.isEmpty
        ? 0
        : MoneyUtils.stringToMinorUnits(priceText);
    if (priceText.isNotEmpty && priceMinorUnits == null) return;

    final now = DateTime.now();
    final existing = widget.initial;
    final product = existing == null
        ? Product(
            // code/unit are legacy required columns; they are auto-generated
            // because saved names never use codes or units.
            id: const Uuid().v4(),
            name: name,
            code: 'SN-${const Uuid().v4().substring(0, 8).toUpperCase()}',
            unit: 'Item',
            sellingPriceMinorUnits: priceMinorUnits ?? 0,
            createdAt: now,
            updatedAt: now,
          )
        : Product(
            id: existing.id,
            name: name,
            code: existing.code,
            category: existing.category,
            unit: existing.unit,
            sellingPriceMinorUnits: priceMinorUnits ?? 0,
            isActive: existing.isActive,
            createdAt: existing.createdAt,
            updatedAt: now,
          );

    Navigator.of(context).pop(product);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.initial == null ? 'Add Saved Name' : 'Edit Name'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g., Berbere Shiro, Pasta 500g',
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _priceController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Default Price (Br, optional)',
                  hintText: 'Pre-fills the price when the name is tapped',
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return null;
                  if (MoneyUtils.stringToMinorUnits(v) == null) {
                    return 'Enter a valid amount (max 2 decimals)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Saved names are optional suggestions. The cashier can always '
                'type any name directly on the sale screen.',
                style: TextStyle(color: AppTheme.muted, fontSize: 12),
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
        FilledButton(onPressed: _submit, child: const Text('Save')),
      ],
    );
  }
}
