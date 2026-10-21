import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/product.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';

class AddProductDialog extends StatefulWidget {
  final Future<void> Function(Product) onSave;

  const AddProductDialog({super.key, required this.onSave});

  @override
  State<AddProductDialog> createState() => _AddProductDialogState();
}

class _AddProductDialogState extends State<AddProductDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _codeController = TextEditingController();
  final _categoryController = TextEditingController();
  final _unitController = TextEditingController(text: 'Piece');
  final _priceController = TextEditingController();
  bool _isSaving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _codeController.dispose();
    _categoryController.dispose();
    _unitController.dispose();
    _priceController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isSaving || !_formKey.currentState!.validate()) return;

    final priceMinorUnits = MoneyUtils.stringToMinorUnits(
      _priceController.text,
    );
    if (priceMinorUnits == null) return;

    final now = DateTime.now();
    final newProduct = Product(
      id: const Uuid().v4(),
      name: _nameController.text.trim(),
      code: _codeController.text.trim().toUpperCase(),
      category: _categoryController.text.trim().isEmpty
          ? null
          : _categoryController.text.trim(),
      unit: _unitController.text.trim(),
      sellingPriceMinorUnits: priceMinorUnits,
      createdAt: now,
      updatedAt: now,
    );

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      await widget.onSave(newProduct);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceAll('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add New Product'),
      content: SizedBox(
        width: 400,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'Product Name'),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Product Code (SKU)',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: _categoryController,
                  decoration: const InputDecoration(
                    labelText: 'Category (Optional)',
                  ),
                ),
                TextFormField(
                  controller: _unitController,
                  decoration: const InputDecoration(
                    labelText: 'Unit (e.g., Bag, Kg)',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                TextFormField(
                  controller: _priceController,
                  decoration: const InputDecoration(
                    labelText: 'Selling Price (ETB)',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) {
                    if (v == null || v.trim().isEmpty) return 'Required';
                    if (MoneyUtils.stringToMinorUnits(v) == null) {
                      return 'Enter a valid amount (max 2 decimals)';
                    }
                    return null;
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isSaving ? null : _submit,
          child: _isSaving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save Product'),
        ),
      ],
    );
  }
}
