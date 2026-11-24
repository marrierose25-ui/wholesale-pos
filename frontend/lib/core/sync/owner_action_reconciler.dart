import 'package:pos_cloud_engine/pos_cloud_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

/// Outcome of one reconciliation pass over [PendingOwnerActions].
class OwnerActionReconcileResult {
  /// Entries the server confirmed this pass (already removed locally).
  final int confirmed;

  /// Entries still awaiting authorization (kept in the pending store).
  final int stillPending;

  /// pos-api refused the owner's credentials — nothing was attempted.
  final bool authFailed;

  /// First server/client error encountered, safe to show the operator.
  final String? error;

  const OwnerActionReconcileResult({
    required this.confirmed,
    required this.stillPending,
    this.authFailed = false,
    this.error,
  });
}

/// Releases locally-recorded owner transitions (offline voids / void-request
/// decisions) through the authenticated `pos-api` surface.
///
/// Stage 4.1 / audit H1: the sync gateway stages DATA only — it can no longer
/// turn a pushed `VOIDED`/`APPROVED`/`REJECTED` payload into an authoritative
/// transition, because a license proves the device, not which user acted.
/// The authoritative transition therefore has to come from `pos-api`, whose
/// handlers carve the actor from a verified JWT (`ctx.userId`) and enforce
/// the OWNER_ONLY gate server-side.
///
/// This class is the native side of that contract. It never invents
/// credentials: the owner re-authenticates with their pos-api login (the
/// same phone + password the web/PWA uses), [CloudApiClient] holds the
/// returned JWT, and each pending action is replayed as the matching
/// pos-api action. Only a confirmed `ok: true` removes the local pending
/// record — a refused login or a failed call leaves everything queued, so
/// the operation is never lost and never applied without authorization.
class OwnerActionReconciler {
  final Database db;
  final CloudApiClient api;

  /// The shop's activation code — the tenant identity `pos-api` resolves at
  /// login. Read from the same `settings` key [DeviceActivation] writes.
  final String activationCode;

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

  /// Attempts every pending action in order. Stops at the first failure so a
  /// refused credential or a transient network error cannot partially drain
  /// the queue out of order; confirmed entries are still removed.
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

    // Establish the authenticated session. `login` is the existing public
    // pos-api action; the JWT it returns is what checkAuthorization verifies
    // on every subsequent call — the pending record's localUserId is audit
    // context only and is deliberately NOT sent as proof of identity.
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
    } on CloudApiException catch (e) {
      return OwnerActionReconcileResult(
        confirmed: 0,
        stillPending: pending.length,
        authFailed: true,
        error: e.message,
      );
    }

    final confirmed = <String>{};
    String? firstError;
    var authFailed = false;
    for (final action in pending) {
      try {
        switch (action.kind) {
          case PendingOwnerActions.voidSale:
            await api.call('void_sale', {
              'sale_id': action.targetId,
              'reason': action.reason ?? '',
            });
          case PendingOwnerActions.approveVoid:
            await api.call('approve_void', {'request_id': action.targetId});
          case PendingOwnerActions.rejectVoid:
            await api.call('reject_void', {'request_id': action.targetId});
          default:
            // An unknown kind can never be authorized — drop it rather than
            // retrying forever, but count it as still pending for visibility.
            firstError ??= 'Unknown pending action: ${action.kind}';
            continue;
        }
        confirmed.add(action.dedupeKey);
      } on CloudApiException catch (e) {
        firstError ??= e.message;
        // A 403 means the signed-in user is not an owner (or the session was
        // revoked): no later action can succeed either, so stop here.
        if (e.message.toLowerCase().contains('owner')) {
          authFailed = true;
          break;
        }
        break;
      }
    }

    await PendingOwnerActions.removeConfirmed(db, confirmed);
    final remaining = await PendingOwnerActions.load(db);
    return OwnerActionReconcileResult(
      confirmed: confirmed.length,
      stillPending: remaining.length,
      authFailed: authFailed,
      error: firstError,
    );
  }
}
