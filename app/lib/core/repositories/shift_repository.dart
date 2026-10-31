import 'dart:convert';

import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../../features/sales/shift.dart';
import '../sync/sync_outbox.dart';
import '../sync/sync_outbox_entry.dart';
import '../utils/date_range.dart';
import '../utils/report_filters.dart';
import '../models/user.dart';

/// Data-access contract for register shifts and cash movements.
///
/// [SqfliteShiftRepository] is the local-first implementation; the cloud
/// implementation added in the PWA milestones honours the same contract so the
/// register and shift-history screens stay storage-agnostic.
abstract class ShiftRepository {
  factory ShiftRepository(Database db) = SqfliteShiftRepository;

  Future<Shift?> getActiveShift({String? userId});

  /// Returns the currently open shift, creating a perpetual one (opening cash
  /// `0`) when none exists. Idempotent and safe against the one-open-shift
  /// trigger: concurrent callers converge on a single OPEN row.
  Future<Shift> ensureActiveShift(String cashierId, {String? userId});

  /// Past and present register sessions, newest first, each carrying the
  /// cashier username for display. Filter by the day the shift was *opened*
  /// ([period], a half-open local range) and/or [status] (`OPEN`/`CLOSED`).
  Future<List<Shift>> getShiftHistory({
    String? userId,
    DateRange? period,
    String? status,
  });

  Future<void> openShift(String cashierId, int openingCash);

  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason, {
    String? userId,
    String? photo,
  });

  /// The cash-register ledger, newest first, each carrying the username of
  /// whoever recorded it. Pass [shiftId] to restrict the list to one session,
  /// or omit it for every movement across all shifts.
  Future<List<CashMovement>> getCashMovements({
    String? userId,
    String? shiftId,
  });

  Future<Map<String, int>> getShiftSummary(Shift shift, {String? userId});

  /// Register figures for the perpetual open shift: `balance` is the all-time
  /// expected cash in the drawer, while the `today_*` counters are the same
  /// sums restricted to [day] (a half-open local range) so they reset each
  /// calendar day. Returns all zeros when no shift is open.
  Future<Map<String, int>> getRegisterSnapshot(DateRange day, {String? userId});

  Future<void> closeShift(Shift shift, int closingCash, {String? userId});
}

class SqfliteShiftRepository implements ShiftRepository {
  final Database _db;

  SqfliteShiftRepository(this._db);

  /// Owner always passes; staff must hold [feature] (or one of [aliases]).
  static Future<void> _requireFeature(
    DatabaseExecutor executor,
    String? userId, {
    required String feature,
    List<String> aliases = const [],
  }) async {
    // No user identified (e.g. tests that predate this gate): skip the check.
    if (userId == null || userId.isEmpty) return;
    final rows = await executor.query(
      'users',
      columns: ['role', 'permissions'],
      where: 'id = ? AND deleted_at IS NULL',
      whereArgs: [userId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw Exception('User not found.');
    }
    if (rows.first['role'] == 'OWNER') return;
    final held = User.decodePermissions(rows.first['permissions']);
    final allowed = <String>{...held, ...aliases};
    if (!allowed.contains(feature)) {
      throw Exception('This account does not have access to $feature.');
    }
  }

  @override
  Future<Shift?> getActiveShift({String? userId}) async {
    await _requireFeature(_db, userId, feature: 'register');
    final maps = await _db.query(
      'shifts',
      where: 'status = ?',
      whereArgs: ['OPEN'],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return Shift.fromMap(maps.first);
  }

  @override
  Future<Shift> ensureActiveShift(String cashierId, {String? userId}) async {
    await _requireFeature(_db, userId, feature: 'register');
    final existing = await getActiveShift(userId: userId);
    if (existing != null) return existing;
    final shift = Shift(
      id: const Uuid().v4(),
      cashierId: cashierId,
      openingCashMinorUnits: 0,
      status: 'OPEN',
      openedAt: DateTime.now(),
    );
    await _db.transaction((txn) async {
      // Re-check inside the transaction so a concurrent opener wins exactly
      // once and the one-open-shift trigger is never tripped.
      final active = await txn.query(
        'shifts',
        where: "status = 'OPEN'",
        limit: 1,
      );
      if (active.isNotEmpty) return;
      await txn.insert('shifts', shift.toMap());
      await _enqueueShift(txn, shift.id);
    });
    final after = await getActiveShift();
    return after ?? shift;
  }

  /// Past and present register sessions, newest first, each carrying the
  /// cashier username for display. Filter by the day the shift was *opened*
  /// ([period], a half-open local range) and/or [status] (`OPEN`/`CLOSED`).
  /// Closed shifts keep their stored expected/counted figures even if sales are
  /// later voided, so the historical reconciliation is never rewritten.
  @override
  Future<List<Shift>> getShiftHistory({
    String? userId,
    DateRange? period,
    String? status,
  }) async {
    await _requireFeature(_db, userId, feature: 'register_history');
    // A training account's register sessions are not the shop's history, and its
    // money never entered the drawer, so it is left out of the balance sums
    // below too: a till that trained all day still closes on real cash.
    final clauses = <String>[notDemoOperator('shifts.cashier_id')];
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

  @override
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

  @override
  Future<void> addCashMovement(
    String shiftId,
    String type,
    int amount,
    String reason, {
    String? userId,
    String? photo,
  }) async {
    if (amount <= 0) throw Exception('Movement amount must be positive.');
    if (!{'WITHDRAWAL', 'DEPOSIT', 'EXPENSE'}.contains(type)) {
      throw Exception('Invalid cash movement type.');
    }
    if (reason.trim().isEmpty) throw Exception('A reason is required.');
    // Cap proof photo base64 size (~150 KB JPEG after decode).
    if (photo != null && photo.length > 200 * 1024) {
      throw Exception('Proof photo is too large (limit ~150 KB).');
    }
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
      final createdAt = DateTime.now().toIso8601String();
      await txn.insert('cash_movements', {
        'id': movementId,
        'shift_id': shiftId,
        'user_id': userId,
        'type': type,
        'amount_minor_units': amount,
        'reason': reason.trim(),
        'created_at': createdAt,
        // The legacy TEXT column stays empty (schema 16): the JPEG lives as a
        // BLOB in cash_movement_photos so ledger reads and backups stop
        // carrying a base64 copy of every proof.
      });
      if (photo != null && photo.isNotEmpty) {
        await txn.insert('cash_movement_photos', {
          'movement_id': movementId,
          'jpeg_bytes': base64Decode(photo),
          'created_at': createdAt,
        });
      }
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

  @override
  Future<List<CashMovement>> getCashMovements({
    String? userId,
    String? shiftId,
  }) async {
    await _requireFeature(_db, userId, feature: 'register_history');
    final clauses = <String>[notDemoOperator('cm.user_id')];
    final args = <Object?>[];
    if (shiftId != null) {
      clauses.add('cm.shift_id = ?');
      args.add(shiftId);
    }
    final where = clauses.isEmpty ? '' : ' WHERE ${clauses.join(' AND ')}';
    final maps = await _db.rawQuery('''
      SELECT cm.*, users.username AS user_name, cmp.jpeg_bytes AS photo_bytes
      FROM cash_movements cm
      LEFT JOIN users ON cm.user_id = users.id
      LEFT JOIN cash_movement_photos cmp ON cmp.movement_id = cm.id
      $where
      ORDER BY cm.created_at DESC
    ''', args);
    return maps.map((row) {
      final map = Map<String, dynamic>.from(row);
      final bytes = map.remove('photo_bytes');
      if (bytes is List<int> && bytes.isNotEmpty) {
        // Re-encoded at the boundary so CashMovement keeps its transport shape
        // (a base64 string the ledger view decodes for MemoryImage). A row that
        // an older backup restored into the legacy TEXT column still reads.
        map['photo'] = base64Encode(bytes);
      }
      return CashMovement.fromMap(map);
    }).toList();
  }

  @override
  Future<Map<String, int>> getShiftSummary(
    Shift shift, {
    String? userId,
  }) async {
    await _requireFeature(_db, userId, feature: 'register');
    // One OPEN shift is shared by every login on the device, so the practice
    // money a demo cashier rang up would otherwise sit in the real drawer's
    // expected cash. Excluded here and in every sum below, so the balance the
    // cashier counts against holds only money the shop actually took.
    final notDemoSale = notDemoOperator('cashier_id');
    final notDemoMovement = notDemoOperator('user_id');
    final cashSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'CASH'
        AND $notDemoSale AND shift_id = ?
    ''',
      [shift.id],
    );

    final bankSales = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'COMPLETED' AND payment_method = 'BANK'
        AND $notDemoSale AND shift_id = ?
    ''',
      [shift.id],
    );

    final voids = await _db.rawQuery(
      '''
      SELECT SUM(total_minor_units) as total 
      FROM sales 
      WHERE status = 'VOIDED' AND $notDemoSale
        AND (voided_shift_id = ? OR (voided_shift_id IS NULL AND shift_id = ?))
    ''',
      [shift.id, shift.id],
    );

    final cashMovements = await _db.rawQuery(
      '''
      SELECT 
        SUM(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END) as deposits,
        SUM(CASE WHEN type IN ('WITHDRAWAL', 'EXPENSE') THEN amount_minor_units ELSE 0 END) as withdrawals
      FROM cash_movements 
      WHERE $notDemoMovement AND shift_id = ?
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

  @override
  Future<Map<String, int>> getRegisterSnapshot(
    DateRange day, {
    String? userId,
  }) async {
    await _requireFeature(_db, userId, feature: 'register');
    final shift = await getActiveShift(userId: userId);
    if (shift == null) {
      return {
        'balance': 0,
        'today_cash_sales': 0,
        'today_bank_sales': 0,
        'today_deposits': 0,
        'today_withdrawals': 0,
      };
    }
    // All-time drawer balance reuses the shift summary so the two agree.
    final summary = await getShiftSummary(shift);
    final start = day.start.toIso8601String();
    final end = day.end.toIso8601String();

    final sales = await _db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN payment_method = 'CASH' THEN total_minor_units ELSE 0 END), 0) AS cash_sales,
        COALESCE(SUM(CASE WHEN payment_method = 'BANK' THEN total_minor_units ELSE 0 END), 0) AS bank_sales
      FROM sales
      WHERE status = 'COMPLETED' AND ${notDemoOperator('cashier_id')}
        AND shift_id = ?
        AND created_at >= ? AND created_at < ?
    ''',
      [shift.id, start, end],
    );
    final movements = await _db.rawQuery(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'DEPOSIT' THEN amount_minor_units ELSE 0 END), 0) AS deposits,
        COALESCE(SUM(CASE WHEN type IN ('WITHDRAWAL', 'EXPENSE') THEN amount_minor_units ELSE 0 END), 0) AS withdrawals
      FROM cash_movements
      WHERE ${notDemoOperator('user_id')} AND shift_id = ?
        AND created_at >= ? AND created_at < ?
    ''',
      [shift.id, start, end],
    );

    int asInt(Object? v) => (v as num?)?.toInt() ?? 0;
    return {
      'balance': summary['expected_cash'] ?? 0,
      'today_cash_sales': asInt(sales.first['cash_sales']),
      'today_bank_sales': asInt(sales.first['bank_sales']),
      'today_deposits': asInt(movements.first['deposits']),
      'today_withdrawals': asInt(movements.first['withdrawals']),
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
        AND ${notDemoOperator('cashier_id')}
        AND voided_shift_id = ? AND shift_id <> ?
    ''',
      [shiftId, shiftId],
    );
    return rows.first['total'] as int;
  }

  @override
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
    final movement = Map<String, Object?>.from(rows.first);
    // The legacy TEXT column is empty under schema 16 — the proof lives as a
    // BLOB in cash_movement_photos. Re-attach it here (base64, the shape the
    // cloud row and the PWA expect) so an app-captured proof reaches the
    // browser instead of being stranded on the till that recorded it.
    final photos = await txn.query(
      'cash_movement_photos',
      columns: ['jpeg_bytes'],
      where: 'movement_id = ?',
      whereArgs: [movementId],
      limit: 1,
    );
    final bytes = photos.isEmpty ? null : photos.first['jpeg_bytes'];
    if (bytes is List<int> && bytes.isNotEmpty) {
      movement['photo'] = base64Encode(bytes);
    } else {
      movement.remove('photo');
    }
    await SyncOutbox.upsert(
      txn,
      entityType: SyncEntities.cashMovement,
      entityId: movementId,
      payload: {'cash_movement': movement},
    );
  }
}
