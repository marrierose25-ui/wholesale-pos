/// A person (or category) in the owner's private money-tracking area.
/// Renaming keeps the same row so historical entries stay attached.
class FinanceCategory {
  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// Non-null once the person has been moved to the recycle bin. Active views
  /// filter these out; only the recycle bin lists them.
  final DateTime? deletedAt;

  FinanceCategory({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.updatedAt,
    this.deletedAt,
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

  factory FinanceCategory.fromMap(Map<String, dynamic> map) {
    return FinanceCategory(
      id: map['id'] as String,
      name: map['name'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      deletedAt: map['deleted_at'] == null
          ? null
          : DateTime.parse(map['deleted_at'] as String),
    );
  }
}
