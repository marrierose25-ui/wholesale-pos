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

  SyncService(this._outbox, this._backend);

  Future<SyncResult> syncNow({int batchLimit = 200}) async {
    if (!_backend.isConfigured) return SyncResult.noBackend();

    final pending = await _outbox.pending(limit: batchLimit);
    if (pending.isEmpty) return SyncResult.idle();

    try {
      await _backend.push(pending);
    } catch (_) {
      // Network / backend error: leave everything queued and try later.
      return SyncResult(pushed: 0, remaining: pending.length);
    }

    await _outbox.markSynced(pending.map((e) => e.id).toList());
    final remaining = await _outbox.pendingCount();
    return SyncResult(pushed: pending.length, remaining: remaining);
  }
}
