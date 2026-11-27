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

  /// Marks entries as pushed. Done only after the backend confirmed the
  /// server applied them — never for deferred, retryable, or rejected rows.
  Future<void> markSynced(List<String> ids);

  /// Moves permanently refused entries into durable quarantine: the row keeps
  /// its original payload, entity identity and timestamps, gains the server's
  /// rejection reason, and leaves the pending queue so it is never retried
  /// automatically and never pruned. [rejections] maps outbox id -> reason.
  Future<void> markQuarantined(Map<String, String> rejections);

  /// Quarantined entries, oldest first — the operator's recovery view.
  Future<List<SyncOutboxEntry>> quarantined({int limit = 200});

  /// Number of entries held in quarantine.
  Future<int> quarantinedCount();

  /// Operator action: returns quarantined entries to the pending queue so the
  /// next drain re-sends them (e.g. after the cause was fixed).
  Future<void> retryQuarantined(List<String> ids);

  /// Operator action: permanently discards quarantined entries. This is the
  /// ONLY way a quarantined row leaves the store — deliberate, never automatic.
  Future<int> discardQuarantined(List<String> ids);

  /// Removes already-synced rows, returning how many were deleted. Only ever
  /// deletes rows with a non-null synced_at; quarantined rows are untouched.
  Future<int> pruneSynced();
}
