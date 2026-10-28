import 'package:flutter/foundation.dart';

import 'sync_backend.dart';
import 'sync_outbox_repository.dart';
import 'sync_pull_applier.dart';
import 'sync_status.dart';

/// Outcome of one drain attempt.
class SyncResult {
  final int pushed;
  final int remaining;
  final bool skipped; // true when no backend is configured

  /// Rows written into SQLite by the download half of this cycle. Non-zero
  /// means this device learned about transactions another till recorded.
  final int applied;

  /// Why this cycle failed, or null when it completed. Carried on the result as
  /// well as the [SyncService.status] notifier so a caller that awaits the cycle
  /// (sign-in, a manual "sync now") can report it immediately.
  final String? error;

  const SyncResult({
    required this.pushed,
    required this.remaining,
    this.skipped = false,
    this.applied = 0,
    this.error,
  });

  factory SyncResult.idle() => const SyncResult(pushed: 0, remaining: 0);
  factory SyncResult.noBackend() =>
      const SyncResult(pushed: 0, remaining: 0, skipped: true);

  bool get ok => error == null;
}

/// Drains the outbox to a [SyncBackend], then pulls back everything the shop
/// recorded elsewhere. Offline-first by construction: if the backend is missing
/// or throws, nothing is lost — the rows stay queued and the next attempt (a
/// timer, app resume, or after a sale) retries.
///
/// Every cycle ends by publishing a [SyncStatus]; nothing that stops syncing
/// stays silent. A refused licence in particular cannot be retried away, so it
/// has to reach the operator (see `SyncStatus.authenticationFailed`).
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

  /// Live view of the loop, for the UI. A [ValueNotifier] so a settings screen
  /// can rebuild without polling.
  final ValueNotifier<SyncStatus> status;

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
  }) : status = ValueNotifier(SyncStatus(configured: _backend.isConfigured));

  Future<SyncResult> syncNow({
    int batchLimit = 200,
    bool forcePull = false,
  }) async {
    if (!_backend.isConfigured) {
      status.value = SyncStatus.disabled;
      return SyncResult.noBackend();
    }
    if (_inFlight) return SyncResult.idle();
    _inFlight = true;

    var pushed = 0;
    var remaining = 0;
    var applied = 0;
    Object? failure;
    try {
      try {
        final result = await _push(batchLimit);
        pushed = result.$1;
        remaining = result.$2;
      } catch (error) {
        failure = error;
        remaining = await _queuedSafely();
      }
      try {
        applied = await _pull(force: forcePull);
      } catch (error) {
        failure ??= error;
      }
    } finally {
      _inFlight = false;
      final message = failure == null ? null : _describe(failure);
      status.value = SyncStatus(
        configured: true,
        lastSuccess: message == null
            ? DateTime.now()
            : status.value.lastSuccess,
        error: message,
        authenticationFailed: failure is SyncAuthException,
        applied: applied,
        queued: remaining,
      );
    }

    return SyncResult(
      pushed: pushed,
      remaining: remaining,
      applied: applied,
      error: status.value.error,
    );
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

    // A backend failure propagates: everything stays queued, and [syncNow]
    // records why so the operator is not left guessing.
    final Set<String> acked = await _backend.push(pending);

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
  /// is a no-op, so the order is safe either way. A failure propagates to
  /// [syncNow]: the stored cursor is untouched either way, so the next tick
  /// resumes from the same page.
  Future<int> _pull({bool force = false}) async {
    final puller = this.puller;
    if (puller == null) return 0;
    final last = _lastPull;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < pullInterval) {
      return 0;
    }
    final report = await puller.pullNow();
    _lastPull = DateTime.now();
    return report.inserted;
  }

  Future<int> _queuedSafely() async {
    try {
      return await _outbox.pendingCount();
    } catch (_) {
      return 0;
    }
  }

  /// Operator-facing wording: drop Dart's `Exception: ` prefix so a snackbar or
  /// a settings row reads like a sentence.
  static String _describe(Object error) {
    final text = error.toString();
    const prefix = 'Exception: ';
    return text.startsWith(prefix) ? text.substring(prefix.length) : text;
  }
}
