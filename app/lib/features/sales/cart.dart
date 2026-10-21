import 'cart_item.dart';

class Cart {
  final List<CartItem> _items = [];
  int _discountPercent = 0;

  List<CartItem> get items => List.unmodifiable(_items);
  int get discountPercent => _discountPercent;

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

  void setDiscount(int percent) {
    if (percent < 0) percent = 0;
    if (percent > 100) percent = 100;
    _discountPercent = percent;
  }

  int get subtotalMinorUnits {
    return _items.fold(0, (sum, item) => sum + item.lineTotalMinorUnits);
  }

  int get discountMinorUnits {
    if (_discountPercent == 0) return 0;
    return ((subtotalMinorUnits * _discountPercent) / 100).round();
  }

  int get totalMinorUnits {
    return subtotalMinorUnits - discountMinorUnits;
  }

  void clear() {
    _items.clear();
    _discountPercent = 0;
  }
}
