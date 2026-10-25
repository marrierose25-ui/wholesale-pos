import 'sync_outbox_entry.dart';

/// Milestone 5 read-convergence primitive.
///
/// Once the native app points its READS at `pos-api` (while keeping SQLite as
/// the offline write-cache + the existing outbox push), a screen must show the
/// same live numbers the web shows — but the cloud lags a device by whatever is
/// still queued in that device's outbox. [reconcile] closes exactly that gap:
///
///   * rows the cloud has already acked win (they are the shared truth), and
///   * a LOCAL write whose outbox entry is still PENDING (`syncedAt == null`)
///     is surfaced over the cloud copy until the worker gets it acked, so a
///     cashier never sees their own just-entered sale "disappear."
///
/// The algorithm is intentionally generic: it works on any id-keyed row maps so
/// one primitive serves sales, shifts, cash movements and void requests alike.
/// A repository adapts its typed models to id-keyed maps, calls [reconcile],
/// and rehydrates — this file holds only the merge decision, no SQL/HTTP, so it
/// runs unchanged on native, web and in unit tests.
class CloudReadReconciler {
  const CloudReadReconciler._();

  /// Merges authoritative [cloudRows] with this device's [outbox] entries for
  /// [entityType].
  ///
  /// [idOf] extracts a row's entity id from a cloud row (the same id the outbox
  /// stamped in [SyncOutboxEntry.entityId]). Returned rows keep the cloud's
  /// original order, with pending-local upserts substituted in place and any
  /// cloud-absent pending upsert (a brand-new, not-yet-synced row) appended.
  ///
  /// Rules, in order of application:
  ///   1. Acked entries (`isSynced`) are ignored — the cloud already reflects
  ///      them, so the cloud row is authoritative.
  ///   2. Among PENDING entries for the same entity, only the newest
  ///      (`createdAt`) is kept — it is the latest local intent.
  ///   3. A pending `DELETE` removes the row (locally deleted, not yet acked).
  ///   4. A pending `UPSERT` replaces the cloud row with its local [payload],
  ///      or adds it when the cloud does not have it yet.
  static List<Map<String, dynamic>> reconcile({
    required String entityType,
    required List<Map<String, dynamic>> cloudRows,
    required List<SyncOutboxEntry> outbox,
    required String Function(Map<String, dynamic> row) idOf,
  }) {
    // 1 + 2: newest pending entry per entity id, for this type only.
    final pendingById = <String, SyncOutboxEntry>{};
    for (final entry in outbox) {
      if (entry.entityType != entityType) continue;
      if (entry.isSynced) continue; // acked → cloud wins.
      final existing = pendingById[entry.entityId];
      if (existing == null || entry.createdAt.isAfter(existing.createdAt)) {
        pendingById[entry.entityId] = entry;
      }
    }

    // Nothing pending for this type → the cloud result stands completely
    // untouched (no rebuild, no reordering, same list identity).
    if (pendingById.isEmpty) return cloudRows;

    final result = <Map<String, dynamic>>[];
    final consumed = <String>{};

    // 3 + 4 over the cloud rows, preserving their order.
    for (final row in cloudRows) {
      final id = idOf(row);
      consumed.add(id);
      final pending = pendingById[id];
      if (pending == null) {
        result.add(row); // no local pending → cloud truth stands.
        continue;
      }
      if (pending.operation == SyncOperations.delete) {
        continue; // dropped: deleted locally, pending ack.
      }
      result.add(
        pending.payload,
      ); // local pending upsert shadows the cloud row.
    }

    // 4 (cont): pending upserts for entities the cloud has not received yet.
    for (final entry in pendingById.values) {
      if (consumed.contains(entry.entityId)) continue;
      if (entry.operation == SyncOperations.delete) continue;
      result.add(entry.payload);
    }

    return result;
  }
}
