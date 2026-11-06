/// A saved customer in the Warehouse picklist directory (schema 21).
///
/// Purely a name/phone lookup used by the New Picklist form so a worker can
/// pick who a fulfillment is for instead of retyping it. It is deliberately
/// isolated from the ledger `customers` / `users` tables and from Sales: a
/// picklist customer only labels a picklist header, never a transaction.
class PicklistCustomer {
  final String id;
  final String name;
  final String? phone;
  final DateTime createdAt;

  PicklistCustomer({
    required this.id,
    required this.name,
    required this.createdAt,
    this.phone,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone': phone,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory PicklistCustomer.fromMap(Map<String, dynamic> map) {
    return PicklistCustomer(
      id: map['id'] as String,
      name: map['name'] as String,
      phone: map['phone'] as String?,
      // Defensive parse: a missing/blank stamp falls back to now rather than
      // throwing, matching the null/coerce-guard convention for cloud rows.
      createdAt:
          DateTime.tryParse(map['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}
