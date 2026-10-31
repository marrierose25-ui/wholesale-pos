import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/utils/date_range.dart';
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
      'id': 'cashier-1',
      'username': 'test_cashier',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'cashier-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSale({
    required String id,
    required int totalMinorUnits,
    required DateTime createdAt,
    String product = 'Sugar',
    String paymentMethod = 'CASH',
  }) async {
    await repository.saveSale(
      Sale(
        id: id,
        receiptNumber: 'REC-$id',
        cashierId: 'cashier-1',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        paymentMethod: paymentMethod,
        subtotalMinorUnits: totalMinorUnits,
        discountMinorUnits: 0,
        totalMinorUnits: totalMinorUnits,
        amountPaidMinorUnits: totalMinorUnits,
        changeMinorUnits: 0,
        createdAt: createdAt,
        items: [
          SaleItem(
            id: 'item-$id',
            saleId: id,
            productId: 'MANUAL',
            productNameSnapshot: product,
            unitPriceSnapshotMinorUnits: totalMinorUnits,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: totalMinorUnits,
          ),
        ],
      ),
    );
  }

  test('Dashboard stats split revenue by payment method', () async {
    await seedSale(
      id: 'sale-1',
      totalMinorUnits: 5000,
      createdAt: DateTime.now(),
    );
    await seedSale(
      id: 'sale-2',
      totalMinorUnits: 3000,
      createdAt: DateTime.now(),
      paymentMethod: 'BANK',
    );

    final stats = await repository.getDashboardStats();
    expect(stats['revenue'], 8000);
    expect(stats['sales_count'], 2);
    expect(stats['cash_revenue'], 5000);
    expect(stats['bank_revenue'], 3000);
    expect(stats['average_sale'], 4000);
  });

  test(
    'A loan sale is recorded but excluded from every revenue figure',
    () async {
      await seedSale(
        id: 'sale-cash',
        totalMinorUnits: 5000,
        createdAt: DateTime.now(),
      );
      await seedSale(
        id: 'sale-loan',
        totalMinorUnits: 4000,
        createdAt: DateTime.now(),
        paymentMethod: 'LOAN',
        product: 'Flour',
      );

      // The loan is a real, retrievable sale.
      final sales = await repository.getSales();
      expect(sales.map((s) => s.id), contains('sale-loan'));

      final stats = await repository.getDashboardStats();
      // Only the cash sale counts toward money; the loan contributes nothing.
      expect(stats['revenue'], 5000);
      expect(stats['cash_revenue'], 5000);
      expect(stats['bank_revenue'], 0);
      // The loan is still a completed sale, so the dashboard counts it.
      expect(stats['sales_count'], 2);

      // The trend and the product mix both drop the loan line too.
      final trend = await repository.getRevenueTrend(DateRange.today());
      final dayTotal = trend.fold<int>(0, (a, r) => a + (r['total'] as int));
      expect(dayTotal, 5000);
      final products = await repository.getProductSalesSummary(
        period: DateRange.today(),
      );
      final productRevenue = products.fold<int>(
        0,
        (a, r) => a + (r['total_revenue'] as int),
      );
      expect(productRevenue, 5000);
      expect(
        products.map((r) => r['product_name_snapshot']),
        isNot(contains('Flour')),
      );
    },
  );

  test('Dashboard periods exclude older sales by date filtering', () async {
    // Two days ago is outside today, yesterday, and (when today is Monday)
    // this week — but inside all time.
    final old = DateTime.now().subtract(const Duration(days: 2));
    await seedSale(id: 'sale-old', totalMinorUnits: 5000, createdAt: old);
    await seedSale(
      id: 'sale-new',
      totalMinorUnits: 3000,
      createdAt: DateTime.now(),
    );

    final today = await repository.getDashboardStats(period: DateRange.today());
    expect(today['revenue'], 3000);
    expect(today['sales_count'], 1);

    final yesterday = await repository.getDashboardStats(
      period: DateRange.yesterday(),
    );
    expect(yesterday['revenue'], 0);

    final yesterdayCustom = await repository.getDashboardStats(
      period: DateRange.custom(
        DateTime.now().subtract(const Duration(days: 2)),
        DateTime.now(),
      ),
    );
    expect(yesterdayCustom['revenue'], 8000);

    final allTime = await repository.getDashboardStats(
      period: DateRange.allTime(),
    );
    expect(allTime['revenue'], 8000);
  });

  test(
    'Product summary sums milliunit quantities and filters by period',
    () async {
      final old = DateTime.now().subtract(const Duration(days: 2));
      await seedSale(
        id: 'p-old',
        totalMinorUnits: 1000,
        createdAt: old,
        product: 'Sugar',
      );
      await seedSale(
        id: 'p-1',
        totalMinorUnits: 5000,
        createdAt: DateTime.now(),
        product: 'Sugar',
      );
      await seedSale(
        id: 'p-2',
        totalMinorUnits: 3000,
        createdAt: DateTime.now(),
        product: 'Sugar',
      );

      final todaySummary = await repository.getProductSalesSummary(
        period: DateRange.today(),
      );
      expect(todaySummary.length, 1);
      expect(todaySummary.first['product_name_snapshot'], 'Sugar');
      expect(todaySummary.first['total_qty_milliunits'], 2000);
      expect(todaySummary.first['line_count'], 2);
      expect(todaySummary.first['total_revenue'], 8000);

      final allSummary = await repository.getProductSalesSummary();
      expect(allSummary.first['total_qty_milliunits'], 3000);
      expect(allSummary.first['line_count'], 3);
      expect(allSummary.first['total_revenue'], 9000);
    },
  );

  test('Manual-amount lines report no numeric quantity', () async {
    await repository.saveSale(
      Sale(
        id: 'sale-manual',
        receiptNumber: 'REC-MANUAL',
        cashierId: 'cashier-1',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        subtotalMinorUnits: 2500,
        discountMinorUnits: 0,
        totalMinorUnits: 2500,
        amountPaidMinorUnits: 2500,
        changeMinorUnits: 0,
        createdAt: DateTime.now(),
        items: [
          SaleItem(
            id: 'item-manual',
            saleId: 'sale-manual',
            productId: 'MANUAL',
            productNameSnapshot: 'Mixed Boxes',
            unitPriceSnapshotMinorUnits: 2500,
            quantityText: '2 boxes and 1 piece',
            billingQuantityMilliunits: null,
            lineTotalMinorUnits: 2500,
          ),
        ],
      ),
    );

    final summary = await repository.getProductSalesSummary();
    expect(summary.single['product_name_snapshot'], 'Mixed Boxes');
    expect(summary.single['total_qty_milliunits'], 0);
    expect(summary.single['line_count'], 1);
    expect(summary.single['total_revenue'], 2500);
  });

  test('Cashier performance reports sales counts and revenue', () async {
    await seedSale(id: 'c-1', totalMinorUnits: 5000, createdAt: DateTime.now());
    await seedSale(id: 'c-2', totalMinorUnits: 3000, createdAt: DateTime.now());

    final performance = await repository.getCashierPerformance();
    expect(performance.length, 1);
    expect(performance.first['username'], 'test_cashier');
    expect(performance.first['total_sales'], 2);
    expect(performance.first['total_revenue'], 8000);
  });
}
