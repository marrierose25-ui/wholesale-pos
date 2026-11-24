import 'dart:convert';

import 'package:sqflite/sqflite.dart';

/// A locally-authorized owner transition that still needs authoritative
/// cloud authorization through `pos-api`.
///
/// Stage 4.1 / audit H1: the sync gateway no longer applies VOIDED sales or
/// decided void requests from pushed payloads — a license proves the device,
/// never which user acted. So when an owner voids a sale (or decides a void
/// request) while this till is offline, the local row changes immediately
/// (the shop keeps trading) and this record keeps the intent durably until
/// the owner re-authenticates against `pos-api` and the server confirms the
/// transition. The record is what survives an app restart; without it the
/// local void would be invisible to the cloud forever.
class PendingOwnerAction {
  /// `void_sale` | `approve_void` | `reject_void` — the pos-api action names.
  final String kind;

  /// The sale id (void_sale) or void-request id (approve/reject void).
  final String targetId;

  /// Void reason, required by the `void_sale` action; null for decisions.
  final String? reason;

  /// The local user who authorized the transition (audit context only —
  /// NEVER sent to the server as proof of identity).
  final String localUserId;

  final DateTime createdAt;

  const PendingOwnerAction({
    required this.kind,
    required this.targetId,
    required this.localUserId,
    required this.createdAt,
    this.reason,
  });

  String get dedupeKey => '$kind:$targetId';

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'target_id': targetId,
    if (reason != null) 'reason': reason,
    'local_user_id': localUserId,
    'created_at': createdAt.toIso8601String(),
  };

  static PendingOwnerAction? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'];
    final targetId = json['target_id'];
    final userId = json['local_user_id'];
    final created = json['created_at'];
    if (kind is! String ||
        targetId is! String ||
        targetId.isEmpty ||
        userId is! String ||
        created is! String) {
      return null;
    }
    return PendingOwnerAction(
      kind: kind,
      targetId: targetId,
      reason: json['reason'] as String?,
      localUserId: userId,
      createdAt: DateTime.tryParse(created) ?? DateTime.now(),
    );
  }
}

/// Durable queue of owner transitions awaiting server authorization.
///
/// Stored as a JSON list in the `settings` table — the same place session
/// and license state already lives — so it needs no schema migration and is
/// covered by the existing backup/restore paths. Writes go through the
/// caller's transaction so the intent commits atomically with the local
/// void it describes; a crash can therefore never produce a voided sale
/// with no pending record (or a pending record for a rolled-back void).
class PendingOwnerActions {
  PendingOwnerActions._();

  static const String settingKey = 'pending_owner_actions';

  static const String voidSale = 'void_sale';
  static const String approveVoid = 'approve_void';
  static const String rejectVoid = 'reject_void';

  static Future<List<PendingOwnerAction>> load(DatabaseExecutor db) async {
    final rows = await db.query(
      'settings',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: const [settingKey],
      limit: 1,
    );
    if (rows.isEmpty) return const [];
    final raw = rows.first['value'];
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final item in decoded)
          if (item is Map<String, dynamic>)
            ?PendingOwnerAction.fromJson(item),
      ];
    } on FormatException {
      // A corrupt list must not wedge syncing or hide real pending work:
      // treat it as empty rather than throwing inside a transaction.
      return const [];
    }
  }

  /// Appends [action] inside the caller's transaction. Re-recording the
  /// same (kind, target) replaces the older entry instead of duplicating
  /// it, so a retried local operation can never queue the transition twice.
  static Future<void> record(
    Transaction txn, {
    required String kind,
    required String targetId,
    required String localUserId,
    String? reason,
  }) async {
    final existing = await load(txn);
    final next = [
      for (final a in existing)
        if (a.dedupeKey != '$kind:$targetId') a,
      PendingOwnerAction(
        kind: kind,
        targetId: targetId,
        reason: reason,
        localUserId: localUserId,
        createdAt: DateTime.now(),
      ),
    ];
    await _write(txn, next);
  }

  /// Drops every entry the server has now confirmed (or that no longer
  /// needs authorizing). Entries not named here stay pending.
  static Future<void> removeConfirmed(
    DatabaseExecutor db,
    Set<String> dedupeKeys,
  ) async {
    if (dedupeKeys.isEmpty) return;
    final remaining = [
      for (final a in await load(db))
        if (!dedupeKeys.contains(a.dedupeKey)) a,
    ];
    await _write(db, remaining);
  }

  static Future<void> _write(
    DatabaseExecutor db,
    List<PendingOwnerAction> actions,
  ) async {
    if (actions.isEmpty) {
      await db.delete(
        'settings',
        where: 'key = ?',
        whereArgs: const [settingKey],
      );
      return;
    }
    await db.insert('settings', {
      'key': settingKey,
      'value': jsonEncode([for (final a in actions) a.toJson()]),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}
