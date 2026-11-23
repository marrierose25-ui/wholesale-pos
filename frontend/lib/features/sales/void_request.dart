import 'sale.dart';

/// A cashier's not-yet-actioned request to void a sale. The sale stays
/// `COMPLETED` (and keeps counting as revenue) until an owner approves or
/// rejects the request. Mirrors the pending-refund pattern adapted from the
/// DineFlow reference.
class VoidRequest {
  static const String statusPending = 'PENDING';
  static const String statusApproved = 'APPROVED';
  static const String statusRejected = 'REJECTED';

  final String id;
  final String saleId;
  final String requestedBy;
  final String? requesterName;
  final String reason;
  final String status;
  final DateTime createdAt;
  final String? decidedBy;
  final DateTime? decidedAt;

  /// The sale this request targets, hydrated for display only.
  final Sale? sale;

  VoidRequest({
    required this.id,
    required this.saleId,
    required this.requestedBy,
    this.requesterName,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.decidedBy,
    this.decidedAt,
    this.sale,
  });

  bool get isPending => status == statusPending;
}
