/// One line in the cash-register ledger: money physically entering (DEPOSIT)
/// or leaving (WITHDRAWAL / EXPENSE) the drawer, on top of sales. Read-only —
/// rows are created by the register screen and the finance "mark taken" flow.
class CashMovement {
  final String id;
  final String shiftId;
  final String type; // DEPOSIT, WITHDRAWAL, EXPENSE
  final int amountMinorUnits;
  final String reason;
  final DateTime createdAt;

  /// Optional proof photo (compressed JPEG as base64), attached when the
  /// movement was recorded. Mostly used on debits as withdrawal evidence.
  final String? photo;

  /// Name of the user who recorded the movement, hydrated from the users
  /// table for the ledger view only; never persisted on the movement row.
  final String? userName;

  const CashMovement({
    required this.id,
    required this.shiftId,
    required this.type,
    required this.amountMinorUnits,
    required this.reason,
    required this.createdAt,
    this.photo,
    this.userName,
  });

  /// True when the movement adds cash to the drawer.
  bool get isDeposit => type == 'DEPOSIT';

  factory CashMovement.fromMap(Map<String, dynamic> map) {
    return CashMovement(
      id: map['id'] as String,
      shiftId: map['shift_id'] as String,
      type: map['type'] as String,
      amountMinorUnits: (map['amount_minor_units'] as num?)?.toInt() ?? 0,
      reason: (map['reason'] as String?) ?? '',
      createdAt: DateTime.parse(map['created_at'] as String),
      photo: map['photo'] as String?,
      userName: map['user_name'] as String?,
    );
  }
}
