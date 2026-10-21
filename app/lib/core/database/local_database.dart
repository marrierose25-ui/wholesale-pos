import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:uuid/uuid.dart';

class LocalDatabase {
  static const String databaseName = 'wholesale_pos.db';
  static const int schemaVersion = 6;
  static const String deviceIdFileName = 'device_id.txt';
  static const String themeSettingKey = 'theme_mode';

  LocalDatabase._();

  static void _configureFactory() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<Database> open() async {
    _configureFactory();
    final dir = await getApplicationSupportDirectory();
    return _openAt(p.join(dir.path, databaseName));
  }

  /// Opens a database at an explicit path. Used by tests that need to exercise
  /// migrations against a real file.
  static Future<Database> openAt(String path) async {
    _configureFactory();
    return _openAt(path);
  }

  static Future<Database> openInMemory() async {
    _configureFactory();
    return databaseFactory.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  static Future<Database> _openAt(String path) {
    return databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) async => await db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _onCreate,
        onUpgrade: _onUpgrade,
      ),
    );
  }

  /// Returns the stable ID of this installation. The ID is persisted next to
  /// the database so a restored backup can safely add the row back instead of
  /// attaching new sales to another machine's device record.
  static Future<String> registerCurrentDevice(Database db) async {
    if (db.path == inMemoryDatabasePath) {
      final existing = await db.query('devices', orderBy: 'rowid', limit: 1);
      if (existing.isNotEmpty) return existing.first['id']! as String;
      final id = const Uuid().v4();
      await _insertDeviceIfMissing(db, id);
      return id;
    }

    final stateFile = File(p.join(p.dirname(db.path), deviceIdFileName));
    String? id;
    try {
      if (await stateFile.exists()) {
        final saved = (await stateFile.readAsString()).trim();
        if (saved.isNotEmpty) id = saved;
      }
    } catch (_) {
      id = null;
    }
    if (id == null) {
      id = const Uuid().v4();
      await stateFile.writeAsString(id, flush: true);
    }
    await _insertDeviceIfMissing(db, id);
    return id;
  }

  static Future<void> _insertDeviceIfMissing(Database db, String id) async {
    final existing = await db.query(
      'devices',
      columns: ['id'],
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await db.insert('devices', {
      'id': id,
      'name': '${Platform.localHostname} Register',
      'platform': Platform.operatingSystem,
    });
  }

  static Future<String?> getSetting(Database db, String key) async {
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['value'] as String?;
  }

  static Future<void> setSetting(Database db, String key, String value) async {
    await db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
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
    if (oldVersion < 4) {
      await db.execute(
        "ALTER TABLE users ADD COLUMN salt TEXT NOT NULL DEFAULT ''",
      );
      await db.execute("ALTER TABLE sales ADD COLUMN shift_id TEXT");
      await db.execute("ALTER TABLE sales ADD COLUMN void_reason TEXT");
      await db.execute('''
        CREATE TABLE cash_movements (
          id TEXT PRIMARY KEY,
          shift_id TEXT NOT NULL,
          type TEXT NOT NULL,
          amount_minor_units INTEGER NOT NULL,
          reason TEXT,
          created_at TEXT NOT NULL
        )
      ''');
    }
    if (oldVersion < 5) {
      await db.execute('ALTER TABLE sales ADD COLUMN voided_at TEXT');
      await db.execute('ALTER TABLE sales ADD COLUMN voided_by TEXT');
      await db.execute('ALTER TABLE sales ADD COLUMN voided_shift_id TEXT');
      await db.execute('ALTER TABLE cash_movements ADD COLUMN user_id TEXT');
      final openShifts = await db.rawQuery(
        "SELECT COUNT(*) AS count FROM shifts WHERE status = 'OPEN'",
      );
      if ((openShifts.first['count'] as int) <= 1) {
        await db.execute(
          "CREATE UNIQUE INDEX one_open_shift ON shifts(status) WHERE status = 'OPEN'",
        );
      }
      await db.execute('''
        CREATE TRIGGER prevent_second_open_shift_insert
        BEFORE INSERT ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN')
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
      ''');
      await db.execute('''
        CREATE TRIGGER prevent_second_open_shift_update
        BEFORE UPDATE OF status ON shifts WHEN NEW.status = 'OPEN'
        AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN' AND id != NEW.id)
        BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
      ''');
      await db.execute('CREATE INDEX sales_shift_id ON sales(shift_id)');
    }
    if (oldVersion < 6) {
      await _rebuildCashMovementsWithUserForeignKey(db);
      await db.execute('''
        CREATE TABLE IF NOT EXISTS counters (
          name TEXT PRIMARY KEY,
          value INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
      await _createIndexesAndTriggers(db);
    }
  }

  /// Schema 5 added `user_id` with ALTER TABLE, which SQLite cannot attach a
  /// foreign key to. Rebuild the table once so upgraded databases match fresh
  /// installs.
  static Future<void> _rebuildCashMovementsWithUserForeignKey(
    Database db,
  ) async {
    final foreignKeys = await db.rawQuery(
      'PRAGMA foreign_key_list(cash_movements)',
    );
    if (foreignKeys.any((row) => row['table'] == 'users')) return;

    await db.execute('''
      CREATE TABLE cash_movements_v6 (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT,
        FOREIGN KEY(shift_id) REFERENCES shifts(id),
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');
    await db.execute('''
      INSERT INTO cash_movements_v6
        (id, shift_id, type, amount_minor_units, reason, created_at, user_id)
      SELECT id, shift_id, type, amount_minor_units, reason, created_at, user_id
      FROM cash_movements
    ''');
    await db.execute('DROP TABLE cash_movements');
    await db.execute('ALTER TABLE cash_movements_v6 RENAME TO cash_movements');
  }

  static Future<void> _createIndexesAndTriggers(DatabaseExecutor db) async {
    final openShifts = await db.rawQuery(
      "SELECT COUNT(*) AS count FROM shifts WHERE status = 'OPEN'",
    );
    if ((openShifts.first['count'] as int) <= 1) {
      await db.execute(
        "CREATE UNIQUE INDEX IF NOT EXISTS one_open_shift ON shifts(status) WHERE status = 'OPEN'",
      );
    }
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sales_shift_id ON sales(shift_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sales_created_at ON sales(created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS sale_items_sale_id ON sale_items(sale_id)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS audit_logs_created_at ON audit_logs(created_at)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS cash_movements_shift_id ON cash_movements(shift_id)',
    );
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_second_open_shift_insert
      BEFORE INSERT ON shifts WHEN NEW.status = 'OPEN'
      AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN')
      BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    ''');
    await db.execute('''
      CREATE TRIGGER IF NOT EXISTS prevent_second_open_shift_update
      BEFORE UPDATE OF status ON shifts WHEN NEW.status = 'OPEN'
      AND EXISTS (SELECT 1 FROM shifts WHERE status = 'OPEN' AND id != NEW.id)
      BEGIN SELECT RAISE(ABORT, 'A shift is already open'); END
    ''');
  }

  static Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();

    batch.execute('''
      CREATE TABLE users (
        id TEXT PRIMARY KEY,
        username TEXT UNIQUE NOT NULL,
        password_hash TEXT NOT NULL,
        salt TEXT NOT NULL,
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

    batch.execute('''
      CREATE TABLE cash_movements (
        id TEXT PRIMARY KEY,
        shift_id TEXT NOT NULL,
        type TEXT NOT NULL,
        amount_minor_units INTEGER NOT NULL,
        reason TEXT,
        created_at TEXT NOT NULL,
        user_id TEXT,
        FOREIGN KEY(shift_id) REFERENCES shifts(id),
        FOREIGN KEY(user_id) REFERENCES users(id)
      )
    ''');

    batch.execute('''
      CREATE TABLE sales (
        id TEXT PRIMARY KEY,
        receipt_number TEXT UNIQUE NOT NULL,
        cashier_id TEXT NOT NULL,
        device_id TEXT NOT NULL,
        shift_id TEXT NOT NULL,
        customer_name TEXT,
        payment_method TEXT NOT NULL DEFAULT 'CASH',
        subtotal_minor_units INTEGER NOT NULL,
        discount_minor_units INTEGER NOT NULL,
        total_minor_units INTEGER NOT NULL,
        amount_paid_minor_units INTEGER NOT NULL,
        change_minor_units INTEGER NOT NULL,
        status TEXT NOT NULL,
        void_reason TEXT,
        voided_at TEXT,
        voided_by TEXT,
        voided_shift_id TEXT,
        created_at TEXT NOT NULL,
        synced_at TEXT,
        FOREIGN KEY(cashier_id) REFERENCES users(id),
        FOREIGN KEY(device_id) REFERENCES devices(id),
        FOREIGN KEY(shift_id) REFERENCES shifts(id)
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
        FOREIGN KEY(sale_id) REFERENCES sales(id) ON DELETE CASCADE
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
      CREATE TABLE counters (
        name TEXT PRIMARY KEY,
        value INTEGER NOT NULL
      )
    ''');

    batch.execute('''
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');

    await batch.commit(noResult: true);
    await _createIndexesAndTriggers(db);
  }
}
