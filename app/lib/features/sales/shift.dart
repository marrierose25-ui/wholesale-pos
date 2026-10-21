class Shift {
  final String id;
  final String cashierId;
  final int openingCashMinorUnits;
  final int? closingCashMinorUnits;
  final int? expectedCashMinorUnits;
  final String status; // OPEN, CLOSED
  final DateTime openedAt;
  final DateTime? closedAt;

  Shift({
    required this.id,
    required this.cashierId,
    required this.openingCashMinorUnits,
    this.closingCashMinorUnits,
    this.expectedCashMinorUnits,
    required this.status,
    required this.openedAt,
    this.closedAt,
  });

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
    return Shift(
      id: map['id'] as String,
      cashierId: map['cashier_id'] as String,
      openingCashMinorUnits: map['opening_cash_minor_units'] as int,
      closingCashMinorUnits: map['closing_cash_minor_units'] as int?,
      expectedCashMinorUnits: map['expected_cash_minor_units'] as int?,
      status: map['status'] as String,
      openedAt: DateTime.parse(map['opened_at'] as String),
      closedAt: map['closed_at'] != null
          ? DateTime.parse(map['closed_at'] as String)
          : null,
    );
  }
}
