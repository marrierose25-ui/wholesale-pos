import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/finance_repository.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_entry.dart';
import 'package:wholesale_pos_app/core/sync/sync_outbox_repository.dart';
import 'package:wholesale_pos_app/core/utils/date_range.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

/// The training account exists so a new cashier can practise on the shop's own
/// products and people. Practice money must never become the shop's money: these
/// tests pin both halves of that rule — nothing the demo touches is queued for
/// the cloud, and nothing the demo already left in this till's SQLite is
/// reported as a real taking.
///
/// The second half matters more than it looks: one till keeps exactly ONE open
/// shift and every login shares it, so a practice sale is booked onto the real
/// drawer's session. Without the exclusion the cashier counting the drawer would
/// be short by every sale the trainee rang up.
void main() {
  late Database db;
  late SaleRepository sales;
  late ShiftRepository shifts;
  late FinanceRepository finance;
  late SyncOutboxRepository outbox;

  final now = DateTime.now().toIso8601String();

  Future<void> insertUser(
    String id,
    String username,
    String role, {
    bool isDemo = false,
    List<String> permissions = const [],
  }) async {
    await db.insert('users', {
      'id': id,
      'username': username,
      'password_hash': 'x',
      'salt': 'x',
      'role': role,
      'is_active': 1,
      'is_demo': isDemo ? 1 : 0,
      // The demo account is a CASHIER, so Money Tracking only opens for it when
      // the owner ticks it — exactly how a shop lets a trainee practise.
      'permissions': jsonEncode(permissions),
      'created_at': now,
    });
  }

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    sales = SaleRepository(db);
    shifts = ShiftRepository(db);
    finance = FinanceRepository(db);
    outbox = SyncOutboxRepository(db);

    await insertUser('owner-1', 'owner', 'OWNER');
    await insertUser('cashier-1', 'kebede', 'CASHIER');
    await insertUser(
      'demo-1',
      'demo',
      'CASHIER',
      isDemo: true,
      permissions: ['pos', 'finance'],
    );
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    // The one open shift of the till, opened by the real owner and shared by
    // everyone who logs in — including the demo account.
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
    int total, {
    required String cashierId,
    String productId = 'prod-1',
    String productName = 'Sugar',
  }) {
    return sales.saveSale(
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
        createdAt: DateTime.now(),
        items: [
          SaleItem(
            id: 'item-$id',
            saleId: id,
            productId: productId,
            productNameSnapshot: productName,
            unitPriceSnapshotMinorUnits: total,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: total,
          ),
        ],
      ),
    );
  }

  /// Queued rows for one entity type. Reading the outbox directly is the point
  /// of these tests: a demo row that never got queued is invisible everywhere.
  Future<List<Map<String, Object?>>> queued(String entityType) {
    return db.query(
      'sync_outbox',
      columns: ['entity_id', 'operation'],
      where: 'entity_type = ?',
      whereArgs: [entityType],
    );
  }

  group('the outbox refuses practice money', () {
    test('a demo sale is kept by the till and queued for nothing', () async {
      await seedSale('demo-sale', 10000, cashierId: 'demo-1');

      // The sale IS written: the trainee needs their own history to learn on.
      final local = await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: ['demo-sale'],
      );
      expect(local, hasLength(1));
      expect(await queued(SyncEntities.sale), isEmpty);
      expect(await outbox.pendingCount(), 0);
    });

    test('a real cashier on the same shift still queues', () async {
      await seedSale('real-sale', 10000, cashierId: 'cashier-1');

      final entries = await queued(SyncEntities.sale);
      expect(entries, hasLength(1));
      expect(entries.single['entity_id'], 'real-sale');
    });

    test(
      'a demo void request queues neither the sale nor the request',
      () async {
        await seedSale('demo-sale', 10000, cashierId: 'demo-1');
        await sales.requestVoid('demo-sale', 'demo-1', 'pressed wrong key');

        expect(await queued(SyncEntities.sale), isEmpty);
        expect(await queued(SyncEntities.voidRequest), isEmpty);
      },
    );

    test(
      'a demo cash movement stays local while an owner top-up syncs',
      () async {
        await shifts.addCashMovement(
          'shift-1',
          'DEPOSIT',
          5000,
          'practice float',
          userId: 'demo-1',
        );
        await shifts.addCashMovement(
          'shift-1',
          'DEPOSIT',
          1000,
          'real float',
          userId: 'owner-1',
        );

        final movements = await queued(SyncEntities.cashMovement);
        expect(movements, hasLength(1));
        final reason = await db.query(
          'cash_movements',
          columns: ['reason'],
          where: 'id = ?',
          whereArgs: [movements.single['entity_id']],
        );
        expect(reason.single['reason'], 'real float');
      },
    );

    test('a shift the demo opened is not queued', () async {
      await db.delete('shifts'); // one open shift per till; start clean
      await shifts.openShift('demo-1', 500);

      expect(await queued(SyncEntities.shift), isEmpty);
      final open = await shifts.getActiveShift();
      expect(open, isNotNull);
      expect(open!.cashierId, 'demo-1');
    });

    test('a collection the demo completes keeps both of its rows', () async {
      final category = await finance.createCategory(
        ownerId: 'demo-1',
        name: 'Training Customer',
      );
      final entry = await finance.addEntry(
        ownerId: 'demo-1',
        categoryId: category.id,
        source: 'Ato',
        amountMinorUnits: 70000,
        paymentMethod: 'CASH',
      );
      await finance.markCompleted(ownerId: 'demo-1', entryId: entry.id);

      // Entry AND its deposit both stay: a completed collection with no
      // deposit behind it is worse than a practice one nobody else sees.
      expect(await queued(SyncEntities.financeEntry), isEmpty);
      expect(await queued(SyncEntities.cashMovement), isEmpty);
      // Master data is shared on purpose, so the person the trainee practised
      // with does leave the device — the demo's own login row must too.
      expect(await queued(SyncEntities.financeCategory), hasLength(1));
    });

    test('a real collection synced from the same till is untouched', () async {
      final category = await finance.createCategory(
        ownerId: 'owner-1',
        name: 'Kebede',
      );
      final entry = await finance.addEntry(
        ownerId: 'owner-1',
        categoryId: category.id,
        source: 'Ato',
        amountMinorUnits: 70000,
        paymentMethod: 'CASH',
      );
      await finance.markCompleted(ownerId: 'owner-1', entryId: entry.id);

      // Two entries for the one collection: the outbox is append-only and the
      // newer state wins, which is how the completed status reaches the cloud.
      final entries = await queued(SyncEntities.financeEntry);
      expect(entries, hasLength(2));
      expect(entries.every((e) => e['entity_id'] == entry.id), isTrue);
      expect(await queued(SyncEntities.cashMovement), hasLength(1));
    });
  });

  group('real reports ignore the training account', () {
    setUp(() async {
      await seedSale('real-1', 3000, cashierId: 'cashier-1');
      await seedSale('real-2', 2000, cashierId: 'owner-1');
      await seedSale(
        'demo-1',
        900000,
        cashierId: 'demo-1',
        productId: 'prod-2',
        productName: 'Flour',
      );
    });

    test('dashboard stats report the shop, not the practice', () async {
      final stats = await sales.getDashboardStats(period: DateRange.today());

      expect(stats['revenue'], 5000);
      expect(stats['sales_count'], 2);
    });

    test(
      'sales history and the recent-sales strip hide demo receipts',
      () async {
        final history = await sales.getSales(period: DateRange.today());
        expect(history.map((s) => s.id), unorderedEquals(['real-1', 'real-2']));

        final recent = await sales.getRecentSales(limit: 10);
        expect(recent.any((s) => s.id == 'demo-1'), isFalse);
      },
    );

    test('the revenue trend does not count practice money', () async {
      final trend = await sales.getRevenueTrend(DateRange.today());

      expect(trend.single['total'], 5000);
      expect(trend.single['count'], 2);
    });

    test('the product mix leaves out what the trainee practised on', () async {
      final summary = await sales.getProductSalesSummary(
        period: DateRange.today(),
      );

      expect(
        summary.map((r) => r['product_name_snapshot']),
        unorderedEquals(['Sugar']),
      );
    });

    test('cashier performance has no row for the demo account', () async {
      final perf = await sales.getCashierPerformance(period: DateRange.today());

      expect(
        perf.map((r) => r['username']),
        unorderedEquals(['kebede', 'owner']),
      );
      expect(
        perf.fold<int>(0, (sum, r) => sum + (r['total_revenue'] as int)),
        5000,
      );
    });

    test('the shared drawer excludes practice sales and movements', () async {
      await shifts.addCashMovement(
        'shift-1',
        'DEPOSIT',
        500000,
        'practice deposit',
        userId: 'demo-1',
      );
      await shifts.addCashMovement(
        'shift-1',
        'DEPOSIT',
        1000,
        'real deposit',
        userId: 'owner-1',
      );

      final open = (await shifts.getActiveShift())!;
      final summary = await shifts.getShiftSummary(open);
      // 3000 + 2000 in cash sales, 1000 deposited: the 9000 Br of training and
      // its 5000 Br top-up never entered the drawer the cashier will count.
      expect(summary['cash_sales'], 5000);
      expect(summary['deposits'], 1000);
      expect(summary['expected_cash'], 6000);

      final snapshot = await shifts.getRegisterSnapshot(DateRange.today());
      expect(snapshot['balance'], 6000);
      expect(snapshot['today_cash_sales'], 5000);
      expect(snapshot['today_deposits'], 1000);

      final ledger = await shifts.getCashMovements();
      expect(ledger, hasLength(1));
      expect(ledger.single.userName, 'owner');
    });

    test('a demo void never reaches the owner approval queue', () async {
      await sales.requestVoid('demo-1', 'demo-1', 'pressed wrong key');
      await sales.requestVoid('real-1', 'cashier-1', 'wrong price');

      final pending = await sales.getPendingVoidRequests();
      expect(pending, hasLength(1));

      // And the dashboard's pending count agrees with the queue the owner sees.
      final stats = await sales.getDashboardStats(period: DateRange.today());
      expect(stats['pending_void_requests'], 1);
    });

    test('voiding a demo sale does not move the real drawer', () async {
      await sales.voidSale('demo-1', 'owner-1', 'practice receipt');

      final open = (await shifts.getActiveShift())!;
      final summary = await shifts.getShiftSummary(open);
      expect(summary['voids'], 0);
      expect(summary['cash_refunds'], 0);
      expect(summary['expected_cash'], 5000);

      expect(await sales.getVoidedSalesForShift(open.id), isEmpty);
    });

    test('shift history lists the real sessions only', () async {
      // The till's open owner shift stays; a closed training session is added
      // beside it and must not appear in the shop's history.
      await db.insert('shifts', {
        'id': 'shift-demo',
        'cashier_id': 'demo-1',
        'opening_cash_minor_units': 100,
        'closing_cash_minor_units': 100,
        'status': 'CLOSED',
        'opened_at': now,
        'closed_at': DateTime.now().toIso8601String(),
      });

      final history = await shifts.getShiftHistory();
      expect(history.map((s) => s.id), unorderedEquals(['shift-1']));
    });
  });
}
