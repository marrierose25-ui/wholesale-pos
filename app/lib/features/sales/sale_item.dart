class SaleItem {
  final String id;
  final String saleId;
  final String productId;
  final String productNameSnapshot;
  final int unitPriceSnapshotMinorUnits;
  final int quantity;
  final int lineDiscountMinorUnits;
  final int lineTotalMinorUnits;

  SaleItem({
    required this.id,
    required this.saleId,
    required this.productId,
    required this.productNameSnapshot,
    required this.unitPriceSnapshotMinorUnits,
    required this.quantity,
    this.lineDiscountMinorUnits = 0,
    required this.lineTotalMinorUnits,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sale_id': saleId,
      'product_id': productId,
      'product_name_snapshot': productNameSnapshot,
      'unit_price_snapshot_minor_units': unitPriceSnapshotMinorUnits,
      'quantity': quantity,
      'line_discount_minor_units': lineDiscountMinorUnits,
      'line_total_minor_units': lineTotalMinorUnits,
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
      quantity: map['quantity'] as int,
      lineDiscountMinorUnits: map['line_discount_minor_units'] as int,
      lineTotalMinorUnits: map['line_total_minor_units'] as int,
    );
  }
}
