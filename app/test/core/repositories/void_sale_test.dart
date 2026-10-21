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

  test(
    'Voiding a sale updates status and removes from revenue reports',
    () async {
      final now = DateTime.now();
      final sale = Sale(
        id: 'sale-to-void',
        receiptNumber: 'REC-VOID',
        cashierId: 'cashier-1',
        deviceId: 'device-1',
        subtotalMinorUnits: 5000,
        discountMinorUnits: 0,
        totalMinorUnits: 5000,
        amountPaidMinorUnits: 5000,
        changeMinorUnits: 0,
        createdAt: now,
        items: [
          SaleItem(
            id: 'item-v',
            saleId: 'sale-to-void',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 5000,
            quantity: 1,
            lineTotalMinorUnits: 5000,
          ),
        ],
      );

      await repository.saveSale(sale);

      // Check it's in reports initially
      expect(await repository.getTodayRevenue(), 5000);

      // Void it
      await repository.voidSale('sale-to-void', 'REC-VOID', 'owner-1');

      // Check reports are now 0
      expect(await repository.getTodayRevenue(), 0);

      // Check the sale still exists but is marked VOIDED
      final sales = await repository.getAllSales();
      expect(sales.length, 1);
      expect(sales.first.status, 'VOIDED');

      // Check Audit Logs
      final logs = await repository.getAuditLogs();
      expect(logs.length, 2); // SALE_COMPLETED and SALE_VOIDED
      expect(logs.first['action'], 'SALE_VOIDED');
    },
  );
}
