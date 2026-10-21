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
    'Calculates today revenue, product summary, and cashier performance',
    () async {
      final now = DateTime.now();

      // Create two sales
      final sale1 = Sale(
        id: 'sale-1',
        receiptNumber: 'REC-001',
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
            id: 'item-1',
            saleId: 'sale-1',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 5000,
            quantity: 1,
            lineTotalMinorUnits: 5000,
          ),
        ],
      );
      final sale2 = Sale(
        id: 'sale-2',
        receiptNumber: 'REC-002',
        cashierId: 'cashier-1',
        deviceId: 'device-1',
        subtotalMinorUnits: 3000,
        discountMinorUnits: 0,
        totalMinorUnits: 3000,
        amountPaidMinorUnits: 3000,
        changeMinorUnits: 0,
        createdAt: now,
        items: [
          SaleItem(
            id: 'item-2',
            saleId: 'sale-2',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 3000,
            quantity: 1,
            lineTotalMinorUnits: 3000,
          ),
        ],
      );

      await repository.saveSale(sale1);
      await repository.saveSale(sale2);

      // Insert user manually since foreign keys aren't strictly enforced on this test setup
      await db.insert('users', {
        'id': 'cashier-1',
        'username': 'test_cashier',
        'password_hash': 'hash',
        'role': 'CASHIER',
        'is_active': 1,
        'created_at': now.toIso8601String(),
      });

      final todayRevenue = await repository.getTodayRevenue();
      expect(todayRevenue, 8000);

      final productSummary = await repository.getProductSalesSummary();
      expect(productSummary.length, 1);
      expect(productSummary.first['product_name_snapshot'], 'Sugar');
      expect(productSummary.first['total_qty'], 2);
      expect(productSummary.first['total_revenue'], 8000);

      final cashierPerformance = await repository.getCashierPerformance();
      expect(cashierPerformance.length, 1);
      expect(cashierPerformance.first['username'], 'test_cashier');
      expect(cashierPerformance.first['total_sales'], 2);
      expect(cashierPerformance.first['total_revenue'], 8000);
    },
  );
}
