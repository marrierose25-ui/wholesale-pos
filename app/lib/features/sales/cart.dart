import 'cart_item.dart';

class Cart {
  final List<CartItem> _items = [];

  List<CartItem> get items => List.unmodifiable(_items);

  /// Adds a line exactly as entered. Lines are never merged because each one
  /// keeps its own quantity description ("2 boxes" stays separate from
  /// "1 kunital") and possibly its own manual amount.
  void addItem(CartItem item) {
    _items.add(item);
  }

  void removeItem(String id) {
    _items.removeWhere((i) => i.id == id);
  }

  /// Replaces a line in place, keeping its position in the order.
  void replaceItem(CartItem item) {
    final index = _items.indexWhere((i) => i.id == item.id);
    if (index >= 0) _items[index] = item;
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
