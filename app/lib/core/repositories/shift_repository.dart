import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/shift.dart';

class ShiftRepository {
  final Database _db;

  ShiftRepository(this._db);

  Future<Shift?> getActiveShift() async {
    final maps = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Shift.fromMap(maps.first);
  }

  Future<void> openShift(String cashierId, int openingCash) async {
    final active = await getActiveShift();
    if (active != null) throw Exception('A shift is already open');

    final shift = Shift(
      id: const Uuid().v4(),
      cashierId: cashierId,
      openingCashMinorUnits: openingCash,
      status: 'OPEN',
      openedAt: DateTime.now(),
    );
    await _db.insert('shifts', shift.toMap());
  }

  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason,
  ) async {
    await _db.insert('cash_movements', {
      'id': const Uuid().v4(),
      'shift_id': shiftId,
      'type': type, // WITHDRAWAL, DEPOSIT, EXPENSE
      'amount_minor_units': amount,
      'reason': reason,
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  Future<Map<String, int>> getShiftSummary(Shift shift) async {
    final cashSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'CASH' AND shift_id = ?
    ''',
      [shift.id],
    );

    final bankSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'BANK' AND shift_id = ?
    ''',
      [shift.id],
    );

    final voids = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'VOIDED' AND shift_id = ?
    ''',
      [shift.id],
    );

    final cashMovements = await _db.rawQuery(
      '''
      SELECT 
        SUM(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END) as deposits,
        SUM(CASE WHEN type IN ('WITHDRAWAL', 'EXPENSE') THEN amount_minor_units ELSE 0 END) as withdrawals
      FROM cash_movements 
      WHERE shift_id = ?
    ''',
      [shift.id],
    );

    final cashTotal = (cashSales.first['total'] as int?) ?? 0;
    final bankTotal = (bankSales.first['total'] as int?) ?? 0;
    final voidTotal = (voids.first['total'] as int?) ?? 0;

    final deposits = (cashMovements.first['deposits'] as int?) ?? 0;
    final withdrawals = (cashMovements.first['withdrawals'] as int?) ?? 0;

    final expectedCash =
        shift.openingCashMinorUnits + cashTotal + deposits - withdrawals;

    return {
      'cash_sales': cashTotal,
      'bank_sales': bankTotal,
      'voids': voidTotal,
      'deposits': deposits,
      'withdrawals': withdrawals,
      'expected_cash': expectedCash,
    };
  }

  Future<void> closeShift(Shift shift, int closingCash) async {
    final summary = await getShiftSummary(shift);
    await _db.update(
      'shifts',
      {
        'closing_cash_minor_units': closingCash,
        'expected_cash_minor_units': summary['expected_cash'],
        'status': 'CLOSED',
        'closed_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [shift.id],
    );
  }
}
