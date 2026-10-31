import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'sync_outbox_entry.dart';

/// Which table and columns name the operator behind a sync entity. Kept in code
/// rather than in a payload so the outbox, not the caller, decides what leaves
/// the device.
class _LedgerOwner {
  const _LedgerOwner(this.table, this.columns);

  final String table;
  final List<String> columns;
}

/// Appends a change to the outbox. Callers pass the *same transaction handle*
/// they used for the business write, so the data change and its queue entry
/// commit or roll back together — the classic transactional-outbox guarantee
/// that no event is ever lost or duplicated by a crash.
class SyncOutbox {
  SyncOutbox._();

  /// Money a training account rang up belongs to that till alone: its sales,
  /// shifts, deposits, void requests and collections are never pushed, because
  /// once they reach the cloud they land in every device's dashboard, sales
  /// history and drawer. Checked here rather than at each call site so a future
  /// writer cannot forget it. Master data is deliberately absent: the demo
  /// account's own row must keep syncing (that is how its login works on every
  /// device), and products and people are shared by design.
  ///
  /// A finance entry names two hands, because a collection is really two rows:
  /// the entry and the deposit that pays it. If either was the demo account,
  /// both stay home — pushing only the entry would leave the cloud with a
  /// collection marked taken and no money behind it.
  static const Map<String, _LedgerOwner> _ledgerOwners = {
    SyncEntities.sale: _LedgerOwner('sales', ['cashier_id']),
    SyncEntities.shift: _LedgerOwner('shifts', ['cashier_id']),
    SyncEntities.cashMovement: _LedgerOwner('cash_movements', ['user_id']),
    SyncEntities.voidRequest: _LedgerOwner('void_requests', ['requested_by']),
    SyncEntities.financeEntry: _LedgerOwner('finance_entries', [
      'created_by',
      'completed_by',
    ]),
  };

  /// True when this row was written by an account flagged `is_demo`.
  ///
  /// Answers false when the row is already gone (a delete of something the
  /// device just removed) or the operator is unknown, so real money always
  /// syncs: only a positively identified training account is ever held back.
  /// The table and columns come from the constant map above, never from input.
  static Future<bool> _isDemoOwned(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
  }) async {
    final owner = _ledgerOwners[entityType];
    if (owner == null) return false;
    final actors = owner.columns.map((c) => 't.$c').join(', ');
    final rows = await txn.rawQuery(
      '''
      SELECT 1 FROM ${owner.table} t
      JOIN users u ON u.id IN ($actors)
      WHERE t.id = ? AND u.is_demo = 1
      LIMIT 1
      ''',
      [entityId],
    );
    if (rows.isNotEmpty) return true;
    // A deposit is the second half of a collection: it names the operator who
    // carried the cash, but it was the finance entry's hands that made the
    // money a training exercise. Looking only at the movement's own user_id
    // let a demo collection leave the till through a deposit written by a real
    // account.
    if (entityType == SyncEntities.cashMovement) {
      final entryCheck = await txn.rawQuery(
        '''
        SELECT 1 FROM cash_movements cm
        JOIN finance_entries fe ON fe.id = cm.source_finance_entry_id
        JOIN users u ON u.id IN (fe.created_by, fe.completed_by)
        WHERE cm.id = ? AND u.is_demo = 1
        LIMIT 1
        ''',
        [entityId],
      );
      return entryCheck.isNotEmpty;
    }
    return false;
  }

  /// Queues a whole row, filed under the key its entity type uses.
  ///
  /// The row is read by the caller straight out of the database and passed
  /// through [timestampsToUtc] on the way in, so what the cloud receives is
  /// this device's data with real instants rather than wall-clock guesses.
  static Future<void> upsertRow(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    required Map<String, Object?> row,
  }) async {
    final key = SyncEntities.payloadKeys[entityType];
    if (key == null) {
      throw ArgumentError.value(
        entityType,
        'entityType',
        'unknown sync entity',
      );
    }
    await upsert(
      txn,
      entityType: entityType,
      entityId: entityId,
      payload: {key: timestampsToUtc(row)},
    );
  }

  /// Rewrites every `..._at` / `..._date` value as an explicit UTC instant.
  ///
  /// SQLite stores `DateTime.now().toIso8601String()`, which is LOCAL wall
  /// clock with no zone suffix. Postgres reads such a string in its own zone
  /// (UTC on Supabase), so a 14:00 entry in a UTC+3 shop would be filed as
  /// 14:00 UTC and every other screen would show it three hours late —
  /// potentially on the wrong day, which moves a sale out of a report range.
  /// Attaching the offset here means the cloud stores the moment, and the pull
  /// converts it back into each device's own wall clock.
  ///
  /// A value that already carries an offset or a `Z` is left exactly as it is.
  static Map<String, Object?> timestampsToUtc(Map<String, Object?> row) {
    return row.map((column, value) {
      if (value is! String || value.isEmpty) return MapEntry(column, value);
      if (!column.endsWith('_at') && !column.endsWith('_date')) {
        return MapEntry(column, value);
      }
      final parsed = DateTime.tryParse(value);
      if (parsed == null || parsed.isUtc) return MapEntry(column, value);
      return MapEntry(column, parsed.toUtc().toIso8601String());
    });
  }

  static Future<void> upsert(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
    required Map<String, Object?> payload,
  }) async {
    if (await _isDemoOwned(txn, entityType: entityType, entityId: entityId)) {
      return;
    }
    await txn.insert('sync_outbox', {
      'id': const Uuid().v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': SyncOperations.upsert,
      'payload': jsonEncode(payload),
      'created_at': DateTime.now().toIso8601String(),
      'synced_at': null,
    });
  }

  static Future<void> delete(
    DatabaseExecutor txn, {
    required String entityType,
    required String entityId,
  }) async {
    if (await _isDemoOwned(txn, entityType: entityType, entityId: entityId)) {
      return;
    }
    await txn.insert('sync_outbox', {
      'id': const Uuid().v4(),
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': SyncOperations.delete,
      'payload': jsonEncode({'id': entityId}),
      'created_at': DateTime.now().toIso8601String(),
      'synced_at': null,
    });
  }
}
