import 'package:sqflite/sqflite.dart';

import '../models/picklist.dart';
import '../models/picklist_customer.dart';
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

  /// The saved customer directory (schema 21), newest-typed names first.
  Future<List<PicklistCustomer>> getCustomers();

  /// Persists a new directory entry. Throws when the name is blank.
  Future<void> addCustomer(PicklistCustomer customer);

  /// Toggles one line fully-taken / untouched and re-derives the header status.
  /// [isTaken] sets `taken_qty` to the line's `requested_qty` (or back to 0),
  /// so a single tap fulfills a whole line — the auto-save checkbox path.
  Future<void> toggleItemTaken(String picklistId, String itemId, bool isTaken);

  /// Corrects one line (name, requested quantity, unit, unit price). Re-derives
  /// the header status from the remaining active lines.
  Future<void> updatePicklistItem(PicklistItem item);

  /// Soft-deletes one line. When it was the last active line the header is
  /// soft-deleted too, so the list leaves the queue instead of becoming empty.
  Future<void> deletePicklistItem(String picklistId, String itemId);

  /// Soft-deletes a whole list (header + lines) so every device hides it.
  Future<void> deletePicklist(String picklistId);
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
    final where = <String>['deleted_at IS NULL'];
    final args = <Object?>[];
    if (status != null && status.isNotEmpty) {
      where.add('status = ?');
      args.add(status);
    }
    final maps = await _db.query(
      'picklists',
      where: where.join(' AND '),
      whereArgs: args,
      orderBy: 'created_at DESC',
    );
    return maps.map(Picklist.fromMap).toList();
  }

  /// The line items of one picklist, in a stable creation order (product name)
  /// so the fulfillment screen keeps the same layout between visits. Deleted
  /// lines are filtered out here, never physically removed.
  @override
  Future<List<PicklistItem>> getItems(String picklistId) async {
    final maps = await _db.query(
      'picklist_items',
      where: 'picklist_id = ? AND deleted_at IS NULL',
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
    // Validate every line before the transaction so a bad row never leaves a
    // header behind, and recompute the total here rather than trusting the
    // caller's copy.
    final lineTotals = <String, int>{};
    for (final item in items) {
      if (item.productName.trim().isEmpty) {
        throw Exception('Every item needs a product name.');
      }
      lineTotals[item.id] = _safeLineTotal(
        item.unitPriceMinorUnits,
        item.requestedQty,
      );
    }

    await _db.transaction((txn) async {
      await txn.insert('picklists', picklist.toMap());
      for (final item in items) {
        final takenQty = item.takenQty < 0
            ? 0
            : (item.takenQty > item.requestedQty
                  ? item.requestedQty
                  : item.takenQty);
        await txn.insert('picklist_items', {
          ...item.toMap(),
          'product_name': item.productName.trim(),
          'taken_qty': takenQty,
          'line_total_minor_units': lineTotals[item.id],
        });
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
        columns: ['status', 'deleted_at'],
        where: 'id = ?',
        whereArgs: [picklistId],
        limit: 1,
      );
      if (headerRows.isEmpty || headerRows.first['deleted_at'] != null) {
        throw Exception('Picklist not found.');
      }
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
          where: 'id = ? AND picklist_id = ? AND deleted_at IS NULL',
          whereArgs: [item.id, picklistId],
        );
        await _enqueueItem(txn, item.id);
      }

      // Re-read every active item (not just the edited subset) so the status
      // reflects the whole list even if a partial save touched only some lines.
      final itemRows = await txn.query(
        'picklist_items',
        where: 'picklist_id = ? AND deleted_at IS NULL',
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
  /// at all → PENDING; any middle ground → PARTIAL. An empty set is PENDING;
  /// callers that delete the last line soft-delete the header instead.
  static String _deriveStatus(List<PicklistItem> items) {
    if (items.isEmpty) return Picklist.statusPending;
    if (items.every((i) => i.isFulfilled)) return Picklist.statusCompleted;
    if (items.every((i) => i.takenQty <= 0)) return Picklist.statusPending;
    return Picklist.statusPartial;
  }

  /// Corrects one line. Only an active, non-COMPLETED list may be edited, and
  /// only an active line: a tombstoned row is gone for every surface.
  @override
  Future<void> updatePicklistItem(PicklistItem item) async {
    final productName = item.productName.trim();
    if (productName.isEmpty) {
      throw Exception('Every item needs a product name.');
    }
    if (item.requestedQty <= 0) {
      throw Exception('Requested quantity must be a positive whole number.');
    }
    final lineTotal = _safeLineTotal(
      item.unitPriceMinorUnits,
      item.requestedQty,
    );
    await _db.transaction((txn) async {
      await _requireEditable(txn, item.picklistId);

      // Read the stored progress rather than trusting the caller's copy: the
      // edit dialog only changes the line definition, so `takenQty` must stay
      // what the warehouse actually recorded — clamped to the new ceiling.
      final existing = await txn.query(
        'picklist_items',
        columns: ['taken_qty'],
        where: 'id = ? AND picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [item.id, item.picklistId],
        limit: 1,
      );
      if (existing.isEmpty) throw Exception('Item not found.');
      final storedTaken = (existing.first['taken_qty'] as num?)?.toInt() ?? 0;
      final takenQty = storedTaken < 0
          ? 0
          : (storedTaken > item.requestedQty ? item.requestedQty : storedTaken);

      final now = DateTime.now();
      final nowText = now.toIso8601String();
      final updated = await txn.update(
        'picklist_items',
        {
          'product_name': productName,
          'requested_qty': item.requestedQty,
          'taken_qty': takenQty,
          'unit': item.unit,
          'unit_price_minor_units': item.unitPriceMinorUnits,
          // Recomputed here, never trusted from the caller, so a line total can
          // never disagree with its own quantity and price.
          'line_total_minor_units': lineTotal,
          'updated_at': nowText,
        },
        where: 'id = ? AND picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [item.id, item.picklistId],
      );
      if (updated != 1) throw Exception('Item not found.');
      await _enqueueItem(txn, item.id);

      await _rederiveHeader(txn, item.picklistId, nowText);
    });
  }

  /// Largest value the cloud's `int` money columns can hold (2^31 - 1). Native
  /// edits sync through `pos-api`, so a price or line total beyond this would
  /// be rejected by the database after the local write had already happened.
  static const int _maxMinorUnits = 2147483647;

  /// Multiplies price by quantity, rejecting a negative price and an unsafe
  /// product instead of letting the value overflow the cloud column.
  static int _safeLineTotal(int unitPriceMinorUnits, int requestedQty) {
    if (unitPriceMinorUnits < 0) {
      throw Exception('Price cannot be negative.');
    }
    if (requestedQty <= 0) {
      throw Exception('Requested quantity must be a positive whole number.');
    }
    if (unitPriceMinorUnits > _maxMinorUnits ||
        (unitPriceMinorUnits != 0 &&
            requestedQty > _maxMinorUnits ~/ unitPriceMinorUnits)) {
      throw Exception('Price is too large for that quantity.');
    }
    return unitPriceMinorUnits * requestedQty;
  }

  /// Soft-deletes one line. The last active line takes the header with it, so
  /// the queue never shows an empty list.
  @override
  Future<void> deletePicklistItem(String picklistId, String itemId) async {
    await _db.transaction((txn) async {
      await _requireEditable(txn, picklistId);

      final now = DateTime.now();
      final nowText = now.toIso8601String();
      final updated = await txn.update(
        'picklist_items',
        {'deleted_at': nowText, 'updated_at': nowText},
        where: 'id = ? AND picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [itemId, picklistId],
      );
      if (updated != 1) throw Exception('Item not found.');
      await _enqueueItem(txn, itemId);

      final remaining = await txn.query(
        'picklist_items',
        columns: ['id'],
        where: 'picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [picklistId],
        limit: 1,
      );
      if (remaining.isEmpty) {
        await _softDeleteHeader(txn, picklistId, nowText);
      } else {
        await _rederiveHeader(txn, picklistId, nowText);
      }
    });
  }

  /// Soft-deletes the whole list. Its lines are tombstoned too, so a device
  /// that still holds them cannot surface one through a direct item read.
  @override
  Future<void> deletePicklist(String picklistId) async {
    await _db.transaction((txn) async {
      final headerRows = await txn.query(
        'picklists',
        columns: ['id', 'status', 'deleted_at'],
        where: 'id = ?',
        whereArgs: [picklistId],
        limit: 1,
      );
      if (headerRows.isEmpty || headerRows.first['deleted_at'] != null) {
        throw Exception('Picklist not found.');
      }
      if (headerRows.first['status'] == Picklist.statusCompleted) {
        throw Exception('A completed picklist can no longer be edited.');
      }
      final nowText = DateTime.now().toIso8601String();
      final itemRows = await txn.query(
        'picklist_items',
        columns: ['id'],
        where: 'picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [picklistId],
      );
      for (final row in itemRows) {
        final itemId = row['id'] as String;
        await txn.update(
          'picklist_items',
          {'deleted_at': nowText, 'updated_at': nowText},
          where: 'id = ?',
          whereArgs: [itemId],
        );
        await _enqueueItem(txn, itemId);
      }
      await _softDeleteHeader(txn, picklistId, nowText);
    });
  }

  /// Refuses an edit on a missing, tombstoned or COMPLETED list.
  static Future<void> _requireEditable(
    DatabaseExecutor txn,
    String picklistId,
  ) async {
    final rows = await txn.query(
      'picklists',
      columns: ['status', 'deleted_at'],
      where: 'id = ?',
      whereArgs: [picklistId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['deleted_at'] != null) {
      throw Exception('Picklist not found.');
    }
    if (rows.first['status'] == Picklist.statusCompleted) {
      throw Exception('A completed picklist can no longer be edited.');
    }
  }

  /// Re-reads the active lines and writes the derived header status.
  static Future<void> _rederiveHeader(
    DatabaseExecutor txn,
    String picklistId,
    String nowText,
  ) async {
    final rows = await txn.query(
      'picklist_items',
      where: 'picklist_id = ? AND deleted_at IS NULL',
      whereArgs: [picklistId],
    );
    final status = _deriveStatus(rows.map(PicklistItem.fromMap).toList());
    await txn.update(
      'picklists',
      {'status': status, 'updated_at': nowText},
      where: 'id = ?',
      whereArgs: [picklistId],
    );
    await _enqueuePicklist(txn, picklistId);
  }

  /// Marks the header itself deleted and queues it.
  static Future<void> _softDeleteHeader(
    DatabaseExecutor txn,
    String picklistId,
    String nowText,
  ) async {
    await txn.update(
      'picklists',
      {'deleted_at': nowText, 'updated_at': nowText},
      where: 'id = ?',
      whereArgs: [picklistId],
    );
    await _enqueuePicklist(txn, picklistId);
  }

  // ------------------------------------------------------------------
  // Customer directory + auto-save toggle (schema 21)
  // ------------------------------------------------------------------

  @override
  Future<List<PicklistCustomer>> getCustomers() async {
    final maps = await _db.query(
      'picklist_customers',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return maps.map(PicklistCustomer.fromMap).toList();
  }

  @override
  Future<void> addCustomer(PicklistCustomer customer) async {
    final name = customer.name.trim();
    if (name.isEmpty) {
      throw Exception('A customer name is required.');
    }
    // The directory is a plain local lookup: it rides no sync outbox and never
    // touches the ledger customers/users tables.
    await _db.insert('picklist_customers', customer.toMap());
  }

  /// One-tap fulfillment: set the line's taken qty to its requested qty (or 0),
  /// then re-derive the parent status. Mirrors [updateItemQuantities]'s freeze
  /// on a COMPLETED list so closed history can never be reopened by a stray tap.
  @override
  Future<void> toggleItemTaken(
    String picklistId,
    String itemId,
    bool isTaken,
  ) async {
    await _db.transaction((txn) async {
      await _requireEditable(txn, picklistId);

      final itemRows = await txn.query(
        'picklist_items',
        where: 'id = ? AND picklist_id = ? AND deleted_at IS NULL',
        whereArgs: [itemId, picklistId],
        limit: 1,
      );
      if (itemRows.isEmpty) throw Exception('Item not found.');
      final requested = (itemRows.first['requested_qty'] as num?)?.toInt() ?? 0;

      final nowText = DateTime.now().toIso8601String();
      await txn.update(
        'picklist_items',
        {'taken_qty': isTaken ? requested : 0, 'updated_at': nowText},
        where: 'id = ? AND picklist_id = ?',
        whereArgs: [itemId, picklistId],
      );
      await _enqueueItem(txn, itemId);

      // Re-read the active line set so the header status reflects every item,
      // not just the one tapped.
      await _rederiveHeader(txn, picklistId, nowText);
    });
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
