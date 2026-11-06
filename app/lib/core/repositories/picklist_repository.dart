import 'package:sqflite/sqflite.dart';

import '../models/picklist.dart';
import '../models/picklist_item.dart';
import '../sync/sync_outbox.dart';
import '../sync/sync_outbox_entry.dart';

/// Data access for the Warehouse Picklist (Digital Fulfillment) area.
///
/// This is a deliberately independent feature: it touches only the `picklists`
/// / `picklist_items` tables plus (natively) the [SyncOutbox]. It never reads
/// or writes Sales, Shifts, Register, or Finance, so a picklist can never show
/// up in Sales History or move a cent in the drawer. Access is gated at the
/// navigation layer behind the `warehouse` permission tick; the cloud `pos-api`
/// applies the same rule via `ACTION_FEATURES`.
///
/// An interface with two implementations so the same Warehouse screens drive
/// either the local SQLite store (native tills) or the cloud `pos-api` (PWA),
/// exactly like [FinanceRepository]. The contract names no storage detail.
abstract class PicklistRepository {
  /// Native default: a SQLite-backed repository over [db].
  factory PicklistRepository(Database db) = SqflitePicklistRepository;

  /// All picklists, newest first. When [status] is provided (PENDING /
  /// PARTIAL / COMPLETED) the list is narrowed to that state.
  Future<List<Picklist>> getPicklists({String? status});

  /// The line items of one picklist.
  Future<List<PicklistItem>> getItems(String picklistId);

  /// Creates a picklist header together with its items, atomically.
  Future<void> createPicklist(Picklist picklist, List<PicklistItem> items);

  /// Saves a fulfillment progress pass and re-derives the header status.
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  );
}

/// SQLite implementation of [PicklistRepository] for the native tills. Every
/// create/update rides in a single transaction that also appends the affected
/// rows to the [SyncOutbox], so the local write and its sync event commit or
/// roll back together.
class SqflitePicklistRepository implements PicklistRepository {
  final Database _db;

  SqflitePicklistRepository(this._db);

  // ------------------------------------------------------------------
  // Reads
  // ------------------------------------------------------------------

  @override
  Future<List<Picklist>> getPicklists({String? status}) async {
    final maps = await _db.query(
      'picklists',
      where: status == null || status.isEmpty ? null : 'status = ?',
      whereArgs: status == null || status.isEmpty ? null : [status],
      orderBy: 'created_at DESC',
    );
    return maps.map(Picklist.fromMap).toList();
  }

  /// The line items of one picklist, in a stable creation order (product name)
  /// so the fulfillment screen keeps the same layout between visits.
  @override
  Future<List<PicklistItem>> getItems(String picklistId) async {
    final maps = await _db.query(
      'picklist_items',
      where: 'picklist_id = ?',
      whereArgs: [picklistId],
      orderBy: 'product_name COLLATE NOCASE ASC',
    );
    return maps.map(PicklistItem.fromMap).toList();
  }

  // ------------------------------------------------------------------
  // Writes
  // ------------------------------------------------------------------

  /// Creates a picklist header together with its items in one transaction. The
  /// caller supplies the fully-built models (ids, timestamps, `takenQty`); this
  /// method persists them and queues both families for the cloud.
  @override
  Future<void> createPicklist(
    Picklist picklist,
    List<PicklistItem> items,
  ) async {
    final customer = picklist.customerName.trim();
    if (customer.isEmpty) {
      throw Exception('A customer name is required.');
    }
    if (items.isEmpty) {
      throw Exception('A picklist needs at least one item.');
    }

    await _db.transaction((txn) async {
      await txn.insert('picklists', picklist.toMap());
      for (final item in items) {
        await txn.insert('picklist_items', item.toMap());
        await _enqueueItem(txn, item.id);
      }
      // Parent last, once its items exist: the header carries the initial
      // status and depends on nothing, but ordering it after the items keeps
      // the outbox's apply (which lands headers before items) consistent.
      await _enqueuePicklist(txn, picklist.id);
    });
  }

  /// Saves a fulfillment progress pass. Writes each item's new `takenQty`, then
  /// re-derives the header status from the full item set so a partially-ticked
  /// list reads PARTIAL, a finished one COMPLETED, and an untouched one PENDING.
  ///
  /// A COMPLETED picklist is frozen: once history is closed it can no longer be
  /// edited, so the row is left exactly as it is.
  @override
  Future<void> updateItemQuantities(
    String picklistId,
    List<PicklistItem> updatedItems,
  ) async {
    await _db.transaction((txn) async {
      final headerRows = await txn.query(
        'picklists',
        columns: ['status'],
        where: 'id = ?',
        whereArgs: [picklistId],
        limit: 1,
      );
      if (headerRows.isEmpty) throw Exception('Picklist not found.');
      final currentStatus = headerRows.first['status'] as String;
      if (currentStatus == Picklist.statusCompleted) {
        throw Exception('A completed picklist can no longer be edited.');
      }

      final now = DateTime.now();
      final nowText = now.toIso8601String();
      for (final item in updatedItems) {
        await txn.update(
          'picklist_items',
          {'taken_qty': item.takenQty, 'updated_at': nowText},
          where: 'id = ? AND picklist_id = ?',
          whereArgs: [item.id, picklistId],
        );
        await _enqueueItem(txn, item.id);
      }

      // Re-read every item (not just the edited subset) so the status reflects
      // the whole list even if a partial save touched only some lines.
      final itemRows = await txn.query(
        'picklist_items',
        where: 'picklist_id = ?',
        whereArgs: [picklistId],
      );
      final items = itemRows.map(PicklistItem.fromMap).toList();
      final newStatus = _deriveStatus(items);

      await txn.update(
        'picklists',
        {'status': newStatus, 'updated_at': nowText},
        where: 'id = ?',
        whereArgs: [picklistId],
      );
      await _enqueuePicklist(txn, picklistId);
    });
  }

  /// Status from the item set: everything fulfilled → COMPLETED; nothing taken
  /// at all → PENDING; any middle ground → PARTIAL.
  static String _deriveStatus(List<PicklistItem> items) {
    if (items.every((i) => i.isFulfilled)) return Picklist.statusCompleted;
    if (items.every((i) => i.takenQty <= 0)) return Picklist.statusPending;
    return Picklist.statusPartial;
  }

  // ------------------------------------------------------------------
  // Outbox
  // ------------------------------------------------------------------

  /// Queues a picklist header, read back straight from the transaction so the
  /// payload carries exactly the committed status and `updated_at` — the stamp
  /// the cloud compares newest-wins.
  static Future<void> _enqueuePicklist(
    DatabaseExecutor txn,
    String picklistId,
  ) async {
    final rows = await txn.query(
      'picklists',
      where: 'id = ?',
      whereArgs: [picklistId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.picklist,
      entityId: picklistId,
      row: rows.first,
    );
  }

  /// Queues one line item alongside its header.
  static Future<void> _enqueueItem(DatabaseExecutor txn, String itemId) async {
    final rows = await txn.query(
      'picklist_items',
      where: 'id = ?',
      whereArgs: [itemId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.picklistItem,
      entityId: itemId,
      row: rows.first,
    );
  }
}
