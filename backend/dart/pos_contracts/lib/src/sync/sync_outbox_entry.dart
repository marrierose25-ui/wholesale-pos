import 'dart:convert';

/// A single queued change waiting to be pushed to a remote backend.
///
/// The outbox is a *local* concept: business tables remain the source of
/// truth, and every write also appends one of these rows inside the same
/// transaction. A background worker drains them to the cloud once a
/// [SyncBackend] is configured. Keeping the queue local means the POS keeps
/// selling with no network, and nothing is ever lost if the sync fails.
class SyncOutboxEntry {
  final String id;
  final String entityType;
  final String entityId; // id of the affected row
  final String operation; // 'UPSERT' | 'DELETE'
  final String payloadJson; // serialized aggregate (row + children)
  final DateTime createdAt;
  final DateTime? syncedAt;

  const SyncOutboxEntry({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.payloadJson,
    required this.createdAt,
    this.syncedAt,
  });

  bool get isSynced => syncedAt != null;

  Map<String, dynamic> get payload =>
      jsonDecode(payloadJson) as Map<String, dynamic>;

  factory SyncOutboxEntry.fromMap(Map<String, Object?> map) {
    return SyncOutboxEntry(
      id: map['id'] as String,
      entityType: map['entity_type'] as String,
      entityId: map['entity_id'] as String,
      operation: map['operation'] as String,
      payloadJson: map['payload'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      syncedAt: map['synced_at'] == null
          ? null
          : DateTime.parse(map['synced_at'] as String),
    );
  }
}

/// Entity types written to the outbox. Kept as constants so producers and the
/// future backend agree on the vocabulary.
///
/// Two families, and the server treats them differently:
///
///   * **Ledger** ([sale], [shift], [cashMovement], [voidRequest]) is append-
///     only. The gateway stages each entity once and `pos_sync_apply` replays
///     it through the same RPCs the tills call, so a device can never restate
///     money it has already booked.
///   * **Master data** ([user], [product], [financeCategory], [financeEntry])
///     is mutable: a rename, a re-ticked permission, a collection marked
///     taken. These are re-staged on every change and applied newest-wins, so
///     the cloud copy tracks the row instead of freezing at creation.
abstract final class SyncEntities {
  static const String sale = 'sale';
  static const String shift = 'shift';
  static const String cashMovement = 'cash_movement';
  static const String voidRequest = 'void_request';
  static const String user = 'user';
  static const String product = 'product';
  static const String financeCategory = 'finance_category';
  static const String financeEntry = 'finance_entry';
  static const String picklist = 'picklist';
  static const String picklistItem = 'picklist_item';

  /// Master data: the newest payload wins, so a later edit of the same id must
  /// replace what is already staged rather than be dropped as a duplicate.
  static const Set<String> mutable = {
    user,
    product,
    financeCategory,
    financeEntry,
    // A picklist's status and its items' taken quantities change over time as
    // warehouse workers tick stock off, so both are re-staged on every edit.
    picklist,
    picklistItem,
  };

  /// Payload key each entity type is filed under, so the gateway and the
  /// server-side apply agree on one shape without a per-type branch.
  static const Map<String, String> payloadKeys = {
    sale: 'sale',
    shift: 'shift',
    cashMovement: 'cash_movement',
    voidRequest: 'void_request',
    user: 'user',
    product: 'product',
    financeCategory: 'finance_category',
    financeEntry: 'finance_entry',
    picklist: 'picklist',
    picklistItem: 'picklist_item',
  };
}

abstract final class SyncOperations {
  static const String upsert = 'UPSERT';
  static const String delete = 'DELETE';
}