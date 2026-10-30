import 'package:flutter_test/flutter_test.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/shift_repository.dart';
import 'package:wholesale_pos_app/core/utils/date_range.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late ShiftRepository repository;

  final now = DateTime.now();
  final todayOpen = DateTime(now.year, now.month, now.day, 9);
  final yesterdayOpen = DateTime(now.year, now.month, now.day - 1, 9);
  final twoDaysAgoOpen = DateTime(now.year, now.month, now.day - 2, 9);

  setUp(() async {
    db = await LocalDatabase.openInMemory();
    repository = ShiftRepository(db);
    final stamp = DateTime.now().toIso8601String();

    await db.insert('users', {
      'id': 'owner-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'is_active': 1,
      'created_at': stamp,
    });
    await db.insert('users', {
      'id': 'cashier-1',
      'username': 'meron',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'CASHIER',
      'is_active': 1,
      'created_at': stamp,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });

    await _insertShift(
      db,
      id: 'two-days-ago',
      status: 'CLOSED',
      openedAt: twoDaysAgoOpen,
      closedAt: twoDaysAgoOpen.add(const Duration(hours: 10)),
      expected: 10000,
      closing: 9500, // short by 500
      cashierId: 'owner-1',
    );
    await _insertShift(
      db,
      id: 'yesterday',
      status: 'CLOSED',
      openedAt: yesterdayOpen,
      closedAt: yesterdayOpen.add(const Duration(hours: 10)),
      expected: 5000,
      closing: 5000, // balanced
      cashierId: 'cashier-1',
    );
    await _insertShift(
      db,
      id: 'today',
      status: 'OPEN',
      openedAt: todayOpen,
      cashierId: 'owner-1',
    );
  });

  tearDown(() async {
    await db.close();
  });

  test('returns all shifts newest-first with the cashier name', () async {
    final shifts = await repository.getShiftHistory();

    expect(shifts.map((s) => s.id).toList(), [
      'today',
      'yesterday',
      'two-days-ago',
    ]);
    final yesterday = shifts.firstWhere((s) => s.id == 'yesterday');
    expect(yesterday.cashierName, 'meron');
  });

  test('filters by a single day (today) by opened date', () async {
    final shifts = await repository.getShiftHistory(period: DateRange.today());
    expect(shifts.map((s) => s.id).toList(), ['today']);
  });

  test('filters by yesterday', () async {
    final shifts = await repository.getShiftHistory(
      period: DateRange.yesterday(),
    );
    expect(shifts.map((s) => s.id).toList(), ['yesterday']);
  });

  test('status filter separates open and closed shifts', () async {
    final open = await repository.getShiftHistory(status: 'OPEN');
    expect(open.map((s) => s.id).toList(), ['today']);

    final closed = await repository.getShiftHistory(status: 'CLOSED');
    expect(closed.map((s) => s.id).toSet(), {'yesterday', 'two-days-ago'});
  });

  test('combined date + status filter', () async {
    // Yesterday restricted to CLOSED shifts is exactly one row.
    final shifts = await repository.getShiftHistory(
      period: DateRange.yesterday(),
      status: 'CLOSED',
    );
    expect(shifts.single.id, 'yesterday');
  });

  test('exposes the counted-minus-expected discrepancy', () async {
    final shifts = await repository.getShiftHistory(status: 'CLOSED');
    final yesterday = shifts.firstWhere((s) => s.id == 'yesterday');
    final short = shifts.firstWhere((s) => s.id == 'two-days-ago');
    final open = await repository.getShiftHistory(status: 'OPEN');

    expect(yesterday.discrepancy, 0);
    expect(short.discrepancy, -500);
    // An open shift has no closing figure yet.
    expect(open.single.discrepancy, isNull);
  });

  // F-002: shift repository reads enforce feature-tick authorization.
  test(
    'getShiftHistory requires the register_history tick for staff',
    () async {
      await expectLater(
        repository.getShiftHistory(userId: 'cashier-1'),
        throwsException,
      );
      expect(
        (await repository.getShiftHistory(userId: 'owner-1')).isNotEmpty,
        isTrue,
      );
    },
  );

  test(
    'getCashMovements requires the register_history tick for staff',
    () async {
      await expectLater(
        repository.getCashMovements(userId: 'cashier-1'),
        throwsException,
      );
      expect(
        (await repository.getCashMovements(userId: 'owner-1')).isEmpty,
        isTrue,
      );
    },
  );

  test('getRegisterSnapshot requires the register tick', () async {
    await expectLater(
      repository.getRegisterSnapshot(DateRange.today(), userId: 'cashier-1'),
      throwsException,
    );
    expect(
      (await repository.getRegisterSnapshot(
        DateRange.today(),
        userId: 'owner-1',
      )).isNotEmpty,
      isTrue,
    );
  });

  test('getShiftSummary requires the register tick', () async {
    final open = await repository.getActiveShift(userId: 'owner-1');
    expect(open, isNotNull);
    if (open == null) return;
    await expectLater(
      repository.getShiftSummary(open, userId: 'cashier-1'),
      throwsException,
    );
    expect(
      (await repository.getShiftSummary(
        open,
        userId: 'owner-1',
      )).containsKey('expected_cash'),
      isTrue,
    );
  });
}

Future<void> _insertShift(
  Database db, {
  required String id,
  required String status,
  required DateTime openedAt,
  DateTime? closedAt,
  int? expected,
  int? closing,
  required String cashierId,
}) async {
  await db.insert('shifts', {
    'id': id,
    'cashier_id': cashierId,
    'opening_cash_minor_units': 0,
    'closing_cash_minor_units': closing,
    'expected_cash_minor_units': expected,
    'status': status,
    'opened_at': openedAt.toIso8601String(),
    'closed_at': closedAt?.toIso8601String(),
  });
}
