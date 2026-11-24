import 'dart:convert';

import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Outcome of one reconciliation pass over [PendingOwnerActions].
class OwnerActionReconcileResult {
  /// Entries the server confirmed this pass (already removed locally).
  final int confirmed;

  /// Entries still awaiting authorization (kept in the pending store).
  final int stillPending;

  /// pos-api refused the owner's credentials — nothing was attempted.
  final bool authFailed;

  /// Entries whose authoritative cloud state conflicts with the local
  /// intent (e.g. a different owner already decided differently). These are
  /// kept pending for operator resolution — never silently overwritten.
  final int conflicts;

  /// First server/client error encountered, safe to show the operator.
  final String? error;

  const OwnerActionReconcileResult({
    required this.confirmed,
    required this.stillPending,
    this.authFailed = false,
    this.conflicts = 0,
    this.error,
  });
}

/// Releases locally-recorded owner transitions (offline voids / void-request
/// decisions) through the authenticated `pos-api` surface.
///
/// Stage 4.1 / audit H1: the sync gateway stages DATA only — it can no longer
/// turn a pushed `VOIDED`/`APPROVED`/`REJECTED` payload into an authoritative
/// transition, because a license proves the device, not which user acted.
/// Stage 4.1.1 hardens the release path:
///
///   * **Prerequisite ordering** — an action is only attempted after its
///     target is verified present in the cloud (a staged-but-unapplied sync
///     row does not count). If the target has not landed yet, the entry
///     stays pending and is retried on the next pass. After a JSON restore
///     the outbox rows are gone, so the prerequisite sync event is re-queued
///     from the local row before the check.
///   * **Idempotent retries** — if the transition committed but the response
///     was lost, the next attempt sees a conflict. Instead of trusting the
///     error, the reconciler reads the authoritative state through pos-api
///     and confirms the entry only when it matches the exact intended
///     action AND actor. A conflicting decision by anyone stays pending.
///
/// The owner re-authenticates with their pos-api (cloud) credentials — the
/// same phone + password the web/PWA uses, NOT necessarily the local till
/// password. [CloudApiClient] holds the returned JWT in memory only; the
/// pending record's `localUserId` is audit context and is never sent as
/// proof of identity.
class OwnerActionReconciler {
  final Database db;
  final CloudApiClient api;

  /// The shop's activation code — the tenant identity `pos-api` resolves at
  /// login. Read from the same `settings` key [DeviceActivation] writes.
  final String activationCode;

  /// The verified pos-api user id from the login response — used ONLY to
  /// confirm that an already-applied transition was made by this same
  /// owner, never sent to the server as authorization.
  String? _authedUserId;

  OwnerActionReconciler({
    required this.db,
    required this.api,
    required this.activationCode,
  });

  /// True when there is queued owner work AND this build can reach pos-api.
  Future<bool> hasPending() async {
    if (!api.isConfigured || activationCode.isEmpty) return false;
    return (await PendingOwnerActions.load(db)).isNotEmpty;
  }

  /// Number of unresolved pending actions (for UI indicators).
  Future<int> pendingCount() async =>
      (await PendingOwnerActions.load(db)).length;

  /// Attempts every pending action in order. Stops at the first hard
  /// failure (bad credentials, owner-required refusal, network) so a refused
  /// session cannot partially drain the queue; entries already confirmed
  /// are still removed.
  Future<OwnerActionReconcileResult> reconcile({
    required String username,
    required String password,
  }) async {
    final pending = await PendingOwnerActions.load(db);
    if (pending.isEmpty) {
      return const OwnerActionReconcileResult(confirmed: 0, stillPending: 0);
    }
    if (!api.isConfigured || activationCode.isEmpty) {
      return OwnerActionReconcileResult(
        confirmed: 0,
        stillPending: pending.length,
        error: 'This build cannot reach the cloud authorization service.',
      );
    }

    try {
      final json = await api.call('login', {
        'activation_code': activationCode,
        'username': PhoneNumber.loginIdentifier(username),
        'password': password,
      });
      final token = json['token'];
      if (token is! String || token.isEmpty) {
        return OwnerActionReconcileResult(
          confirmed: 0,
          stillPending: pending.length,
          authFailed: true,
          error: 'Sign-in did not return a session.',
        );
      }
      api.token = token;
      _authedUserId = json['user_id'] is String ? json['user_id'] as String : null;
    } on CloudApiException catch (e) {
      return OwnerActionReconcileResult(
        confirmed: 0,
        stillPending: pending.length,
        authFailed: true,
        error: e.message,
      );
    }

    final confirmed = <String>{};
    var conflicts = 0;
    String? firstError;
    var stop = false;
    for (final action in pending) {
      if (stop) break;
      try {
        // 1. Make sure the prerequisite cloud record can exist: re-queue the
        //    sync event if a restore dropped it, then require the target to
        //    be visible through pos-api before attempting the transition.
        await _ensureOutboxTarget(action);
        final prereq = await _prerequisiteMet(action);
        if (prereq == Prereq.missing) continue; // stays pending, retry later
        if (prereq == Prereq.error) {
          firstError ??= 'Could not verify cloud state.';
          stop = true;
          break;
        }

        // 2. Attempt the authoritative transition.
        await _callAction(action);
        confirmed.add(action.dedupeKey);
      } on CloudApiException catch (e) {
        firstError ??= e.message;
        if (e.message.toLowerCase().contains('owner')) {
          // Not an owner (or session revoked): nothing else can succeed.
          stop = true;
          break;
        }
        // 3. Lost-response / already-applied handling: read the
        //    authoritative state instead of trusting the error.
        final verdict = await _verdict(action);
        if (verdict == Verdict.confirmed) {
          confirmed.add(action.dedupeKey);
        } else if (verdict == Verdict.conflict) {
          conflicts++;
        } else {
          // stillPending or unknown — keep queued, retry next pass.
          stop = true; // a hard failure likely affects later actions too
        }
      }
    }

    await PendingOwnerActions.removeConfirmed(db, confirmed);
    final remaining = await PendingOwnerActions.load(db);
    return OwnerActionReconcileResult(
      confirmed: confirmed.length,
      stillPending: remaining.length,
      conflicts: conflicts,
      error: firstError,
    );
  }

  Future<void> _callAction(PendingOwnerAction action) {
    switch (action.kind) {
      case PendingOwnerActions.voidSale:
        return api.call('void_sale', {
          'sale_id': action.targetId,
          'reason': action.reason ?? '',
        });
      case PendingOwnerActions.approveVoid:
        return api.call('approve_void', {'request_id': action.targetId});
      case PendingOwnerActions.rejectVoid:
        return api.call('reject_void', {'request_id': action.targetId});
      default:
        throw CloudApiException('Unknown pending action: ${action.kind}');
    }
  }

  /// Re-queues the sync event for the action's target when the outbox no
  /// longer holds it (JSON restore deletes `sync_outbox` but keeps
  /// `settings`, so pending actions would otherwise wait forever for a
  /// cloud record that can never arrive). Idempotent: the server applies
  /// by entity id, so a duplicate push is a no-op.
  Future<void> _ensureOutboxTarget(PendingOwnerAction action) async {
    final entityType = action.kind == PendingOwnerActions.voidSale
        ? SyncEntities.sale
        : SyncEntities.voidRequest;
    final queued = await db.query(
      'sync_outbox',
      columns: const ['id'],
      where: 'entity_type = ? AND entity_id = ? AND synced_at IS NULL',
      whereArgs: [entityType, action.targetId],
      limit: 1,
    );
    if (queued.isNotEmpty) return;

    if (action.kind == PendingOwnerActions.voidSale) {
      final saleRows = await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: [action.targetId],
        limit: 1,
      );
      if (saleRows.isEmpty) return; // nothing to sync; stays pending
      final items = await db.query(
        'sale_items',
        where: 'sale_id = ?',
        whereArgs: [action.targetId],
      );
      await db.insert('sync_outbox', {
        'id': const Uuid().v4(),
        'entity_type': entityType,
        'entity_id': action.targetId,
        'operation': 'upsert',
        'payload': jsonEncode({
          'sale': SyncOutbox.timestampsToUtc(saleRows.first),
          'items': [
            for (final i in items) SyncOutbox.timestampsToUtc(i),
          ],
        }),
        'created_at': DateTime.now().toIso8601String(),
        'synced_at': null,
      });
    } else {
      final rows = await db.query(
        'void_requests',
        where: 'id = ?',
        whereArgs: [action.targetId],
        limit: 1,
      );
      if (rows.isEmpty) return;
      await db.insert('sync_outbox', {
        'id': const Uuid().v4(),
        'entity_type': entityType,
        'entity_id': action.targetId,
        'operation': 'upsert',
        'payload': jsonEncode({
          'void_request': SyncOutbox.timestampsToUtc(rows.first),
        }),
        'created_at': DateTime.now().toIso8601String(),
        'synced_at': null,
      });
    }
  }

  /// Whether the action's cloud target exists yet. `missing` → keep pending
  /// (the sync pipeline will deliver it); `met` → safe to attempt.
  Future<Prereq> _prerequisiteMet(PendingOwnerAction action) async {
    try {
      if (action.kind == PendingOwnerActions.voidSale) {
        final res = await api.call('search_sales', {
          'sale_id': action.targetId,
          'limit': 1,
        });
        final sales = res['sales'];
        return sales is List && sales.isNotEmpty ? Prereq.met : Prereq.missing;
      }
      // approve/reject: the request must exist in the cloud. PENDING is the
      // only state that can still be acted on; decided states are handled by
      // _verdict after the call fails.
      final res = await api.call('list_void_requests', {'limit': 1000});
      final reqs = res['void_requests'];
      if (reqs is! List) return Prereq.missing;
      final found = reqs.any(
        (r) => r is Map && '${r['id']}' == action.targetId,
      );
      return found ? Prereq.met : Prereq.missing;
    } on CloudApiException {
      return Prereq.error;
    }
  }

  /// Reads the authoritative cloud state after a failed transition attempt
  /// and classifies it: does it already reflect EXACTLY this action by THIS
  /// owner (confirmed), a different decision (conflict), or neither
  /// (stillPending → retry later)?
  Future<Verdict> _verdict(PendingOwnerAction action) async {
    try {
      if (action.kind == PendingOwnerActions.voidSale) {
        final res = await api.call('search_sales', {
          'sale_id': action.targetId,
          'limit': 1,
        });
        final sales = res['sales'];
        if (sales is! List || sales.isEmpty) return Verdict.stillPending;
        final sale = sales.first;
        if (sale is! Map) return Verdict.stillPending;
        if ('${sale['status']}' != 'VOIDED') return Verdict.stillPending;
        // Confirmed only when the recorded voidor is this same verified
        // owner — a void by anyone else is a conflict, not a success.
        return '${sale['voided_by']}' == _authedUserId
            ? Verdict.confirmed
            : Verdict.conflict;
      }
      final wanted = action.kind == PendingOwnerActions.approveVoid
          ? 'APPROVED'
          : 'REJECTED';
      final res = await api.call('list_void_requests', {
        'status': wanted,
        'limit': 1000,
      });
      final reqs = res['void_requests'];
      if (reqs is! List) return Verdict.stillPending;
      for (final r in reqs) {
        if (r is Map && '${r['id']}' == action.targetId) {
          return '${r['decided_by']}' == _authedUserId
              ? Verdict.confirmed
              : Verdict.conflict;
        }
      }
      // Not decided as intended: check whether it was decided the OTHER way
      // (conflict) or is still pending/missing (retry later).
      final other = await api.call('list_void_requests', {
        'status': action.kind == PendingOwnerActions.approveVoid
            ? 'REJECTED'
            : 'APPROVED',
        'limit': 1000,
      });
      final otherReqs = other['void_requests'];
      if (otherReqs is List &&
          otherReqs.any((r) => r is Map && '${r['id']}' == action.targetId)) {
        return Verdict.conflict;
      }
      return Verdict.stillPending;
    } on CloudApiException {
      return Verdict.stillPending;
    }
  }
}

enum Prereq { met, missing, error }

enum Verdict { confirmed, conflict, stillPending }
