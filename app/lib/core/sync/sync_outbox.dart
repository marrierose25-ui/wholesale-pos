import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'sync_outbox_entry.dart';

/// Appends a change to the outbox. Callers pass the *same transaction handle*
/// they used for the business write, so the data change and its queue entry
/// commit or roll back together — the classic transactional-outbox guarantee
/// that no event is ever lost or duplicated by a crash.
class SyncOutbox {
  SyncOutbox._();

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
