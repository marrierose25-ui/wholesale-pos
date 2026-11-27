/// One product's stock record inside one store: how many units are on hand
/// and the reorder threshold that decides the stock-status colour.
///
/// Quantities are MILLIUNITS (1500 = 1.5), the same fixed-point convention
/// `sale_items.billing_quantity_milliunits` uses, so kilogram/litre stock
/// never touches binary floating point.
class StoreInventory {
  final String id;
  final String storeId;
  final String productId;
  final int onHandMilliunits;
  final int reorderMilliunits;
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  StoreInventory({
    required this.id,
    required this.storeId,
    required this.productId,
    required this.onHandMilliunits,
    required this.reorderMilliunits,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'store_id': storeId,
      'product_id': productId,
      'on_hand_milliunits': onHandMilliunits,
      'reorder_milliunits': reorderMilliunits,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory StoreInventory.fromMap(Map<String, dynamic> map) {
    int milli(Object? v) => (v as num?)?.toInt() ?? 0;
    return StoreInventory(
      id: map['id'] as String,
      storeId: map['store_id'] as String,
      productId: map['product_id'] as String,
      onHandMilliunits: milli(map['on_hand_milliunits']),
      reorderMilliunits: milli(map['reorder_milliunits']),
      deletedAt: map['deleted_at'] == null
          ? null
          : DateTime.parse(map['deleted_at'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(
        (map['updated_at'] as String?) ?? map['created_at'] as String,
      ),
    );
  }
}
