import 'package:flutter/material.dart';

import '../../core/models/user.dart';
import '../../core/repositories/finance_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';
import 'finance_person_screen.dart';
import 'finance_recycle_bin_screen.dart';

/// Owner-only overview of people tracked in the private money area. Cashier
/// access is blocked in [FinanceRepository] at the data layer, not just here.
class FinanceOverviewScreen extends StatefulWidget {
  final FinanceRepository financeRepository;
  final User currentUser;

  const FinanceOverviewScreen({
    super.key,
    required this.financeRepository,
    required this.currentUser,
  });

  @override
  State<FinanceOverviewScreen> createState() => FinanceOverviewScreenState();
}

class FinanceOverviewScreenState extends State<FinanceOverviewScreen> {
  List<Map<String, dynamic>> _summaries = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  /// Pulls the latest per-person summaries. [silent] (the shell's tab-select
  /// hook) repaints in the background without the loading spinner.
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    }
    try {
      final summaries = await widget.financeRepository.getCategorySummaries(
        widget.currentUser.id,
      );
      if (!mounted) return;
      setState(() {
        _summaries = summaries;
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

  Future<void> _showAddPersonDialog() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => const _NameDialog(title: 'Add Person'),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.financeRepository.createCategory(
        ownerId: widget.currentUser.id,
        name: name,
      );
      await load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _showRenameDialog(Map<String, dynamic> summary) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _NameDialog(
        title: 'Rename Person',
        initial: summary['name'] as String,
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await widget.financeRepository.renameCategory(
        ownerId: widget.currentUser.id,
        categoryId: summary['id'] as String,
        newName: name,
      );
      await load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  void _showError(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
    );
  }

  Future<void> _confirmDelete(Map<String, dynamic> summary) async {
    final name = summary['name'] as String;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Move to recycle bin?'),
        content: Text(
          'Move "$name" to the recycle bin? Their entries stay saved and can '
          'be restored later, or deleted for good from the recycle bin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Move to bin'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await widget.financeRepository.deleteCategory(
        ownerId: widget.currentUser.id,
        categoryId: summary['id'] as String,
      );
      await load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _openRecycleBin() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FinanceRecycleBinScreen(
          financeRepository: widget.financeRepository,
          currentUser: widget.currentUser,
        ),
      ),
    );
    load();
  }

  Future<void> _openPerson(Map<String, dynamic> summary) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FinancePersonScreen(
          financeRepository: widget.financeRepository,
          currentUser: widget.currentUser,
          categoryId: summary['id'] as String,
          personName: summary['name'] as String,
        ),
      ),
    );
    load();
  }

  @override
  Widget build(BuildContext context) {
    final totalPending = _summaries.fold<int>(
      0,
      (sum, row) => sum + (row['pending_total'] as int? ?? 0),
    );

    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Money Tracking'),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Recycle Bin',
            onPressed: _openRecycleBin,
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: load),
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
                    TextButton(onPressed: load, child: const Text('Retry')),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  GlassCard(
                    padding: EdgeInsets.zero,
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Pending Across Everyone',
                            style: TextStyle(
                              color: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.color,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            MoneyUtils.formatBr(totalPending),
                            style: TextStyle(
                              fontSize: 28,
                              fontWeight: FontWeight.bold,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_summaries.isEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No people yet. Add the names you want to track '
                          'money for.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Theme.of(context).textTheme.bodySmall?.color,
                          ),
                        ),
                      ),
                    )
                  else
                    ..._summaries.map(_buildPersonTile),
                ],
              ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddPersonDialog,
        icon: const Icon(Icons.person_add),
        label: const Text('Add Person'),
      ),
    );
  }

  Widget _buildPersonTile(Map<String, dynamic> summary) {
    final name = summary['name'] as String;
    final pendingCount = summary['pending_count'] as int? ?? 0;
    final pendingTotal = summary['pending_total'] as int? ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppDesign.buttonGradient,
            ),
            child: Center(
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: const TextStyle(
                  color: AppDesign.onBlue,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
          ),
          title: Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(
            pendingCount == 0
                ? 'No pending entries'
                : '$pendingCount pending • ${MoneyUtils.formatBr(pendingTotal)}',
          ),
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'rename') {
                _showRenameDialog(summary);
              } else if (value == 'delete') {
                _confirmDelete(summary);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(
                value: 'delete',
                child: Text('Move to recycle bin'),
              ),
            ],
          ),
          onTap: () => _openPerson(summary),
        ),
      ),
    );
  }
}

class _NameDialog extends StatefulWidget {
  final String title;
  final String? initial;

  const _NameDialog({required this.title, this.initial});

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial ?? '');
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A name is required.');
      return;
    }
    Navigator.of(context).pop(name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(labelText: 'Name', errorText: _error),
            onSubmitted: (_) => _submit(),
          ),
          if (widget.title == 'Rename Person')
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                'Renaming keeps all existing entries and history.',
                style: TextStyle(fontSize: 12, color: AppTheme.muted),
              ),
            ),
        ],
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
