import 'cloud_read_convergence.dart';
import 'sync_outbox_entry.dart';

/// Milestone 5 native read-convergence *policy*.
///
/// [CloudReadConvergence] merges the authoritative `pos-api` rows with this
/// device's still-pending outbox so the phone shows the same live numbers the
/// web shows. But the plan's hard constraint is that **native must stay an
/// offline till**: making it strictly-online was explicitly rejected because a
/// till with no signal has to keep selling. This class is the piece that
/// reconciles those two demands for a single read:
///
///   * **Online** — delegate to [CloudReadConvergence]: committed cloud data
///     wins on read, the cashier's own un-acked local writes stay surfaced.
///   * **Cloud unreachable** — fall back to the local SQLite cache (the offline
///     write-cache is already the till's own truth and contains the pending
///     writes), so the screen renders instead of erroring.
///   * **Cloud reachable but refusing** (e.g. an expired session) — by default
///     this is *not* masked as "offline"; the caller supplies
///     [shouldFallbackOnError] to decide. Returning `false` rethrows so the shell
///     can prompt a re-login rather than quietly show stale rows forever.
///
/// Like [CloudReadConvergence] it stays dependency-free over SQL/HTTP: every
/// source is an injected async thunk, so the policy is unit-tested with in-memory
/// fakes and a deliberately-throwing cloud fetch (no live `pos-api` needed).
class NativeReadConvergence {
  /// The online merge this policy delegates to when the cloud answers.
  final CloudReadConvergence _online;

  /// Reads this device's local SQLite rows — the offline-authoritative source.
  final Future<List<Map<String, dynamic>>> Function() fetchLocalCache;

  /// Decides whether a cloud error means "unreachable → serve the local cache"
  /// or "a real refusal → surface it". Defaults to treating every error as
  /// offline (the safe, always-sells behavior); wiring can pass a
  /// connectivity- or status-aware predicate.
  final bool Function(Object error) shouldFallbackOnError;

  /// Optional observability hook fired when a read degrades to the local cache,
  /// so the UI can show an "offline" indicator without changing the result.
  final void Function(Object error)? onFallback;

  NativeReadConvergence({
    required String entityType,
    required Future<List<Map<String, dynamic>>> Function() fetchCloudRows,
    required Future<List<SyncOutboxEntry>> Function() fetchPendingOutbox,
    required String Function(Map<String, dynamic> row) idOf,
    required this.fetchLocalCache,
    bool Function(Object error)? shouldFallbackOnError,
    this.onFallback,
  }) : _online = CloudReadConvergence(
         entityType: entityType,
         fetchCloudRows: fetchCloudRows,
         fetchPendingOutbox: fetchPendingOutbox,
         idOf: idOf,
       ),
       shouldFallbackOnError = shouldFallbackOnError ?? ((_) => true);

  /// Runs one converged read: cloud-authoritative + pending-outbox when online,
  /// local cache when the cloud is unreachable, rethrown refusal otherwise.
  Future<List<Map<String, dynamic>>> read() async {
    try {
      return await _online.read();
    } catch (error) {
      if (!shouldFallbackOnError(error)) rethrow;
      onFallback?.call(error);
      return fetchLocalCache();
    }
  }
}
