import 'cart_item.dart';

class Cart {
  final List<CartItem> _items = [];

  List<CartItem> get items => List.unmodifiable(_items);

  void addItem(CartItem item) {
    final existingIndex = _items.indexWhere(
      (i) =>
          i.name == item.name &&
          i.unitPriceMinorUnits == item.unitPriceMinorUnits,
    );
    if (existingIndex >= 0) {
      _items[existingIndex].quantity += item.quantity;
    } else {
      _items.add(item);
    }
  }

  void removeItem(String id) {
    _items.removeWhere((i) => i.id == id);
  }

  void updateQuantity(String id, int newQuantity) {
    if (newQuantity <= 0) {
      removeItem(id);
      return;
    }
    final index = _items.indexWhere((i) => i.id == id);
    if (index >= 0) {
      _items[index].quantity = newQuantity;
    }
  }

  int get subtotalMinorUnits {
    return _items.fold(0, (sum, item) => sum + item.lineTotalMinorUnits);
  }

  int get discountMinorUnits => 0;

  int get totalMinorUnits => subtotalMinorUnits;

  void clear() {
    _items.clear();
  }
}
