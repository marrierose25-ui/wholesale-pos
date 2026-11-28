class Product {
  final String id;
  final String name;
  final String code;
  final String? category;
  final String unit;
  final int sellingPriceMinorUnits;

  /// Purchase/cost price in minor units. Defaults to 0 for products created
  /// before the inventory foundation (and for saved-name rows that never
  /// carried a cost).
  final int boughtPriceMinorUnits;

  /// Optional product photo as a base64 JPEG, compressed through the same
  /// pipeline as register proof photos. Null when the product has no image.
  final String? imageData;
  final bool isActive;
  final DateTime createdAt;
  final DateTime updatedAt;

  Product({
    required this.id,
    required this.name,
    required this.code,
    this.category,
    required this.unit,
    required this.sellingPriceMinorUnits,
    this.boughtPriceMinorUnits = 0,
    this.imageData,
    this.isActive = true,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'code': code,
      'category': category,
      'unit': unit,
      'selling_price_minor_units': sellingPriceMinorUnits,
      'bought_price_minor_units': boughtPriceMinorUnits,
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    // `selling_price_minor_units` is bigint and `is_active` is a 0/1 integer in
    // both SQLite and Postgres, but the web JSON decoder can present either as a
    // `double`. Read through `num` so a cloud-hydrated saved name never throws.
    return Product(
      id: map['id'] as String,
      name: map['name'] as String,
      code: map['code'] as String? ?? '',
      category: map['category'] as String?,
      unit: map['unit'] as String? ?? '',
      sellingPriceMinorUnits:
          (map['selling_price_minor_units'] as num?)?.toInt() ?? 0,
      boughtPriceMinorUnits:
          (map['bought_price_minor_units'] as num?)?.toInt() ?? 0,
      imageData: map['image_data'] as String?,
      isActive: ((map['is_active'] as num?)?.toInt() ?? 1) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(
        (map['updated_at'] as String?) ?? map['created_at'] as String,
      ),
    );
  }
}
