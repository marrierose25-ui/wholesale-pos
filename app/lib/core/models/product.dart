class Product {
  final String id;
  final String name;
  final String code;
  final String? category;
  final String unit;
  final int sellingPriceMinorUnits;
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
      'is_active': isActive ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Product.fromMap(Map<String, dynamic> map) {
    return Product(
      id: map['id'] as String,
      name: map['name'] as String,
      code: map['code'] as String,
      category: map['category'] as String?,
      unit: map['unit'] as String,
      sellingPriceMinorUnits: map['selling_price_minor_units'] as int,
      isActive: (map['is_active'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
