/// One line of a Warehouse Picklist: a product the warehouse is asked to pull
/// for a [Picklist]. `takenQty` rises from zero toward `requestedQty` as the
/// worker ticks items off, so the row is mutable and carries `updatedAt` — the
/// stamp the sync compares newest-wins.
///
/// Deliberately stores `productName` rather than a product foreign key: a
/// picklist is a fulfillment instruction, not a priced sale, and must survive
/// even if the saved-name row changes or is removed later.
///
/// The pricing fields (schema 21) are display-only value carried alongside the
/// instruction — `unit`, `unitPriceMinorUnits` and the computed
/// `lineTotalMinorUnits`. They never feed Sales or the drawer; a picklist line
/// is not a sale, it is a request with an optional price hint.
class PicklistItem {
  final String id;
  final String picklistId;
  final String productName;
  final int requestedQty;
  final int takenQty;

  /// Free-form unit of measure ("kg", "bag", "bottle"). Nullable so pre-21
  /// rows and quantity-only lines stay valid.
  final String? unit;

  /// Unit price in minor units (1/100 Birr). 0 when no price was entered.
  final int unitPriceMinorUnits;

  /// `unitPriceMinorUnits * requestedQty`, computed on the create form and
  /// stored so the directory / detail can show a line value without recomputing.
  final int lineTotalMinorUnits;
  final DateTime updatedAt;

  PicklistItem({
    required this.id,
    required this.picklistId,
    required this.productName,
    required this.requestedQty,
    required this.takenQty,
    required this.updatedAt,
    this.unit,
    this.unitPriceMinorUnits = 0,
    this.lineTotalMinorUnits = 0,
  });

  /// True once the worker has taken everything the line asked for.
  bool get isFulfilled => takenQty >= requestedQty;

  /// Returns a copy with the fulfillment progress updated. Used by the
  /// Warehouse screen when a worker ticks an item off; every other field
  /// (id, parent, requested, pricing) is immutable.
  PicklistItem copyWith({int? takenQty, DateTime? updatedAt}) {
    return PicklistItem(
      id: id,
      picklistId: picklistId,
      productName: productName,
      requestedQty: requestedQty,
      takenQty: takenQty ?? this.takenQty,
      updatedAt: updatedAt ?? this.updatedAt,
      unit: unit,
      unitPriceMinorUnits: unitPriceMinorUnits,
      lineTotalMinorUnits: lineTotalMinorUnits,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'picklist_id': picklistId,
      'product_name': productName,
      'requested_qty': requestedQty,
      'taken_qty': takenQty,
      'unit': unit,
      'unit_price_minor_units': unitPriceMinorUnits,
      'line_total_minor_units': lineTotalMinorUnits,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory PicklistItem.fromMap(Map<String, dynamic> map) {
    return PicklistItem(
      id: map['id'] as String,
      picklistId: map['picklist_id'] as String,
      productName: map['product_name'] as String,
      requestedQty: (map['requested_qty'] as num?)?.toInt() ?? 0,
      takenQty: (map['taken_qty'] as num?)?.toInt() ?? 0,
      unit: map['unit'] as String?,
      unitPriceMinorUnits:
          (map['unit_price_minor_units'] as num?)?.toInt() ?? 0,
      lineTotalMinorUnits:
          (map['line_total_minor_units'] as num?)?.toInt() ?? 0,
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }
}
