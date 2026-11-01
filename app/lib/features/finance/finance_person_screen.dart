import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/models/finance_entry.dart';
import '../../core/models/user.dart';
import '../../core/repositories/finance_repository.dart';
import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/money_utils.dart';

/// The dedicated page for one person in the owner's private money area.
/// Pending entries disappear from the active list once marked taken, but
/// stay permanently in history and remain searchable.
class FinancePersonScreen extends StatefulWidget {
  final FinanceRepository financeRepository;
  final User currentUser;
  final String categoryId;
  final String personName;

  const FinancePersonScreen({
    super.key,
    required this.financeRepository,
    required this.currentUser,
    required this.categoryId,
    required this.personName,
  });

  @override
  State<FinancePersonScreen> createState() => _FinancePersonScreenState();
}

class _FinancePersonScreenState extends State<FinancePersonScreen> {
  List<FinanceEntry> _entries = [];
  Map<String, int> _totals = {'pending_total': 0, 'completed_total': 0};
  bool _isLoading = true;
  String? _error;

  final _searchController = TextEditingController();
  Timer? _searchDebounce;

  String _statusFilter = 'PENDING';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final entries = await widget.financeRepository.searchEntries(
        ownerId: widget.currentUser.id,
        categoryId: widget.categoryId,
        searchQuery: _searchController.text.trim().isEmpty
            ? null
            : _searchController.text.trim(),
        status: _statusFilter,
      );
      final totals = await widget.financeRepository.getPersonTotals(
        widget.currentUser.id,
        widget.categoryId,
      );
      if (!mounted) return;
      setState(() {
        _entries = entries;
        _totals = totals;
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

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 350), _load);
  }

  void _showError(Object e) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(e.toString().replaceAll('Exception: ', ''))),
    );
  }

  Future<void> _showAddEntryDialog({FinanceEntry? editing}) async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => _EntryDialog(initial: editing),
    );
    if (result == null) return;

    try {
      if (editing == null) {
        await widget.financeRepository.addEntry(
          ownerId: widget.currentUser.id,
          categoryId: widget.categoryId,
          source: result['source'] as String,
          amountMinorUnits: result['amount'] as int,
          description: result['description'] as String?,
          entryDate: result['date'] as DateTime,
          paymentMethod: result['paymentMethod'] as String?,
        );
      } else {
        await widget.financeRepository.updateEntry(
          ownerId: widget.currentUser.id,
          entryId: editing.id,
          source: result['source'] as String,
          amountMinorUnits: result['amount'] as int,
          description: result['description'] as String?,
          entryDate: result['date'] as DateTime,
          paymentMethod: result['paymentMethod'] as String?,
        );
      }
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  Future<void> _markCompleted(FinanceEntry entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark as Taken?'),
        content: Text(
          'Mark ${entry.source} (${MoneyUtils.formatBr(entry.amountMinorUnits)}) as taken? It will leave the pending list but stay in history.'
          '${entry.isCash ? ' As a cash collection, the amount is also added to the register balance.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark Taken'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.financeRepository.markCompleted(
        ownerId: widget.currentUser.id,
        entryId: entry.id,
      );
      await _load();
    } catch (e) {
      if (mounted) _showError(e);
    }
  }

  String _formatDate(DateTime date) {
    return '${date.year.toString().padLeft(4, '0')}-'
        '${date.month.toString().padLeft(2, '0')}-'
        '${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(title: Text(widget.personName)),
      body: AppBackground(
        child: Column(
          children: [
            _buildSummary(),
            _buildTabsAndSearch(),
            const Divider(height: 1),
            Expanded(
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
                            onPressed: _load,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    )
                  : _entries.isEmpty
                  ? Center(
                      child: Text(
                        _statusFilter == 'PENDING'
                            ? 'No pending entries.'
                            : _statusFilter == 'COMPLETED'
                            ? 'No completed entries yet.'
                            : 'No entries yet.',
                        style: TextStyle(
                          color: Theme.of(context).textTheme.bodySmall?.color,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(16),
                      itemCount: _entries.length,
                      itemBuilder: (context, index) =>
                          _buildEntryCard(_entries[index]),
                    ),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddEntryDialog(),
        icon: const Icon(Icons.add),
        label: const Text('Add Entry'),
      ),
    );
  }

  Widget _buildSummary() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Row(
        children: [
          Expanded(
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pending',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      MoneyUtils.formatBr(_totals['pending_total'] ?? 0),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Taken (Completed)',
                      style: TextStyle(
                        color: Theme.of(context).textTheme.bodySmall?.color,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      MoneyUtils.formatBr(_totals['completed_total'] ?? 0),
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabsAndSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: Column(
        children: [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'PENDING', label: Text('Pending')),
              ButtonSegment(value: 'COMPLETED', label: Text('Completed')),
              ButtonSegment(value: 'ALL', label: Text('All History')),
            ],
            selected: {_statusFilter},
            onSelectionChanged: (selection) {
              setState(() => _statusFilter = selection.first);
              _load();
            },
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search source or description...',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              suffixIcon: _searchController.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        _load();
                      },
                    ),
            ),
            onChanged: _onSearchChanged,
            onSubmitted: (_) => _load(),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(FinanceEntry entry) {
    final isPending = !entry.isCompleted;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ListTile(
          leading: Icon(
            isPending ? Icons.schedule_rounded : Icons.check_circle_rounded,
            color: isPending ? AppDesign.warning : AppDesign.success,
          ),
          title: Text(
            entry.source,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_formatDate(entry.entryDate)} • ${entry.status}'
                '${entry.paymentMethod == null ? '' : ' • ${entry.paymentMethod == 'CASH' ? 'Cash' : 'Bank'}'}',
              ),
              if (entry.description != null &&
                  entry.description!.trim().isNotEmpty)
                Text(
                  entry.description!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              if (entry.isCompleted && entry.completedAt != null)
                Text(
                  'Taken on ${_formatDate(entry.completedAt!)}',
                  style: TextStyle(fontSize: 11, color: AppTheme.muted),
                ),
            ],
          ),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                MoneyUtils.formatBr(entry.amountMinorUnits),
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              if (isPending) ...[
                const SizedBox(width: 4),
                PopupMenuButton<String>(
                  onSelected: (value) {
                    if (value == 'complete') _markCompleted(entry);
                    if (value == 'edit') _showAddEntryDialog(editing: entry);
                  },
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: 'complete',
                      child: Text('Mark as Taken'),
                    ),
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EntryDialog extends StatefulWidget {
  final FinanceEntry? initial;

  const _EntryDialog({this.initial});

  @override
  State<_EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends State<_EntryDialog> {
  late final TextEditingController _sourceController;
  late final TextEditingController _amountController;
  late final TextEditingController _descriptionController;
  late DateTime _selectedDate;
  late String _paymentMethod;
  String? _error;
  bool _isSaving = false;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _sourceController = TextEditingController(text: initial?.source ?? '');
    _amountController = TextEditingController(
      text: initial == null
          ? ''
          : MoneyUtils.minorUnitsToString(initial.amountMinorUnits),
    );
    _descriptionController = TextEditingController(
      text: initial?.description ?? '',
    );
    _selectedDate = initial?.entryDate ?? DateTime.now();
    _paymentMethod = initial?.paymentMethod ?? 'CASH';
  }

  @override
  void dispose() {
    _sourceController.dispose();
    _amountController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  void _nextStep() {
    final source = _sourceController.text.trim();
    if (source.isEmpty) {
      setState(() => _error = 'A source is required (e.g., a bank name).');
      return;
    }
    final amount = MoneyUtils.stringToMinorUnits(_amountController.text);
    if (amount == null || amount <= 0) {
      setState(() => _error = 'Enter a valid amount in Br.');
      return;
    }
    setState(() {
      _error = null;
      _step = 1;
    });
  }

  void _submit() {
    final source = _sourceController.text.trim();
    final amount = MoneyUtils.stringToMinorUnits(_amountController.text);
    if (source.isEmpty || amount == null || amount <= 0) return;

    setState(() => _isSaving = true);
    Navigator.of(context).pop({
      'source': source,
      'amount': amount,
      'description': _descriptionController.text.trim(),
      'date': _selectedDate,
      'paymentMethod': _paymentMethod,
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.initial == null
            ? (_step == 0 ? 'Add Entry (1/2)' : 'Select Payment (2/2)')
            : (_step == 0 ? 'Edit Entry (1/2)' : 'Select Payment (2/2)'),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: _step == 0 ? _buildDetailsStep() : _buildPaymentStep(),
      ),
      actions: _step == 0
          ? [
              TextButton(
                onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton(onPressed: _nextStep, child: const Text('Next')),
            ]
          : [
              TextButton(
                onPressed: _isSaving ? null : () => setState(() => _step = 0),
                child: const Text('Back'),
              ),
              FilledButton(
                onPressed: _isSaving ? null : _submit,
                child: _isSaving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Complete'),
              ),
            ],
    );
  }

  Widget _buildDetailsStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _sourceController,
          autofocus: widget.initial == null,
          decoration: const InputDecoration(
            labelText: 'Source (e.g., CBE Bank)',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _amountController,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount (Br)'),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(6),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Date',
              suffixIcon: Icon(Icons.calendar_today, size: 18),
            ),
            child: Text(
              '${_selectedDate.year}-'
              '${_selectedDate.month.toString().padLeft(2, '0')}-'
              '${_selectedDate.day.toString().padLeft(2, '0')}',
            ),
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _descriptionController,
          decoration: const InputDecoration(
            labelText: 'Description / Notes (optional)',
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.danger, fontSize: 13),
          ),
        ],
      ],
    );
  }

  Widget _buildPaymentStep() {
    final source = _sourceController.text.trim();
    final amountStr = _amountController.text.trim();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Source: $source',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                'Amount: $amountStr Br',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Text(
          'How was this collected?',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in const <(String, String)>[
              ('CASH', 'Cash'),
              ('BANK', 'Bank Transfer'),
            ])
              ChoiceChip(
                label: Text(option.$2),
                selected: _paymentMethod == option.$1,
                onSelected: (_) => setState(() {
                  _paymentMethod = option.$1;
                }),
              ),
          ],
        ),
        const SizedBox(height: 16),
        if (_paymentMethod == 'CASH')
          Text(
            'Cash collections are added to the register when marked taken.',
            style: TextStyle(fontSize: 12, color: AppTheme.muted),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.danger, fontSize: 13),
          ),
        ],
      ],
    );
  }
}
