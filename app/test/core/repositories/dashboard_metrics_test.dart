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
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': now,
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
      'created_at': now,
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
      'opened_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSale(
    String id,
    int total,
    DateTime createdAt, {
    String status = 'COMPLETED',
    String cashierId = 'owner-1',
  }) async {
    await repository.saveSale(
      Sale(
        id: id,
        receiptNumber: 'REC-$id',
        cashierId: cashierId,
        deviceId: 'device-1',
        shiftId: 'shift-1',
        subtotalMinorUnits: total,
        discountMinorUnits: 0,
        totalMinorUnits: total,
        amountPaidMinorUnits: total,
        changeMinorUnits: 0,
        status: status,
        createdAt: createdAt,
        items: [
          SaleItem(
            id: 'item-$id',
            saleId: id,
            productId: 'MANUAL',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: total,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: total,
          ),
        ],
      ),
    );
  }

  test('getRevenueTrend groups completed revenue per calendar day', () async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 10);
    final yesterday = today.subtract(const Duration(days: 1));

    await seedSale('t1', 3000, today);
    await seedSale('t2', 3000, today.add(const Duration(hours: 1)));
    await seedSale('y1', 5000, yesterday);

    final trend = await repository.getRevenueTrend(
      DateRange.custom(yesterday, today),
    );

    final byDay = {for (final r in trend) r['day'] as String: r};
    final yesterdayKey =
        '${yesterday.year.toString().padLeft(4, '0')}-'
        '${yesterday.month.toString().padLeft(2, '0')}-'
        '${yesterday.day.toString().padLeft(2, '0')}';
    final todayKey =
        '${today.year.toString().padLeft(4, '0')}-'
        '${today.month.toString().padLeft(2, '0')}-'
        '${today.day.toString().padLeft(2, '0')}';

    expect(byDay[yesterdayKey]!['total'], 5000);
    expect(byDay[yesterdayKey]!['count'], 1);
    expect(byDay[todayKey]!['total'], 6000);
    expect(byDay[todayKey]!['count'], 2);

    // Oldest to newest.
    expect(trend.first['day'], yesterdayKey);
    expect(trend.last['day'], todayKey);
  });

  test('getRevenueTrend excludes voided sales', () async {
    final now = DateTime.now();
    await seedSale('v1', 4000, now, status: 'VOIDED');
    await seedSale('c1', 2000, now);

    final trend = await repository.getRevenueTrend(DateRange.today());
    expect(trend.single['total'], 2000);
    expect(trend.single['count'], 1);
  });

  test('dashboard stats report void and pending-request counts', () async {
    final now = DateTime.now();
    await seedSale('s1', 5000, now);
    await seedSale('s2', 5000, now);

    var stats = await repository.getDashboardStats(period: DateRange.today());
    expect(stats['revenue'], 10000);
    expect(stats['sales_count'], 2);
    expect(stats['void_count'], 0);
    expect(stats['pending_void_requests'], 0);

    // One cashier requests a void: pending count rises, revenue unchanged.
    await repository.requestVoid('s1', 'cashier-1', 'wrong price');
    stats = await repository.getDashboardStats(period: DateRange.today());
    expect(stats['revenue'], 10000);
    expect(stats['pending_void_requests'], 1);
    expect(stats['void_count'], 0);

    // Owner approves: it becomes a void, pending clears.
    final requestId = (await repository.getPendingVoidRequests()).first.id;
    await repository.approveVoidRequest(requestId, 'owner-1');
    stats = await repository.getDashboardStats(period: DateRange.today());
    expect(stats['revenue'], 5000);
    expect(stats['void_count'], 1);
    expect(stats['pending_void_requests'], 0);
  });
}
