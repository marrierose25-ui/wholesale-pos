class Shift {
  final String id;
  final String cashierId;
  final int openingCashMinorUnits;
  final int? closingCashMinorUnits;
  final int? expectedCashMinorUnits;
  final String status; // OPEN, CLOSED
  final DateTime openedAt;
  final DateTime? closedAt;

  /// Username of the cashier who ran the shift. Hydrated from the users table
  /// for the register-history view only; never persisted on the shift row.
  final String? cashierName;

  Shift({
    required this.id,
    required this.cashierId,
    required this.openingCashMinorUnits,
    this.closingCashMinorUnits,
    this.expectedCashMinorUnits,
    required this.status,
    required this.openedAt,
    this.closedAt,
    this.cashierName,
  });

  /// Counted cash minus the expected cash at close time. Null while the shift
  /// is still open (no closing figure recorded yet).
  int? get discrepancy {
    if (closingCashMinorUnits == null || expectedCashMinorUnits == null) {
      return null;
    }
    return closingCashMinorUnits! - expectedCashMinorUnits!;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'cashier_id': cashierId,
      'opening_cash_minor_units': openingCashMinorUnits,
      'closing_cash_minor_units': closingCashMinorUnits,
      'expected_cash_minor_units': expectedCashMinorUnits,
      'status': status,
      'opened_at': openedAt.toIso8601String(),
      'closed_at': closedAt?.toIso8601String(),
    };
  }

  factory Shift.fromMap(Map<String, dynamic> map) {
    // Cash columns are integer-typed in both stores, but the web JSON decoder
    // can hand back a whole number as a `double`; reading through `num` keeps a
    // cloud-hydrated shift from throwing an `as int` cast.
    return Shift(
      id: map['id'] as String,
      cashierId: map['cashier_id'] as String,
      openingCashMinorUnits:
          (map['opening_cash_minor_units'] as num?)?.toInt() ?? 0,
      closingCashMinorUnits: (map['closing_cash_minor_units'] as num?)?.toInt(),
      expectedCashMinorUnits: (map['expected_cash_minor_units'] as num?)
          ?.toInt(),
      status: map['status'] as String,
      openedAt: DateTime.parse(map['opened_at'] as String),
      closedAt: map['closed_at'] != null
          ? DateTime.parse(map['closed_at'] as String)
          : null,
      cashierName: map['cashier_name'] as String?,
    );
  }
}
