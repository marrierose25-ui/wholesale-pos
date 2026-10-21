import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/product.dart';
import '../../core/utils/money_utils.dart';

class AddProductDialog extends StatefulWidget {
  final Function(Product) onSave;

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

  void _submit() {
    if (!_formKey.currentState!.validate()) return;

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

    widget.onSave(newProduct);
    Navigator.of(context).pop();
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
                  validator: (v) => v!.isEmpty ? 'Required' : null,
                ),
                TextFormField(
                  controller: _codeController,
                  decoration: const InputDecoration(
                    labelText: 'Product Code (SKU)',
                  ),
                  validator: (v) => v!.isEmpty ? 'Required' : null,
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
                  validator: (v) => v!.isEmpty ? 'Required' : null,
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
                    if (v!.isEmpty) return 'Required';
                    if (MoneyUtils.stringToMinorUnits(v) == null) {
                      return 'Invalid price';
                    }
                    return null;
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Save Product')),
      ],
    );
  }
}
