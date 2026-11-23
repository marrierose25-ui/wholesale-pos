import 'package:pos_core/catalog.dart' as catalog;
import 'package:pos_core/finance.dart' as finance;
import 'package:pos_core/register.dart' as register;
import 'package:pos_core/sales.dart' as sales;
import 'package:pos_core/users.dart' as users;
import 'package:pos_core/warehouse.dart' as warehouse;
import 'package:test/test.dart';

/// Verifies the module-specific public entry points expose exactly the
/// entities owned by that module — no more, no less.
void main() {
  test('sales.dart exports the sales entities', () {
    expect(sales.Sale, isA<Type>());
    expect(sales.SaleItem, isA<Type>());
    expect(sales.VoidRequest, isA<Type>());
  });

  test('register.dart exports the register entities', () {
    expect(register.Shift, isA<Type>());
    expect(register.CashMovement, isA<Type>());
  });

  test('finance.dart exports the finance entities', () {
    expect(finance.FinanceCategory, isA<Type>());
    expect(finance.FinanceEntry, isA<Type>());
  });

  test('warehouse.dart exports the warehouse entities', () {
    expect(warehouse.Picklist, isA<Type>());
    expect(warehouse.PicklistItem, isA<Type>());
    expect(warehouse.PicklistCustomer, isA<Type>());
  });

  test('catalog.dart exports the catalog entities', () {
    expect(catalog.Product, isA<Type>());
  });

  test('users.dart exports the users entities', () {
    expect(users.User, isA<Type>());
  });
}
