import 'package:flutter/material.dart';

import '../../core/models/product.dart';
import '../../core/repositories/product_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/utils/money_utils.dart';
import 'add_product_dialog.dart';

/// Owner screen for managing saved names. Saved names are optional
/// suggestions on the POS screen — the catalog is never required to make a
/// sale. Deactivated names are kept so they can be brought back later.
class ProductListScreen extends StatefulWidget {
  final ProductRepository repository;

  const ProductListScreen({super.key, required this.repository});

  @override
  State<ProductListScreen> createState() => _ProductListScreenState();
}

class _ProductListScreenState extends State<ProductListScreen> {
  List<Product> _activeNames = [];
  List<Product> _inactiveNames = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadNames();
  }

  Future<void> _loadNames() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final active = await widget.repository.getAllActive();
      final inactive = await widget.repository.getAllInactive();
      if (!mounted) return;
      setState(() {
        _activeNames = active;
        _inactiveNames = inactive;
        _isLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not load saved names.';
      });
    }
  }

  void _showError(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
    );
  }

  Future<void> _showAddDialog() async {
    final product = await showDialog<Product>(
      context: context,
      builder: (context) => const SavedNameDialog(),
    );
    if (product == null) return;
    try {
      await widget.repository.save(product);
      await _loadNames();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _showEditDialog(Product product) async {
    final updated = await showDialog<Product>(
      context: context,
      builder: (context) => SavedNameDialog(initial: product),
    );
    if (updated == null) return;
    try {
      await widget.repository.update(updated);
      await _loadNames();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _deactivate(Product product) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Deactivate Name?'),
        content: Text(
          '"${product.name}" will stop appearing as a suggestion on the POS '
          'screen. Existing sales keep their recorded names.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Deactivate'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.repository.deactivate(product.id);
      await _loadNames();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _reactivate(Product product) async {
    try {
      await widget.repository.reactivate(product.id);
      await _loadNames();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Saved Names'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadNames),
          const SizedBox(width: 16),
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
                    TextButton(
                      onPressed: _loadNames,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Row(
                        children: [
                          const IconChip(icon: Icons.info_outline, size: 32),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Saved names are optional shortcuts for the POS '
                              'screen — tapping one pre-fills the name and '
                              'default price. Cashiers can always type any '
                              'product name without saving it here.',
                              style: TextStyle(
                                color: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.color,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'ACTIVE NAMES',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (_activeNames.isEmpty)
                    GlassCard(
                      padding: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Center(
                          child: Text(
                            'No saved names yet. Sales never require them — '
                            'add one only if you want a shortcut.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    ..._activeNames.map(_buildActiveTile),
                  if (_inactiveNames.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      'DEACTIVATED',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).textTheme.bodySmall?.color,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ..._inactiveNames.map(_buildInactiveTile),
                  ],
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddDialog,
        icon: const Icon(Icons.add),
        label: const Text('Add Name'),
      ),
    );
  }

  Widget _buildActiveTile(Product product) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: const IconChip(icon: Icons.label_rounded, size: 38),
          title: Text(
            product.name,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            product.sellingPriceMinorUnits > 0
                ? 'Default: ${MoneyUtils.formatBr(product.sellingPriceMinorUnits)}'
                : 'No default price',
            style: const TextStyle(fontSize: 12),
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'edit') _showEditDialog(product);
              if (value == 'deactivate') _deactivate(product);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'deactivate', child: Text('Deactivate')),
            ],
          ),
          onTap: () => _showEditDialog(product),
        ),
      ),
    );
  }

  Widget _buildInactiveTile(Product product) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          dense: true,
          leading: IconChip(
            icon: Icons.label_off_rounded,
            size: 36,
            color: AppDesign.textFaint,
          ),
          title: Text(
            product.name,
            style: TextStyle(
              color: Theme.of(context).textTheme.bodySmall?.color,
            ),
          ),
          trailing: TextButton.icon(
            onPressed: () => _reactivate(product),
            icon: const Icon(Icons.restore, size: 16),
            label: const Text('Restore'),
          ),
        ),
      ),
    );
  }
}
