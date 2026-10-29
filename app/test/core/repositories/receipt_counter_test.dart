import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';
import 'package:wholesale_pos_app/features/sales/sale.dart';
import 'package:wholesale_pos_app/features/sales/sale_item.dart';

void main() {
  late Database db;
  late SaleRepository repository;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SaleRepository(db);

    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
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
  });

  tearDown(() async {
    await db.close();
  });

  test('Allocates sequential daily receipt numbers', () async {
    final first = await repository.nextReceiptNumber();
    final second = await repository.nextReceiptNumber();

    final now = DateTime.now();
    final day =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    expect(first, 'REC-$day-0001');
    expect(second, 'REC-$day-0002');
  });

  test('Never hands out a receipt another register already recorded', () async {
    // A second device straight after it joins the shop: the pull has filled
    // `sales` with the first register's numbers for today, and receipt_number is
    // UNIQUE locally. The day's counter only knows what THIS till handed out, so
    // it answered 0001 — already in the book — and saveSale died on the unique
    // index. A till that cannot take a payment is not an edge case.
    final now = DateTime.now();
    final day =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final prefix = 'REC-$day-';

    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': 0,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });
    for (final (id, receipt) in [
      ('sale-remote-1', '${prefix}0001'),
      // The pull tags a receipt that clashed on the way in; the digits still
      // have to count as used.
      ('sale-remote-4', '${prefix}0004#device-9'),
    ]) {
      await db.insert('sales', {
        'id': id,
        'receipt_number': receipt,
        'cashier_id': 'owner-1',
        'device_id': 'device-1',
        'shift_id': 'shift-1',
        'payment_method': 'CASH',
        'subtotal_minor_units': 1000,
        'discount_minor_units': 0,
        'total_minor_units': 1000,
        'amount_paid_minor_units': 1000,
        'change_minor_units': 0,
        'status': 'COMPLETED',
        'created_at': DateTime.now().toIso8601String(),
      });
    }

    final next = await repository.nextReceiptNumber();
    expect(next, '${prefix}0005');

    // And the sale that uses it actually lands.
    await repository.saveSale(
      Sale(
        id: 'sale-local-1',
        receiptNumber: next,
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
            id: 'item-1',
            saleId: 'sale-local-1',
            productId: 'prod-1',
            productNameSnapshot: 'Sugar',
            unitPriceSnapshotMinorUnits: 5000,
            quantityText: '1',
            billingQuantityMilliunits: 1000,
            lineTotalMinorUnits: 5000,
          ),
        ],
      ),
    );
    expect(
      await db.query('sales', where: 'id = ?', whereArgs: ['sale-local-1']),
      hasLength(1),
    );
    // The counter remembers it moved, so the next sale is sequential again.
    expect(await repository.nextReceiptNumber(), '${prefix}0006');
  });

  test('Dashboard reports whether a register shift is open', () async {
    var stats = await repository.getDashboardStats();
    expect(stats['is_shift_open'], 0);

    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': 10000,
      'status': 'OPEN',
      'opened_at': DateTime.now().toIso8601String(),
    });

    stats = await repository.getDashboardStats();
    expect(stats['is_shift_open'], 1);
    expect(stats['expected_cash'], 10000);
  });
}
