/// A person (or category) in the owner's private money-tracking area.
/// Renaming keeps the same row so historical entries stay attached.
class FinanceCategory {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  FinanceCategory({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory FinanceCategory.fromMap(Map<String, dynamic> map) {
    return FinanceCategory(
      id: map['id'] as String,
      name: map['name'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
