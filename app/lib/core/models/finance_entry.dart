/// One manually recorded money activity in the owner's private area, e.g.
/// "taken from Bank X". Completely separate from sales: creating or
/// completing an entry never touches sales or revenue totals.
class FinanceEntry {
  static const String statusPending = 'PENDING';
  static const String statusCompleted = 'COMPLETED';

  final String id;
  final String categoryId;
  final String source;
  final int amountMinorUnits;
  final String? description;
  final String status;
  final DateTime entryDate;
  final DateTime createdAt;
  final String createdBy;
  final DateTime? completedAt;
  final String? completedBy;
  final DateTime updatedAt;

  /// Person name hydrated from the category for display only.
  final String? categoryName;

  FinanceEntry({
    required this.id,
    required this.categoryId,
    required this.source,
    required this.amountMinorUnits,
    this.description,
    required this.status,
    required this.entryDate,
    required this.createdAt,
    required this.createdBy,
    this.completedAt,
    this.completedBy,
    required this.updatedAt,
    this.categoryName,
  });

  bool get isCompleted => status == statusCompleted;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'category_id': categoryId,
      'source': source,
      'amount_minor_units': amountMinorUnits,
      'description': description,
      'status': status,
      'entry_date': entryDate.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'created_by': createdBy,
      'completed_at': completedAt?.toIso8601String(),
      'completed_by': completedBy,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory FinanceEntry.fromMap(Map<String, dynamic> map) {
    return FinanceEntry(
      id: map['id'] as String,
      categoryId: map['category_id'] as String,
      source: map['source'] as String,
      amountMinorUnits: (map['amount_minor_units'] as num?)?.toInt() ?? 0,
      description: map['description'] as String?,
      status: map['status'] as String,
      entryDate: DateTime.parse(map['entry_date'] as String),
      createdAt: DateTime.parse(map['created_at'] as String),
      createdBy: map['created_by'] as String,
      completedAt: map['completed_at'] == null
          ? null
          : DateTime.parse(map['completed_at'] as String),
      completedBy: map['completed_by'] as String?,
      updatedAt: DateTime.parse(map['updated_at'] as String),
      categoryName: map['category_name'] as String?,
    );
  }
}
