class CartItem {
  final String id;
  final String name;
  final int unitPriceMinorUnits;
  int quantity;

  CartItem({
    required this.id,
    required this.name,
    required this.unitPriceMinorUnits,
    this.quantity = 1,
  });

  int get lineTotalMinorUnits => unitPriceMinorUnits * quantity;
}
