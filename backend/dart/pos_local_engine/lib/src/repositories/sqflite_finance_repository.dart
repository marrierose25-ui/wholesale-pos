import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../sync/sync_outbox.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/finance.dart';

class SqfliteFinanceRepository implements FinanceRepository {
  final Database _db;

  SqfliteFinanceRepository(this._db);

  static const int _maxNameLength = 80;
  static const int _maxSourceLength = 120;
  static const int _maxDescriptionLength = 500;

  /// Active, and either the OWNER or ticked for Money Tracking. Read from the
  /// same executor as the work it guards, so a permission change made in the
  /// browser (which the pull applies to this row) takes effect immediately.
  Future<void> _requireFinanceAccess(
    DatabaseExecutor executor,
    String userId,
  ) async {
    final rows = await executor.query(
      'users',
      columns: ['role', 'is_active', 'permissions'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty || rows.first['is_active'] != 1) {
      throw Exception('Only an active account can access financial records.');
    }
    if (rows.first['role'] == 'OWNER') return;
    final held = User.decodePermissions(rows.first['permissions']);
    if (!held.contains('finance')) {
      throw Exception('This account does not have Money Tracking access.');
    }
  }

  Future<void> _audit(
    DatabaseExecutor executor,
    String userId,
    String action,
    String details,
  ) async {
    try {
      await executor.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': action,
        'details': details,
        'created_at': DateTime.now().toIso8601String(),
      });
    } catch (error) {
      // A local audit-table failure must never roll back real financial
      // activity, but it must be visible in the support log. Do not include
      // the financial payload/details here; the action and actor are enough
      // to correlate the failure with the transaction.
      AppLogger.error(
        'Finance audit write failed for $action (actor $userId): $error',
      );
    }
  }

  String _validatedName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      throw Exception('A name is required.');
    }
    if (trimmed.length > _maxNameLength) {
      throw Exception('Name must be $_maxNameLength characters or fewer.');
    }
    return trimmed;
  }

  // ------------------------------------------------------------------
  // Categories (people)
  // ------------------------------------------------------------------

  @override
  Future<List<FinanceCategory>> getCategories(String ownerId) async {
    await _requireFinanceAccess(_db, ownerId);
    final maps = await _db.query(
      'finance_categories',
      where: 'deleted_at IS NULL',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return maps.map(FinanceCategory.fromMap).toList();
  }

  /// People in the recycle bin (soft-deleted), newest trashed first.
  @override
  Future<List<FinanceCategory>> getDeletedCategories(String ownerId) async {
    await _requireFinanceAccess(_db, ownerId);
    final maps = await _db.query(
      'finance_categories',
      where: 'deleted_at IS NOT NULL',
      orderBy: 'deleted_at DESC',
    );
    return maps.map(FinanceCategory.fromMap).toList();
  }

  /// Categories with pending entry counts and pending totals, for the
  /// overview list.
  @override
  Future<List<Map<String, dynamic>>> getCategorySummaries(
    String ownerId,
  ) async {
    await _requireFinanceAccess(_db, ownerId);
    return _db.rawQuery('''
      SELECT finance_categories.id,
             finance_categories.name,
             COUNT(finance_entries.id) AS pending_count,
             COALESCE(SUM(finance_entries.amount_minor_units), 0) AS pending_total
      FROM finance_categories
      LEFT JOIN finance_entries
        ON finance_entries.category_id = finance_categories.id
       AND finance_entries.status = 'PENDING'
      WHERE finance_categories.deleted_at IS NULL
      GROUP BY finance_categories.id, finance_categories.name
      ORDER BY finance_categories.name COLLATE NOCASE ASC
    ''');
  }

  @override
  Future<FinanceCategory> createCategory({
    required String ownerId,
    required String name,
  }) async {
    final trimmed = _validatedName(name);
    final now = DateTime.now();
    final category = FinanceCategory(
      id: const Uuid().v4(),
      name: trimmed,
      createdAt: now,
      updatedAt: now,
    );

    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      await txn.insert('finance_categories', category.toMap());
      await _enqueueCategory(txn, category.id);
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_CREATED',
        'Person "$trimmed" added.',
      );
    });
    return category;
  }

  /// Renames a person. Entries stay attached to the same row, so history is
  /// preserved and remains searchable under the new name.
  @override
  Future<void> renameCategory({
    required String ownerId,
    required String categoryId,
    required String newName,
  }) async {
    final trimmed = _validatedName(newName);
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw Exception('Person not found.');
      }
      final oldName = existing.first['name'] as String;
      await txn.update(
        'finance_categories',
        {'name': trimmed, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [categoryId],
      );
      await _enqueueCategory(txn, categoryId);
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_RENAMED',
        'Person "$oldName" renamed to "$trimmed".',
      );
    });
  }

  /// Moves a person to the recycle bin. History is kept; the person and their
  /// entries leave the active area until restored or permanently deleted.
  @override
  Future<void> deleteCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (existing.isEmpty) throw Exception('Person not found.');
      if (existing.first['deleted_at'] != null) {
        throw Exception('Person is already in the recycle bin.');
      }
      final name = existing.first['name'] as String;
      await txn.update(
        'finance_categories',
        {
          'deleted_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [categoryId],
      );
      await _enqueueCategory(txn, categoryId);
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_DELETED',
        'Person "$name" moved to the recycle bin.',
      );
    });
  }

  /// Restores a binned person back to the active area.
  @override
  Future<void> restoreCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (existing.isEmpty) throw Exception('Person not found.');
      if (existing.first['deleted_at'] == null) {
        throw Exception('Person is not in the recycle bin.');
      }
      final name = existing.first['name'] as String;
      await txn.update(
        'finance_categories',
        {'deleted_at': null, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [categoryId],
      );
      await _enqueueCategory(txn, categoryId);
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_RESTORED',
        'Person "$name" restored from the recycle bin.',
      );
    });
  }

  /// Removes a binned person and all of their entries for good. Only allowed
  /// for people already in the recycle bin. Entries have no ON DELETE CASCADE,
  /// so they are removed explicitly inside the same transaction.
  @override
  Future<void> permanentlyDeleteCategory({
    required String ownerId,
    required String categoryId,
  }) async {
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (existing.isEmpty) throw Exception('Person not found.');
      if (existing.first['deleted_at'] == null) {
        throw Exception('Move the person to the recycle bin first.');
      }
      final name = existing.first['name'] as String;
      await txn.delete(
        'finance_entries',
        where: 'category_id = ?',
        whereArgs: [categoryId],
      );
      await txn.delete(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
      );
      // The purge has to reach the cloud too, or the person the till deleted
      // keeps a home on the web. A DELETE entry is applied through
      // `pos_delete_finance_category` — the same RPC the PWA's own permanent
      // delete calls — so the server re-checks that the row is binned and
      // removes its entries rather than trusting this device's word.
      await SyncOutbox.delete(
        txn,
        entityType: SyncEntities.financeCategory,
        entityId: categoryId,
      );
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_PERMANENTLY_DELETED',
        'Person "$name" and their entries permanently deleted.',
      );
    });
  }

  // ------------------------------------------------------------------
  // Outbox
  // ------------------------------------------------------------------

  /// Queues a person for the cloud, inside the caller's transaction. Read back
  /// rather than serialised from the model so the payload carries exactly what
  /// committed, `updated_at` included — the stamp the server compares against
  /// when the same person was edited on two surfaces.
  static Future<void> _enqueueCategory(
    DatabaseExecutor txn,
    String categoryId,
  ) async {
    final rows = await txn.query(
      'finance_categories',
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.financeCategory,
      entityId: categoryId,
      row: rows.first,
    );
  }

  /// Queues one collection. A mark-completed is the important case: the entry
  /// row changes status and a cash deposit rides with it, so both halves have
  /// to leave this device together or the web shows a completed collection with
  /// no movement against the drawer.
  static Future<void> _enqueueEntry(
    DatabaseExecutor txn,
    String entryId,
  ) async {
    final rows = await txn.query(
      'finance_entries',
      where: 'id = ?',
      whereArgs: [entryId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsertRow(
      txn,
      entityType: SyncEntities.financeEntry,
      entityId: entryId,
      row: rows.first,
    );
  }

  // ------------------------------------------------------------------
  // Entries
  // ------------------------------------------------------------------

  String _validatedSource(String source) {
    final trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw Exception('A source is required (e.g., a bank name).');
    }
    if (trimmed.length > _maxSourceLength) {
      throw Exception('Source must be $_maxSourceLength characters or fewer.');
    }
    return trimmed;
  }

  /// Normalizes the optional Cash/Bank tender marker on a collection. Returns
  /// `null` when unset so older entries and non-cash collections stay neutral.
  String? _validatedPaymentMethod(String? paymentMethod) {
    if (paymentMethod == null) return null;
    final normalized = paymentMethod.trim().toUpperCase();
    if (normalized.isEmpty) return null;
    if (normalized != 'CASH' && normalized != 'BANK') {
      throw Exception('Payment method must be CASH or BANK.');
    }
    return normalized;
  }

  Future<FinanceCategory> _requireCategory(
    DatabaseExecutor executor,
    String categoryId,
  ) async {
    final maps = await executor.query(
      'finance_categories',
      where: 'id = ?',
      whereArgs: [categoryId],
      limit: 1,
    );
    if (maps.isEmpty) throw Exception('Person not found.');
    return FinanceCategory.fromMap(maps.first);
  }

  @override
  Future<FinanceEntry> addEntry({
    required String ownerId,
    required String categoryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  }) async {
    final validatedSource = _validatedSource(source);
    final validatedPaymentMethod = _validatedPaymentMethod(paymentMethod);
    if (amountMinorUnits <= 0) {
      throw Exception('The amount must be greater than zero.');
    }
    final trimmedDescription = description?.trim();
    if (trimmedDescription != null &&
        trimmedDescription.length > _maxDescriptionLength) {
      throw Exception(
        'Description must be $_maxDescriptionLength characters or fewer.',
      );
    }

    final now = DateTime.now();
    final entry = FinanceEntry(
      id: const Uuid().v4(),
      categoryId: categoryId,
      source: validatedSource,
      amountMinorUnits: amountMinorUnits,
      description: trimmedDescription == null || trimmedDescription.isEmpty
          ? null
          : trimmedDescription,
      status: FinanceEntry.statusPending,
      entryDate: entryDate ?? now,
      createdAt: now,
      createdBy: ownerId,
      updatedAt: now,
      paymentMethod: validatedPaymentMethod,
    );

    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final category = await _requireCategory(txn, categoryId);
      await txn.insert('finance_entries', entry.toMap());
      await _enqueueEntry(txn, entry.id);
      await _audit(
        txn,
        ownerId,
        'FINANCE_ENTRY_ADDED',
        'Person "${category.name}": $validatedSource '
            '${MoneyUtils.formatBr(amountMinorUnits)} (pending).',
      );
    });
    return entry;
  }

  /// Edits a still-pending entry. Completed entries are immutable so the
  /// completion record stays a reliable audit trail.
  @override
  Future<void> updateEntry({
    required String ownerId,
    required String entryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
    String? paymentMethod,
  }) async {
    final validatedSource = _validatedSource(source);
    final validatedPaymentMethod = _validatedPaymentMethod(paymentMethod);
    if (amountMinorUnits <= 0) {
      throw Exception('The amount must be greater than zero.');
    }
    final trimmedDescription = description?.trim();

    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final maps = await txn.query(
        'finance_entries',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );
      if (maps.isEmpty) throw Exception('Entry not found.');
      if (maps.first['status'] != FinanceEntry.statusPending) {
        throw Exception('Only pending entries can be edited.');
      }
      final entry = FinanceEntry.fromMap(maps.first);
      final category = await _requireCategory(txn, entry.categoryId);

      await txn.update(
        'finance_entries',
        {
          'source': validatedSource,
          'amount_minor_units': amountMinorUnits,
          'description':
              trimmedDescription == null || trimmedDescription.isEmpty
              ? null
              : trimmedDescription,
          'entry_date': (entryDate ?? entry.entryDate).toIso8601String(),
          'payment_method': validatedPaymentMethod,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [entryId, FinanceEntry.statusPending],
      );
      await _enqueueEntry(txn, entryId);
      await _audit(
        txn,
        ownerId,
        'FINANCE_ENTRY_UPDATED',
        'Pending entry for "${category.name}" edited: '
            '$validatedSource ${MoneyUtils.formatBr(amountMinorUnits)}.',
      );
    });
  }

  /// Marks an entry as taken/completed. The entry leaves the pending list but
  /// stays stored permanently, searchable, and viewable in history.
  @override
  Future<void> markCompleted({
    required String ownerId,
    required String entryId,
  }) async {
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final maps = await txn.query(
        'finance_entries',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );
      if (maps.isEmpty) throw Exception('Entry not found.');
      if (maps.first['status'] != FinanceEntry.statusPending) {
        throw Exception('Entry is already completed.');
      }
      final entry = FinanceEntry.fromMap(maps.first);
      final category = await _requireCategory(txn, entry.categoryId);

      final now = DateTime.now();
      final updated = await txn.update(
        'finance_entries',
        {
          'status': FinanceEntry.statusCompleted,
          'completed_at': now.toIso8601String(),
          'completed_by': ownerId,
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [entryId, FinanceEntry.statusPending],
      );
      if (updated != 1) {
        throw Exception('Entry is no longer pending.');
      }
      await _enqueueEntry(txn, entryId);
      // A cash collection physically puts money into the drawer, so deposit it
      // onto the open (perpetual) shift. Bank/non-cash collections never touch
      // the register. With no drawer open there is nowhere for the money to
      // land: minting a shift here would leave the shop with a register the
      // owner never opened and a day no one can count, so the collection is
      // refused until the drawer is opened.
      if (entry.paymentMethod == 'CASH') {
        final shiftRows = await txn.query(
          'shifts',
          columns: ['id'],
          where: "status = 'OPEN'",
          limit: 1,
        );
        if (shiftRows.isEmpty) {
          throw Exception(
            'Open the register before completing a cash collection.',
          );
        }
        final shiftId = shiftRows.first['id'] as String;
        final movementId = const Uuid().v4();
        final movement = {
          'id': movementId,
          'shift_id': shiftId,
          'user_id': ownerId,
          'type': 'DEPOSIT',
          'amount_minor_units': entry.amountMinorUnits,
          'reason': 'Collected from ${category.name}',
          'created_at': now.toIso8601String(),
          // The collection this deposit came from. Without it the cloud cannot
          // tell this row from the deposit `pos_complete_finance` writes when
          // the browser completes the same entry — its one-deposit-per-entry
          // index only sees NULL here — and the money lands in the drawer
          // twice. The same map is the outbox payload, so it travels.
          'source_finance_entry_id': entry.id,
        };
        await txn.insert('cash_movements', movement);
        await SyncOutbox.upsert(
          txn,
          entityType: SyncEntities.cashMovement,
          entityId: movementId,
          payload: {'cash_movement': movement},
        );
      }
      await _audit(
        txn,
        ownerId,
        'FINANCE_ENTRY_COMPLETED',
        'Person "${category.name}": ${entry.source} '
            '${MoneyUtils.formatBr(entry.amountMinorUnits)} marked taken.',
      );
    });
  }

  /// Deletes a pending or completed entry. A completed CASH collection gets a
  /// matching WITHDRAWAL on the open drawer, so the money `markCompleted`
  /// deposited is returned rather than left behind. The row itself is marked
  /// `DELETED` instead of being removed: the ledger is append-only in the
  /// cloud, and the hidden status is what syncs the deletion to every surface.
  @override
  Future<void> deleteEntry({
    required String ownerId,
    required String entryId,
  }) async {
    final now = DateTime.now();
    await _db.transaction((txn) async {
      await _requireFinanceAccess(txn, ownerId);
      final maps = await txn.query(
        'finance_entries',
        where: 'id = ?',
        whereArgs: [entryId],
        limit: 1,
      );
      if (maps.isEmpty) throw Exception('Entry not found.');
      final entry = FinanceEntry.fromMap(maps.first);
      if (entry.status == FinanceEntry.statusDeleted) {
        throw Exception('Entry is already deleted.');
      }
      final category = await _requireCategory(txn, entry.categoryId);

      // A completed CASH collection deposited its amount into the drawer. Find
      // that deposit and post the exact opposite movement, not a raw row
      // deletion: the cash ledger is append-only and the reversal has to travel
      // to the cloud through the same `pos_add_cash_movement` path.
      if (entry.isCompleted && entry.isCash) {
        final deposits = await txn.query(
          'cash_movements',
          columns: ['id', 'amount_minor_units'],
          where: "source_finance_entry_id = ? AND type = 'DEPOSIT'",
          whereArgs: [entry.id],
        );
        // Older databases gained source_finance_entry_id in schema v17, but
        // existing deposits were not backfilled. Never infer a relationship
        // from amount, timestamp or description: deleting without the exact
        // linked deposit would leave drawer cash overstated.
        if (deposits.length != 1) {
          throw Exception(
            'This completed cash collection does not have exactly one linked '
            'deposit. Reconcile its cash movement before deleting it.',
          );
        }
        if (deposits.single['amount_minor_units'] != entry.amountMinorUnits) {
          throw Exception(
            'The linked cash deposit amount does not match this collection. '
            'Reconcile the cash movement before deleting it.',
          );
        }
        final existingReversals = await txn.query(
          'cash_movements',
          columns: ['id'],
          where: "source_finance_entry_id = ? AND type = 'WITHDRAWAL'",
          whereArgs: [entry.id],
        );
        if (existingReversals.isNotEmpty) {
          throw Exception(
            'This cash collection already has a linked withdrawal. '
            'Reconcile the cash movement before deleting it again.',
          );
        }

        final shifts = await txn.query(
          'shifts',
          columns: ['id'],
          where: "status = 'OPEN'",
          limit: 1,
        );
        if (shifts.isEmpty) {
          throw Exception(
            'Open the register before deleting a completed cash collection '
            'so its deposit can be reversed.',
          );
        }
        final movementId = const Uuid().v4();
        final movement = {
          'id': movementId,
          'shift_id': shifts.first['id'] as String,
          'user_id': ownerId,
          'type': 'WITHDRAWAL',
          'amount_minor_units': entry.amountMinorUnits,
          'reason':
              'Reversal: deleted cash collection from ${category.name} '
              '(${entry.source})',
          'created_at': now.toIso8601String(),
          // Links the reversal to its collection like the DEPOSIT does, so
          // the cloud can tell "the device already posted this leg" apart
          // from a second reversal and never books the money back twice.
          'source_finance_entry_id': entry.id,
        };
        await txn.insert('cash_movements', movement);
        await SyncOutbox.upsert(
          txn,
          entityType: SyncEntities.cashMovement,
          entityId: movementId,
          payload: {'cash_movement': movement},
        );
      }

      final updated = await txn.update(
        'finance_entries',
        {
          'status': FinanceEntry.statusDeleted,
          // Who deleted it is ledger data, not a UI hint: the cloud resolves
          // this actor through its own grant so a forged payload id cannot
          // re-attribute the deletion.
          'deleted_by': ownerId,
          'updated_at': now.toIso8601String(),
        },
        where: 'id = ? AND status != ?',
        whereArgs: [entryId, FinanceEntry.statusDeleted],
      );
      if (updated != 1) throw Exception('Entry is already deleted.');

      await _enqueueEntry(txn, entryId);
      await _audit(
        txn,
        ownerId,
        'FINANCE_ENTRY_DELETED',
        'Person "${category.name}": ${entry.source} '
            '${MoneyUtils.formatBr(entry.amountMinorUnits)} deleted.'
            '${entry.isCompleted && entry.isCash ? ' Cash deposit reversed.' : ''}',
      );
    });
  }

  /// Searches financial history. Matches person name, source, and
  /// description; filters by status and an optional entry-date range.
  @override
  Future<List<FinanceEntry>> searchEntries({
    required String ownerId,
    String? categoryId,
    String? searchQuery,
    String? status,
    DateRange? dateRange,
  }) async {
    await _requireFinanceAccess(_db, ownerId);

    final where = <String>[];
    final args = <dynamic>[];

    // A deleted entry stays in the table so its deletion can sync, but it must
    // never resurface in the active ledger or its totals.
    where.add('finance_entries.status != ?');
    args.add(FinanceEntry.statusDeleted);

    if (categoryId != null && categoryId.isNotEmpty) {
      where.add('finance_entries.category_id = ?');
      args.add(categoryId);
    }
    if (status != null &&
        status.isNotEmpty &&
        status != 'ALL' &&
        status != FinanceEntry.statusPending &&
        status != FinanceEntry.statusCompleted) {
      throw Exception('Invalid status filter.');
    }
    if (status != null && status.isNotEmpty && status != 'ALL') {
      where.add('finance_entries.status = ?');
      args.add(status);
    }
    if (dateRange != null) {
      where.add(
        'finance_entries.entry_date >= ? AND finance_entries.entry_date < ?',
      );
      args.add(dateRange.start.toIso8601String());
      args.add(dateRange.end.toIso8601String());
    }

    final query = searchQuery?.trim();
    if (query != null && query.isNotEmpty) {
      final pattern = '%${SaleRepository.escapeLike(query.toLowerCase())}%';
      const escape = r" ESCAPE '\'";
      where.add('''
        (LOWER(finance_entries.source) LIKE ?$escape
         OR LOWER(COALESCE(finance_entries.description, '')) LIKE ?$escape
         OR LOWER(finance_categories.name) LIKE ?$escape)
      ''');
      args.addAll(List.filled(3, pattern));
    }

    final sql = StringBuffer('''
      SELECT finance_entries.*, finance_categories.name AS category_name
      FROM finance_entries
      JOIN finance_categories
        ON finance_entries.category_id = finance_categories.id
       AND finance_categories.deleted_at IS NULL
    ''');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(
      ' ORDER BY finance_entries.entry_date DESC, finance_entries.created_at DESC',
    );

    final maps = await _db.rawQuery(sql.toString(), args);
    return maps.map(FinanceEntry.fromMap).toList();
  }

  /// Pending and completed totals for one person, used on the person page. A
  /// binned person reports zeros so the active views never surface their rows.
  @override
  Future<Map<String, int>> getPersonTotals(
    String ownerId,
    String categoryId,
  ) async {
    await _requireFinanceAccess(_db, ownerId);
    final rows = await _db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN finance_entries.status = 'PENDING' THEN finance_entries.amount_minor_units ELSE 0 END), 0) AS pending_total,
        COALESCE(SUM(CASE WHEN finance_entries.status = 'COMPLETED' THEN finance_entries.amount_minor_units ELSE 0 END), 0) AS completed_total
      FROM finance_entries
      JOIN finance_categories
        ON finance_entries.category_id = finance_categories.id
       AND finance_categories.deleted_at IS NULL
      WHERE finance_entries.category_id = ?
    ''',
      [categoryId],
    );
    final row = rows.first;
    return {
      'pending_total': row['pending_total'] as int,
      'completed_total': row['completed_total'] as int,
    };
  }
}
