import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/features/sales/cart.dart';
import 'package:wholesale_pos_app/features/sales/cart_item.dart';

void main() {
  test('Empty cart totals to zero', () {
    final cart = Cart();
    expect(cart.subtotalMinorUnits, 0);
    expect(cart.totalMinorUnits, 0);
  });

  test('Adding items calculates correct subtotal', () {
    final cart = Cart();
    cart.addItem(
      CartItem(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantity: 2,
      ),
    ); // 9000.00
    cart.addItem(
      CartItem(id: '2', name: 'Sugar', unitPriceMinorUnits: 12000, quantity: 5),
    ); // 600.00

    expect(cart.subtotalMinorUnits, 960000); // 9600.00 ETB
    expect(cart.totalMinorUnits, 960000);
  });

  test('Adding the same item increases quantity', () {
    final cart = Cart();
    cart.addItem(
      CartItem(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantity: 1,
      ),
    );
    cart.addItem(
      CartItem(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantity: 2,
      ),
    );

    expect(cart.items.length, 1);
    expect(cart.items.first.quantity, 3);
    expect(cart.subtotalMinorUnits, 1350000); // 13500.00 ETB
  });

  test('Updating quantity to zero removes item', () {
    final cart = Cart();
    cart.addItem(
      CartItem(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantity: 1,
      ),
    );
    cart.updateQuantity('1', 0);

    expect(cart.items.isEmpty, isTrue);
  });

  test('Catalog items merge by product ID even if the name changes', () {
    final cart = Cart();
    cart.addItem(
      CartItem(
        id: '1',
        productId: 'prod-1',
        name: 'Flour 50kg',
        unitPriceMinorUnits: 450000,
      ),
    );
    cart.addItem(
      CartItem(
        id: '2',
        productId: 'prod-1',
        name: 'Flour (renamed)',
        unitPriceMinorUnits: 460000,
      ),
    );

    expect(cart.items.length, 1);
    expect(cart.items.first.quantity, 2);
    expect(cart.items.first.unitPriceMinorUnits, 450000);
  });
}
