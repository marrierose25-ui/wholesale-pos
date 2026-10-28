import 'sync_outbox_entry.dart';

/// Seam between the offline POS and whatever remote store is used later
/// (Supabase/PostgREST, a REST API, etc.). The app never talks to the network
/// directly — it hands batches of queued changes to a [SyncBackend].
///
/// Implementations must be idempotent: the same entry may be pushed more than
/// once (e.g. after a crash between a successful push and marking it synced),
/// so the backend should upsert by [SyncOutboxEntry.entityId].
abstract class SyncBackend {
  /// True when a remote target is configured and reachable enough to try.
  bool get isConfigured;

  /// Pushes a batch of queued changes. Throw on any wholesale failure; the
  /// caller leaves every row in the outbox and retries later.
  ///
  /// On partial success (some entries applied, some rejected/transient) return
  /// the set of OUTBOX row ids ([SyncOutboxEntry.id]) the server confirmed —
  /// either applied or permanently rejected — so exactly those are marked
  /// synced and only the genuinely retryable ones stay queued (audit #20).
  /// Back-ends that cannot report per-entry outcomes return every id (the
  /// pre-existing "ack the whole batch" behaviour).
  Future<Set<String>> push(List<SyncOutboxEntry> entries);
}

/// Default backend used while the app is still purely offline (and in tests).
/// It accepts nothing and throws nothing: rows simply stay queued, so wiring a
/// real backend later is a drop-in replacement with no other code changes.
class NoopSyncBackend implements SyncBackend {
  const NoopSyncBackend();

  @override
  bool get isConfigured => false;

  @override
  Future<Set<String>> push(List<SyncOutboxEntry> entries) async {
    // Intentionally does nothing. The outbox retains every row.
    return const {};
  }
}
