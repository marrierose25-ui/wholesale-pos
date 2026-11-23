/// Header of a Warehouse Picklist (Digital Fulfillment).
///
/// An independent feature: a picklist is created against a customer name and
/// its line items are ticked up as warehouse workers take stock. It never
/// touches Sales, Shifts, or Finance — the money and drawer logic are untouched
/// by design. `status` and the item quantities change over time, so the row is
/// mutable and carries `updatedAt`, the stamp the sync compares newest-wins.
class Picklist {
  static const String statusPending = 'PENDING';

  /// Some but not all items have been partially/fully taken. Set by the
  /// repository's progress pass between [statusPending] and [statusCompleted].
  static const String statusPartial = 'PARTIAL';
  static const String statusCompleted = 'COMPLETED';

  final String id;
  final String customerName;
  final String status;
  final String createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;

  Picklist({
    required this.id,
    required this.customerName,
    required this.status,
    required this.createdBy,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isCompleted => status == statusCompleted;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'customer_name': customerName,
      'status': status,
      'created_by': createdBy,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Picklist.fromMap(Map<String, dynamic> map) {
    return Picklist(
      id: map['id'] as String,
      customerName: map['customer_name'] as String,
      status: map['status'] as String? ?? statusPending,
      createdBy: map['created_by'] as String,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
