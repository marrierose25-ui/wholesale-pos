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

    await db.insert('users', {
      'id': 'owner-1',
      'username': 'test',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
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
        cashierId: 'owner-1',
        deviceId: 'device-1',
        shiftId: 'shift-1',
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

      expect(await repository.getTodayRevenue(), 5000);

      await repository.voidSale(
        'sale-to-void',
        'REC-VOID',
        'owner-1',
        'mistake',
      );

      expect(await repository.getTodayRevenue(), 0);

      final sales = await repository.getAllSales();
      expect(sales.length, 1);
      expect(sales.first.status, 'VOIDED');

      final logs = await repository.getAuditLogs();
      expect(logs.length, 2);
      expect(logs.first['action'], 'SALE_VOIDED');
    },
  );
}
