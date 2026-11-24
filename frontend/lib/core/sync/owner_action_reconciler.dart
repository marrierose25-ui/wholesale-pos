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
      // Stage 4.1.2 ordering: assess authoritative state BEFORE executing.
      // A target that already reflects this exact action is confirmed
      // without a second privileged call; a conflicting decision is kept
      // pending and surfaced; a missing target waits for the sync pipeline.
      await _ensureOutboxTarget(action);
      var verdict = await _assess(action);
      if (verdict == Verdict.waitingForTarget ||
          verdict == Verdict.retryableFailure) {
        if (verdict == Verdict.retryableFailure) {
          firstError ??= 'Could not verify cloud state.';
          stop = true;
        }
        continue; // stays pending; retried on the next pass
      }
      if (verdict == Verdict.confirmed) {
        confirmed.add(action.dedupeKey);
        continue;
      }
      if (verdict == Verdict.conflict) {
        conflicts++;
        continue;
      }
      // readyToExecute — attempt the privileged transition.
      try {
        await _callAction(action);
        confirmed.add(action.dedupeKey);
      } on CloudApiException catch (e) {
        firstError ??= e.message;
        if (e.message.toLowerCase().contains('owner')) {
          // Not an owner (or session revoked): nothing else can succeed.
          stop = true;
          break;
        }
        // The transition may have committed with a lost response. Re-assess
        // authoritative state rather than trusting the error.
        verdict = await _assess(action);
        if (verdict == Verdict.confirmed) {
          confirmed.add(action.dedupeKey);
        } else if (verdict == Verdict.conflict) {
          conflicts++;
        } else {
          stop = true; // waitingForTarget/retryableFailure: keep queued
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

  /// Exact-id void-request lookup. `status` may be null to probe every
  /// decision state — exact-id queries bypass the list page limit, so this
  /// is reliable regardless of how many requests the shop has.
  Future<Map<String, dynamic>?> _findVoidRequest(
    String requestId, {
    String? status,
  }) async {
    final statuses = status != null
        ? [status]
        : const ['PENDING', 'APPROVED', 'REJECTED'];
    for (final s in statuses) {
      final res = await api.call('list_void_requests', {
        'request_id': requestId,
        'status': s,
        'limit': 1,
      });
      final reqs = res['void_requests'];
      if (reqs is List && reqs.isNotEmpty && reqs.first is Map) {
        return Map<String, dynamic>.from(reqs.first as Map);
      }
    }
    return null;
  }

  /// Authoritative-state assessment for [action] (Stage 4.1.2 verdict
  /// model). Reads only through pos-api's tenant-scoped, JWT-authenticated
  /// endpoints — never trusts local rows or payload claims.
  Future<Verdict> _assess(PendingOwnerAction action) async {
    try {
      if (action.kind == PendingOwnerActions.voidSale) {
        final res = await api.call('search_sales', {
          'sale_id': action.targetId,
          'limit': 1,
        });
        final sales = res['sales'];
        if (sales is! List || sales.isEmpty) return Verdict.waitingForTarget;
        final sale = sales.first;
        if (sale is! Map) return Verdict.retryableFailure;
        final status = '${sale['status']}';
        if (status == 'VOIDED') {
          // Confirmed only when the recorded voidor is this same verified
          // owner AND the reason matches the recorded intent.
          final sameActor = '${sale['voided_by']}' == _authedUserId;
          final sameReason = _norm(sale['void_reason']) ==
              _norm(action.reason);
          return sameActor && sameReason
              ? Verdict.confirmed
              : Verdict.conflict;
        }
        return status == 'COMPLETED'
            ? Verdict.readyToExecute
            : Verdict.conflict;
      }

      final wanted = action.kind == PendingOwnerActions.approveVoid
          ? 'APPROVED'
          : 'REJECTED';
      final other = action.kind == PendingOwnerActions.approveVoid
          ? 'REJECTED'
          : 'APPROVED';
      final req = await _findVoidRequest(action.targetId);
      if (req == null) return Verdict.waitingForTarget;
      final status = '${req['status']}';
      final decidedBy = '${req['decided_by']}';
      if (status == wanted) {
        return decidedBy == _authedUserId
            ? Verdict.confirmed
            : Verdict.conflict;
      }
      if (status == other) return Verdict.conflict;
      return status == 'PENDING'
          ? Verdict.readyToExecute
          : Verdict.conflict;
    } on CloudApiException {
      return Verdict.retryableFailure;
    }
  }

  static String _norm(Object? v) =>
      v == null ? '' : v.toString().trim().toLowerCase();
}

/// Explicit reconciliation verdicts (Stage 4.1.2).
enum Verdict {
  /// Authoritative cloud state already reflects exactly this action by this
  /// verified actor — safe to drop the pending record.
  confirmed,

  /// The cloud holds a DIFFERENT authoritative decision (other actor, or
  /// same actor with different parameters). Never overwritten.
  conflict,

  /// The target record has not reached the cloud business table yet.
  waitingForTarget,

  /// Target exists and is still in the pre-transition state — safe to call
  /// the privileged pos-api action.
  readyToExecute,

  /// Transient failure (network, 5xx, unreadable state) — retry later.
  retryableFailure,
}
