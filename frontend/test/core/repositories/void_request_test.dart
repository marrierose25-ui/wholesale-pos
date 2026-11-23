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
      'is_active': 1,
      'created_at': DateTime.now().toIso8601String(),
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'cashier',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
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
        cashierId: 'cashier-1',
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

  test('a cashier can request a void; the sale stays completed', () async {
    await seedSale('sale-req');

    await repository.requestVoid('sale-req', 'cashier-1', 'wrong item scanned');

    // Revenue is untouched until an owner decides.
    final stats = await repository.getDashboardStats();
    expect(stats['revenue'], 5000);

    final sales = await repository.getSales();
    expect(sales.first.status, 'COMPLETED');
    expect(sales.first.hasPendingVoidRequest, isTrue);

    final pending = await repository.getPendingVoidRequests();
    expect(pending.length, 1);
    expect(pending.first.requesterName, 'cashier');
    expect(pending.first.reason, 'wrong item scanned');
    expect(pending.first.status, VoidRequest.statusPending);
    expect(pending.first.sale?.id, 'sale-req');
  });

  test('a duplicate pending request on the same sale is blocked', () async {
    await seedSale('sale-dup');
    await repository.requestVoid('sale-dup', 'cashier-1', 'first');

    await expectLater(
      repository.requestVoid('sale-dup', 'cashier-1', 'second'),
      throwsException,
    );
    final pending = await repository.getPendingVoidRequests();
    expect(pending.length, 1);
  });

  test('a void request requires a reason', () async {
    await seedSale('sale-noreason');
    await expectLater(
      repository.requestVoid('sale-noreason', 'cashier-1', '   '),
      throwsException,
    );
  });

  test('a request cannot be filed on an already-voided sale', () async {
    await seedSale('sale-voided');
    await repository.voidSale('sale-voided', 'owner-1', 'mistake');

    await expectLater(
      repository.requestVoid('sale-voided', 'cashier-1', 'again'),
      throwsException,
    );
  });

  test('a non-owner cannot approve or reject a request', () async {
    await seedSale('sale-guard');
    await repository.requestVoid('sale-guard', 'cashier-1', 'oops');
    final requestId = (await repository.getPendingVoidRequests()).first.id;

    await expectLater(
      repository.approveVoidRequest(requestId, 'cashier-1'),
      throwsException,
    );
    await expectLater(
      repository.rejectVoidRequest(requestId, 'cashier-1'),
      throwsException,
    );

    // Still pending, sale untouched.
    final pending = await repository.getPendingVoidRequests();
    expect(pending.length, 1);
    final sale = (await repository.getSales()).first;
    expect(sale.status, 'COMPLETED');
  });

  test('owner approval voids the sale and removes it from revenue', () async {
    await seedSale('sale-approve');
    await repository.requestVoid('sale-approve', 'cashier-1', 'double rung');
    final requestId = (await repository.getPendingVoidRequests()).first.id;

    await repository.approveVoidRequest(requestId, 'owner-1');

    final stats = await repository.getDashboardStats();
    expect(stats['revenue'], 0);
    expect(stats['void_count'], 1);
    expect(stats['pending_void_requests'], 0);

    final sale = (await repository.getSales()).first;
    expect(sale.status, 'VOIDED');
    expect(sale.voidedBy, 'owner-1');
    expect(sale.hasPendingVoidRequest, isFalse);

    expect(await repository.getPendingVoidRequests(), isEmpty);
    final requests = await db.query(
      'void_requests',
      where: 'id = ?',
      whereArgs: [requestId],
    );
    expect(requests.single['status'], VoidRequest.statusApproved);
    expect(requests.single['decided_by'], 'owner-1');
  });

  test('owner rejection leaves the sale completed', () async {
    await seedSale('sale-reject');
    await repository.requestVoid('sale-reject', 'cashier-1', 'thought wrong');
    final requestId = (await repository.getPendingVoidRequests()).first.id;

    await repository.rejectVoidRequest(requestId, 'owner-1');

    final stats = await repository.getDashboardStats();
    expect(stats['revenue'], 5000);
    final sale = (await repository.getSales()).first;
    expect(sale.status, 'COMPLETED');
    expect(sale.hasPendingVoidRequest, isFalse);

    final requests = await db.query(
      'void_requests',
      where: 'id = ?',
      whereArgs: [requestId],
    );
    expect(requests.single['status'], VoidRequest.statusRejected);
  });

  test('a decided request cannot be acted on again', () async {
    await seedSale('sale-twice-decide');
    await repository.requestVoid('sale-twice-decide', 'cashier-1', 'oops');
    final requestId = (await repository.getPendingVoidRequests()).first.id;
    await repository.rejectVoidRequest(requestId, 'owner-1');

    await expectLater(
      repository.approveVoidRequest(requestId, 'owner-1'),
      throwsException,
    );
  });

  test(
    'a request left pending on a voided sale drops out of the queue',
    () async {
      await seedSale('sale-stale');
      await repository.requestVoid('sale-stale', 'cashier-1', 'oops');
      final requestId = (await repository.getPendingVoidRequests()).first.id;
      await repository.voidSale('sale-stale', 'owner-1', 'mistake');

      // An older build left this behind: the sale is voided but the request is
      // still PENDING, so the owner sees a row they can never act on.
      await db.update(
        'void_requests',
        {'status': VoidRequest.statusPending},
        where: 'id = ?',
        whereArgs: [requestId],
      );

      expect(await repository.getPendingVoidRequests(), isEmpty);
    },
  );

  test('a direct owner void auto-closes any pending request', () async {
    await seedSale('sale-direct-void');
    await repository.requestVoid('sale-direct-void', 'cashier-1', 'oops');

    await repository.voidSale('sale-direct-void', 'owner-1', 'mistake');

    expect(await repository.getPendingVoidRequests(), isEmpty);
  });
}
