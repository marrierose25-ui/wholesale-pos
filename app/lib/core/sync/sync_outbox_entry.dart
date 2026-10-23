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
  final String
  entityType; // 'sale' | 'shift' | 'cash_movement' | 'void_request'
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
abstract final class SyncEntities {
  static const String sale = 'sale';
  static const String shift = 'shift';
  static const String cashMovement = 'cash_movement';
  static const String voidRequest = 'void_request';
}

abstract final class SyncOperations {
  static const String upsert = 'UPSERT';
  static const String delete = 'DELETE';
}
