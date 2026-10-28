import 'sync_backend.dart';
import 'sync_outbox_repository.dart';

/// Outcome of one drain attempt.
class SyncResult {
  final int pushed;
  final int remaining;
  final bool skipped; // true when no backend is configured

  const SyncResult({
    required this.pushed,
    required this.remaining,
    this.skipped = false,
  });

  factory SyncResult.idle() => const SyncResult(pushed: 0, remaining: 0);
  factory SyncResult.noBackend() =>
      const SyncResult(pushed: 0, remaining: 0, skipped: true);
}

/// Drains the outbox to a [SyncBackend]. Offline-first by construction: if the
/// backend is missing or throws, nothing is lost — the rows stay queued and the
/// next attempt (a timer, app resume, or after a sale) retries.
class SyncService {
  final SyncOutboxRepository _outbox;
  final SyncBackend _backend;

  /// Single-flight guard (audit #11). A periodic timer, app-resume and the
  /// post-sale trigger can all request a drain at once; two overlapping drains
  /// would send the same rows in unpredictable order and re-introduce the
  /// out-of-order overwrite the outbox's ASC ordering exists to prevent. While
  /// one drain is running, concurrent calls return idle — the still-queued rows
  /// are picked up by the very next trigger.
  bool _inFlight = false;

  SyncService(this._outbox, this._backend);

  Future<SyncResult> syncNow({int batchLimit = 200}) async {
    if (!_backend.isConfigured) return SyncResult.noBackend();
    if (_inFlight) return SyncResult.idle();
    _inFlight = true;
    try {
      final pending = await _outbox.pending(limit: batchLimit);
      if (pending.isEmpty) return SyncResult.idle();

      final Set<String> acked;
      try {
        acked = await _backend.push(pending);
      } catch (_) {
        // Network / backend error: leave everything queued and try later.
        return SyncResult(pushed: 0, remaining: pending.length);
      }

      // Mark synced only what the server confirmed; a partially-acked batch
      // leaves its retryable rows queued (audit #20).
      await _outbox.markSynced(acked.toList());
      final remaining = await _outbox.pendingCount();
      return SyncResult(pushed: acked.length, remaining: remaining);
    } finally {
      _inFlight = false;
    }
  }
}
