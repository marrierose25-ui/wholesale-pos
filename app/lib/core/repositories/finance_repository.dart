import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../models/finance_category.dart';
import '../models/finance_entry.dart';
import '../utils/date_range.dart';
import '../utils/money_utils.dart';
import 'sale_repository.dart';

/// Data access for the owner's private money-tracking area. Every method —
/// reads included — verifies an active OWNER inside the query or transaction,
/// so cashiers are blocked at the data layer, not just by hidden navigation.
/// Financial entries are fully separate from sales and never affect revenue.
class FinanceRepository {
  final Database _db;

  FinanceRepository(this._db);

  static const int _maxNameLength = 80;
  static const int _maxSourceLength = 120;
  static const int _maxDescriptionLength = 500;

  Future<void> _requireActiveOwner(
    DatabaseExecutor executor,
    String userId,
  ) async {
    final rows = await executor.query(
      'users',
      columns: ['role', 'is_active'],
      where: 'id = ?',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty ||
        rows.first['role'] != 'OWNER' ||
        rows.first['is_active'] != 1) {
      throw Exception('Only an active owner can access financial records.');
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
    } catch (_) {
      // Auditing must never block financial record keeping.
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

  Future<List<FinanceCategory>> getCategories(String ownerId) async {
    await _requireActiveOwner(_db, ownerId);
    final maps = await _db.query(
      'finance_categories',
      orderBy: 'name COLLATE NOCASE ASC',
    );
    return maps.map(FinanceCategory.fromMap).toList();
  }

  /// Categories with pending entry counts and pending totals, for the
  /// overview list.
  Future<List<Map<String, dynamic>>> getCategorySummaries(
    String ownerId,
  ) async {
    await _requireActiveOwner(_db, ownerId);
    return _db.rawQuery('''
      SELECT finance_categories.id,
             finance_categories.name,
             COUNT(finance_entries.id) AS pending_count,
             COALESCE(SUM(finance_entries.amount_minor_units), 0) AS pending_total
      FROM finance_categories
      LEFT JOIN finance_entries
        ON finance_entries.category_id = finance_categories.id
       AND finance_entries.status = 'PENDING'
      GROUP BY finance_categories.id, finance_categories.name
      ORDER BY finance_categories.name COLLATE NOCASE ASC
    ''');
  }

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
      await _requireActiveOwner(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        columns: ['id'],
        where: 'LOWER(name) = LOWER(?)',
        whereArgs: [trimmed],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        throw Exception('A person named "$trimmed" already exists.');
      }
      await txn.insert('finance_categories', category.toMap());
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
  Future<void> renameCategory({
    required String ownerId,
    required String categoryId,
    required String newName,
  }) async {
    final trimmed = _validatedName(newName);
    await _db.transaction((txn) async {
      await _requireActiveOwner(txn, ownerId);
      final existing = await txn.query(
        'finance_categories',
        where: 'id = ?',
        whereArgs: [categoryId],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw Exception('Person not found.');
      }
      final duplicate = await txn.query(
        'finance_categories',
        columns: ['id'],
        where: 'LOWER(name) = LOWER(?) AND id != ?',
        whereArgs: [trimmed, categoryId],
        limit: 1,
      );
      if (duplicate.isNotEmpty) {
        throw Exception('A person named "$trimmed" already exists.');
      }
      final oldName = existing.first['name'] as String;
      await txn.update(
        'finance_categories',
        {'name': trimmed, 'updated_at': DateTime.now().toIso8601String()},
        where: 'id = ?',
        whereArgs: [categoryId],
      );
      await _audit(
        txn,
        ownerId,
        'FINANCE_CATEGORY_RENAMED',
        'Person "$oldName" renamed to "$trimmed".',
      );
    });
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

  Future<FinanceEntry> addEntry({
    required String ownerId,
    required String categoryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
  }) async {
    final validatedSource = _validatedSource(source);
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
    );

    await _db.transaction((txn) async {
      await _requireActiveOwner(txn, ownerId);
      final category = await _requireCategory(txn, categoryId);
      await txn.insert('finance_entries', entry.toMap());
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
  Future<void> updateEntry({
    required String ownerId,
    required String entryId,
    required String source,
    required int amountMinorUnits,
    String? description,
    DateTime? entryDate,
  }) async {
    final validatedSource = _validatedSource(source);
    if (amountMinorUnits <= 0) {
      throw Exception('The amount must be greater than zero.');
    }
    final trimmedDescription = description?.trim();

    await _db.transaction((txn) async {
      await _requireActiveOwner(txn, ownerId);
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
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ? AND status = ?',
        whereArgs: [entryId, FinanceEntry.statusPending],
      );
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
  Future<void> markCompleted({
    required String ownerId,
    required String entryId,
  }) async {
    await _db.transaction((txn) async {
      await _requireActiveOwner(txn, ownerId);
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
      await _audit(
        txn,
        ownerId,
        'FINANCE_ENTRY_COMPLETED',
        'Person "${category.name}": ${entry.source} '
            '${MoneyUtils.formatBr(entry.amountMinorUnits)} marked taken.',
      );
    });
  }

  /// Searches financial history. Matches person name, source, and
  /// description; filters by status and an optional entry-date range.
  Future<List<FinanceEntry>> searchEntries({
    required String ownerId,
    String? categoryId,
    String? searchQuery,
    String? status,
    DateRange? dateRange,
  }) async {
    await _requireActiveOwner(_db, ownerId);

    final where = <String>[];
    final args = <dynamic>[];

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
    ''');
    if (where.isNotEmpty) sql.write(' WHERE ${where.join(' AND ')}');
    sql.write(
      ' ORDER BY finance_entries.entry_date DESC, finance_entries.created_at DESC',
    );

    final maps = await _db.rawQuery(sql.toString(), args);
    return maps.map(FinanceEntry.fromMap).toList();
  }

  /// Pending and completed totals for one person, used on the person page.
  Future<Map<String, int>> getPersonTotals(
    String ownerId,
    String categoryId,
  ) async {
    await _requireActiveOwner(_db, ownerId);
    final rows = await _db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN status = 'PENDING' THEN amount_minor_units ELSE 0 END), 0) AS pending_total,
        COALESCE(SUM(CASE WHEN status = 'COMPLETED' THEN amount_minor_units ELSE 0 END), 0) AS completed_total
      FROM finance_entries
      WHERE category_id = ?
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
