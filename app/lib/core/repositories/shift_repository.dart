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
    final shift = Shift(
      id: const Uuid().v4(),
      cashierId: cashierId,
      openingCashMinorUnits: openingCash,
      status: 'OPEN',
      openedAt: DateTime.now(),
    );
    await _db.insert('shifts', shift.toMap());
  }

  Future<Map<String, int>> getShiftSummary(Shift shift) async {
    final cashSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'CASH' AND created_at >= ?
    ''',
      [shift.openedAt.toIso8601String()],
    );

    final bankSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'BANK' AND created_at >= ?
    ''',
      [shift.openedAt.toIso8601String()],
    );

    final voids = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'VOIDED' AND created_at >= ?
    ''',
      [shift.openedAt.toIso8601String()],
    );

    final cashTotal = (cashSales.first['total'] as int?) ?? 0;
    final bankTotal = (bankSales.first['total'] as int?) ?? 0;
    final voidTotal = (voids.first['total'] as int?) ?? 0;

    return {
      'cash_sales': cashTotal,
      'bank_sales': bankTotal,
      'voids': voidTotal,
      'expected_cash': shift.openingCashMinorUnits + cashTotal,
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
