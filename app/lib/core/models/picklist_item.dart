/// One line of a Warehouse Picklist: a product the warehouse is asked to pull
/// for a [Picklist]. `takenQty` rises from zero toward `requestedQty` as the
/// worker ticks items off, so the row is mutable and carries `updatedAt` — the
/// stamp the sync compares newest-wins.
///
/// Deliberately stores `productName` rather than a product foreign key: a
/// picklist is a fulfillment instruction, not a priced sale, and must survive
/// even if the saved-name row changes or is removed later.
class PicklistItem {
  final String id;
  final String picklistId;
  final String productName;
  final int requestedQty;
  final int takenQty;
  final DateTime updatedAt;

  PicklistItem({
    required this.id,
    required this.picklistId,
    required this.productName,
    required this.requestedQty,
    required this.takenQty,
    required this.updatedAt,
  });

  /// True once the worker has taken everything the line asked for.
  bool get isFulfilled => takenQty >= requestedQty;

  /// Returns a copy with the fulfillment progress updated. Used by the
  /// Warehouse screen when a worker saves taken quantities; every other field
  /// (id, parent, requested) is immutable.
  PicklistItem copyWith({int? takenQty, DateTime? updatedAt}) {
    return PicklistItem(
      id: id,
      picklistId: picklistId,
      productName: productName,
      requestedQty: requestedQty,
      takenQty: takenQty ?? this.takenQty,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'picklist_id': picklistId,
      'product_name': productName,
      'requested_qty': requestedQty,
      'taken_qty': takenQty,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory PicklistItem.fromMap(Map<String, dynamic> map) {
    return PicklistItem(
      id: map['id'] as String,
      picklistId: map['picklist_id'] as String,
      productName: map['product_name'] as String,
      requestedQty: (map['requested_qty'] as num?)?.toInt() ?? 0,
      takenQty: (map['taken_qty'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
