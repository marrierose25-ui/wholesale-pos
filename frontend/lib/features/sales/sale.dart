import 'sale_item.dart';

class Sale {
  final String id;
  final String receiptNumber;
  final String cashierId;
  final String deviceId;
  final String shiftId;
  final String? customerName;
  final String paymentMethod;
  final int subtotalMinorUnits;
  final int discountMinorUnits;
  final int totalMinorUnits;
  final int amountPaidMinorUnits;
  final int changeMinorUnits;
  final String status;
  final String? voidReason;
  final DateTime? voidedAt;
  final String? voidedBy;
  final String? voidedShiftId;
  final DateTime createdAt;
  final DateTime? syncedAt;

  /// Username of the cashier who recorded the sale. Hydrated from the users
  /// table for display only; never persisted on the sale row itself.
  final String? cashierName;

  /// True when a cashier has filed a not-yet-actioned void request against this
  /// sale. Hydrated from `void_requests` for display only; never persisted on
  /// the sale row itself.
  final bool hasPendingVoidRequest;

  final List<SaleItem> items;

  Sale({
    required this.id,
    required this.receiptNumber,
    required this.cashierId,
    required this.deviceId,
    required this.shiftId,
    this.customerName,
    this.paymentMethod = 'CASH',
    required this.subtotalMinorUnits,
    required this.discountMinorUnits,
    required this.totalMinorUnits,
    required this.amountPaidMinorUnits,
    required this.changeMinorUnits,
    this.status = 'COMPLETED',
    this.voidReason,
    this.voidedAt,
    this.voidedBy,
    this.voidedShiftId,
    required this.createdAt,
    this.syncedAt,
    this.cashierName,
    this.hasPendingVoidRequest = false,
    required this.items,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'receipt_number': receiptNumber,
      'cashier_id': cashierId,
      'device_id': deviceId,
      'shift_id': shiftId,
      'customer_name': customerName,
      'payment_method': paymentMethod,
      'subtotal_minor_units': subtotalMinorUnits,
      'discount_minor_units': discountMinorUnits,
      'total_minor_units': totalMinorUnits,
      'amount_paid_minor_units': amountPaidMinorUnits,
      'change_minor_units': changeMinorUnits,
      'status': status,
      'void_reason': voidReason,
      'voided_at': voidedAt?.toIso8601String(),
      'voided_by': voidedBy,
      'voided_shift_id': voidedShiftId,
      'created_at': createdAt.toIso8601String(),
      'synced_at': syncedAt?.toIso8601String(),
    };
  }
}
