import 'sale_item.dart';

class Sale {
  final String id;
  final String receiptNumber;
  final String cashierId;
  final String deviceId;
  final String? customerName;
  final String paymentMethod;
  final int subtotalMinorUnits;
  final int discountMinorUnits;
  final int totalMinorUnits;
  final int amountPaidMinorUnits;
  final int changeMinorUnits;
  final String status;
  final DateTime createdAt;
  final DateTime? syncedAt;

  final List<SaleItem> items;

  Sale({
    required this.id,
    required this.receiptNumber,
    required this.cashierId,
    required this.deviceId,
    this.customerName,
    this.paymentMethod = 'CASH',
    required this.subtotalMinorUnits,
    required this.discountMinorUnits,
    required this.totalMinorUnits,
    required this.amountPaidMinorUnits,
    required this.changeMinorUnits,
    this.status = 'COMPLETED',
    required this.createdAt,
    this.syncedAt,
    required this.items,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'receipt_number': receiptNumber,
      'cashier_id': cashierId,
      'device_id': deviceId,
      'customer_name': customerName,
      'payment_method': paymentMethod,
      'subtotal_minor_units': subtotalMinorUnits,
      'discount_minor_units': discountMinorUnits,
      'total_minor_units': totalMinorUnits,
      'amount_paid_minor_units': amountPaidMinorUnits,
      'change_minor_units': changeMinorUnits,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'synced_at': syncedAt?.toIso8601String(),
    };
  }
}
