import 'cloud_read_reconciler.dart';
import 'sync_outbox_entry.dart';

/// Milestone 5 native read-convergence adapter.
///
/// [CloudReadReconciler] holds only the *merge decision*; something still has to
/// hand it the two live inputs for a given entity type:
///
///   * the authoritative cloud rows, fetched from `pos-api` (a
///     [CloudApiClient.call] whose decoded body is mapped to id-keyed rows), and
///   * this device's still-PENDING outbox entries
///     (`SyncOutboxRepository.pending()`, newest-intent wins inside the merge).
///
/// This class wires exactly those two sources for one entity type and runs the
/// merge, so a converged native read shows the same live numbers the web shows
/// while a cashier's own just-entered, not-yet-acked writes stay visible.
///
/// It is deliberately dependency-free over SQL/HTTP: each source is supplied as
/// an async thunk, so the same adapter serves sales / shifts / cash movements /
/// void requests, keeps web + native on one code path, and is trivially unit-
/// tested with in-memory fakes (no live `pos-api` required to prove the merge).
class CloudReadConvergence {
  /// Which outbox entity type this adapter reconciles (see [SyncEntities]).
  final String entityType;

  /// Fetches the authoritative cloud rows for this entity, as id-keyed maps.
  final Future<List<Map<String, dynamic>>> Function() fetchCloudRows;

  /// Fetches this device's PENDING outbox entries (un-acked local writes).
  final Future<List<SyncOutboxEntry>> Function() fetchPendingOutbox;

  /// Extracts the entity id from a cloud row — the same id the outbox stamped in
  /// [SyncOutboxEntry.entityId].
  final String Function(Map<String, dynamic> row) idOf;

  const CloudReadConvergence({
    required this.entityType,
    required this.fetchCloudRows,
    required this.fetchPendingOutbox,
    required this.idOf,
  });

  /// Reads both sources concurrently, then reconciles. The cloud fetch and the
  /// (local, synchronous-in-practice) outbox fetch are independent, so starting
  /// them before awaiting overlaps their latency.
  Future<List<Map<String, dynamic>>> read() async {
    final cloudRowsFuture = fetchCloudRows();
    final outboxFuture = fetchPendingOutbox();
    final cloudRows = await cloudRowsFuture;
    final outbox = await outboxFuture;
    return CloudReadReconciler.reconcile(
      entityType: entityType,
      cloudRows: cloudRows,
      outbox: outbox,
      idOf: idOf,
    );
  }
}
