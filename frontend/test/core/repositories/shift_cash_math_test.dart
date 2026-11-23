import 'package:flutter_test/flutter_test.dart';
import 'package:pos_local_engine/pos_local_engine.dart';
import 'package:pos_contracts/pos_contracts.dart';
import 'package:pos_core/pos_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Guards the corrected expected-cash formula:
///   opening + cashSales + deposits - withdrawals - crossShiftCashRefunds
/// A sale rung up and voided in the SAME shift must net to zero (it is never a
/// refund against this drawer); only refunds of an EARLIER shift's cash sale
/// reduce the drawer.
void main() {
  late Database db;
  late ShiftRepository repository;

  const opening = 10000;

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = SqfliteShiftRepository(db);
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
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    // An earlier, closed shift used as the origin of cross-shift refunds.
    await db.insert('shifts', {
      'id': 'shift-A',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': opening,
      'status': 'CLOSED',
      'opened_at': now,
    });
    // The current open shift under test.
    await db.insert('shifts', {
      'id': 'shift-B',
      'cashier_id': 'owner-1',
      'opening_cash_minor_units': opening,
      'status': 'OPEN',
      'opened_at': now,
    });
  });

  tearDown(() async {
    await db.close();
  });

  Future<Shift> openShiftB() async {
    final row = (await db.query(
      'shifts',
      where: 'id = ?',
      whereArgs: ['shift-B'],
    )).single;
    return Shift.fromMap(row);
  }

  Future<void> insertSale({
    required String id,
    required String originShiftId,
    required int total,
    required String status,
    String paymentMethod = 'CASH',
    String? voidedShiftId,
  }) async {
    final now = DateTime.now().toIso8601String();
    await db.insert('sales', {
      'id': id,
      'receipt_number': 'REC-$id',
      'cashier_id': 'owner-1',
      'device_id': 'device-1',
      'shift_id': originShiftId,
      'payment_method': paymentMethod,
      'subtotal_minor_units': total,
      'discount_minor_units': 0,
      'total_minor_units': total,
      'amount_paid_minor_units': total,
      'change_minor_units': 0,
      'status': status,
      'voided_shift_id': voidedShiftId,
      'created_at': now,
    });
  }

  test(
    'a same-shift void nets to zero and does not reduce expected cash',
    () async {
      // A completed cash sale of 5000 counted in cash sales.
      await insertSale(
        id: 's1',
        originShiftId: 'shift-B',
        total: 5000,
        status: 'COMPLETED',
      );
      // A cash sale rung up AND voided in shift B: not in cash sales, and must
      // not be subtracted again as a refund.
      await insertSale(
        id: 's2',
        originShiftId: 'shift-B',
        total: 3000,
        status: 'VOIDED',
        voidedShiftId: 'shift-B',
      );

      final summary = await repository.getShiftSummary(await openShiftB());

      expect(summary['cash_sales'], 5000);
      expect(summary['cash_refunds'], 0);
      // opening 10000 + cashSales 5000 - refunds 0 = 15000 (the 3000 void is a
      // pure no-op, exactly as it should be).
      expect(summary['expected_cash'], 15000);
    },
  );

  test('a cross-shift cash refund reduces expected cash', () async {
    // A sale originally rung up in shift A, refunded while shift B is open:
    // real cash leaving drawer B now.
    await insertSale(
      id: 'x1',
      originShiftId: 'shift-A',
      total: 4000,
      status: 'VOIDED',
      voidedShiftId: 'shift-B',
    );

    final summary = await repository.getShiftSummary(await openShiftB());

    expect(summary['cash_refunds'], 4000);
    expect(summary['expected_cash'], opening - 4000);
  });

  test('a non-cash (bank) refund never touches the cash drawer', () async {
    await insertSale(
      id: 'b1',
      originShiftId: 'shift-A',
      total: 4000,
      status: 'VOIDED',
      paymentMethod: 'BANK',
      voidedShiftId: 'shift-B',
    );

    final summary = await repository.getShiftSummary(await openShiftB());

    expect(summary['cash_refunds'], 0);
    expect(summary['expected_cash'], opening);
  });

  test('deposits add and withdrawals subtract from expected cash', () async {
    final now = DateTime.now().toIso8601String();
    await db.insert('cash_movements', {
      'id': 'm-in',
      'shift_id': 'shift-B',
      'user_id': 'owner-1',
      'type': 'DEPOSIT',
      'amount_minor_units': 2000,
      'reason': 'float top-up',
      'created_at': now,
    });
    await db.insert('cash_movements', {
      'id': 'm-out',
      'shift_id': 'shift-B',
      'user_id': 'owner-1',
      'type': 'WITHDRAWAL',
      'amount_minor_units': 1500,
      'reason': 'bank drop',
      'created_at': now,
    });

    final summary = await repository.getShiftSummary(await openShiftB());

    expect(summary['deposits'], 2000);
    expect(summary['withdrawals'], 1500);
    expect(summary['expected_cash'], opening + 2000 - 1500);
  });

  test(
    'closeShift stores the same expected figure as getShiftSummary',
    () async {
      await insertSale(
        id: 'c1',
        originShiftId: 'shift-B',
        total: 5000,
        status: 'COMPLETED',
      );
      await insertSale(
        id: 'c2',
        originShiftId: 'shift-A',
        total: 1200,
        status: 'VOIDED',
        voidedShiftId: 'shift-B',
      );
      final shift = await openShiftB();
      final summary = await repository.getShiftSummary(shift);
      final expected = summary['expected_cash'];

      await repository.closeShift(shift, expected!);

      final stored = (await db.query(
        'shifts',
        where: 'id = ?',
        whereArgs: ['shift-B'],
      )).single;
      expect(stored['expected_cash_minor_units'], expected);
      expect(stored['status'], 'CLOSED');
    },
  );
}
