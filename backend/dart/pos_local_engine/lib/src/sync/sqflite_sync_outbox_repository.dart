import 'package:sqflite/sqflite.dart';

import 'package:pos_contracts/pos_contracts.dart';

/// Local SQLite implementation of [SyncOutboxRepository].
class SqfliteSyncOutboxRepository implements SyncOutboxRepository {
  final Database _db;

  SqfliteSyncOutboxRepository(this._db);

  /// Oldest unsynced entries first, so the cloud sees events in order.
  /// Quarantined rows are excluded: they already got their verdict and only an
  /// explicit operator retry may re-queue them.
  @override
  Future<List<SyncOutboxEntry>> pending({int limit = 200}) async {
    final rows = await _db.query(
      'sync_outbox',
      where: "synced_at IS NULL AND COALESCE(status, 'pending') = 'pending'",
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(SyncOutboxEntry.fromMap).toList();
  }

  @override
  Future<int> pendingCount() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS count FROM sync_outbox "
      "WHERE synced_at IS NULL AND COALESCE(status, 'pending') = 'pending'",
    );
    return rows.first['count'] as int;
  }

  /// Marks entries as pushed. Done only after the backend confirmed the
  /// server applied them.
  @override
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

  /// Moves permanently refused entries into durable quarantine. The payload,
  /// entity identity and created_at are untouched; only the status, the
  /// server's reason and the quarantine timestamp are added. These rows are
  /// never auto-retried and never pruned — only [retryQuarantined] or
  /// [discardQuarantined] (both deliberate operator actions) touch them.
  @override
  Future<void> markQuarantined(Map<String, String> rejections) async {
    if (rejections.isEmpty) return;
    final now = DateTime.now().toIso8601String();
    await _db.transaction((txn) async {
      for (final entry in rejections.entries) {
        await txn.update(
          'sync_outbox',
          {
            'status': 'quarantined',
            'last_error': entry.value,
            'quarantined_at': now,
          },
          where: "id = ? AND synced_at IS NULL",
          whereArgs: [entry.key],
        );
      }
    });
  }

  @override
  Future<List<SyncOutboxEntry>> quarantined({int limit = 200}) async {
    final rows = await _db.query(
      'sync_outbox',
      where: "status = 'quarantined' AND synced_at IS NULL",
      orderBy: 'quarantined_at ASC, created_at ASC',
      limit: limit,
    );
    return rows.map(SyncOutboxEntry.fromMap).toList();
  }

  @override
  Future<int> quarantinedCount() async {
    final rows = await _db.rawQuery(
      "SELECT COUNT(*) AS count FROM sync_outbox "
      "WHERE status = 'quarantined' AND synced_at IS NULL",
    );
    return rows.first['count'] as int;
  }

  @override
  Future<void> retryQuarantined(List<String> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.update(
      'sync_outbox',
      {'status': 'pending', 'last_error': null, 'quarantined_at': null},
      where: "id IN ($placeholders) AND status = 'quarantined'",
      whereArgs: ids,
    );
  }

  @override
  Future<int> discardQuarantined(List<String> ids) async {
    if (ids.isEmpty) return 0;
    final placeholders = List.filled(ids.length, '?').join(',');
    return _db.delete(
      'sync_outbox',
      where: "id IN ($placeholders) AND status = 'quarantined'",
      whereArgs: ids,
    );
  }

  /// Removes already-synced rows to keep the queue from growing forever.
  /// Only ever deletes rows with a non-null synced_at — quarantined financial
  /// records are durable and survive every prune.
  @override
  Future<int> pruneSynced() async {
    return _db.delete('sync_outbox', where: 'synced_at IS NOT NULL');
  }
}
