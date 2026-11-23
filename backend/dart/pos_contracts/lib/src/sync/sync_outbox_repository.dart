import 'sync_outbox_entry.dart';

/// Persistence and lifecycle for the local sync outbox.
///
/// Enqueuing lives in the SQLite implementation (`SyncOutbox`), called inside
/// business transactions; this contract only covers draining the queue.
abstract class SyncOutboxRepository {
  /// Oldest unsynced entries first, so the cloud sees events in order.
  Future<List<SyncOutboxEntry>> pending({int limit = 200});

  /// Number of entries still waiting to be pushed.
  Future<int> pendingCount();

  /// Marks entries as pushed. Done only after the backend accepted them.
  Future<void> markSynced(List<String> ids);

  /// Removes already-synced rows, returning how many were deleted.
  Future<int> pruneSynced();
}
