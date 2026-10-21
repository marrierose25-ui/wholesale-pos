import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wholesale_pos_app/core/database/local_database.dart';
import 'package:wholesale_pos_app/core/repositories/sale_repository.dart';

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
