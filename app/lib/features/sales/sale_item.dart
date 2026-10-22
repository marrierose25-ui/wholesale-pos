class SaleItem {
  final String id;
  final String saleId;
  final String productId;
  final String productNameSnapshot;
  final int unitPriceSnapshotMinorUnits;

  /// The quantity exactly as the cashier typed it, e.g. "2 boxes and 1 piece".
  /// Stored verbatim so history always shows what was actually entered.
  final String quantityText;

  /// The numeric quantity used for billing, in milliunits (1500 = 1.5).
  /// Null when the cashier entered the line amount manually because the
  /// quantity could not be interpreted as a number.
  final int? billingQuantityMilliunits;

  final int lineDiscountMinorUnits;
  final int lineTotalMinorUnits;
  final String? notes;

  SaleItem({
    required this.id,
    required this.saleId,
    required this.productId,
    required this.productNameSnapshot,
    required this.unitPriceSnapshotMinorUnits,
    required this.quantityText,
    this.billingQuantityMilliunits,
    this.lineDiscountMinorUnits = 0,
    required this.lineTotalMinorUnits,
    this.notes,
  });

  bool get hasManualLineTotal => billingQuantityMilliunits == null;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sale_id': saleId,
      'product_id': productId,
      'product_name_snapshot': productNameSnapshot,
      'unit_price_snapshot_minor_units': unitPriceSnapshotMinorUnits,
      'quantity_text': quantityText,
      'billing_quantity_milliunits': billingQuantityMilliunits,
      'line_discount_minor_units': lineDiscountMinorUnits,
      'line_total_minor_units': lineTotalMinorUnits,
      'notes': notes,
    };
  }

  factory SaleItem.fromMap(Map<String, dynamic> map) {
    return SaleItem(
      id: map['id'] as String,
      saleId: map['sale_id'] as String,
      productId: map['product_id'] as String,
      productNameSnapshot: map['product_name_snapshot'] as String,
      unitPriceSnapshotMinorUnits:
          map['unit_price_snapshot_minor_units'] as int,
      quantityText: map['quantity_text'] as String,
      billingQuantityMilliunits: map['billing_quantity_milliunits'] as int?,
      lineDiscountMinorUnits: map['line_discount_minor_units'] as int,
      lineTotalMinorUnits: map['line_total_minor_units'] as int,
      notes: map['notes'] as String?,
    );
  }
}
