import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show FilteringTextInputFormatter;

import '../../core/models/picklist.dart';
import '../../core/models/picklist_item.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'warehouse_shared.dart';

/// Fulfillment screen for one picklist: shows the requested lines and lets a
/// warehouse worker enter how much was actually taken. Saving writes the new
/// quantities through [PicklistRepository.updateItemQuantities], which recomputes
/// the header status and queues everything to the outbox.
///
/// A COMPLETED picklist is frozen — the fields render read-only so closed
/// history can never be restated. This screen only ever touches the picklist
/// tables, never Sales or the drawer.
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
  final Map<String, TextEditingController> _controllers = {};
  bool _isLoading = true;
  bool _saving = false;
  String? _error;

  bool get _readOnly => widget.picklist.isCompleted;

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
      for (final item in items) {
        _controllers[item.id] = TextEditingController(
          text: item.takenQty.toString(),
        );
      }
      if (!mounted) return;
      setState(() {
        _items = items;
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

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _saveProgress() async {
    if (_saving || _readOnly) return;
    setState(() => _saving = true);

    final updated = <PicklistItem>[];
    for (final item in _items) {
      final taken =
          int.tryParse(_controllers[item.id]?.text ?? '') ?? item.takenQty;
      final clamped = taken < 0 ? 0 : taken;
      updated.add(item.copyWith(takenQty: clamped, updatedAt: DateTime.now()));
    }

    try {
      await widget.repository.updateItemQuantities(widget.picklist.id, updated);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Progress saved')));
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
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
        title: Text(widget.picklist.customerName),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: PicklistStatusChip(status: widget.picklist.status),
            ),
          ),
        ],
      ),
      body: AppBackground(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!),
                    const SizedBox(height: 8),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  if (_readOnly)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Text(
                        'This picklist is completed and read-only.',
                        style: TextStyle(
                          color: AppDesign.textLo,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  for (final item in _items) _buildItemCard(item),
                ],
              ),
      ),
      bottomNavigationBar: _readOnly
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: FilledButton.icon(
                  onPressed: _saving ? null : _saveProgress,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppDesign.onBlue,
                          ),
                        )
                      : const Icon(Icons.playlist_add_check),
                  label: Text(_saving ? 'Saving…' : 'Save Progress'),
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

  Widget _buildItemCard(PicklistItem item) {
    final controller = _controllers[item.id];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.productName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Requested: ${item.requestedQty}',
                    style: TextStyle(color: AppDesign.textLo, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 88,
              child: TextField(
                controller: controller,
                readOnly: _readOnly,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: InputDecoration(
                  labelText: 'Taken',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  isDense: true,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
