import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;
import 'package:uuid/uuid.dart';

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/models/user.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';

/// Builds a new picklist: a customer name plus one or more requested line
/// items. Writes through [PicklistRepository.createPicklist], which also queues
/// the header and every item to the sync outbox. Pops `true` on success so the
/// directory knows to reload.
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

/// One editable row. Controllers live here so they survive rebuilds and are
/// disposed with the screen.
class _ItemDraft {
  final TextEditingController product = TextEditingController();
  final TextEditingController qty = TextEditingController();

  void dispose() {
    product.dispose();
    qty.dispose();
  }
}

class _CreatePicklistScreenState extends State<CreatePicklistScreen> {
  final _formKey = GlobalKey<FormState>();
  final _customerController = TextEditingController();
  final List<_ItemDraft> _items = [_ItemDraft()];
  bool _saving = false;

  @override
  void dispose() {
    _customerController.dispose();
    for (final item in _items) {
      item.dispose();
    }
    super.dispose();
  }

  void _addItem() => setState(() => _items.add(_ItemDraft()));

  void _removeItem(int index) {
    setState(() {
      _items.removeAt(index).dispose();
      // Always keep at least one blank row so the form never collapses to empty.
      if (_items.isEmpty) _items.add(_ItemDraft());
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final customer = _customerController.text.trim();
    final now = DateTime.now();
    final picklistId = const Uuid().v4();

    final items = <PicklistItem>[];
    for (final draft in _items) {
      final productName = draft.product.text.trim();
      final requested = int.tryParse(draft.qty.text.trim()) ?? 0;
      if (productName.isEmpty || requested <= 0) continue;
      items.add(
        PicklistItem(
          id: const Uuid().v4(),
          picklistId: picklistId,
          productName: productName,
          requestedQty: requested,
          takenQty: 0,
          updatedAt: now,
        ),
      );
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
        );
      }
    }
  }

  String? _validateCustomer(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Customer name is required.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: const Text('New Picklist')),
      body: AppBackground(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 96),
            children: [
              GlassCard(
                child: TextFormField(
                  controller: _customerController,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Customer Name',
                    border: OutlineInputBorder(),
                  ),
                  validator: _validateCustomer,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Requested Items',
                style: TextStyle(
                  color: AppDesign.textHi,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              for (var i = 0; i < _items.length; i++) ...[
                _buildItemRow(i),
                const SizedBox(height: 10),
              ],
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: _addItem,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Item'),
                ),
              ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
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
                : const Icon(Icons.save),
            label: Text(_saving ? 'Saving…' : 'Save Picklist'),
            style: FilledButton.styleFrom(
              backgroundColor: AppDesign.blue,
              foregroundColor: AppDesign.onBlue,
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildItemRow(int index) {
    final draft = _items[index];
    return GlassCard(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: draft.product,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(
                labelText: 'Product #${index + 1}',
                border: const OutlineInputBorder(),
              ),
              validator: (value) {
                // A row is either fully filled or ignored on save; only flag a
                // row where the worker typed a quantity but no product name.
                final hasQty = (int.tryParse(draft.qty.text.trim()) ?? 0) > 0;
                if (hasQty && (value == null || value.trim().isEmpty)) {
                  return 'Name required.';
                }
                return null;
              },
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 1,
            child: TextFormField(
              controller: draft.qty,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Qty',
                border: OutlineInputBorder(),
              ),
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            ),
          ),
          IconButton(
            onPressed: _items.length > 1 || draft.product.text.isNotEmpty
                ? () => _removeItem(index)
                : null,
            icon: const Icon(Icons.delete_outline),
            color: AppDesign.danger,
            tooltip: 'Remove item',
          ),
        ],
      ),
    );
  }
}
