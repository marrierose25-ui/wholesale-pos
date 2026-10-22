import '../../core/utils/money_utils.dart';

class CartItem {
  final String id;
  final String productId;
  final String name;
  final int unitPriceMinorUnits;

  /// The quantity description exactly as typed, e.g. "2 boxes and 1 piece".
  final String quantityText;

  /// Numeric billing quantity in milliunits (1500 = 1.5). Null when the line
  /// total was entered manually.
  final int? billingQuantityMilliunits;

  /// Manually entered line amount. When set, it overrides the
  /// price x quantity calculation so descriptive quantities are never
  /// silently turned into numbers.
  final int? manualLineTotalMinorUnits;

  final String? notes;

  CartItem({
    required this.id,
    this.productId = 'MANUAL',
    required this.name,
    required this.unitPriceMinorUnits,
    required this.quantityText,
    this.billingQuantityMilliunits,
    this.manualLineTotalMinorUnits,
    this.notes,
  });

  bool get usesManualLineTotal => manualLineTotalMinorUnits != null;

  int get lineTotalMinorUnits {
    if (manualLineTotalMinorUnits != null) return manualLineTotalMinorUnits!;
    final milliunits = billingQuantityMilliunits;
    if (milliunits == null) {
      throw StateError('Cart item needs a billing quantity or manual total.');
    }
    final total = MoneyUtils.tryLineTotalMinorUnits(
      unitPriceMinorUnits,
      milliunits,
    );
    if (total == null) {
      throw StateError('Line total is too large.');
    }
    return total;
  }
}
