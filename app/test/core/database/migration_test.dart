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

  test('Upgrades a v6 database to v7, preserving sale items and adding finance tables', () async {
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
      'opening_cash_minor_units': 0,
      'status': 'CLOSED',
      'opened_at': now,
    });
    await db.insert('sales', {
      'id': 'sale-1',
      'receipt_number': 'REC-001',
      'cashier_id': 'user-1',
      'device_id': 'device-1',
      'shift_id': 'shift-1',
      'subtotal_minor_units': 7000,
      'discount_minor_units': 0,
      'total_minor_units': 7000,
      'amount_paid_minor_units': 7000,
      'change_minor_units': 0,
      'status': 'COMPLETED',
      'created_at': now,
    });

    // Rewind sale_items to the v6 shape: an integer quantity column and no
    // flexible-quantity columns.
    await db.execute('DROP TABLE sale_items');
    await db.execute('''
      CREATE TABLE sale_items (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name_snapshot TEXT NOT NULL,
        unit_price_snapshot_minor_units INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        line_discount_minor_units INTEGER NOT NULL DEFAULT 0,
        line_total_minor_units INTEGER NOT NULL,
        FOREIGN KEY(sale_id) REFERENCES sales(id) ON DELETE CASCADE
      )
    ''');
    await db.insert('sale_items', {
      'id': 'item-1',
      'sale_id': 'sale-1',
      'product_id': 'prod-1',
      'product_name_snapshot': 'Sugar',
      'unit_price_snapshot_minor_units': 3500,
      'quantity': 2,
      'line_discount_minor_units': 0,
      'line_total_minor_units': 7000,
    });
    await db.execute('PRAGMA user_version = 6');
    await db.close();

    db = await LocalDatabase.openAt(dbPath);

    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, LocalDatabase.schemaVersion);

    // Legacy values were copied into both new columns: quantity 2 becomes
    // text "2" and billing milliunits 2000.
    final item = (await db.query(
      'sale_items',
      where: 'id = ?',
      whereArgs: ['item-1'],
    )).single;
    expect(item['quantity_text'], '2');
    expect(item['billing_quantity_milliunits'], 2000);
    expect(item['line_total_minor_units'], 7000);
    final columns = await db.rawQuery('PRAGMA table_info(sale_items)');
    expect(
      columns.map((row) => row['name']),
      containsAll(['quantity_text', 'billing_quantity_milliunits', 'notes']),
    );
    expect(columns.map((row) => row['name']), isNot(contains('quantity')));

    // The finance tables and their indexes exist after the upgrade.
    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();
    expect(tables, containsAll(['finance_categories', 'finance_entries']));
    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    )).map((row) => row['name'] as String).toSet();
    expect(
      indexes,
      containsAll([
        'finance_entries_category_id',
        'finance_entries_status',
        'finance_entries_entry_date',
      ]),
    );

    // The sale itself survived untouched.
    final sale = (await db.query(
      'sales',
      where: 'id = ?',
      whereArgs: ['sale-1'],
    )).single;
    expect(sale['total_minor_units'], 7000);

    await db.close();
  });

  test(
    'Upgrades a v7 database to v8, adding void_requests and its indexes',
    () async {
      var db = await LocalDatabase.openAt(dbPath);
      final now = DateTime.now().toIso8601String();
      await db.insert('users', {
        'id': 'user-1',
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
      await db.insert('shifts', {
        'id': 'shift-1',
        'cashier_id': 'user-1',
        'opening_cash_minor_units': 0,
        'status': 'CLOSED',
        'opened_at': now,
      });
      await db.insert('sales', {
        'id': 'sale-1',
        'receipt_number': 'REC-001',
        'cashier_id': 'user-1',
        'device_id': 'device-1',
        'shift_id': 'shift-1',
        'subtotal_minor_units': 5000,
        'discount_minor_units': 0,
        'total_minor_units': 5000,
        'amount_paid_minor_units': 5000,
        'change_minor_units': 0,
        'status': 'COMPLETED',
        'created_at': now,
      });

      // Rewind to the v7 shape: no void_requests table or indexes.
      await db.execute('DROP TABLE void_requests');
      await db.execute('DROP INDEX IF EXISTS void_requests_sale_id');
      await db.execute('DROP INDEX IF EXISTS void_requests_status');
      await db.execute('PRAGMA user_version = 7');
      await db.close();

      db = await LocalDatabase.openAt(dbPath);

      final version = await db.rawQuery('PRAGMA user_version');
      expect(version.first.values.first, LocalDatabase.schemaVersion);

      final tables = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      )).map((row) => row['name'] as String).toSet();
      expect(tables, contains('void_requests'));

      final indexes = (await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index'",
      )).map((row) => row['name'] as String).toSet();
      expect(
        indexes,
        containsAll(['void_requests_sale_id', 'void_requests_status']),
      );

      // void_requests references both sales and users.
      final foreignKeys = await db.rawQuery(
        'PRAGMA foreign_key_list(void_requests)',
      );
      final fkTables = foreignKeys.map((row) => row['table']).toSet();
      expect(fkTables, containsAll(['sales', 'users']));

      // The pre-existing sale survived the upgrade untouched.
      final sale = (await db.query(
        'sales',
        where: 'id = ?',
        whereArgs: ['sale-1'],
      )).single;
      expect(sale['total_minor_units'], 5000);

      await db.close();
    },
  );

  test('Upgrades a v8 database to v9, adding the sync_outbox queue', () async {
    var db = await LocalDatabase.openAt(dbPath);
    final now = DateTime.now().toIso8601String();
    await db.insert('users', {
      'id': 'user-1',
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
    await db.insert('shifts', {
      'id': 'shift-1',
      'cashier_id': 'user-1',
      'opening_cash_minor_units': 0,
      'status': 'CLOSED',
      'opened_at': now,
    });
    await db.insert('sales', {
      'id': 'sale-1',
      'receipt_number': 'REC-001',
      'cashier_id': 'user-1',
      'device_id': 'device-1',
      'shift_id': 'shift-1',
      'subtotal_minor_units': 5000,
      'discount_minor_units': 0,
      'total_minor_units': 5000,
      'amount_paid_minor_units': 5000,
      'change_minor_units': 0,
      'status': 'COMPLETED',
      'created_at': now,
    });

    // Rewind to the v8 shape: no sync_outbox table or its pending index.
    await db.execute('DROP TABLE sync_outbox');
    await db.execute('DROP INDEX IF EXISTS sync_outbox_pending');
    await db.execute('PRAGMA user_version = 8');
    await db.close();

    db = await LocalDatabase.openAt(dbPath);

    final version = await db.rawQuery('PRAGMA user_version');
    expect(version.first.values.first, LocalDatabase.schemaVersion);

    final tables = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    )).map((row) => row['name'] as String).toSet();
    expect(tables, contains('sync_outbox'));

    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index'",
    )).map((row) => row['name'] as String).toSet();
    expect(indexes, contains('sync_outbox_pending'));

    // sync_outbox is a fresh empty queue: nothing is marked pending yet.
    expect(await db.query('sync_outbox'), isEmpty);

    // The pre-existing sale survived the upgrade untouched.
    final sale = (await db.query(
      'sales',
      where: 'id = ?',
      whereArgs: ['sale-1'],
    )).single;
    expect(sale['total_minor_units'], 5000);

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
