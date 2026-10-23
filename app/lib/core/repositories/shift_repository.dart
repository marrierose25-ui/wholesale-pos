import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/shift.dart';
import '../sync/sync_outbox.dart';
import '../sync/sync_outbox_entry.dart';
import '../utils/date_range.dart';

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

  /// Past and present register sessions, newest first, each carrying the
  /// cashier username for display. Filter by the day the shift was *opened*
  /// ([period], a half-open local range) and/or [status] (`OPEN`/`CLOSED`).
  /// Closed shifts keep their stored expected/counted figures even if sales are
  /// later voided, so the historical reconciliation is never rewritten.
  Future<List<Shift>> getShiftHistory({
    DateRange? period,
    String? status,
  }) async {
    final clauses = <String>[];
    final args = <Object?>[];
    if (period != null) {
      clauses.add('shifts.opened_at >= ? AND shifts.opened_at < ?');
      args
        ..add(period.start.toIso8601String())
        ..add(period.end.toIso8601String());
    }
    if (status != null) {
      clauses.add('shifts.status = ?');
      args.add(status);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    final maps = await _db.rawQuery('''
      SELECT shifts.*, users.username AS cashier_name
      FROM shifts
      LEFT JOIN users ON shifts.cashier_id = users.id
      $where
      ORDER BY shifts.opened_at DESC
    ''', args);
    return maps.map(Shift.fromMap).toList();
  }

  Future<void> openShift(String cashierId, int openingCash) async {
    if (openingCash < 0) throw Exception('Opening cash cannot be negative.');
    final shift = Shift(
      id: const Uuid().v4(),
      cashierId: cashierId,
      openingCashMinorUnits: openingCash,
      status: 'OPEN',
      openedAt: DateTime.now(),
    );
    await _db.transaction((txn) async {
      final active = await txn.query(
        'shifts',
        where: "status = 'OPEN'",
        limit: 1,
      );
      if (active.isNotEmpty) throw Exception('A shift is already open');
      await txn.insert('shifts', shift.toMap());
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': cashierId,
        'action': 'SHIFT_OPENED',
        'details': 'Shift $shift.id opened with cash $openingCash minor units.',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueShift(txn, shift.id);
    });
  }

  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason, {
    String? userId,
  }) async {
    if (amount <= 0) throw Exception('Movement amount must be positive.');
    if (!{'WITHDRAWAL', 'DEPOSIT', 'EXPENSE'}.contains(type)) {
      throw Exception('Invalid cash movement type.');
    }
    if (reason.trim().isEmpty) throw Exception('A reason is required.');
    await _db.transaction((txn) async {
      final shifts = await txn.query(
        'shifts',
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [shiftId],
        limit: 1,
      );
      if (shifts.isEmpty) {
        throw Exception('Cash movement requires an open shift.');
      }
      if (userId != null) {
        final users = await txn.query(
          'users',
          columns: ['is_active'],
          where: 'id = ?',
          whereArgs: [userId],
          limit: 1,
        );
        if (users.isEmpty || users.first['is_active'] != 1) {
          throw Exception('An active user is required.');
        }
      }
      final movementId = const Uuid().v4();
      await txn.insert('cash_movements', {
        'id': movementId,
        'shift_id': shiftId,
        'user_id': userId,
        'type': type,
        'amount_minor_units': amount,
        'reason': reason.trim(),
        'created_at': DateTime.now().toIso8601String(),
      });
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId,
        'action': 'CASH_MOVEMENT_ADDED',
        'details': '$type $amount for shift $shiftId: ${reason.trim()}',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueCashMovement(txn, movementId);
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
      WHERE status = 'VOIDED' AND (voided_shift_id = ? OR (voided_shift_id IS NULL AND shift_id = ?))
    ''',
      [shift.id, shift.id],
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

    final cashRefunds = await _cashRefundsForShift(shift.id);
    final expectedCash =
        shift.openingCashMinorUnits +
        cashTotal +
        deposits -
        withdrawals -
        cashRefunds;

    return {
      'cash_sales': cashTotal,
      'bank_sales': bankTotal,
      'voids': voidTotal,
      'deposits': deposits,
      'withdrawals': withdrawals,
      'cash_refunds': cashRefunds,
      'expected_cash': expectedCash,
    };
  }

  /// Cash that genuinely leaves *this* drawer because of a void: a sale that
  /// was rung up in a different shift but refunded while this one was open.
  /// A sale rung up and voided in the same shift nets to zero (its incoming
  /// cash was never counted in `cash_sales`, so it must not be subtracted
  /// again), which is why `shift_id <> voided_shift_id` is required here.
  Future<int> _cashRefundsForShift(String shiftId) async {
    final rows = await _db.rawQuery(
      '''
      SELECT COALESCE(SUM(total_minor_units), 0) AS total FROM sales
      WHERE status = 'VOIDED' AND payment_method = 'CASH'
        AND voided_shift_id = ? AND shift_id <> ?
    ''',
      [shiftId, shiftId],
    );
    return rows.first['total'] as int;
  }

  Future<void> closeShift(
    Shift shift,
    int closingCash, {
    String? userId,
  }) async {
    if (closingCash < 0) throw Exception('Closing cash cannot be negative.');
    await _db.transaction((txn) async {
      final rows = await txn.query(
        'shifts',
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [shift.id],
        limit: 1,
      );
      if (rows.isEmpty) throw Exception('Shift is no longer open.');
      final currentShift = Shift.fromMap(rows.first);
      final cashSales = await txn.rawQuery(
        "SELECT COALESCE(SUM(total_minor_units), 0) AS total FROM sales WHERE status = 'COMPLETED' AND payment_method = 'CASH' AND shift_id = ?",
        [shift.id],
      );
      final movements = await txn.rawQuery(
        "SELECT COALESCE(SUM(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE -amount_minor_units END), 0) AS total FROM cash_movements WHERE shift_id = ?",
        [shift.id],
      );
      // Only cross-shift cash refunds reduce this drawer; see
      // [_cashRefundsForShift] for the same-shift netting rule.
      final cashVoids = await txn.rawQuery(
        "SELECT COALESCE(SUM(total_minor_units), 0) AS total FROM sales WHERE status = 'VOIDED' AND payment_method = 'CASH' AND voided_shift_id = ? AND shift_id <> ?",
        [shift.id, shift.id],
      );
      final expected =
          currentShift.openingCashMinorUnits +
          (cashSales.first['total'] as int) +
          (movements.first['total'] as int) -
          (cashVoids.first['total'] as int);
      await txn.update(
        'shifts',
        {
          'closing_cash_minor_units': closingCash,
          'expected_cash_minor_units': expected,
          'status': 'CLOSED',
          'closed_at': DateTime.now().toIso8601String(),
        },
        where: "id = ? AND status = 'OPEN'",
        whereArgs: [shift.id],
      );
      await txn.insert('audit_logs', {
        'id': const Uuid().v4(),
        'user_id': userId ?? shift.cashierId,
        'action': 'SHIFT_CLOSED',
        'details':
            'Shift ${shift.id} closed. Expected: $expected, '
            'Counted: $closingCash, Difference: ${closingCash - expected}.',
        'created_at': DateTime.now().toIso8601String(),
      });
      await _enqueueShift(txn, shift.id);
    });
  }

  Future<void> _enqueueShift(Transaction txn, String shiftId) async {
    final rows = await txn.query(
      'shifts',
      where: 'id = ?',
      whereArgs: [shiftId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsert(
      txn,
      entityType: SyncEntities.shift,
      entityId: shiftId,
      payload: {'shift': rows.first},
    );
  }

  Future<void> _enqueueCashMovement(Transaction txn, String movementId) async {
    final rows = await txn.query(
      'cash_movements',
      where: 'id = ?',
      whereArgs: [movementId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    await SyncOutbox.upsert(
      txn,
      entityType: SyncEntities.cashMovement,
      entityId: movementId,
      payload: {'cash_movement': rows.first},
    );
  }
}
