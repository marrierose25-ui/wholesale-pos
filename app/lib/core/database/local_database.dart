import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class LocalDatabase {
  static const _databaseName = 'wholesale_pos.db';
  static const _databaseVersion = 3;

  LocalDatabase._();

  static Future<Database> open() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final dir = await getApplicationSupportDirectory();
    final path = p.join(dir.path, _databaseName);

    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<Database> openInMemory() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: _databaseVersion,
        onCreate: _onCreate,
      ),
    );
  }

  static Future<void> _onUpgrade(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute('''
        CREATE TABLE shifts (
          id TEXT PRIMARY KEY,
          cashier_id TEXT NOT NULL,
          opening_cash_minor_units INTEGER NOT NULL,
          closing_cash_minor_units INTEGER,
          expected_cash_minor_units INTEGER,
          status TEXT NOT NULL,
          opened_at TEXT NOT NULL,
          closed_at TEXT
        )
      ''');
    }
    if (oldVersion < 3) {
      await db.execute(
        "ALTER TABLE sales ADD COLUMN payment_method TEXT NOT NULL DEFAULT 'CASH'",
      );
    }
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        role TEXT NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE products (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        code TEXT UNIQUE NOT NULL,
        category TEXT,
        unit TEXT NOT NULL,
        selling_price_minor_units INTEGER NOT NULL,
        is_active INTEGER NOT NULL DEFAULT 1,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE devices (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        platform TEXT NOT NULL,
        license_key TEXT,
        last_sync_at TEXT
      )
    ''');

    batch.execute('''
      CREATE TABLE sales (
        id TEXT PRIMARY KEY,
        receipt_number TEXT UNIQUE NOT NULL,
        cashier_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        customer_name TEXT,
        payment_method TEXT NOT NULL DEFAULT 'CASH',
        subtotal_minor_units INTEGER NOT NULL,
        discount_minor_units INTEGER NOT NULL,
        total_minor_units INTEGER NOT NULL,
        amount_paid_minor_units INTEGER NOT NULL,
        change_minor_units INTEGER NOT NULL,
        status TEXT NOT NULL,
        created_at TEXT NOT NULL,
        synced_at TEXT,
        FOREIGN KEY(cashier_id) REFERENCES users(id),
        FOREIGN KEY(device_id) REFERENCES devices(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE sale_items (
        id TEXT PRIMARY KEY,
        sale_id TEXT NOT NULL,
        product_id TEXT NOT NULL,
        product_name_snapshot TEXT NOT NULL,
        unit_price_snapshot_minor_units INTEGER NOT NULL,
        quantity INTEGER NOT NULL,
        line_discount_minor_units INTEGER NOT NULL,
        line_total_minor_units INTEGER NOT NULL,
        FOREIGN KEY(sale_id) REFERENCES sales(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE audit_logs (
        id TEXT PRIMARY KEY,
        user_id TEXT,
        action TEXT NOT NULL,
        details TEXT,
        created_at TEXT NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE shifts (
        id TEXT PRIMARY KEY,
        cashier_id TEXT NOT NULL,
        opening_cash_minor_units INTEGER NOT NULL,
        closing_cash_minor_units INTEGER,
        expected_cash_minor_units INTEGER,
        status TEXT NOT NULL,
        opened_at TEXT NOT NULL,
        closed_at TEXT
      )
    ''');

    await batch.commit(noResult: true);
  }
}
