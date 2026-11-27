import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pos_core/pos_core.dart';
import 'package:pos_contracts/pos_contracts.dart' hide AppBackend;

import '../../core/theme/app_design.dart';
import '../../core/theme/app_theme.dart';

/// The dedicated page for one person in the owner's private money area.
/// Pending and taken entries share one list in date order; the status chip on
/// each row says which it is, and a taken entry stays visible for good.
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
        status: 'ALL',
      );
      final totals = await widget.financeRepository.getPersonTotals(
        widget.currentUser.id,
        widget.categoryId,
      );
      if (!mounted) return;
      // One list in time order, newest first, whatever the status. The repo
      // already orders by entry date; re-sorting here keeps a locally inserted
      // row from jumping to the end.
      final ordered = [...entries]
        ..sort((a, b) => b.entryDate.compareTo(a.entryDate));
      setState(() {
        _entries = ordered;
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
      SnackBar(
        content: Text(e.toString().replaceAll('Exception: ', '')),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
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
          'Mark ${entry.source} (${MoneyUtils.formatBr(entry.amountMinorUnits)}) as taken? It stays in the list, marked as taken.'
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

  Future<void> _deleteEntry(FinanceEntry entry) async {
    final reversesCash = entry.isCompleted && entry.isCash;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Entry?'),
        content: Text(
          'Delete ${entry.source} (${MoneyUtils.formatBr(entry.amountMinorUnits)})? '
          'This cannot be undone.'
          '${reversesCash ? ' The cash amount was added to the register when this collection was marked taken, so it will be taken back out of the register too.' : ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await widget.financeRepository.deleteEntry(
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
        // A single scroll view: with the on-screen keyboard open the viewport
        // shrinks to a phone's top half, so the summary/search header must be
        // able to scroll away instead of overflowing a fixed Column.
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _buildSummary()),
            SliverToBoxAdapter(child: _buildSearch()),
            const SliverToBoxAdapter(child: Divider(height: 1)),
            if (_isLoading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _load, child: const Text('Retry')),
                    ],
                  ),
                ),
              )
            else if (_entries.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                  child: Text(
                    'No entries yet.',
                    style: TextStyle(color: AppDesign.textLo),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverList.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) =>
                      _buildEntryCard(_entries[index]),
                ),
              ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: 'fab-add-finance-entry',
        onPressed: () => _showAddEntryDialog(),
        icon: const Icon(CupertinoIcons.plus),
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
                      style: TextStyle(color: AppDesign.textLo, fontSize: 13),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      MoneyUtils.formatBr(_totals['pending_total'] ?? 0),
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppDesign.blue,
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
                      style: TextStyle(color: AppDesign.textLo, fontSize: 13),
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

  Widget _buildSearch() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
      child: TextField(
        controller: _searchController,
        decoration: InputDecoration(
          hintText: 'Search source or description...',
          prefixIcon: const Icon(CupertinoIcons.search),
          isDense: true,
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(CupertinoIcons.xmark),
                  onPressed: () {
                    _searchController.clear();
                    _load();
                  },
                ),
        ),
        onChanged: _onSearchChanged,
        onSubmitted: (_) => _load(),
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
            isPending
                ? CupertinoIcons.clock
                : CupertinoIcons.checkmark_circle_fill,
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    MoneyUtils.formatBr(entry.amountMinorUnits),
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              PopupMenuButton<String>(
                onSelected: (value) {
                  if (value == 'complete') _markCompleted(entry);
                  if (value == 'edit') _showAddEntryDialog(editing: entry);
                  if (value == 'delete') _deleteEntry(entry);
                },
                itemBuilder: (context) => [
                  if (isPending) ...[
                    const PopupMenuItem(
                      value: 'complete',
                      child: Text('Mark as Taken'),
                    ),
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                  ],
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
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
    // The on-screen keyboard lifts the dialog, so the body must be capped to
    // the space that is left above it and scroll, otherwise the action row is
    // pushed off a small phone and the Column overflows.
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final maxBodyHeight = (media.size.height - keyboard - 200).clamp(
      120.0,
      460.0,
    );
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      title: Text(
        widget.initial == null
            ? (_step == 0 ? 'Add Entry (1/2)' : 'Select Payment (2/2)')
            : (_step == 0 ? 'Edit Entry (1/2)' : 'Select Payment (2/2)'),
      ),
      content: MediaQuery(
        data: media.copyWith(viewInsets: EdgeInsets.zero),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 420, maxHeight: maxBodyHeight),
          child: SingleChildScrollView(
            clipBehavior: Clip.none,
            padding: const EdgeInsets.only(top: 8),
            child: _step == 0 ? _buildDetailsStep() : _buildPaymentStep(),
          ),
        ),
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
          controller: _amountController,
          autofocus: widget.initial == null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Amount (Br)'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _sourceController,
          decoration: const InputDecoration(
            labelText: 'Source (e.g., CBE Bank)',
          ),
        ),
        const SizedBox(height: 12),
        InkWell(
          onTap: _pickDate,
          borderRadius: BorderRadius.circular(6),
          child: InputDecorator(
            decoration: const InputDecoration(
              labelText: 'Date',
              suffixIcon: Icon(CupertinoIcons.calendar, size: 18),
            ),
            child: Text(
              '${_selectedDate.year}-'
              '${_selectedDate.month.toString().padLeft(2, '0')}-'
              '${_selectedDate.day.toString().padLeft(2, '0')}',
            ),
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
            color: AppDesign.cardSoft.withValues(alpha: 0.3),
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
        const SizedBox(height: 16),
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
