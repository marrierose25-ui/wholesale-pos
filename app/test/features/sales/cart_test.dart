import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/features/sales/cart.dart';
import 'package:wholesale_pos_app/features/sales/cart_item.dart';

void main() {
  CartItem numericLine({
    required String id,
    required String name,
    required int unitPriceMinorUnits,
    required int quantityMilliunits,
    String quantityText = '',
  }) {
    return CartItem(
      id: id,
      name: name,
      unitPriceMinorUnits: unitPriceMinorUnits,
      quantityText: quantityText.isEmpty ? '$quantityMilliunits' : quantityText,
      billingQuantityMilliunits: quantityMilliunits,
    );
  }

  test('Empty cart totals to zero', () {
    final cart = Cart();
    expect(cart.subtotalMinorUnits, 0);
    expect(cart.totalMinorUnits, 0);
  });

  test('Numeric quantity lines calculate exact integer totals', () {
    final cart = Cart();
    cart.addItem(
      numericLine(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantityMilliunits: 2000,
        quantityText: '2',
      ),
    ); // 9000.00
    cart.addItem(
      numericLine(
        id: '2',
        name: 'Sugar',
        unitPriceMinorUnits: 12000,
        quantityMilliunits: 5000,
        quantityText: '5',
      ),
    ); // 600.00

    expect(cart.subtotalMinorUnits, 960000); // 9600.00 Br
    expect(cart.totalMinorUnits, 960000);
  });

  test('Fractional billing quantities round half-up exactly', () {
    // 500 minor units x 1.5 = 750 exactly.
    expect(
      numericLine(
        id: 'a',
        name: 'Oil',
        unitPriceMinorUnits: 500,
        quantityMilliunits: 1500,
        quantityText: '1.5',
      ).lineTotalMinorUnits,
      750,
    );
    // 333 x 0.111 = 36.963 -> 37 (round half up via integer math).
    expect(
      numericLine(
        id: 'b',
        name: 'Salt',
        unitPriceMinorUnits: 333,
        quantityMilliunits: 111,
        quantityText: '0.111',
      ).lineTotalMinorUnits,
      37,
    );
    // 1005 x 0.1 = 100.5 -> 101 (ties round up, never banker's rounding).
    expect(
      numericLine(
        id: 'c',
        name: 'Rice',
        unitPriceMinorUnits: 1005,
        quantityMilliunits: 100,
        quantityText: '0.1',
      ).lineTotalMinorUnits,
      101,
    );
  });

  test('Manual line totals keep descriptive quantities as text', () {
    final cart = Cart();
    // "2 boxes and 1 piece" is a description, never a number. The cashier
    // entered the line amount manually.
    cart.addItem(
      CartItem(
        id: '1',
        name: 'Berbere',
        unitPriceMinorUnits: 25000,
        quantityText: '2 boxes and 1 piece',
        manualLineTotalMinorUnits: 137500,
      ),
    );

    expect(cart.items.first.usesManualLineTotal, isTrue);
    expect(cart.items.first.lineTotalMinorUnits, 137500);
    expect(cart.subtotalMinorUnits, 137500);
  });

  test('Identical descriptions stay as separate lines (no merging)', () {
    final cart = Cart();
    cart.addItem(
      numericLine(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantityMilliunits: 1000,
        quantityText: '1',
      ),
    );
    cart.addItem(
      numericLine(
        id: '2',
        name: 'Flour',
        unitPriceMinorUnits: 460000,
        quantityMilliunits: 1000,
        quantityText: '1',
      ),
    );

    // Each entered line is kept exactly as the cashier described it.
    expect(cart.items.length, 2);
    expect(cart.items.first.unitPriceMinorUnits, 450000);
    expect(cart.items.last.unitPriceMinorUnits, 460000);
    expect(cart.subtotalMinorUnits, 910000);
  });

  test('replaceItem edits a line in place', () {
    final cart = Cart();
    cart.addItem(
      numericLine(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantityMilliunits: 1000,
        quantityText: '1',
      ),
    );
    cart.addItem(
      numericLine(
        id: '2',
        name: 'Sugar',
        unitPriceMinorUnits: 12000,
        quantityMilliunits: 2000,
        quantityText: '2',
      ),
    );

    cart.replaceItem(
      numericLine(
        id: '2',
        name: 'Sugar',
        unitPriceMinorUnits: 13000,
        quantityMilliunits: 3000,
        quantityText: '3',
      ),
    );

    expect(cart.items.length, 2);
    expect(cart.items.last.quantityText, '3');
    expect(cart.items.last.lineTotalMinorUnits, 39000);
  });

  test('removeItem deletes only the targeted line', () {
    final cart = Cart();
    cart.addItem(
      numericLine(
        id: '1',
        name: 'Flour',
        unitPriceMinorUnits: 450000,
        quantityMilliunits: 1000,
        quantityText: '1',
      ),
    );
    cart.addItem(
      numericLine(
        id: '2',
        name: 'Sugar',
        unitPriceMinorUnits: 12000,
        quantityMilliunits: 2000,
        quantityText: '2',
      ),
    );

    cart.removeItem('1');

    expect(cart.items.length, 1);
    expect(cart.items.first.name, 'Sugar');
  });

  test('A line without quantity or manual total is a programming error', () {
    final item = CartItem(
      id: '1',
      name: 'Flour',
      unitPriceMinorUnits: 450000,
      quantityText: 'later',
    );

    expect(() => item.lineTotalMinorUnits, throwsStateError);
  });
}
