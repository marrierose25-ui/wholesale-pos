import 'sync_outbox_entry.dart';

/// One page of cloud-side changes plus the keyset to resume from.
///
/// [changes] is keyed by CLOUD table name (`sales`, `sale_items`, `shifts`,
/// `cash_movements`, `void_requests`, `users`) and holds rows exactly as the
/// server returned them. Nothing is applied here — [SyncPullApplier] decides
/// what lands in SQLite.
class SyncPullResult {
  final Map<String, List<Map<String, dynamic>>> changes;

  /// `{received_at, id}` of the last row in this page, or null when empty.
  /// Passed back verbatim on the next call.
  final Map<String, String>? nextCursor;

  /// True when the server held back rows, so the caller should page again.
  final bool hasMore;

  const SyncPullResult({
    required this.changes,
    this.nextCursor,
    this.hasMore = false,
  });

  const SyncPullResult.empty()
    : changes = const {},
      nextCursor = null,
      hasMore = false;

  int get rowCount =>
      changes.values.fold(0, (total, rows) => total + rows.length);

  bool get isEmpty => rowCount == 0;
}

/// Seam between the offline POS and whatever remote store is used later
/// (Supabase/PostgREST, a REST API, etc.). The app never talks to the network
/// directly — it hands batches of queued changes to a [SyncBackend].
///
/// Implementations must be idempotent: the same entry may be pushed more than
/// once (e.g. after a crash between a successful push and marking it synced), so
/// the backend should upsert by [SyncOutboxEntry.entityId].
///
/// [pull] is the other half: without it a till can only send, so a second
/// device never learns about the first one's transactions.
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

  /// Fetches cloud changes recorded after [cursor].
  ///
  /// A null cursor asks for the tenant's history from the beginning, which is
  /// what a device does on its first sync. Throw on a transport or auth
  /// failure — the caller keeps its cursor and retries, so a pull can never
  /// lose rows or apply a partial page out of order.
  ///
  /// [tables] narrows the page to specific cloud tables. Callers page one table
  /// at a time on purpose: a keyset cursor is only ordered within one table, so
  /// a mixed page would let a fast-moving table drag the cursor past rows a
  /// slower one has not delivered yet.
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  });
}

/// The cloud refused this device's licence — as opposed to being unreachable.
///
/// The distinction is the whole difference between "offline, keep selling" and
/// "this till will never sync until it is activated": the first fixes itself on
/// the next tick, the second needs the operator to paste the shop's activation
/// code. A pre-Phase-17 `license.key` validates locally but carries no tenant,
/// so the gateway answers 401 for it and sync would otherwise fail silently.
class SyncAuthException implements Exception {
  final String message;

  const SyncAuthException(this.message);

  @override
  String toString() => message;
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

  @override
  Future<SyncPullResult> pull({
    Map<String, String>? cursor,
    int limit = 1000,
    List<String>? tables,
  }) async => const SyncPullResult.empty();
}
