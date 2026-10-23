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
