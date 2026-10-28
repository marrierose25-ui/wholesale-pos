import 'sync_backend.dart';
import 'sync_outbox_repository.dart';
import 'sync_pull_applier.dart';

/// Outcome of one drain attempt.
class SyncResult {
  final int pushed;
  final int remaining;
  final bool skipped; // true when no backend is configured

  /// Rows written into SQLite by the download half of this cycle. Non-zero
  /// means this device learned about transactions another till recorded.
  final int applied;

  const SyncResult({
    required this.pushed,
    required this.remaining,
    this.skipped = false,
    this.applied = 0,
  });

  factory SyncResult.idle() => const SyncResult(pushed: 0, remaining: 0);
  factory SyncResult.noBackend() =>
      const SyncResult(pushed: 0, remaining: 0, skipped: true);
}

/// Drains the outbox to a [SyncBackend], then pulls back everything the shop
/// recorded elsewhere. Offline-first by construction: if the backend is missing
/// or throws, nothing is lost — the rows stay queued and the next attempt (a
/// timer, app resume, or after a sale) retries.
class SyncService {
  final SyncOutboxRepository _outbox;
  final SyncBackend _backend;

  /// Null when the build has no gateway (offline-only release, or the legacy
  /// PostgREST sink which is write-only). Push still runs; nothing is pulled.
  final CloudSyncPuller? puller;

  /// How often the download half is allowed to run.
  ///
  /// Pushing is cheap and event-driven (one call, only when the outbox holds
  /// rows); pulling costs one request per cloud table, so it runs on a slower
  /// cadence. Every sign-in forces it ([syncNow] with `forcePull`), which is the
  /// moment the operator actually expects the whole shop's history.
  final Duration pullInterval;

  DateTime? _lastPull;

  /// Single-flight guard (audit #11). A periodic timer, app-resume and the
  /// post-sale trigger can all request a drain at once; two overlapping drains
  /// would send the same rows in unpredictable order and re-introduce the
  /// out-of-order overwrite the outbox's ASC ordering exists to prevent. While
  /// one drain is running, concurrent calls return idle — the still-queued rows
  /// are picked up by the very next trigger.
  bool _inFlight = false;

  SyncService(
    this._outbox,
    this._backend, {
    this.puller,
    this.pullInterval = const Duration(minutes: 2),
  });

  Future<SyncResult> syncNow({
    int batchLimit = 200,
    bool forcePull = false,
  }) async {
    if (!_backend.isConfigured) return SyncResult.noBackend();
    if (_inFlight) return SyncResult.idle();
    _inFlight = true;
    try {
      final result = await _push(batchLimit);
      final applied = await _pull(force: forcePull);
      return SyncResult(
        pushed: result.$1,
        remaining: result.$2,
        applied: applied,
      );
    } finally {
      _inFlight = false;
    }
  }

  /// Returns `(pushed, stillQueued)`.
  Future<(int, int)> _push(int batchLimit) async {
    final pending = await _outbox.pending(limit: batchLimit);
    // Nothing to send is the normal steady state now: it must NOT end the
    // cycle, because the pull still has to run (audit: an early return here is
    // why a second device never saw the first one's sales).
    if (pending.isEmpty) {
      return (0, await _outbox.pendingCount());
    }

    final Set<String> acked;
    try {
      acked = await _backend.push(pending);
    } catch (_) {
      // Network / backend error: leave everything queued and try later.
      return (0, pending.length);
    }

    // Mark synced only what the server confirmed; a partially-acked batch
    // leaves its retryable rows queued (audit #20).
    await _outbox.markSynced(acked.toList());
    return (acked.length, await _outbox.pendingCount());
  }

  /// Applies every cloud page this device has not seen yet. Returns the number
  /// of rows written locally.
  ///
  /// Runs after the push so this till's own sales are already server-side and
  /// the page it reads back includes them — applying a row that is already here
  /// is a no-op, so the order is safe either way. A failure is swallowed: the
  /// stored cursor is untouched, so the next tick resumes from the same page.
  Future<int> _pull({bool force = false}) async {
    final puller = this.puller;
    if (puller == null) return 0;
    final last = _lastPull;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < pullInterval) {
      return 0;
    }
    try {
      final report = await puller.pullNow();
      _lastPull = DateTime.now();
      return report.inserted;
    } catch (_) {
      return 0;
    }
  }
}
