import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SaleRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SaleRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('Saves a complete sale with items transactionally', () async {
    final now = DateTime.now();
    final saleId = 'sale-1';

    final sale = Sale(
      id: saleId,
      receiptNumber: 'REC-001',
      cashierId: 'user-1',
      deviceId: 'device-1',
      subtotalMinorUnits: 5000,
      discountMinorUnits: 0,
      totalMinorUnits: 5000,
      amountPaidMinorUnits: 10000,
      changeMinorUnits: 5000,
      createdAt: now,
      items: [
        SaleItem(
          id: 'item-1',
          saleId: saleId,
          productId: 'prod-1',
          productNameSnapshot: 'Sugar',
          unitPriceSnapshotMinorUnits: 5000,
          quantity: 1,
          lineTotalMinorUnits: 5000,
        ),
      ],
    );

    await repository.saveSale(sale);

    final sales = await db.query('sales');
    expect(sales.length, 1);

    final items = await db.query('sale_items');
    expect(items.length, 1);

    final logs = await db.query('audit_logs');
    expect(logs.length, 1);
  });

  test('getAllSales returns saved sales with items', () async {
    final now = DateTime.now();
    final sale = Sale(
      id: 'sale-2',
      receiptNumber: 'REC-002',
      cashierId: 'user-1',
      deviceId: 'device-1',
      subtotalMinorUnits: 1500,
      discountMinorUnits: 0,
      totalMinorUnits: 1500,
      amountPaidMinorUnits: 2000,
      changeMinorUnits: 500,
      createdAt: now,
      items: [
        SaleItem(
          id: 'item-2',
          saleId: 'sale-2',
          productId: 'prod-2',
          productNameSnapshot: 'Flour',
          unitPriceSnapshotMinorUnits: 1500,
          quantity: 1,
          lineTotalMinorUnits: 1500,
        ),
      ],
    );

    await repository.saveSale(sale);
    final fetchedSales = await repository.getAllSales();

    expect(fetchedSales.length, 1);
    expect(fetchedSales.first.receiptNumber, 'REC-002');
    expect(fetchedSales.first.items.length, 1);
    expect(fetchedSales.first.items.first.productNameSnapshot, 'Flour');
  });
}
