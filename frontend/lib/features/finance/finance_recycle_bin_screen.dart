import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;

import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';

/// Lists people moved to the recycle bin with Restore / Delete forever. Only
/// reachable by the owner (the repository enforces owner-only at the data
/// layer); permanent deletion here is the sole place entries are erased.
class FinanceRecycleBinScreen extends StatefulWidget {
  final FinanceRepository financeRepository;
  final User currentUser;

  const FinanceRecycleBinScreen({
    super.key,
    required this.financeRepository,
    required this.currentUser,
  });

  @override
  State<FinanceRecycleBinScreen> createState() =>
      _FinanceRecycleBinScreenState();
}

class _FinanceRecycleBinScreenState extends State<FinanceRecycleBinScreen> {
  List<FinanceCategory> _deleted = [];
  bool _isLoading = true;
  String? _error;

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
      final deleted = await widget.financeRepository.getDeletedCategories(
        widget.currentUser.id,
      );
      if (!mounted) return;
      setState(() {
        _deleted = deleted;
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

  void _showError(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
    );
  }

  Future<void> _restore(FinanceCategory category) async {
    try {
      await widget.financeRepository.restoreCategory(
        ownerId: widget.currentUser.id,
        categoryId: category.id,
      );
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _deleteForever(FinanceCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete forever?'),
        content: Text(
          'Permanently delete "${category.name}" and all of their entries? '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete forever'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.financeRepository.permanentlyDeleteCategory(
        ownerId: widget.currentUser.id,
        categoryId: category.id,
      );
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: const Text('Recycle Bin')),
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
            : _deleted.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'The recycle bin is empty.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppDesign.textLo),
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: _deleted.map(_buildTile).toList(),
              ),
      ),
    );
  }

  Widget _buildTile(FinanceCategory category) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(
            CupertinoIcons.person_crop_circle_badge_xmark,
            color: AppTheme.muted,
          ),
          title: Text(
            category.name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: category.deletedAt == null
              ? null
              : Text('Removed ${_formatDate(category.deletedAt!)}'),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => _restore(category),
                child: const Text('Restore'),
              ),
              IconButton(
                tooltip: 'Delete forever',
                icon: const Icon(CupertinoIcons.trash, color: AppTheme.danger),
                onPressed: () => _deleteForever(category),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }
}
