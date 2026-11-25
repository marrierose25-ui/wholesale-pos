import 'dart:convert';

import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:sqflite/sqflite.dart';

/// Locally stored, server-issued actor grants.
///
/// A device licence authenticates the DEVICE. It says nothing about which
/// person is operating the till, so the sync gateway will not attribute a
/// staged sale, cash movement, or finance row to a `cashier_id`/`created_by`
/// inside the payload. Instead the native client signs a user in with their
/// password and asks `pos-api` for an opaque grant bound to
/// (tenant, user, device); this class keeps that token in the same local
/// settings table as the licence.
///
/// Security properties:
///   * The grant is a delegated credential, not a password. It expires and is
///     invalidated server-side by a token-version bump (password reset,
///     deactivation, deletion) or device deactivation.
///   * It is stored locally so an offline till can attach it to queued rows
///     when the network returns. It is never written into the outbox payload
///     itself, so a later reader of the outbox cannot replay it as data.
///   * No grant is required to SELL. A missing/expired grant leaves the outbox
///     row queued; it never blocks the register.
class ActorGrantStore {
  /// Settings key prefix. One grant per user id, so a device that several
  /// people use keeps each person's grant rather than overwriting one.
  static const String keyPrefix = 'actor_grant:';

  final Database _db;

  /// The signed-in user, set by the auth shell. Used as the fallback actor for
  /// outbox rows that carry no actor column (e.g. a product edit): the person
  /// operating the till is the actor.
  String? currentUserId;

  // Not const: [currentUserId] is mutable session state.
  ActorGrantStore(this._db);

  static String keyFor(String userId) => '$keyPrefix$userId';

  Future<void> save(
    String userId, {
    required String grant,
    DateTime? expiresAt,
  }) async {
    if (userId.isEmpty || grant.isEmpty) return;
    await LocalDatabase.setSetting(
      _db,
      keyFor(userId),
      jsonEncode({
        'grant': grant,
        'expires_at': expiresAt?.toUtc().toIso8601String(),
      }),
    );
  }

  /// The live grant for [userId], or null when absent/expired/malformed.
  /// Expiry is checked locally so an offline till does not queue a push it
  /// already knows the server will defer.
  Future<String?> grantFor(String userId, {DateTime? now}) async {
    if (userId.isEmpty) return null;
    final raw = await LocalDatabase.getSetting(_db, keyFor(userId));
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final grant = decoded['grant'];
      if (grant is! String || grant.isEmpty) return null;
      final expires = DateTime.tryParse('${decoded['expires_at'] ?? ''}');
      if (expires != null &&
          !(now ?? DateTime.now()).toUtc().isBefore(expires.toUtc())) {
        return null;
      }
      return grant;
    } catch (_) {
      return null;
    }
  }

  Future<void> clear(String userId) async {
    await _db.delete(
      'settings',
      where: 'key = ?',
      whereArgs: [keyFor(userId)],
    );
  }

  /// The grant to attach to [entry]: the entry's own actor when it names one
  /// (so an owner's queued edit still resolves after a cashier logs in), else
  /// the currently signed-in user.
  Future<String?> grantForEntry(SyncOutboxEntry entry) async {
    final actor = actorIdOf(entry) ?? currentUserId;
    return actor == null ? null : grantFor(actor);
  }

  /// Actor id a queued row claims, used ONLY to choose which locally stored
  /// grant to attach. The server never trusts this field; it resolves the
  /// grant to a live user and uses that user for every actor column.
  static String? actorIdOf(SyncOutboxEntry entry) {
    Map<String, dynamic> payload;
    try {
      payload = entry.payload;
    } catch (_) {
      return null;
    }
    String? read(String objectKey, String field) {
      final object = payload[objectKey];
      if (object is Map) {
        final value = object[field];
        if (value is String && value.isNotEmpty) return value;
      }
      return null;
    }

    switch (entry.entityType) {
      case SyncEntities.sale:
        return read('sale', 'cashier_id');
      case SyncEntities.shift:
        return read('shift', 'cashier_id');
      case SyncEntities.cashMovement:
        return read('cash_movement', 'user_id');
      case SyncEntities.voidRequest:
        return read('void_request', 'requested_by');
      case SyncEntities.financeEntry:
        return read('finance_entry', 'created_by') ??
            read('finance_entry', 'completed_by');
      case SyncEntities.picklist:
        return read('picklist', 'created_by');
      // `user` is deliberately absent: the payload id is the ACCOUNT being
      // edited, not the person editing it. Falling through to the signed-in
      // user is what attributes an owner's offline cashier edit correctly.
      default:
        return null;
    }
  }
}
