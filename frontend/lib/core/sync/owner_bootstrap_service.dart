import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

/// Outcome of one first-owner bootstrap reconciliation pass.
enum OwnerBootstrapStatus {
  /// No local OWNER exists, or bootstrap already completed.
  notNeeded,

  /// The cloud owner now exists with the SAME id as the local owner.
  bootstrapped,

  /// A different owner already owns the tenant — surfaced, never overwritten.
  conflict,

  /// Offline / server unreachable / rate-limited — retry on a later pass.
  pending,
}

class OwnerBootstrapResult {
  final OwnerBootstrapStatus status;
  final String? detail;

  const OwnerBootstrapResult(this.status, [this.detail]);
}

/// Reconciles a natively-created first owner with the cloud (Request 3 P0).
///
/// The deadlock this closes: a new native install creates its OWNER locally
/// and queues the `user` sync row, but `pos_sync_apply` refuses to create an
/// OWNER through device sync (by design — a device grant must never mint
/// owner accounts), and `issue_actor_grant` needs the cloud `pos_users` row
/// to exist first. The existing `setup_owner` pos-api action is the secure
/// bootstrap path: it is gated by the activation code, enforces the
/// one-owner policy inside `pos_setup_owner`, and is rate-limited.
///
/// This service calls it with the LOCAL owner's id and its already-stored
/// cloud-format credential (`users.cloud_pw_salt`/`cloud_pw_hash` — the same
/// PBKDF2 pair the web verifies, never a new secret and never the local-only
/// password hash). Identity stays consistent because the server adopts the
/// supplied id; `pos_setup_owner` is idempotent for the same id and refuses
/// a second owner atomically.
///
/// When the cloud already has a DIFFERENT owner (web bootstrap won the
/// race), the result is [OwnerBootstrapStatus.conflict]: the local owner
/// keeps working offline, nothing is overwritten, and the operator sees the
/// conflict instead of a silently split identity.
class OwnerBootstrapService {
  /// Settings key prefix recording the reconciliation state per owner id.
  static const String statePrefix = 'owner_bootstrap:';

  final Database db;
  final String apiUrl;
  final Future<String?> Function() activationCodeProvider;
  final http.Client? client;

  const OwnerBootstrapService({
    required this.db,
    required this.apiUrl,
    required this.activationCodeProvider,
    this.client,
  });

  bool get isConfigured => apiUrl.isNotEmpty;

  static String stateKey(String userId) => '$statePrefix$userId';

  /// Runs one reconciliation pass. Never throws: every failure maps to
  /// [OwnerBootstrapStatus.pending] so the till keeps selling and the next
  /// connectivity window retries.
  Future<OwnerBootstrapResult> reconcile() async {
    if (!isConfigured) {
      return const OwnerBootstrapResult(OwnerBootstrapStatus.notNeeded);
    }
    final owner = await _localOwner();
    if (owner == null) {
      return const OwnerBootstrapResult(OwnerBootstrapStatus.notNeeded);
    }
    final ownerId = owner['id'] as String;
    final state = await LocalDatabase.getSetting(db, stateKey(ownerId));
    if (state == 'done' || state == 'conflict') {
      return OwnerBootstrapResult(
        state == 'done'
            ? OwnerBootstrapStatus.bootstrapped
            : OwnerBootstrapStatus.conflict,
      );
    }
    final code = (await activationCodeProvider())?.trim() ?? '';
    if (code.isEmpty) {
      return const OwnerBootstrapResult(OwnerBootstrapStatus.pending,
          'No activation code stored yet.');
    }

    final pwSalt = '${owner['cloud_pw_salt'] ?? ''}';
    final pwHash = '${owner['cloud_pw_hash'] ?? ''}';
    if (pwSalt.isEmpty || pwHash.isEmpty) {
      // An owner row without a cloud-format credential cannot be reconciled
      // without the plaintext password (which is never stored). Leave it
      // pending; a password change or re-setup republishes the credential.
      return const OwnerBootstrapResult(OwnerBootstrapStatus.pending,
          'Owner has no cloud credential to reconcile with.');
    }

    try {
      final res = await (client ?? http.Client())
          .post(
            Uri.parse(apiUrl),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'action': 'setup_owner',
              'activation_code': code,
              'username': owner['username'],
              'user_id': ownerId,
              'pw_salt': pwSalt,
              'pw_hash': pwHash,
            }),
          )
          .timeout(const Duration(seconds: 20));
      final decoded = jsonDecode(res.body);
      if (decoded is! Map) {
        return const OwnerBootstrapResult(OwnerBootstrapStatus.pending,
            'Unexpected bootstrap response.');
      }
      if (decoded['ok'] == true) {
        await _markDone(ownerId);
        return const OwnerBootstrapResult(OwnerBootstrapStatus.bootstrapped);
      }
      // 409 "Owner already exists": the tenant has an owner. If it is THIS
      // owner id the earlier attempt actually committed (lost response) —
      // done. Any other id is a real identity conflict.
      final cloudOwnerId = '${decoded['owner_id'] ?? ''}';
      if (cloudOwnerId.isNotEmpty && cloudOwnerId == ownerId) {
        await _markDone(ownerId);
        return const OwnerBootstrapResult(OwnerBootstrapStatus.bootstrapped);
      }
      if (cloudOwnerId.isNotEmpty) {
        await LocalDatabase.setSetting(db, stateKey(ownerId), 'conflict');
        return OwnerBootstrapResult(OwnerBootstrapStatus.conflict,
            'Cloud owner ${decoded['owner_username'] ?? cloudOwnerId} '
            'already exists with a different id.');
      }
      // Any other refusal (rate limit, licence, validation) is retryable.
      return OwnerBootstrapResult(OwnerBootstrapStatus.pending,
          '${decoded['error'] ?? 'Bootstrap refused.'}');
    } catch (_) {
      return const OwnerBootstrapResult(OwnerBootstrapStatus.pending,
          'Cloud unreachable.');
    }
  }

  Future<Map<String, Object?>?> _localOwner() async {
    final rows = await db.query(
      'users',
      where: "role = 'OWNER' AND deleted_at IS NULL",
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Bootstrap delivered the owner row through the secure pos-api path, so
  /// the queued `user` sync entry for it is already satisfied server-side —
  /// mark exactly those outbox rows synced instead of letting them bounce
  /// through pos_sync_apply (which refuses OWNER creation by design).
  Future<void> _markDone(String ownerId) async {
    await LocalDatabase.setSetting(db, stateKey(ownerId), 'done');
    final pending = await db.query(
      'sync_outbox',
      columns: const ['id'],
      where: "entity_type = 'user' AND entity_id = ? AND synced_at IS NULL",
      whereArgs: [ownerId],
    );
    if (pending.isEmpty) return;
    final outbox = SqfliteSyncOutboxRepository(db);
    await outbox.markSynced([for (final r in pending) r['id'] as String]);
  }
}
