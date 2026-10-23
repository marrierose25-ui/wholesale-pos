import 'package:sqflite/sqflite.dart';

import 'sync_outbox_entry.dart';

/// Reads and updates the local outbox queue. Enqueuing lives in [SyncOutbox]
/// (called inside business transactions); this class only drains it.
class SyncOutboxRepository {
  final Database _db;

  SyncOutboxRepository(this._db);

  /// Oldest unsynced entries first, so the cloud sees events in order.
  Future<List<SyncOutboxEntry>> pending({int limit = 200}) async {
    final rows = await _db.query(
      'sync_outbox',
      where: 'synced_at IS NULL',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(SyncOutboxEntry.fromMap).toList();
  }

  Future<int> pendingCount() async {
    final rows = await _db.rawQuery(
      'SELECT COUNT(*) AS count FROM sync_outbox WHERE synced_at IS NULL',
    );
    return rows.first['count'] as int;
  }

  /// Marks entries as pushed. Done only after the backend accepted them.
  Future<void> markSynced(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.update(
      'sync_outbox',
      {'synced_at': DateTime.now().toIso8601String()},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  /// Removes already-synced rows to keep the queue from growing forever.
  /// Only ever deletes rows with a non-null synced_at.
  Future<int> pruneSynced() async {
    return _db.delete('sync_outbox', where: 'synced_at IS NOT NULL');
  }
}
