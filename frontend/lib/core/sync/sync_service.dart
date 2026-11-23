import 'package:flutter/foundation.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';

import 'sync_status.dart';

/// The one place the sync engine's cadence is written down.
///
/// A flat 3-second loop pulls nine cloud tables every three seconds, which is
/// 28,800 pulls a day per till — on a shop with three registers and a phone
/// that is ~90k requests a day to move nothing at all overnight, and it is the
/// battery drain that makes a cashier turn sync off. So the cadence is
/// adaptive: [cycle] is the floor a busy till runs at, and an idle one climbs
/// [backoffRungs] instead, to [max] at worst.
///
/// The number that must NOT grow is the one the operator feels. A sale they
/// just rang has to leave the till immediately ([SyncService.notifyLocalActivity]
/// wakes the loop), and a row from another register has to land inside a
/// blink — so the fast floor is held for [boost] after any activity.
abstract final class SyncIntervals {
  /// The floor, and the interval a boosted (recently active) till keeps.
  static const Duration cycle = Duration(seconds: 3);

  /// How long a cycle that moved anything holds the floor, so a shop in the
  /// middle of trading stays instant instead of climbing after every sale.
  static const Duration boost = Duration(seconds: 30);

  /// The ceiling. Even a till that has seen nothing for hours retries twice a
  /// minute, which is invisible on battery and still catches the network
  /// coming back.
  static const Duration max = Duration(seconds: 60);

  /// The rungs above [cycle] an idle cycle climbs, one per idle cycle. Three
  /// quiet cycles take a till from the floor to a minute.
  static const List<Duration> backoffRungs = <Duration>[
    Duration(seconds: 10),
    Duration(seconds: 30),
    max,
  ];

  /// How soon a woken loop drains after a local write.
  ///
  /// Not zero: one sale writes a sale row, its line items and sometimes a
  /// movement, and a short settle lets a single request carry all of them
  /// instead of firing one per write.
  static const Duration wake = Duration(milliseconds: 250);
}

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

  /// How often the download half is allowed to run, and the floor of the
  /// adaptive cadence ([nextDelay] never goes below it).
  ///
  /// Pushing is cheap and event-driven (one call, only when the outbox holds
  /// rows); pulling costs one request per cloud table, so it follows the
  /// adaptive interval rather than a fixed one: sign-in still forces it
  /// ([syncNow] with `forcePull`), which is the moment the operator actually
  /// expects the whole shop's history.
  final Duration pullInterval;

  /// Injected clock. Only the boost window needs it, and a test that has to
  /// prove a 30-second window expires cannot wait 30 seconds for it.
  final DateTime Function() _now;

  /// Live view of the loop, for the UI. A [ValueNotifier] so a settings screen
  /// can rebuild without polling.
  final ValueNotifier<SyncStatus> status;

  DateTime? _lastPull;

  /// Which rung of [SyncIntervals.backoffRungs] an idle cycle sits on. 0 means
  /// the floor, and it is both the fresh state and the state after activity.
  /// Never climbs past the last rung.
  int _rung = 0;

  /// Until when [_rung] is pinned to 0, set by any cycle that moved data or any
  /// local write. Null means never.
  DateTime? _boostUntil;

  /// Set by the drain loop in `main.dart` so this class can wake it up without
  /// owning a `Timer` (and without the engine importing the UI layer).
  void Function()? _wake;

  /// The last error text written to the log, so a network that stays down for
  /// an hour produces one line about it and not two thousand.
  String? _lastLoggedError;

  /// True while a recently-active till should keep the floor interval.
  bool get _isBoosted {
    final until = _boostUntil;
    return until != null && _now().isBefore(until);
  }

  /// How long the caller's loop should wait before its next drain.
  ///
  /// The engine decides the cadence; the loop only obeys. That split is what
  /// makes it testable without a fake async clock and what lets a sign-in, a
  /// manual "sync now" and a sale all consult one answer.
  Duration get nextDelay {
    if (_isBoosted || _rung == 0) return pullInterval;
    final index = _rung - 1;
    return SyncIntervals.backoffRungs[index.clamp(
      0,
      SyncIntervals.backoffRungs.length - 1,
    )];
  }

  /// Called by the drain loop so a local write can shorten the wait to the next
  /// cycle. Re-assigning it is how the loop hands itself over at start-up; it is
  /// never read for anything but calling.
  set onWake(void Function()? callback) => _wake = callback;

  /// A local write (a sale, a shift open, a cash movement) just queued rows.
  ///
  /// This is the event the operator is waiting for, so the loop comes back to
  /// the floor interval and is prodded immediately instead of whenever the
  /// current rung happens to fire — the difference between "synced in 3s" and
  /// "synced within a minute" on a till that has been quiet all morning.
  void notifyLocalActivity() {
    _rung = 0;
    _boostUntil = _now().add(SyncIntervals.boost);
    _wake?.call();
  }

  /// Single-flight guard (audit #11). The timer, a wake fired by
  /// [notifyLocalActivity], sign-in and the manual "sync now" in Settings can
  /// all request a drain at once; two overlapping drains would send the same
  /// rows in unpredictable order and re-introduce the out-of-order overwrite
  /// the outbox's ASC ordering exists to prevent. While one drain is running,
  /// concurrent calls return idle — the still-queued rows are picked up by the
  /// very next trigger.
  ///
  /// The guard is what makes a [SyncIntervals.cycle]-short floor safe. A full
  /// cycle is a push, a pull of every cloud table and the writes they cause, so
  /// it can outlast three seconds on a slow connection — and the wake hook in
  /// [notifyLocalActivity] now deliberately fires cycles closer together than
  /// the interval ever did. Concurrent writers inside one `db.transaction` fail
  /// with locking errors, and the second one would re-send rows the first had
  /// already queued but not yet acked; both are prevented here.
  bool _inFlight = false;

  SyncService(
    this._outbox,
    this._backend, {
    this.puller,
    this.pullInterval = SyncIntervals.cycle,
    @visibleForTesting DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       status = ValueNotifier(SyncStatus(configured: _backend.isConfigured));

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
      _recordCadence(pushed: pushed, applied: applied, error: message);
      status.value = SyncStatus(
        configured: true,
        lastSuccess: message == null ? _now() : status.value.lastSuccess,
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

  /// Feeds the adaptive interval and the log file from one cycle's outcome.
  ///
  /// "Moved something" means pushed or applied, and nothing else. A cycle that
  /// queued nothing and downloaded nothing is a till at an empty shop, and the
  /// only thing worth doing about it is asking less often.
  ///
  /// A FAILED cycle counts as idle on purpose. A network that is down does not
  /// get better because this till asked every three seconds — that behaviour is
  /// the quota burn this fix exists to stop — and nothing is lost by waiting,
  /// because the outbox still holds every row and the first success snaps back
  /// to the floor and drains the backlog at full speed.
  void _recordCadence({
    required int pushed,
    required int applied,
    String? error,
  }) {
    if (pushed > 0 || applied > 0) {
      _rung = 0;
      _boostUntil = _now().add(SyncIntervals.boost);
    } else if (!_isBoosted && _rung < SyncIntervals.backoffRungs.length) {
      _rung++;
    }

    if (error == null) {
      if (_lastLoggedError != null) {
        AppLogger.info('Sync recovered after: $_lastLoggedError');
        _lastLoggedError = null;
      }
      return;
    }
    // One line per distinct failure. Without this an offline till on the floor
    // interval writes the same stack every three seconds and buries the one
    // message that mattered underneath it.
    if (error == _lastLoggedError) return;
    _lastLoggedError = error;
    AppLogger.warn('Sync cycle failed: $error');
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
    // Throttle on the live cadence, not the floor: a manual "sync now" that is
    // not a forcePull must not defeat the backoff the loop just earned.
    if (!force && last != null && _now().difference(last) < nextDelay) {
      return 0;
    }
    final report = await puller.pullNow();
    _lastPull = _now();
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
