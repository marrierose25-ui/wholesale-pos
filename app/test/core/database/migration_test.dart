import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wholesale_pos_app/core/database/local_database.dart';

void main() {
  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('wholesale_pos_test_');
    dbPath = p.join(tempDir.path, 'test.db');
  });

  tearDown(() async {
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {
      // Windows occasionally holds the file handle a moment longer.
    }
  });

  test('Upgrades a v5 database to v6 without losing cash movements', () async {
    var db = await LocalDatabase.openAt(dbPath);
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'user-1',
      'username': 'owner',
      'password_hash': 'x',
      'salt': 'x',
      'role': 'OWNER',
      'created_at': now,
    });
    await db.insert('devices', {
      'id': 'device-1',
      'name': 'PC',
      'platform': 'Windows',
    });
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 10000,
      'status': 'OPEN',
      'opened_at': now,
    });
    await db.insert('cash_movements', {
      'id': 'movement-1',
      'shift_id': 'shift-1',
      'type': 'CASH_IN',
      'amount_minor_units': 5000,
      'reason': 'float top-up',
      'created_at': now,
      'user_id': 'user-1',
    });

    // Rewind the database to the v5 shape: cash_movements had user_id added
    // with ALTER TABLE (so no foreign key), and counters/settings did not
    // exist yet.
    await db.execute('''
      CREATE TABLE cash_movements_v5 (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT
      )
    ''');
    await db.execute('''
      INSERT INTO cash_movements_v5
        (id, shift_id, type, amount_minor_units, reason, created_at, user_id)
      SELECT id, shift_id, type, amount_minor_units, reason, created_at, user_id
      FROM cash_movements
    ''');
    await db.execute('DROP TABLE cash_movements');
    await db.execute('ALTER TABLE cash_movements_v5 RENAME TO cash_movements');
    await db.execute('DROP TABLE counters');
    await db.execute('DROP TABLE settings');
    await db.execute('DROP INDEX IF EXISTS sales_created_at');
    await db.execute('DROP INDEX IF EXISTS sale_items_sale_id');
    await db.execute('DROP INDEX IF EXISTS audit_logs_created_at');
    await db.execute('DROP INDEX IF EXISTS cash_movements_shift_id');
    await db.execute('PRAGMA user_version = 5');
    await db.close();

    db = await LocalDatabase.openAt(dbPath);

    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, LocalDatabase.schemaVersion);

    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();
    expect(tables, containsAll(['counters', 'settings', 'cash_movements']));

    final foreignKeys = await db.rawQuery(
      'PRAGMA foreign_key_list(cash_movements)',
    );
    expect(foreignKeys.any((row) => row['table'] == 'users'), isTrue);

    final movement = (await db.query(
      'cash_movements',
      where: 'id = ?',
      whereArgs: ['movement-1'],
    )).single;
    expect(movement['amount_minor_units'], 5000);
    expect(movement['user_id'], 'user-1');

    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    )).map((row) => row['name'] as String).toSet();
    expect(
      indexes,
      containsAll([
        'sales_shift_id',
        'sales_created_at',
        'sale_items_sale_id',
        'audit_logs_created_at',
        'cash_movements_shift_id',
      ]),
    );

    final triggers = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'trigger'",
    )).map((row) => row['name'] as String).toSet();
    expect(
      triggers,
      containsAll([
        'prevent_second_open_shift_insert',
        'prevent_second_open_shift_update',
      ]),
    );

    await db.close();
  });

  test('Re-registers the persisted device ID after a restore', () async {
    var db = await LocalDatabase.openAt(dbPath);
    final deviceId = await LocalDatabase.registerCurrentDevice(db);
    expect(
      await File(p.join(tempDir.path, LocalDatabase.deviceIdFileName)).exists(),
      isTrue,
    );

    // Simulate a restore that replaced the devices table.
    await db.delete('devices');
    expect(await db.query('devices'), isEmpty);
    await db.close();

    db = await LocalDatabase.openAt(dbPath);
    final restoredId = await LocalDatabase.registerCurrentDevice(db);

    expect(restoredId, deviceId);
    final devices = await db.query('devices');
    expect(devices.length, 1);
    expect(devices.single['id'], deviceId);
    await db.close();
  });
}
