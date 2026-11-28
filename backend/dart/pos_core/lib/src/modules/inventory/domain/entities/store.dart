/// A store is a location where the business holds inventory. A shop can have
/// several; each product's on-hand and reorder quantities live per store in
/// [StoreInventory], never as one global figure on the product itself.
///
/// Mutable master data: carries [updatedAt], the stamp sync compares
/// newest-wins, and a [deletedAt] tombstone so a deletion reaches every
/// device (the sync feed has no delete channel).
class Store {
  final String id;
  final String name;

  /// When set, the store is deleted. Reads filter it out; the row stays so
  /// the tombstone can sync to other devices.
  final DateTime? deletedAt;
  final DateTime createdAt;
  final DateTime updatedAt;

  Store({
    required this.id,
    required this.name,
    this.deletedAt,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isDeleted => deletedAt != null;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'deleted_at': deletedAt?.toIso8601String(),
    };
  }

  factory Store.fromMap(Map<String, dynamic> map) {
    return Store(
      id: map['id'] as String,
      name: map['name'] as String,
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
