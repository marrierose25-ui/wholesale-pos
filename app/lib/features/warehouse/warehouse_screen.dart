import 'package:flutter/material.dart';

import '../../core/models/picklist.dart';
import '../../core/models/user.dart';
import '../../core/repositories/picklist_repository.dart';
import '../../core/theme/app_design.dart';
import 'create_picklist_screen.dart';
import 'picklist_detail_screen.dart';
import 'warehouse_shared.dart';

/// Directory of Warehouse Picklists — the landing screen for the Warehouse tab.
///
/// Deliberately standalone: it reads only [PicklistRepository] (picklist tables
/// + outbox) and never touches Sales, Register, or Finance. The layout borrows
/// the Money Tracking overview so the look is consistent across the app.
class WarehouseScreen extends StatefulWidget {
  final PicklistRepository repository;
  final User currentUser;

  /// Fired after a local write so the shell can nudge the sync engine to ship
  /// the queued outbox rows promptly (same cadence the ledger writes use).
  final VoidCallback? onDataChanged;

  const WarehouseScreen({
    super.key,
    required this.repository,
    required this.currentUser,
    this.onDataChanged,
  });

  @override
  State<WarehouseScreen> createState() => WarehouseScreenState();
}

class WarehouseScreenState extends State<WarehouseScreen> {
  /// The in-flight directory query the [FutureBuilder] watches. Reassigned on
  /// every refresh so the list repulls without remounting the screen.
  late Future<List<Picklist>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.repository.getPicklists();
  }

  /// Re-runs the directory fetch. Called by the shell on tab-select and by the
  /// refresh action after a create / fulfillment returns.
  Future<void> refresh({bool silent = false}) async {
    setState(() => _future = widget.repository.getPicklists());
  }

  Future<void> _createPicklist() async {
    final created = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => CreatePicklistScreen(
          repository: widget.repository,
          currentUser: widget.currentUser,
        ),
      ),
    );
    if (created == true) {
      widget.onDataChanged?.call();
      refresh();
    }
  }

  Future<void> _openPicklist(Picklist picklist) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (context) => PicklistDetailScreen(
          repository: widget.repository,
          picklist: picklist,
        ),
      ),
    );
    if (changed == true) {
      widget.onDataChanged?.call();
      refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppDesign.bg,
      appBar: AppBar(
        title: const Text('Warehouse'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: refresh),
          const SizedBox(width: 8),
        ],
      ),
      body: AppBackground(
        child: FutureBuilder<List<Picklist>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              final message = (snapshot.error?.toString() ?? '').replaceAll(
                'Exception: ',
                '',
              );
              return Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      message.isEmpty ? 'Could not load picklists.' : message,
                    ),
                    const SizedBox(height: 8),
                    TextButton(onPressed: refresh, child: const Text('Retry')),
                  ],
                ),
              );
            }
            final picklists = snapshot.data ?? const <Picklist>[];
            if (picklists.isEmpty) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text(
                    'No picklists yet. Create one to start fulfilling '
                    'customer orders.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Theme.of(context).textTheme.bodySmall?.color,
                    ),
                  ),
                ),
              );
            }
            return ListView(
              padding: const EdgeInsets.all(24),
              children: [for (final p in picklists) _buildPicklistCard(p)],
            );
          },
        ),
      ),
      // Only owners / warehouse staff ever reach this screen (the tab is gated
      // behind the `warehouse` tick), so the create action is offered to
      // everyone who can open it.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createPicklist,
        icon: const Icon(Icons.add),
        label: const Text('New Picklist'),
      ),
    );
  }

  Widget _buildPicklistCard(Picklist picklist) {
    final name = picklist.customerName;
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
          subtitle: Text(formatPicklistDate(picklist.createdAt)),
          trailing: PicklistStatusChip(status: picklist.status),
          onTap: () => _openPicklist(picklist),
        ),
      ),
    );
  }
}
