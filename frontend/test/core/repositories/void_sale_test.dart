import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/pos_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late SaleRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteSaleRepository(db);

    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier',
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
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seedSale(String id) async {
    await repository.saveSale(
      Sale(
        id: id,
        receiptNumber: 'REC-$id',
        cashierId: 'owner-1',
        deviceId: 'device-1',
        shiftId: 'shift-1',
        subtotalMinorUnits: 5000,
        discountMinorUnits: 0,
        totalMinorUnits: 5000,
        amountPaidMinorUnits: 5000,
        changeMinorUnits: 0,
        createdAt: DateTime.now(),
        items: [
          SaleItem(
            id: 'item-$id',
            saleId: id,
            productId: 'MANUAL',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 5000,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 5000,
          ),
        ],
      ),
    );
  }

  test(
    'Voiding a sale excludes it from revenue but keeps the record',
    () async {
      await seedSale('sale-to-void');

      final before = await repository.getDashboardStats();
      expect(before['revenue'], 5000);
      expect(before['sales_count'], 1);

      await repository.voidSale('sale-to-void', 'owner-1', 'mistake');

      final after = await repository.getDashboardStats();
      expect(after['revenue'], 0);
      expect(after['sales_count'], 0);
      expect(after['average_sale'], 0);

      // History keeps the record forever; nothing is deleted.
      final sales = await repository.getSales();
      expect(sales.length, 1);
      expect(sales.first.status, 'VOIDED');
      expect(sales.first.voidReason, 'mistake');
      expect(sales.first.voidedBy, 'owner-1');

      final logs = await repository.getAuditLogs();
      expect(logs.length, 2);
      expect(logs.first['action'], 'SALE_VOIDED');
      // The audit detail references the amount, not a receipt number.
      expect(logs.first['details'].contains('50.00 Br'), isTrue);
      expect(logs.first['details'].contains('REC-'), isFalse);
    },
  );

  test('Voiding the same sale twice is rejected', () async {
    await seedSale('sale-twice');
    await repository.voidSale('sale-twice', 'owner-1', 'mistake');

    await expectLater(
      repository.voidSale('sale-twice', 'owner-1', 'other reason'),
      throwsException,
    );
  });

  test('A cashier cannot void sales', () async {
    await seedSale('sale-cashier');

    await expectLater(
      repository.voidSale('sale-cashier', 'cashier-1', 'cashier attempt'),
      throwsException,
    );

    final sales = await repository.getSales();
    expect(sales.first.status, 'COMPLETED');
  });

  test('A direct owner void queues the request it settles', () async {
    await seedSale('sale-with-request');
    await db.insert('void_requests', {
      'id': 'request-1',
      'sale_id': 'sale-with-request',
      'requested_by': 'cashier-1',
      'reason': 'wrong item scanned',
      'status': 'PENDING',
      'created_at': DateTime.now().toIso8601String(),
    });

    await repository.voidSale('sale-with-request', 'owner-1', 'mistake');

    // Settling the request locally is only half of it: without a queue entry
    // the cloud keeps it PENDING forever and the owner's web queue shows a
    // request against a sale that is already voided.
    final outbox = await db.query(
      'sync_outbox',
      where: "entity_type = 'void_request'",
    );
    expect(outbox.length, 1);
    expect(outbox.first['entity_id'], equals('request-1'));
  });

  test('A void reason is required', () async {
    await seedSale('sale-noreason');

    await expectLater(
      repository.voidSale('sale-noreason', 'owner-1', '   '),
      throwsException,
    );
  });
}
